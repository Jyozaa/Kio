# Kio build and verification status

Last updated: 2026-10-01

## Source and scope

- Repository: `/Users/joe/Desktop/Kio`, branch `main`; baseline HEAD `3a3e07344156722e004fd293f5212d89bcbfebd0` (`transcript clipping`). The work in this pass is local and uncommitted; GitHub was not queried or changed.
- The app has not been installed or launched during this pass. A signed Debug build exists only in Xcode DerivedData.
- Canonical manual build/install command: `bash scripts/dev-run.sh`. It prepares the pinned Reel runtime before building and launches the app; run it only for manual acceptance.

## This implementation pass

- Cue modes are Word Tracking, Follow My Voice, and Classic. Follow My Voice aligns progressive speech transcripts with a responsive local fuzzy matcher; Word Tracking retains conservative matching. A single engine tap feeds the chosen speech backend and throttled waveform. macOS 26+ uses SpeechAnalyzer/SpeechTranscriber where available; earlier/incompatible configurations fall back to SFSpeechRecognizer.
- Cue's active view uses a bounded reading window, inline current-word accent, lower emphasis for past/future text, and an overlaid control strip plus waveform/recent-transcript status.
- Reel helper downloads and Prepare Reel UI were removed. The runtime is built from the pinned machine-readable manifest and staged under `Contents/Resources/Reel`; Kio resolves helpers only from that bundle. The build cache is `.cache/reel/`.
- FFmpeg/ffprobe 9.0.2 and LAME 3.100 are built as shared LGPL configurations with corresponding sources/notices packaged. gallery-dl is excluded because the repository has no Kio distribution license declaration establishing GPL redistribution compatibility.

## Verification

- Cue focused tests: 10 passed (`swift test --package-path Packages/KioKit --scratch-path /tmp/kio-swift-build --filter cue`).
- Reel focused tests: 9 passed with the same command and `--filter reel`.
- `CONFIGURATION=Debug KIO_BUILD_SIGNING_MODE=public bash scripts/build-mac.sh`: passed; produced Kio 0.1.0 in Xcode DerivedData, ad-hoc signed with nested Mach-O verification.
- Bundle probes passed for yt-dlp 2026.08.19, Deno 2.9.7, FFmpeg/ffprobe 9.0.2, and Streamlink 8.6.0. Importing Streamlink with Python `-B -I` preserved the app's strict code signature; no bytecode caches were created.
- `git diff --check`, `bash -n` on build/install/package scripts, and `plutil -lint` on the Xcode project passed.
- Kio was not launched; visual, microphone, and live-media acceptance remains for the user. See `docs/MANUAL_ACCEPTANCE.md` focused section.
