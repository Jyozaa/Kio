# Kio architecture

The SwiftUI companion owns presentation, task state and cancellation. A Python 3.12
helper owns routing and orchestration. Versioned NDJSON over stdin/stdout isolates
these components. Stdout contains protocol messages only; diagnostic stderr must
never contain secrets or full private observations.

A targetless deterministic fast router handles installed-app discovery, validated URLs and
encoded search queries. Natural language also passes through a bounded local
semantic planner and TaskPlan before observe → normalize → bounded candidates →
local Laya choice → validate → policy → CUA execution → fresh observation.

CUA owns native/browser observation, identities, input and verification. The packaged
Kio host directly spawns the pinned vendor-signed CUA Driver 0.30.4 helper in
`serve --embedded` mode and exposes a private Unix socket to the Python helper's MCP
proxy. This makes Kio the macOS TCC responsible app. Source-development runs retain
the standalone CuaDriver fallback. The installed CUA tool schemas are discovered at
connection time; Kio branches on typed capabilities rather than a version string. A
schema indicates API support only; target state, permissions, capture identity and
optional extensions are checked separately. The release pin and audit are in
docs/cua-upgrade.md.

Candidate tables are single-use capabilities tied to an observation. The private
table retains Driver identities; models see bounded opaque IDs and descriptions.
Unknown, foreign, duplicate, stale and mismatched IDs fail closed. Refresh before
each action and discard the entire table after any execution attempt.

Laya runs in process, loaded once, with operation and compatible target heads.
Candidate construction semantically narrows ordinary decisions to at most eight
choices (hard cap ten). The default effective confidence floor remains 0.55,
accounting for operation and target. CPU fallback is supported. The loop
has a default 50-iteration ceiling, bounded history and stall detection. Cancellation is checked
before inference and every action, and after execution.

Gemini is optional BYOK and receives minimal text context only. Its only schemas
are generated_text(text) and guidance(focus). Literal text bypasses generation.
Recovery is at most one guidance attempt per task, followed by fresh
observation and a new local decision; unresolved uncertainty returns needs_user.
Neither model can supply executable code, shell commands, selectors or coordinates.
The current Phase 16 policy uses ALLOW/BLOCK; goal-scoped ordinary actions execute automatically.

On Apple Silicon arm64, Laya inference uses the pinned `laya-mlx` backend by
default after same-input fixture parity with upstream Torch; supported MLX
runtime errors fall back to Torch. A normalized backend interface keeps runtime
code independent of the inference implementation, and the model is loaded once
per helper. `KIO_LAYA_BACKEND=torch` explicitly selects Torch. Fine-tuning
continues to use upstream PyTorch. See [`laya-mlx.md`](laya-mlx.md) and the
measured [backend comparison](benchmarks/laya-backend-comparison.md).

Typed semantic planning is separate from target selection. The model-facing
`KioDecisionStateV1` contains bounded goal, app/window, referent, relevant
visible text, and recent verified history. `KioCandidateFormatV1` puts each
candidate's sanitized semantic description in the option itself and uses an
opaque per-observation ID. The verifier remains authoritative; Laya's goal-state
answer is only a hint when proof is unavailable. Repeated unchanged observations
may trigger one bounded, non-executing recovery hint. See the
[versioned decision protocol](kio-decision-protocol.md).

No screenshots/content are persisted by default. No TTS, paid Jev/TypeSafe API,
Apple Vision OCR worker, OmniParser, signing, or notarisation are required. The
single launchable product bundle is `/Applications/Kio.app`; CUA Perception remains
a separately installed, signed extension.

## References inspected 2026-09-26

- https://github.com/trycua/cua/tree/main/libs/cua-driver — standalone app, TCC,
  official CLI/MCP and generated SDK boundaries; installed Driver 0.30.4.
- https://github.com/NandhaKishorM/laya — Router.predict(state, questions), choice
  criteria maps and answer_confidence. Checkpoint is pinned by immutable revision; MPS/CPU latency is measured locally.
