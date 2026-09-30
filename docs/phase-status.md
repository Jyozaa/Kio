# Phase status

Entries below preserve the chronological audit trail. Where an earlier entry names
Apple Vision/OCR, Gemini Vision, a cached Kio.app, or CUA 0.30.2, the current
continuation entries supersede that implementation and its artifact evidence.

Current status: phases 1–10 and 11.0–42 have passing local implementation gates.
The latest 2026-09-29 shortcut/runtime continuation also passes `scripts/check-all.sh`
and rebuilds the canonical `/Applications/Kio.app`. External live gates remain open
where they require a physical shortcut, human speech, usable live controls, or a live
third-party account. The app's blob itself was not visually inspected because CUA
timed out while binding to Kio's menu-bar-only surface. Phase 35 is complete; phase 21
has its own historical verification below.
External exceptions: human-spoken microphone E2E was not run (Phase 28 used a controlled
local acoustic stimulus); no live Gemini key/model; no supported normalized DOM route on
the tested browser. The Phase 36 test app has not been granted Accessibility or Screen &
System Audio Recording, so its setup self-test correctly remains in needs-setup. Phase 16
follows the user's revised autonomous ALLOW/BLOCK requirement. Historical failed
attempts are preserved below; later gate results supersede them.

## Phase 1 — PASS (2026-09-26)
- Scope: inspected empty workspace and all five upstream references; documented
  architecture, ownership, licences, safety and supported standalone CUA launch.
- Files: README.md, THIRD_PARTY_NOTICES.md, .gitignore, docs/architecture.md,
  agent/{pyproject.toml,.python-version,uv.lock,src,tests}, apps/macos/Package.swift,
  Swift foundation sources/tests.
- Commands: `uv sync --project agent`; `uv sync --project agent --locked`;
  `uv run --project agent ruff check agent`;
  `uv run --project agent ruff format --check agent`;
  `uv run --project agent pytest`;
  `swift build --package-path apps/macos`; `swift test --package-path apps/macos`.
- Results: locked sync PASS; lint/format PASS; Python 1 passed; Swift build PASS;
  XCTest 1 passed. Swift 6.3.3, Python 3.12.8, pytest 8.4.2, Ruff 0.16.9.
- Limitations: foundation UI only; no agent integrations yet. Installed CUA 0.23.2
  identified; doctor reports binary healthy but this is not an observation smoke.

## Phase 2 — PASS (see gate evidence below)
Historical gate results below are retained; later PASS entries supersede initial blocks.

### Phase 2 gate — PASS (2026-09-27)
- Scope: native SwiftUI input, task states, Stop/Reset, floating status panel;
  versioned bounded NDJSON, demo subprocess, malformed-input recovery/cancellation.
- Files: agent/src/companion_agent/{protocol.py,__main__.py}, test_protocol.py,
  Swift Protocol.swift, Companion.swift, ProtocolTests.swift, Info.plist,
  scripts/run-macos.sh, docs/protocol.md.
- Commands: `uv run --project agent --no-editable ruff check agent`;
  `uv run --project agent --no-editable ruff format --check agent`;
  `uv run --project agent --no-editable pytest`;
  `swift build --package-path apps/macos`; `swift test --package-path apps/macos`.
- Results: Python 16 passed; Swift 5 passed; build/lint/format PASS.
- Visual smoke through cua_repl: typed Demo smoke, clicked Run, observed
  working/Looking at the page then completed/Done; next run clicked Stop while
  working and observed idle/Stopped. Completion screenshot inspected in memory.
- Fixed live-launch import failure by using `uv sync --locked --no-editable`;
  standalone helper uses installed wheel, not an editable-path link.
- Limitations: inert demo only; no real agent action wired until phase 9.

## Phase 3 — PASS (initial permission block resolved; see later gate)

### Initial phase 3 attempt — BLOCKED (subsequently resolved) (2026-09-27)
- Scope implemented: persistent official CUA MCP adapter; read-only health, app/
  window discovery, native structured-state normalization, browser inspection;
  FakeDriver and project-owned error codes. No autonomous execution added.
- Files: agent/src/companion_agent/driver.py, agent/tests/test_driver.py,
  agent/pyproject.toml, agent/uv.lock, docs/part1-results.md.
- Commands: `cua-driver doctor --json` PASS binary/install probes;
  `open -n -g -a CuaDriver --args serve` launched supported standalone app;
  `cua-driver call health_report '{}'` FAILED permissions_pending;
  `cua-driver call check_permissions '{"prompt":false}'` FAILED
  permissions_pending (exit 75); `cua-driver permissions status --json` UNKNOWN.
  `uv run --project agent --no-editable python -m companion_agent.driver`
  FAILED driver_unavailable during MCP initialization (exit 1).
- Local tests: `uv sync --project agent --locked --no-editable --reinstall-package companion-agent`;
  `uv run --project agent --no-editable ruff check agent` PASS;
  `uv run --project agent --no-editable ruff format --check agent` PASS;
  `uv run --project agent --no-editable pytest` 28 PASS;
  `swift build --package-path apps/macos` PASS;
  `swift test --package-path apps/macos` 5 PASS.
- Limitation: real CUA observation unverified; native/browser adapter response
  normalization is contract-tested only. Missing OS grants cannot be replaced by
  a mock or the Codex computer-use tool's separate permission identity.
- Required next step: grant Accessibility and Screen Recording to CuaDriver.app
  through its official permission onboarding, then repeat real smoke/observation.
- At this initial blocked attempt, phases 4–10 had not started. Subsequent gates follow.

### Phase 3 gate — PASS after permission grant (2026-09-27)
- Real commands: `cua-driver permissions status --json` grants true;
  `cua-driver call health_report '{}'` overall ok;
  `cua-driver call launch_app '{"bundle_id":"com.apple.calculator"}'` opened Calculator;
  `cua-driver call list_windows '{"pid":39591}'` resolved window 22175;
  `uv run --project agent --no-editable python -m companion_agent.driver --pid 39591 --window-id 22175`
  PASS health ok and 145 normalized native controls (AXButton, AXMenuItem etc.).
- Meaningful actual labels inspected from structured state: All Clear, Divide,
  Per cent. No private screenshot/content file was saved.
- Regression: `uv run --project agent --no-editable pytest` 28 passed;
  `uv run --project agent --no-editable ruff check agent` passed.
- Browser state remains dependent on Driver's explicit browser setup; no claim of
  real browser observation yet. Native observation acceptance satisfied.

## Phase 4 — PASS

### Phase 4 gate — PASS (2026-09-27)
- Files: candidates.py and test_candidates.py. Observation/Element/Action/Table/
  ExecutionResult types; private Driver identity, single-use tables, per-table
  opaque IDs; cap 30 per targeted operation (configurable 1–100); deterministic
  relevance/layout ordering; disabled/invisible/blank/duplicate filtering.
- Tests include 1,000-control pages, empty pages, repeated labels at distinct
  positions, foreign/unknown/duplicate/reused IDs, foreign snapshot members and
  fingerprints changing with values. All execution attempts consume their table.
- Commands: `uv sync --project agent --locked --no-editable --reinstall-package companion-agent`;
  `uv run --project agent --no-editable pytest` 40 passed;
  `uv run --project agent --no-editable ruff check agent --fix` PASS after import fix;
  `uv run --project agent --no-editable ruff format --check agent` PASS.
- Limitations: actual execution is phase 7; token validity remains Driver-owned.

## Phase 5 — PASS

### Phase 5 gate — PASS with documented model limits (2026-09-27)
- Files: chooser.py, evaluate.py, test_chooser.py, fixtures/decisions/simple.json;
  laya==0.3.20 and transitive versions pinned in uv.lock; HF model revision
  55cf4c4ebb4ebe31b2550e8bdf3bd21b99753851 (English), MPS backend with CPU fallback.
- Commands: `uv run --project agent --no-editable python -m companion_agent.evaluate --corpus fixtures/decisions/simple.json`
  PASS 8/10 = 80%; initial cold load/download 39.408 s, first inference 2.432 s,
  warm median 0.145 s. Local inference only; zero paid API calls.
- `uv run --project agent --no-editable pytest` 49 passed;
  `uv run --project agent --no-editable ruff check agent --fix` and
  `uv run --project agent --no-editable ruff format agent` passed.
- Model limits: one absent-target scroll case selected Home at 0.296 (must block);
  one already-filled field case selected TYPE_TEXT again at 0.9043 (requires
  progress verification/stall protection). Correct Search/Help choices were below
  0.55 and must not silently execute. Accuracy is not the auto-execution rate.
- Upstream warning: choice heads with 11+ entries have a checkpoint temperature
  clamped to 0.5; those confidence values are uncalibrated. Threshold is a guard,
  not a correctness guarantee. No checkpoint/source monkeypatching applied.

## Phase 6 — PASS

### Phase 6 gate — PASS (2026-09-27)
- Files: direct.py/test_direct.py and fixed Driver launch_app method.
- Exact/normalized installed-app matching, validated http(s) URLs, encoded Google
  searches and stop/cancel parsing. Fixed native /usr/bin/open argv; no shell.
- Commands: `uv run --project agent --no-editable pytest` 60 passed;
  Ruff check/format passed. Inline Python smoke imported parse_direct and
  execute_direct, ran Open Calculator and Search Google for Norbert Wiener through
  CuaDriver.connect; both completed, path direct, gemini_calls 0.
- `cua-driver call list_windows '{"on_screen_only":true}'` independently verified
  Calculator window 22175 and Chrome window 71 titled Norbert Wiener - Google Search.
- Limitation: direct URL completion means OS open succeeded; later page content is
  observed for live smoke, not asserted by direct router as search-result correctness.

## Phase 7 — PASS

### Phase 7 gate — PASS (2026-09-27)
- Files: loop.py, policy.py, smoke_loop.py, test_loop.py; Driver fixed action
  methods; browser AX scoping in candidates.py; fixtures/browser/smoke.html.
- Core loop: fresh observation before decision AND immediately before action;
  changed state rejects the decision; exactly identical state may rebind the
  validated local choice to a new table/token. Both tables are discarded.
- Tests: `uv run --project agent --no-editable pytest` 73 passed; Ruff passed.
  Includes deterministic multi-step loop, stale change before execution, cancelled
  inference, repeated no-op, unknown completion and seven consequential labels.
- Real command: `uv run --project agent --no-editable python -m companion_agent.smoke_loop --pid 49195 --window-id 22189 --goal 'Click Start, then click Continue to reach Success'`
  PASS completed, steps=2, path=laya_loop, gemini_calls=0; fresh Safari AX observed
  Success after two actual CUA token clicks selected by real local Laya.
- Fixture served with `agent/.venv/bin/python -m http.server 8765 --bind 127.0.0.1 --directory fixtures/browser`.
- Browser limitation: installed CUA refused isolated Chrome launch with
  browser_route_unavailable (vendor signature attestation); supported native Safari
  AX worked. No permission bypass or legacy page mutation was used.
- General completion without a deterministic verifier returns needs_user rather
  than trusting DONE. Scroll without a grounded container fails closed. Phase 10 added grounded scroll tokens.

## Phase 8 — PASS

### Phase 8 gate — PASS (2026-09-27)
- Files: system2.py/test_system2.py; loop.py recovery and generation integration.
- Official Gemini REST generateContent/structured-output docs inspected on this date.
  Model name configured via GEMINI_MODEL, key via GEMINI_API_KEY. Neither required
  for local operation. No key was configured; live Gemini smoke not applicable.
- Commands: Ruff check/format PASS; `uv run --project agent --no-editable pytest`
  86 passed. Literal text: 0 calls; generated text: 1; repeated low confidence:
  exactly 1 guidance call and 2 local decisions with fresh observations.
- Tests cover schema extras/executable guidance rejection, timeout, 429, other HTTP
  errors, 32 KiB response cap, malformed/no-key execution blocked and secret-free errors.
- Guidance receives only goal + at most 10 short labels; generation receives only
  requested writing task + selected field description. No screenshots or tool schemas.
- Recovery bounded once per task (stricter than once per blocked state); no retries
  on rate limits. Generated content never becomes code/selector/coordinates.

## Phase 9 — PASS

### Phase 9 gate — PASS (2026-09-27)
- Files: runtime.py/test_runtime.py, __main__.py, protocol.py, Swift protocol/UI.
  Real runtime is default; explicit --demo remains available. User names target app;
  ambiguous/multiple visible windows fail safely. Laya loads lazily and is reused.
- Python 88 passed, Ruff passed, Swift build + 5 XCTest tests passed. A Swift test
  initially expected cancellation after terminal confirmation; updated lifecycle
  test now verifies confirmation clears authority and cancellation on a new task.
- Real native UI smoke: Open Calculator → completed/Done; Buy now → visible
  waitingForConfirmation panel (no action); Click Start → Stop → idle/Stopped.
  Completion and cancelled screenshots inspected in memory, not persisted.
- Stop stays available during work. Reset is disabled until task terminal. Provider
  errors contain no raw private content. Confirmation offers dismiss/manual action,
  never an approve-and-execute route. No TTS/audio code.

## Phase 10 — PASS

### Phase 10 gate — PASS (2026-09-27)
- Added full local fixture, compound-goal focusing, grounded scrolling, native
  dropdown dispatch, off-window filtering, success preconditions, reusable check
  script and explicit-target live fault-injection harness. Updated launcher to
  atomically replace its executable rather than overwrite a running binary.
- Native Safari dropdown investigation: background AXPress/AXPick and set_value
  did not change the selected value (set_value timed out). Documented CUA
  foreground AXPick on the freshly observed menu-item token worked; new snapshot
  independently confirmed Option B. Production dispatch now uses this locally
  fixed guarded action. No arbitrary model tools or pixel coordinates added.
- Final `scripts/check.sh` PASS. It executes:
  `uv sync --project agent --locked --no-editable --reinstall-package companion-agent`;
  `uv run --project agent --no-editable ruff check agent`;
  `uv run --project agent --no-editable ruff format --check agent`;
  `uv run --project agent --no-editable pytest` → **95 passed in 3.96 s**;
  `swift build --package-path apps/macos` PASS;
  `swift test --package-path apps/macos` → **5 passed, zero failures**.
  Earlier final-pass attempts caught a late-bound test-harness closure (fixed by
  binding defaults) and a test fixture with a button-sized window frame (corrected
  to a realistic window; dedicated off-window rejection test remains).
- Clean-process real CUA smoke:
  `agent/.venv/bin/python -m companion_agent.driver --pid 49195 --window-id 22189`
  PASS, health ok, Driver 0.23.2, native Safari snapshot 303 controls.
- Clean-process real Laya smoke:
  `agent/.venv/bin/python -m companion_agent.evaluate --corpus fixtures/decisions/simple.json`
  PASS 9/10 (90%), MPS, cached cold load 5.171661 s, first decision 0.665793 s,
  warm median 0.102230 s. Scroll case chose an incorrect button at 0.296 confidence,
  below the execution floor. Checkpoint calibration warning remains documented.
