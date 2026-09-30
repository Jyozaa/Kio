# Laya backend comparison on the Kio host

Environment: Apple M2 Pro, 16 GB RAM, macOS arm64, Python 3.12.8, checkpoint
`convaiinnovations/laya` revision
`55cf4c4ebb4ebe31b2550e8bdf3bd21b99753851`; upstream Torch Laya 0.3.20 versus
`laya-mlx` 0.2.0 at source revision
`0a859518634112655cb97c745dbf04f5191aaf13`, MLX 0.32.3. MLX uses fp16. Process
RSS is a process high-water mark, not an isolated model allocation. The test
split contains 14 cases, including a deterministic verifier-completed row; the
operation accuracy excluding that already-verified row is also reported.
Raw split reports and the exact parity comparisons are in
[`laya-backend-parity.json`](laya-backend-parity.json) and the neighboring
`laya-kio-*.json` files; query-shape reports are `laya-profile-*.json`.

## Same-input parity and legacy baseline

Torch and MLX received byte-equivalent serialized state and question inputs.
Across validation and test, all compared choice labels matched; maximum
probability delta was 0.0006 on legacy-format prompts, below the 0.02 tolerance.
Legacy test and validation results were 10/14 combined (operation 8/12 after
excluding two deterministic verifier-completed rows, target 6/6). Each split had
one false high-confidence error. ECE was .202 on test and .194 on validation.
This old representation's confidence is particularly unreliable for the
checkpoint's 11+ option bucket.

## Kio V1 representation

| Split/backend | Cold load | First inference | Warm full-decision median / p90 | Peak RSS | Operation (non-DONE) | Target | Combined | False high-confidence errors | ECE |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Test Torch | 2.74 s | 0.19 s | 116 / 144 ms | 2,847 MiB | 8/12 (66.7%) | 6/6 | 10/14 | 0 | .0900 |
| Test MLX | 0.26 s | 0.07 s | 90 / 121 ms | 950 MiB | 8/12 (66.7%) | 6/6 | 10/14 | 0 | .0899 |
| Validation Torch | 3.96 s | 0.48 s | 118 / 134 ms | 2,845 MiB | 8/12 (66.7%) | 6/6 | 10/14 | 0 | .1278 |
| Validation MLX | 0.22 s | 0.08 s | 90 / 112 ms | 953 MiB | 8/12 (66.7%) | 6/6 | 10/14 | 0 | .1272 |

Exact choice parity was 84/84 across both representations and both splits.
For Kio V1, that is 22/22 per split (20 model choice heads plus two
deterministic verifier-completed rows per split); the maximum probability delta
was 0.003 and mean delta was 0.000243. Each split retained 100% target recall at
raw observation, exhaustive candidate-builder, and production-candidate
boundaries (six labelled targets). The 301-candidate diagnostic case narrowed
to one production candidate while retaining its gold target.

On Kio V1, MLX reduced the matched test full-decision median from 116 ms to
90 ms and process high-water RSS from 2,847 MiB to 950 MiB. Validation medians
were 118 ms Torch and 90 ms MLX. The earlier V1 code had a state-label shadowing
defect in candidate text; these persisted reports are from the corrected
candidate renderer. MLX became the arm64 default because choices were stable,
inference was faster on both splits, and the process RSS was lower; Torch
remains the fallback.

Changing to the compact state/candidate representation did not improve this
generic model's aggregate accuracy: both representations scored 10/14 on the
test set and 10/14 on validation. The corrected V1 report had zero false
high-confidence errors on either split and lower ECE (.090 test, .128
validation), with target accuracy unchanged at 6/6. These 14-case fixtures do
not support a general capability claim or model promotion.

## Query-shape, repeatability, and optimization profiles

Ten warm repeats per shape all returned identical selected choices. The
diagnostic timings (median / p90) were:

| Query shape | Torch | MLX eager | MLX prompt cache | MLX compile |
|---|---:|---:|---:|---:|
| One question | 35.1 / 37.2 ms | 24.1 / 24.5 ms | 24.7 / 25.3 ms | 23.4 / 23.7 ms |
| Operation + target | 69.6 / 71.0 ms | 53.7 / 54.5 ms | 54.3 / 56.8 ms | 53.1 / 53.8 ms |
| Five-question batch | 193.3 / 196.5 ms | 131.4 / 132.5 ms | 132.0 / 134.5 ms | 132.1 / 137.9 ms |
| Eight-choice target | 47.3 / 50.7 ms | 34.7 / 35.6 ms | 34.0 / 34.1 ms | 33.6 / 33.9 ms |
| Thirty-choice diagnostic | 55.8 / 56.7 ms | 46.2 / 47.7 ms | 44.6 / 45.2 ms | 44.6 / 45.8 ms |

Peak process RSS was 2,853 MiB for Torch and varied from 790 to 956 MiB across
the MLX eager/cache/compile runs. Prompt caching's small improvement
on one/eight-choice queries did not carry to operation-plus-target or
five-question calls. Compilation only slightly changed warm timings and added
2.45 seconds to the first inference in this profile. Neither option is enabled
in Kio. Batch size remains 8; these profiles also confirm stable repeat
decisions at that configuration.

Raw profile reports are retained as
`laya-profile-{torch,mlx-eager,mlx-cache,mlx-compile}.json`.

## Reproduction

The reproducible command is
`scripts/agent.sh -m companion_agent.backend_benchmark`; `prepare` fixes the
input JSON and source hash, `run` evaluates legacy or V1, `compare` checks
probability and choice parity, and `profile` measures one-question,
operation-plus-target, five-question batch, eight-choice, and diagnostic
30-choice shapes. Compilation and prompt caching are opt-in flags. The
30-choice query is synthetic diagnostic input only: production target choices
remain bounded to eight. Detailed JSON reports include host/runtime metadata
and should be retained when changing a runtime.

`laya-mlx` emits a calibration warning for the pinned checkpoint's
`choice:11+` raw temperature 0.1006, which it clamps to its supported interval.
The affected confidence is uncalibrated; selected-label probabilities are
still directly compared between the two implementations. Do not compare MLX
benchmarks published for an M3 Max with these host measurements.
