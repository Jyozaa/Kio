# Phase 33 dogfood corpus and error analysis

The dogfood runs use only the local browser fixtures. Recording was explicitly opted
into and written under `fixtures/trajectories/phase33/`; seven existing user-support
trajectories were not opened or used. Recordings contain structured observations and
decisions, no screenshots, audio, execution payloads or native CUA tokens. The fixture
text is synthetic and has no external submission.

## Verified trajectories

Seven task/run groups completed with independently verified outcomes, totaling 24
executed decisions:

| Task class | Runs | Actions | Independent evidence |
|---|---:|---:|---|
| Form: type, selection, completion | 2 | 5 | Exact field value; Option B; Success |
| Long sequential workflow | 1 | 12 | Fixture audit and Success |
| Native confirmation across browser surface | 1 | 2 | Success after the fresh native dialog action |
| Page scrolling | 1 | 1 | Independent page-bottom Success marker |
| Single field entry | 1 | 1 | Exact field value |
| Start/Continue workflow | 1 | 2 | Success |

These labels were re-reviewed against the complete task outcome and exported using the
existing immutable trajectory-correction mechanism. The original trajectories remain
unchanged. Export: `fixtures/calibration/phase33-export-v2/` (train 6, validation 13,
test 5 action rows). The deterministic split seed is 418 and assigns whole runs, never
individual steps. Run counts are train 2, validation 2, test 3. No run ID appears in
more than one split. This small fixture corpus is a reproducibility smoke, not a
representative population benchmark.

To reproduce a run, start the fixture server, open the requested path in Chrome, and
use the live target window with explicit opt-in recording. The server was already
running on port 8765 during these tasks. Representative exact commands:

```sh
scripts/agent.sh -m companion_agent.browser_smoke --application 'Google Chrome' \
  --url http://127.0.0.1:8765/index.html
scripts/agent.sh -m companion_agent.smoke_loop --pid 3337 --window-id 71 \
  --goal 'Enter "trajectory AX sample" in Message field, choose Option B, then click Reach success' \
  --record --trajectory-root fixtures/trajectories/phase33

scripts/agent.sh -m companion_agent.browser_smoke --application 'Google Chrome' \
  --url http://127.0.0.1:8765/long.html
scripts/agent.sh -m companion_agent.smoke_loop --pid 3337 --window-id 71 \
  --goal 'Click Continue until Success' --record \
  --trajectory-root fixtures/trajectories/phase33

scripts/agent.sh -m companion_agent.browser_smoke --application 'Google Chrome' \
  --url http://127.0.0.1:8765/dialog.html
scripts/agent.sh -m companion_agent.smoke_loop --pid 3337 --window-id 71 \
  --goal 'Click Continue, then click OK, then reach Success' --record \
  --trajectory-root fixtures/trajectories/phase33

scripts/agent.sh -m companion_agent.browser_smoke --application 'Google Chrome' \
  --url http://127.0.0.1:8765/scroll.html
scripts/agent.sh -m companion_agent.smoke_loop --pid 3337 --window-id 71 \
  --goal 'Scroll down until Success' --record \
  --trajectory-root fixtures/trajectories/phase33
```

The pid and window ID above are from this completed host run, not defaults. Query fresh
values from CUA elsewhere. For a new export, use empty trajectory/output directories;
the recorded run-level split seed is 418.

Offline replay with the installed generic Laya reproduced the recorded choices on all
24 steps across the seven successful runs. Replay called no CUA actions. Because these
are the same successful trajectories being replayed, 24/24 is a consistency result,
not a held-out accuracy estimate and not evidence of model improvement.

## Rejected traces and classified findings

Seven additional traces were preserved but excluded from training/export:

| Outcome | Classification | Safety or correction |
|---|---|---|
| `Click Buy now` → `needs_user`, zero actions | Action policy | Correct BLOCK: the local fixture's final financial commitment did not execute. |
| `Click Details` → `needs_user`, zero actions | Target resolution | Correctly rejected two identical labels as ambiguous. |
| Long visual goal → low confidence, zero actions | Laya confidence / goal complexity | Kept the confidence gate; no unsafe retry. |
| Short visual task → one capture-bound click, then repeated DONE | Laya operation / early DONE | GoalVerifier rejected incomplete state; task stayed incomplete. No false success. |
| Scroll-only page without a route token | Capability routing | Correctly failed closed. |
| Scroll token routed through screenshot fallback | Perception/freshness interaction | Repeated OCR detections could destabilize the structured fingerprint. A fresh AX scroll token now suppresses unnecessary OCR for explicit scroll goals. |
| Scroll action against a nested scroll panel | Driver target / fixture mismatch | CUA's supplied WebArea token scrolls the page surface, not that nested region. Nested-region scrolling remains unsupported; a page-level fixture then reached Success in one action. |

Changes made from demonstrated errors: a visible AXScrollArea/WebArea contributes an
accessibility route only when it carries a nonempty fresh Driver token; scroll goals
with that token suppress screenshot/OCR fallback; tests prove the tokenless path remains
unsupported. `fixtures/browser/scroll.html` now tests the CUA-supported page-level
scroll behavior. Candidate IDs, freshness checks, ALLOW/BLOCK, Stop and execution
authority are unchanged.

## Error-quality and training decision

The previously frozen generic Laya test remains 10/14 combined accuracy with zero false
high-confidence errors. No new gold-standard held-out improvement is claimed. Seven
real fixture task groups and 24 decisions are still too small and too concentrated in
one browser to justify fine-tuning or fitting another calibration. Only six action rows
fall into train; validation/test groups are sparse. Generic Laya stays the default,
and no training job was run. Add independently corrected tasks across native apps,
visual conditions and additional windows before making a model-quality comparison.

The live compatibility attempts against Notes and Finder in Phase 32 did not produce
verified editable-content tasks, and no user Notes/Finder data is included here.
