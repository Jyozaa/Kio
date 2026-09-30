"""Copy the locked standalone Python installation, not a relocatable virtualenv."""

import importlib.metadata
import json
import shutil
import sys
import sysconfig
from pathlib import Path

PRUNE_PATHS = (
    "include",  # CPython headers are only needed to compile extension modules.
    "lib/python3.12/ensurepip",  # Kio does not support installing packages into its runtime.
    "lib/python3.12/idlelib",
    "lib/python3.12/tkinter",
    "lib/python3.12/lib2to3",
    "lib/python3.12/pydoc_data",
    "lib/tcl8.6",
    "lib/tk8.6",
    "lib/python3.12/site-packages/torch/include",  # No runtime C++ extension compilation.
)


def prune_runtime(output: Path) -> int:
    """Remove audited developer/UI payloads from a newly assembled runtime only."""
    removed = 0
    for relative in PRUNE_PATHS:
        path = output / relative
        if path.is_dir():
            removed += sum(item.stat().st_size for item in path.rglob("*") if item.is_file())
            shutil.rmtree(path)

    torch_bin = output / "lib/python3.12/site-packages/torch/bin"
    for path in torch_bin.glob("protoc*"):
        if path.is_file():
            removed += path.stat().st_size
            path.unlink()

    tk_extension = output / "lib/python3.12/lib-dynload/_tkinter.cpython-312-darwin.so"
    if tk_extension.exists():
        removed += tk_extension.stat().st_size
        tk_extension.unlink()
    return removed


def main() -> None:
    output = Path(sys.argv[1])
    if output.exists():
        raise SystemExit("Runtime destination must be new")
    base = Path(sys.base_prefix)
    if sys.version_info[:3] != (3, 12, 8) or not (base / "lib/libpython3.12.dylib").is_file():
        raise SystemExit("Expected standalone CPython 3.12.8 macOS runtime")
    ignore = shutil.ignore_patterns(
        "__pycache__", "*.pyc", "direct_url.json", "_virtualenv*", "*.pth"
    )
    shutil.copytree(base, output, symlinks=False, ignore=ignore)
    site = output / "lib/python3.12/site-packages"
    if site.exists():
        shutil.rmtree(site)  # Only the newly created build output, never the source runtime.
    shutil.copytree(
        sysconfig.get_paths()["purelib"], site, dirs_exist_ok=True, symlinks=False, ignore=ignore
    )
    # Console-script shebangs are never used: all helper entry points use bundled python -I -m.
    # Drop copied launcher scripts which embed developer paths.
    for path in (output / "bin").iterdir():
        if path.name not in {"python", "python3", "python3.12"} and path.is_file():
            path.unlink()
    removed = prune_runtime(output)
    packages = []
    for dist in importlib.metadata.distributions():
        license_name = (
            dist.metadata.get("License-Expression")
            or dist.metadata.get("License")
            or "; ".join(
                v for v in dist.metadata.get_all("Classifier", []) if v.startswith("License ::")
            )
            or "See bundled distribution licence files"
        )
        packages.append(
            {
                "name": dist.metadata["Name"],
                "version": dist.version,
                "license": license_name,
                "bundled": True,
            }
        )
    (output.parent / "python-dependencies.json").write_text(
        json.dumps(sorted(packages, key=lambda p: p["name"].lower()), indent=2)
    )
    print(
        f"Bundled Python {sys.version.split()[0]} with {len(packages)} distributions; pruned {removed / 1024**2:.1f} MiB"
    )


if __name__ == "__main__":
    main()