- https://github.com/farzaa/clicky — floating visual companion inspiration only.
- https://github.com/browser-use/jev-ultrafast — operation-specific target heads.
- https://github.com/awlevin/typesafe-computer-use — local factual preprocessing.

No upstream source code has been copied. See phase-status.md for implemented scope.

## Kio identity (Phase 11.0)

The product is Kio and the local artifact is Kio.app. The stable bundle identifier
remains local.companion.dev and owns the embedded CUA TCC grants. The helper's vendor
signature remains unchanged. The application-support root is
~/Library/Application Support/Kio/. Legacy prototype
state is copied without deleting its original; existing Kio state takes precedence.
The single future Keychain service identifier is Kio. Technical module names and
NDJSON v1 are unchanged.

## Unified perception (Phase 11)

The loop receives PerceptionResult from CompositePerceptionProvider. Its structured
provider uses a supported normalized DOM route when explicitly advertised by the
adapter, otherwise existing CUA AX. This installed CUA/Safari combination has no
verified normalized DOM action route; native web AX remains truthfully labelled AX.
Candidate construction still consumes the existing normalized Element/Observation.

Immutable PerceptionFrame binds image digest, target/window, generation, dimensions
and geometry. Its project-owned capture ID is NOT native execution authority.
VisualRegion carries the exact frame ID. Observations can contain structured-browser,
AX and visual evidence together. Agreeing detections merge provenance without copying
lower-authority action payloads; when AX and visual observations identify the same
control, candidates retain separate execution authority. Duplicate labels at distinct
positions remain separate. Visual escalation checks the active semantic operation,
target and available verifier evidence instead of treating any AX control as enough.
The production visual provider captures through CUA and consumes the separately
installed, publisher-verified CUA Perception `parse_visual_regions` contract. CUA
text and icon regions retain their source, confidence, dimensions and native capture
binding; icon classifications are not given invented semantics. The model chooser
receives only bounded local candidates and never a screenshot or coordinate.
If the optional extension is unavailable, visual routing fails closed. The former
screenshot OCR provider was removed from the runtime and package.

The local development virtualenv now lives under ~/Library/Caches/Kio/development-venv
(configurable KIO_DEV_ENV), avoiding observed offloaded/renamed Desktop dependencies.
Old virtualenv state is preserved. scripts/check.sh and run-macos.sh sync the same
locked environment; scripts/agent.sh runs its interpreter. This is development
runtime placement, not the self-contained Phase 19 artifact.

## Independent verification (Phase 13)

GoalVerifier returns VERIFIED, NOT_VERIFIED or UNKNOWN with bounded expected/observed
facts. Literal fields, requested options and Success must all match; a window title
alone is insufficient. Explicit expectations also support checkbox/toggle state,
appearance/disappearance, URL transition, running app and caller-authorized local
file existence. Unsupported/ambiguous goals remain UNKNOWN. These checks do not use
models. Evidence stays in task memory/results; durable recording is not enabled yet.

DONE cannot complete a task. NOT_VERIFIED causes bounded reobservation; UNKNOWN may
use one existing System-2 hint and otherwise needs_user. Direct app launch rechecks
running apps. Direct URL routing checks a native browser address field against the
requested destination; failure to observe it returns needs_user.

## Gemini boundary

Gemini is optional text-only System 2. It can generate requested prose or provide
bounded high-level guidance from short structured labels. Kio never uploads a
screenshot to Gemini, has no Gemini visual-perception setting, and does not use
Gemini as a perception backend. Visual understanding follows structured browser,
AX, then the signed CUA Perception extension. Gemini never directly controls the
desktop; CUA remains execution authority.

## Phase 16 autonomous policy (revised requirement)

The active user goal authorizes grounded ordinary actions. ActionPolicy returns
ALLOW/BLOCK only: explicit sends, submissions, uploads and edits run automatically.
Scope checks reject unrelated external effects; ambiguous equal-label targets,
secret entry, security-sensitive operations and final financial commitments block.
Search, product selection, basket navigation and non-secret checkout fields remain
automatic. No model can bypass policy or invent executable arguments.

