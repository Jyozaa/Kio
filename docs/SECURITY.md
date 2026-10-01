# Security

## Execution boundary

- No arbitrary shell, AppleScript, generic GUI automation, or model-generated code execution is registered.
- The model proposes a plan through a synthetic `submit_plan` tool schema; Kio never dispatches it. The decoder validates operation names, actual artifact indexes, argument types/ranges, and input kinds before execution. A single repair attempt is allowed; invalid plans are rejected.
- Deterministic Mac tools validate inputs and verify outputs. Transformations create conflict-safe copies; the explicit file-move operation requires a preview and user confirmation.
- Deterministic fast paths run before any model. The selected cloud provider may plan from the request and file metadata; strict native decoding still validates its output against registered operations and artifact indexes. No provider response can directly execute a command or choose an arbitrary path.
- BYOK keys exist only in macOS Keychain under provider-specific service names. Cloud API calls use HTTPS directly to the selected provider; they never pass through Kio's relay. There is no automatic provider fallback. Semantic cloud operations use the selected content-privacy mode, which defaults to asking before document text is sent. Local Qwen remains an explicit local provider choice.
- Patch accepts only supported text/code files, writes a separate proposal plus a reviewable diff, preserves the source, and never executes proposed code.
- Scout permits public HTTP(S) content only, blocks local/private destinations and unsafe schemes, and treats fetched page content as untrusted data rather than instructions.

## Pairing and relay

- The Mac starts a five-minute one-use pairing. The Worker hashes device bearer credentials and stores only public device keys.
- Phone and Mac derive AES-GCM keys from P-256 ECDH plus HKDF-SHA-256. Nonces are fresh per message/file; invalid ciphertext fails authenticated decryption.
- Request/reply envelopes and file contents are encrypted before upload. D1 stores encrypted file chunks with 24-hour expiry, acknowledgement deletion, and cleanup. File transfers are capped at 50 MiB each, 64 MiB active per workspace, and 384 MiB globally. Paired devices are limited to twelve uploads per hour.
- Anonymous workspace creation is limited to five per source IP per UTC day. The relay stores a SHA-256 hash for the limiter window instead of the raw IP. Revoked phone records and expired limiter rows are removed by cleanup.
- D1 stores device/message/file routing metadata needed to deliver and revoke. The Worker cannot read plaintext task messages or files and has no code execution or model capability.
- Revoking a phone disables its credential and removes queued envelopes and file transfers. Uncollected envelopes and files expire within 24 hours.
- Tokens/private keys remain in Keychain on Mac and browser IndexedDB on phone. The Worker stores only credential hashes.

## Reel downloads and Cue audio

- Reel downloads fixed helper versions only from pinned URLs after the explicit **Prepare Reel** action. SHA-256 is checked before install/version probes; helper state is stored in Kio's Application Support directory. The Streamlink Python runtime and every wheel are pinned and checksum-verified as well.
- Reel uses Foundation `Process` with a Kio-controlled executable and typed argument builders. It does not invoke a shell, read browser cookies, send login credentials, or bypass DRM. Public URL validation is performed before media work; incomplete task outputs are kept in temporary directories and removed on cancellation.
- Cue asks for microphone and Speech Recognition access only when a mode that needs them starts. Classic mode uses no microphone. Cue does not request Accessibility or Screen Recording access.

## Local app identity and user-controlled inputs

- Development builds use the existing stable local signing identity and keep bundle ID `app.kio.mac`. The selection scripts store only the public certificate fingerprint and do not generate or export a key. Public builds remain ad-hoc signed. macOS owns Keychain and privacy authorization decisions; stable signing reduces identity churn but is not a promise that all future prompts disappear.
- Clipboard data is read only when the user explicitly pastes it into Kio. Screenshot capture is an explicit action and may require macOS Screen Recording permission. Finder Services act only on the files the user selected.
- Browser notifications are opt-in. Closed-app Web Push is not configured.

## Limits

The relay uses Workers Free + D1 quotas; over-quota operations fail under that plan and known D1 capacity errors return specific messages. The local integration smoke test covers cryptographic interoperability, tamper rejection, multi-chunk transfers, per-workspace/global bounds, rate limits, acknowledgement, and revocation. The relay is not a substitute for protecting an unlocked Mac or phone, its local user account, the PWA origin, or the Cloudflare account. Keep the relay URL and phone browser under your control.
