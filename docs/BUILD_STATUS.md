# Kio build and verification status

Last updated: 2026-10-02

## Repository state

- Repository: `/Users/joe/Desktop/Kio`, branch `main`.
- Starting and final HEAD: `1dc9cfd8e444bf325aecef117c2f845b541c6147` (`Reel agent bugs`). The hardening changes are local and uncommitted.
- The working tree contains the hardening changes; no commit or push was made.
- The latest GitHub Actions run for that unchanged HEAD is [red](https://github.com/Jyozaa/Kio/actions/runs/36966311918). It failed in `test_public_build_ignores_a_configured_private_development_identity`: the fake Xcode build did not create the pinned Reel helper executables that the app build now validates. The test fixture was updated and passed locally. Since these changes were not pushed, there is no remote CI result for them yet.

## Implemented in this hardening pass

- Added a typed semantic intent and deterministic capability compiler for format-directed conversion, quality/size entities, page selection, time ranges, and rename destinations. Destination formats are selected from the language relationship, not the first matching token. Explicitly negated transformations stop before provider planning. Unsupported or mismatched source/target types ask instead of choosing an unrelated operation.
- Cloud providers and Local Qwen now share one bounded structured plan contract and validation path. Repair prompts include sanitized prior output and specific validation failures, with one retry. Typed contextual actions and Reel picker buttons submit plans directly rather than translating selections back into English.
- Image conversion preserves `.jpeg` versus `.jpg`, verifies the encoded ImageIO type, extension, decodability, and dimensions, and identifies first-frame-only animated conversion. Static image input uses an EXIF-aware decode path for conversion, resize, PDF creation, crop, comparison, background removal, and contact sheets. Batch image work rolls back partial outputs on failure.
- Added typed MP3, M4A, WAV, and FLAC output formats for audio and video sources. Echo and Reel use the shared bundled FFmpeg/ffprobe runtime. Audio output is checked for codec/container, audio-only streams, duration, extension, nonzero size, and the configured byte cap. Reel video output is checked for streams, compatible container/codecs, duration, size, and requested resolution.
- Reel uses yt-dlp with a Streamlink fallback for public, non-DRM sources; inspection metadata is bounded and internal. Direct HTTP transfers validate each redirect destination before following and enforce the byte cap while receiving. Helper output size and duration are monitored during downloads. Streamlink uses the selected quality; subtitle downloads return their generated files; final names derive from sanitized source titles. Gallery download is not advertised or executable.
- The notch and full chat share typed Reel selection state. Internal inspection artifacts are excluded from ordinary result cards, history, and text operations, while still supporting typed follow-up downloads.
- Cue alignment prefers nearby repeated-word matches, weights multi-token evidence, normalizes number words/digits, ignores duplicate partial confirmations, and keeps recent recognized text visible even when alignment holds. Cue lifecycle pinning and collapse are scoped to Cue's own interaction reason.
- Local and phone submissions capture separate immutable input snapshots. Remote IDs are recorded only after staging or queue acceptance. Provider-content consent is scoped to task/provider/source set. Conversation events retain the operation that created them; Clear History removes Kio-owned temporary/support state without deleting user outputs.
- Fresh builds prepare the pinned, checksum-verified Reel runtime before app compilation; CI caches it by OS, architecture, manifest, and build-script hashes. CI signing stays disabled and does not require a personal signing identity.

## Noninteractive verification

The final `./scripts/check.sh` pass completed successfully on 2026-10-02. The script also ran `git diff --check`.

- Python scripts: 14 passed.
- Swift package suites: 59 KioTools tests, 2 KioSync tests, and 97 KioCore/planner tests passed (158 total).
- macOS app: Debug and Release builds succeeded with code signing disabled. Products are under the current user's `KioDerivedData/Build/Products/{Debug,Release}/Kio.app`; version `0.1.0`, build `1`.
- Mobile PWA: `npm ci`, TypeScript check, production Vite build, and 2 crypto tests passed.
- Relay: `npm ci`, TypeScript check, local smoke and lifecycle checks, and shared WebCrypto vector passed.
- Pinned Reel runtime cache and helper executables validated; the build script copied the runtime into the app resource input.
- No signed app was produced, so `codesign --verify` did not apply.
- **Kio was not launched or interactively tested by Codex.** No microphone, browser, physical phone, live provider, or live-media download was used. Visual, permission, live-service, and user-file checks remain manual; follow [the hardening-pass acceptance guide](MANUAL_ACCEPTANCE.md#hardening-pass--format-routing-media-contracts-reel-cue-and-phone-isolation).

## Current limitations and warnings

- Reel supports public sources only when yt-dlp, Streamlink, or direct media resolution can handle them. Authentication-only and DRM-protected sources are not bypassed. Gallery downloads remain unavailable. No claim of universal provider coverage is made.
- WebP output depends on an ImageIO WebP encoder being available on the user's macOS runtime. Incompatible WebM video re-encoding is not advertised as supported; compatible streams can be copied, and unsupported combinations fail clearly.
- The local Debug and Release products are unsigned CI-style builds. The manual development installer/signing path is separate.
- Xcode reports that the `Require prepared Reel runtime` build phase has no declared outputs and therefore runs each build; this is a non-fatal build-efficiency warning. Xcode also reports that bundled upstream signed helper binaries cannot be stripped; both builds still succeed.
