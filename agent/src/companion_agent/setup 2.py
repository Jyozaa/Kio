"""Explicit first-run checks/install; JSON status only, no secret or image output."""

import argparse
import asyncio
import json
import os
import shutil
import subprocess
import tempfile
import wave
from pathlib import Path

from .driver import CuaDriver, DriverError
from .models import install_model, model_path, valid_model
from .storage import application_support


def model_ready(manifest, root):
    return all(
        valid_model(model_path(item, root), item) for item in manifest.get("files", [manifest])
    )


def install_manifest(manifest, root, *, progress=None):
    items = manifest.get("files", [manifest])
    total_size = sum(item["size"] for item in items)
    completed = 0

    def report(item, downloaded):
        if progress is not None:
            progress(
                {
                    "event": "progress",
                    "model": manifest["name"],
                    "file": item["name"],
                    "downloaded": completed + downloaded,
                    "total": total_size,
                }
            )

    for item in items:
        target = model_path(item, root)
        if valid_model(target, item):
            report(item, item["size"])
            completed += item["size"]
            continue
        # Reuse only exact pinned, checksum-verified HF cache content. No download here.
        if manifest["name"] == "Laya":
            from huggingface_hub import try_to_load_from_cache

            cached = try_to_load_from_cache(
                "convaiinnovations/laya", item["name"], revision=item["revision"]
            )
            if isinstance(cached, str) and valid_model(Path(cached), item):
                target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                import tempfile

                with tempfile.NamedTemporaryFile(dir=target.parent, delete=False) as temporary:
                    staging = Path(temporary.name)
                try:
                    shutil.copyfile(cached, staging)
                    staging.replace(target)
                finally:
                    staging.unlink(missing_ok=True)
                report(item, item["size"])
                completed += item["size"]
                continue
        last_reported = 0

        def item_progress(downloaded, item_size, item=item):
            nonlocal last_reported
            if downloaded == item_size or downloaded - last_reported >= 8 * 1024 * 1024:
                report(item, downloaded)
                last_reported = downloaded

        install_model(item, root, progress=item_progress)
        completed += item["size"]
    (root / "models" / (manifest["name"].lower().replace("/", "-") + ".manifest.json")).write_text(
        json.dumps(manifest, indent=2)
    )


def voice_model_self_test(manifest, root):
    """Load the optional local voice model using generated silence, never mic audio."""
    if not model_ready(manifest, root):
        return "skipped"
    executable = os.environ.get("KIO_STT_EXECUTABLE")
    if not executable or not os.access(executable, os.X_OK):
        return "runtime_missing"
    model = model_path(manifest, root)
    try:
        with tempfile.TemporaryDirectory(prefix="kio-voice-self-test-") as folder:
            audio = Path(folder) / "silence.wav"
            with wave.open(str(audio), "wb") as output:
                output.setnchannels(1)
                output.setsampwidth(2)
                output.setframerate(16_000)
                output.writeframes(b"\0\0" * 3200)
            result = subprocess.run(
                [executable, "-m", str(model), "-f", str(audio), "-l", "en", "-nt", "-np"],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=20,
                check=False,
            )
    except (OSError, subprocess.SubprocessError):
        return "failed"
    return "ready" if result.returncode == 0 else "failed"


async def status(manifests, *, self_test=False):
    root = application_support()
    result = {
        "driver": "missing",
        "permissions": "unchecked",
        "laya": "missing",
        "stt": "optional",
        "perception": "optional",
        "voice_test": "not_run",
        "status": "needs_setup",
        "message": "Complete required setup checks.",
    }
    for key in ("laya", "stt"):
        manifest = json.loads((manifests / f"{key}.json").read_text())
        if model_ready(manifest, root):
            result[key] = "ready"
    try:
        async with CuaDriver.connect() as driver:
            result["driver"] = "ready"
            await driver.health()
            result["permissions"] = "ready"
            result["perception"] = (
                "ready" if driver.capabilities.visual_regions_contract else "optional"
            )
    except DriverError as error:
        result["permissions"] = error.code
    if self_test:
        stt_manifest = json.loads((manifests / "stt.json").read_text())
        result["voice_test"] = voice_model_self_test(stt_manifest, root)
    if result["laya"] == "ready" and result["permissions"] == "ready":
        result["status"] = "ready"
        result["message"] = "Required setup checks passed."
        if self_test:
            from .candidates import Element, Observation, build_candidates
            from .chooser import LayaChooser

            chooser = await asyncio.to_thread(LayaChooser)
            table = build_candidates(
                Observation(
                    "self-test",
                    0,
                    0,
                    (Element("e", "self-test", "Success", "AXStaticText", None, True, True, "AX"),),
                ),
                "Reach Success",
            )
            decision = await asyncio.to_thread(chooser.choose, "Reach Success", table, [])
            table.validate(decision.candidate_id, "self-test")
            result["message"] = (
                "CUA health, model load and bounded inference passed. No computer action executed."
            )
            if result["voice_test"] == "ready":
                result["message"] += " The optional local voice model loaded successfully."
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["check", "install-laya", "install-stt", "self-test"])
    parser.add_argument("--manifests", type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.command.startswith("install-"):
            name = args.command.removeprefix("install-")
            manifest = json.loads((args.manifests / f"{name}.json").read_text())
            install_manifest(
                manifest,
                application_support(),
                progress=lambda event: print(json.dumps(event), flush=True),
            )
        result = asyncio.run(status(args.manifests, self_test=args.command == "self-test"))
    except Exception:  # noqa: BLE001 -- setup boundary never exposes provider errors or paths
        result = {
            "status": "error",
            "message": "Setup failed. Check the connection, model files and CUA permissions, then retry.",
        }
    print(json.dumps(result))
    raise SystemExit(0 if result["status"] == "ready" else 1)


if __name__ == "__main__":
    main()
