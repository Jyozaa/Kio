# Privacy

Kio v2 is a local Mac utility. It has no account, cloud model, phone companion, relay, or chat history. File transformations run on the Mac. Kio does not send file contents to an LLM because it has no LLM provider integration.

## Files and Reel

Convert reads the files the user drops into Kio and writes new output files. Source files are preserved. Reel connects to a public media URL only when the user inspects or downloads it; its bundled yt-dlp, Streamlink, FFmpeg/ffprobe, and Python helpers do not download software at app runtime. Normal source network metadata is visible to the site contacted by Reel.

## Sessions

Session monitoring is opt-in per provider. Enabling an integration modifies a provider's local hook configuration and preserves one `.kio-backup` copy of its original JSON settings where that applies. Hook events are normalized to provider, opaque session id, project name, working directory, event kind, and timestamp. Kio intentionally drops prompts, transcript text, tool names, tool arguments, and terminal output. Hook inbox files are local, mode-restricted, and capped; processed events are removed. The bounded session cache is stored at `~/Library/Application Support/Kio/Sessions.json`.

The working directory and project name may identify private local projects. Users can remove any hook in Sessions or Settings. Provider hook delivery depends on starting or continuing sessions in that provider after the hook is enabled.

## Clipboard

Clipboard history is off by default. When enabled, Kio polls the system pasteboard for changes and stores supported plain text, file URLs, and local PNG copies of images in `~/Library/Application Support/Kio`. It skips pasteboard items carrying `org.nspasteboard.ConcealedType` or `org.nspasteboard.TransientType` and can skip app identifiers the user lists. Kio does not transmit clipboard content. Text and file metadata are stored in `Clipboard.json`; image copies are stored under `Clipboard/Images` and removed when their entries are pruned, deleted, or cleared.

The history is bounded by entry count and captured image bytes; individual clipboard text is capped. Pinned items survive normal retention, but the hard entry cap and image-storage budget still apply and may evict an image entry if needed to stay within the image cap. Users can disable capture, set retention and count, exclude apps, unpin/delete entries, or clear the full store from Settings/Clipboard.

macOS does not provide a universally reliable API for identifying which process last wrote every pasteboard change. Kio uses the frontmost application's bundle identifier at capture time as a best-effort exclusion signal. Password managers that mark data concealed/transient are skipped; users should also add sensitive apps to the exclusion list.

## News

News does not scrape pages or run in the background. Kio contacts the configured HTTPS RSS/Atom feed URLs only when the user refreshes or saves feed settings. Those servers receive ordinary network metadata such as the Mac's public IP address. Kio stores bounded local headlines, publisher/topic labels, dates, and article URLs in `News.json`. Headlines stay silent by default; a notch alert is possible only for a topic the user explicitly enables.

## Cue and permissions

Cue scripts remain in local app memory. Classic mode does not use the microphone. Follow My Voice requests microphone and Speech Recognition permission only after the user chooses Start. It uses Apple Speech/SpeechAnalyzer frameworks on the Mac according to the selected macOS version and locale.

## Local storage

Dashboard preference, provider status, clipboard entries, News cache, and Cue settings are kept in the user's local macOS account. Kio does not provide cloud sync or encrypt these stores separately from the platform's normal user-account protections. Removing an integration stops future hook events; the user may remove or retain previously recorded session summaries from local storage.
