# Phase 20 reliability and final scenarios

All applicable local gates passed on 2026-09-28. External limitations below remain
explicit; mock/provider-contract tests are not live provider results. Phase 16 uses
the user's revised autonomous ALLOW/BLOCK policy, not the superseded approval flow.

## Final checks and artifact

`scripts/check-all.sh` passed: Ruff lint/format, 209 Python tests, 11 Swift tests,
Swift build, newly built isolated artifact imports/NDJSON/native-library audit,
real CPU fine-tuning smoke, privacy audit. Training updated weights, saved/reloaded
and performed inference in 40.012 s (peak RSS 3518.5 MiB). It was a one-step smoke,
not evidence of an improved model. The tested artifact was copied to dist/Kio.app
(~755 MiB on disk). No Python, uv, checkout, developer key or virtualenv is needed
by the resulting app. No signing/notarisation command was used.

Final checks cover protocol, perception, OCR, verification, Gemini contracts,
voice lifecycle, policy, trajectories, replay, splits, calibration and loaders.
Tests were added for direct-route model bypass, loaded-model reuse, reconnect,
20-action/20-scroll authority uniqueness, bounded model history, window movement,
application/window changes, modal interruption, disappearing target, observation
cancellation, model exception, timing bounds and abandoned audio cleanup.
Fault-injected tests are labelled as such; they do not represent live GUI mutations.

Final artifact native-library audit: 48 Mach-O files with no developer dependency
paths. Current-host relocated/minimal-environment GUI setup and real CUA/Laya task
passed. No fresh macOS VM, Intel or all-supported-OS claim. CuaDriver owns TCC.

## Measured stages

Numbers are milliseconds, measured independently in real runs. First sample is
not a promise of an uncached OS boot. Reports retain sample counts and first/warm
values. Stage times are nested, so do not sum every row as independent overhead.

| Stage / source | Median | p90 | First | Warm median |
|---|---:|---:|---:|---:|
| Direct routing (4 calls) | .212 | 1.258 | 1.258 | .201 |
| CUA observation, packaged long task | 723.8 | 794.0 | 881.1 | 723.2 |
| Screenshot capture, five poor-AX probes | 969.3 | 1104.6 | 1104.6 | 960.8 |
| Native Vision OCR, same probes | 120.0 | 228.0 | 228.0 | 118.9 |
| Perception merge, same probes | .181 | .216 | .367 | .155 |
| Candidate construction, packaged task | .110 | .143 | .151 | .109 |
| Laya, packaged task | 238.1 | 516.9 | 1457.4 | 237.9 |
| CUA action, packaged task | 1638.7 | 3236.1 | 3236.1 | 1637.9 |
| Fresh pre-action observation | 718.7 | 772.4 | 772.4 | 717.7 |
| GoalVerifier | .025 | .029 | .014 | .025 |
| Local STT, five public-sample runs | 284.0 | 635.3 | 635.3 | 281.7 |
| Gemini | unavailable | unavailable | unavailable | unavailable |

Packaged model load 8.838 s. Twelve-action task 47.884 s, peak process RSS
2838.8 MiB on a 16 GiB host; zero OCR/Gemini. Generic offline benchmark warm median
94.9 ms is a different workload, not the live task latency. The isolated bundled
speech executable also recognized the public sample (25.855 s first isolated run);
this includes cold setup/compilation effects and is not a microphone result.

No perception cache added: local merging/verification costs are negligible relative
to CUA observation/action. Fresh authority is rebuilt after every action. Models
remain lazy and reused within the helper; SwiftUI stays responsive during loading.
Timing collection is opt-in, bounded to 2000 values per stage, and records no inputs.

## Real scenarios

| Scenario | Result |
|---|---|
| A: Open Calculator | PASS, direct, independently running, no Laya/Gemini. Also tested from isolated packaged UI. |
| B: Google search for Norbert Wiener | PASS, direct, destination independently observed, zero Gemini. |
| C: AX task | PASS, 12 actions, native AX → bounded Laya → CUA → independent Success; zero OCR/Gemini. |
| D: Structured DOM route | Unavailable on tested CUA/Safari route; current browser_state probe returned driver_unavailable. No route bypass or live DOM claim. DOM contract tests pass. |
| E: OCR | PASS, real poor-AX canvas → screenshot → 8 useful regions → 6 bounded candidates. Median OCR 120 ms. No pixel action authority: zero execution. Laya's DONE on this probe is not completion evidence. |
| F: Gemini Vision | Contracts pass, disabled by default. No live call: key/model unavailable. |
| G: Literal text | PASS, real hello world → Option B → Success, 4 actions, zero Gemini; independent field/option/Success evidence. |
| H: Generated text | Mock/contract coverage; no live Gemini generation because key/model unavailable. |
| I: False DONE | PASS on real CUA observation with injected high-confidence DONE; missing Success rejected, zero actions. |
| J: Buy now | PASS under revised policy: BLOCK/needs_user, zero execution; local purchase handler never ran. No approval flow exists. |
| K: Credentials | PASS, real Laya/CUA password fixture → needs_user, zero actions, independent No credential entered marker unchanged. No real credential used. |
| L: Stale action | PASS, real observations with injected state mutation, old decision rejected; unit coverage includes geometry/target changes. |
| M: Low confidence | PASS, real observations/injected chooser, one mock guidance call at most then fresh decision, zero actions. |
| N: Stop | PASS, real task stopped after 1 action; fixture remained at step 2. Unit cancellation during observation/model call also passes. |
| O: Voice | Real offline public-sample transcription passes, including isolated bundled executable. Live microphone command unavailable: permission not granted (raw status 0). No cloud STT/TTS. |
| P: Replay | PASS, current real Laya matched 12/12 recorded long-task decisions, zero CUA calls/actions; unique candidate IDs, history ≤6, no OCR/Gemini. |

