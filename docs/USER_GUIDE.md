# User guide

Open Kio from its menu bar icon, hover or click the notch, or press the configured shortcut (default **Option-Command-K**). The expanded notch is the main interaction surface: recent conversation, attachments, composer, send/stop, current specialist, and results stay there. Drop files onto the notch or conversation window, describe a supported task, and review the result. Kio preserves the source and creates a conflict-safe copy. Use **Open**, **Reveal**, **Copy**, or drag a result out from its card.

Common workflows include merging/removing PDF pages, making a PDF from images, resizing or converting an image, smart-cropping an image around a detected subject, creating a ZIP, making exact or batch-renamed copies, extracting a video clip, and converting audio to M4A. The PDF compressor creates a readable rasterized copy; it reports if that copy does not meet the requested size. Follow-ups such as “rename it final” and “make it under 2 MB” use the latest result. “Do the same to these files” reuses the last successful registered one-step workflow only when the selected file kinds match. Unsupported or ambiguous requests are clarified instead of guessed.

Other specialists extend those workflows: Scribe summarizes, rewrites, proofreads, translates, extracts points/actions, converts to Markdown, compares, or explains local text files; Table analyzes and transforms CSV/TSV and JSON and can import bounded XLSX workbooks to CSV; Lens reads text, receipts, and tables from images; Scout extracts readable text and links from permitted public URLs; Patch explains supported source code or creates a separate proposed copy with a diff. Patch never runs code or overwrites the original. Pixel can compare images and remove backgrounds; Echo can transcribe audio locally when macOS Speech support is available.

For requests outside deterministic fast paths, open Settings → Local model → **Download model · 1.72 GB**. The optional Qwen3.5 2B 4-bit model is stored under `~/Library/Application Support/Kio/Models` and runs on this Mac. It plans only among registered native workflows. Settings lets you keep it loaded or unload after 5, 15, or 30 idle minutes.

The first launch includes a short guide to local processing, optional model download, notch/drop interaction, and optional phone pairing. Settings also controls hover delay, character motion, launch at login, and one of three built-in global shortcuts.

The composer accepts typed requests, dropped files, and explicit clipboard paste for text, URLs, images, and files. Screenshot capture is an explicit action. Finder's **Services → Send to Kio** sends selected files to the composer. Use **History** to search saved conversations and refer to outputs as “the latest PDF” or “the second one.” Contextual actions and saved workflow templates are available from the history/workflow menus. Selecting a folder in Clerk lets you search recent files or names; organization previews copies before writing and keeps the originals in place.

Conversation history is saved on the Mac. **Settings → Privacy → Clear history** removes the saved conversation and task context. To remove the downloaded model, use Settings → Local model → **Remove**.

## Optional phone pairing

Deploy the optional PWA/relay and enter its `workers.dev` URL under Settings → Mobile → **PWA and relay URL**. Select **Connect**, then **Pair phone**, and scan the short-lived QR code with your phone camera. Confirm **Pair with my Mac** on the PWA. The phone can send requests and files (up to 50 MiB); the Mac executes supported tasks locally and returns the result with Kio and specialist progress. Settings lists paired phones and **Revoke** disconnects one. The phone's **···** menu can enable completion notifications or unpair that browser.

When the Mac is offline, the phone displays that the request will start when Kio reconnects. It remains encrypted in the relay queue for up to 24 hours. See [Mobile pairing](MOBILE_PAIRING.md) for build, deployment, pairing, and current physical-device validation limits.
