# Legacy Kio README

This guide describes the earlier experimental CUA-based Kio. Its code, supporting
documentation, and third-party notices remain in this repository. The former
`scripts/check.sh` command is preserved as `scripts/check-legacy.sh`.

# Kio

A local macOS SwiftUI companion with a Python helper, embedded CUA execution, local
Laya decisions, bounded semantic planning, and optional text-only Gemini assistance.
The current continuation keeps the canonical app at `/Applications/Kio.app` and
records live provider/OS limits in [Part 2 results](docs/part2-results.md).
See [verified results and limitations](docs/part1-results.md) and
[gate evidence](docs/phase-status.md).
See the [tested app compatibility matrix](docs/compatibility.md) for host-specific
results and limitations.
Fixture trajectory and Laya error analysis is in [Phase 33 dogfood results](docs/phase33-dogfood.md).

## Run the packaged app

Build with `scripts/build-unsigned-app.sh`; it stages privately, verifies, atomically installs, and runs `/Applications/Kio.app`. On first launch,
Kio opens a setup window that checks its local runtime and models, explains required
permissions, and opens the matching macOS privacy pane. It rechecks when Kio returns
to the foreground. Accessibility and Screen & System Audio Recording must be granted
to Kio itself. The app carries Python and its dependencies and starts its bundled CUA
helper as a direct child process; end users need no terminal, Python installation,
or separate CuaDriver.app.
See [packaging, setup and manual-open instructions](docs/packaging.md).
See the [Phase 34 bundle-size audit](docs/bundle-size.md) for final artifact size and
what remains in the self-contained runtime.

## Development run

Requires macOS 14+, Swift 6, uv, and CUA Driver 0.30.4 for the source-development
fallback (pinned in third_party/cua-driver.json). The packaged app does not use this
fallback: its Swift host starts the bundled driver and Kio owns the TCC identity.
For source development, start the standalone app daemon if needed:

```sh
open -n -g -a CuaDriver --args serve
scripts/run-macos.sh
```

The launcher syncs the locked Python 3.12.8 environment, builds a local unsigned
app, and starts the real helper. First use downloads the pinned Laya checkpoint
into the normal Hugging Face cache; inference is local. Set
`KIO_LAYA_BACKEND=torch LAYA_DEVICE=cpu` to force the Torch CPU backend. Apple Silicon defaults to native MLX inference with
Torch fallback; other hosts use the existing Torch backend. The backend parity
measurements and opt-in decision schemas are documented in
[the Kio decision protocol](docs/kio-decision-protocol.md) and
[the Laya backend comparison](docs/benchmarks/laya-backend-comparison.md).
The held-out [video-parity benchmark](docs/video-parity.md) distinguishes offline
parser checks from live app behavior.

Try `Open Calculator`, `Open https://example.com`, or `Search Google for Norbert Wiener`.
Explicit browser selection is supported with `Open https://example.com in Safari` or
`Search Google for Norbert Wiener in Chrome`; Kio does not switch browsers when one is
named. A target app is optional: Kio resolves explicit app names from the installed app
catalog, otherwise uses the frontmost app or a relevant recent task/browser context.
It asks only when the current app/window evidence is genuinely ambiguous. Run starts work;
Stop cancels before the next action. Goal-directed actions run automatically under the
ALLOW/BLOCK policy; unsupported or blocked actions stop with a concise reason.

Global web searches use the deterministic browser route; named-site and current-page
searches stay within that page's search controls. “Press the mute button” is treated as
one activation, while “mute me” asks Kio to reach and verify a microphone state.

Gemini is optional: set `GEMINI_API_KEY` and `GEMINI_MODEL` in the launch environment.
Do not put secrets in files. Literal text does not need Gemini. Without it, writing
requests and unresolved uncertainty stop safely. `COMPANION_DEMO=1` runs an inert demo.

## Local fixture and verification

```sh
scripts/agent.sh -m http.server 8765 --bind 127.0.0.1 --directory fixtures/browser
```

Open `http://127.0.0.1:8765/index.html` in Safari. Use:
`Enter "hello world" in Message field, choose Option B, then click Reach success`.
The fixture includes a disabled control, duplicate labels, scrolling and a fake
purchase handler. Refresh it before each demo.

```sh
scripts/check-legacy.sh
scripts/agent.sh -m companion_agent.driver
scripts/agent.sh -m companion_agent.evaluate --corpus fixtures/decisions/simple.json
```

For explicit-target live checks, discover current pid/window IDs with CUA's
`list_apps` and `list_windows`, then replace the example placeholders:

```sh
scripts/agent.sh -m companion_agent.smoke_loop --pid PID --window-id WINDOW --goal 'Enter "hello world" in Message field, choose Option B, then click Reach success'
scripts/agent.sh -m companion_agent.smoke_loop --pid PID --window-id WINDOW --goal 'Write a short friendly greeting in the Message field' --mock-system2
scripts/agent.sh -m companion_agent.live_checks --pid PID --window-id WINDOW
```

