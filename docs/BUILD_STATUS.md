# Kio build and verification status

Last updated: 2026-10-01

## Source and signing

- Checkout: `/Users/joe/Desktop/Kio`, branch `main`, HEAD `90ab486345fb85a1ad1337f10e79a7dae1514ed6` (`byok and agents`). The focused Cue UI correction is in the uncommitted working tree; nothing was committed or pushed.
- Origin: `https://github.com/Jyozaa/Kio.git`. GitHub and remote CI were not queried or changed during this pass; the Cue correction remains local and unpushed.
- Development install target: `/Users/joe/Applications/Kio.app`, bundle ID `app.kio.mac`. The app bundle was removed at the user's request and was not reinstalled or launched in this pass. `bash scripts/dev-run.sh` is the documented build/install/launch command for manual acceptance.
- Project version/build: `0.1.0` / `1`.

## Implemented in the working tree

- 14 agents: Kio, Pip, Pixel, Zip, Echo, Clerk, Courier, Scribe, Table, Lens, Scout, Patch, Reel, and Cue. The typed registry has 95 `ToolOperation` cases.
- The notch is modeled as idle/composer, preparing, working, result, clarification/error, Cue setup, and Cue active states. Its collapsed presentation has no character/content payload; expanded content uses the same progress value for shell masking and clipping. The full chat header and search were simplified, with Crew behind a compact menu.
- Character bodies now use a subtle outline, low-key asymmetry, black eyes, randomized single/double blink timing, gaze/lean, role motion, and success movement. These visual behaviors have not been manually observed in the app.
- Intelligence settings include Deterministic / No AI, OpenAI, Anthropic, Gemini, OpenRouter, Groq, and Local Qwen. BYOK keys use provider-specific macOS Keychain services. Cloud calls go directly to the selected HTTPS endpoint; no silent provider fallback is configured. Content transfer defaults to asking before document text is sent.
- Reel has seven registered operations for inspect, video, audio, live, gallery, captions, and thumbnail acquisition. It uses native downloads for direct public media and pinned yt-dlp, Streamlink, gallery-dl, and FFmpeg/ffprobe helpers otherwise. The helpers and Streamlink's pinned Python runtime/wheels download only through the explicit Prepare Reel flow, are SHA-256 checked before install, and live in `~/Library/Application Support/Kio/Helpers/`. No browser cookies or DRM bypass are used.
- Pixel adds runtime-checked HEIC/HEIF, JPEG, PNG, TIFF, BMP input and available JPEG, PNG, HEIC, TIFF, and WebP encoders; batch conversion and batch background removal are registered. Encoder availability depends on ImageIO on the user's macOS version.
- Cue provides classic, voice-paced, and word-tracking modes, with local script alignment and lazy microphone/Speech Recognition requests only when a microphone mode starts. This pass gives Cue the full notch content area, removes the normal mascot from Cue, compacts its setup controls, and reserves stable spacing for the active word highlight. No live audio was captured or tested; visual acceptance requires user testing.
- The mobile roster/styles know about Reel and Cue. The relay/PWA was not deployed.

## Non-interactive verification

- `swift test --scratch-path /tmp/KioSwiftScratch --package-path Packages/KioKit --filter KioCoreTests`: 67 tests passed, including planner routing, presentation/motion policies, provider request construction, and Cue alignment state.
- `swift test --scratch-path /tmp/KioSwiftScratch --package-path Packages/KioKit --filter KioToolsTests`: 47 tests passed, including Pixel conversions, batch operations, and typed Reel command/backend checks.
- `npm ci --prefix apps/mobile`: passed. `npm --prefix apps/mobile run typecheck` and `npm --prefix apps/mobile run build`: passed; Vite produced the production PWA bundle in `apps/mobile/dist`.
- Cue-related `KioCoreTests`: 77 tests passed, including Cue text alignment and notch presentation states.
- Mac app Debug build: passed with `xcodebuild -project apps/mac/KioMac.xcodeproj -scheme KioMac -configuration Debug -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation -skipPackageUpdates CODE_SIGNING_ALLOWED=NO build`. The app was not launched. `git diff --check`: passed.

## Manual testing still required

Kio was not launched or visually tested by Codex. Cue notch geometry/animation, setup/active/completion appearance, live word following, and permission behavior require manual acceptance. Follow the Cue checklist supplied with this change. No live provider API, YouTube/media download, phone pairing, release packaging, deployment, or interactive permission flow was run.
