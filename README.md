# Kio

Kio is a local-first macOS assistant built around the MacBook notch. Deterministic requests use registered native workflows; semantic planning and writing use the provider selected in Settings, with Local Qwen remaining optional. Transformations preserve their sources; moving files requires explicit confirmation. Completed outputs are checked before Kio reports success.

## What works

Kio accepts dropped files and folders, pasted text/URLs/images/files, screenshots copied to the clipboard, and explicit region captures. Finder's **Send to Kio** service can attach selected files. Fast paths handle obvious requests without starting an AI model. Optional BYOK providers and on-device Qwen can select only registered operations.

- **PDFs:** merge, combine PDFs and images in selection order, inspect, search selectable text with page snippets, extract text, OCR, split, reorder, rotate, remove pages, remove blank pages, extract pages, and compress.
- **Images and visual understanding:** single and batch resize/convert, rotate, manual and Vision smart crop, compress, metadata removal, contact sheets, approximate image comparison/similarity, Vision background removal, OCR, table extraction, structured text, and receipt fields.
- **Pixel formats:** HEIC/HEIF, JPEG, PNG, TIFF, and BMP input where ImageIO supports decoding; output is selected from runtime-supported JPEG, PNG, HEIC, TIFF, and WebP encoders. Transparent-to-JPEG conversion uses a white background; first-frame-only animated conversion is identified.
- **Tables:** quoted CSV/TSV and JSON table parsing; inspect/statistics, merge, deduplicate, sort, filter, select/rename/reorder columns, normalize, compare, and CSV/JSON conversion. XLSX import is read-only, bounded, and exports values to CSV; it does not calculate formulas or preserve workbook formatting/macros.
- **Text and code:** local-model summarize, rewrite, proofread, translate, key points, action items, Markdown conversion, comparison, and explanation. Patch proposes a separate copy and diff; it never runs generated code or replaces the source automatically.
- **Web and URLs:** Scout fetches public HTTP(S) pages for readable text or links, searches free Crossref and Europe PMC research metadata, and treats page content as untrusted data.
- **Online media:** Reel inspects public media URLs, offers normalized quality/format choices, and downloads permitted video, audio, live streams, galleries, captions, and thumbnails through pinned, checksum-verified helpers prepared only on request. Reel does not read browser cookies or bypass DRM.
- **Local media:** inspect, thumbnail, trim or extract a clip, resize, transcode, compress, extract/convert audio to M4A, and optional on-device transcription/subtitles.
- **Cue:** an in-notch teleprompter with speech word tracking, classic timed scrolling, and voice-paced scrolling. Microphone and Speech Recognition permissions are requested only when a microphone mode starts.
- **Intelligence:** Deterministic / No AI, OpenAI, Anthropic, Gemini, OpenRouter, Groq, and Local Qwen. Provider keys stay in macOS Keychain and cloud requests go directly to the selected provider; document-content transfer asks first by default.
- **Files:** conflict-safe rename copies, duplicate reports, date/type organization into verified copies, ZIP creation/inspection/safe extraction, and confirmed file moves.
- **Workflows and history:** typed reusable workflow templates, shared contextual action chips in the notch and full chat, local artifact references, and searchable on-device conversations.
- **Mobile:** optional encrypted PWA pairing, multi-file transfer in both directions, camera/photo/file and URL sharing, retryable offline queue, task progress, output downloads, and notifications where supported.

See [Build status](docs/BUILD_STATUS.md) for the checked paths and known gaps.

## Build the Mac app

Requirements: Apple Silicon Mac, macOS 14+, Xcode, Swift 6, Node.js 22.12+, and npm.

```sh
bash scripts/check.sh
bash scripts/build-mac.sh
```

The canonical check installs the PWA and relay dependencies with `npm ci` from their lockfiles before building them. `bash scripts/bootstrap.sh` is optional when you only want to pre-resolve the Swift package.

For a stable local development signature and canonical install location, see [Stable local macOS development signing](docs/DEV_SIGNING.md) and run `bash scripts/dev-run.sh`. This selects the existing self-signed local identity, not an Apple Development certificate, and installs to `~/Applications/Kio.app`. It does not create or import a signing key. Public builds use a separate signing path.

Package an ad-hoc-signed Release app and DMG:

```sh
bash scripts/package-dmg.sh
```

The app and checksum are written under `build/release/`. The ad-hoc signature is for local use and does not provide Gatekeeper distribution; public release needs Developer ID signing and notarization.

## Develop the phone app and relay

```sh
npm ci --prefix apps/mobile
npm --prefix apps/mobile run dev

npm ci --prefix apps/relay
npm --prefix apps/relay run typecheck
bash apps/relay/scripts/check-local.sh
```

The PWA is a static Vite build in `apps/mobile/dist`; Wrangler serves it from the Worker. Run `npx wrangler login` once, then `bash scripts/deploy-relay.sh`. The script prepares the free D1 database, applies migrations, builds the PWA, and deploys. Follow [Mobile pairing](docs/MOBILE_PAIRING.md) to pair. Cloudflare authorization is required only to deploy the optional relay; Mac file processing does not require it.

The previously deployed phone app is available at [kio-relay.kio-relay.workers.dev](https://kio-relay.kio-relay.workers.dev). It may lag behind the current source until the latest PWA and Worker are deployed. Pair it from Kio Settings before sending tasks.

## Architecture and privacy

The model can choose only typed, registered tools. Native Swift code validates inputs and performs the work. There is no arbitrary shell, GUI-control, or remote execution capability. The local-first app does not require an account or cloud service. Read [Architecture](docs/KIO_ARCHITECTURE.md), [Privacy](docs/PRIVACY.md), and [Security](docs/SECURITY.md).

The earlier experimental CUA implementation remains separate under `apps/macos` and `agent` on this branch; this new app lives under `apps/mac` and does not use those components. Its former guide is in [LEGACY_README.md](LEGACY_README.md), its check script is retained as [check-legacy.sh](scripts/check-legacy.sh), and its dependency notices remain in [the legacy notices file](docs/LEGACY_THIRD_PARTY_NOTICES.md).
