# Kio

Kio turns your MacBook notch into a local-first productivity dashboard.

The dashboard has four spaces:

- **Kio** — Convert files, inspect and download supported media with Reel, and present scripts with Cue.
- **Sessions** — passively monitor Claude Code, Codex, OpenCode, and Cursor lifecycle events through opt-in local hooks.
- **Clipboard** — keep a bounded local history of text, images, and file references.
- **News** — read headlines from configured RSS and Atom feeds. Headlines remain quiet unless a topic alert is enabled.

The notch is Kio’s primary interface. Hover or press **⌥⌘K** to open it. Drop files onto the notch, paste a public media link, or select a dashboard space. There is no full chat window, account, cloud model, or phone companion.

## Build

Requirements: Apple Silicon Mac, Xcode with macOS SDK, Swift 6, and network access to prepare Reel’s pinned runtime during the first build.

```sh
scripts/build-mac.sh
```

`scripts/build-mac.sh` builds and verifies the app bundle, prints its exact location, and does not open the app. For a source build with a persistent development identity, see [Development build and signing](docs/DEVELOPMENT_SIGNING.md).

To run the noninteractive checks:

```sh
scripts/check.sh
```

The check script runs Swift package tests, prepares/verifies Reel’s runtime, and builds the macOS app in Debug and Release. It does not launch Kio or request microphone access.

## Architecture and privacy

See [Product](docs/PRODUCT.md), [Architecture](docs/KIO_ARCHITECTURE.md), [Privacy](docs/PRIVACY.md), and [Security](docs/SECURITY.md). For user-run interaction checks, see the [manual acceptance guide](docs/MANUAL_ACCEPTANCE.md). Current build evidence is in [Build status](docs/BUILD_STATUS.md).

Kio’s Swift packages are intentionally small: `KioCore` contains file and operation types, `KioModel` contains deterministic conversion parsing and local dashboard stores, and `KioTools` contains the retained conversion and Reel engines. The Mac app owns the notch panel, dashboard views, Cue presentation, and optional session hook setup.

## Scope

Kio supports image conversion/resizing/compression; audio and video conversion where the bundled codecs can produce the requested result; PDF compression, merge, and image-to-PDF; Reel media inspection/video/audio/subtitle downloads; Cue; local session monitoring; clipboard history; and feed-based headlines. PDF-to-image, file organization, arbitrary PDF page edits, general AI chat/research/writing, and control of other apps are out of scope.

Reel’s bundled runtime contacts a media source only when the user requests inspection or a download. News requests go to the configured public feed URLs when the user refreshes. Session hooks and clipboard history are opt-in and store bounded local metadata/content as described in [Privacy](docs/PRIVACY.md).
