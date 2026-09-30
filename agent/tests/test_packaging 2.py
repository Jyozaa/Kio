import importlib.util
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/package-runtime.py"
SPEC = importlib.util.spec_from_file_location("kio_package_runtime", SCRIPT)
assert SPEC and SPEC.loader
PACKAGE_RUNTIME = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PACKAGE_RUNTIME)


def test_runtime_pruning_removes_only_audited_non_runtime_payloads(tmp_path):
    root = tmp_path / "python"
    removable = [
        "include/python3.12/Python.h",
        "lib/python3.12/ensurepip/__init__.py",
        "lib/python3.12/idlelib/__init__.py",
        "lib/python3.12/tkinter/__init__.py",
        "lib/python3.12/lib2to3/__init__.py",
        "lib/python3.12/pydoc_data/__init__.py",
        "lib/tcl8.6/init.tcl",
        "lib/tk8.6/tk.tcl",
        "lib/python3.12/site-packages/torch/include/torch.h",
        "lib/python3.12/site-packages/torch/bin/protoc",
        "lib/python3.12/site-packages/torch/bin/protoc-3.21.12.0",
        "lib/python3.12/lib-dynload/_tkinter.cpython-312-darwin.so",
    ]
    for relative in removable:
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"non-runtime")
    retained = [
        "lib/python3.12/site-packages/torch/lib/libtorch_cpu.dylib",
        "lib/python3.12/site-packages/torch/bin/torch_shm_manager",
        "lib/python3.12/site-packages/torch/__init__.py",
    ]
    for relative in retained:
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"runtime")

    removed = PACKAGE_RUNTIME.prune_runtime(root)

    assert removed == len(removable) * len(b"non-runtime")
    assert all(not (root / relative).exists() for relative in removable)
    assert all((root / relative).is_file() for relative in retained)
