# Kio application bundle size audit

Measured on Apple Silicon macOS 27.0 on 2026-09-28. Sizes below sum the actual
regular-file bytes in each app bundle; `du` also reports APFS allocated blocks, which
varied more because the old app contained filesystem clones. Neither figure includes
the user-managed Laya or Whisper weights in Application Support.

| Bundle | File payload | `du -sk` allocation |
|---|---:|---:|
| Before Phase 34 | 703.55 MiB | 755.3 MiB |
| After Phase 34 | 649.97 MiB | 675.2 MiB |
| Reduction | 53.58 MiB (7.6%) | 80.1 MiB allocated |

PyTorch remains the largest dependency. Its package payload fell from 495.9 MiB to
450.8 MiB after pruning its C++ headers. The required `libtorch_cpu.dylib` remains
about 368 MiB. Other larger packages in the final bundle are Transformers (46.8 MiB),
SymPy (25.4 MiB), NumPy (19.4 MiB), and Tokenizers (9.4 MiB). Kio's Laya Python
package is about 0.3 MiB. Whisper's standalone CLI is about 4.5 MiB. Model manifests
are bundled, while the roughly 804 MiB Laya model and 74 MiB Whisper model remain
managed under `~/Library/Application Support/Kio/models/` with revision and
SHA-256 validation.

The runtime removes 53.9 MiB of copied, non-runtime payloads: PyTorch C++ headers and
its two `protoc` compiler binaries; CPython development headers, `ensurepip`, IDLE,
Tkinter/Tcl/Tk, `lib2to3`, and pydoc topic data. The shared-memory helper, all Python
runtime packages, their `.dist-info` metadata and licences, and native runtime
libraries remain. The Python environment is built with `--no-dev`; pytest and Ruff are
not in the dependency inventory. No alternative inference backend was introduced.

The clean build contains 57 runtime Python distributions and 46 Mach-O files. The
relocated artifact check imported Python 3.12.8, PyTorch 2.14.0, Laya 0.3.20,
Tokenizers, NumPy, MCP, and Kio from the app in isolated mode; it launched the inert
NDJSON helper and found no developer library paths. A packaged Laya run on the frozen
14-case test set matched the development installation's expected decisions: 10/14
combined accuracy, 7/7 target decisions, and zero false high-confidence errors.
Warm median inference was 117 ms packaged and 111 ms in the development environment;
cold model load was 7.42 s in this run. Calibration error was 0.184 packaged versus
0.189 in development. Laya's existing warning for its 11+ choice temperature remains;
no improvement or new calibration is claimed.

Build and regression command:

```sh
scripts/check-all.sh
```

The exact unsigned artifact tested for this report was a private temporary build; the
current canonical artifact is `/Applications/Kio.app`. It remains self-contained
from the user's perspective: no system Python, uv, developer virtual environment,
source checkout, or model install in Terminal is required. The CUA Driver is embedded
in the canonical app and is the TCC-owning runtime.
