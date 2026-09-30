# User guide

Open Kio from its menu bar icon, or press **Option-Command-K**. Drop files onto the notch panel or the conversation window, describe a supported task, and review the result. Kio preserves the source and creates a conflict-safe copy. Use **Open** or **Reveal** on a result card.

Common workflows include merging/removing PDF pages, making a PDF from images, resizing or converting an image, creating a ZIP, making renamed copies, and extracting audio from a video. The PDF compressor creates a readable rasterized copy; it reports if that copy does not meet the requested size. Follow-ups such as “make it smaller” use the latest result. Unsupported or ambiguous requests are clarified instead of guessed.

For requests outside deterministic fast paths, open Settings → Local model → **Download model · 1.72 GB**. The optional Qwen3.5 2B 4-bit model is stored under `~/Library/Application Support/Kio/Models` and runs on this Mac. It plans only among registered native workflows.

Conversation history is saved on the Mac. **Settings → Privacy → Clear history** removes the saved conversation and task context. To remove the downloaded model, use Settings → Local model → **Remove**.

## Optional phone pairing

Deploy the optional PWA/relay and enter its `workers.dev` URL under Settings → Mobile → **PWA and relay URL**. Select **Connect**, then **Pair phone**, and scan the short-lived QR code with your phone camera. Confirm **Pair with my Mac** on the PWA. The phone can send requests and files (up to 50 MiB); the Mac executes supported tasks locally and returns the result. Settings lists paired phones and **Revoke** disconnects one. The phone's **···** menu unpairs that browser.

When the Mac is offline, the phone displays that the request will start when Kio reconnects. It remains encrypted in the relay queue for up to 24 hours. See [Mobile pairing](MOBILE_PAIRING.md) for build, deployment, pairing, and current physical-device validation limits.
