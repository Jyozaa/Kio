# Native Laya inference with MLX

On arm64 macOS, the default chooser prefers `laya-mlx` 0.2.0, pinned to source
revision `0a859518634112655cb97c745dbf04f5191aaf13`, with MLX and mlx-metal
0.32.3. The same pinned Laya checkpoint is used for Torch and MLX comparisons.
Other platforms keep upstream Torch. `KIO_LAYA_BACKEND=torch` selects the
fallback explicitly; an MLX load or supported inference failure falls back to
Torch. The model instance remains warm for the helper lifetime.

The integration boundary is `DecisionBackend` in
`agent/src/companion_agent/backends.py`. Both providers normalize answers to
choice, probability map, and top-choice probability. MLX's entropy-style
`confidence` remains available as `backend_confidence`; Kio's
`answer_confidence` is the selected label's probability, matching upstream
Torch semantics.

The current production settings are fp16, eager inference, batch size 8, and
prompt caching off. On this 16 GB M2 Pro, matched-fixture warm inference and
process RSS favored MLX. Compilation and prefix caching remain opt-in benchmark
flags and are not enabled by default unless their same-host measurements show
a repeatable improvement without changing decisions. The installed generic
checkpoint has an out-of-range 11+ choice temperature; laya-mlx clamps it and
warns that confidence in that bucket is uncalibrated. Kio does not use that raw
entropy value as its top-class probability.

Exact same-input parity and split metrics are recorded in
[`benchmarks/laya-backend-comparison.md`](benchmarks/laya-backend-comparison.md).
Python wheel notices and upstream Laya attribution are bundled under
`Contents/Resources/third-party-licenses/` in the rebuilt app. Fine-tuning stays
on the upstream Laya/PyTorch workflow; MLX is an inference backend, not a
training implementation.
