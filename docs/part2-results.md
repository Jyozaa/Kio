# Kio Part 2 results — phase gates and current progress

Part 1 baseline reverified before edits: `scripts/check.sh` passed 95 Python tests,
5 Swift tests, lint, format and build (2026-09-27). Part 2 gates were completed sequentially;
external test exceptions remain explicit in the final scenario report.

The chronological entries below preserve earlier gate evidence for audit purposes.
Where an older entry mentions Apple Vision/OCR, Gemini Vision, `dist/Kio.app`, a
cached development bundle, or CUA 0.30.2, the current continuation entries at the
bottom supersede that implementation. The current production route is structured
browser → AX → separately installed signed CUA Perception, with one canonical
`/Applications/Kio.app` and text-only optional Gemini.

## Phase 11.0 identity decisions

Product and executable: Kio; artifact: Kio.app. Internal Python package and Swift
module/class names are retained. NDJSON v1 schemas and task semantics are unchanged.

Bundle identifier `local.companion.dev` is preserved. Existing external CuaDriver.app
continues to own its own Accessibility/Screen Recording grants. Renaming display
text does not justify changing either identity. Future Keychain service is exactly
`Kio`; no credentials are stored yet.

Application support: `~/Library/Application Support/Kio/`. Only the root is created
until a feature actually needs a subdirectory. Existing Kio state wins. Otherwise,
legacy LocalCompanion or Local Companion state is copied through staging, retaining
the entire original directory. None of these state directories existed on this host
before migration. The existing Hugging Face cache is reused, not moved or deleted.

Phase 11.0 PASS: 98 Python tests / 5 Swift tests; native Kio launch, direct command,
Stop, CUA observation and Laya 9/10 verified. Phases 11–12 PASS: 125 Python / 5 Swift tests. Real AX four-action regression
passed. Real native OCR detected Settings on a poor-AX canvas (capture 909 ms,
OCR 130 ms, merge <1 ms). CUA 0.23.2 lacks capture-bound pixel authority; unmapped
OCR-only controls safely require user intervention. No raw image enters Laya.
Phase 13 PASS: 140 Python / 5 Swift tests; false DONE rejected on real CUA state
with injected decisions and zero actions. Real Laya fixture completed in five
actions with independent field/option/Success evidence. Direct Calculator and
Google search independently verified, zero Gemini. Phase 14 PASS: 162 Python / 6 Swift tests. Vision contract coverage passes;
no live Gemini tests (key/model absent). Vision is optional and disabled by default.
Phase 15 PASS for available checks: 165 Python / 9 Swift tests. Real offline
whisper.cpp sample transcription succeeded (20.450 s first run, 0.422 s repeat).
Microphone smoke unavailable: permission not granted; no live voice-command claim.
Phase 16 PASS under revised autonomous ALLOW/BLOCK requirement: 185 Python /
10 Swift tests. Real CUA/Laya Start → Continue → Send → Submit → Success completed
in four actions, zero approvals/Gemini. Real-state safety fault checks reject stale
and blocked actions and honor Stop. Historical approval blocker no longer applies.
Phase 17 PASS: 189 Python / 10 Swift tests. Real four-step trajectory replay
matched 4/4 with local Laya and zero CUA execution. Corrections/export produced
four sanitized training rows, grouped by task. Phase 18 PASS: 193 Python / 10 Swift tests. Real CPU forward/backward, checkpoint
reload and inference succeeded (34.192 s). Generic/calibrated/tiny-trained held-out
accuracy all 10/14; no accuracy improvement claimed and generic remains default.
See docs/laya-training.md for calibration, memory, latency and reproduction.
Phase 19 PASS on a relocated, environment-isolated current-host artifact: standalone
Kio.app, real setup/self-test, Calculator, four-action CUA/Laya workflow, and real
Keychain round trip. 195 Python / 10 Swift tests, 48 native files audited. No claim
of fresh-VM/TCC or microphone testing. Phase 20 PASS for applicable local gates: 209 Python / 11 Swift tests, real final
packaged 12-action task (47.884 s, zero OCR/Gemini), secret boundary/Stop/recovery,
12/12 offline replay and another real fine-tuning smoke. See
[final scenario evidence and limitations](phase20-results.md).


## Phase 21 — CUA 0.30.2 capability audit PASS (2026-09-28)

- Scope: upgrade the external official CUA app, inspect actual stable release/MCP
  schemas and capture contract, add schema-driven `DriverCapabilities`, preserve native
  capture IDs, and distinguish an advertised optional parser from its installed state.
- Release 0.30.2 is the stable SemVer channel per its release notes despite the
  monorepo's GitHub prerelease marker. Verified archive SHA-256 and deep/strict app
  signature. Existing and replacement bundles share the same `com.trycua.driver`
  designated requirement and Team ID; official installer retained TCC grants. The
  old app bundle remains in the Kio cache as a recovery copy.
- Inspected live schemas for `get_window_state`, `click`, `type_text`, `browser_prepare`,
  `get_browser_state`, browser actions, `get_desktop_state`, and
  `parse_visual_regions`; pinned docs also cover the Python SDK and exact capture/action
  semantics. Kio continues using MCP because the external app owns TCC. The zero-dependency
  embedded Python SDK is not adopted, so `uv.lock` and MCP 1.30.0 remain unchanged;
  external Driver hash/version pin is `third_party/cua-driver.json`.
- Files: `agent/src/companion_agent/capabilities.py`, `driver.py`,
  `agent/tests/test_capabilities.py`, reduced live schema fixture, third-party pin,
  README, architecture, notices and `docs/cua-upgrade.md`.
- `scripts/check-all.sh` baseline before edits: PASS, 209 Python / 11 Swift, lint, format,
  build, isolated 755 MiB app audit, tiny training reload/inference and privacy audit
  (43.119 s training smoke, no errors). `scripts/check.sh` after changes: PASS, 216 Python /
  11 Swift; lint, format and build PASS.
- Live 0.30.2 `health_report`: overall ok; Accessibility and Screen Recording PASS.
  Four-action form PASS, 12-action local workflow PASS, direct Calculator and Google
  search PASS (0 Laya/Gemini), five safety checks PASS (zero guarded actions); real
  Stop cancelled after one action. Password goal returned needs_user before typing and
  the low-confidence real chooser executed zero actions.
