# Security

## Execution boundary

- No arbitrary shell, AppleScript, generic GUI automation, or model-generated code execution is registered.
- The model proposes only typed plans for known operations. The decoder validates operation names, actual artifact indexes, argument types/ranges, and input kinds before execution.
- Deterministic Mac tools create conflict-safe outputs and check the result before returning it. Originals are preserved.
- File processing is local. The model receives request text and file metadata only.

## Pairing and relay

- The Mac starts a five-minute one-use pairing. The Worker hashes device bearer credentials and stores only public device keys.
- Phone and Mac derive AES-GCM keys from P-256 ECDH plus HKDF-SHA-256. Nonces are fresh per message/file; invalid ciphertext fails authenticated decryption.
- Request/reply envelopes and file contents are encrypted before upload. D1 stores encrypted file chunks with 24-hour expiry, acknowledgement deletion, and cleanup. File transfers are capped at 50 MiB each and 128 MiB active total.
- D1 stores device/message/file routing metadata needed to deliver and revoke. The Worker cannot read plaintext task messages or files and has no code execution or model capability.
- Revoking a phone disables its credential and removes queued envelopes and file transfers. Uncollected envelopes and files expire within 24 hours.
- Tokens/private keys remain in Keychain on Mac and browser IndexedDB on phone. The Worker stores only credential hashes.

## Limits

The relay uses Workers Free + D1 quotas; over-quota operations fail under that plan. A public deployment has not been exercised yet. The local integration smoke test covers cryptographic interoperability, tamper rejection, multi-chunk transfers, bounds, acknowledgement, and revocation. The relay is not a substitute for protecting an unlocked Mac or phone, its local user account, the PWA origin, or the Cloudflare account. Keep the relay URL and phone browser under your control.