- Real full browser task, fresh page:
  `open -a Safari 'http://127.0.0.1:8765/index.html?acceptance=final1'`
  then `agent/.venv/bin/python -m companion_agent.smoke_loop --pid 49195 --window-id 22189 --goal 'Enter "hello world" in Message field, choose Option B, then click Reach success'`
  PASS completed, four actions, gemini_calls=0. Observed field value, Option B and
  Success are all required by the verifier.
- Real generated-text input with mocked System 2:
  `open -a Safari 'http://127.0.0.1:8765/index.html?acceptance=greeting1'`
  then `agent/.venv/bin/python -m companion_agent.smoke_loop --pid 49195 --window-id 22189 --goal 'Write a short friendly greeting in the Message field' --mock-system2`
  PASS completed, one action, one mocked generation. Separate fresh CUA observation
  asserted exact `Message preview: Hello! I hope you're having a lovely day.` from
  the fixture input handler. No live Gemini key configured, so live Gemini not run.
- `agent/.venv/bin/python -m companion_agent.live_checks --pid 49195 --window-id 22189`
  PASS 4 checks: consequential→confirmation_required; stale_observation→needs_user
  after rejecting the first decision and observing again; low_confidence→needs_user
  after one mocked hint; stop→cancelled during choice. Every check executed zero
  desktop actions; purchase handler independently remained unrun. This harness
  uses real CUA observations, mock decisions and an explicitly injected observation
  change, not a real page race. Unit integration tests separately exercise stalls.
- Existing phase 6 and phase 9 live direct/UI evidence remains valid. Literal/direct
  demos used zero Gemini calls. No secrets stored, no Git commit created (workspace
  was not a Git repository), no paid Jev/TypeSafe API, TTS, perception, signing or
  notarisation added. Remaining limitations are in part1-results.md.
- Final-code repeat after the visibility filter and full regression:
  `open -a Safari 'http://127.0.0.1:8765/index.html?acceptance=final2'`, followed by
  the same full-task smoke command above: PASS completed, four actions, zero
  Gemini calls. No production source changes followed this successful run.

# Part 2 — Kio

## Baseline before Phase 11.0 — PASS (2026-09-27)
- Read README, architecture, protocol, phase status, Part 1 results, pyproject and
  parsed the complete uv.lock. No AGENTS.md found. Existing architecture preserved.
- `scripts/check.sh`: 95 Python tests in 4.11 s, 5 Swift tests, lint/format/build PASS.

## Phase 11.0 — PASS
- Kio display/window/menu/product/executable/artifact naming, preserving internal
  identifiers and `local.companion.dev` bundle identity. NDJSON files unchanged.
- Application support root established; legacy state copied without source deletion,
  existing Kio state preferred. Actual host had no prototype support directory.
- Files: Swift package/plist/UI, run-macos.sh, storage.py/test_storage.py, helper
  startup, README, architecture/protocol/Part 2 results.
- `scripts/check.sh`: 98 Python tests in 4.08 s, 5 Swift tests, lint/format/build PASS.
- `agent/.venv/bin/python -m companion_agent.driver --pid 49195 --window-id 22189`:
  real CUA health ok, 285 Safari controls.
- `agent/.venv/bin/python -m companion_agent.evaluate --corpus fixtures/decisions/simple.json`:
  real Laya 9/10, cached load 5.694 s, warm median 103 ms, MPS; calibration warning unchanged.
- `scripts/run-macos.sh`: Kio.app launched. Native UI window/menu/product all Kio.
- Reviewed `rg -n 'Local Companion|LocalCompanion' README.md docs scripts apps agent/src agent/tests`
  excluding build/cache: remaining names only legacy migration constants/tests/docs.
- Keychain service reserved as Kio. No new grants requested; CUA owns its existing TCC.
- Live native UI: Open Calculator completed; Stop during local model loading returned
  idle/Stopped. Actual persistent helper/NDJSON path verified after rename.
- Phase 11.0 gate PASS. No protocol changes, no data deleted; 98 Python / 5 Swift.

## Phase 11 — PASS
- Scope: provider-neutral types, immutable capture/region identity, deterministic
  merge/provenance, configurable fallback, provider timeout/failure boundaries;
  loop now observes through Composite→Structured provider without changing actions.
- Files: perception.py, candidates.py, loop.py, test_perception.py, architecture.
- Inspected actual `cua-driver describe get_window_state` and `describe get_browser_state`:
  AX element_token, parent_index, screen frame and snapshot replacement are supported;
  semantic_v2 browser refs are session-bound, not interchangeable with AX tokens.
  No future DOM/visual execution authority inferred from the presence of a tool.
- `scripts/check.sh`: 116 Python tests / 5 Swift tests, lint/format/build PASS.
  Tests cover AX/DOM contracts, mixed precedence, overlap/provenance, duplicates,
  visual-only state, immutable capture metadata, invalid boxes, timeout/failure,
  fallback suppression/trigger. DOM tests are contracts, not a live DOM claim.
- Inline Python called real CuaDriver → CompositePerceptionProvider → Structured:
  17 normalized Safari AX elements, used_visual=False. Real browser_state probe
  unavailable; AX fallback retained. No screenshots/models added in this phase.
- Real regression: `open -a Safari 'http://127.0.0.1:8765/index.html?phase=11'`
  then `agent/.venv/bin/python -m companion_agent.smoke_loop --pid 49195 --window-id 22189 --goal 'Enter "hello world" in Message field, choose Option B, then click Reach success'`:
  completed four real actions, zero Gemini. Phase 11 gate PASS.

## Phase 12 — PASS
- Scope/files: native KioOCR worker, ocr.py, Driver.capture, Composite capture
  generation handling, loop visual fallback, visual_smoke.py, poor-AX canvas fixture,
  test_ocr.py, launcher/check runtime placement and third-party review.
- Reviewed installed 0.23.2 tool schemas: screenshot frame_valid, image content,
  window bounds/dimensions exist; click has no capture_id input. Current upstream
  capture-bound contract is newer. Pixel authority therefore explicitly unavailable.
- Local dependency repair: AnyIO import stalled in an offloaded Desktop virtualenv.
  `uv sync --project agent --locked --no-editable --reinstall-package anyio` restored
  that import; further Desktop renaming/offloading required a local-cache dev env.
  `UV_PROJECT_ENVIRONMENT="$HOME/Library/Caches/Kio/development-venv" uv sync --project agent --locked --no-editable --link-mode copy`
  installed the same locked packages. Original environment preserved; no user data
  removed. scripts/agent.sh and launch/check scripts use the cache env consistently.
- Accurate Vision OCR produced Settings from a real screenshot but took 43.597 s,
  beyond the configured 15 s deadline. Fast mode was measured and selected for UI
  labels; no invented icon semantics, third-party weights or AGPL components added.
- Original Safari window disappeared; fresh `cua-driver call list_windows '{"pid":49195}'`
  resolved window 23648 after opening the local fixture. Stale window was never used
  for a pixel action. CuaDriver was restarted through stop + app-owned serve.
- `KIO_OCR_EXECUTABLE="$PWD/apps/macos/.build/debug/KioOCR" scripts/agent.sh -m companion_agent.visual_smoke --pid 49195 --window-id 23648`:
  PASS real screenshot → OCR → structured text → bounded Laya choices. Capture
  0.909 s, OCR 0.130 s, merge 0.000297 s, 2 retained regions, 6 non-click candidates,
  Laya 0.484 s, end-to-end including model load/initial observation 15.891 s.
  Zero actions/Gemini. Laya incorrectly selected DONE; this smoke never executes.
  Raw screenshots never enter chooser input. Region-only click eligibility is false.
- `scripts/check.sh`: 125 Python tests passed in 4.29 s; lint/format PASS.
  Tests include short valid labels, noise, duplicate/repeated labels, region cap,
  Retina/crop conversion, grouping, large image limits and unavailable/failed OCR.
- Full live loop on the poor-AX fixture, same OCR environment and target, goal
  `Click Settings`: needs_user (low confidence), zero actions, zero Gemini; no
  unsafe pixel fallback. The visual smoke's incorrect DONE is not completion proof.
- Final Swift build and 5 tests PASS; Phase 12 gate PASS under the permitted safe
  fail-closed execution path. No visual-click success is claimed for Driver 0.23.2.

## Phase 13 — PASS
- Scope/files: verification.py/test_verification.py; loop evidence and independent
  DONE handling; direct.py/driver.py/runtime.py direct outcome checks; deterministic
  explicit-option candidate pruning and its tests; architecture documentation.
- Deterministic checks: named field, option, content marker (not window title alone),
  checkbox/toggle, appeared/disappeared, explicit URL/transition, running app and
  explicitly caller-authorized file. Unknown/ambiguous outcome remains UNKNOWN.
  Evidence is bounded expected/observed data in task result, no screenshot storage.
- `scripts/check.sh`: 139 Python tests in 4.15 s / 5 Swift tests / build/lint/format PASS.
  Tests explicitly reject wrong field/URL/option, missing marker, partial task and
  incorrect DONE; a rejected DONE can reobserve and later complete after a real action.
  Repeated failed DONE is bounded. The old single-DONE mock was extended to supply
  repeated responses for this new reobserve behavior, retaining its no-completion assertion.
- Live first attempt safely stopped at Option B: confidence 0.5397 < unchanged 0.55.
  Candidate construction now retains explicitly named observed menu options; it never
  fabricates one or changes the threshold. The generic select-head test still covers
  multiple options, with a separate exact-label pruning test.
- `open -a Safari 'http://127.0.0.1:8765/index.html?phase=13-retry'`, then
  `KIO_OCR_EXECUTABLE="$PWD/apps/macos/.build/debug/KioOCR" scripts/agent.sh -m companion_agent.smoke_loop --pid 49195 --window-id 23648 --goal 'Enter "hello world" in Message field, choose Option B, then click Reach success'`:
  real completed in 5 actions, zero Gemini; independent evidence matches hello world,
  option b and Success. This run included a transient menu interaction; not reported
  as the earlier four-action result.

- Final gate: `scripts/check.sh`: 140 Python tests (4.11 s), 5 Swift tests,
  build/lint/format PASS. Real injected false DONE on CUA state rejected with zero
  actions. Real direct Calculator and Google search both independently verified,
  zero Gemini. Exact Google /search host aliases are accepted; query/scheme remain exact.
- Live command: `scripts/agent.sh` Python harness using `CuaDriver.connect()` and
  `execute_direct(parse_direct(goal), driver, asyncio.Event())` for both goals.

## Phase 14 — PASS
- Files: system2.py, settings.py, loop.py, test_vision.py, PrivacySettings.swift,
  PrivacyTests.swift, Companion.swift, README/architecture/protocol/results.
- Added inline target-window PNG advisory vision, strict bounded schema and supplied
  region IDs, tool-part rejection, off-by-default persisted privacy UI, fresh local
  decision after guidance. No images persisted; one recovery per task.
- `scripts/check.sh`: 162 Python tests PASS (4.17 s), lint/format/build PASS.
  Two overlapping Swift builds hit modified-input diagnostics; after both exited,
  `swift test --package-path apps/macos` passed all 6 tests. No tests disabled.
- Contract tests cover valid/invalid IDs, coordinates/code/tools, malformed JSON,
  missing key, disabled vision, oversized input/output, timeout, 429, fresh selection.
- Environment presence-only check: GEMINI_API_KEY absent, GEMINI_MODEL absent.
  Live generated-text/guidance/vision NOT RUN, as permitted by Phase 14 gate.
  No live Gemini success or latency claimed. Current CUA pixel limitation remains.

## Phase 15 — PASS (microphone smoke permission-limited)
- Files: VoiceController.swift/VoiceState.swift/VoiceTests.swift, Companion.swift,
  Info.plist, models.py/test_models.py, models/stt.json, scripts/build-stt.sh,
  launcher, README/notices. Native hold/release → local whisper.cpp → editable
  transcript → ordinary goal. Cancel invalidates in-flight results and kills worker;
  recorder released immediately on release/cancel. No cloud STT/TTS.
- Official whisper.cpp v1.9.4 source/license/runtime inspected. Built statically
  with Metal/Accelerate. Runtime version string is 1.9.4-dev. tiny.en MIT weights
  pinned to revision 5359861c739e955e79d9a303bcbc70fb988958b1; SHA and size verified.
- Initial build failed: Xcode 26.6 clang paired with CommandLineTools SDK 27.0.
  Explicit matching Xcode SDK restored build. `scripts/build-stt.sh` records choice.
- `scripts/agent.sh -m companion_agent.models models/stt.json --install`: PASS.
  `scripts/check.sh`: 165 Python / 9 Swift tests, build/lint/format PASS.
- Real whisper-cli on upstream samples/jfk.wav: expected phrase recognized;
  first run 20.450 s, repeat process 0.422 s. Sample inference, NOT microphone E2E.
  Exact flags: `-m <installed tiny.en> -f <upstream samples/jfk.wav> -l en -nt -np`.
- Microphone hardware detected, authorization rawValue 0 (notDetermined). Live
  microphone/spoken-command smoke NOT RUN because recording permission is absent.
  Native UI inspected; typed Open Calculator completed with new voice UI present.
- Limitations: English model, explicit development setup, microphone E2E pending
  permission/user speech; crash-time temporary audio cleanup deferred to hardening.

## Phase 16 — BLOCKED (implementation partial; do not advance)
- Files: policy.py, approval.py, approval_smoke.py, loop/runtime/helper/protocol,
  test_policy.py/test_protocol.py, Swift protocol/state/UI/tests, docs.
- Explicit ALLOW/CONFIRM/BLOCK; role/type/action/task/history inputs, sensitive text
  manual, expiring task/candidate/observation binding; UI Cancel/Allow once.
- `scripts/check.sh`: 184 Python tests (4.27 s), 10 Swift tests, build/lint/format PASS.
  Adversarial coverage: don't buy/find Buy/article delete, real delete account,
  draft vs send, checkout link vs payment, credential fields, stale/duplicate/expired
  approval, cancellation, state mutation after approval.
- Real CUA smoke first failed because prior Safari window disappeared and the local
  fixture server had stopped. Restarted `scripts/agent.sh -m http.server 8765 --bind
  127.0.0.1 --directory fixtures/browser`, enumerated window 24556, reopened fixture.
- `open -a Safari 'http://127.0.0.1:8765/index.html?phase=16-retry'`;
  `PYTHONPATH=agent/src scripts/agent.sh -m companion_agent.approval_smoke --pid 49195 --window-id 24556`:
  PASS: real Safari page changed after approval; two injected chooser decisions,
  zero CUA actions, needs_user. This is real state validation, not live Laya inference.
