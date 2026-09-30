# Local model

Kio uses MLX Swift LM 3.31.4 with `mlx-community/Qwen3.5-2B-4bit`. The selected 4-bit model is approximately 1.72 GB and is Apache-2.0 licensed. The model card and license were checked before wiring the runtime. MLX Swift LM 3.31.4 lists Qwen3.5 text support.

In Settings, **Download model** begins the download and preparation. Kio stores the Hugging Face cache under `~/Library/Application Support/Kio/Models`. The model is loaded only after that explicit action or when a later request needs model planning. **Keep model loaded** defaults on; when turned off, Kio unloads it after 15 minutes without model use. Removing the model deletes only Kio's cached copy; it can be downloaded again.

The fast deterministic planner remains first. When a request needs model planning, Kio sends the local model the request and a short list of file indexes, names, types, and sizes. It does not send file contents or local paths to the planner. Model output is parsed into a strict typed plan, restricted to registered operations and existing artifacts, and validated before a tool can run. Invalid output is rejected; there is no cloud fallback or arbitrary command execution.

The 1.72 GB download and inference were exercised in the built app on Apple Silicon. With a one-pixel PNG attached, the request “Please turn this picture into a portable document page that I can print” went through local model planning, decoded to the registered image-to-PDF workflow, and produced a verified 5 KB PDF. The conversation and output reference were then restored from local history after quitting and reopening Kio. This was a focused smoke workflow; it does not validate every natural-language phrasing or every supported tool through model planning.

To repeat the smoke workflow, open Settings, choose **Load local model**, attach an image, and ask for a portable document page without saying “PDF” (the deterministic PDF fast path is intentionally bypassed). The raw model is not downloaded by `scripts/check.sh`; it is a large, explicit first-use download.

References: [quantized model card and Apache-2.0 license](https://huggingface.co/mlx-community/Qwen3.5-2B-4bit), [original Qwen model](https://huggingface.co/Qwen/Qwen3.5-2B), [MLX Swift LM release notes](https://github.com/ml-explore/mlx-swift-lm/releases), [supported models](https://github.com/ml-explore/mlx-swift-lm/blob/main/skills/mlx-swift-lm/references/supported-models.md).
