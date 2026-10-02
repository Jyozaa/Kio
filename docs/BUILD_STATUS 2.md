# Kio build and verification status

Last updated: 2026-10-01

## Source and scope

- Repository: `/Users/joe/Desktop/Kio`, branch `main`; baseline HEAD `69f7943f082e2fbf38b9f5847574f520932beb5b` (`teleprompter`). The work in this pass is local and uncommitted; GitHub was not queried or changed.
- Kio was not launched or interactively tested by Codex. The user must perform microphone, visual, and live-media acceptance.
- Canonical manual build/install command: `bash scripts/dev-run.sh`. It prepares the pinned Reel runtime before building and launches the app; run it only for manual acceptance.

## Existing implementation

- Cue modes are Word Tracking, Follow My Voice, and Classic. Follow My Voice aligns progressive speech transcripts with a responsive local fuzzy matcher; Word Tracking retains conservative matching. A single engine tap feeds the chosen speech backend and throttled waveform. macOS 26+ uses SpeechAnalyzer/SpeechTranscriber where available; earlier/incompatible configurations fall back to SFSpeechRecognizer.
- Cue's active view uses a bounded reading window, inline current-word accent, lower emphasis for past/future text, and an overlaid control strip plus waveform/recent-transcript status.
- Reel helper downloads and Prepare Reel UI were removed. The runtime is built from the pinned machine-readable manifest and staged under `Contents/Resources/Reel`; Kio resolves helpers only from that bundle. The build cache is `.cache/reel/`.
- FFmpeg/ffprobe 9.0.2 and LAME 3.100 are built as shared LGPL configurations with corresponding sources/notices packaged. gallery-dl is excluded because the repository has no Kio distribution license declaration establishing GPL redistribution compatibility.

## Focused fixes in this pass

- Cue no longer preheats the audio engine or force-unwraps a guessed device format. Startup validates the hardware format, asks SpeechAnalyzer for a supported format, converts before its async input stream, tracks tap/session state explicitly, creates a fresh analyzer sequence per start, and falls back to SFSpeech Recognition when modern setup/start fails.
- Cue owns a `.cueSession` notch-interaction reason from setup through active reading and completion. Pointer exit cannot collapse it; completion shows briefly, then exits Cue and force-collapses the notch.
- Reel uses the bundled yt-dlp `--print` object template to emit only required inspection fields. Captured stdout now carries byte-count/truncation state, with separate empty, oversized, malformed-JSON, and helper-failure handling.

## Verification

- Cue and alignment focused tests: 14 passed (`swift test --package-path Packages/KioKit --scratch-path /tmp/kio-focused-swift --filter cue`).
- Reel focused tests: 11 passed with the same command and `--filter reel`.
- The bundled yt-dlp 2026.08.19 emitted one valid compact JSON object for static local `--load-info-json` fixtures, including optional-field fallbacks; no live URL was accessed.
- Focused macOS Debug `xcodebuild` completed successfully with `CODE_SIGNING_ALLOWED=NO`; the app product was produced under `/var/folders/_5/xssw295j0g3_vhrcrkrm51mw0000gn/0/KioDerivedData/Build/Products/Debug/Kio.app`. `git diff --check` passed.
- Kio was not launched; visual, microphone, and live-media acceptance remains for the user. See the first focused section in `docs/MANUAL_ACCEPTANCE.md`.
