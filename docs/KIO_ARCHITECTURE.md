# Architecture

## Mac app

`apps/mac/KioMac` is the SwiftUI/AppKit host. A stable transparent host panel anchors to the notched display when available; an animatable silhouette expands inside it. The notch and the full conversation window observe one workspace and history. The menu bar exposes the conversation window, settings, and shortcut. `Packages/KioKit` contains:

- `KioCore`: artifact references, typed plans, operation identities, and validation.
- `KioModel`: deterministic fast paths and strict decoding of local-model plans against registered operations and actual artifact indexes.
- `KioTools`: native PDFKit, ImageIO, AVFoundation, and system zlib implementations, with conflict-safe output files and post-operation verification.
- `KioInference`: MLX Swift LM, Hugging Face model cache/download, and local planning.
- `KioSync`: Keychain-backed Mac identity, secure phone pairing, encrypted relay envelopes, and encrypted file transfers.
- `KioUI`: shared design tokens and character rendering.

The deterministic planner handles known requests first. The one local model is used only when a request needs broader planning. It receives a `submit_plan` tool schema through the pinned Qwen3.5 tool-call format; Kio never dispatches that synthetic tool. The result is decoded into a bounded `TaskPlan`, with at most one repair attempt. The model receives request text plus file names, types, sizes, and indexes. The executor alone resolves local URLs. The model cannot invoke shell commands or add tools.

Conversation entries and artifact references are persisted with SwiftData on the Mac. The last verified workflow and a bounded remote task-ID ledger are stored locally for safe follow-ups and relay redelivery handling. Each plan uses a stable snapshot of its original inputs and records outputs per step. Original input files are never overwritten by the registered transformations.

Execution status carries the task plan, current step and operation, active `AgentID`, progress text, counts, latest output, and failure/cancellation state. The notch and full chat share this state; remote progress envelopes carry the actual speaker and agent ID.

## Phone and relay

`apps/mobile` is a static React PWA. Pairing is initiated by the Mac and completed with a short-lived, single-use QR invitation. The phone creates a P-256 keypair. The Mac private key and bearer token are stored in Keychain; the phone private key is stored as a non-extractable `CryptoKey` in IndexedDB. Both sides derive AES-GCM keys with ECDH and HKDF.

`apps/relay` is a Cloudflare Worker backed by a single D1 database on the Workers Free plan. D1 stores device public keys, hashed bearer credentials, pairings, encrypted message envelopes, and encrypted file chunks. Downloads are acknowledged and deleted; uncollected transfers expire after 24 hours. File transfers are capped at 50 MiB each, 64 MiB of active encrypted files per workspace, and 384 MiB globally. A source IP can create up to five workspaces per UTC day; each paired device can upload up to twelve files per hour. The relay stores a hash, not a raw IP, for this limiter. Each D1 BLOB chunk is 1,000,000 bytes, below the platform's 2 MB row limit.

The Mac polls the relay and is the only executor. Offline phone requests remain queued. The Worker never runs a model or reads envelope/file plaintext. A deployed PWA and relay URL must be entered in Mac Settings before pairing; local Mac workflows do not depend on deployment.

## Earlier experimental implementation

The prior CUA-based assistant is retained separately in `apps/macos` and `agent` on the integrated repository branch. The new product does not import or execute that architecture.

## Assistant capabilities in the current tree

`AgentID` has 12 members: Kio, Pip, Pixel, Zip, Echo, Clerk, Courier, Scribe, Table, Lens, Scout, and Patch. The current typed operation registry has 87 `ToolOperation` cases. Plans may compose registered operations into bounded pipelines; each step receives only validated artifact references and typed arguments.

- **Scribe** sends bounded text from supported local text files to the local model for summaries, rewrites, proofreading, translation, key points, action items, Markdown conversion, comparison, or plain-language explanation. The output is a separate Markdown file.
- **Table** parses CSV/TSV and JSON for inspection, statistics, sorting, filtering, column selection/renaming/reordering, normalization, merge, deduplication, comparison, and format conversion. Its XLSX path reads cached cell values from bounded workbooks and creates CSV; it does not run Excel macros or recalculate formulas.
- **Lens** uses Apple Vision locally for image OCR, receipt extraction, table extraction, and structured text. **Scout** fetches readable content and links from permitted public HTTP(S) URLs. **Patch** uses the local model to explain or propose bounded text/code changes, then writes a separate copy and diff for review; it does not apply changes to the source or execute code.
- Explicit clipboard paste accepts text, URLs, images, and files. Screenshot capture is user-initiated. Finder Services can send selected files to the composer. Searchable history, recent-artifact references, contextual actions, and saved workflow templates are local Mac features.
- Pip combines selected PDF and image inputs in their original order into a bounded, verified PDF. The notch and full chat use the same type-aware quick-action catalog and planner route.
- The optional PWA supports multiple attachments, camera/share input, encrypted retry, specialist progress, result download, and opt-in browser notifications. The Mac remains the planner and executor. Changes in `apps/mobile` must be deployed separately before they appear at the public PWA origin.
