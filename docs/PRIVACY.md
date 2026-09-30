# Privacy

## Mac use without mobile relay

The app does not require an account or network service for local file workflows. File bytes stay on the Mac. The optional model is downloaded from Hugging Face after the user chooses **Download model**; once prepared, inference runs on the Mac. Planning receives the request and file names, types, sizes, and indexes, not file contents or local paths. Conversation text, task context, and artifact metadata are stored in the user's local SwiftData store; clearing history removes those records. The Mac's P-256 private key and relay bearer token are stored in Keychain.

## Optional phone relay

Pairing is opt-in and uses the URL supplied in Settings. Before data reaches the relay, Mac and phone encrypt request/reply messages and file bytes using ECDH-derived AES-GCM keys. The relay stores public keys, opaque device IDs, hashed credentials, routing/timing metadata, file byte sizes, and ciphertext. The relay cannot decrypt message or file contents. A relay-hosted PWA can observe the connected phone's IP address as a normal web service; Cloudflare operates the configured Worker and its underlying infrastructure.

Envelopes expire after 24 hours or earlier when acknowledged. File chunks are removed on acknowledgement or by the 24-hour expiry cleanup. Revoking a phone removes its pending envelopes and file transfers. The Worker does not run the model or any file-processing tool.

The phone keeps its private key and conversation history in browser IndexedDB. Clearing site data or unpairing removes that phone's local copy. Mac history is stored in the local macOS user account and is not encrypted by Kio beyond the platform's normal file protections. Do not pair on a device or relay URL you do not control.