Every chosen action is checked against its own single-use table, policy, a fresh
observation and freshly rebound Driver token. Policy is checked again on fresh
state, and Stop is checked immediately before execution. Old tables are discarded.
There is no approval delay or approval transfer. Historical approval work is
recorded in phase-status.md; the production broker and UI have been removed.

## Phase 17 inspection without execution

Opt-in trajectories use schema version 1 and a whitelist of structured metadata.
Execution payloads/tokens, screenshots and audio are absent. Sanitized corrections
are separate files anchored to the immutable original hash. Offline replay creates
non-executable description-only tables and calls only the local chooser. Dataset
exports normalize ephemeral candidate IDs and split by task group, not steps.
See docs/trajectories.md for exact commands and redaction limitations.

## Packaged runtime
Kio.app launches its bundled standalone Python in isolated mode, with locked native
Laya/PyTorch dependencies. Its Swift host owns a private runtime directory and
directly supervises `Contents/Helpers/cua-driver`; the Python helper connects only
through that host-owned socket. No separate CuaDriver.app is required by the packaged
artifact. First-run setup verifies manifests and real CUA/model health; models are explicitly
installed under Kio Application Support. Phase 36 adds a versioned onboarding state and
an automatically presented SwiftUI setup window hosted by AppKit, so the first-run flow
works on the supported macOS 14 minimum. Missing mandatory permissions open their exact
System Settings pane; a completed setup opens a focused repair view if Accessibility or
Screen & System Audio Recording is later revoked. Model installs are local, checksummed,
and display progress. Microphone and local voice remain optional; the global shortcut is
required for normal setup because it is Kio's system-wide push-to-talk entry point.
Keychain service Kio owns the optional
Gemini key. No secret enters NDJSON, trajectories or logs. Runtime model selection
is generic by default; explicit specialized checkpoints fall back on load failure.

## Candidate authority and target-local freshness

Structured browser, AX and signed CUA Perception may all contribute candidates for
one observation. A window-level surface summary remains useful for diagnostics and
metrics, but it does not own action authority. Every candidate privately carries the
fresh browser ref/session, AX element token, or visual capture binding needed for its
own execution path. Laya sees only opaque candidate IDs and short semantic context.

Before execution, Kio observes again, rebuilds candidates and semantically rebinds
the chosen target using its label, role, parent/region/nearby context, scope and
observed state. AX/browser actions use the new token/ref. Visual targets are parsed
again from a new native capture; unrelated pixel changes are allowed, but the target
must be uniquely re-identified and the new capture ID is used for the click. Kio does
not compare whole-window fingerprints or require identical image digests. CUA remains
the only execution authority, and completion is checked against fresh state.

Perception escalation asks whether the current SemanticStep has a compatible,
discriminating target and enough evidence for its verifier. A few unrelated AX
controls do not suppress CUA Perception. The chooser receives at most eight ordinary
candidates, with ten as the hard cap. No raw screenshot, coordinate, selector or
execution token reaches Laya. See phase20-results.md.

## Surface routing (Phase 22)

Each fresh observation is resolved into a surface identity and current capabilities
for diagnostics and routing metrics. This summary does not assign one authority to
the whole window. Candidate construction carries each structured-browser ref, AX
token or visual capture binding privately, so a mixed window can use the best source
for each target. The summary is recomputed after actions and state transitions,
including dialogs and transient menus. Surface classes come from observation evidence
and optional adapter hints, not an application allowlist. Ambiguous window targets
still require user input. Unsupported target actions fail closed.

## Browser selection and fallback (Phase 24 / K)

An explicit browser name is resolved against CUA's installed/running app inventory and
used for URL/search opening and destination verification. Missing or ambiguous app
names stop instead of falling through to the system default. Structured browser,
AX and capture-bound visual candidates can coexist; each carries its own authority.
If an explicit browser task receives
CUA's `browser_consent_required` or `next_action=browser_prepare`, Kio starts the
official exact-window `browser_prepare` flow automatically. Kio does not add a
redundant browser-access approval button; any genuine host grant remains inside
CUA/browser security. After the grant Kio retries the same goal from a fresh browser
state. CUA remains the source of truth for authorization and structured target IDs.
Preparation failure, refused consent or an unattested
route falls back to AX/visual perception. Tool schemas alone never claim a live
structured route.

