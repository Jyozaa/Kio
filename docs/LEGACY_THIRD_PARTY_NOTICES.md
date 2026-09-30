# Third-party notices

Initial architectural references (later training adaptation is documented below):

| Project | Licence | Use |
|---|---|---|
| [Clicky](https://github.com/farzaa/clicky) | MIT | Floating companion interaction inspiration |
| [CUA Driver](https://github.com/trycua/cua) | MIT | Pinned 0.30.4 helper bundled in Kio.app; official embedded integration |
| [Laya](https://github.com/NandhaKishorM/laya) | Apache-2.0 | Local decision provider (0.3.20) |
| [laya-mlx](https://github.com/mizorewww/laya-mlx/tree/0a859518634112655cb97c745dbf04f5191aaf13) | Apache-2.0; derived-work attribution in `third_party/laya-mlx/NOTICE` | Pinned native Apple Silicon inference backend (0.2.0) |
| [MLX](https://github.com/ml-explore/mlx) | MIT | Apple Metal inference runtime (0.32.3), arm64 macOS only |
| [MLX Metal](https://github.com/ml-explore/mlx) | MIT | Metal runtime support (0.32.3), arm64 macOS only |
| [jev-ultrafast](https://github.com/browser-use/jev-ultrafast) | No code adapted | Operation/target head architecture reference |
| [typesafe-computer-use](https://github.com/awlevin/typesafe-computer-use) | MIT | Architecture reference only |

No OmniParser, Apple Vision OCR worker, Gemini Vision path, or other third-party perception component is bundled. The
upstream CUA Driver executable is copied byte-for-byte from the pinned universal
release, retains its vendor signature and is accompanied by its MIT licence.
Model: convaiinnovations/laya revision 55cf4c4ebb4ebe31b2550e8bdf3bd21b99753851;
model artifacts are separately installed under Kio Application Support; an existing
verified Hugging Face cache may be reused. Weights are not bundled in the app.
Development/build transitive dependencies are recorded in agent/uv.lock.
The MLX Python distributions and their licence texts are conditional Apple Silicon
runtime dependencies and are copied into `Contents/Resources/third-party-licenses/mlx/`;
the laya-mlx Apache-2.0 licence and required upstream attribution are copied beside
them. The complete laya-mlx source remains separately available at its pinned revision.

## Phase 12 review (historical, 2026-09-27)

- A former screenshot OCR prototype was removed after the signed CUA Perception migration; no OCR worker or Vision runtime is shipped.
- [CUA Perception](https://github.com/trycua/cua/blob/main/libs/cua-driver/docs/perception-extension.md):
  separately installed optional extension, absent from this artifact. Current upstream
  detector ledger is AGPL-3.0-only; OCR artifacts Apache-2.0. Not installed or bundled.
- [OmniParser](https://github.com/microsoft/OmniParser): reviewed as an optional visual
  parser. Detector obligations and additional runtime/model footprint make it unsuitable
  for this default lightweight pipeline. No OmniParser code or weights included.
- No icon detector added; VisualRegionDetector remains a local provider interface.
  OCR text is not treated as proof of clickability or assigned invented icon meanings.

## Phase 15 local speech

- whisper.cpp v1.9.4 release (runtime reports 1.9.4-dev), source revision
  927cfce34f31707e17f2bff35c349632fb9e2c3a: MIT, offline speech recognition.
  Built unmodified from official source; the bundled `whisper-cli` and optional
  official `whisper-stream` helper use the same source. Includes ggml 0.23.0 (MIT),
  Apple Accelerate/Metal system frameworks; no cloud STT or TTS.
  Source: https://github.com/ggml-org/whisper.cpp/tree/v1.9.4
- SDL2-compat 2.32.70 (Zlib) and SDL3 3.2.0 (Zlib): bundled together when the
  official `whisper-stream` helper is available, so local microphone capture does
  not depend on Homebrew at runtime. The app carries both dylibs beside the helper
  and rewrites their load paths to the app bundle.
- Whisper tiny.en ggml weights: MIT, downloaded separately, 77,704,715 bytes,
  revision/SHA-256/source in models/stt.json. Not committed or part of source.
  https://huggingface.co/ggerganov/whisper.cpp
- AVFoundation: Apple system framework, microphone capture only; not redistributed.
- Upstream JFK public speech sample was used only for local inference validation,
  not a microphone recording or Kio command. No generated speech was used.

## Phase 18 training adaptation

Laya 0.3.20 (Apache-2.0) official RLCD notebook algorithms adapted in training.py,
upstream revision 9d955671415fc19f069b9cc998928075c1f255ec. Attribution and
reproduction details: docs/laya-training.md. PyTorch 2.14.0 (BSD-style),
transformers 5.17.0 (Apache-2.0), safetensors (Apache-2.0) are existing runtime
dependencies reused for local training. Experimental weights are stored separately
in Kio Application Support and are not committed or selected by default.

## Phase 19 bundled distribution

The unsigned Apple Silicon artifact bundles standalone CPython 3.12.8 (PSF-2.0),
whisper.cpp 1.9.4 / ggml (MIT), and the distributions below. Python and
linked dependency notices are retained in third_party/python-licenses and copied
into the app; wheel licence files remain in each dist-info directory.
The speech source licence is included. CUA Driver 0.30.4 is bundled under MIT at
Contents/Helpers/cua-driver with its original vendor signature and licence. No
perception detector or AGPL component is included; Apple frameworks are not
redistributed.
Laya and Whisper model weights are downloaded/reused separately from pinned
checksum manifests (Apache-2.0 and MIT respectively), never part of the app/source.

| Distribution | Version | Licence metadata | Purpose | Bundled |
|---|---|---|---|---|
| annotated-doc | 0.0.5 | MIT | Transitive local runtime support | Yes |
| annotated-types | 0.8.0 | MIT | Transitive local runtime support | Yes |
| anyio | 4.15.1 | MIT | Transitive local runtime support | Yes |
| attrs | 26.1.0 | MIT | Transitive local runtime support | Yes |
| certifi | 2026.7.22 | MPL-2.0 | TLS trust bundle | Yes |
| cffi | 2.1.1 | MIT-0 | Transitive local runtime support | Yes |
| click | 8.5.0 | BSD-3-Clause | Transitive local runtime support | Yes |
| companion-agent | 0.1.0 | Project-owned; no third-party grant claimed | Project-owned helper | Yes |
| cryptography | 50.0.1 | Apache-2.0 OR BSD-3-Clause | Transitive local runtime support | Yes |
| filelock | 4.0.4 | MIT | Transitive local runtime support | Yes |
| fsspec | 2026.9.0 | BSD-3-Clause | Transitive local runtime support | Yes |
| h11 | 0.16.0 | MIT | Transitive local runtime support | Yes |
| hf-xet | 1.6.0 | Apache-2.0 | Transitive local runtime support | Yes |
| httpcore | 1.0.9 | BSD-3-Clause | Transitive local runtime support | Yes |
| httpx | 0.28.1 | BSD-3-Clause | Optional Gemini HTTPS | Yes |
| httpx-sse | 0.4.3 | MIT | Transitive local runtime support | Yes |
| huggingface_hub | 1.33.0 | Apache-2.0 | Pinned model cache/install | Yes |
| idna | 3.20 | BSD-3-Clause | Transitive local runtime support | Yes |
| Jinja2 | 3.1.6 | BSD License | Transitive local runtime support | Yes |
| jsonschema | 4.26.0 | MIT | Transitive local runtime support | Yes |
| jsonschema-specifications | 2025.9.1 | MIT | Transitive local runtime support | Yes |
| laya | 0.3.20 | Apache-2.0 | Bounded local chooser | Yes |
| laya-mlx | 0.2.0 | Apache-2.0 | Preferred Apple Silicon Laya inference | Apple Silicon only |
| markdown-it-py | 4.2.0 | MIT License | Transitive local runtime support | Yes |
| MarkupSafe | 3.0.3 | BSD-3-Clause | Transitive local runtime support | Yes |
| mcp | 1.30.0 | MIT | CUA transport | Yes |
| mlx | 0.32.3 | MIT | Apple Silicon inference runtime | Apple Silicon only |
| mlx-metal | 0.32.3 | MIT | MLX Metal runtime support | Apple Silicon only |
| mdurl | 0.1.2 | MIT License | Transitive local runtime support | Yes |
| mpmath | 1.3.0 | BSD | Transitive local runtime support | Yes |
| networkx | 3.7 | BSD-3-Clause | Transitive local runtime support | Yes |
| numpy | 2.5.3 | BSD-3-Clause AND 0BSD AND MIT AND Zlib AND CC0-1.0 | Transitive local runtime support | Yes |
| packaging | 26.3 | Apache-2.0 OR BSD-2-Clause | Transitive local runtime support | Yes |
| pycparser | 3.0 | BSD-3-Clause | Transitive local runtime support | Yes |
| pydantic | 2.13.5 | MIT | Transitive local runtime support | Yes |
| pydantic-settings | 2.15.0 | MIT | Transitive local runtime support | Yes |
| pydantic_core | 2.46.5 | MIT | Transitive local runtime support | Yes |
| Pygments | 2.21.0 | BSD-2-Clause | Transitive local runtime support | Yes |
| PyJWT | 2.15.0 | MIT | Transitive local runtime support | Yes |
| python-dotenv | 1.2.3 | BSD-3-Clause | Transitive local runtime support | Yes |
| python-multipart | 0.0.32 | Apache-2.0 | Transitive local runtime support | Yes |
| PyYAML | 6.0.3 | MIT | Transitive local runtime support | Yes |
| referencing | 0.37.0 | MIT | Transitive local runtime support | Yes |
| regex | 2026.9.10 | Apache-2.0 AND CNRI-Python | Transitive local runtime support | Yes |
| rich | 15.0.0 | MIT | Transitive local runtime support | Yes |
| rpds-py | 2026.6.3 | MIT | Transitive local runtime support | Yes |
| safetensors | 0.8.0 | Apache Software License | Transitive local runtime support | Yes |
| setuptools | 84.0.0 | MIT | Transitive local runtime support | Yes |
| shellingham | 1.5.4 | ISC License | Transitive local runtime support | Yes |
| sse-starlette | 3.4.11 | BSD-3-Clause | Transitive local runtime support | Yes |
| starlette | 1.7.0 | BSD-3-Clause | Transitive local runtime support | Yes |
| sympy | 1.14.0 | BSD | Transitive local runtime support | Yes |
| tokenizers | 0.23.2 | Apache Software License | Local tokenization | Yes |
| torch | 2.14.0 | Apache-2.0 AND Apache-2.0 WITH LLVM-exception AND BSD-2-Clause AND BSD-3-Clause AND BSL-1.0 AND MIT | Local inference/training backend | Yes |
| tqdm | 4.70.1 | MPL-2.0 AND MIT | Transitive local runtime support | Yes |
| transformers | 5.17.0 | Apache 2.0 License | Local encoder/tokenizer loading | Yes |
| typer | 0.27.2 | MIT | Transitive local runtime support | Yes |
| typing-inspection | 0.4.4 | MIT | Transitive local runtime support | Yes |
| typing_extensions | 4.16.0 | PSF-2.0 | Transitive local runtime support | Yes |
| uvicorn | 0.54.0 | BSD-3-Clause | Transitive local runtime support | Yes |

## Phase 21 Driver upgrade

CUA Driver 0.30.2 (MIT), pinned release and verified archive/installer hashes
in third_party/cua-driver.json; the executable is bundled into Kio.app unchanged.
Its `com.trycua.driver` vendor signature remains intact inside the app, while the
Swift host is locally ad-hoc signed as `local.companion.dev` for TCC responsibility.
MCP 1.30.0 and the existing uv.lock remain unchanged; the Python SDK is not required
by the persistent MCP integration. Optional
parse_visual_regions availability does not install its AGPL icon-detector extension.
No perception dependency or weights were added. See docs/cua-upgrade.md.

## Phase 36 CUA Perception extension

The optional [CUA Perception extension 0.2.1](https://github.com/trycua/cua/releases/tag/cua-perception-v0.2.1)
is installed separately by the user through the signed CUA Driver extension
catalog. It is not bundled in `Kio.app`, downloaded by Kio, or required for
structured AX/DOM tasks. The publisher-verified catalog records the detector
components and their licences: the OmniParser-derived detector is AGPL-3.0-only,
Ultralytics is AGPL-3.0-only, PP-OCR is Apache-2.0, and the ONNX Runtime glue is
MIT. Kio accepts visual regions only when the extension returns an exact
capture-bound response from the same CUA screenshot; it never invokes the
a separate local OCR worker as the production visual-perception route. The extension
and its model remain user-managed under `~/.cua-driver/extensions` and Kio's
application bundle stays free of these AGPL components.
