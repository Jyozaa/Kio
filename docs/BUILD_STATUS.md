# Kio build status

## Current milestone

The local checkout contains the hardening and completion work described below. The Cloudflare relay and PWA currently deployed at <https://kio-relay.kio-relay.workers.dev> are still the earlier deployed build; this checkout has not been deployed or released.

## Implemented in this checkout

- Reproducible CI/bootstrap checks and tag-aware Mac app, DMG, checksum, and release versioning.
- Typed planner/executor fixes for exact conflict-safe rename, stable multi-step artifact inputs, stale output recovery, image format/extension correctness, duplicate relay task handling, and one bounded model-plan repair.
- Structured local-model planning with a pinned Qwen tool-call format, while keeping deterministic status/file paths independent of model inference.
- Expanded-notch interaction state, stable host-panel rendering, specialist character motion and pointer tracking, reduced-motion support, onboarding, settings, and hotkey/login options.
- Relay quota and cleanup protections, including per-workspace and per-device transfer bounds, global active-transfer limits, and hashed-IP workspace creation limits.
- PWA install assets/service-worker updates, notification preference handling, and richer agent/avatar message support with backward-compatible relay payloads.
- Architecture, privacy, security, free-tier, local-model, mobile-pairing, release, and user documentation updates.

## Automated verification in this checkout

- `bash scripts/check.sh` — passed after the latest code change: 35 Swift tests, Debug macOS build, clean `npm ci` installs, PWA typecheck and production build, relay typecheck, local Wrangler/D1 integration smoke checks, and CryptoKit/WebCrypto interoperability.
- `KIO_VERSION_OVERRIDE=0.2.0 scripts/package-dmg.sh` — passed after the final UI appearance fix. The `Kio-0.2.0.dmg` image verified, its SHA-256 checksum matched, and the Release app reports `CFBundleShortVersionString=0.2.0`.

## Live checks

- **Mac to paired laptop browser:** the paired Chrome PWA displayed `Mac online`; asking “Is my Mac online?” returned “Your Mac is online—it received this request just now.”
- **Offline queue and reconnect:** after terminating Kio, Chrome showed the status request queued while Mac was offline. Relaunching the Debug app delivered the reply, and the PWA presence changed back to online.
- **Earlier browser file workflow:** the paired Chrome session contains a successful image-to-PDF request and a follow-up rename from the earlier deployed build. In the current run, the native macOS chooser showed the generated PNG selected and previewed it as a PNG, but its Open button stayed disabled. No upload occurred, so a fresh browser file round trip was not verified.
- **Deployed service:** the relay health endpoint returned `{"ok":true,"version":1}`. The live PWA is the earlier deployment, so local PWA visuals and the new agent/avatar payloads have not been confirmed in production.
- **Mac UI:** inspected the running app's restored conversation window. The warm off-white surface, readable dark text, Pip's progress entry, PDF result card, and Open/Reveal controls were visible. A text-contrast issue found during inspection was fixed and the Debug app rebuilt. The expanded-notch hover/animation, drag/drop, and processing/result sequence were not fully re-inspected through the native UI in this pass.

## Requires final device validation

- Physical iPhone pairing, upload/download, notifications, and offline/reconnect behavior remain unverified on an iPhone. The user previously confirmed Add to Home Screen works.
- The current source changes have not been deployed. Do not use this document as evidence that the live PWA has the new UI or relay behavior.
- Public Mac distribution remains ad-hoc signed and is not notarized for Gatekeeper distribution.

## Outputs

`KIO_VERSION_OVERRIDE=0.2.0 scripts/package-dmg.sh` creates `build/release/Kio-0.2.0.dmg` and its `.sha256` file. The `.app` is under `Build/Products/Release` in the DerivedData path printed by `scripts/build-mac.sh` (set `KIO_DERIVED_DATA_PATH` to choose a stable path).
