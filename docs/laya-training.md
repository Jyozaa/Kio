# Kio Laya evaluation and training

The generic pinned Laya checkpoint remains the default model. On Apple Silicon
arm64, MLX is now the preferred inference implementation after same-input parity;
Torch remains the cross-platform/fallback backend. No accuracy improvement was
established by the one-step training smoke. All benchmarks here are offline
structured decision tests; they are not live DOM/OCR integration claims. Runtime
policy remains independent.

The frozen corpus `fixtures/calibration/cases-v1.json` has 14 validation and 14 test
cases, separate from the four real fixture training decisions. It covers AX, DOM,
OCR-only state, duplicate controls, scroll, typing, selection, DONE, BLOCKED,
uncertainty, financial policy context, 301 observed controls, and action history.
The small paired templates limit generalization. Do not tune against its test split.
Corpus SHA-256: d9e081456ac3a1682d9f10a847dfebb942b39da86d54bafdc4a08b1acdba6cf2.

Phase 33 added seven explicitly recorded local-fixture task groups (24 verified
action decisions) under `fixtures/trajectories/phase33/` and a run-level export in
`fixtures/calibration/phase33-export-v2/`. Its six training rows and sparse validation
and test run groups are not enough for training or a new calibration. See
`docs/phase33-dogfood.md` for replay consistency, failure classification and limits.

Validation input comparison: existing pruning scored 10/14 versus 8/14 without
pruning (one false high-confidence error without pruning). Removing history kept
10/14 but worsened ECE from .1752 to .1866. Existing descriptions, bounded state,
and operation/target decomposition were retained; no avoidable input rewrite was
introduced to train around these results.

| Untouched test split | Operation / combined | Target | False confidence ≥ .8 | ECE | Warm median / p90 |
|---|---:|---:|---:|---:|---:|
| Generic | 10/14 | 6/6 | 0 | .1991 | 94.9 / 115.4 ms |
| Validation calibrated | 10/14 | 6/6 | 0 | .1994 | 97.8 / 116.2 ms |
| One-step trained | 10/14 | 6/6 | 0 | .1879 | 96.0 / 113.2 ms |

Raw reports including cold load and peak RSS are in `docs/benchmarks/`. Memory
peaks are process high-water marks, not isolated resident model sizes. Calibration
fit T=1.65 by deterministic NLL on 20 labelled validation heads only, constrained
to the installed runtime's [.5, 5] range. It did not improve test ECE. Generic
11+ choice temperatures trigger the upstream clamp warning; treat those confidence
values as uncalibrated. Neither experimental checkpoint is promoted to default.

## Reproduction

Use the locked development environment (`scripts/check.sh`). No training weights
are committed. Explicit output directories must not already exist.

```bash
PYTHONPATH=agent/src scripts/agent.sh -m companion_agent.training train \
  --dataset fixtures/trajectories/autonomy-export/train.jsonl \
  --output "$HOME/Library/Application Support/Kio/models/laya-smoke-v1" \
  --steps 1 --device cpu
PYTHONPATH=agent/src scripts/agent.sh -m companion_agent.training calibrate \
  --dataset fixtures/calibration/validation.jsonl \
  --output "$HOME/Library/Application Support/Kio/models/laya-calibrated-v1"
PYTHONPATH=agent/src scripts/agent.sh -m companion_agent.benchmark \
  --cases fixtures/calibration/cases-v1.json --split test \
  --model "$HOME/Library/Application Support/Kio/models/laya-smoke-v1" \
  --report docs/benchmarks/tiny-trained-test.json
```

Omit `--model` for generic; use `--split validation --no-prune` or `--no-history`
for the input comparisons. `KIO_LAYA_MODEL_PATH` explicitly opts into a local
checkpoint. Missing or unloadable specialized checkpoints fall back to generic.
A malformed generic checkpoint still fails explicitly.

Training adapts the official [Laya typed-decision RLCD notebook](https://github.com/NandhaKishorM/laya/blob/9d955671415fc19f069b9cc998928075c1f255ec/notebooks/laya_finetune_typed_decisions_2xT4_kaggle.ipynb):
installed 0.3.20 sequence construction, model forward, proper reward, noisy RLCD
plus supervised loss, AdamW, gradient clipping, safetensors checkpoint and reload.
CPU smoke freezes the encoder and trains decision heads; `--train-encoder` enables
full parameter training and `--device cuda` supports an appropriate GPU. For larger
runs use the pinned official free Kaggle notebook workflow, without uploading
unsanitized trajectories. Full training was not attempted on this 16 GB machine.

Actual smoke: one forward/backward/update, changed weights, checkpoint saved and
reloaded, bounded inference passed; 34.192 s, peak RSS 3655.6 MiB. Metadata records
seed 42, dataset hash, base/upstream revisions and weight hash. Base revision:
55cf4c4ebb4ebe31b2550e8bdf3bd21b99753851. Runtime: Python 3.12.8, Laya 0.3.20,
PyTorch 2.14.0, transformers 5.17.0. A successful smoke demonstrates plumbing,
not a trained general-purpose Kio model.

## Kio V1 collection and fine-tuning path

The new model input contract is documented in
[`kio-decision-protocol.md`](kio-decision-protocol.md). The opt-in trajectory
recorder stores sanitized, bounded records under Application Support; it omits
control values and observation titles and keeps only candidate-associated
controls. Training export emits separate `NEXT_OPERATION` and `TARGET` rows
using `KioDecisionStateV1` plus `KioCandidateFormatV1`. Rows are exported only
for a human correction or an executed, state-changing, independently verified
step in a completed run. The video fixture is held out and is never a source of
training rows.

Split assignment hashes the task identifier, so all decisions from one task
stay together in exactly one of train, validation, or test. The exporter writes
three JSONL files and includes a task-group hash, trajectory ID, step index,
decision family, and provenance. Keep separate task groups and app/session
families across splits; a tiny export should be treated as pipeline validation,
not as a trainable corpus. `training.read_rows` rejects schema mismatch,
unlisted labels, credentials/contact data, local paths, screenshot/audio fields,
and execution tokens. `training.assert_disjoint` checks groups before any
multi-split evaluation.

Pipeline-only conversion of the currently checked-in Phase 33 data (14 stored
trajectory records in seven task groups) produced 47 typed decision rows:
43 train, 4 validation, and 0 test. The task groups stayed disjoint. This small
local set cannot support a held-out evaluation and was not used to fine-tune
the model. The older four-row legacy smoke corpus is also not a specialized
Kio dataset.

For a new corpus, use explicitly consented, user-directed local tasks. Review
`inspect` output before export, keep corrections in a private directory, and do
not upload raw trajectories to Kaggle. Export to a new path:

```bash
scripts/agent.sh -m companion_agent.trajectories export \
  "$HOME/Library/Application Support/Kio/trajectories" \
  --corrections "$HOME/Library/Application Support/Kio/corrections" \
  --output /tmp/kio-v1-export
```

Train only on `/tmp/kio-v1-export/train.jsonl`; use the separate validation
split for calibration/model selection, and evaluate promotion once on untouched
`test.jsonl`. Record generic-versus-specialized operation, target, combined
accuracy, false-high-confidence errors, and ECE. Keep the checkpoint's Kio
schema manifest and weights hash. The upstream Laya RLCD notebook remains the
full GPU training workflow; MLX does not train or convert checkpoints
automatically. No full specialized training or checkpoint conversion was
performed for this change.
