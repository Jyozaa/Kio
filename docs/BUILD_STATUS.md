# Kio build and verification status

Last updated: 2026-10-02

## Repository and CI state

- Repository: `/Users/joe/Desktop/Kio`, branch `main`.
- Starting and final HEAD: `ede42d60bda5d17cd1fe5e7214c13975f7511894` (`testing`). `origin/main` still points to this commit.
- This hardening pass is present only as local, uncommitted changes. No commit or push was made.
- The GitHub Actions run for the unchanged starting HEAD, [36978665130](https://github.com/Jyozaa/Kio/actions/runs/36978665130), was still `in_progress` at the final status check. Therefore CI has no final result for this HEAD, and it does not include the local working-tree changes.
- The preceding completed run, [36966311918](https://github.com/Jyozaa/Kio/actions/runs/36966311918), was red on an older HEAD. Its Python test subprocess failed while running `scripts/build-mac.sh`; the available traceback did not establish the subprocess's specific underlying cause. The local Python suite now passes.

## Reliability changes

- Reel inspection now retains bounded per-variant metadata: exact format ID, quality/resolution, frame rate, container, codecs, bitrate, size, audio/video presence, language, protocol, and source backend. Older inspection records decode with defaults for fields they did not store.
- Reel selection resolves actual inspected video/audio format IDs and records whether conversion is required. MP4 prefers H.264/AVC video plus AAC audio, including a lower compatible source before transcoding; AV1/Opus is not chosen when a suitable H.264/AAC source is available. WebM recognizes VP9/AV1 and Opus aliases; MKV and MOV use their compatible copy/remux paths where possible. Unsafe format IDs are rejected.
- Quality and format options are derived from available variants, so the picker does not offer unsupported quality/format pairs. Conversion-required and lower-compatible-source choices are identified in the shared Reel picker.
- The same Reel download card appears in the notch and inline with its Reel inspection message in chat. Historical cards use their own inspection artifact and remain available after a download or later result. Inspection files continue to be subject to existing cleanup/retention behavior.
- Internal intermediate artifacts can no longer select their own support directory as the final output location. Internal-only inputs use the configured output folder or `Downloads/Kio`.
- Audio normalization verifies media with ffprobe rather than inferring the encoded format from a `.tmp` filename. Final user-facing paths retain the requested extension. Local video-to-MP3, M4A, WAV, and FLAC integration coverage uses temporary intermediates.
- Bundled FFmpeg failures now carry a bounded category, exit status, operation, codecs/container, and sanitized relevant stderr excerpt. User-facing errors remain short. VideoToolbox H.264 is used when encoding is necessary; a software fallback is permitted only if the bundled runtime explicitly declares an allowed LGPL encoder. The current runtime does not include that encoder, and no GPL x264/x265 component was added. Encoding bitrate targets vary by output resolution.
- Streamlink inspection no longer invents MP4, audio, or VOD availability: values remain unknown unless inspection data establishes them. Reel fallback is limited to unsupported-extractor/no-matching-source cases, rather than masking authorization, DRM, unsafe-URL, timeout, or other errors.
- Cue number matching is bounded by nearby script context, allowing spoken `one two three` to match `1, 2, 3` while also supporting a contextual whole-number reading. Kio/Kyo/Keo matching is local to a short context window; common short words are not accepted as fuzzy names. SpeechAnalyzer receives contextual vocabulary, and Cue does not fabricate confidence for partial results.
- Semantic routing uses attached artifact context for requests such as “get this as MP3”: local video converts while a URL uses Reel. Supported compound image conversion/resize or conversion/size-limit requests compile both steps; incomplete or ambiguous compound requests clarify. General action negation blocks mutating and non-mutating operations. Common resize, compress, rename, extract, remove, merge, move, and copy paths use their registered typed arguments. Local video target formats are typed and limited to supported runtime behavior.
- Other audited defects addressed include stale `activeOutput` dependence for Reel cards, internal Reel artifacts appearing as ordinary output cards, unsafe/overbroad variant metadata, and misleading fixed timeout text.

## Final noninteractive verification

The final complete `./scripts/check.sh` pass exited successfully on 2026-10-02. It ran with isolated Swift and Xcode derived-data directories under `/tmp`; it did not launch the app.

- `git diff --check`: passed.
- Python script tests: 14 passed.
- Swift package tests: 62 KioTools tests, 2 KioSync tests, and 103 KioCore tests passed (167 total).
- macOS Debug and Release builds: passed, with code signing disabled (`CODE_SIGNING_ALLOWED=NO`, identity `-`). The Debug app reports version `0.1.0`, build `1`; products are under `/tmp/KioDerivedDataHardening/Build/Products/{Debug,Release}/Kio.app`.
- Mobile PWA: dependency installation, TypeScript check, production Vite build, and 2 PWA crypto tests passed.
- Relay: dependency installation, TypeScript check, local smoke and lifecycle checks, and shared WebCrypto vector passed.
- Pinned Reel helper runtime validation and resource preparation passed. The local-video media integration tests passed.
- Non-fatal Xcode warnings remain: the prepared-runtime build phase has no declared outputs and runs on each build; signed upstream helper binaries cannot be stripped.
- The builds are unsigned. No `codesign --verify` claim applies.
- **Kio was not launched or manually tested by Codex.** No UI, microphone, live provider/media, physical phone, or relay deployment was tested. See the [manual acceptance guide](MANUAL_ACCEPTANCE.md#reliability-hardening-reel-variants-cue-context-and-semantic-routing).

## Remaining limitations

- Reel support depends on what yt-dlp, Streamlink, or direct media resolution can inspect and retrieve. Authentication-gated and DRM-protected sources are unsupported; no universal site coverage is claimed.
- The bundled runtime has no declared LGPL software H.264 encoder. If VideoToolbox encoding fails, Kio returns a diagnostic instead of using a prohibited encoder. Incompatible WebM conversion is not advertised; compatible WebM streams can be copied.
- WebP conversion depends on ImageIO WebP encoder availability on the user's macOS version.
- Manual acceptance is still needed for visible picker placement/behavior, real public-source behavior, microphone/Cue recognition, actual user media playback, permissions, and the installed app experience.
