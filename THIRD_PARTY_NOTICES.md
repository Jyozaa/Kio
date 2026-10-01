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
