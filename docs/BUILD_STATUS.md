# Kio build and verification status

Last updated: 2026-09-30

## Current source and app identity

- Checkout: `/Users/joe/Desktop/Kio`, branch `main`.
- Acceptance follow-up fix: `ead83de` keeps the notch feed at the latest message and persists active-result clearing across launches.
- The app used for live Mac checks is built from this checkout at `/var/folders/_5/xssw295j0g3_vhrcrkrm51mw0000gn/0/KioDerivedData/Build/Products/Debug/Kio.app`, bundle ID `app.kio.mac`.
- The older installed app at `/Users/joe/Applications/Kio.app` has bundle ID `local.companion.dev`; it is not the app used for these checks.
- Local changes are not pushed to GitHub. GitHub Actions therefore has no run for this source state.

## IMPLEMENTED

- Mac notch composer, compact result view, history access, file drops, hover retention, output-folder selection, and character handoff/animation behavior.
- Local fast answers and stricter tool-plan decoding, plus reusable one- and two-step follow-up pipelines.
- Native PDF, image, archive, media, and file-management workflows. ZIP extraction validates paths and checksums, bounds decompression, and rejects unsafe entry types and unsupported encryption.
- Encrypted optional phone relay, PWA notifications, relay workspace lifecycle cleanup, and browser downloads.

## AUTOMATED TESTED

- `bash scripts/check.sh` passed after the acceptance fixes: 57 Swift tests, the Xcode Debug build, mobile install/build, relay typecheck, relay smoke and lifecycle checks, and WebCrypto interoperability.
- `./scripts/package-dmg.sh` produced `build/release/Kio-0.1.0.dmg` and its `.sha256` file. The DMG mounted; its app bundle identity/version, code signature integrity, and checksum were verified.
- `git diff --check` passed.
- Remote relay health returned `{"ok":true,"version":1}` and no remote database migrations were pending after deployment.

## Live checks

**LIVE TESTED ON MAC**

- The running process path was verified as the Debug app built from this checkout (`app.kio.mac`), not the older installed app.
- The Mac answered “Is my Mac online?” with “Your Mac is online—it received this request just now.”
- In the notch, the composer retained text and stayed expanded for over five seconds while focused; both Return and the send arrow submitted the online-status question. Reopening after a reply showed the latest message fully, and the result was no longer restored as the active output after an unrelated request and app restart.
- The History button opened the full conversation using the same persisted messages. The notch’s complete hover, drag/drop, handoff animation, cancellation, result-action, Reduce Motion, shortcut, and multi-display checklist has not been completed.
- A final offline/reconnect check stopped the Debug app, sent a harmless request from the deployed PWA, and confirmed that the PWA queued it while Kio was offline. Relaunching the ad-hoc-signed Debug build then blocked on the main thread in `SecItemCopyMatching` while loading the paired Keychain identity; no reconnect or reply was observed. I stopped this stalled process. macOS keychain access needs to be resolved before repeating this check. The queued request remains pending in the paired PWA.

**LIVE TESTED IN LAPTOP BROWSER**

- The current-source PWA and local relay were paired in Chrome. The Mac answered the online question, converted a PNG to a PDF, and Chrome downloaded a valid one-page PDF. A follow-up rename created and downloaded `Browser-Followup-2.pdf`, confirming conflict-safe output naming. Both PDFs were checked with `pdfinfo`.
- Before the current deployment, the same Chrome profile’s PWA also completed a PNG-to-PDF download and follow-up rename. After deployment, a fresh online-status question received the Mac’s reply.
- A post-deployment file upload is still unverified: Chrome’s file chooser did not open through the automation connection. Chrome’s upload guidance says to enable “Allow access to file URLs” for the ChatGPT extension before retrying.
- The local relay used for the source-to-source browser round-trip has been stopped. The Mac was returned to the deployed relay URL.

**DEPLOYED**

- Current mobile assets and relay code were deployed to `https://kio-relay.kio-relay.workers.dev` on 2026-09-30 (Worker version `c08c188a-d1e5-462e-8d34-ff9ec017bfbf`). Remote migrations through `0005_workspace_lifecycle.sql` were applied.

## Not verified yet

- **PHYSICAL IPHONE:** not tested; no physical iPhone was available. Manual acceptance: pair from Settings, send a text request, upload a PNG and download the resulting PDF, then run a follow-up rename.
- Post-deployment file round-trip, offline/reconnect, no-duplicate execution, live local-model planning/repair, and notification behavior remain unverified. The current reconnect attempt exposed a Keychain access stall as described above.
- Notch visual checks remain for actual hover expansion, drag/drop chips, task handoff/character animation, stop, Open/Reveal/Copy/drag-out, follow-up pipelines, Reduce Motion, global shortcut, output-folder/onboarding behavior, and display changes.
- GitHub Actions has not run against the unpushed local commits.
- Repository hygiene found no remaining paths matching `* 2*`; the 179 tracked duplicate paths were removed in `022e64f`, and one stale untracked `docs/BUILD_STATUS 2.md` copy was removed during final review.
