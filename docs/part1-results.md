# Part 1 results

Verified locally on 2026-09-27. Phases 1–10 implemented; phases 11–20 not started.
Gate-by-gate history and exact commands are in [phase-status.md](phase-status.md).

## Architecture and working capabilities

SwiftUI owns goal input, target app selection, status panel, Stop/Reset and blocked
confirmation UI. A persistent Python subprocess communicates over bounded v1
NDJSON. Deterministic app/URL/Google search routes bypass Laya and Gemini.

Other tasks use CUA observations → local normalized state → bounded single-use
candidate tables → real local Laya operation/target heads → confidence and safety
validation → fresh observation → fresh CUA token execution → observed verification.
Explicit compound instructions are split locally into pending subgoals. Models do
not supply tools, code, selectors, coordinates or native tokens. Default limits:
30 targets per operation, confidence 0.55, 50 iterations, six history entries.
Stalls and uncertainty stop; configured System 2 gets at most one recovery hint.

Optional Gemini has only generated_text and guidance schemas with minimal text
context. Generated text is re-decided against fresh state. No executable approval
route exists for consequential actions. No keys or screenshots are persisted.

## Versions

Python 3.12.8; Swift 6.3.3; external CUA Driver 0.23.2; Laya 0.3.20;
MCP 1.30.0; pytest 8.4.2; Ruff 0.16.9. All Python dependencies are pinned with
hashes in agent/uv.lock. Model: convaiinnovations/laya, immutable revision
`55cf4c4ebb4ebe31b2550e8bdf3bd21b99753851`. Tested on MPS with CPU fallback implemented.

## Tests and demos

- Final Python lint and format pass; 95 unit/integration tests pass.
- Swift build passes; 5 XCTest tests pass.
- Real CUA health is ok; latest native Safari observation contained 303 indexed
  controls. Earlier Calculator observation also passed. No screenshot saved.
- Real Laya evaluation: 9/10 correct. The missed scrolling decision had confidence
  0.296 and would not execute at the default 0.55 threshold.
- Real simple multi-step CUA/Laya smoke: Start → Continue → Success, two actions.
- Real full fixture: entered hello world, opened Delivery, selected Option B,
  clicked Reach success; completed in four actions with verified state.
- Real generated-text typing: local Laya + CUA, one mocked System-2 response,
  one input action; fixture input handler independently echoed the greeting.
- Live-observation safety harness: mock decisions over real CUA state; purchase
  blocked with zero actions; injected observation change rejected with reobserve;
  low confidence stopped after one mocked hint; cancellation during decision
  stopped before action. Purchase handler remained untouched. Stale observation
  injection is not a claim that a real page race was induced.
- Automated integration tests also cover repeated no-op stalls, malformed
  decisions/protocol, single-use IDs, provider failures, subprocess cancellation,
  disabled/duplicate/off-window controls, limits and minimal System-2 schemas.
- Real UI: Open Calculator completed, Buy now showed blocked confirmation, and
  Stop during a loop returned idle/Stopped. Screenshots inspected in memory only.
- Real direct routes: Calculator opened; Google search result title independently
  observed. Both bypassed Laya and Gemini.

| Demo | Gemini calls |
|---|---:|
| Open Calculator / URL / Google search | 0 |
| Literal full fixture / simple multi-step | 0 |
| Generated greeting | 1 mocked generation; 0 live |
| Buy / stale / Stop checks | 0 |
| Low confidence with configured mock | 1 mocked guidance; 0 live |

No GEMINI_API_KEY was configured, so no live Gemini request was made. Mocked
contract/error coverage is not presented as a live provider smoke.

## Measured Laya latency

Initial download/load: 39.4 s; first inference: 2.43 s; initial warm median: 145 ms.
Final clean-process run with cached weights: load 5.172 s; first decision 0.666 s;
warm median 102 ms, 90% accuracy on the ten-case corpus. Download/cache state
explains the difference; these are local measurements, not performance promises.

## Run locally

From the repository root: `scripts/run-macos.sh`. See README.md for prerequisites,
fixture commands and optional environment variables. `scripts/check.sh` reproduces
lint, formatting, Python tests, Swift build and Swift tests in new processes.
Real driver/model/fixture smoke commands are separately opt-in and require a
current explicit target window; window IDs must be rediscovered after app restarts.

## Limitations before phase 11

- Tested native AX route in Safari and Calculator; not universal browser/app support.
  CUA refused isolated Chromium with browser_route_unavailable/vendor attestation.
  No bypass or legacy browser mutation was enabled.
- Safari native dropdown selection requires CUA's guarded foreground AXPick,
  which briefly fronts the target and restores focus. Background AX and set_value
  attempts failed; this is recorded rather than hidden behind a mock.
- Completion verification is deliberately narrow (literal/single-field equality
  and explicit Success marker plus requested field/option state). Other DONE
  decisions return needs_user. Dynamic/custom controls may be unsupported.
- Laya's pinned checkpoint warns that choice counts 11+ have an invalid calibration
  temperature clamped by upstream to 0.5. Confidence for those entries is uncalibrated;
  local safety checks remain mandatory. The chooser is not perfectly accurate.
- AX availability/visibility is limited by the upstream snapshot; nested clipping
  and semantic browser coverage are not fully general. Screenshots/perception fallback
  are not implemented. An action already in flight cannot be undone by Stop.
- One visible window per named app is required. Model loading and CUA calls can delay
  cancellation acknowledgement, but cancellation is checked before the next action.
- No live Gemini verification without user configuration. No paid Jev/TypeSafe API,
  copied upstream code, TTS, OmniParser, signing/notarisation or distribution work.
  Broader autonomy and phases 11–20 remain deferred.