- Real OCR on the poor-AX visual canvas: native 2x capture 1254×1568 (0.447 s), Apple
  Vision 7 regions (0.251 s), 6 bounded candidates, real Laya (0.565 s), zero actions,
  zero Gemini. Native `capture_id` was present and bound to the frame. The optional CUA
  parser returned `not_installed`; `visual_regions=false`, while its tool contract is
  recorded as present. No extension was installed because the icon detector is
  AGPL-3.0-only; local Vision remains the parser.
- Known limit: Phase 21 does not yet route OCR candidates to CUA clicks; safe visual
  execution is the next phase. `uv.lock` deliberately stays unchanged because no CUA
  Python SDK is needed by the app-owned MCP integration.

## Phase 22 — per-observation surface routing PASS

`SurfaceResolver` derives surface kind and identity from each fresh normalized
observation and live CUA capability set. `CapabilityRouter` prefers a supported
structured browser route, then usable accessibility controls, then an exact native
capture-bound visual result. Desktop routing is opt-in. Multi-window selection uses
visible geometry and deterministic title/session evidence; ambiguous targets require
user input. Routes are recomputed after actions and dialogs/transient surfaces are
reclassified.

Verification: `scripts/check.sh` passed 223 Python tests, 11 Swift tests, build, Ruff
lint and formatting. A live CUA 0.30.2 Safari observation routed through accessibility;
local Laya completed the two-action fixture and GoalVerifier observed Success with
zero Gemini. Metrics: `/tmp/kio-phase22-live-metrics.json`. No live DOM route or visual
click is claimed; Phase 23 handles capture-bound visual execution.

## Phase 23 — capture-bound visual actions

Apple Vision OCR output now becomes a visual candidate only when the text is relevant
to the active goal, confidence and bounds pass local checks, and a real native CUA
capture ID is present. Laya selects a candidate ID and never receives coordinates.
Before acting, Kio obtains a fresh observation and image, confirms the observation and
image digest are unchanged, rebuilds the candidate table, and uses the exact CUA
capture-bound click contract. Stale, clipped, low-confidence or unsupported results
stop without a blind click.

`scripts/check.sh` passed 234 Python tests, 11 Swift tests, Ruff lint/format and Swift
build. A real CUA 0.30.2 + Safari canvas probe produced 11 OCR regions, 7 bounded
choices and one visual candidate. Real Laya chose it at 0.7332 confidence; capture
439 ms, OCR 159 ms, merge 0.33 ms, chooser 351 ms. The probe executed zero actions and
made zero Gemini calls. Real CUA capture-bound clicks advanced Settings → Continue →
Option B → Success; GoalVerifier observed the independent Success marker. The measured
two-action continuation took 10.646 s total, zero Gemini. Metrics:
`/tmp/kio-phase23-visual-probe.json` and `/tmp/kio-phase23-visual-e2e-final.json`.

During the live run OCR rendered Settings as `Settcngs`, and progress tracking repeated
the first clause after the click. Kio now stores a locally selected canonical goal
token in private candidate metadata for progress only; this does not change the OCR
description or add model authority. A regression test covers that case. CUA's capture
ID remains the only pixel-action authority; Kio's SHA-256 digest is a stale-state check,
not a substitute.

This live gate covers the available Safari visual fixture, not arbitrary GUI accuracy
or every display configuration. Optional CUA visual parsing remains uninstalled and
Gemini was not involved. The upstream Laya calibration warning remains and its
confidence threshold has not been weakened.

## Phase 24 — browser-agnostic control

Explicit `Open <URL> in <app>` and `Search Google for <query> in <app>` now resolve the
requested installed app and pass its bundle identity to LaunchServices. Verification
reads an address field from that exact app process; when a browser hides the scheme,
Kio uses the expected scheme but still requires the exact host, path, query and fragment.
An unavailable explicit app returns needs_user instead of opening a different default
browser. AX state and surface routing stay generic across browser brands.

Live Safari and Google Chrome runs both opened and independently verified the requested
local fixture URL. The same AX-backed form task completed in Safari in four actions and
in Chrome across three runs after an initial fail-closed dropdown attempt; the final
Chrome state independently matched `hello browser`, Option B and Success. The Chrome
AX tree contained a 6-pixel clipped duplicate of Option B next to the full 24-pixel
item. Kio now excludes such a clipped menu fragment from both candidate construction
and duplicate-target ambiguity checks. The full element remains subject to normal Laya
confidence and policy checks. Metrics: `/tmp/kio-phase24-safari-ax.json`,
`/tmp/kio-phase24-chrome-ax.json`, and `/tmp/kio-phase24-chrome-ax-final.json`.
Reproduce direct app routing with
`PYTHONPATH=agent/src scripts/agent.sh -m companion_agent.browser_smoke --application Safari --url http://127.0.0.1:8765/index.html`
(substitute `Chrome` to select Chrome). Reproduce the AX task with
`PYTHONPATH=agent/src scripts/agent.sh -m companion_agent.smoke_loop --pid 44355 --window-id 25471 --goal 'Enter "hello browser" in Message field, choose Option B, then click Reach success'`
(Chrome: PID 3337, window 71).

