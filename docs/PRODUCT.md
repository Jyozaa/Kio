# Product

Kio turns the MacBook notch into a compact productivity dashboard. The notch is the product surface; it is not a launcher for a general chat assistant.

## Dashboard spaces

- **Kio** contains exactly three task features: Convert, Reel, and Cue.
- **Sessions** monitors local lifecycle events from supported coding tools.
- **Clipboard** stores a bounded local shelf of recent clipboard items.
- **News** presents headlines from feeds the user chooses.

The last selected dashboard space is stored locally. The collapsed notch is black. It briefly widens for eligible Kio/session events, then retracts. Ordinary News updates do not create ambient events.

## Kio features

### Convert

Convert is deterministic and local. It accepts image formats JPEG, PNG, HEIC/HEIF, WebP, and TIFF; image resize and target-size JPEG compression; audio conversion among MP3, M4A, WAV, and FLAC; video conversion, resizing, target-size compression, and audio extraction where the bundled media runtime supports the requested input/output; PDF compression and merge; and image-to-PDF. It keeps originals and writes results to the selected output location. PDF-to-image is not currently implemented.

Convert does not handle file organization, image editing/inspection, arbitrary PDF page edits, archives, transcription, or general content transformation. Unsupported requests receive a direct explanation.

### Reel

Reel inspects a public media link and presents the available qualities and compatible formats. It supports video, audio-only output, subtitle download, safe output paths, format checks, original-audio-first track selection using source language preferences, and verification with yt-dlp, Streamlink fallback, FFmpeg, and ffprobe. It does not read browser cookies, log in, or bypass DRM.

### Cue

Cue has **Follow My Voice** and **Classic** modes. Follow My Voice uses Apple Speech frameworks when started; Classic uses a local reading-speed clock. Cue fixes typography for the whole session, lays out the complete script into stable lines, and highlights the active word without changing its width. As reading advances to a new line, the complete document moves upward gently; words do not reflow around the active token.

## Sessions

Sessions is passive. Claude Code, Codex, OpenCode, and Cursor hooks can be enabled individually. They send only lifecycle metadata such as provider, session identifier, project, working directory, event type, and timestamp. Kio does not inspect prompts, transcripts, terminal contents, or tool arguments. The user enables or removes each hook from the Sessions space or Settings.

## Clipboard

Clipboard history is off until enabled. It stores supported text, images, and file URLs in local Application Support; deduplicates repeated entries; skips concealed/transient pasteboard types and configured excluded applications; caps recent entries and image bytes; and preserves pinned entries through normal retention. The strict image-storage cap can evict an image entry when required. Clearing history removes the locally copied image files too.

## News

News reads configured RSS or Atom sources over HTTPS when refreshed. The feed parser keeps bounded headline metadata and filters by topic. New headlines remain silent by default; only topics explicitly listed as alert topics can show a temporary notch event.

## Out of scope

Kio has no general LLM, provider keys, full chat transcript/window, specialist agent crew, phone/PWA/Courier, relay, web research, file organization, broad writing tools, or general control of other applications.