The last command uses real observations, mock decisions and injected stale state;
it asserts that no desktop action executes. See results for what was tested live.
No screenshot persistence, TTS, third-party perception models, signing or notarisation.
Visual understanding is provided by the separately installed, signed CUA Perception extension. Kio never sends screenshots to Gemini and Laya receives structured regions/candidates only.

Development dependencies are installed in `~/Library/Caches/Kio/development-venv`
(or `KIO_DEV_ENV`). This avoids Desktop file offloading observed during development.
Use `scripts/agent.sh` for helper CLI commands after running the launcher or check script.

Kio uses `~/Library/Application Support/Kio/`; existing prototype state is preserved.
Development and packaged workflows install the one canonical bundle at
`/Applications/Kio.app`; temporary staging bundles are deleted after verification.
The bundle identifier remains `local.companion.dev`, so grant Accessibility, Screen
Recording, and Input Monitoring to that exact app. Model caches and configuration
remain under Kio Application Support.

Kio starts as a menu-bar companion without opening a large window. Its menu contains
**Settings**, **Setup**, **Diagnostics**, and **Quit Kio**; task controls remain in the
explicit developer diagnostics window. Voice and active-task states appear in a compact
48-point non-activating animated blob below the current display's notch/safe area. Its
flat color morphs gently while idle, responds to microphone level while listening, and
uses quiet dots/check/attention marks for work and results. The blob follows display
changes and does not take focus from the frontmost app. Subtle macOS interface cues
play on listening, completion, and attention; they can be disabled in Settings. Kio
remains silent and never uses text-to-speech. Read-only UI questions may expand it into
a short answer card. The **Review voice transcript before running**
option defaults off; otherwise local transcription submits automatically. Escape cancels
during permission, listening, or transcription states.

Kio separates answer-only questions, read-only questions about the visible UI, and action
requests before creating action candidates. Read-only inspection uses a bounded
`UIInspector` snapshot without candidate IDs or executable metadata and does not launch,
focus, or change the inspected app. Actions keep their validated semantic steps,
literal parameters, and constraints through the observe/decide/act/verify loop. The
planner remains bounded; ambiguous or unsupported workflows may still stop for user
input.

Gemini is text-only and optional. It may provide generated text or high-level prose
guidance; it is never given screenshots and cannot select or execute computer actions.

Local voice development setup (optional):

```bash
scripts/build-stt.sh
scripts/agent.sh -m companion_agent.models models/stt.json --install
scripts/run-macos.sh
```

Model check without download: omit `--install`. Hold **Hold to talk** or enable the
global **⌥+⌘** shortcut in Kio's Input Monitoring settings. Local speech/silence
detection ends capture and submits a transcript automatically. The packaged path uses
one warm `whisper-stream` process and does not write a WAV; the development fallback
may use a private temporary WAV when the stream helper is unavailable. Input Monitoring
is required for the normal Kio setup; Microphone remains optional and typed commands
work without it. Cancel voice stops capture/transcription and discards temporary
audio. Capture is limited to 30 seconds, transcription to 60 seconds. Kio never
speaks. The current tiny.en model is English-only. Fallback WAV files are removed on
completion/cancel; a process/OS crash can leave one until the next launch, which
cleans abandoned recorder directories safely.

The global listener observes only modifier changes and key-down events with a
non-intercepting Core Graphics session tap; it does not store typed keys. Input
Monitoring must be explicitly enabled for Kio in System Settings. Phase 28 verified the
local microphone → Whisper → command → computer-use path with three controlled acoustic
stimuli (macOS `say` played through the built-in speakers); these were not human-spoken
tests. See `docs/phase-status.md` for the exact tasks and limits. Kio itself has no TTS.

The helper also keeps a short in-memory conversational context across commands so a
follow-up search can use the browser just opened, or an ordinary reference can resolve
to a recently verified page or completed object. Context expires and is only semantic;
all actions still require fresh CUA state and freshly validated candidates. The CUA MCP
connection stays warm for the helper lifetime; every action still gets fresh observations
and tokens. One local Laya instance is prewarmed in the background after the startup
health check when the verified model manifest is available. Deterministic app, search,
and URL commands do not wait for Laya.

Kio now uses ALLOW/BLOCK policy with no approval UI. Permitted goal-directed
actions run automatically, including explicitly requested sends/submissions.
Secret entry, final financial commitments, ambiguous targets and unsafe/unsupported
actions return needs_user. Freshness and independent completion checks remain
mandatory. See docs/phase-status.md for the sequential gate evidence.

Optional structured recording and offline analysis: [trajectory workflow](docs/trajectories.md).
Recording is off unless `KIO_RECORD_TRAJECTORIES=1` or the fixture `--record` flag is set.

Offline evaluation, calibration and real tiny training: [Laya workflow](docs/laya-training.md).
Generic Laya remains the default; experimental checkpoints are opt-in.

Final credential-free checks: `scripts/check-all.sh`. [Final scenarios, timing and limitations](docs/phase20-results.md).