## Cross-surface native dialogs (Phase 25)

Some supported apps expose an alert as a separate small `AXWindow` instead of nesting
an `AXAlert` or `AXSheet` in the content tree. Kio recognizes only a compact, bounded
window whose small accessibility subtree contains text and button controls, then
observes and targets that exact window with fresh CUA tokens. Before acting it
re-resolves the foreground dialog; a window change discards the pending decision.
After dismissal, the loop returns to the original content window and verifies the
result there. This changes target routing only; it adds no key, selector, or coordinate
authority.

Native file pickers that CUA lists as a separate window but cannot associate with an
AXWindow remain unsupported. Kio stops when the picker has no usable controls and no
native capture-bound click identity; it does not use OCR alone to click or select files.

## Global voice shortcut (Phase 26)

Kio uses a Core Graphics session event tap in `listenOnly` mode. The tap observes
only modifier changes and key-down events, returns each event unchanged, and retains
no key codes or characters. A local recognizer triggers once when aggregate left/right
Option and Command flags have both been held and then released without an intervening
ordinary key. Input Monitoring is checked at startup and must be explicitly enabled in
Kio; the app reports when the shortcut is unavailable. Kio requests microphone access
only after the shortcut begins voice capture. The current consent state can therefore
leave the voice phase at “Microphone permission…” without recording.