- Blocking limitation: installed click schema lacks atomic whole-state precondition;
  element_token only rejects a newer snapshot. verify_state is separate and limited
  to up to eight predicates. A post-approval observation invalidates the exact grant;
  rebinding approval to a new table would violate the user's explicit rule.
  Current code hands unchanged approved actions back for manual completion.
  Successful approved CUA execution is NOT claimed. Phase 16 gate remains open;
  Phases 17–20 have not been started. No safety rule or test was relaxed.

## Phase 16 — PASS (autonomous revision supersedes approval requirement)
- User explicitly replaced CONFIRM/single-action approval with ALLOW/BLOCK.
  Removed production broker/approval smoke/UI; legacy wire fields are decode-only,
  inbound approve unsupported. Historical blocked attempt above retained for audit.
- Policy permits ordinary goal-directed steps and explicit send/submit/upload/delete.
  Secrets, final financial commitment, ambiguous equal-label controls and unsafe
  targeting remain blocked. Rechecks policy on fresh state; Stop before inference
  and execution. Model guidance never overrides BLOCK.
- Files: policy/loop/runtime/helper/protocol/objectives/verification/live_checks,
  policy/objective/verifier/loop/protocol tests; Swift protocol/UI/tests; autonomy.html;
  README/architecture/protocol/results. Added deterministic explicit click-sequence
  progress requiring an executed step AND the old control absent/disabled.
- Initial broad-goal live attempt stopped low-confidence with zero actions. No
  threshold change. Explicit ordered goal below passed with real local Laya.
- `scripts/check.sh`: 185 Python (4.15 s), 10 Swift tests, lint/format/build PASS.
  Final `swift test --package-path apps/macos && swift build --package-path apps/macos` PASS.
- `open -a Safari 'http://127.0.0.1:8765/autonomy.html?phase=16-autonomous'`;
  `KIO_OCR_EXECUTABLE="$PWD/apps/macos/.build/debug/KioOCR" scripts/agent.sh -m companion_agent.smoke_loop --pid 49195 --window-id 24556 --goal 'Click Start, then click Continue, then click Send, then click Submit, then reach Success'`:
  PASS four real CUA/Laya actions, automatic Send and Submit, observed Success,
  0 approval prompts/interactions, 0 Gemini. No external message/form service involved.
- Opened index.html?phase=16-safety, then `PYTHONPATH=agent/src scripts/agent.sh -m companion_agent.live_checks --pid 49195 --window-id 24556`: real CUA observations
  with injected chooser/faults passed blocked purchase, stale observation, bounded
  low-confidence guidance (mock), Stop; zero actions in each safety scenario.
- Existing false-DONE, literal text, and all Phases 1–15 safety regressions retained.
  Test count changed because obsolete confirmation cases were replaced, not disabled.

## Phase 17 — PASS
- Files: trajectories.py/tests, chooser bounded probability metadata/shared formatter,
  loop/runtime/smoke recording integration, docs/trajectories.md, sanitized fixture export.
- Recording opt-in; no screenshot/audio/native tokens/payloads. Original file written
  once with mode 0600, separate hash-bound corrections, offline chooser-only replay,
  deterministic task-group splits and candidate-ID normalization. Unknown versions,
  invalid candidates and conflicting corrections fail closed.
- `scripts/check.sh`: 189 Python / 10 Swift tests, lint/format/build PASS.
- Same Phase 16 real CUA/Laya four-action smoke with `--record` on autonomy.html?phase=17-corpus:
  completed four actions, Success verified, zero Gemini. Recorded run
  b47cc3f8f9da4b56a03de75af4b07a19 under Application Support/Kio/trajectories.
- `scripts/agent.sh -m companion_agent.trajectories replay <run.json>`: real Laya
  matched all 4 historical decisions (confidence .9937/.9875/.9869/.9866), zero CUA
  connections/actions. Tests independently prohibit Driver connect/execute in replay.
- Inspected the four recorded candidate labels; added corrections for Start/Continue/
  Send/Submit using `correct()`. Original unchanged. `export()` produced 4 train,
  0 validation, 0 test rows in fixtures/trajectories/autonomy-export. One task is
  intentionally kept together; this is a small corpus, not held-out evaluation.
- Known limits: heuristic PII sanitization is not exhaustive; inspect before sharing.
  Offline sanitized replay can differ from private original input. No debug image mode
  added, so there is no accidental screenshot persistence path.

