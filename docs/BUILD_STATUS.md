# Kio build status

## Current milestone

Deployed release candidate. The optional PWA and encrypted relay are live at <https://kio-relay.kio-relay.workers.dev>; the Mac app works locally without them.

## Current status and next step

The deployed relay is connected and Kio reports one paired phone online. Pairing, the live Chrome PWA round trip for “Is my Mac online?”, a remote image-to-PDF task, a follow-up rename of its result, and offline queue/reconnect are verified. A generated 96×64 PNG produced a valid one-page 96×64 PDF; the phone then renamed the latest result to `Kio-Mobile-Followup.pdf`, preserving the original. Both outputs are in `~/Downloads/Kio`. For the offline check, the Release app was stopped, the PWA showed a queued status question, and after relaunch Kio processed it and returned the reply to both the phone and Mac history. The deterministic, read-only fast path bypasses model planning and has unit coverage. The user confirmed that Add to Home Screen works on iOS. Next acceptance step: validate a file task from the physical iPhone.

## Implemented

- Native macOS notch shell, menu bar, drag and drop, chat window, shortcut, settings, motion controls, and local persistent conversation history.
- Bounded deterministic planner and strict typed plan decoder.
- Verified native workflows: PDF merge and page removal; image-to-PDF, resize, and format conversion; readable-copy PDF compression; conflict-safe batch rename copies; ZIP archive creation; video audio extraction.
- Optional MLX Swift LM path with explicit Qwen3.5 2B 4-bit download, cache, progress, load/unload, and local plan decoding; model-planned image-to-PDF inference was exercised in the app.
- Mobile PWA with one-time QR pairing, encrypted message history, reconnect/offline status, remote requests, and encrypted file attachments/results up to 50 MiB.
- Mac-online status questions from the phone use a deterministic reply fast path instead of the file-operation planner.
- Cloudflare Worker relay with remote D1 migrations, offline encrypted message queue, device revocation, encrypted temporary file chunks, size bounds, expiry cleanup, local integration smoke coverage, and a deployed PWA.
- Build, check, and DMG packaging scripts.

## Verification in this checkout

- `bash scripts/check.sh` — passed: 19 Swift tests, Debug macOS build, TypeScript check and production PWA build, relay typecheck, local Wrangler/D1 integration smoke, and Swift CryptoKit/WebCrypto interoperability vector.
- `bash scripts/package-dmg.sh` — passed: Release app build and signature verification, DMG creation and verification, and SHA-256 checksum generation.
- Public deployment check — `https://kio-relay.kio-relay.workers.dev/api/health` returned `{"ok":true,"version":1}`, the deployed PWA loaded, and Wrangler reported no pending remote migrations.
- Manual app check — launched the built Mac app, downloaded and ran the local model on an image-to-PDF task, verified the PDF output, quit and relaunched Kio, and confirmed SwiftData restored the conversation.

## Not verified or not shipped

- Only a focused model-backed workflow was exercised; all model prompts/tool selections are not covered. The model is optional; deterministic fast paths do not require it.
- Pairing, live status reply, remote image-to-PDF, follow-up rename, and offline queue/reconnect through the paired Chrome PWA are verified. The user confirmed iOS Add to Home Screen works; a physical iPhone file-task round trip was not independently observed. Local WebCrypto/Worker interoperability is covered by the smoke script.
- Public Worker health, PWA, device pairing, one remote image-to-PDF task, and offline status queue/reconnect are verified. Other remote file tasks remain unvalidated.
- No paid account or custom domain is required by the configured plan. Unsigned/notarized public Mac distribution is not included.
- The registered tool set is intentionally narrower than arbitrary file management or universal GUI automation. Unregistered requests are clarified or rejected.

## Outputs

`bash scripts/package-dmg.sh` creates `build/release/Kio-0.1.0.dmg` and its `.sha256` file. The `.app` is in `Build/Products/Release` under the path printed by `scripts/build-mac.sh` (set `KIO_DERIVED_DATA_PATH` to choose a stable location). Ad-hoc signing is suitable for local testing, not direct Gatekeeper distribution.
