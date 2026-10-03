# Kio v2 build and verification status

Last updated: 2026-10-02

## Repository state

- Repository: `/Users/joe/Desktop/Kio`; branch: `main`; remote: `https://github.com/Jyozaa/Kio.git`.
- Starting HEAD: `efbe7b33c6195cbb2929df7ba3964eb65fedc3d4` (`fixed reel and tele`). The worktree changes are local and uncommitted; final HEAD remains unchanged unless the user commits them.
- The latest pre-change GitHub Actions run was [37012487283](https://github.com/Jyozaa/Kio/actions/runs/37012487283), for the starting commit. It was still `in_progress` when checked. It cannot validate these uncommitted edits. No post-change run exists because the changes have not been pushed.

## Migration summary

Kio is being reshaped into a native notch dashboard with **Kio**, **Sessions**, **Clipboard**, and **News** spaces. Kio contains Convert, Reel, and Cue. The old full chat app, provider/LLM planner stack, local-model downloads, specialist-agent UI, mobile PWA, phone pairing, relay, remote task handling, and generic file/workflow tools were removed from the current product and build graph. Git history is preserved.

The retained package has only KioCore, KioModel, and KioTools, with no external Swift package dependencies. Native typed operations remain for Convert and Reel. Cue's speech tracking stays in KioModel; the new presentation uses fixed 17.5 pt measured lines, stable per-word geometry, justified eligible lines, and a gentle whole-document offset when the reading line changes.

The Mac app now uses a borderless notch panel and four dashboard spaces. Session hook installation is opt-in for Claude Code, Codex, Cursor, and OpenCode. Clipboard capture is opt-in and bounded locally. News uses user-configured HTTPS RSS/Atom feeds and explicit refresh, with ambient alerts only for selected topics. The app bundle has a generated Kio app icon that can be replaced by final brand artwork.

## Verification

Final broad check: `./scripts/check.sh` passed on 2026-10-02. It ran `git diff --check`, 14 Python helper tests, 32 Swift package tests (16 Reel, 4 Convert integration/regression, and 12 dashboard/session/clipboard/news/Cue), prepared Reel runtime validation, and noninteractive Xcode Debug and Release builds. The build emitted asset-catalog warnings for the app icon metadata and the Xcode destination-selection warning; both configurations completed successfully. The check did not launch or open Kio.

Final-check iterations exposed and fixed the Reel source-format picker and Codex hook normalization cases, then added retained Convert coverage for image conversion/resize, PDF creation/merge/compression, and MP3 extraction from video. `ToolExecutor` now accepts an optional runtime root so media integration coverage can use the same pinned runtime built by the check script while the app continues to default to its bundled runtime. The final broad check passed with those paths covered.

The latest GitHub Actions run remains [37012487283](https://github.com/Jyozaa/Kio/actions/runs/37012487283), still `in_progress` for the starting commit. It predates and cannot validate the local uncommitted changes. No post-change run exists because the changes have not been pushed.

Independent interaction remains unverified by Codex. The app was not launched, no UI automation was used, and no microphone permission was requested. Use [the manual acceptance guide](MANUAL_ACCEPTANCE.md) to review the interactive behavior yourself.

## Known scope limits

- PDF-to-image is not implemented. Convert provides PDF merge/compression and images-to-PDF.
- Image target-size compression outputs JPEG; choose JPEG for an image size target.
- Supported media formats vary with the prepared pinned runtime and source codecs. Reel will report unsupported conversion paths instead of claiming they work.
- Reel source-audio ranking depends on language/original metadata provided by the source extractor. The interface shows “Original audio preferred”; there is no language picker.
- Reel live-source download support depends on Streamlink/source compatibility. Authentication and DRM are unsupported.
- Provider hook delivery and field shapes depend on provider versions/settings and need user-side acceptance.
- macOS frontmost-app identification for clipboard exclusions is best-effort. Some apps may not label concealed/transient pasteboard content.
- Follow My Voice needs a real microphone/permission check by the user. Classic mode does not use the microphone.

For implementation details, see [Architecture](KIO_ARCHITECTURE.md); for scope, see [Product](PRODUCT.md).