## Phase 18 — PASS
- Files: training.py, benchmark.py, chooser loader, training tests, frozen calibration
  corpus, docs/benchmarks/*.json, docs/laya-training.md, notices, check.sh.
- Official Laya notebook inspected at revision 9d955671415fc19f069b9cc998928075c1f255ec;
  installed API used for real forward/backward/checkpoint/reload/inference. CPU smoke
  updated decision-head weights in 34.192 s (3655.6 MiB peak RSS), no full training claim.
- Exact train/calibrate/benchmark commands and dataset hashes in docs/laya-training.md.
  Validation-only T=1.65, 20 heads; frozen 14-case test accuracy 10/14 for generic,
  calibrated and tiny-trained checkpoints. No default promotion or accuracy gain claimed.
  Candidate pruning improved validation 8/14 to 10/14; history retained.
- Missing/corrupt specialized checkpoints safely fall back to generic. Test task
  groups disjoint from validation and actual fixture training corpus.
- scripts/check.sh: Ruff lint/format PASS; 193 Python tests PASS. Desktop Swift cache
  hit recurring input-modified filesystem error. Moved build scratch path to Kio cache;
  swift test/build --package-path apps/macos --scratch-path "$HOME/Library/Caches/Kio/swift-build":
  10 Swift tests and build PASS. No tests disabled.
- Limit: small handcrafted paired validation/test templates; not broad GUI accuracy.
  Generic 11+ choice confidence warning remains documented. Larger training optional.

## Phase 19 — PASS (current-host isolated environment)
- Added standalone-runtime packaging, setup UI/check/install/self-test, pinned Laya
  manifest, Keychain service Kio, bundle-relative helper discovery, external CUA
  /Applications detection, distribution licence inventory and artifact audit.
- scripts/build-unsigned-app.sh produced dist/Kio.app (~761 MB before final pip
  removal). CPython 3.12.8 + 57 locked production distributions, native OCR and
  whisper.cpp (explicit macOS 14 target); no system Python/uv/source checkout used.
- scripts/check.sh: 195 Python / 10 Swift, Ruff lint/format/build PASS.
- scripts/check-artifact.py on a relocated cache copy and final dist/Kio.app:
  isolated imports and inert NDJSON PASS; 48 Mach-O files, no developer dylib paths.
- Minimal environment HOME/PATH/USER, no developer key/venv/root: launched relocated
  Kio, verified model through setup UI, ran real CUA/Laya self-test, completed setup,
  opened Calculator, then real Start/Continue/Send/Submit/Success workflow from UI.
  Four actions independently verified by fixture; no terminal needed after launch.
- Initial workflow safely stopped on CUA's extra 66x20 Safari tooltip. Added tested
  exclusion of tiny/non-content windows; ambiguity between real windows still blocks.
- Real Keychain temporary unique account save/read/replace/delete PASS; no real key
  read or changed. Real HTTPS small model-config download verified SHA-256. Existing
  pinned HF model reused with full checksums, original cache preserved.
- Final bundle separate self-test from minimal environment: real CUA ready, model
  ready, bounded inference PASS. No Gemini configured, no microphone permission.
- Limit: isolated/relocated current-user test, not a fresh macOS VM or Intel test.
  Existing CuaDriver TCC grants retained; Gatekeeper manual-open behavior documented.
  Exact commands: docs/packaging.md; setup JSON is separate from unchanged NDJSON v1.

## Phase 20 — PASS for all applicable local gates
- Exact implementation, commands, raw report links, external limitations and A–P
  scenario evidence: docs/phase20-results.md. Files: metrics.py, timed pipeline stages,
  smoke scripts, runtime/driver/candidate fixes, VoiceTemporaryFiles, stress/routing
  tests, long/credential fixtures, scripts/check-all.sh, artifact/privacy audits, docs.
- Final scripts/check-all.sh PASS: Ruff lint/format, 209 Python / 11 Swift, Swift
  build, fresh standalone artifact, 48 Mach-O audit, real tiny training reload/infer,
  privacy audit. No disabled regressions. Final training 40.012 s; no default promotion.
- Final dist/Kio.app (~755 MiB), minimal environment and bundled interpreter: real
  12-action task completed in 47.884 s, 2838.8 MiB peak RSS, zero OCR/Gemini.
  Real form four actions verified field/option/Success after fixing documented CUA
  foreground web typing; no coordinate fallback. Real secret field blocked untouched.
- Stop halted after one action, helper crash recovered via Run, CUA stop/restart
  readiness recovered, real replay matched 12/12 with zero CUA execution.
- Five real OCR probes: capture median969 ms, OCR120 ms, merge.181 ms, 8 regions,
  6 candidates, zero actions (CUA lacks capture-bound pixel authority).
- External exceptions: no live Gemini key/model, no granted microphone permission,
  no available normalized DOM route on tested browser. Contract tests pass; no
  fabricated provider/microphone/DOM success. No universal GUI or fresh-VM claim.
- Phase 16 latest autonomous ALLOW/BLOCK requirement supersedes original one-action
  approval requirements. Deprecated approval messages still cannot grant authority.


## Phase 21 — CUA upgrade and capability audit PASS (2026-09-28)
- Scope: move the external Driver to stable 0.30.2 after inspecting official release
  notes, installer, SDK boundary, current live MCP schemas and capture/perception docs.
- Files: `capabilities.py`, Driver schema discovery and native capture identity,
  capability tests and actual-schema fixture, README/architecture,
  `third_party/cua-driver.json`, `THIRD_PARTY_NOTICES.md`,
  `docs/cua-upgrade.md`, `docs/part2-results.md`.
- Architecture: persistent MCP remains because CuaDriver.app owns existing TCC. Runtime
  schemas grant transport capability only; live permission, target, capture and optional
  extension state remain separate. Browser actions and one-use capture IDs are preserved.
  The Python SDK is not added, so `uv.lock` stays at 82 packages and MCP 1.30.0.
- Commands: `scripts/check-all.sh` baseline; `scripts/check.sh` after edits; live
  `companion_agent.driver`, `smoke_loop`, `live_checks`, `visual_smoke`, and direct
  runtime checks.
- Results: baseline complete suite 209 Python/11 Swift plus lint/format/build,
  isolated package audit, tiny training smoke and privacy audit PASS. After upgrade and
  edits `scripts/check.sh` = 216 Python / 11 Swift, lint/format/build PASS; final
  `scripts/check-all.sh` evidence recorded in the Phase 21 report.
- Live results: Driver 0.30.2 health ok, Accessibility/Screen Recording pass; four-action
  form and 12-action workflow complete; Calculator and Google search direct complete;
  5 safety checks pass with zero guarded actions; Stop cancels after one action; password
  task needs_user without typing. Real poor-AX canvas OCR: 7 regions, 6 candidates,
  capture 447 ms, OCR 251 ms, Laya 565 ms, zero actions/Gemini. Exact native capture ID
  is now carried through Kio's frame.
- Parser/license: live `parse_visual_regions` returned `not_installed`; active capability
  stays false. The separate optional icon parser is AGPL-3.0-only and was not installed.
  Kio continues with local Apple Vision OCR.
- Limitations: visual candidate execution has not yet been connected to the new capture
  contract; Phase 23 owns that implementation. No live DOM action or Gemini/microphone
  integration is claimed.

## Phase 22 — universal surface capability router PASS (2026-09-28)
- Scope/files: added project-owned `Surface`, identity/capability/route types,
  `SurfaceResolver`, `CapabilityRouter`, capability-gated dispatch on each fresh loop
  observation, deterministic target-window resolution, and surface tests. Updated
  `runtime.py`, `loop.py`, `capabilities.py`, README/architecture and this report.
- Architecture: structured browser actions take priority only when both the current
  surface and live driver capability are ready; otherwise usable AX wins, then visual
  only with native capture-bound authority and a matching visual result. Desktop is
  explicit fallback only. Routes are recalculated on each fresh observation. Window
  selection filters transient/tiny/off-space windows, accepts a unique visible window
  or strong goal-title/session evidence, and returns needs_user on ambiguity.
- Regression found and fixed: an already verified terminal screen with only static
  text had no action route and was incorrectly rejected before GoalVerifier ran. The
  loop now verifies completion before requiring a route; if further action is needed,
  unsupported still fails closed. A test covers verified completion without action
  capability.
- Tests/commands: `scripts/check.sh` PASS — 223 Python tests, 11 Swift tests, Swift
  build, Ruff lint and format. Tests cover structured-browser/AX/visual priorities,
  route recalculation, browser/dialog/transient classification, target resolution and
  ambiguity, desktop opt-in, capture authority and verified terminal state.
- Live: CUA Driver 0.30.2 fresh Safari observation classified `BROWSER_PAGE` and
  selected accessibility route from 6 live elements. Real Safari fixture with local
  Laya completed Start → Continue in 2 actions; independent verifier observed Success,
  zero Gemini. Metrics are in `/tmp/kio-phase22-live-metrics.json`.
- Limits: the installed optional visual parser remains absent and no structured DOM
  action was advertised for this Safari target. Visual action execution is Phase 23.

## Phase 23 — safe capture-bound visual execution PASS (2026-09-28)
- Scope/files: connected local OCR regions to goal-matched visual candidates and the
  installed CUA 0.30.2 one-use capture click contract. Updated `candidates.py`,
  `driver.py`, `loop.py`, `visual_smoke.py`, perception merging, visual execution tests,
  README and architecture documentation.
- Architecture: the action point is deterministically calculated from the region box
  and exact captured frame. Laya sees only region text, coarse position and candidate
  ID. Before acting Kio reobserves and recaptures, verifies unchanged observation and
  image digest, rebuilds the table, rechecks policy/Stop, then submits the current
  native capture ID with in-frame pixel coordinates to CUA. No stale retries or blind
  fallback exist. OCR spelling noise can map to a canonical goal token privately for
  ordered-goal progress; it does not change candidate identity or model authority.
- Regression/tests: `scripts/check.sh` PASS — 234 Python tests, 11 Swift tests, Ruff
  lint/format and Swift build. Added visual capture binding, exact CUA arguments,
  duplicate labels, confidence/bounds, stale-pixel rejection, fuzzy OCR matching and
  canonical objective progress coverage.
- Live smoke: `companion_agent.visual_smoke` used CUA Driver 0.30.2 and Apple Vision
  on a real Safari canvas fixture. 11 OCR regions, 7 bounded choices, one visual
  candidate; Laya selected its capture-bound CLICK at 0.7332 confidence. Capture
  439 ms, OCR 159 ms, merge 0.33 ms, Laya 351 ms; zero actions/Gemini in the probe.
  Real local loop then executed exact-capture clicks through Continue and Option B;
  GoalVerifier independently observed Success. Two actions in the measured run,
  10.65 s total, zero Gemini. The preceding Settings click was separately accepted
  against its native capture and advanced the same fixture before that run.
- Exact commands: `scripts/check.sh`; `KIO_OCR_EXECUTABLE=... PYTHONPATH=agent/src
  scripts/agent.sh -m companion_agent.visual_smoke --pid 44355 --window-id 25471`;
  same environment with `companion_agent.smoke_loop --pid 44355 --window-id 25471
  --goal 'Click Continue, then click Option B, then reach Success'`.
- Limits: verification was on the supported live Safari canvas fixture and current
  display geometry. This does not establish arbitrary visual-control reliability on
  every display scale or app. Unmatched/low-confidence OCR, changed captures, clipped
  boxes and missing native capture authority remain fail-closed. Optional CUA visual
  parser stays absent; local Vision OCR is used. Laya's upstream calibration warning
  remains visible and its confidence gate is unchanged.

## Phase 24 — browser-agnostic control PASS for available local gates (2026-09-28)
- Scope/files: honored an explicitly named application for direct URL/search opening,
  generalized address-field URL verification to the exact selected process, and fixed
  two AX fallback problems around closed dropdowns and duplicate clipped menu rows.
  Updated `direct.py`, `driver.py`, `candidates.py`, `policy.py`, direct/candidate/policy
  tests and browser compatibility documentation.
- Architecture: target app selection remains name/bundle-driven and generic; selected
  browsers are never replaced with the default. Unknown/uninstalled explicit targets
  return needs_user without opening the default. Structured browser operations remain
  capability-gated; Phase K now starts CUA's official preparation flow after a
  `browser_consent_required` refusal. The live driver still cannot attest the current
  Chrome profile because its preparation endpoint returned `browser_route_unavailable`,
  so Kio used the real AX fallback; no live DOM/CDP action is claimed.
- Tests/commands: `scripts/check.sh` PASS — Ruff lint/format, 239 Python tests, 11 Swift
  tests, and Swift build. Targeted direct, candidate, policy, and route tests passed.
- Live Safari: requested Safari explicitly for the local fixture URL and independently
  verified the exact address field. Same four-step form task completed by AX in four
  real CUA actions; GoalVerifier matched the field value, Option B, and Success; zero
  Gemini. Metrics: `/tmp/kio-phase24-safari-ax.json`.
- Live Chrome: requested Chrome explicitly and independently verified its exact URL.
  The same form task completed using AX in stages: text entry, dropdown expansion,
  selection of Option B, and Reach success. GoalVerifier matched all three results;
  zero Gemini. Initial runs exposed a clipped duplicate menu item and were rejected by
  confidence/ambiguity checks; candidate filtering and policy now exclude the 6-pixel
  clipped fragment, while the full 24-pixel item remains actionable. Metrics:
  `/tmp/kio-phase24-chrome-ax.json` and `/tmp/kio-phase24-chrome-ax-final.json`.
- Reproduction: `PYTHONPATH=agent/src scripts/agent.sh -m companion_agent.browser_smoke
  --application Safari --url http://127.0.0.1:8765/index.html` (same with `Chrome`);
  `PYTHONPATH=agent/src scripts/agent.sh -m companion_agent.smoke_loop --pid 44355
  --window-id 25471 --goal 'Enter "hello browser" in Message field, choose Option B,
  then click Reach success'` (same Chrome task with `--pid 3337 --window-id 71`).
- Electron: VS Code was installed and running. Read-only CUA/OCR inspection returned
  AX controls and a usable accessibility route on the selected window; exact structured
  browser binding was refused. No task action was sent to the user's editor.
- Browser matrix: Safari and Google Chrome are installed and tested. Firefox, Arc,
  Brave and Edge are NOT INSTALLED per the current CUA app inventory; they were not
  installed for this check. Discord, Notion and VS Code are present as Electron apps.
- Limits: current-host structured-browser attachment cannot be live-validated without
  the CUA authorization/runtime setup described in `docs/cua-upgrade.md`; no hidden
  attachment or existing-profile authorization was attempted. Results cover these
  installed apps and fixture only, not every browser or Electron application.

## Phase 25 — generic app control and cross-surface dialog continuity PASS (2026-09-28)
- Scope/files: followed compact native dialog windows reported separately from their
  content window, classified their fresh AX controls for foreground token delivery, and
  returned to the content window after dismissal. Updated `candidates.py`, `surface.py`,
  `loop.py`, candidate/loop tests, `fixtures/browser/dialog.html`, README, and architecture
  documentation. No app-specific action sequence or alternate input path was added.
- Architecture: a compact bounded AXWindow with a small text/button-only subtree is
  treated as a native dialog. Kio resolves visible same-app windows by current-space and
  z-order, observes the candidate window, and routes only when local AX structure matches
  the dialog shape. It re-resolves that window immediately before action; any change
  discards the decision. It returns to the original window for independent verification.
- Tests/commands: targeted candidate, loop, and surface tests PASS (48 tests).
  `scripts/check.sh` PASS: Ruff lint, 54-file format check, 243 Python tests, Swift build,
  and 11 Swift tests. Tests cover compact native-window classification, exact
  dialog-target action, route return, and existing stale-state, policy, and cancellation
  behavior.
- Live cross-surface smoke: explicitly opened `http://127.0.0.1:8765/dialog.html` in
  Chrome, then ran
  `PYTHONPATH=agent/src scripts/agent.sh -m companion_agent.smoke_loop --pid 3337 --window-id 71 --goal 'Click Continue, then click OK, then reach Success' --metrics /tmp/kio-phase25-cross-surface-dialog-final.json`.
  Real CUA Driver 0.30.2 and local Laya performed two actions: browser Continue → native
  confirmation OK. Kio then returned to the browser and independently observed Success.
  Completed, 2 actions, zero Gemini; total 7.05 s, Laya median 471 ms, fresh observation
  median 276 ms, CUA action median 2165 ms.
- File picker: the Safari upload fixture opened a real native Open panel. CUA listed it
  as a separate window but returned `ax_window_unresolved`, zero controls, and no native
  capture ID. Local screenshot OCR returned zero usable regions. A harmless `Click
  Cancel` run returned `needs_user` with zero actions. Kio did not guess a file path or
  click without native capture authority. The temporary fixture copy under Downloads
  was removed. Safe file selection through this current CUA route remains unsupported.
- Other live coverage: Phase 24 real Safari/Chrome AX form runs, Phase 23 Safari
  capture-bound visual fixture, Phase 20 Calculator direct launch, and Phase 24 read-only
  VS Code Electron observation remain the app categories verified on this host. No real
  mail/message send, destructive operation, or editor mutation was used.
- Limits: the cross-surface gate is satisfied by browser → native confirmation → browser;
  it does not establish file-picker interoperability or universal macOS app support.
  Structured DOM control remains unavailable on this host, as documented in Phase 24.

## Phase 26 — global Option+Command voice shortcut PASS (2026-09-28)
- Scope/files: implemented a modifier-only recognizer, a non-intercepting Core Graphics
  session event tap, explicit Input Monitoring status/request UI, automatic local
  silence-end detection, and cancellation/queueing for voice replacement of an active
  task. Added `ModifierChordRecognizer.swift`, `SpeechSilenceDetector.swift`,
  `GlobalShortcutMonitor.swift`, the voice/model integration, Swift tests, and the
  opt-in `scripts/post-shortcut-smoke.swift`.
- Architecture: Kio requests only `flagsChanged` and `keyDown` events in
  `CGEventTapOptions.listenOnly`, uses aggregate modifier flags for left/right Option and
  Command, and returns the original event unchanged. No characters or key codes are
  persisted or logged. A non-modifier key invalidates the chord; Input Monitoring is
  checked on launch and can be explicitly requested from Kio. Microphone permission is
  requested only when voice capture begins. New transcribed commands wait for the prior
  task's cancellation result before submission; cancelling voice clears a queued command
  while the original task remains stopped.
- Tests/commands: `scripts/check.sh` PASS after Phase 26: 243 Python tests, 19 Swift
  tests, Swift build, Ruff lint and 54-file format check. Modifier tests cover both
  modifier orders, aggregate left/right flags, one trigger per release, letter/Escape
  rejection, and interrupted-tap reset. Silence tests cover speech-before-silence,
  trailing silence, no-speech timeout, meter errors, and max duration.
- Live shortcut: built Kio with bundle ID `local.companion.dev`; its own UI reported
  “Global Option+Command shortcut is enabled.” With Calculator foreground and Kio
  inactive, ran the guarded synthetic session event smoke
  `swift scripts/post-shortcut-smoke.swift --send-option-command`. The live Kio app
  changed to “Microphone permission…”, proving the global event reached the app while
  another application was active. The Kio process was then closed cleanly. This was a
  synthetic Core Graphics flags-changed event, not a physical keyboard press.
- Microphone: the live run stopped at macOS microphone authorization (`notDetermined` in
  the earlier Phase 15 check); no recording or audio file was created. Actual voice
  transcription still requires the user to enable Microphone for Kio. No TTS exists.
- Limits: Kio focused, Safari/Chrome/Finder, full-screen and other-Space shortcut
  variants were not individually exercised. The session tap architecture is global,
  but this is not a universal focus matrix result. Local physical-microphone and STT
  E2E remain unverified as recorded in Phase 15. Phase 27 follows.

## Phase 27 — notch-expanding voice UI PASS (2026-09-28)
- Scope/files: changed Kio to a menu-bar-first app with separately opened debug/setup
  windows; implemented a compact non-activating overlay positioned from current
  `NSScreen` geometry and safe areas; added restrained expand/collapse, waveform/status
  states, Escape cancellation, transcript review setting (default OFF), automatic local
  transcript submission, and brief Done dismissal. Updated Companion.swift,
  NotchOverlayController.swift, GlobalShortcutMonitor.swift, OverlayLayout.swift and
  OverlayLayoutTests.swift, plus README and architecture docs. NDJSON and helper routing
  are unchanged.
- Architecture: panel uses `.borderless` + `.nonactivatingPanel`, status-bar level,
  all-Spaces/full-screen-auxiliary behavior, and leaves the frontmost app active. The
  screen containing keyboard focus is preferred, then the pointer screen, then the
  first screen. A notched display uses its live top safe inset; other displays anchor
  below the menu-bar visible frame. Display-parameter changes reposition a visible
  panel. Debug and setup windows open only from the menu extra.
- Tests/commands: `scripts/check.sh` PASS: Ruff lint, 54-file format check, 243 Python
  tests, Swift build, and 22 Swift tests. Geometry tests cover notch placement,
  non-notch display with negative origin, and narrow-screen width clamping. Existing
  modifier, VAD, cancellation, and protocol tests remain green.
- Live UI smoke: `scripts/run-macos.sh` launched Kio with bundle ID
  `local.companion.dev`. Before voice activation, CoreGraphics listed no visible Kio
  windows; the helper remained running. After guarded synthetic Option+Command, a live
  360×92 Kio panel appeared at the top center of the built-in 2056×1329 display, 39 px
  from the captured screen top, visually connected below its 38 px safe-area/notch.
  Safari remained frontmost. The live capture was temporary and deleted. The UI then
  returned a low-confidence status; this was not counted as a task or STT success.
  Kio was quit cleanly, its helper stopped, no voice temp directory remained, and trajectory recording is
  disabled by default. This is a UI/shortcut smoke, not a verified speech transcript.
- Limits: intentional microphone speech → transcript → task E2E is Phase 28. The screen
  change path is implemented but an external-display hotplug was not available. A
  physical keyboard chord was not used; the shortcut smoke posts synthetic modifier
  events. Voice cancellation during an active recording/transcription is covered by
  state tests; the timed live attempt progressed beyond the initial listening UI and
  is not counted as a live Escape acceptance result.

## Phase 28 — local microphone command E2E PASS (2026-09-28)
- Scope/files: made first-use microphone authorization explicit in
  `VoiceController.swift`, exposed a System Settings action for denied permission in
  `Companion.swift`, normalized trailing spoken punctuation in the deterministic
  direct router, and resolved duplicate same-bundle CUA process entries by preferring
  a unique active process. Ambiguous process groups still fail closed. Added direct
  routing and active-process regression tests.
- Tests/commands: `scripts/check.sh` PASS after implementation: Ruff lint and format
  (54 Python files), 244 Python tests, Swift build, and 22 Swift tests. Read-only live
  CUA health returned `health=ok`, Driver 0.30.2. Test coverage includes punctuation,
  combined browser search, duplicate app instances and ambiguity rejection.
- Live voice tests: with microphone permission authorized, the local built-in
  microphone captured speech from macOS `say` played acoustically through the
  MacBook's speakers (controlled acoustic stimulus; not a human-spoken test). Local
  Whisper transcribed and ran three commands:
  `Open Calculator.` independently verified Calculator as frontmost;
  `Open Google Chrome and search for Norbert Wiener.` independently verified Chrome
  at `google.com/search?q=Norbert+Wiener`; and `Click Continue until Success.` drove
  12 fresh CUA actions on the Safari long-workflow fixture, whose independent success
  marker and title became `Success`. The active Safari process resolver fix corrected
  a first fail-closed attempt against duplicate stale process records. CUA 0.30.2 and
  local Laya were used for the multi-step task. No Gemini calls were made. No voice or
  screenshot artifacts were retained; Kio's temporary recording directory was empty
  after tasks, and trajectory recording was disabled.
- Limits: macOS `say` generated the acoustic stimulus outside Kio; Kio itself has no
  TTS, and a live human speaker/accent test remains unverified. Voice latency was not
  instrumented in this phase. Safari/Chrome focus behavior beyond these exact tasks is
  not established. Phase 29 follows.

## Phase 29 — short conversational session context PASS (2026-09-28)
- Scope/files: added in-memory `SessionContext` and integrated deterministic follow-up
  resolution in `runtime.py`. It tracks current app/bundle/process/window/page, the
  last completed goal, bounded object/selection/text references, and short recent
  entity/URL/app lists. Added tests in `test_session_context.py` and runtime handoff
  tests in `test_runtime.py`; documented the boundary in README and architecture.
- Architecture: no conversation transcript or trajectory is supplied to Laya. The
  context expires after ten minutes, clears target/object references when the process
  or remembered window disappears, and clears object-specific references when switching
  apps. It can route a simple search to the browser just opened, reopen the last
  verified page, or turn “Call it …” into a bounded title-field goal only when a
  completed object-creation goal is recorded. Context never supplies action authority.
- Tests/commands: `scripts/check.sh` PASS: Ruff lint, 56-file format check, 252 Python
  tests, Swift build, and 22 Swift tests. Tests cover browser/app continuity, exact
  search query, page references, object naming guarded by a completed creation, timeout,
  closed-target invalidation and explicit reset.
- Live smoke: with the real CUA Driver 0.30.2, one persistent `Runtime` completed
  `Open Google Chrome` and then `Search Norbert Wiener` with target input still set to
  Safari. The app-open GoalVerifier evidence observed `Google Chrome`; the follow-up
  route used remembered Chrome and the URL verifier observed
  `google.com/search?q=Norbert+Wiener`. Both used the deterministic direct route and
  zero Gemini. An intervening read-only health probe transiently returned
  `driver_unavailable`; the full sequential live smoke then reconnected and passed.
- Limits: object naming was unit-tested but not exercised against Notes in this run;
  no app-specific item mutation is claimed. Context covers common short references, not
  unrestricted conversational inference. Phase 30 follows.

## Phase 30 — performance instrumentation and safe routing audit PASS (2026-09-28)
- Scope/files: extended opt-in timing with dynamic route samples in `metrics.py` and
  `loop.py`; measured normalized structured observation separately from DOM and AX in
  `perception.py`, visual perception in `ocr.py`, and full runtime task time in
  `runtime.py`. Added route-distribution tests. No freshness or authority shortcut was
  introduced.
- Architecture decisions: post-action observation is already reused for both
  GoalVerifier and the next decision; no second observation or stale reuse exists.
  Structured AX suppresses screenshot/OCR through the existing capability-aware
  fallback. No perception cache was justified. Laya stays persistent/lazy; the first
  measured model load was 5.18 s and reached 2.39 GiB peak RSS, so automatic idle
  preload would impose large memory cost and unnecessary model loading for direct
  commands. The UI remains responsive because loading is off the main thread. CUA
  action delivery remains as documented: foreground web typing is retained after the
  earlier real background-delivery ambiguity.
- Tests/commands: `scripts/check.sh` PASS: Ruff lint, 56-file format check, 253 Python
  tests, Swift build, and 22 Swift tests. Existing regressions guarantee direct routes
  bypass Laya/Gemini, AX-sufficient routes bypass OCR, loaded Laya is reused, and
  post-action state is fresh.
- Live structured AX run: on CUA Driver 0.30.2, Chrome local fixture task
  `Enter "phase thirty check" in Message field, choose Option B, then click Reach
  success` completed four actions with AX, local Laya, fresh CUA state and independent
  field/option/Success evidence; zero OCR and Gemini. Timings from that run (n=4
  decisions/actions): AX observation median 296.6 ms, p90 384.6 ms; Laya median
  780.3 ms, p90 954.0 ms (first 913.6 ms, warm median 647.0 ms); CUA action median
  2257.5 ms, p90 3375.9 ms; fresh observation median 272.6 ms; candidate building
  median 0.073 ms; GoalVerifier median 0.021 ms; total 15.647 s (3.91 s/action).
  Peak process RSS was 2392 MiB. A separate three-run direct Google search smoke had
  zero model/action steps and zero Gemini; runtime median 2140 ms, p90 2239 ms, warm
  median 2068 ms, with parser median 0.025 ms and direct execution median 1257 ms.
- Known limits: no normalized DOM route was advertised by the current CUA browser
  adapter, so DOM timings are instrumented but have no live sample. The Safari local
  fixture URL attempt returned needs_user; Chrome route succeeded. Driver action latency
  dominates the safe AX task, so no platform-sensitive delivery shortcut was applied.
  Poor-AX capture/OCR remains the separately measured Phase 20/21 path (Phase 20
  screenshot capture median 969 ms and OCR median 120 ms); this AX run made no screenshot.

## Phase 31 — live Gemini fallback availability gate PASS (2026-09-28)
- Scope: checked Kio's configured Keychain service without reading or exposing the
  credential value; inspected the existing text/guidance/vision contracts and current
  target-window image minimization.
- Key status: no generic-password item exists for service `Kio`, account `gemini`.
  Per the phase's explicit no-key rule, no live Gemini requests were made; this is not
  reported as a live generated-text, guidance or vision integration.
- Validation: `scripts/check.sh` PASS immediately before this gate (253 Python tests,
  22 Swift tests, Ruff lint/format and Swift build). Existing contract coverage in
  `agent/tests/test_system2.py` and `agent/tests/test_vision.py` validates generated
  text, guidance, visual region references, invalid/oversized output, injection and
  timeout/rate-limit boundaries. The real live tasks in Phases 28–30 made zero Gemini
  calls.
- Architecture: Gemini remains optional. Vision still requires the explicit privacy
  setting and uses only a target-window frame; after any advisory response Kio performs
  fresh local perception, candidate construction, Laya, policy and CUA validation.
  Phase 32 follows.
- Limits: live generated text, high-level guidance and visual guidance remain untested
  until a Kio Keychain Gemini credential is configured. This did not block continuing
  the local-control phases, as directed.

## Phase 32 — current-host compatibility matrix PASS for exercised gates (2026-09-28)
- Scope/files: created `docs/compatibility.md` and linked it from README. It records
  installed/tested status, actual route, task result and known issue for browsers,
  native apps, Electron apps and fixtures. It explicitly says this is tested coverage,
  not a support whitelist.
- Browser coverage: Safari and Chrome are installed. Live local AX tasks in both
  browsers completed with independent form/Success verification; Chrome also completed
  direct Google search and Phase 30 task. The installed CUA exposed no usable normalized
  DOM route. Firefox, Arc, Brave and Edge are absent from the CUA app inventory and
  `/Applications`; none was installed or labeled tested.
- Native coverage: real CUA direct app launch + independent running-app verification
  completed for Finder, Notes, Calendar, Reminders, Preview, System Settings and
  Google Chrome in the Phase 32 run; Calculator had prior and current live direct
  verification. Read-only AX observations completed for Calculator (146 controls),
  Finder (246), Notes (71), Calendar (190), Reminders (126), Preview (102), System
  Settings (119), and Safari (9) with no UI labels/content written to this report.
  No settings were changed and no calendar/reminder/document edits were made. A new-note
  content task was attempted but its helper result was not trustworthy; it is explicitly
  not claimed as a pass.
- Electron/hybrid coverage: installed Discord and VS Code were previously observed
  read-only through real CUA AX; Discord exposed 117 controls, and VS Code exposed AX
  controls with OCR inspected only as needed. No user editor or messages were changed.
  Notion and Spotify are installed but were not exercised.
- Fixture coverage: real Chrome and Safari AX form tasks, real Chrome 12-action workflow,
  local poor-AX OCR/capture-bound task, and the Chrome → native confirmation → Chrome
  task all remain documented in their phase entries. The native file picker still fails
  closed; no camera task was run.
- Commands: browser launches were checked through `companion_agent.browser_smoke` for
  local URL verification; app launches and the AX form task used real
  `CuaDriver.connect()` and `AgentLoop`/`Runtime`; regression suite for these changes
  remains `scripts/check.sh` (253 Python, 22 Swift, lint/format/build PASS at Phase 30).
- Limits: the create/rename Finder workflow and a successfully verified Notes content
  task remain uncompleted. Electron Notion/Spotify tasks and any app-specific settings
  navigation remain untested. See `docs/compatibility.md`; no universal-app claim is
  made. Phase 33 follows.

## Phase 33 — safe dogfood trajectories and error analysis PASS (2026-09-28)
- Scope/files: added explicit `smoke_loop --trajectory-root` to write opt-in sanitized
  fixture recordings outside the default user-recording directory; created
  `fixtures/browser/scroll.html`, `fixtures/trajectories/phase33/` and its task-level
  export under `fixtures/calibration/phase33-export-v2/`. Updated scroll capability
  routing/fallback tests and added `docs/phase33-dogfood.md`.
- Architecture: a scroll route requires a visible AXScrollArea/WebArea with a nonempty
  fresh CUA element token. That structured scroll target suppresses OCR on explicit
  scroll goals to avoid screenshot text jitter. Without the token Kio remains
  unsupported. Only page-level scroll is currently demonstrated; nested scroll-region
  action remains unsupported. No action authority, freshness, policy, Stop or model
  boundary was relaxed.
- Data: seven independently verified fixture task groups produced 24 executed action
  labels. Existing trajectory correction hashes keep each original immutable. Seed 418
  assigned whole runs into train (2 runs/6 rows), validation (2/13) and test (3/5),
  with no run split across partitions. Existing unverified attempts were kept separate
  for error analysis and excluded from the export. Privacy scan found no credential
  patterns or machine paths and no image/audio files in the fixture dataset.
- Replay/live results: real CUA Driver 0.30.2 + local Laya completed Chrome AX form
  typing/selection (4 actions), single field entry (1), selection-only (2), 12-step
  continuation, page scroll (1), start/continue (2), and browser → native confirmation
  dialog → browser (2). Each task had independent field/option/Success evidence where
  applicable; all made zero Gemini calls. Offline generic-Laya replay matched 24/24
  recorded choices and executed zero CUA actions. This measures consistency only, not
  independent accuracy.
- Error analysis: final financial commitment policy returned needs_user with zero
  actions; identical Details targets returned needs_user with zero actions. A long
  visual instruction was rejected at low confidence with zero actions. A shorter
  visual task made one capture-bound click, then emitted repeated early DONE; the
  GoalVerifier rejected it and the task remained incomplete. Scroll traces found the
  missing AX route, stale/OCR fallback interaction, and unsupported nested target; the
  fresh-token page-level route now passed live. See `docs/phase33-dogfood.md` for
  classifications and boundaries.
- Tests/commands: `scripts/check.sh` PASS after source changes: Ruff lint/format, 257
  Python tests, Swift build, 22 Swift tests. Real fixture recordings used
  `scripts/agent.sh -m companion_agent.smoke_loop ... --record
  --trajectory-root fixtures/trajectories/phase33`; see the dogfood report for exact
  task commands and split seed.
- Training decision: no fine-tuning or new calibration was run. Twenty-four action
  labels across seven runs, with only six train rows and one browser fixture family,
  are not sufficient to justify a change. The frozen generic benchmark remains
  10/14; no improvement is claimed and generic Laya remains default. Phase 34 follows.

## Phase 34 — package-size audit and final artifact hardening PASS (2026-09-28)
- Scope/files: audited Python/PyTorch/Laya/Tokenizers/Whisper/model payloads and
  added `docs/bundle-size.md`. Updated `scripts/package-runtime.py` to prune only
  non-runtime CPython development/UI resources, PyTorch C++ headers and two `protoc`
  binaries. Added `agent/tests/test_packaging.py`; updated packaging and README links.
- Architecture decision: PyTorch remains because current Laya depends on it and its
  CPU library accounts for about 368 MiB. No Core ML/MLX/ONNX conversion or inference
  rewrite was attempted. Laya/Whisper weights remain revision/SHA-256 managed in Kio
  Application Support, not duplicated in the app. Runtime distributions and `.dist-info`
  metadata/licenses stay bundled; `--no-dev` keeps pytest/Ruff out.
- Size: regular-file payload fell from 703.55 MiB to 649.97 MiB (53.58 MiB / 7.6%).
  Host `du -sk` reported 755.3 MiB to 675.2 MiB allocated. The package-pruning function
  removed 53.9 MiB of files. The final bundle contains 57 runtime distributions and
  46 Mach-O files.
- Tests/commands: initial clean `scripts/check.sh` passed 257 Python / 22 Swift.
  After packaging changes, `scripts/check-all.sh` passed Ruff lint/format, 258 Python,
  Swift build and 22 Swift tests, isolated artifact imports/NDJSON startup, all 46
  Mach-O path audits, tiny training step/checkpoint reload/inference, and privacy audit.
  The training smoke completed one backward step and reported changed weights,
  checkpoint reload and inference working (38.7 s; about 3.48 GiB peak RSS).
  `scripts/agent.sh scripts/check-artifact.py dist/Kio.app` passed again after final
  promotion. Python version 3.12.8; torch 2.14.0; Laya 0.3.20; Tokenizers 0.23.2.
- Packaged benchmark command:
  ```sh
  KIO_MODEL_MANIFEST=dist/Kio.app/Contents/Resources/models/laya.json \
    dist/Kio.app/Contents/Resources/python/bin/python3.12 -I -B \
    -m companion_agent.benchmark --cases fixtures/calibration/cases-v1.json \
    --report /tmp/kio-phase34-packaged-clean.json --split test
  ```
  Development comparison used the same manifest and corpus with
  `scripts/agent.sh -m companion_agent.benchmark`.
- Packaged model regression: `companion_agent.benchmark` on
  `fixtures/calibration/cases-v1.json --split test` matched the development build's
  expected outcomes across 14 cases: combined accuracy 10/14, target accuracy 7/7,
  zero false high-confidence errors. Warm median was 117 ms packaged / 111 ms
  development; cold load 7.42 s packaged. ECE was 0.184 / 0.189 respectively. No
  model, decision policy or calibration artifact changed. Existing upstream Laya
  11+ choice calibration warning remains.
- Live smoke: real `cua-driver call health_report '{}'` returned overall `ok` on
  CUA Driver 0.30.2, arm64/macOS 27.0, active MCP and granted Accessibility/Screen
  Recording. ScreenCaptureKit capability was skipped because this health call is
  read-only; this is a health check, not a desktop-action smoke. The app's live Laya
  regression used the installed checksum-verified Application Support model; no CUA
  action or Gemini request was made in that benchmark.
- Limitations: no Intel or fresh-user VM was available; runtime still requires the
  separately installed CuaDriver.app and its TCC grants. Gatekeeper behavior remains
  the documented unsigned/manual-open path. No inference-backend replacement was
  evaluated because no alternative was needed to achieve the safe size reduction.

## Phase 35 — embedded CUA host PASS (2026-09-28)
- Scope: bundle the verified CUA Driver 0.30.2 executable and let the Swift app host
  own its daemon, private MCP socket and macOS TCC responsibility. The source-dev
  fallback remains external; the packaged app has no CuaDriver.app dependency.
- Files: `EmbeddedDriverSpec.swift`, `EmbeddedCUASupervisor.swift`,
  `HelperConfiguration.swift`, `Companion.swift`, `SetupView.swift`, `Info.plist`,
  `driver.py`, `test_driver.py`, `FoundationTests.swift`,
  `scripts/package-cua-driver.py`, `scripts/build-unsigned-app.sh`,
  `scripts/check-artifact.py`, `third_party/cua-driver.json`, README, architecture,
  packaging, CUA upgrade, notices, test strategy and Part 2 results.
- Architecture: the Kio Swift process directly starts
  `cua-driver serve --embedded --socket … --permission-mode standard`; the persistent
  Python helper connects with the official `mcp --embedded --socket` proxy. The
  per-host private temp directory has user-only permissions, an exclusive Kio lock,
  a short Unix socket path, stale-session cleanup and graceful child termination.
  The exact vendor-signed executable hash is checked and its signature is preserved.
  Kio bundle identifier `local.companion.dev` stays unchanged and owns embedded
  Accessibility and Screen & System Audio Recording permission attribution.
- Tests/commands: a cache artifact was built with
  `KIO_BUILD_OUTPUT="$HOME/Library/Caches/Kio/Kio-P35c.app" scripts/build-unsigned-app.sh`.
  `scripts/agent.sh -m pytest agent/tests/test_driver.py agent/tests/test_setup.py -q`
  passed 21 tests; Ruff check and format check passed on the changed Driver/tests;
  `swift test --package-path apps/macos --scratch-path "$HOME/Library/Caches/Kio/swift-build" --filter FoundationTests`
  passed 3 tests. `scripts/agent.sh scripts/check-artifact.py
  "$HOME/Library/Caches/Kio/Kio-P35c.app"` passed: isolated Python 3.12.8 / torch
  2.14.0, inert NDJSON, pinned CUA 0.30.2 hash/vendor signature and 47 Mach-O path
  audits. Swift build completed as part of the focused Swift test command.
- Live smoke: Kio was granted Accessibility and Screen & System Audio Recording
  through System Settings. `/Applications/CuaDriver.app` was stopped before the
  acceptance run. Packaged Kio started `cua-driver serve --embedded` as its direct
  child (host PID 5225, driver PPID 5225); real `health_report` returned `ok`,
  `identity_source=parent_application`, bundle `local.companion.dev` and parent PID
  5225. `check_permissions` returned `attribution=host`, Accessibility=true and
  Screen Recording=true. The embedded connection launched Calculator, observed its
  146 real AX controls and captured a 460×816 PNG with a native CUA capture ID; the
  image remained in memory. After graceful termination of Kio, its child exited and
  its Unix socket was removed. The standalone Driver remained stopped.
- Latency: no separate latency benchmark was needed for this lifecycle/identity gate.
- Limitations: live permission and process validation is on Apple Silicon/macOS 27
  with this user's TCC grants. Ad-hoc host rebuilds or a changed bundle identity may
  require grants again. A first staging build under the Desktop/File Provider path
  failed bundle signing because of staging metadata; the isolated cache build passed.
- Phase 36 follows for the first-run setup and permission-repair UX. Development-source
  runs continue to use the explicit standalone Driver fallback; the packaged runtime does not.

## Phase 36 — IN PROGRESS (2026-09-28)
- Scope: versioned first-run/repair state, branded setup UI, native permission routes,
  optional voice setup, required global-shortcut setup, model download progress, and
  non-mutating self-test.
- Files: `SetupProgress.swift`, `SetupView.swift`, `Companion.swift`,
  `GlobalShortcutMonitor.swift`, `models.py`, `setup.py`, `FoundationTests.swift`,
  `test_models.py`, `test_setup.py`, README, architecture, packaging, this status and
  Part 2 results.
- Architecture: setup completion is persisted as schema/setup version 2, with safe
  migration of the legacy completion flag. A SwiftUI setup view is hosted in one AppKit
  window presented by `applicationDidFinishLaunching`, retaining macOS 14 support.
  The same global-shortcut monitor is shared by app and setup. Permission repair is
  separate from first-run onboarding. A newly granted Screen Recording permission
  requires an explicit Kio restart before Continue is enabled.
- Tests/commands: `scripts/check.sh` PASS — 265 Python tests, 26 Swift tests, Ruff lint
  and format, Swift build. Focused setup Python tests: 6 passed; focused Swift
  Foundation tests: 5 passed. Release `Kio-P36.app` passed `scripts/check-artifact.py`:
  isolated Python 3.12.8 / torch 2.14.0 imports, inert NDJSON, original vendor-signed
  CUA Driver 0.30.2 hash and signature, and 47 Mach-O load-path audits.
- Live smoke: first launch automatically displayed “Welcome to Kio”. The Accessibility
  button opened System Settings’ “Device Control and Data Access” pane; the screen
  button opened “Screen & System Audio Recording”. Local AI and Voice Model checks
  found checksum-valid models. The setup self-test loaded the local voice model using
  generated silence; no microphone was used. A separate bundled-runtime MPS smoke loaded
  generic Laya, selected and validated a supplied candidate in 727.09 ms, with no CUA
  action. A real setup status call reported `driver=ready`, `permissions=driver_unavailable`,
  `laya=ready`, `stt=ready`, `voice_test=ready`, `status=needs_setup`; it did not claim
  Kio was ready or execute an action. The first-run simulation was restored afterward
  (`kioSetupComplete=true`, versioned test key removed).
- Limitations/gate: this new app path has no TCC grants. No permission was granted on
  the user's behalf; the ready-state CUA self-test and post-grant restart/recheck are
  therefore unverified, and Phase 37 has not started. macOS ad-hoc rebuilds or moving
  the app may require the user to grant Kio permissions again. Microphone remains
  optional; Input Monitoring is required for normal setup. No model download was needed or
  claimed because the pinned local models were already valid.
- Follow-up troubleshooting: inspected the live `Kio-P36.app`, `dist/Kio.app`, and
  source-development app identities after reports of disabled shortcut and missing
  Whisper runtime. Added a deterministic local Whisper resolver that cannot override
  a packaged helper, development-cache fallbacks for direct GUI launches, stable
  ad-hoc identifier metadata in `scripts/run-macos.sh`, and an app-activation
  Input Monitoring recheck. This does not transfer TCC consent between builds.
  `Kio-P36.app` continued to report Accessibility and Screen Recording as Needed
  after Check Setup and a full relaunch, despite a visible Kio switch being on in
  System Settings. A new grant to the exact running build is still needed to pass
  this phase's live permission gate.

### Phase 36 lifecycle/signing follow-up (2026-09-28)

- The menu-bar label no longer owns startup. `KioRuntimeCoordinator` is registered by
  the SwiftUI app initializer and started from `applicationDidFinishLaunching`, so the
  helper, CUA supervisor, voice wiring, and global event tap have one deterministic
  lifecycle owner.
- Input Monitoring is now a required normal setup stage. Setup version 2 reopens older
  completions once, rejects persisted “skip input monitoring” state, and includes the
  requirement in repair checks. Microphone and the local voice model remain optional.
- The event tap handles `tapDisabledByTimeout` and `tapDisabledByUserInput` by resetting
  the chord and re-enabling itself. Runtime health exposes creation, enablement, recovery
  count, and last-event state for diagnostics.
- Development and unsigned packaging scripts accept `KIO_CODESIGN_IDENTITY`. The
  no-certificate fallback uses an explicit designated requirement for the retained
  `local.companion.dev` bundle identifier. Neither script creates a permanent certificate;
  Keychain Access setup for a named local certificate is documented in `docs/packaging.md`.
- Verification after this work: `scripts/check.sh` passed 265 Python tests, Ruff lint/
  format, Swift build, and 29 Swift tests. The rebuilt development app at
  `~/Library/Caches/Kio/development/Kio.app` passed strict codesign verification and
  reports `designated => identifier "local.companion.dev"`.
- Live permission gate remains open: System Settings shows a Kio entry enabled, but the
  running build still reports Accessibility and Screen Recording as needed. Toggling the
  entry requires macOS administrator authentication, which was not supplied. No physical
  Option+Command press was claimed; a synthetic CUA key event would not satisfy this gate.

### Phase 36 canonical/live follow-up

- The duplicate cleanup gate was completed before feature work resumed. Project
  bundles with identifier `local.companion.dev` were removed from the repository
  build directory, Kio caches and Trash; the only remaining launchable project
  bundle is `/Applications/Kio.app`. Application Support, model caches, config,
  Keychain items and source were preserved. The canonical bundle is ad-hoc signed
  with identifier `local.companion.dev`, contains the pinned CUA Driver 0.30.2
  executable and passes strict/deep signature and artifact checks.
- The running canonical app's embedded CUA returned health `ok`, attributed
  Accessibility and Screen & System Audio Recording to host bundle
  `local.companion.dev`, and reported AX reachability. The live setup window showed
  `Global Shortcut Ready`, `Microphone Ready`, `Voice Model Ready` and all required
  setup checks passed. The user subsequently reported completing the physical
  Option+Command check; this report is retained as user evidence, not synthetic
  key injection or an agent-observed key event.
- CUA Perception 0.2.1 was installed from its publisher-verified signed catalog in
  the user's CUA extension store. It is not bundled in Kio.app. Through the
  canonical embedded daemon, a fresh Chrome capture produced 166 capture-bound
  regions (76 text regions merged into normalized visual elements); the parser used
  `onnx_runtime_cpu` and completed in 3.89 s. A Python `CuaVisualPerceptionProvider`
  then validated the exact native capture id, source window, dimensions and digest.
  Visual candidates remain locally bounded and expose no coordinates to Laya.
- Production loop construction now selects this CUA provider. The former Apple
  Vision/KioOCR worker and its package target were removed after the live migration;
  no second pixel backend remains. If the signed extension is unavailable, Kio fails
  closed instead of silently switching to an unreviewed pixel backend.
- Added CUA provider, capture/region validation, visual-source candidate and
  production-routing regression tests. The obsolete KioOCR Swift target, Apple
  Vision worker, `KIO_OCR_EXECUTABLE` path and OCR tests were removed after this
  migration. Focused perception, capability and visual execution tests passed;
  the complete post-migration gate passed 259 Python tests and 29 Swift tests.
- The real poor-AX `fixtures/browser/visual.html` fixture was brought frontmost in
  Chrome. Its CUA capture produced text and icon regions, including the visible
  `Settings` target. Bundled Kio's local Laya selected that bounded visual candidate
  at 0.9813 confidence in 9.11 s cold (model load); a capture-bound CUA click
  advanced the fixture to `Continue`, and a fresh capture id/digest was observed.
  No Gemini request or Apple Vision/KioOCR process was present. Warm parser calls
  were about 3.9 s on this host.
- Rebuilt `/Applications/Kio.app` after the migration. The final artifact has 46
  Mach-O files, contains no `KioOCR`, retains the vendor CUA SHA-256
  `4b894a8690c70a992fd2cdec11e3f218df5ba9afa74eeab70e26ff81c7a03698`, and passes
  strict/deep codesign. After relaunch, the embedded daemon again reported health
  `ok`, host identity `local.companion.dev`, Accessibility and Screen Recording
  granted, and AX reachable.

## Phase 37 — generic natural-language GoalCompiler PASS (2026-09-28)

- Scope: normalize conversational wrappers, preserve quoted literals, resolve
  installed-app entities dynamically, and compile compound app-plus-task commands
  into a bounded app prelude followed by the existing generic UI loop.
- Files: new `agent/src/companion_agent/goal_compiler.py`, `direct.py`, `runtime.py`,
  `test_goal_compiler.py`, runtime regressions and related docs.
- Architecture: GoalCompiler is deterministic and runs before direct routing. It
  strips only generic wake/politeness wrappers, never rewrites quoted text, URLs or
  search content. App matching scores the live installed-app inventory with bounded
  token/initial/fuzzy aliases and fails closed on ambiguity; there is no app
  whitelist. Compound commands are limited to an `ENSURE_APP` prelude plus one
  remaining generic goal, which then uses the existing CUA/AX/Perception/Laya path.
  Model calls and Gemini are not involved in compilation.
- Tests: focused compiler, direct-router and runtime tests passed 29 tests; Ruff
  lint and format checks passed.
- Live smoke: through the canonical embedded CUA daemon, the literal user-style
  command `Hey Kio, open Calculator up for me` normalized to `open Calculator`,
  resolved the installed Calculator bundle and independently verified the running
  app. Result was `completed`, path `direct`, zero Gemini calls.
- Known limitation at the compiler gate: browser tab creation and richer media
  semantics remain later phases; the compiler deliberately leaves those actions
  to the existing generic CUA path.

## Phase 38 — state-aware app reuse and foregrounding PASS (2026-09-28)

- Scope: reuse running applications/windows, wait for a usable window after launch,
  bring requested apps to the foreground through the CUA contract, and verify the
  exact window before continuing.
- Files: `direct.py`, `driver.py`, focused direct/runtime tests and this status.
- Architecture: `ensure_app_ready` checks the live bundle identity and usable
  layer-0 window list, reuses one existing window, otherwise launches once and
  polls for a usable window. It calls CUA `bring_to_front` with an exact window id
  when available and allows one bounded recovery attempt. It never creates a new
  application instance and fails closed when foreground verification cannot be
  established. Explicit-browser URL routing uses the same preparation path.
- Tests: direct and runtime focused tests passed 25 tests; reuse/foreground and
  ambiguous-target regressions are covered; Ruff passed.
- Live smoke: with Calculator already running, a natural `Hey Kio, open Calculator
  up for me` command reused its existing PID/window, CUA exact foreground activation
  verified the target window, and independent app verification returned `completed`
  with zero Gemini calls. No second Calculator instance was created.
- Known limitation: generic browser new-tab creation remains dependent on the
  target browser's current CUA structured/AX route and is rechecked in the browser
  phase; Kio does not use blind keyboard macros.

## Phase 39 — semantic action grounding PASS (2026-09-28)

- Scope: improve generic media/play/search/submit candidate ordering without
  lowering the global confidence threshold or adding app-specific macros.
- Files: `goal_compiler.py`, `candidates.py`, compiler/candidate tests and this
  status. GoalCompiler now marks `PLAY` intent and scopes `play … on App` through
  the same bounded `ENSURE_APP` prelude.
- Architecture: deterministic semantic hints boost labels such as Play, Resume,
  Start, Search, Send and Submit while down-ranking unrelated Settings, Profile,
  Search or Close controls for a play goal. Candidate IDs, source authority,
  freshness, policy and Laya confidence gates are unchanged.
- Tests: focused compiler, candidate, direct and runtime tests passed 52 tests;
  Ruff lint/format passed. Coverage includes repeated labels, ambiguity and the
  generic media ranking path.
- Live evidence: the canonical CUA visual fixture already demonstrated a bounded
  text target selected by local Laya; this phase adds only deterministic ordering
  for a generic `Play` request. No Spotify-specific code or live media state was
  claimed on this host.

## Phase 40 — streaming local voice and early safe preparation PASS (2026-09-28)

- Scope: add a bounded rolling local Whisper decode while recording, stable-clause
  detection, early safe app-open preparation, cancellation, and final-clause
  continuation without cloud STT or TTS.
- Files: new `CompanionCore/StableTranscriptDetector.swift`, `VoiceState.swift`,
  `VoiceController.swift`, `Companion.swift`, and Foundation tests.
- Architecture: the recorder remains local and temporary. Rolling whisper-cli
  hypotheses are fed to a repeated-complete-clause detector; only complete app-open
  or query-shaped clauses can trigger early preparation. The early clause is tracked
  by the voice session; a later final transcript is reduced to its remaining clause
  before submission, preventing duplicate semantic steps. Cancellation invalidates
  both partial and final work through the existing generation token.
- Tests: Swift Foundation, voice and overlay focused tests passed (13 selected in
  the combined Foundation/Overlay run); the new detector rejects incomplete
  `search for` and commits a repeated `open Calculator` clause. No cloud endpoint
  or TTS path was added.
- Live limitation: an acoustic streaming microphone run was not repeated in this
  code-only gate; the existing local Whisper model/runtime and microphone state
  remain available for the separate OS voice smoke. No live transcript is claimed.

## Phase 41 — fixed notch pill geometry PASS (2026-09-28)

- The active overlay now uses one 380×142 point frame and fixed 22-point corner
  radius across Listening, Transcribing, Working, Done, Error and Needs User.
  Transcript and waveform content are clipped inside the fixed panel; state changes
  no longer pass variable heights to `NSPanel`.
- Swift overlay geometry tests and build passed. A live measurement remains part of
  the final OS UI smoke; no screenshot-derived dimensions are claimed here.

## Phase J — native file picker and browser recheck PASS (2026-09-28)

- Scope: re-test the standard macOS file picker and current structured-browser
  preparation against the embedded CUA daemon without adding blind keyboard or
  profile-modification fallbacks.
- Live file-picker smoke: the real Chrome upload fixture opened the native `Open`
  panel through its AX button. The panel exposed an AX `Cancel` action and was
  dismissed safely; no file was selected, uploaded or persisted. The panel's
  window was not safely resolvable through the embedded CUA window-state route,
  so Kio must fail closed or hand off if a task requires selecting a file.
- Live browser smoke: `get_browser_state` returned the official
  `browser_consent_required` refusal for the existing Chrome profile, with
  `existing_profile` as the supported preparation strategy. Phase K now starts
  that official preparation attempt automatically for an explicit browser goal;
  it does not permanently classify consent as an AX-only limitation.
- Tests: existing native-dialog, capability-routing, stale-state and visual
  execution regressions remain in the focused suite; no new unsafe route was added.
- Limitation: the old implementation did not yet resume through the host consent
  action; that behavior is covered by Phase K below.

## Phase K — official structured-browser preparation and resume (2026-09-29)

- Scope: when an explicit browser goal selects a running browser, Kio now tries
  the structured CUA route first, calls the documented `browser_prepare` flow for
  the exact PID/window when CUA asks for it, surfaces a one-time browser-access
  action without exposing CUA jargon, and resubmits the unchanged goal after the
  host grants access. Preparation failures or a refused grant fall back to the
  existing AX route; no blind click, profile edit, DevTools flag or approval
  bypass is used.
- Files: `agent/src/companion_agent/browser.py`, `driver.py`, `direct.py`,
  `runtime.py`, `tests/test_browser.py`, direct/compiler regressions,
  `CompanionCore/EmbeddedDriverSpec.swift`, `EmbeddedCUASupervisor.swift`,
  `Companion.swift`, `CompanionCore/Protocol.swift` and their tests.
- Architecture: CUA-issued `target_id`/`tab_id` values are the only structured
  action authority. `browser_prepare` uses `{kind: existing_profile}` and the
  exact native window. The Swift “Allow Browser Access” action restarts the
  embedded daemon with CUA's documented `--grant existing-profile`, then
  automatically retries the original goal. A fresh structured state is required
  after navigation before completion; AX fallback is used only when preparation
  or structured verification fails.
- Focused tests: `PYTHONPATH=agent/src agent/.venv/bin/pytest -q
  agent/tests/test_browser.py agent/tests/test_direct.py agent/tests/test_driver.py
  agent/tests/test_goal_compiler.py` — **52 passed**. The new tests cover
  already-authorized state, consent-to-prepare, automatic reobserve, preparation
  failure fallback, exact CUA IDs and no duplicate navigation. Swift Foundation
  and protocol tests — **17 passed** — cover grant arguments and user-facing
  consent text. Ruff lint and format passed.
- Live CUA smoke: the canonical `/Applications/Kio.app` (bundle
  `local.companion.dev`, embedded CUA 0.30.2) reused the existing Chrome window.
  A fresh `get_browser_state` returned `browser_consent_required` with
  `next_action=browser_prepare`; Kio then attempted official preparation. On this
  host CUA returned `browser_route_unavailable` because the current Chrome
  profile's `DevToolsActivePort` could not be read (`Operation not permitted`).
  Kio correctly completed the harmless navigation through AX fallback. This is a
  real preparation-failure fallback, **not** a structured-browser PASS.
- Known limitation: a structured-browser PASS remains blocked by the current
  Chrome/profile CUA endpoint on this host. No bypass flag or profile mutation was
  used. The structured PASS gate remains open until a real CUA preparation grant
  yields a structured state and structured action; the consent/resume contract is
  covered by tests and the host UI path.
- Final regression after the browser changes: `scripts/check.sh` passed **277 Python
  tests**, Ruff lint/format, Swift build, and **33 Swift tests**. `scripts/check-artifact.py
  /Applications/Kio.app` passed with bundled Python 3.12.8, Torch 2.14.0, 46 Mach-O
  files and pinned CUA 0.30.2. The canonical embedded daemon is running in standard
  mode with host identity `local.companion.dev` and health `ok`.

## Phase 42 — canonical install, semantic planning, and Gemini visual removal (current gate)

- Scope: enforce one canonical launchable app at `/Applications/Kio.app`; build scripts
  now stage privately, verify, atomically replace the canonical bundle, and remove staging.
  Added a bounded local `NaturalLanguageInterpreter`/`SemanticTaskPlanner` vocabulary,
  fixed `open a new tab` precedence, and added sequential execution for plans with more
  than two validated steps. Removed Gemini screenshot upload, `visual_guidance`, the
  `allow_gemini_vision` setting, and its Swift UI toggle; Gemini remains text-only.
- Tests: the current regression is **279 Python tests** and **33 Swift tests**;
  Ruff lint/format and Swift build pass. Semantic planner tests cover natural
  email-draft paraphrases, literal recipient preservation, new-tab precedence and
  media desired state. Structured-browser tests cover task session lifecycle,
  private CUA refs, automatic preparation and capture-bound action payloads.
- Architecture: structured browser → AX → signed CUA Perception remains the visual
  hierarchy. Raw screenshots are never sent to Gemini or Laya. CUA remains execution
  authority. Browser candidates carry one consistent named session from start through
  fresh verification and close it at task end.
- Canonical artifact: private staging is removed after build; `/Applications/Kio.app`
  is the only project bundle, with bundle ID `local.companion.dev`. The embedded
  vendor-signed CUA Driver is pinned to **0.30.4** and the live embedded health check
  reports `overall=ok`.
- Browser UX: an explicit browser goal starts the official CUA preparation route
  automatically. Kio has no redundant browser-access approval button; any genuine
  CUA/browser-owned consent remains in that security boundary. Preparation failure
  falls back to AX. On this host the existing Chrome profile still returns
  `browser_route_unavailable`, so no live structured-browser PASS is claimed.
- Perception: meaningfully labeled CUA icon regions are capture-bound visual
  candidates; unlabeled detector classes remain non-actionable. Visual capture IDs
  survive AX merge provenance.
- Gemini: screenshot upload, `visual_guidance`, and `allow_gemini_vision` were
  removed. Gemini remains optional text-only generation/guidance.

## Current continuation — warm voice and overlay semantics (2026-09-29)

- The packaged local voice route now starts one persistent official `whisper-stream`
  process with a rolling 500 ms window. It does not relaunch `whisper-cli` for each
  partial. A bounded semantic parser assigns stable IDs to early `ENSURE_APP` and
  web-search steps, normalizing wake-word/punctuation changes before committing them.
  The AVAudioRecorder/`whisper-cli` path remains only as a development fallback when
  the streaming helper or model is absent.
- Early completion no longer dismisses the fixed 380×142 overlay while the same voice
  session is still listening, transcribing, reviewing, or has pending work. The final
  transcript reconciles against the committed semantic step ID before sending any
  remainder to the ordinary planner.
- `scripts/check.sh` passed 279 Python tests and 37 Swift tests, Ruff lint/format and
  full Swift build. `scripts/build-unsigned-app.sh` rebuilt `/Applications/Kio.app`
  with CUA Driver 0.30.4, `whisper-stream`, SDL2-compat, and its required SDL3
  runtime. The SDL2/SDL3 install IDs and rpaths are private to the bundle, and the
  Kio-owned Whisper/SDL stack is re-signed after Mach-O edits. `scripts/check-artifact.py`
  passed 49 Mach-O audits with no developer/Homebrew paths; strict codesign passed for
  Kio, CUA, Whisper, SDL2-compat, and SDL3. Embedded CUA health returned `ok` from
  the canonical app.
- A local non-spoken streaming start/stop smoke initialized the bundled helper and
  microphone device. Before the SDL3 packaging fix, the helper could terminate with
  a dyld `Code Signature Invalid` error and the OS showed “Failed loading SDL3
  library.” After rebuilding, the helper remained alive for a 5-second capture,
  enumerated the real macOS input devices, loaded the installed Whisper model, and
  emitted its normal `[Start speaking]` state. No human speech result is claimed.
  Physical Option+Command, human-spoken voice E2E, and structured Chrome control
  remain open external gates.
- Final `scripts/check-all.sh` on this exact tree passed 279 Python tests, 36 Swift
  tests, Ruff lint/format, Swift build, isolated packaging/NDJSON, 48 Mach-O audits,
  privacy scan, and the required one-step CPU fine-tuning smoke. The smoke reported
  `weights_changed=true`, checkpoint reload and inference working in 38.76 seconds
  at 3599 MiB peak RSS; no training improvement is claimed.

### Current voice runtime correction (2026-09-29)

- The packaged `whisper-stream` 1.9.4 interface does not accept the legacy `-nt` or
  `-np` flags. Kio had been passing those flags while suppressing stderr, so the helper
  exited immediately and the UI reduced the empty result to “No speech detected.”
  Streaming arguments now match the installed helper, and Whisper's `[BLANK_AUDIO]`
  marker is removed before transcript state is updated.
- Rebuilt `/Applications/Kio.app` and reran `scripts/check.sh`: 279 Python tests and
  37 Swift tests passed, including a regression that treats `[BLANK_AUDIO]` as empty
  speech. Strict signatures and the 49-file artifact audit passed. A live local
  `say`-to-microphone smoke produced transcript hypotheses from the bundled helper
  with no unsupported-argument error. This is an acoustic local smoke, not a claim of
  a human-spoken test or a physical shortcut event.

### Current continuation — cognitive requests, read-only UI and compact floating surface (2026-09-29)

- Scope: separate answer-only, read-only UI, and action requests; introduce a bounded
  provider-neutral `UIInspector`/`ObservationAnswer` path; preserve semantic operations,
  exact literals, desired state and constraints through sequential UI steps; and replace
  the large diagnostic-first production interaction with a 48-point non-activating orb,
  concise answer card, native Settings surface, and explicit Diagnostics window.
- Files: `semantic_planner.py`, `runtime.py`, `ui_inspector.py`, `candidates.py`,
  `chooser.py`, `loop.py`, `verification.py`, Python tests, Swift protocol/overlay/app
  sources and tests, plus README, architecture, protocol and Part 2 result records.
- Architecture: read-only inspection creates no action candidates and does not launch
  or foreground the inspected app. Password-field values are removed from inspection.
  For actions, locally validated structured substeps and constraints pass through a
  fresh observe/decide/act/verify loop. Laya still receives only locally generated
  candidate IDs. The answer uses a separate bounded `answer` NDJSON kind under v1.
- Tests: `scripts/check.sh` passed **304 Python tests**, Ruff lint and format,
  Swift build, and **38 Swift tests**. `scripts/check-all.sh` passed the same suite,
  isolated packaging/NDJSON, **49 Mach-O** load-path audits, privacy audit and the
  required one-step CPU training smoke. The smoke changed weights, saved/reloaded a
  checkpoint and ran inference in **35.80 s** at **3428 MiB peak RSS**; it is a
  smoke-only result and no model improvement is claimed.
- Live Discord: through the canonical app's embedded CUA Driver **0.30.4**, the
  read-only question “Where is the mute button in Discord?” returned its bottom-left
  location and nearby controls with zero actions. “Am I muted?” returned unmuted.
  The explicit “Mute me in Discord” test selected the supplied Mute candidate, made
  one CUA click, and GoalVerifier observed `checked=true`; a fresh follow-up answer
  reported muted. No Discord-specific executor was added.
- Live Outlook limitation: Outlook is installed. Its unique inbox window was on a
  different Space. CUA's exact-window foreground call reported a verified foreground
  transition, but the next window snapshots still marked the content window off-space;
  Kio then abstained before creating a draft or entering fields. No email was sent. The
  live Outlook draft acceptance case remains open because Kio cannot currently obtain
  a stable visible snapshot of that window.
- SDL follow-up: rebuilt `/Applications/Kio.app` at **2026-09-29 04:02**, preserved
  bundle ID `local.companion.dev`, and passed strict signature plus isolated artifact
  checks after the structured-create update. The bundled SDL2-compat → SDL3 `SDL_Init(0)` no-audio smoke succeeded and
  the bundled `whisper-stream --help` exited successfully. Kio was relaunched from
  this exact bundle with its embedded CUA daemon healthy. This verifies dependency
  loading without recording audio; a fresh in-app microphone capture was not run, so
  the reported SDL popup is not yet closed by a live recording test.
- Limits: human-spoken input, the physical Option+Command chord, a live screenshot of
  the orb/answer card, and a live Outlook draft remain unverified in this continuation.
  The Laya checkpoint still reports an
  upstream invalid-temperature warning for `choice:11+`; affected confidence is
  uncalibrated. The semantic vocabulary and step adapters are bounded, so Kio is not
  yet a universal arbitrary-task executor.

### Current continuation — animated blob, subtle sounds, and semantic edge case (2026-09-29)

- Scope: replace the circular orb with a compact animated 2D blob; provide restrained
  idle, listening, working, completion, and attention states; add configurable local
  interface sounds; and resume semantic-planner hardening.
- Files: new `AnimatedBlob.swift` and `KioSoundEffects.swift`; updated `Companion.swift`,
  `README.md`, `docs/architecture.md`, semantic planner and tests, this status, and
  `docs/part2-results.md`.
- Architecture: a sampled SwiftUI vector path morphs at 30 fps; microphone level shapes
  the listening contour and three-bar mark. Work uses moving dots; completion and
  attention use check/exclamation marks. macOS `Tink`, `Pop`, and `Purr` cues play at
  volume 0.09–0.12 for listening, completion/answer, and attention. The General Settings
  toggle defaults on and disables all cues. No audio assets or dependencies were added;
  Kio remains silent and has no TTS.
- Semantic correction: explicit microphone requests to prevent transmission, such as
  “Could you prevent my microphone from transmitting audio?”, map locally to `MUTED`.
  A negative request does not produce a mute action. This is a planner result, not a live
  microphone action. The separate unfamiliar-state path remains bounded by Laya's enum
  choices and confidence gate.
- Commands: `scripts/check.sh`; `scripts/build-unsigned-app.sh`;
  `python3 scripts/check-artifact.py /Applications/Kio.app`; `scripts/check-all.sh`;
  real local Laya probe via the development environment.
- Results: `scripts/check.sh` passed **309 Python tests**, Ruff lint/format, Swift build,
  and **38 Swift tests**. `scripts/check-all.sh` repeated those gates, validated isolated
  packaged imports/NDJSON and **49 Mach-O files**, passed privacy audit, and completed
  the one-step CPU fine-tuning smoke in **37.10 s** at **3552 MiB peak RSS**; weights
  changed and checkpoint reload/inference worked. This is not evidence of model
  improvement. The real local Laya probe classified the file rearrangement task as
  `MOVE`/`FILE` at confidence **0.632**; the explicit microphone suppression request
  took the deterministic route at about **22 ms** without a model decision. The upstream
  `choice:11+` invalid-temperature warning remains.
- Artifact: canonical `/Applications/Kio.app` rebuilt at **2026-09-29 05:11 BST**;
  bundle ID `local.companion.dev`; app and embedded CUA signatures verified; pinned CUA
  Driver **0.30.4** SHA-256 matched `third_party/cua-driver.json`;
  `check-artifact.py` reported isolated Python 3.12.8/Torch 2.14.0 and no developer
  library paths.
- Live limits: Kio launched, but `cua.getApp("Kio")` timed out with `-10005`, so no
  screenshot of the actual overlay was obtained and no audible playback smoke was run.
  The macOS named sound resources resolved successfully. No physical Option+Command
  event, human-spoken transcription, CUA microphone change, or new live CUA task was
claimed by this continuation.

### Current continuation — targetless execution and safe live checks (2026-09-29)

- Scope: generic installed-app/browser resolution; targetless and frontmost/session
  context; semantic-step preservation through direct and UI execution; exact PID/window
  continuity; bounded same-app recovery; independent completion evidence; persistent
  CUA transport; and Whisper rolling-output assembly plus early safe voice clauses.
- Files include `target_resolver.py`, `runtime.py`, `loop.py`, `driver.py`,
  `semantic_planner.py`, `verification.py`, Swift voice/session code, new regression
  tests, and updates to README, architecture, protocol, packaging, and test strategy.
- Local gates: `scripts/check.sh` passed **343 Python tests**, Ruff lint/format,
  Swift build, and **46 Swift tests**. The final `scripts/check-all.sh` also passed
  isolated packaged imports/NDJSON, **49 Mach-O** audits, privacy audit, and the
  one-step CPU training smoke: weights changed, checkpoint reload and inference worked
  in **38.48 s** at **3501 MiB peak RSS**. This smoke does not show model improvement.
- Artifact: rebuilt `/Applications/Kio.app`; strict/deep `codesign` passed; the
  isolated artifact audit confirmed Python **3.12.8**, Torch **2.14.0**, pinned CUA
  **0.30.4**, and no developer library paths. Spotlight found exactly one matching
  bundle ID, `/Applications/Kio.app`. After relaunch, embedded CUA health was `ok`.
- Live targetless evidence: opening Spotify completed after the final rebuild and
  Spotify was restored as the foreground app. Its AX tree exposed no transport
  play/pause controls, and a read-only playback-state query could not determine the
  state, so playback was not changed. A Discord read-only question was answered with
  zero actions. The targetless Norbert Wiener search and `x.com` navigation completed;
  destination verification is covered by the direct verifier and runtime evidence
  propagation regression.
- Live limits: opening Notes succeeded after Launch Services moved its existing window
  onto the current Space, but note creation abstained because neither AX nor visual
  perception exposed a grounded new-note control; no note was created. Outlook is
  installed but its live process exposed no usable current-Space content window; no
  draft or message was created or sent. Photo Booth opened, but capture did not produce
  independently verified state or a new still image. Capture now presses only one
  uniquely labeled AX shutter and abstains after an unverified result; this behavior is
  covered by unit tests. The existing Photo Booth movie was preserved.
- Cleanup: Chrome History showed the two acceptance visits (Norbert Wiener and `x.com`)
  at 08:19 on 2026-09-29. The live History database was locked while Chrome was open;
  a CUA checkbox-selection call exited unsuccessfully and a fresh snapshot showed both
  test rows still unchecked. No broader history deletion was attempted. Notes, Outlook,
  and Photo Booth contain no test-created artifacts. Physical Option+Command and
  human-spoken voice tests were not performed or claimed.

### Shortcut-triggered voice crash fix (2026-09-29)

- Crash reports from 09:08:46 and 09:09:00 BST both identify `VoiceController.startStreamingMeter(token:)` on `RealtimeMessenger.mServiceQueue`; Swift raised an executor-isolation trap when AVAudioEngine invoked the tap callback off the main actor. This callback starts when the global Option+Command shortcut begins a streaming voice session.
- Moved tap-block construction to a `nonisolated` factory. Audio-level calculation remains on AVAudioEngine’s callback queue, and only the meter state update is hopped to `MainActor`.
- Verification: `swift build -c release` passed; `scripts/build-unsigned-app.sh` rebuilt and installed `/Applications/Kio.app`; strict code-signature verification passed; the canonical app relaunched and remained running, and embedded `health_report` returned `overall=ok`. The physical shortcut was not re-triggered as part of this fix.

### Runtime recovery and browser target correction (2026-09-29)

- The phrase “a new tab in Chrome” was incorrectly parsed with app hint `new`; fuzzy app resolution matched that to Apple News. New-tab parsing now extracts the browser name, and short non-exact app names cannot fuzzy-match unrelated apps.
- A compound browser request now preserves its explicit destination URL and routes a following search to the destination page. Planner inspection for “open a new tab in Chrome, go to youtube.com, and search minecraft” yields Chrome, a new tab, `https://youtube.com/`, then a page search for `minecraft`.
- Helper stdout disconnects, confirmed driver-transport loss, and an exited embedded daemon restart the local helper/runtime once and ask the user to retry the interrupted request; the app does not replay actions that may already have happened. Ordinary CUA/task errors and MCP request timeouts do not restart the daemon. A startup socket timeout reports that the runtime is not ready, leaving the supervisor's process recovery in control.
- Verification: Python source parsing, release Swift build, and strict signatures for the app and embedded driver passed. The installed app relaunched with its helper and embedded daemon; a read-only health probe returned `overall=ok`. No app actions or full test suite were run during this recovery.

### Shortcut crash and complete runtime regression (2026-09-29)

- Root cause: both same-morning Kio crash reports show `EXC_BREAKPOINT` / `SIGTRAP`
  on AVAudioEngine's real-time service queue. The streaming meter's callback created
  a `Task { @MainActor ... }`; Swift's executor-isolation check trapped on the audio
  thread. Kio then exited, disconnecting its embedded Driver and making the runtime
  recovery UI report a helper failure.
- Fix: the tap callback now captures only a lock-protected scalar meter and publishes
  the computed level. It never captures `VoiceController`, accesses actor state, or
  schedules a main-actor task. The existing main-actor silence monitor polls that
  scalar and updates UI/silence state. Regression tests cover bounded values and
  concurrent callback/UI reads.
- Browser correction: semantic search now preserves GLOBAL_WEB, NAMED_SITE, and
  CURRENT_SITE scope. “Search YouTube for Minecraft” resolves as named-site search;
  “Open YouTube and search Minecraft” stays on the opened site; a plain “Search
  Minecraft” remains global. The Chrome → new tab → `youtube.com` → search flow carries
  four step-specific source clauses and uses the fresh destination page for search.
  An unavailable named website resolves through the live browser inventory. No
  Apple-News fuzzy match is used for “new tab in Chrome.”
- Navigation verification now checks structured current URL, a native browser
  address field, AX document URL metadata, then an exact destination hostname in the
  page title. New-tab verification also accepts a fresh AX tab-strip delta when no
  structured tab ID is available.
- `scripts/check.sh`: **375 Python tests** passed; Ruff lint/format, Swift build and
  **48 Swift tests** passed.
- `scripts/check-all.sh`: repeated those gates; isolated packaged imports and NDJSON
  passed; all **49 Mach-O** binaries passed library-path auditing; privacy audit found
  no issues. One-step CPU training changed weights, checkpoint reload and inference
  worked in **36.65 s** at **3523 MiB peak RSS**. This is a packaging/training smoke,
  not evidence of model improvement. Laya's upstream `choice:11+` invalid-temperature
  warning remains.
- Canonical bundle: rebuilt `/Applications/Kio.app`; strict Kio and vendor Driver
  signatures and the 49-file artifact audit passed. Spotlight found exactly one
  matching Kio bundle. Kio remained running after launch; its embedded CUA 0.30.4
  returned `health=ok` through Kio's private socket.
- Live limit: the physical Option+Command chord and a human-spoken voice session were
not repeated after the fix. No live YouTube/Chrome action was run in this pass.

### Corrective media, visual search and app readiness pass (2026-09-29)

- Implementation: media candidate ranking now respects the requested `PLAYING` or
  `PAUSED` state, and primary transport labels provide state evidence without being
  clicked when the state is already satisfied. `ACTIVATE_CONTROL_ONCE` and `SEARCH`
  may use fresh capture-bound visual candidates. Current-site visual search focuses a
  freshly grounded region, then requires a fresh structured editable field for typing.
  `ensure_app_ready` continues bounded polling after one activation attempt, including
  delayed windows and slow Space/key-window transitions. Ordinary activation errors
  may request Launch Services once; transport loss still propagates.
- Regression coverage: 389 Python tests and 48 Swift tests passed in
  `scripts/check.sh`; Ruff check/format and Swift build passed. The focused changed
  Python modules passed 181 tests. Readiness tests cover delayed window appearance,
  delayed multiwindow key/main selection, off-Space transition, one activation, and
  transport-error propagation.
- Discord live: one-shot “press the mute button” dispatched exactly one accessibility
  click, verified the state change, and restored the original muted state. “Mute me”
  and “Unmute me” each dispatched one click and reached their requested states.
- Spotify live: opening succeeded. AX exposed 290 controls but no primary transport.
  CUA Perception ran twice and returned 149 regions each time without a Play/Pause
  target. “Play the song” abstained with zero clicks, so neither playback nor pause is
  claimed as live-tested.
- Browser live: global Google search for Norbert Wiener completed and a matching
  Google results URL was independently observed. YouTube opened, but site search did
  not complete: structured browser preparation returned `browser_consent_required`.
  A Chrome new-tab request did not produce an independently verified new tab. No
  YouTube search success is claimed.
- App readiness live: lowercase “open visual studio code” and “open system settings”
  both completed against the rebuilt embedded CUA. Outlook moved from an off-Space
  unusable window to a usable window after one Launch Services request and bounded
  polling. The installed Calculator was observed stopped and then opened successfully.
  An Outlook draft attempt did not
  establish an exact recipient field; no draft completion is claimed and no Send
  action was issued.
- CUA reported capture-bound visual click and browser APIs. Visual focus followed by
  structured typing is implemented and fixture-tested, but the live browser consent
  gate prevented verifying the site-search path in Chrome. The physical shortcut and
  human-spoken voice path remain user-only; they were not synthesized or claimed.
- Final `scripts/check-all.sh` passed on the implementation tree: 389 Python tests,
  Ruff check/format, Swift build and 48 Swift tests; isolated packaged imports and
  NDJSON passed; 49 Mach-O files had no developer library paths; the privacy audit
  reported 123 source/report files, 3 opt-in trajectories and no issues. The one-step
  CPU smoke changed weights, reloaded the checkpoint and ran inference in 36.95 s at
  3605 MiB peak RSS. This is only a packaging/training smoke, not model-quality
  evidence.
- Canonical `/Applications/Kio.app` was rebuilt and installed. Strict app and
  embedded Driver signatures passed; `check-artifact.py` verified pinned CUA 0.30.4,
  isolated Python 3.12.8/Torch 2.14.0, inert NDJSON and 49 audited Mach-O files. After
  launch, exactly one Kio process and one embedded daemon were present; the daemon
  health report was `ok`. Spotlight and a filesystem search found one bundle ID/path:
  `/Applications/Kio.app`.

### Typed Kio decisions, MLX backend, and video-parity fixtures (2026-09-29)

- Added the versioned Kio Decision Protocol V1: bounded semantic computer state,
  opaque candidate IDs, typed operation/target choices, completion and recovery
  decisions, redaction, and sanitized trajectory rows. The model receives neither
  executable CUA authority nor coordinates. Session referents now survive app
  switches and stale references are re-grounded before use.
- Added the native `laya-mlx` inference backend for Apple Silicon with the upstream
  Torch backend retained as fallback. Dependency and notices are pinned in
  `pyproject.toml`, `uv.lock`, `third_party/`, and the canonical app bundle. The
  benchmark records package/checkpoint revisions, backend configuration, precision,
  latency, memory, accuracy, calibration, candidate recall, and choice parity.
- Same-input Torch/MLX parity: **84/84 exact choices**, with the largest probability
  difference **0.003**. On the Kio V1 splits, MLX warm median latency was about
  **90 ms** versus Torch's **116–118 ms**, with about **0.93 GiB** versus **2.78 GiB**
  peak RSS. MLX cold load was **0.22–0.26 s** on these runs. Both backends chose the
  same benchmark answers; this does not mean those answers were always correct.
- On each 14-case V1 split, both backends scored operation **8/12**, target **6/6**,
  and combined decisions **10/14**; false high-confidence errors were zero. ECE was
  **0.090** on test and **0.128** on validation. The compact representation did not
  raise aggregate accuracy over the legacy baseline. These small fixtures are not a
  model promotion gate.
- Added the held-out reference-video parser fixtures: canonical **9/9** and natural
  variants **16/16**. These test intent, literal preservation, app context, and
  no-action courtesy handling only. They do not establish GUI action or full-video
  parity. The benchmark remains excluded from trajectory training/export.
- Existing phase-33 data converts to **47 sanitized rows** across seven task groups
  (**43 train, 4 validation, 0 test**). This is a plumbing sample, not enough data for
  a dedicated checkpoint; no Kio fine-tune or model-quality claim is made.
- Verification: `scripts/check.sh` passed **402 Python tests** and **48 Swift tests**;
  `scripts/check-all.sh` passed packaging/import and NDJSON checks, **52 Mach-O**
  library-path audits, the privacy audit, and the CPU training smoke. The canonical
  `/Applications/Kio.app` was rebuilt and `scripts/check-artifact.py` confirmed its
  bundled MLX backend and notices. The smoke is packaging evidence only.
- Live-safe status: Kio's embedded driver health returned `ok`. The natural
  conversational Notes open/create/title sequence did not return a completed result;
  one `Open Notes` route completed, but the multi-turn typed probe stopped before
  confirming creation or the `Hello` title. A read-only AX snapshot found no exact
  `Hello` value in the current Notes window. No note-creation success is claimed, and
  no Notes data was deleted. No live browser task, physical shortcut, human speech, or
  Photo Booth capture is claimed in this pass.
