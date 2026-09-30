# Kio typed decision protocol

`KioDecisionStateV1` and `KioCandidateFormatV1` are the frozen model-facing
schemas for this implementation. The source of truth is
`agent/src/companion_agent/decision_protocol.py`.

## State and options

State is a compact JSON object with a bounded task/subgoal, application name and
window title, surface kind, current referent, up to three goal-related visible
labels, recent verified steps, modal/editable/selection flags, and candidate
count. Goal text is capped at 400 characters; history, labels, and other fields
have their own limits. Common credentials, email addresses, and phone numbers
are redacted. Raw accessibility trees, screenshots, coordinates, element IDs,
and execution tokens never enter the prompt.

Controls are represented only in the choice criteria. Each per-request ID is an
opaque `c_N`; the response is mapped back to a private candidate capability and
validated against the exact observation before policy and fresh re-grounding.
Descriptions include a sanitized label, human-readable role, checked/selected
state, native/browser/dialog surface, and available parent/region/container/row
or nearby-label context. The regular target path remains capped at eight
choices. The 30-choice benchmark is diagnostic-only.

## Decision families

| Family | Choice contract | Effect |
|---|---|---|
| `NEXT_OPERATION` | Semantic planner vocabulary such as OPEN_APP, CREATE, SET_FIELD, SEARCH, NAVIGATE, CAPTURE, WAIT, REPLAN, NEEDS_USER | Chooses a semantic next step; deterministic direct routes remain first |
| `TARGET` | Operation-specific observed candidate IDs | Chooses a target only; never returns a selector or action payload |
| `GOAL_STATE` | SATISFIED, NOT_SATISFIED, UNCERTAIN | Hint only when deterministic verification is UNKNOWN; cannot complete a task |
| `RECOVERY` | WAIT_FOR_TRANSITION, REOBSERVE, NEEDS_USER | Non-executing hint after a repeated unchanged observation |

The control chooser still has a distinct bounded CUA-operation decision for
legacy unstructured UI steps. When a semantic plan fixes the operation, it asks
only for a compatible target. Independent policy, one-shot effect accounting,
fresh observation, and deterministic verification remain authoritative.

The train-row schema is `kio-decision-v1`. Each supervised decision carries a
decision family, question, expected label, task-group hash, trajectory ID,
step index, app family, and provenance. Exports include only corrected rows or
steps that executed, changed state, were independently verified, and completed.
Split assignment is deterministic and by task ID so a task never crosses
train/validation/test. Video-parity fixtures are explicitly excluded.

## Compatibility

Specialized Kio checkpoints must include `kio_model.json`, exact state and
candidate schema identifiers, upstream model revision, dataset and weights
hashes. A missing or incompatible manifest is rejected and the generic pinned
checkpoint is used. The base checkpoint is not fine-tuned or promoted in this
change.
