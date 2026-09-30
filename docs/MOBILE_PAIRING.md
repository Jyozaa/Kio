# Phone PWA and relay

The phone experience is a local-first PWA. The Mac remains the only computer that plans and runs file tasks. The relay is optional; without a deployed relay, the Mac app continues to work locally.

## Live PWA

The deployed PWA and relay origin is <https://kio-relay.kio-relay.workers.dev>. It is served through Cloudflare Workers Free and uses the account's `workers.dev` subdomain; there is no custom domain.

## Build and local development

```sh
npm ci --prefix apps/mobile
npm --prefix apps/mobile run build
npm ci --prefix apps/relay
npm --prefix apps/relay run typecheck
bash apps/relay/scripts/check-local.sh
```

The Worker serves the production PWA from `apps/mobile/dist`. Its local `/api` routes use Wrangler's local D1 database. `scripts/check-local.sh` runs migrations and an integration smoke test with real WebCrypto keys and D1 storage.

## Deploy

1. Sign in to Cloudflare with `npx wrangler login`.
2. From the repo root run `bash scripts/deploy-relay.sh`. It creates or reuses the free D1 database in western Europe, updates the D1 binding, applies migrations, builds the PWA, and deploys the Worker.
3. Copy Wrangler's resulting `https://<worker>.<subdomain>.workers.dev` URL into Kio Settings → Mobile → PWA and relay URL.
4. Select **Connect**, then **Pair phone**.
5. Scan the one-time QR code with the phone camera and select **Pair with my Mac**.

Deployment is complete. The configured Workers Free/D1 path uses no R2 bucket, paid Worker plan, model API, or custom domain. See [Free tier](FREE_TIER.md) for current quotas and their limits.

## Pairing and security

The Mac creates a five-minute one-time invitation. The phone creates a P-256 ECDH keypair and a random bearer credential. Only the phone's public key and a hash of its token are sent to the relay. The Mac's private key and bearer token are stored in Keychain; the phone's private key is stored as a non-extractable WebCrypto key in IndexedDB. Both endpoints derive a per-workspace AES-GCM key through HKDF-SHA-256.

Request/reply envelopes and file bytes are encrypted on the sending device. The relay queues envelopes for up to 24 hours and stores file bytes in 1,000,000-byte encrypted D1 chunks. Each file is limited to 50 MiB; the relay allows 128 MiB active in total. The recipient's acknowledgement deletes the transfer; otherwise a 15-minute cleanup trigger removes it after 24 hours. Mac Settings lists paired phones and can revoke one. The phone's **···** action revokes its pairing and clears the saved phone session.

If the Mac is offline, the PWA states that the task will start when Kio reconnects. Messages remain encrypted in the relay queue for up to 24 hours. The PWA stores its own conversation history in that phone browser's IndexedDB. Add it to the iPhone Home Screen from Safari's Share menu to launch it as an app-like PWA.

## Current validation limits

The local smoke test exercises one-time pairing, device authentication, actual encryption/decryption, multi-chunk file transfer in both directions, queue acknowledgement, size bounds, tamper rejection, and revocation. The public PWA and Worker health endpoint have been checked. The paired Chrome PWA completed a live “Is my Mac online?” request/reply round trip; Kio confirmed receipt on the Mac. It also completed a remote image-to-PDF task and a follow-up rename of the latest result. A generated 96×64 PNG produced a valid one-page 96×64 PDF; the returned and renamed PDF files were downloaded to `~/Downloads/Kio` and validated. Offline queueing was verified by stopping the Release app, confirming the PWA queued a status question, then relaunching Kio and observing the reply in both the phone conversation and Mac history. The user confirmed that Add to Home Screen works on iOS, though a physical iPhone file-task round trip was not independently observed.

The Mac handles “Is my Mac online?” with a deterministic read-only response that confirms receipt of the phone request without invoking model planning. The path is unit-tested and verified live through the paired Chrome PWA.
