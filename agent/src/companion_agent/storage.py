"""Kio identity and non-destructive application-support migration."""

import shutil
import tempfile
from pathlib import Path

PRODUCT_NAME = "Kio"
BUNDLE_IDENTIFIER = "local.companion.dev"
KEYCHAIN_SERVICE = "Kio"
LEGACY_NAMES = ("LocalCompanion", "Local Companion")


def application_support(base: Path | None = None) -> Path:
    base = base if base is not None else Path.home() / "Library" / "Application Support"
    root = base / PRODUCT_NAME
    if root.exists():
        if not root.is_dir():
            raise ValueError("Kio support root is not a directory")
        return root
    base.mkdir(parents=True, exist_ok=True)
    legacy = next((base / name for name in LEGACY_NAMES if (base / name).is_dir()), None)
    if legacy is None:
        root.mkdir(mode=0o700, exist_ok=True)
        return root
    # Copy to a sibling staging directory. Never rename/delete the legacy source.
    # If another process establishes Kio concurrently, prefer that state.
    with tempfile.TemporaryDirectory(prefix=".kio-migrate-", dir=base) as staging:
        copied = Path(staging) / "Kio"
        shutil.copytree(legacy, copied, symlinks=True)
        try:
            copied.rename(root)
        except OSError:
            if not root.is_dir():
                raise
    return root