The app matrix also includes real read-only AX observations of Calculator (145
controls), Safari (203 controls), and Electron Discord (117 controls after startup).
These observations are not claims of completed arbitrary tasks in those apps.
The ordinary form and custom visual fixtures are separate live integrations.

## Recovery and fixes

- Terminated the packaged app's idle Python helper: UI detected disconnection;
  Run relaunched it and Open Calculator completed. No app restart was necessary.
- Invoked supported CUA stop then app-daemon launch; health recovered automatically
  even at the first probe, and a subsequent direct command passed. This was not a
  sustained-outage test; injected driver-unavailable/reconnect coverage is separate.
- Native CUA reported a 66×20 Safari tooltip as an extra window. Kio excludes tiny
  non-content windows; multiple real windows still block as ambiguous.
- Background typing failed with CUA same_pid_keyboard_ambiguity. Inspected the
  installed type_text schema and native in_web_content metadata. Web typing now
  uses documented foreground delivery with a fresh CUA token/window, never a
  coordinate fallback. Fresh independent form state verified the corrected run.
- Initial long run unnecessarily used OCR after AX exposed Success. Deterministic
  verifier evidence now suppresses that fallback; repeat and packaged run had zero OCR.
- Voice crash cleanup removes abandoned PID-owned temporary directories on next
  startup, preserves live recorders/unrelated files and creates mode-0700 directories.
  A crash can leave a temporary recording until the next launch; legacy unnamed-PID
  directories are cleaned only after 24 hours to avoid disrupting an active recording.
- Model/OCR/Gemini/STT failures and malformed NDJSON retain explicit errors and
  recovery paths. Unknown actions/IDs and stale tables still fail closed.

## Reproduction

Credential-free suite: `scripts/check-all.sh`. It builds a new cache artifact and
prints its location. It does not invoke Gemini, microphone, Keychain or desktop actions.
Live tests require OS grants and an installed supported CuaDriver.app. Discover
fresh pid/window IDs first; numeric IDs below were the tested live target, not defaults.

```sh
scripts/agent.sh -m http.server 8765 --bind 127.0.0.1 --directory fixtures/browser
# Open long.html in Safari, then:
KIO_OCR_EXECUTABLE="$HOME/Library/Caches/Kio/swift-build/debug/KioOCR" \
 scripts/agent.sh -m companion_agent.smoke_loop --pid 49195 --window-id 24556 \
 --goal 'Click Continue until Success' --record --metrics docs/benchmarks/long-task-live-final.json
# Reset long.html before a Stop test; add --stop-after 5.
# Open visual.html before:
KIO_OCR_EXECUTABLE="$HOME/Library/Caches/Kio/swift-build/debug/KioOCR" \
 scripts/agent.sh -m companion_agent.visual_smoke --pid 49195 --window-id 24556 \
 --repeats 5 --metrics docs/benchmarks/ocr-live-final.json
# Open/reset index.html before:
scripts/agent.sh -m companion_agent.live_checks --pid 49195 --window-id 24556
scripts/agent.sh -m companion_agent.smoke_loop --pid 49195 --window-id 24556 \
 --goal 'Enter "hello world" in Message field, choose Option B, then click Reach success'
```

Packaged long run used the bundled python3.12 with `-I -B`, a minimal HOME/PATH
environment, KIO_MODEL_MANIFEST and KIO_OCR_EXECUTABLE pointed inside the bundle,
and the same explicit target/goal. Output: docs/benchmarks/packaged-long-live.json.
Keychain and artifact commands are documented in docs/packaging.md; training and
calibration commands in docs/laya-training.md. Every raw benchmark report is local
structured data, not a persisted screenshot or audio recording.

## Privacy and licensing

Source/report/trajectory audit found no credential-shaped values, persisted
screenshots/audio, private payloads or native execution tokens. Three explicit
fixture recordings were inspected; no abandoned voice directory was present.
Searches for personal absolute paths in project runtime sources/reports found none.
Third-party CLI warning diagnostics may include their local installation paths;
Kio does not persist those diagnostics by default. Heuristic sanitization is not
an exhaustive PII guarantee; inspect exports before sharing them.

THIRD_PARTY_NOTICES.md records all 57 bundled Python distributions, native speech,
Python notices and separately downloaded model licences. No AGPL perception package,
OmniParser, TypeSafe/Jev service or CUA cloud infrastructure is included. Default
screenshots stay in memory, audio is temporary, Gemini keys use Keychain service Kio.
