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

Request/reply envelopes and file bytes are encrypted on the sending device. The relay queues envelopes for up to 24 hours and stores file bytes in 1,000,000-byte encrypted D1 chunks. Each file is limited to 50 MiB, each workspace to 64 MiB of active transfers, and the deployment to a 384 MiB emergency ceiling. Each paired device can upload 12 files per hour. The recipient's acknowledgement deletes a transfer; otherwise a 15-minute cleanup trigger removes it after 24 hours. New anonymous workspaces are limited to five per source IP per UTC day using a stored SHA-256 hash. Mac Settings lists paired phones and can revoke one. The phone's **···** action revokes its pairing and clears the saved phone session.

Encrypted progress payloads may include a speaker and one of Kio's registered agent IDs. Older payloads without these fields remain readable. The updated PWA renders Kio and specialist slime avatars from those events. Its service worker caches the app shell and uses versioned cache cleanup; the manifest includes PNG install icons and a separate Apple touch icon. A user can explicitly enable browser notifications for completion while the PWA is open or backgrounded. Closed-app Web Push is not configured; it requires additional push credentials and final platform-specific testing.

If the Mac is offline, the PWA states that the task will start when Kio reconnects. Messages remain encrypted in the relay queue for up to 24 hours. The PWA stores its own conversation history in that phone browser's IndexedDB. Add it to the iPhone Home Screen from Safari's Share menu to launch it as an app-like PWA.

## Current validation limits

`./scripts/check.sh` passes the local PWA typecheck/build and WebCrypto tests, plus relay authentication, encryption, multi-chunk transfer, queue acknowledgement, bounds, rate-limit, tamper, lifecycle, and revocation checks. Worker version `0382cb4c-37b5-4bce-84d6-aea27c8b70e1` was deployed on 2026-09-30.

The existing paired Chrome profile was live-checked after the Mac rebuild: Settings reported **Mac online · 1 paired phone**. The PWA accepted two CSV files in one request, ran “Merge these tables” on the Mac, and displayed the resulting downloadable CSV. Two receipt images also completed Lens OCR and a PDF round trip; the PDF download was confirmed. Offline queue/reconnect, URL fetch, saved-workflow listing and execution, and prior result-download/rename flows were live-checked. The Chrome notification control was exercised but did not reach an enabled state, and no notification was observed. A desktop browser cannot verify iPhone camera capture or the OS share-target handoff. Forced duplicate-delivery behavior remains unverified in Chrome.

The user previously confirmed that Add to Home Screen works. No physical iPhone file-task round trip was observed. Complete this manual checklist on iPhone:

1. Add Kio to the Home Screen from Safari.
2. Pair the PWA with the Mac using the QR code.
3. Send a text request.
4. Send multiple photos.
5. Use the camera flow for a receipt.
6. Confirm specialist progress appears.
7. Download a CSV and a PDF result.
8. Paste or share a URL into Kio.
9. Queue a task while the Mac is offline.
10. Reconnect the Mac and confirm one completion.
11. Check an opt-in completion notification.
12. Revoke the phone pairing.
