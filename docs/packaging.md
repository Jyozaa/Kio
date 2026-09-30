# Unsigned Kio application

Build on Apple Silicon with the pinned uv lock and Swift toolchain:

```sh
scripts/build-unsigned-app.sh
open /Applications/Kio.app
```

The build uses a private temporary staging directory, verifies the bundle, and atomically installs the sole launchable project app at `/Applications/Kio.app`. Staging is removed on success or failure. Set `KIO_BUILD_OUTPUT` only for a temporary artifact check and remove that app after inspection.

Build tools are developer requirements only. The output carries standalone CPython
3.12.8, locked non-development Python distributions (including PyTorch, Laya and
tokenizers, plus `laya-mlx`/MLX/Metal on arm64 macOS), the static whisper.cpp executable, and the checksum-verified
CUA Driver 0.30.4 helper. It does not execute system Python, uv, a virtualenv or
source-checkout code. Set KIO_BUILD_OUTPUT to a temporary path for an isolated
artifact check; that path is replaced on each build and must not be used as a
second installed Kio identity.
The runtime directory is a full standalone installation, with internal dylib paths,
not a copied virtualenv. Python runs isolated with user site/PYTHONPATH disabled.

The [standalone Python distribution layout](https://gregoryszorc.com/docs/python-build-standalone/main/distributions.html)
provides a self-contained installation. Installed runtime dylibs and extension
modules are checked by scripts/check-artifact.py after relocation. The artifact
includes each Python distribution's licence files and an exact dependency inventory.

The packaged Swift host directly launches `Contents/Helpers/cua-driver serve
--embedded --socket … --permission-mode standard`. The Python helper connects through
the private socket using the documented MCP proxy. The CUA helper's upstream vendor
signature is verified and left intact. Accessibility and Screen & System Audio
Recording belong to Kio's retained bundle identifier `local.companion.dev`; no
separate CuaDriver.app is needed. Source-development builds may still use the
standalone Driver fallback. The development launcher ad-hoc signs its app wrapper with
an explicit designated requirement for the retained `local.companion.dev` identifier and
resolves its local Python and Whisper tools without requiring a shell environment.
The ad-hoc signature is not a Developer ID identity. macOS privacy grants apply to the exact canonical app identity at `/Applications/Kio.app`; quit and reopen Kio after changing grants, then use Check Setup.
Input Monitoring is required for the global shortcut and is checked during normal setup.
For a stable local development identity, create or select a code-signing certificate in
Keychain Access once, confirm it with `security find-identity -v -p codesigning`, and run
`KIO_CODESIGN_IDENTITY='Exact certificate name' scripts/run-macos.sh` (or set the same
variable for `scripts/build-unsigned-app.sh`). The scripts never create a permanent
certificate silently. Without a named identity, the explicit ad-hoc requirement is used;
macOS may still require regranting TCC after a rebuild. No Developer ID signing/notarisation command runs;
Apple toolchain binaries can carry automatic ad-hoc signatures. This is not an
Apple-verified distribution. A downloaded/quarantined copy may be blocked by
Gatekeeper; use macOS Privacy & Security's explicit Open Anyway/manual-open flow
if you choose to trust the build. Kio never removes quarantine or bypasses TCC.

First launch automatically opens a versioned Kio setup window with runtime and
permission checks, required Laya, required global shortcut, optional microphone/local voice,
optional Gemini, and a self-test. Returning from System Settings triggers a fresh
permission check. Once setup is complete, revoked Accessibility or Screen & System
Audio Recording access opens a focused repair view instead of restarting onboarding.
Models are installed under ~/Library/Application Support/Kio/models and verified
against source-controlled revision/size/SHA-256 manifests. Existing HF cache files
may be reused only after checksum verification. The user starts an in-app download
when a model is missing; Kio shows byte progress and supports retry. Setup self-test
performs CUA health, local bounded Laya inference, and a local voice-model load when
the corresponding permissions and runtime are available. It does not execute a
desktop action or invoke Gemini.

After the embedded driver's startup health check succeeds, the helper starts one
background Laya load when the verified local model manifest is present. A task that
needs semantic inference waits for that same load; direct app-open, browser-search
and URL tasks stay independent of it. The runtime retains one chooser instance and
does not create a second load while prewarming. On the 16 GB development Mac, an
isolated cold-load measurement took 5.6 seconds, reached 1.95 GB maximum RSS and
3.14 GB peak footprint; the host memory-pressure reading showed 39% free before
measurement. These are machine-specific figures, not a general memory guarantee.

Gemini keys entered in setup use macOS Keychain service Kio, account gemini.
Save replaces that item; delete removes it. The stored key is never displayed.
Only the non-secret model identifier is in preferences. The GUI passes the retrieved
key privately to its child process; it is not placed in protocol messages, files,
logs or trajectories. Existing environment-key support remains for development.
Voice and Gemini can be skipped. Kio never speaks.

Credential-free artifact import/protocol/native-library audit:

```sh
scripts/agent.sh scripts/check-artifact.py /path/to/Kio.app
```

Separate live Keychain test (temporary unique account, removed afterward):

```sh
swiftc apps/macos/Sources/CompanionCore/KeychainStore.swift scripts/keychain-smoke.swift -o /tmp/kio-keychain-smoke
/tmp/kio-keychain-smoke
```

The clean-environment test uses a relocated bundle, clean working directory,
minimal PATH and no developer Python/Gemini variables on the current macOS user.
It is not a claim of testing a fresh macOS VM, a separate user's TCC grants, Intel,
or every macOS release. Runtime requires the macOS permissions granted to Kio itself.
Ad-hoc host rebuilds or identity changes can require permissions to be granted again;
the vendor-signed nested helper is not re-signed. Speech deployment target is explicitly macOS 14; upstream
binaries' runtime requirements remain subject to their supported Apple Silicon OS.

Phase 34 trims copied compiler headers/tools and unused CPython development/UI modules
from the runtime. All inference libraries and Python package metadata remain. See the
[bundle-size audit](bundle-size.md) for before/after sizes, package breakdown, and
the packaged Laya regression comparison.
