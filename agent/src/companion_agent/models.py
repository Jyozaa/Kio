"""Explicit checksum-verified model installation, never downloads during inference."""

import argparse
import hashlib
import json
import ssl
import tempfile
import urllib.request
from pathlib import Path

from .storage import application_support


def secure_open(url, timeout):
    import certifi

    return urllib.request.urlopen(
        url, timeout=timeout, context=ssl.create_default_context(cafile=certifi.where())
    )


def model_path(manifest, root):
    relative = Path(manifest["install_path"])
    if relative.is_absolute() or ".." in relative.parts:
        raise ValueError("invalid_model_path")
    path = root / relative
    if not path.resolve().is_relative_to(root.resolve()):
        raise ValueError("invalid_model_path")
    return path


def valid_model(path, manifest):
    if not path.is_file() or path.stat().st_size != manifest["size"]:
        return False
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest() == manifest["sha256"]


def install_model(manifest, root, *, opener=secure_open, progress=None):
    path = model_path(manifest, root)
    if valid_model(path, manifest):
        return path
    if not manifest["url"].startswith("https://"):
        raise ValueError("invalid_model_source")
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with tempfile.TemporaryDirectory(prefix=".install-", dir=path.parent) as staging:
        download = Path(staging) / "model"
        with opener(manifest["url"], timeout=60) as response, download.open("wb") as output:
            total = 0
            while chunk := response.read(1024 * 1024):
                total += len(chunk)
                if total > manifest["size"]:
                    raise ValueError("model_size_mismatch")
                output.write(chunk)
                if progress is not None:
                    progress(total, manifest["size"])
        if not valid_model(download, manifest):
            raise ValueError("model_checksum_mismatch")
        download.replace(path)
    metadata = path.with_suffix(".manifest.json")
    metadata.write_text(json.dumps(manifest, indent=2))
    return path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("manifest", type=Path)
    parser.add_argument("--install", action="store_true")
    args = parser.parse_args()
    manifest = json.loads(args.manifest.read_text())
    root = application_support()
    if args.install:
        install_model(manifest, root)
    ready = valid_model(model_path(manifest, root), manifest)
    print(json.dumps({"name": manifest["name"], "ready": ready, "revision": manifest["revision"]}))
    raise SystemExit(0 if ready else 1)


if __name__ == "__main__":
    main()
