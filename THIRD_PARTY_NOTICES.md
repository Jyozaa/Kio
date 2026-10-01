# Third-party notices

## Apple frameworks

The Mac application uses PDFKit, Core Graphics, ImageIO, AVFoundation, AppKit, SwiftUI, Uniform Type Identifiers, SwiftData, CryptoKit, Security, and the system zlib library through the macOS SDK. These are provided by macOS/Xcode; Kio does not bundle a separate copy of zlib.

## Swift package dependencies

Versions are pinned in `Packages/KioKit/Package.resolved`. Copyright and license notices are retained in the source distributions and must be included with any redistributed package binaries.

- [mlx-swift-lm 3.31.4](https://github.com/ml-explore/mlx-swift-lm) — MIT.
- [mlx-swift 0.31.6](https://github.com/ml-explore/mlx-swift) — MIT.
- [swift-huggingface 0.9.0](https://github.com/huggingface/swift-huggingface) — Apache-2.0.
- [swift-transformers 1.3.4](https://github.com/huggingface/swift-transformers) — Apache-2.0.
- [SwiftSoup 2.13.3](https://github.com/scinfu/SwiftSoup) — MIT; used for parsing untrusted public HTML as data.
- [CoreXLSX 0.14.1](https://github.com/CoreOffice/CoreXLSX) — Apache-2.0; read-only XLSX import, bounded before XML parsing.
- [XMLCoder 0.11.1](https://github.com/CoreOffice/XMLCoder) — MIT; transitive CoreXLSX XML decoding dependency.
- [ZIPFoundation 0.9.20](https://github.com/weichsel/ZIPFoundation) — MIT; transitive CoreXLSX ZIP reading dependency and Kio's archive-size preflight.
- Transitive packages pinned in `Package.resolved`: swift-argument-parser 1.8.2, swift-asn1 1.7.3, swift-collections 1.7.1, swift-crypto 4.5.2, swift-jinja 2.5.1, swift-numerics 1.1.1, swift-syntax 603.0.2, yyjson 0.12.0, and EventSource 1.5.1. Their upstream license files are Apache-2.0 or MIT as published by each repository.

The Qwen model weights are a separately downloaded asset and are not included in this repository or app bundle. The selected quantized repository identifies its license as Apache-2.0; see the model card linked in `docs/LOCAL_MODEL.md`.

## Phone app and relay development tools

`apps/mobile/package-lock.json` and `apps/relay/package-lock.json` pin JavaScript build/deployment tools. The deployed PWA bundles React and React DOM (MIT). Vite and TypeScript are build tools and are not needed by the deployed phone client. Wrangler, TypeScript, and Cloudflare Workers type packages are developer tooling; they are not included in the Kio Mac app. See each pinned package's upstream `LICENSE` and `NOTICE` files before redistributing its source or binaries.

The phone uses the browser's Web Crypto API. The relay is built on Cloudflare Workers and D1 and stores file chunks in D1; it does not ship a separate server runtime dependency.

The retained experimental CUA implementation under `apps/macos` and `agent` has separate notices and attribution in [the legacy implementation notices](docs/LEGACY_THIRD_PARTY_NOTICES.md).

## Reel helpers installed on demand

These executables and the Python runtime are **not committed or bundled in Kio**. Kio downloads them only after the user invokes **Prepare Reel**, verifies each artifact against a pinned SHA-256 value, and installs under `~/Library/Application Support/Kio/Helpers/`. The active manifest and exact URLs/digests are in `Packages/KioKit/Sources/KioTools/ReelWorkflow.swift` and `Packages/KioKit/Sources/KioTools/Resources/StreamlinkWheels.json`.

| Component | Pinned artifact | License | Delivery |
|---|---|---|---|
| [yt-dlp](https://github.com/yt-dlp/yt-dlp/releases/tag/2026.08.19) | 2026.08.19, `yt-dlp_macos`, universal macOS executable | Unlicense | Downloaded on demand; SHA-256 pinned in Kio |
| [gallery-dl](https://github.com/gdl-org/builds/releases/tag/2026.10.01) / [gallery-dl source](https://github.com/mikf/gallery-dl) | 1.32.14, `gallery-dl_macos` | GPL-2.0-only | Downloaded on demand; SHA-256 pinned in Kio |
| [FFmpeg](https://ffmpeg.martin-riedl.de/) and ffprobe | 9.0.2 Apple Silicon archives from the pinned build URL | GPL build (x264/x265 enabled), GPL-2.0-or-later terms | Separate on-demand binaries; SHA-256 pinned in Kio; not bundled |
| [python-build-standalone](https://github.com/astral-sh/python-build-standalone/releases/tag/20260901) | CPython 3.12.14, aarch64 Apple macOS `install_only_stripped` archive | PSF-2.0 for CPython; archive component license notices are retained with the installed runtime | Downloaded on demand; SHA-256 pinned in Kio |
| [Streamlink](https://streamlink.github.io/) | 8.6.0 Python wheel | BSD-2-Clause | PyPI wheel downloaded on demand; SHA-256 pinned |

FFmpeg's selected third-party build enables GPL-licensed x264/x265 codecs, so the delivered FFmpeg binaries are identified as GPL builds rather than described as LGPL-only. See [FFmpeg's license and legal considerations](https://ffmpeg.org/legal.html). Users who redistribute an FFmpeg binary must review the precise binary's corresponding-source and license obligations; these notices do not provide legal advice.

### Streamlink Python wheel set

Streamlink's pinned wheel manifest installs its CLI plus these 19 runtime dependencies into the isolated Python 3.12.14 runtime. Each wheel has a fixed PyPI URL and SHA-256 in `StreamlinkWheels.json`; wheel license files stay in the extracted package metadata.

| Distribution | Version | License recorded in the manifest |
|---|---:|---|
| Streamlink | 8.6.0 | BSD-2-Clause |
| certifi | 2026.7.22 | MPL-2.0 |
| isodate | 0.7.2 | BSD-3-Clause |
| lxml | 6.1.3 | BSD-3-Clause |
| pycountry | 26.2.16 | LGPL-2.1-only |
| pycryptodome | 3.23.0 | BSD-3-Clause / public-domain components |
| PySocks | 1.7.1 | BSD |
| requests | 2.34.2 | Apache-2.0 |
| trio | 0.34.0 | MIT OR Apache-2.0 |
| trio-websocket | 0.12.2 | MIT |
| urllib3 | 2.8.0 | MIT |
| websocket-client | 1.9.2 | Apache-2.0 |
| charset-normalizer | 3.5.2 | MIT |
| idna | 3.20 | BSD-3-Clause |
| attrs | 26.1.0 | MIT |
| sortedcontainers | 2.4.0 | Apache-2.0 |
| outcome | 1.3.0.post0 | MIT OR Apache-2.0 |
| sniffio | 1.3.1 | MIT OR Apache-2.0 |
| wsproto | 1.3.2 | MIT |
| h11 | 0.16.0 | MIT |

### Cue reference

[Textream](https://github.com/f/textream) was inspected as a reference for speech partials, recent-position agreement, and keeping the current line visible. Kio's Cue alignment, capture, and UI are independently implemented; no Textream source files or code were copied or adapted, and no Textream project component is shipped. The reference project is MIT-licensed; see its [upstream license](https://github.com/f/textream/blob/master/LICENSE).
