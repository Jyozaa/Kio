# Dependency-aware test strategy

During implementation, run the smallest tests that cover the changed boundary.
Python changes start with the affected `agent/tests/test_*.py` files; a Swift
subsystem change starts with its matching XCTest filter and a build when source
integration requires it. UI geometry changes run geometry and state tests. Intent
compiler work runs compiler and parser tests. CUA lifecycle changes run Driver,
setup, and process-lifecycle coverage. Voice changes run voice/STT tests.

Semantic-control changes cover candidate-level browser/AX/visual authority, mixed
sources, <=8 ordinary choices, contextual duplicate labels, target-local fresh
re-grounding, search scope, independent URL/tab verification, and effect-ledger
replay limits. Shortcut voice changes cover the realtime audio callback boundary:
the AVAudioEngine tap may publish a scalar but must not enter the MainActor or touch
controller state; the main-actor monitor owns UI and silence updates.

Do not rerun unrelated Laya training, package relocation, browser matrices, long
workflows, or privacy audits unless the code change can affect them. Reuse pinned
environments and checksum-verified caches. Each phase still needs its targeted
unit/integration checks and one relevant live smoke where the phase requires one.

For target resolution and semantic dispatch, cover targetless requests, explicit
app mentions, frontmost/session context, one-step and compound metadata, exact
PID/window continuity, stale-window recovery, field literals, and independent
completion checks. Voice changes cover rolling terminal output, split UTF-8/ANSI
sequences, silence end detection, stable clause execution, reconciliation, negation,
and fresh invocation state. CUA lifecycle changes cover one warm connection, close,
and reconnect after transport failure without replaying an uncertain action. Prewarm
tests verify direct actions do not wait for the shared single Laya load.

Run `scripts/check.sh` after shared-runtime or native-host changes. Run
`scripts/check-all.sh` once at the final milestone gate, after code, documentation
and packaging have stabilized. Keep OS permissions, genuine microphone/keyboard
events, and external-application checks separate from credential-free checks. Report
unit/parser evidence separately from live app behavior; restore media state and remove
acceptance artifacts where safe. Report unavailable user-only and third-party gates
as unavailable rather than inferring success.

For playback, test action ranking separately from primary-transport state evidence:
Play/Resume are actions for `PLAYING`, Pause is an action for `PAUSED`, while a
primary Pause label proves `PLAYING` and a primary Play/Resume label proves `PAUSED`.
For visual activation, assert a new capture is perceived before the single dispatch.
For visual site search, assert fresh AX/browser editability after focus and no typing
when that authority is absent. App readiness tests should model delayed window
appearance, off-Space transitions, and key/main changes after one activation request;
ordinary activation errors must not be confused with transport loss. Live browser
checks must separately record profile consent, actual query submission, and result
verification; a successful planner or navigation is not a live site-search result.
