# Security

## Execution boundary

- No arbitrary shell, AppleScript, generic GUI automation, or model-generated code execution is registered.
- The model proposes a plan through a synthetic `submit_plan` tool schema; Kio never dispatches it. The decoder validates operation names, actual artifact indexes, argument types/ranges, and input kinds before execution. A single repair attempt is allowed; invalid plans are rejected.
- Deterministic Mac tools create conflict-safe outputs and check the result before returning it. Originals are preserved.
- File processing is local. The model receives request text and file metadata only.

## Pairing and relay

- The Mac starts a five-minute one-use pairing. The Worker hashes device bearer credentials and stores only public device keys.
- Phone and Mac derive AES-GCM keys from P-256 ECDH plus HKDF-SHA-256. Nonces are fresh per message/file; invalid ciphertext fails authenticated decryption.
- Request/reply envelopes and file contents are encrypted before upload. D1 stores encrypted file chunks with 24-hour expiry, acknowledgement deletion, and cleanup. File transfers are capped at 50 MiB each, 64 MiB active per workspace, and 384 MiB globally. Paired devices are limited to twelve uploads per hour.
- Anonymous workspace creation is limited to five per source IP per UTC day. The relay stores a SHA-256 hash for the limiter window instead of the raw IP. Revoked phone records and expired limiter rows are removed by cleanup.
- D1 stores device/message/file routing metadata needed to deliver and revoke. The Worker cannot read plaintext task messages or files and has no code execution or model capability.
- Revoking a phone disables its credential and removes queued envelopes and file transfers. Uncollected envelopes and files expire within 24 hours.
- Tokens/private keys remain in Keychain on Mac and browser IndexedDB on phone. The Worker stores only credential hashes.

## Limits

The relay uses Workers Free + D1 quotas; over-quota operations fail under that plan and known D1 capacity errors return specific messages. The local integration smoke test covers cryptographic interoperability, tamper rejection, multi-chunk transfers, per-workspace/global bounds, rate limits, acknowledgement, and revocation. The relay is not a substitute for protecting an unlocked Mac or phone, its local user account, the PWA origin, or the Cloudflare account. Keep the relay URL and phone browser under your control.