CUA 0.30.2's actual live `get_browser_state` contract was probed. Chrome's existing
profile returned `browser_consent_required`; the current Phase K route now starts the
official preparation attempt and falls back only when that attempt fails. The live
profile returned `browser_route_unavailable` because its `DevToolsActivePort` was not
readable. The driver-owned isolated route refused because this host lacks its required
vendor-signed system Chromium executable. Safari and VS Code's Electron window returned
`browser_route_unavailable`. No hidden setup or profile change was attempted, and no
live structured DOM action is claimed. VS Code was read-only inspected through CUA and
OCR; the selected window offered a usable AX route, so Kio sent no editor action.
Firefox, Arc, Brave and Edge are not installed in the current app inventory. These are
host-specific limits, not mock passes. CUA's official browser contract and preparation boundary are documented
in its [MCP tool reference](https://github.com/trycua/cua/blob/main/docs/content/docs/reference/cua-driver/mcp-tools.mdx)
and [web-page guide](https://github.com/trycua/cua/blob/main/docs/content/docs/how-to-guides/driver/drive-a-web-page.mdx).

## Phase 25 — generic app control and native dialog continuity

Kio now follows a supported compact native dialog surfaced as its own AXWindow. The
recognizer requires a small bounded accessibility subtree made from dialog text and
buttons, and only affects exact fresh-token delivery. The task loop selects that
foreground same-app window, rechecks its identity before action, and returns to the
original content window after dismissal. No application-specific task macro was added.

The live Chrome fixture proved browser Continue → native confirmation OK → browser
Success using CUA Driver 0.30.2 and local Laya. It completed in two actions, took
7.048 s, and made zero Gemini calls. Stage medians: CUA observation 305 ms, Laya
471 ms, fresh observation 276 ms, CUA action 2165 ms. GoalVerifier independently
observed the fixture's Success marker. Metrics: `/tmp/kio-phase25-cross-surface-dialog-final.json`.

`scripts/check.sh` passed after this implementation: Ruff lint/format, 243 Python
tests, Swift build, and 11 Swift tests. A final read-only CUA Driver 0.30.2 health and
window-resolution check passed; it found the expected Chrome fixture window and no
active compact dialog.

The Safari file-picker fixture exposed a current CUA limitation: its native Open window
was listed but `get_window_state` could not associate it with an AXWindow; there were no
controls, native capture ID, or OCR regions. Kio returned `needs_user` before action.
The cross-surface acceptance example is therefore the native confirmation, not file
selection. File-picker execution remains fail-closed and unsupported on this host.
No data was uploaded or sent externally.

## Phase 26 — global modifier-only voice shortcut

Kio's modifier state machine triggers once after an Option+Command chord is released,
rejects any chord with an intervening ordinary key, and accepts either modifier order.
The Core Graphics session tap is `listenOnly`; it observes only flag changes and
key-down events and passes events through. Kio explicitly checks/requests Input
Monitoring, reports its status, and requests microphone access only after a trigger.
Voice capture now ends after 1.0 s of trailing silence once speech is detected, with
8 s no-speech and 30 s total bounds. An active task is canceled before a replacement
voice command is submitted.

`scripts/check.sh` passed with 243 Python tests, 19 Swift tests, lint, formatting and
build. Live Kio bundle UI reported the shortcut enabled. With Calculator foreground and
Kio inactive, `swift scripts/post-shortcut-smoke.swift --send-option-command` sent a
synthetic Core Graphics modifier-only sequence; Kio entered its microphone permission
state. This confirms the live cross-app event path but does not claim a physical-key
test. At the time of that run, the mic remained unauthorized. Full-screen, other-Space,
Safari and Finder variants remain untested.

## Phase 27 — notch-expanding voice UI

- Files: `Companion.swift`, `GlobalShortcutMonitor.swift`,
  `NotchOverlayController.swift`, `OverlayLayout.swift`, `OverlayLayoutTests.swift`,
  README, architecture and phase status.
- Architecture: menu-bar-first app; separately opened debug/setup windows; a SwiftUI
  view in a non-activating, borderless AppKit panel. Screen choice is keyboard-focus
  screen, then pointer, then first available display. Uses live safe-area and visible
  frame geometry and follows display changes. Existing local VAD and whisper.cpp route
  are retained. Automatic submit remains default; `Review voice transcript before
  running` persists locally and defaults off. Escape cancels active voice capture.
- Tests/command: `scripts/check.sh` PASS — Ruff lint, 54-file format check, 243 Python
  tests, Swift build, 22 Swift tests. New geometry tests cover notch, no-notch/negative
  origin and width clamp; existing VAD/voice cancellation/shortcut tests pass.
- Live UI smoke: `scripts/run-macos.sh`; then
  `swift scripts/post-shortcut-smoke.swift --send-option-command`. Kio ran with bundle
  ID `local.companion.dev`; there was no visible Kio window before activation. The
  modifier event displayed a 360×92 panel at Quartz bounds x=848, y=39 on the built-in
  2056×1329 display. The live safe top was 38 px, matching the panel's placement below
  the notch; Safari remained frontmost. The microphone reached Listening, but the run
  did not use an intentional phrase. It later showed a low-confidence status, which is
  not counted as a transcript or task success. Kio was quit cleanly and its helper
  stopped. The temporary inspection screenshot was deleted; no new trajectory file or
  voice temporary directory remained.
- Limitations: intentional microphone phrase → transcript → verified task belongs to
  Phase 28. No external-display hotplug or physical chord was available. A delayed
  Escape test occurred after the initial listening state had advanced, so it is not
  counted as live Escape confirmation. No TTS was added.

## Phase 28 — local microphone command E2E

The first-use microphone path now checks AVFoundation authorization explicitly, asks
macOS only when permission is not determined, and offers a System Settings route when
denied. Spoken trailing punctuation is normalized before deterministic direct routing.
CUA app resolution groups duplicate same-bundle process records and chooses the unique
active instance; if multiple records remain plausible, it fails closed.

`scripts/check.sh` passed: Ruff lint and format (54 Python files), 244 Python tests,
Swift build and 22 Swift tests. CUA Driver 0.30.2 live health returned `ok`.

With the real microphone and local Whisper, three macOS `say` phrases played through
the MacBook speakers were captured acoustically (not supplied to Kio as audio files;
also not human-spoken tests). `Open Calculator.` led to Calculator independently
observed frontmost. `Open Google Chrome and search for Norbert Wiener.` led to Chrome
and independently observed Google results for that query. `Click Continue until
Success.` drove 12 fresh actions through CUA and Laya in the local Safari fixture; its
independent success marker and title both became `Success`. This was zero Gemini.
Voice latency was not measured. Temporary screenshots and acoustic test material were
deleted; Kio recording temp directories were empty after the run and trajectory
recording remained disabled.

## Phase 29 — short conversational session context

Added an in-memory, bounded `SessionContext` shared by commands within the persistent
helper process. It stores current app/process/window/page, last completed goal, recent
quoted entities, URLs and target apps, plus bounded selected/created/entered-item
references. It expires after ten minutes of inactivity. Closing the target or losing
the remembered window clears the relevant context; changing apps clears object-specific
references. It can resolve “Search …” in the just-opened browser, “Go there” to the last
verified page, and “Call it …” to a title-field goal only if object creation completed.
It supplies semantic routing only, never candidate or action authority, and is not
persisted or given to Laya as a transcript.

`scripts/check.sh` passed with 252 Python tests, 22 Swift tests, Ruff lint/format and
the Swift build. The live CUA Driver 0.30.2 smoke kept one Runtime alive for
`Open Google Chrome` followed by `Search Norbert Wiener` while the caller's target
remained Safari. Both completed through the direct path; the first task's verifier
observed Google Chrome, and the second's URL verifier observed
`google.com/search?q=Norbert+Wiener`. The search used remembered Chrome and made zero
Gemini calls. A read-only health probe briefly returned `driver_unavailable`; the
subsequent complete sequential smoke reconnected and passed. Item naming has test
coverage but was not live-tested against Notes.

## Phase 30 — performance measurement and routing

Added opt-in timing samples for full runtime tasks, structured observation, DOM and AX
subroutes, and route-specific actions. Existing measurements already cover direct
parsing/execution, CUA observation/action, screenshots, OCR, perception merge, candidate
construction, Laya, GoalVerifier, Gemini and STT. Summaries include count, median, p90,
first and warm median; arguments, goals and images are not stored. Tests prove route
samples are opt-in and contain only timing values.

`scripts/check.sh` passed: Ruff lint and format, 253 Python tests, Swift build and 22
Swift tests. On CUA Driver 0.30.2, the Chrome local form fixture completed a four-action
AX task (`phase thirty check`, Option B, Reach success) with independent field/option/
Success verification, zero screenshot/OCR and zero Gemini. For four decisions/actions:

| Stage | Median | p90 | First | Warm median |
|---|---:|---:|---:|---:|
| AX / structured observation | 296.6 ms | 384.6 ms | 384.6 ms | 294.6 ms |
| Laya | 780.3 ms | 954.0 ms | 913.6 ms | 647.0 ms |
| CUA action | 2257.5 ms | 3375.9 ms | 3375.9 ms | 2251.6 ms |
| Fresh observation | 272.6 ms | 304.6 ms | 304.6 ms | 248.3 ms |
| Candidate construction | 0.073 ms | 0.210 ms | 0.159 ms | 0.068 ms |
| GoalVerifier | 0.021 ms | 0.034 ms | 0.034 ms | 0.020 ms |

The task took 15.647 s total (3.91 s/action), with 2392 MiB peak process RSS and a
5.178 s lazy cold model load. A separate three-run direct Google search series took
median 2140 ms/p90 2239 ms/warm median 2068 ms end to end; deterministic parsing
median was 0.025 ms and direct CUA execution median 1257 ms. Both direct and AX runs
made zero Gemini calls.

No screenshot cache, post-action state reuse change, or action-delivery change was
needed: the loop already feeds one fresh post-action observation to verification and
the next decision, and AX-sufficient observations never invoke OCR. A 5.18 s model
load and 2.39 GiB peak RSS argue against unconditional background preload, which would
also load Laya for otherwise direct-only users. The helper already reuses one loaded
model, and loading runs off the SwiftUI main thread. Local warm STT results remain as
previously measured in Phase 20; this phase made no STT runtime change. Current CUA
exposes no normalized DOM action route on this browser, so route instrumentation exists
without a live DOM latency sample. Safari's local fixture navigation failed closed;
the live form and search checks used Chrome.

## Phase 31 — Gemini live fallback gate

Kio's Keychain service/account lookup returned no item for service `Kio`, account
`gemini`; the stored value was never read into output. The phase explicitly requires
contract-only validation when no credential exists, so no live generated-text,
high-level guidance or visual-guidance request was attempted. Existing `test_system2.py`
and `test_vision.py` cover schemas, supplied-region validation, injection, timeout,
rate-limit, missing credential, disabled vision and bounded response behavior. The
last full local check passed 253 Python tests, 22 Swift tests, Ruff lint/format and
Swift build. Recent real CUA tasks made zero Gemini calls. This is a truthful
unavailable-live-provider result, not a successful live integration.

## Phase 32 — real-world compatibility matrix

Created `docs/compatibility.md` to distinguish installed apps, actually tested routes,
completed tasks, and host-specific limitations. Safari and Chrome are installed and
have both completed harmless local AX form tasks with independent verification. The
current CUA setup exposes no usable normalized DOM action route. Firefox, Arc, Brave
and Edge were not installed, so they were not tested.

In a Phase 32 real CUA run, direct launch plus running-app verification completed for
Finder, Notes, Calendar, Reminders, Preview, System Settings and Google Chrome; a
separate Calculator run also passed. Read-only AX observations returned 146 Calculator,
246 Finder, 71 Notes, 190 Calendar, 126 Reminders, 102 Preview, 119 System Settings and
9 Safari controls. The report stores no element labels or user content. Discord (117
controls) and VS Code were already inspected read-only in prior live phases; neither
was modified. Notion and Spotify are installed but were not exercised.

Fixture coverage includes the local Chrome/Safari form tasks, 12-step local workflow,
poor-AX OCR/capture-bound test and cross-surface browser/native confirmation. The
Phase 32 attempt to create and verify a note did not yield a trustworthy completion
result and is not counted as a success. Finder create/rename, Notion/Spotify tasks,
security-setting changes, and camera use were not attempted. This matrix records tested
compatibility, not a universal-app guarantee.

## Phase 33 — dogfood and Laya analysis

Added `fixtures/browser/scroll.html` and an opt-in `--trajectory-root` option to the
live smoke loop. Seven local Chrome fixture tasks completed with CUA Driver 0.30.2 and
independent verification: form typing/selection, 12 sequential actions, native
confirmation, single field entry, selection-only, Start/Continue, and page scrolling.
The sanitized trajectories contain 24 executed action decisions and no screenshots,
audio, CUA payloads or native tokens. Seven additional failure/safety traces were kept
for analysis and excluded from the training export.

Re-reviewed action labels were exported without editing the original trace. Seed 418
split whole runs into train 6 rows/2 tasks, validation 13 rows/2 tasks, and test 5
rows/3 tasks. Generic Laya offline replay matched all 24 recorded decisions with zero
CUA actions; this is replay consistency, not held-out accuracy. The separate frozen
test remains 10/14. With only six training rows and one browser fixture family, no
fine-tuning or calibration was justified, and no improvement is claimed.

Error review found the final financial fixture action BLOCKed with zero actions,
duplicate Details targets rejected as ambiguous, and an uncertain visual goal stopped
at the confidence gate. A shorter visual task executed one capture-bound click but
then chose premature DONE; GoalVerifier rejected completion. Scroll tests exposed the
missing token-authorized route and OCR fallback interaction. Kio now treats a visible
token-bearing AX scroll surface as structured capability and avoids OCR on those
explicit scroll goals; a fresh-token page-scroll task passed in one CUA action. Nested
scrolling remains unsupported. `docs/phase33-dogfood.md` contains exact commands,
task split groups and error classifications.

`scripts/check.sh` passed after source changes: Ruff lint/format, 257 Python tests,
Swift build and 22 Swift tests. Generic Laya remains the default.

## Phase 34 — bundle audit and final unsigned artifact

Audited the existing Kio.app payload before trimming. PyTorch was the dominant
component; `libtorch_cpu.dylib` remains required for local Laya inference. Kio now
omits PyTorch C++ headers and `protoc`, CPython development headers, `ensurepip`, IDLE,
Tkinter/Tcl/Tk, `lib2to3`, and pydoc topic data. All inference libraries, runtime
distributions, package metadata and licences remain; model weights are still managed
by revision and SHA-256 under Application Support. No runtime alternative was
introduced.

The final `dist/Kio.app` totals 649.97 MiB of regular-file payload, down from 703.55
MiB (53.58 MiB, or 7.6%). `scripts/check-all.sh` passed with Ruff, 258 Python tests,
Swift build and 22 Swift tests, clean relocated-artifact import/NDJSON checks, 46
Mach-O dependency-path audits, the one-step fine-tuning smoke, and privacy scan. The
packaged generic Laya matched the development runtime on the 14-case frozen test
outcomes (10/14 overall and 7/7 target decisions); warm median inference was 117 ms
versus 111 ms. This verifies packaging parity, not model improvement. Laya's existing
11+ choice calibration warning remains. Real CUA Driver 0.30.2 health was `ok` with
Accessibility and Screen Recording granted; no desktop action was run in this phase.
See [bundle-size.md](bundle-size.md) for the breakdown and [packaging.md](packaging.md)
for the build/run path.

## Phase 36 — setup implemented; ready-state gate remains open

The setup window now opens automatically on a first run and presents a concise Kio
checklist, exact macOS privacy routes, optional microphone/voice/global shortcut, and
model readiness. Setup progress uses a versioned schema; the old completion preference
is migrated and saved into it. Model installs stream progress to the UI. A later loss of
mandatory Accessibility or Screen & System Audio Recording access opens a repair-only
view. A Screen Recording grant made while Kio is running displays a restart requirement
and blocks Continue until Kio restarts.

Verification: `scripts/check.sh` passed 265 Python and 26 Swift tests, Ruff lint and
format, and Swift build. Focused model/setup tests passed 6/6; setup-state tests passed
within the 5/5 focused Swift Foundation suite. The rebuilt `Kio-P36.app` passed
`scripts/check-artifact.py` (Python 3.12.8 / torch 2.14.0, 47 Mach-O files, unchanged
vendor-signed CUA Driver 0.30.2). A real app first launch showed “Welcome to Kio”; the
Accessibility and screen buttons opened the correct System Settings panes. Local voice
model load passed using generated silence, and the packaged local Laya smoke selected a
validated candidate on MPS in 727.09 ms.

The new app copy did not have Accessibility or Screen & System Audio Recording grants.
The real setup status remained `needs_setup` with `driver_unavailable`; Kio did not claim
readiness or perform desktop actions. Permission grants and the resulting restart/recheck
were not performed on the user's behalf. This is the remaining Phase 36 acceptance gate;
Phase 37 has not started. No microphone or input-monitoring grant was made, and neither
is required for typed use.

### Phase 36 permission/runtime follow-up

After the user reported an inactive global shortcut and a local voice runtime message,
the live host was inspected. `Kio-P36.app`, `dist/Kio.app`, and
`apps/macos/.build/Kio.app` are separate ad-hoc signed artifacts. The active P36 app
reported Accessibility and Screen Recording as Needed even after a fresh setup check
and restart; the visible Kio permission switches alone do not establish that the
current code identity is authorized. Input Monitoring was also visibly enabled for a
Kio entry, but the current process's actual grant could not be confirmed, so no
shortcut success is claimed.

The packaged P36 self-test reported **“Local voice check passed”** using the installed
77,704,715-byte `tiny.en` model (SHA-256
`921e4cf8686fdd993dcd081a5da5b6c365bfde1162e72b08d75ac75289920b1f`) and its bundled
`whisper-cli`; it generated silence locally and did not access the microphone. The
development app previously depended on the launching shell to supply runtime paths.
It now resolves the local cache paths itself, presents a Kio-facing setup message if
voice is unavailable, and ignores environment overrides for packaged Whisper. The
global shortcut refreshes Input Monitoring when Kio becomes active. Added resolver
regression tests. `scripts/check.sh` passed **265 Python tests**, Ruff lint/format,
Swift build, and **29 Swift tests**. `scripts/run-macos.sh` built and launched the
development app at `~/Library/Caches/Kio/development/Kio.app`; its ad-hoc signature
verified with identifier `local.companion.dev`. The local Whisper self-test returned
`voice_test=ready` in an isolated Python environment. The current build still needs
authorization for its exact ad-hoc identity before the live shortcut and mandatory
TCC setup gates can be considered passed. No mic recording or keyboard shortcut
trigger was performed during this troubleshooting run.

The follow-up also moved startup to an application lifecycle coordinator rather than a
menu-bar label task. Setup version 2 requires Input Monitoring for normal mode and
reopens older completed setups once. The modifier event tap now recovers from both
macOS-disabled tap events and reports runtime health. `scripts/run-macos.sh` and
`scripts/build-unsigned-app.sh` accept `KIO_CODESIGN_IDENTITY`; their default ad-hoc
signature carries an explicit `local.companion.dev` designated requirement. The
development app was rebuilt and strict codesign verification reported that requirement.
No physical shortcut trigger or TCC grant is claimed until the exact running build is
authorized in System Settings.

## Phase 35 — embedded CUA host

Kio.app now bundles the exact CUA Driver 0.30.2 universal executable and MIT notice.
The Swift app host directly owns `serve --embedded`; the existing Python Driver adapter
connects through the documented MCP socket proxy. The packaged mode does not fall back
to `/Applications/CuaDriver.app`. Source-development mode may still use the standalone
Driver. The Kio bundle identifier `local.companion.dev` is preserved and owns TCC
responsibility; the nested CUA binary's vendor signature and exact release hash are
preserved.

Focused regressions passed: 21 Python Driver/setup tests, Ruff check/format, and 3
Swift foundation tests. The cache artifact passed `scripts/check-artifact.py`, including
isolated Python 3.12.8 / torch 2.14.0 imports and all 47 Mach-O load-path audits. Live,
with the standalone CuaDriver process stopped, packaged Kio's direct child returned
CUA 0.30.2 health `ok`; identity source was `parent_application`, parent PID matched
Kio, and `check_permissions` attributed Accessibility and Screen & System Audio
Recording to host bundle `local.companion.dev`. A real Calculator observation returned
146 AX controls, and a 460×816 capture had a native CUA capture ID. The PNG was kept in
memory only. Graceful Kio termination stopped the daemon and removed its socket.

Live TCC checks used Apple Silicon/macOS 27 and this user's grants. Ad-hoc host
rebuilds may need those grants again. This phase did not separately benchmark latency.
The polished, versioned setup/repair state machine is Phase 36; development builds
still have the explicit external CUA fallback.

## Phase 36 CUA Perception migration

`cua-perception` 0.2.1 is installed through the publisher-verified CUA extension
catalog in the user's CUA extension store. It is not bundled in Kio.app. The
catalog discloses AGPL-3.0-only OmniParser/Ultralytics components, Apache-2.0
PP-OCR and MIT ONNX Runtime glue; the exact notices are in
`THIRD_PARTY_NOTICES.md`. Kio production routing now uses CUA's
`parse_visual_regions` only after a fresh screenshot capture and validates the
native capture id, target, dimensions and SHA-256 before normalizing regions.

The live poor-AX visual fixture produced text and icon regions through the
canonical embedded daemon. Bundled Kio Laya selected the bounded `Settings`
visual candidate at 0.9813 confidence (9.11 s cold, including model load), and
the capture-bound CUA action advanced the fixture to `Continue`; a fresh capture
id/digest followed. Parser warm time was approximately 3.9 s. No Gemini call and
no Apple Vision/KioOCR process occurred. The old Apple Vision worker, Swift target,
packaging path and OCR tests were removed after this gate.

## Phase 37 natural-language GoalCompiler

The deterministic GoalCompiler accepts generic wake phrases and polite wrappers,
preserves quoted literals, and resolves aliases against the live installed-app
inventory. It compiles compound commands such as “open Calculator and perform one
plus one” into one app prelude and one remaining generic UI goal; no Spotify,
Calculator or phrase-specific macro was added. Ambiguous app matches fail closed.

Focused compiler/direct/runtime tests passed 29 tests with Ruff lint and format.
The live canonical-daemon smoke completed `Hey Kio, open Calculator up for me` as a
direct verified app launch with zero Gemini calls.

## Phase 40–41 voice and pill UX

Voice now performs bounded rolling local Whisper decodes while recording. A stable
clause detector commits only repeated complete app-open/search clauses; early app
preparation is tracked by voice-session generation and final speech is reduced to
the remaining clause, so the early step is not duplicated. Microphone audio remains
temporary and local, with no TTS or cloud STT. Swift detector, voice lifecycle and
overlay focused tests passed.

The notch pill uses a fixed 380×142 point panel and fixed content frame across all
active states. Waveform/transcript content is clipped internally and no longer
changes outer panel geometry. Live acoustic and pixel measurements remain separate
OS smoke checks.

## Phase 38 app/window reuse and foregrounding

`ensure_app_ready` now checks the live app inventory and usable windows before
launching. Existing windows are reused; newly launched apps are polled until a
usable layer-0 window exists, then exact CUA `bring_to_front` activation is
verified with one bounded retry. Explicit-browser URL routing uses the same
preparation path and never requests a new application instance.

Focused direct/runtime tests passed 25 tests. With Calculator already running, the
live natural open command reused its existing PID/window, verified exact foreground
activation through the embedded CUA daemon, and independently completed with zero
Gemini calls.

## Phase 39 semantic action grounding

GoalCompiler now marks generic `PLAY` intent and scopes `play … on App` through an
app prelude. Candidate construction uses deterministic intent hints to rank Play,
Resume, Start, Search, Send and Submit controls while down-ranking unrelated
navigation noise. No global confidence threshold changed and no application-specific
macro or whitelist was introduced. Focused compiler/candidate/direct/runtime tests
passed 52 tests with Ruff lint/format.

## Phase J native file picker and browser recheck

The real Chrome upload fixture opened the macOS `Open` panel through its AX file
control. The native panel exposed a safe AX `Cancel` action, and the smoke closed
it without selecting or transmitting a file. The embedded CUA window-state route
did not resolve the panel as a safe target, so Kio retains the fail-closed/user
handoff behavior for file selection instead of using blind keyboard or pixel
macros.

The current structured browser call returned the official
`browser_consent_required` refusal for the existing profile. No profile or consent
was changed; structured browser control remains opt-in, while AX and the
capture-bound CUA visual route remain available.

## Phase K — official browser preparation and automatic resume

The browser route no longer treats `browser_consent_required` as a permanent
limitation. For an explicit browser goal, Kio reuses the exact existing browser
window, asks CUA for structured state, and automatically calls the documented
`browser_prepare` operation with the `existing_profile` strategy when CUA returns
`next_action=browser_prepare`. CUA-supplied target and tab IDs are retained only
for the fresh structured action/verification pair. If the host needs a one-time
grant, Swift automatically starts the official preparation/restart path and shows
“Preparing one-time browser access to continue.” There is no second Kio approval
button and no profile edit or consent bypass; any user consent remains owned by CUA.

Added bounded Python and Swift tests for an already-authorized route,
consent-to-prepare, automatic resume, refusal/preparation fallback, exact-window
reuse, and duplicate-action prevention. The focused Python run passed 52 tests;
the focused Swift Foundation/protocol run passed 17 tests; Ruff passed.

Live canonical testing reached the real Chrome profile and observed
`browser_consent_required` followed by the official preparation attempt. CUA
returned `browser_route_unavailable` because it could not read that profile's
`DevToolsActivePort` (`Operation not permitted`), so Kio used the existing AX
fallback and completed the harmless navigation. No structured-browser PASS is
claimed: that gate remains open until a real CUA preparation grant produces a
structured browser state and structured action on a profile supported by the
installed CUA release.

The post-change repository gate passed 279 Python tests, Ruff lint/format, Swift
build and 33 Swift tests. The canonical `/Applications/Kio.app` artifact passed
the isolated packaging audit (Python 3.12.8, Torch 2.14.0, 48 Mach-O files and
pinned CUA Driver 0.30.4); its embedded daemon reports `overall=ok` and host
identity `local.companion.dev` in standard permission mode.


## Continuation — canonical install, browser sessions and semantic planning (2026-09-29)

The developer and packaging workflows now use a private staging bundle and atomically
install only `/Applications/Kio.app`; temporary app bundles are removed on exit. The
new bounded local semantic planner now drives natural compound goals, preserves typed
literal parameters, and supports multi-step plans without silently dropping later
steps. Structured browser refs carry the exact CUA session, target, tab and ref from
the normalized observation into a single-use private candidate payload; the model
still sees only Kio candidate IDs. Browser task sessions are started, reused across
fresh snapshots/actions, and closed at task end. The official preparation path is
started automatically for explicit browser goals; Kio does not add a second
“Allow Browser Access” confirmation. A genuine CUA/browser-owned consent boundary is
still respected, and preparation failure falls back to AX.

Gemini's screenshot/visual-guidance path and privacy toggle were removed. Gemini
remains optional text generation/high-level guidance only; visual understanding is
structured browser, AX, then CUA Perception. Meaningfully labeled CUA icon regions
can now become capture-bound visual candidates; unlabeled detector classes remain
non-actionable. CUA visual capture provenance survives AX merges.

Verification: the local regression suite is **279 Python tests** and **33 Swift
tests**, with Ruff lint/format and Swift build passing. The embedded canonical
driver was upgraded and verified as CUA Driver **0.30.4**. The host's existing
Chrome profile still returns `browser_route_unavailable` after the documented
preparation attempt, so no live structured-browser PASS is claimed. The canonical
bundle remains `/Applications/Kio.app`; no alternate project bundle is retained.

## Continuation — warm voice and overlay semantics (2026-09-29)

The normal packaged voice path now uses the official local `whisper-stream` sample
with one persistent process and a rolling 500 ms window. It keeps the model warm,
feeds repeated complete hypotheses through a bounded semantic step parser, and
commits only stable `ENSURE_APP` or web-search preparation steps. Punctuation and
wake-word changes share a semantic step ID, so final transcript reconciliation does
not repeat an early app preparation. The legacy AVAudioRecorder/whisper-cli path
remains only as a development fallback when the streaming helper or model is absent.

`whisper-stream`, SDL2-compat, and the required SDL3 runtime are bundled with the
canonical app when available. Their install IDs and rpaths are rewritten to private
bundle-relative values, and the Kio-owned Whisper/SDL stack is re-signed after those
Mach-O edits. The artifact audit found no Homebrew/developer paths. A local non-spoken
start/stop smoke initialized the helper, enumerated a real macOS input device, loaded
the installed model, and emitted `[Start speaking]` without producing a claimed human
transcript. Human speech, physical shortcut input, and live structured Chrome control
remain external gates.

The prior packaged helper could show macOS “Failed loading SDL3 library” and terminate
with a dyld `Code Signature Invalid` error because SDL2-compat dynamically loads SDL3
and the modified nested libraries were not all re-signed. The canonical rebuild now
passes strict verification for Kio, Whisper, SDL2-compat, and SDL3, and the helper
remained alive through a 5-second capture smoke.

The overlay now stays visible while an early voice step completes if the same voice
session is still listening or has pending work. Fixed 380×142 geometry remains in
place. `scripts/check.sh` passes 279 Python tests and 37 Swift tests with full app
build, Ruff lint and format; the canonical artifact was rebuilt and strict-signature
and embedded-CUA checks passed.

The final `scripts/check-all.sh` on this exact tree also passed isolated packaging,
NDJSON startup, 48 Mach-O audits, privacy scanning and the one-step CPU training
smoke (`weights_changed=true`, checkpoint reload/inference working, 38.76 seconds,
3599 MiB peak RSS). No model improvement is claimed.

### Voice runtime correction (2026-09-29)

The packaged Whisper 1.9.4 `whisper-stream` helper does not support the legacy `-nt`
or `-np` flags. Kio had passed them while suppressing stderr, which made the process
exit immediately and surfaced as “No speech detected.” Streaming now uses only the
supported flags, and `[BLANK_AUDIO]` is filtered before it reaches transcript state.
The rebuilt `/Applications/Kio.app` passes strict signatures and the 49-file artifact
audit. `scripts/check.sh` passes 279 Python and 37 Swift tests, including a regression
for the blank-audio marker. A live local `say`-to-microphone smoke produced transcript
hypotheses with no unsupported-argument error; this is not a human-spoken or physical
shortcut claim.

## Continuation — read-only UI answers, structured semantics and SDL check (2026-09-29)

The request layer now distinguishes `ANSWER_ONLY`, `OBSERVE_AND_ANSWER`, and `ACT`.
Read-only UI questions use a descriptive `UIInspector` snapshot with spatial and nearby
control summaries; that path creates no candidate table and does not open or foreground
the requested app. The helper returns a bounded typed `answer` message under NDJSON v1.
For actions, `SemanticTaskPlan` steps retain operation, object type, exact literals,
desired state, parameters and constraints as the sequential executor reobserves and
verifies each step. The Swift production surface uses a compact non-activating orb and
answer card; the larger execution form is behind Diagnostics.

Verification: `scripts/check.sh` passed **304 Python tests**, Ruff check/format, Swift
build and **38 Swift tests**. `scripts/check-all.sh` also passed isolated artifact/NDJSON
checks, 49 Mach-O audits, privacy audit and a one-step CPU training smoke. The smoke
changed weights, reloaded the checkpoint and ran inference in **35.80 s** at **3428 MiB
peak RSS**; this confirms the pipeline runs and is not evidence of a better model.

Live Discord through the embedded canonical CUA Driver **0.30.4**: “Where is the mute
button in Discord?” returned a bottom-left location near Input Options and Gyo, with zero
actions. “Am I muted?” read the unchecked state as unmuted. The explicit action “Mute me
in Discord” selected the supplied local candidate, executed one CUA click and passed
independent `checked=true` verification. A fresh read-only query then returned “Mute is
muted.” No Discord-specific behavior was added.

Live Outlook was attempted because Outlook is installed. Its unique inbox window was on
another Space. CUA's exact-window foreground call reported a verified transition, but
the next window snapshots still marked the content window off-space; Kio abstained
before opening a draft or entering fields. No email was sent. The live Outlook
acceptance case remains unverified because Kio did not receive stable visible state.

For the reported SDL3 alert, `/Applications/Kio.app` was rebuilt at 04:02 with bundle ID
`local.companion.dev`. Strict codesign and the isolated artifact audit passed (Python
3.12.8, Torch 2.14.0, CUA 0.30.4, 49 Mach-O files). The bundled
`whisper-stream --help` exited successfully, and a no-audio `SDL_Init(0)` call through
the app's copied SDL2-compat library successfully loaded SDL3. Kio was relaunched from
that exact bundle and its embedded CUA health was `ok`. This does not exercise actual
in-app microphone capture; the SDL alert therefore remains unconfirmed fixed until that
live microphone path is retried. Human speech, physical Option+Command and a screenshot
of the orb/answer card were not tested in this continuation. The upstream Laya
invalid-temperature warning for `choice:11+` remains; affected confidence is
uncalibrated.

## Current continuation — animated blob and semantic planner correction (2026-09-29)

The former circular orb is now a flat 2D organic blob built from a sampled SwiftUI
vector path. It gently morphs while idle, reacts to microphone level with a three-bar
listening mark, uses quiet animated dots while Kio works, and shows check/attention
marks for results. It keeps the existing 48-point non-activating placement and expands
only for messages or answer cards. Low-volume macOS `Tink`, `Pop`, and `Purr` effects
mark listening, completion/answer, and attention; **Subtle interface sounds** in Settings
can turn them off. They are UI effects, not speech; no TTS or sound dependency was added.

The semantic planner now deterministically maps a clear request to stop the microphone
from transmitting audio to `SET_STATE/MUTED`. A negated version does not produce a mute
action. This is a planner-only result, not a microphone action. Less explicit state
requests continue through the bounded Laya enum interface and confidence gate.

`scripts/check.sh` passed **309 Python tests**, Ruff lint/format, Swift build, and **38
Swift tests**. `scripts/check-all.sh` repeated those checks, then passed isolated artifact
imports/NDJSON, the **49 Mach-O** load-path audit and privacy audit. Its one-step CPU
training smoke changed weights, saved/reloaded the checkpoint, and ran inference in
**37.10 s** at **3552 MiB peak RSS**. This smoke does not establish model improvement.

The canonical `/Applications/Kio.app` was rebuilt at **2026-09-29 05:11 BST** with
bundle ID `local.companion.dev`. Strict app and embedded CUA signature checks passed;
the CUA Driver **0.30.4** hash matches the pin. The artifact audit found Python **3.12.8**,
Torch **2.14.0**, 49 Mach-O files, and no developer library paths. A real local Laya
probe resolved the file rearrangement to `MOVE`/`FILE` at **0.632** confidence; the clear
microphone suppression phrase took the deterministic path in **about 22 ms**. Upstream
Laya still warns that confidence for `choice:11+` is uncalibrated.

Kio launched from the canonical bundle. The CUA app binding timed out (`-10005`) on its
menu-bar-only surface, so the overlay was not screenshot-verified and no audible playback
smoke was run; the three macOS named sound resources did resolve. Human speech, physical
Option+Command, and a live CUA microphone action were not tested or claimed here.

## Current continuation — targetless execution and safe live checks (2026-09-29)

The runtime resolves apps from the installed-app inventory, explicit language,
frontmost/session context, and just-opened task context. Semantic plans remain
authoritative through direct and UI substeps, exact PID/window identity is preserved,
and stale UI state gets one bounded same-app rediscovery for safe operations. CUA
transport lifetime, independent outcome evidence, browser metadata resolution, rolling
Whisper output assembly, safe early voice clauses, and bounded silence handling have
regressions. One uniquely labeled AX shutter can satisfy an explicit photo-capture step;
ambiguous shutters retain normal confidence handling, and an unverified capture is not
repeated.

Verification: `scripts/check.sh` passed **343 Python tests**, Ruff lint/format, Swift
build, and **46 Swift tests**. The final `scripts/check-all.sh` repeated those gates,
passed isolated imports/NDJSON, **49 Mach-O** audits, and the privacy scan. The one-step
CPU training smoke changed weights, reloaded the checkpoint and ran inference in
**38.48 seconds** at **3501 MiB peak RSS**; it is a pipeline smoke, not model-improvement
evidence. The canonical `/Applications/Kio.app` passed strict/deep signature and
isolated artifact checks (Python 3.12.8, Torch 2.14.0, CUA 0.30.4). Exactly one app
with bundle ID `local.companion.dev` was found. The relaunched embedded CUA health was
`ok`.

Live targetless checks: Spotify opening completed and the app was restored to the
foreground. Its AX tree exposed no play/pause transport controls, and a read-only state
query could not identify playback, so its existing state was left untouched. Discord's
read-only mute-button question completed with zero actions. The Norbert Wiener search
and `x.com` navigation completed through the targetless browser path. Opening Notes
succeeded after generic Launch Services activation moved its existing window to the
current Space; creating a note stopped because no grounded creation control was
available. Outlook exposed no usable current-Space content window, so no draft was
created or sent. Photo Booth opened, but capture did not produce independently verified
state or a new still; its existing movie was preserved.

The Chrome History page showed the two acceptance visits at 08:19 on 2026-09-29. The
History database was locked while Chrome was running, and the exact-row CUA selection
attempt failed without selecting either checkbox, so those two rows remain. No test
note, email, or still photo was left behind. A physical Option+Command shortcut and a
human-spoken transcription were not exercised. The upstream Laya `choice:11+`
temperature warning remains; confidence for that choice is uncalibrated.
