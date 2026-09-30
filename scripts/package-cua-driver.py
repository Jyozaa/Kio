"""Install the pinned, signed CUA Driver CLI into a Kio artifact."""

import argparse
import hashlib
import json
import shutil
import tarfile
import tempfile
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "third_party" / "cua-driver.json"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def archive_path(manifest: dict) -> Path:
    cache = Path.home() / "Library" / "Caches" / "Kio" / f"cua-driver-{manifest['version']}"
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / "cua-driver-universal.tar.gz"
    if archive.is_file() and sha256(archive) == manifest["sha256"]:
        return archive
    archive.unlink(missing_ok=True)
    with tempfile.NamedTemporaryFile(dir=cache, prefix="cua-download-", delete=False) as staged:
        temporary = Path(staged.name)
    try:
        request = urllib.request.Request(manifest["source"], headers={"User-Agent": "Kio-build"})
        with urllib.request.urlopen(request, timeout=120) as response, temporary.open("wb") as out:
            shutil.copyfileobj(response, out)
        if sha256(temporary) != manifest["sha256"]:
            raise ValueError("pinned CUA archive checksum mismatch")
        temporary.replace(archive)
    finally:
        temporary.unlink(missing_ok=True)
    return archive


def member_ending(archive: tarfile.TarFile, suffix: str) -> tarfile.TarInfo:
    matches = [
        member
        for member in archive.getmembers()
        if member.name.endswith(suffix) and ".app/" not in member.name
    ]
    if len(matches) != 1 or not matches[0].isfile():
        raise ValueError(f"pinned CUA archive is missing a unique regular {suffix}")
    return matches[0]


def package(executable: Path, license_path: Path) -> None:
    manifest = json.loads(MANIFEST.read_text())
    if not manifest.get("bundled") or not manifest.get("version"):
        raise ValueError("Kio must bundle a reviewed CUA release")
    with tarfile.open(archive_path(manifest), "r:gz") as archive:
        binary = member_ending(archive, "/cua-driver")
        license_member = member_ending(archive, "/LICENSE")
        binary_source = archive.extractfile(binary)
        license_source = archive.extractfile(license_member)
        if binary_source is None or license_source is None:
            raise ValueError("pinned CUA archive could not be read")
        executable.parent.mkdir(parents=True, exist_ok=True)
        with executable.open("wb") as destination:
            shutil.copyfileobj(binary_source, destination)
        with license_path.open("wb") as destination:
            shutil.copyfileobj(license_source, destination)
    executable.chmod(0o755)
    expected = manifest["executable_sha256"]
    if sha256(executable) != expected:
        executable.unlink(missing_ok=True)
        raise ValueError("pinned CUA executable checksum mismatch")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--executable", type=Path, required=True)
    parser.add_argument("--license", type=Path, required=True)
    args = parser.parse_args()
    package(args.executable, args.license)
    print(f"Bundled pinned CUA Driver {json.loads(MANIFEST.read_text())['version']}")


if __name__ == "__main__":
    main()
