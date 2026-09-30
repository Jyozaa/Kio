# Kio

Kio is a local-first macOS file assistant built around the MacBook notch. Add files, describe a supported task, and Kio plans it locally and runs a registered native workflow. Originals are preserved; completed outputs are checked before Kio reports success.

## What works

- Native SwiftUI/AppKit notch panel, menu bar entry, conversation window, drag and drop, and Option-Command-K shortcut.
- Deterministic PDF merge/page removal/compression, image-to-PDF/resize/convert, conflict-safe batch rename copies, ZIP creation, and audio extraction from video.
- Task-local follow-ups and persistent on-device conversation history.
- Optional on-device MLX planner using Qwen3.5 2B 4-bit. The model download and a model-planned image-to-PDF workflow were exercised in the built app; no hosted AI API is used.
- Optional mobile PWA paired by a one-time QR code. P-256 ECDH, HKDF, and AES-GCM protect message and file contents end to end; the Mac remains the execution authority.
- Optional Cloudflare Worker + D1 relay. The relay stores envelope ciphertext and temporary encrypted file chunks, not readable task content.

See [Build status](docs/BUILD_STATUS.md) for the checked paths and known gaps.

## Build the Mac app

Requirements: Apple Silicon Mac, macOS 14+, Xcode, Swift 6, Node.js 22.12+, and npm.

```sh
bash scripts/check.sh
bash scripts/build-mac.sh
```

The canonical check installs the PWA and relay dependencies with `npm ci` from their lockfiles before building them. `bash scripts/bootstrap.sh` is optional when you only want to pre-resolve the Swift package.

Package a locally signed app and DMG:

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

The deployed phone app is available at [kio-relay.kio-relay.workers.dev](https://kio-relay.kio-relay.workers.dev). Pair it from Kio Settings before sending tasks.

## Architecture and privacy

The model can choose only typed, registered tools. Native Swift code validates inputs and performs the work. There is no arbitrary shell, GUI-control, or remote execution capability. The local-first app does not require an account or cloud service. Read [Architecture](docs/KIO_ARCHITECTURE.md), [Privacy](docs/PRIVACY.md), and [Security](docs/SECURITY.md).

The earlier experimental CUA implementation remains separate under `apps/macos` and `agent` on this branch; this new app lives under `apps/mac` and does not use those components. Its former guide is in [LEGACY_README.md](LEGACY_README.md), its check script is retained as [check-legacy.sh](scripts/check-legacy.sh), and its dependency notices remain in [the legacy notices file](docs/LEGACY_THIRD_PARTY_NOTICES.md).
