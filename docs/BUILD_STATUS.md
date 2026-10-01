# Kio build and verification status

Last updated: 2026-10-01

## Source and signing

- Checkout: `/Users/joe/Desktop/Kio`, branch `main`, HEAD `5cbd55889642c82be6525d5e28e8e41fa87b276d` (`improvements`). Feature changes described below are in the uncommitted working tree; nothing was committed or pushed.
- Origin: `https://github.com/Jyozaa/Kio.git`. GitHub Actions run [36808319264](https://github.com/Jyozaa/Kio/actions/runs/36808319264) for the committed HEAD was `in_progress` when this file was updated. CI does not cover the uncommitted work.
- Canonical local app: `/Users/joe/Applications/Kio.app`, bundle ID `app.kio.mac`. The existing stable self-signed development identity has fingerprint `D1BE804340BFDABFA94E9881FC65357B5B404338`; its private key remains in the user's login Keychain. This pass did not create an Apple Development certificate or run the install/launch script.
- Project version/build: `0.1.0` / `1`.

## Implemented in the working tree

- 14 agents: Kio, Pip, Pixel, Zip, Echo, Clerk, Courier, Scribe, Table, Lens, Scout, Patch, Reel, and Cue. The typed registry has 95 `ToolOperation` cases.
- The notch is modeled as idle/composer, preparing, working, result, clarification/error, Cue setup, and Cue active states. Its collapsed presentation has no character/content payload; expanded content uses the same progress value for shell masking and clipping. The full chat header and search were simplified, with Crew behind a compact menu.
- Character bodies now use a subtle outline, low-key asymmetry, black eyes, randomized single/double blink timing, gaze/lean, role motion, and success movement. These visual behaviors have not been manually observed in the app.
- Intelligence settings include Deterministic / No AI, OpenAI, Anthropic, Gemini, OpenRouter, Groq, and Local Qwen. BYOK keys use provider-specific macOS Keychain services. Cloud calls go directly to the selected HTTPS endpoint; no silent provider fallback is configured. Content transfer defaults to asking before document text is sent.
- Reel has seven registered operations for inspect, video, audio, live, gallery, captions, and thumbnail acquisition. It uses native downloads for direct public media and pinned yt-dlp, Streamlink, gallery-dl, and FFmpeg/ffprobe helpers otherwise. The helpers and Streamlink's pinned Python runtime/wheels download only through the explicit Prepare Reel flow, are SHA-256 checked before install, and live in `~/Library/Application Support/Kio/Helpers/`. No browser cookies or DRM bypass are used.
- Pixel adds runtime-checked HEIC/HEIF, JPEG, PNG, TIFF, BMP input and available JPEG, PNG, HEIC, TIFF, and WebP encoders; batch conversion and batch background removal are registered. Encoder availability depends on ImageIO on the user's macOS version.
- Cue provides classic, voice-paced, and word-tracking modes, with local script alignment and lazy microphone/Speech Recognition requests only when a microphone mode starts. No live audio was captured or tested.
- The mobile roster/styles know about Reel and Cue. The relay/PWA was not deployed.

## Non-interactive verification

- `swift test --scratch-path /tmp/KioSwiftScratch --package-path Packages/KioKit --filter KioCoreTests`: 67 tests passed, including planner routing, presentation/motion policies, provider request construction, and Cue alignment state.
- `swift test --scratch-path /tmp/KioSwiftScratch --package-path Packages/KioKit --filter KioToolsTests`: 47 tests passed, including Pixel conversions, batch operations, and typed Reel command/backend checks.
- `npm ci --prefix apps/mobile`: passed. `npm --prefix apps/mobile run typecheck` and `npm --prefix apps/mobile run build`: passed; Vite produced the production PWA bundle in `apps/mobile/dist`.
- Final macOS Debug build: passed using `xcodebuild` with `CODE_SIGNING_ALLOWED=NO`; the app was not launched. `git diff --check`: passed.

## Manual testing still required

The app, browser, and microphone were not opened for this pass. Notch geometry/animation, full-chat appearance, Keychain persistence, real provider calls, permissions, Cue speech behavior, helper installation against the network, and permitted-media downloads all require the user to check manually. Use the detailed steps and failure indicators in [Manual acceptance](MANUAL_ACCEPTANCE.md). No live provider API, YouTube/media download, phone pairing, release packaging, deployment, or interactive permission flow was run.
