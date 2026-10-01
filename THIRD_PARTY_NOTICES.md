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

## Reel runtime bundled with Kio

The Reel runtime is assembled from pinned arm64 macOS artifacts during an explicit developer/package build by `scripts/build-reel-runtime.sh`. Build downloads are checksum-verified and cached in `.cache/reel/`; Kio itself does not download, install, or update helper runtimes. The built app carries these files under `Contents/Resources/Reel`, the manifest, and a copy of the applicable notices.

| Component | Pin / architecture | License | Upstream and redistribution details |
|---|---|---|---|
| [yt-dlp](https://github.com/yt-dlp/yt-dlp/releases/tag/2026.08.19) | 2026.08.19, universal macOS executable; SHA-256 `0f192b7ec147ab6288885d6351d9ab67367640029b4377576ef46dd79cf7b202` | Unlicense | Official release binary; Unlicense text is included in the app. |
| [Deno](https://github.com/denoland/deno/releases/tag/v2.9.7) | 2.9.7, arm64 Apple Darwin; SHA-256 `5cd46d6268f6f78f5d88bdc7159d20bd44cdaa4b3303474839f87ec6fe7ae25c` | MIT | Official `deno-aarch64-apple-darwin.zip` executable; copyright/license text is included in the app. |
| [FFmpeg / ffprobe](https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz) | 9.0.2, arm64 macOS; source SHA-256 `8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e` | LGPL-2.1-or-later build | Built from the exact accompanying upstream source archive with `--disable-gpl --disable-version3 --disable-nonfree`; shared libraries and source/build configuration ship in the app. No x264/x265 or GPL option is enabled. |
| [LAME](https://sourceforge.net/projects/lame/files/lame/3.100/) | 3.100, arm64 macOS; source SHA-256 `ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e` | LGPL-2.0-or-later | Shared `libmp3lame` linked for MP3 audio conversion; exact source archive and license ship in the app. |
| [python-build-standalone / CPython](https://github.com/astral-sh/python-build-standalone/releases/tag/20260901) | CPython 3.12.14, aarch64 Apple Darwin; SHA-256 `81a359f1cfadd4da11766534c5913791cea55f26e1bb902cacd2a531bb1e4b2b` | PSF-2.0 plus notices of included build components | Pinned install-only runtime and its license metadata are shipped in the app. The build script discovers the interpreter path from the verified archive rather than assuming a nested layout. |
| [Streamlink](https://github.com/streamlink/streamlink/releases/tag/8.6.0) | 8.6.0, Python 3.12 wheel set; each wheel URL and SHA-256 is in `ReelRuntime.json` | BSD-2-Clause plus per-dependency terms below | Pinned wheels are checksum-verified at build time, extracted to isolated bundled site-packages, and their license metadata stays with the installed distributions. |

### Streamlink wheel licenses

The machine-readable `ReelRuntime.json` contains the full filenames, versions, upstream wheel URLs, SHA-256 digests, and license labels used by build preparation, tests, and diagnostics. Bundled wheels include: Streamlink 8.6.0 (BSD-2-Clause); certifi 2026.7.22 (MPL-2.0); isodate 0.7.2 (BSD-3-Clause); lxml 6.1.3 (BSD-3-Clause); pycountry 26.2.16 (LGPL-2.1-only); pycryptodome 3.23.0 (BSD-3-Clause/public-domain components); PySocks 1.7.1 (BSD); requests 2.34.2 (Apache-2.0); trio 0.34.0 (MIT OR Apache-2.0); trio-websocket 0.12.2 (MIT); urllib3 2.8.0 (MIT); websocket-client 1.9.2 (Apache-2.0); charset-normalizer 3.5.2 (MIT); idna 3.20 (BSD-3-Clause); attrs 26.1.0 (MIT); sortedcontainers 2.4.0 (Apache-2.0); outcome 1.3.0.post0 (MIT OR Apache-2.0); sniffio 1.3.1 (MIT OR Apache-2.0); wsproto 1.3.2 (MIT); and h11 0.16.0 (MIT). Wheel license/metadata files are retained in the app.

### Gallery download exclusion

`gallery-dl` 1.32.14 is GPL-2.0-only and is not bundled. The repository contains no project-level Kio license declaration, so the project does not establish redistribution terms compatible with distributing this GPL-only executable alongside the app. Gallery downloads are therefore reported as unavailable; Reel's direct media, video, audio, captions, thumbnails, and live-source features use the bundled runtime where applicable. This is a distribution-policy constraint, not a checksum or setup limitation.

Redistributors should preserve the included notices, license texts, FFmpeg/LAME corresponding source archives, and build configuration. These notices identify the selected artifacts and their license terms; they are not legal advice.

### Cue reference

[Textream](https://github.com/f/textream) was inspected as a reference for speech partials, recent-position agreement, and keeping the current line visible. Kio's Cue alignment, capture, and UI are independently implemented; no Textream source files or code were copied or adapted, and no Textream project component is shipped. The reference project is MIT-licensed; see its [upstream license](https://github.com/f/textream/blob/master/LICENSE).
