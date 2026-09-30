# Structured trajectories and offline replay

Recording is off by default. Set `KIO_RECORD_TRAJECTORIES=1` when launching Kio,
or pass `--record` to the explicit local fixture smoke. Records are new, private
files in `~/Library/Application Support/Kio/trajectories/`. A run is never overwritten.

Schema version 1 records Task (goal/id), Step, ObservationSummary (fingerprint,
normalized non-executable elements), CandidateTable (IDs/descriptions), Decision
(operation/target confidence), Action status, state change, Verification, Outcome,
perception sources and timings. No image, audio, native execution token, clipboard
or executable payload is serialized. Secret-labelled content, known token patterns,
email addresses, phone-like numbers and user-specific paths are redacted. Heuristic
redaction cannot identify every personal name; inspect exports before sharing.

```bash
scripts/agent.sh -m companion_agent.trajectories inspect /absolute/run.json
scripts/agent.sh -m companion_agent.trajectories replay /absolute/run.json
scripts/agent.sh -m companion_agent.trajectories correct /absolute/run.json \
  --step 0 --candidate c_ACTUAL_ID --corrections /absolute/corrections
scripts/agent.sh -m companion_agent.trajectories export /absolute/runs \
  --corrections /absolute/corrections --output /absolute/new-export
```

Replay uses the current local chooser against description-only historical tables.
It never opens a Driver connection or executes an action. Sanitization means it is
an analytical comparison, not guaranteed bit-identical reproduction of private inputs.
Corrections are separate immutable files referencing the original SHA-256; unknown
candidates and conflicting corrections fail. The original decisions remain intact.

Exports contain Laya `state`, `questions`, `expected`, `tags`, `language` and task
metadata, with ephemeral candidate IDs normalized per step. Only explicitly corrected
rows are exported. SHA-256(seed:task_id) assigns train/validation/test; all steps and
runs sharing a task ID stay together. Defaults are 80/10/10 at task level, so a tiny
corpus can have empty splits. Never calibrate on the final test split.

Official dataset contract reviewed: https://github.com/NandhaKishorM/laya/blob/main/docs/evals.md
The installed 0.3.20 predictor accepts these question dictionaries; newer upstream
`laya-evals` CLI availability is not assumed. Phase 18 supplies local evaluation.
