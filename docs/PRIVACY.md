# Privacy

## Intelligence providers

Deterministic / No AI, OpenAI, Anthropic, Gemini, OpenRouter, Groq, and Local Qwen are selectable in Settings → Intelligence. Opening Kio and deterministic fast paths do not load Qwen. BYOK credentials are stored only in the macOS Keychain; provider selection, model identifiers, and the content-privacy choice are saved in preferences. Cloud provider requests travel directly from the Mac to the selected provider over HTTPS. The phone relay never receives provider credentials or provider requests. Kio does not silently fall back to a different provider.

The default content mode is **Ask before sending contents**. Ordinary planning sends the request and bounded file metadata, not file bytes. A semantic operation that needs document contents asks before sending them. **Metadata only** blocks that cloud content operation; **Allow contents** removes the per-operation confirmation. Choosing Local Qwen keeps inference on the Mac. The provider receives any text Kio sends under its own service terms and privacy practices.

## Mac use without mobile relay

The app does not require an account or network service for local file workflows. File bytes stay on the Mac unless the user explicitly chooses a cloud provider/content mode or requests a network workflow. Local Qwen is downloaded from Hugging Face only after the user chooses **Download model**; once prepared and selected, inference runs on the Mac. Planning sends the request and file names, types, sizes, and indexes, not file contents or local paths. When Local Qwen is selected, Scribe reads bounded text from the selected source locally. Lens uses Apple Vision locally. Cloud-provider behavior is described above.

Conversation text and artifact metadata are stored in the user's local SwiftData store. Searchable history, the last verified workflow, and a bounded list of processed remote task IDs stay in local preferences/storage for references, follow-ups, and duplicate suppression. Clearing history removes conversation and last-workflow context; the small task-ID ledger remains to prevent a relayed request from being run again. The Mac's P-256 private key and relay bearer token are stored in Keychain.

Clipboard content is read only when the user explicitly pastes into Kio. Screenshot capture is user-initiated and can require Screen Recording permission. Finder Services receive only the files the user selected. Scout fetches public web pages only when requested; those requests go to the selected websites and expose the normal network metadata to them.

Reel contacts a public media URL only when the user requests inspection or download. Its pinned helper binaries, Python runtime, and Streamlink wheels ship inside `Kio.app/Contents/Resources/Reel`; Kio does not download or install helper software at runtime. Media downloads connect directly to their public source. Reel does not read browser cookies, accept login credentials, or bypass DRM. Use only media you are allowed to save. The optional gallery-dl GPL-2.0-only helper is not bundled because this repository does not declare compatible app redistribution terms.

Cue keeps its script on the Mac. Classic mode needs no microphone. Follow My Voice and Word Tracking ask for microphone and Speech Recognition permission only when started. Kio does not request either permission at launch. Cue uses SpeechAnalyzer/SpeechTranscriber on supported macOS versions and falls back to SFSpeechRecognizer where required; audio and recognition processing follow Apple's Speech framework behavior for the selected OS and locale.

## Optional phone relay

Pairing is opt-in and uses the URL supplied in Settings. Before data reaches the relay, Mac and phone encrypt request/reply messages and file bytes using ECDH-derived AES-GCM keys. The relay stores public keys, opaque device IDs, hashed credentials, routing/timing metadata, file byte sizes, and ciphertext. The relay cannot decrypt message or file contents. Cloudflare receives the connecting IP as part of serving the Worker. Kio hashes that address for its workspace-creation limiter and stores only the hash in D1; Cloudflare's own infrastructure handling remains subject to its privacy policy.

Envelopes expire after 24 hours or earlier when acknowledged. File chunks are removed on acknowledgement or by the 24-hour expiry cleanup. Revoking a phone removes its pending envelopes, file transfers, and transfer-rate records. The Worker does not run the model or any file-processing tool.

The phone keeps its private key and conversation history in browser IndexedDB. Multiple attachments are encrypted before relay upload; the phone can also send from its camera or share target. Clearing site data or unpairing removes that phone's local copy. Completion notifications are opt-in, and closed-app Web Push is not configured. Mac history is stored in the local macOS user account and is not encrypted by Kio beyond the platform's normal file protections. Do not pair on a device or relay URL you do not control.