Core Graphics documents the session event tap at
[CGEventTapLocation.cgSessionEventTap](https://developer.apple.com/documentation/coregraphics/cgeventtaplocation/cgsessioneventtap),
the non-intercepting behavior of
[CGEventTapOptions.listenOnly](https://developer.apple.com/documentation/coregraphics/cgeventtapoptions/listenonly),
and the explicit
[Input Monitoring access request](https://developer.apple.com/documentation/coregraphics/cgrequestlisteneventaccess()).

## Menu-bar shell and voice overlay (Phase 27; current animated-blob continuation)

The default app surface is a menu-bar extra; the debug and setup windows are opened
explicitly from its menu. Voice and active task state appear in a lightweight AppKit
`NSPanel` with a SwiftUI body. The panel is borderless, non-activating, joins all Spaces,
and is full-screen auxiliary. It does not become the key window, so the frontmost target
app retains focus. The current `NSScreen` safe-area geometry positions a compact 48-point
2D animated blob below the notch when present or beneath the menu-bar safe area otherwise.
The non-activating panel follows display changes. A slow vector contour morph signals
readiness, microphone level modulates the listening blob and its three-bar mark, quiet
dots indicate work, and check/attention marks show results. Subtle low-volume macOS
interface sounds mark listening, completion, or attention; the user can disable them in
Settings. These are local UI effects only: Kio has no speech output or TTS. A read-only
answer may briefly expand into a small answer card. Task completion retracts the panel.
Normal use stays out of the developer diagnostics window. Transcript review is an opt-in
UserDefaults preference that defaults to false, so local transcription submits
automatically by default. Escape cancels permission/listening/transcription, and the
modifier chord finishes an active listening capture.

## Request modes, semantic plans and read-only UI inspection

`SemanticTaskPlanner` separates `ANSWER_ONLY`, `OBSERVE_AND_ANSWER`, and `ACT` before
candidate construction. Arithmetic questions use a bounded local grammar. UI questions
go through structured browser state, AX, then CUA Perception and `UIInspector`; this path
does not launch or focus an app, create action candidates, or expose CUA tokens to its
answer formatter. The inspector copies bounded labels, roles, values and states, strips
password values, and derives spatial/nearby descriptions from observed geometry.

Action plans keep enum-validated operations and object types, exact extracted literals,
desired state, per-step parameters, constraints, and completion conditions. The runtime
adapts plans to ordered UI subgoals and passes each original semantic step and plan
constraints into candidate selection and `ActionPolicy`. The executor reobserves and
verifies after every action rather than executing a precomputed UI sequence. Laya's
outputs remain constrained to locally supplied candidate IDs. Unresolved semantic
interpretations use a bounded question over supplied enums; they do not produce code,
selectors, coordinates, or executable plans. The supported operation mappings remain
finite, so unfamiliar or ambiguous workflows may still return `needs_user`.
For an explicit photo capture step, one uniquely labeled AX shutter control can be
selected directly from the typed intent; multiple controls and visual-only targets
remain on the normal chooser and confidence path.

## Local voice command validation (Phase 28)

Microphone permission is checked when voice capture begins and requested only when
macOS reports `notDetermined`; denial leaves typed commands available and exposes a
System Settings path. The verified local audio chain captured three controlled
acoustic stimuli from speakers with the built-in microphone, ran local Whisper and
completed deterministic app launch, browser search and a multi-step CUA task. The
stimuli were synthesized by macOS `say`, not spoken by a human. Voice context never
changes execution authority: app/process resolution remains deterministic, duplicate
same-bundle process records must resolve to one active instance, and ambiguity fails
closed.

## Conversational session context (Phase 29)

The helper retains a small in-memory `SessionContext`: current app/process/window,
last verified page, last completed goal, a few recent quoted entities/URLs/apps, and
bounded object/text references. It expires after ten minutes of inactivity and weakens
when the remembered app or window disappears or the user switches apps. Common
follow-ups such as searching in the browser just opened, returning to the last verified
page, and naming a known newly created item are resolved deterministically. Context is
not sent as a historical trajectory to Laya and is not persisted. It selects semantic
intent/target only; every computer action still needs a fresh observation, newly built
single-use candidates, capability routing, policy and CUA validation.

## Dogfood run-label data (Phase 33)

Opt-in fixture recordings may target an explicit local directory for development
evaluation. Exports retain run-level splits, and replay never receives a CUA driver.
AX scroll goals use a scroll surface only when the observation supplies a fresh native
Driver token; that structured route avoids OCR noise and does not introduce arbitrary
pixel control. Page-level scrolling is tested; nested scrolling remains dependent on
the concrete controls exposed by CUA.

## Target and window resolution (Phase 42)

Normal computer-use commands do not require a target-app field. `TargetResolver`
uses a semantic app hint, an installed app mentioned by the user, an optional
diagnostic override, the current task's exact app/PID/window, a referent-scoped
recent object, a unique active app, relevant session context, and browser inventory.
It returns no target when the live evidence is tied or unusable. Browser detection
uses explicit CUA inventory metadata or installed bundle metadata that both handles
web-navigation schemes and opens HTML documents; a general link handler alone is
not treated as a browser. No product-name list is used.

Window selection prefers the exact task window, one active/key/main window, one
visible current-Space content window, then uniquely stronger observed evidence.
Sequential steps keep the resolved PID and window in `TaskExecutionContext`.
If an idempotent step encounters a stale or missing window, orchestration can
rediscover the same app and one usable window, then reobserve and replan once. Each
new loop builds fresh observations and tokens; a failed connection is never used to
replay an action with old authority. Off-Space windows still stop when CUA cannot
make the requested surface available.

## Long-lived local runtimes and early voice (Phase 42)

The helper opens one MCP connection to its Swift-owned CUA daemon after startup
health and closes it when the helper exits. A transport exception discards the
connection; the next use reconnects. An operation with an uncertain result is not
automatically repeated. Browser sessions and UI observations remain task-scoped,
and every action still requires a new capture/observation and fresh token.

After a successful startup health check, the helper starts one background Laya load
when the app supplied a verified local model manifest. A task that needs Laya waits
for that same load. Deterministic app open, search and URL steps do not wait on it.
The local 16 GB Mac measurement was 5.6 seconds cold load, 1.95 GB maximum RSS and
3.14 GB peak footprint in an isolated process; host memory pressure reported 39%
free before the load. The packaged prewarm is one instance, not a duplicate.

Streaming Whisper output is assembled as rolling terminal hypotheses, including
split ANSI erases, carriage returns, UTF-8 chunks, segment boundaries and overlap.
An input-level meter applies a bounded no-speech, trailing-silence and 30-second
maximum capture policy. A stable transcript can yield multiple safe semantic
clauses; clauses execute serially and each completed clause is removed from the
final transcript before remaining work is submitted. Explicit negation and
read-only questions cannot trigger early actions. Transcript-review mode disables
early execution.

## User-facing errors and diagnostics (Phase 42)

Runtime errors travel as a concise user message plus a bounded `error_code`. The
normal blob view displays the user message; the diagnostics panel displays the
stable code. Transport, stale-state and target failures therefore remain
actionable in logs/diagnostics without exposing internal codes as ordinary copy.

## Semantic effects, site search and app recovery

Each `SemanticStep` carries its own source clause, operation, target and parameters
through perception, candidate building and fresh re-grounding. Explicit “press” or
“click” requests become `ACTIVATE_CONTROL_ONCE`; desired conditions such as “mute
me” and “play the song” remain `SET_STATE`. An `EffectLedger` caps edge-triggered
activation at one dispatch per step and records attempted mutations. Unknown
verification after a one-shot click returns a limited-verification result; it never
causes a second click. Creation, typing, tab creation, sending and deletion likewise
do not replay automatically after an uncertain dispatch.

Search plans retain scope. A named or current-site search uses that page's search
field and checks the resulting URL or newly observed matching results; global web
search remains a direct deterministic route. Browser URL and tab metadata are kept
for verification even when structured browser state has no actionable page elements.
If structured browser preparation is refused or unavailable, Kio continues with fresh
AX and visual evidence where possible; preparation failure and request timeout alone
do not restart the runtime. Only a confirmed transport failure reaches the host's
runtime-recovery path.

App names resolve against the live installed-app inventory, independent of title
capitalization. `ensure_app_ready` reuses and activates a running app, then rechecks
its windows; when none or several are visible it requests presentation and observes
again before returning a bounded ambiguity result. The task context retains the
selected process and window across ordered steps.

## Shortcut audio callback safety

The global Option+Command shortcut begins the streaming voice session. AVAudioEngine
invokes its meter callback on a real-time service queue, so that callback now computes
the level and publishes one bounded scalar through a thread-safe snapshot. It does not
capture `VoiceController` or enter the main actor. The main-actor silence monitor polls
that value at 100 ms intervals and updates the overlay. This prevents an executor
isolation trap from terminating Kio during shortcut use; the audio callback stores no
audio samples or transcript.

## Media, visual fallback and readiness correction (2026-09-29)

Media action ranking is based on the requested state: `PLAYING` promotes Play,
Resume and Start playback, while `PAUSED` promotes Pause. A primary transport control
showing Pause is evidence that playback is already playing; a primary Play or Resume
control is evidence that playback is paused. These are verifier observations, not
action candidates, so an already satisfied state needs no click. Row-level Play
controls do not establish the state of the primary player.

Typed `ACTIVATE_CONTROL_ONCE` and `SEARCH` steps can use capture-bound CUA Perception
regions. The loop refreshes Perception before activating a visual target and binds the
click to that new capture. Site search can use a visual region only to focus the field;
it then requires a fresh editable AX/browser field before typing and verifies the
entered query. Without that structured typing authority, it fails without blind
typing. These routes are regression-tested. Live Chrome page search remains unproven
because the embedded browser route required profile-access consent.

`ensure_app_ready` keeps polling to its bounded deadline after its single activation
request, including after ordinary activation refusal and a one-time Launch Services
request. It accepts delayed windows, Space transitions and key/main window changes;
confirmed transport loss still propagates separately. Unit coverage includes delayed
window appearance, delayed foreground selection, minimized/off-Space recovery, and
preserving transport failures.
