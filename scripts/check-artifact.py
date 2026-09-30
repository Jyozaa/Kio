"""Run with any Python; artifact probes always use its own isolated interpreter."""
import argparse
import json
import os
import pathlib
import subprocess
import tempfile
import hashlib

p = argparse.ArgumentParser()
p.add_argument("app", type=pathlib.Path)
args = p.parse_args()
app = args.app.resolve()
bundle_id = subprocess.check_output(
    ["/usr/libexec/PlistBuddy", "-c", "Print :CFBundleIdentifier", str(app / "Contents/Info.plist")],
    text=True,
).strip()
assert bundle_id == "local.companion.dev", bundle_id
driver = app / "Contents/Helpers/cua-driver"
driver_manifest = json.loads((app / "Contents/Resources/cua-driver.json").read_text())
assert driver_manifest["version"] == "0.30.4" and driver_manifest["bundled"] is True
assert driver_manifest["bundle_path"] == "Contents/Helpers/cua-driver"
assert driver.is_file() and os.access(driver, os.X_OK)
for relative in (
    "Contents/Resources/third-party-licenses/laya-mlx/LICENSE",
    "Contents/Resources/third-party-licenses/laya-mlx/NOTICE",
    "Contents/Resources/third-party-licenses/mlx/MLX-LICENSE",
    "Contents/Resources/third-party-licenses/mlx/MLX-Metal-LICENSE",
):
    assert (app / relative).is_file(), relative
driver_hash = hashlib.sha256(driver.read_bytes()).hexdigest()
assert driver_hash == driver_manifest["executable_sha256"], driver_hash
assert subprocess.check_output([str(driver), "--version"], text=True).strip() == "cua-driver 0.30.4"
subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(driver)], check=True)
subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(app)], check=True)
print("Pinned CUA 0.30.4 executable, vendor signature, and Kio app identity passed.")
python = app / "Contents/Resources/python/bin/python3.12"
env = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": os.environ["HOME"], "TMPDIR": tempfile.gettempdir()}
probe = '''import sys, pathlib, json, ssl, platform, torch, tokenizers, laya, mcp, companion_agent, numpy
root=pathlib.Path(sys.executable).resolve().parents[1]
assert sys.version_info[:3] == (3,12,8)
assert pathlib.Path(sys.base_prefix).resolve() == root
for module in (torch,tokenizers,laya,mcp,companion_agent,numpy):
 assert pathlib.Path(module.__file__).resolve().is_relative_to(root)
backend="torch"
if sys.platform == "darwin" and platform.machine() == "arm64":
 import mlx, mlx.core, laya_mlx
 assert all(pathlib.Path(path).resolve().is_relative_to(root) for path in mlx.__path__)
 for module in (mlx.core,laya_mlx):
  assert pathlib.Path(module.__file__).resolve().is_relative_to(root)
 backend="mlx"
print(json.dumps({"python":sys.version.split()[0],"torch":torch.__version__,"backend":backend,"isolated":bool(sys.flags.isolated)}))
'''
with tempfile.TemporaryDirectory(prefix="kio-artifact-check-") as cwd:
    result = subprocess.run(
        [str(python), "-I", "-B", "-c", probe],
        env=env,
        cwd=cwd,
        capture_output=True,
        text=True,
        check=False,
        timeout=90,
    )
    if result.returncode:
        raise SystemExit(f"Bundled import probe failed:\n{result.stdout}\n{result.stderr}")
    print(result.stdout.strip())
    message = {"version": 1, "kind": "health", "task_id": "artifact-protocol", "text": "", "status": ""}
    result = subprocess.run([str(python), "-I", "-B", "-m", "companion_agent", "--demo"], input=json.dumps(message)+"\n", env=env, cwd=cwd, capture_output=True, text=True, check=True, timeout=30)
    assert json.loads(result.stdout)["status"] == "ready"
    print("Isolated bundled imports and inert NDJSON passed (not a live CUA test).")
# All non-system dylib dependencies must resolve inside the relocated artifact.
count = 0
for path in app.rglob("*"):
    if not path.is_file(): continue
    with path.open("rb") as stream: magic = stream.read(4)
    if magic not in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xfe\xed\xfa\xcf"): continue
    count += 1
    output = subprocess.check_output(["/usr/bin/otool", "-l", str(path)], text=True)
    command = ""
    for line in output.splitlines():
        line = line.strip()
        if line.startswith("cmd "): command = line[4:]
        if command in {"LC_LOAD_DYLIB", "LC_LOAD_WEAK_DYLIB", "LC_REEXPORT_DYLIB"} and line.startswith("name "):
            dep = line[5:].split(" (", 1)[0]
            assert dep.startswith(("@", "/usr/lib/", "/System/Library/")), (path.name, dep)
        if command == "LC_RPATH" and line.startswith("path "):
            value = line[5:].split(" (", 1)[0]
            assert not value.startswith(("/Users/", "/opt/", "/usr/local/")), (path.name, value)
print(f"Audited {count} Mach-O files: no developer library paths.")
