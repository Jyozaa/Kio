# Kio build and verification status

Last updated: 2026-09-30

## Current source and app identity

- Checkout: `/Users/joe/Desktop/Kio`, branch `main`. The acceptance code is committed locally; `origin/main` is still at `9744e51` and the local branch has not been pushed.
- Implementation commit: `9020024`; this final acceptance update changes documentation only.
- Acceptance follow-up fix: `ead83de` keeps the notch feed at the latest message and persists active-result clearing across launches.
- The app used for live Mac checks is built from this checkout at `/var/folders/_5/xssw295j0g3_vhrcrkrm51mw0000gn/0/KioDerivedData/Build/Products/Debug/Kio.app`, bundle ID `app.kio.mac`.
- The older installed app at `/Users/joe/Applications/Kio.app` has bundle ID `local.companion.dev`; it is not the app used for these checks.
- Local changes are not pushed to GitHub. GitHub Actions therefore has no run for this source state.

## Current milestone and next action

- Milestone: hardening, release packaging, relay deployment, offline reconnect, and the deployed laptop-browser file round trip are complete and recorded below.
- Next: finish the remaining notch-specific visual checks, then do physical iPhone acceptance last. No physical iPhone is connected in this environment.

## IMPLEMENTED

- Mac notch composer, compact result view, history access, file drops, hover retention, output-folder selection, and character handoff/animation behavior.
- Local fast answers and stricter tool-plan decoding, plus reusable one- and two-step follow-up pipelines.
- Native PDF, image, archive, media, and file-management workflows. ZIP extraction validates paths and checksums, bounds decompression, and rejects unsafe entry types and unsupported encryption.
- Encrypted optional phone relay, PWA notifications, relay workspace lifecycle cleanup, and browser downloads.

## AUTOMATED TESTED

- `bash scripts/check.sh` passed after the acceptance fixes: 57 Swift tests, the Xcode Debug build, mobile install/build, relay typecheck, relay smoke and lifecycle checks, and WebCrypto interoperability.
- `./scripts/package-dmg.sh` produced `build/release/Kio-0.1.0.dmg` and its `.sha256` file. The DMG mounted; its app bundle identity/version, code signature integrity, and checksum were verified.
- The native registry contains 38 typed tool operations across PDF, image, archive, media, and file workflows. No arbitrary shell or generic GUI-control operation is registered.
- `git diff --check` passed.
- Remote relay health returned `{"ok":true,"version":1}` and no remote database migrations were pending after deployment.
- The latest GitHub Actions run is success for remote commit `9744e51` (run [36727753916](https://github.com/Jyozaa/Kio/actions/runs/36727753916)); there is no CI result for local commits because they are unpushed.

## Live checks

**LIVE TESTED ON MAC**

- The running process path was verified as the Debug app built from this checkout (`app.kio.mac`), not the older installed app.
- The Mac answered “Is my Mac online?” with “Your Mac is online—it received this request just now.”
- In the notch, the composer retained text and stayed expanded for over five seconds while focused; both Return and the send arrow submitted the online-status question. Reopening after a reply showed the latest message fully, and the result was no longer restored as the active output after an unrelated request and app restart.
- The History button opened the full conversation using the same persisted messages. On a generated PDF, Open loaded the file in Preview, Reveal selected it in Finder, and Copy pasted its file path into the unsent Kio composer; that text was cleared. Drag-out remains unverified. The notch’s complete hover, drag/drop, handoff animation, cancellation, Reduce Motion, shortcut, and multi-display checklist has not been completed.
- Offline/reconnect passed on the deployed PWA: I stopped the Mac app, waited for the PWA to report offline, queued “Is my Mac online?”, restarted the current Debug app after the user approved its Keychain access, and observed exactly one expected reply after it came back online.
- A live local-model image-to-PDF task completed using Pip. The single-repair fallback has only automated test coverage so far.

**LIVE TESTED IN LAPTOP BROWSER**

- The current-source PWA and local relay were paired in Chrome. The Mac answered the online question, converted a PNG to a PDF, and Chrome downloaded a valid one-page PDF. A follow-up rename created and downloaded `Browser-Followup-2.pdf`, confirming conflict-safe output naming. Both PDFs were checked with `pdfinfo`.
- After the current deployment, Chrome uploaded `apps/mobile/public/kio-192.png` through the native file chooser; the selected-file chip appeared before sending. The paired Mac received it, Pip reported PDF progress, and the result returned to the PWA. Chrome downloaded and opened the result as a one-page PDF (PDF 1.3, 192 × 192 pt, 9,005 bytes).
- A follow-up rename on that fresh result returned `Browser-Followup-3.pdf`. The suffix was expected because earlier tests had already created `Browser-Followup.pdf` and `Browser-Followup-2.pdf`; the new file downloaded and validated as a one-page PDF too.
- The deployed PWA displayed the Mac-online state and live Pip progress. The prior offline/reconnect test also returned exactly one expected reply. Duplicate suppression under forced relay redelivery remains unverified.
- The local relay used for the source-to-source browser round-trip has been stopped. The Mac was returned to the deployed relay URL.

**DEPLOYED**

- Current mobile assets and relay code were deployed to `https://kio-relay.kio-relay.workers.dev` on 2026-09-30 (Worker version `c08c188a-d1e5-462e-8d34-ff9ec017bfbf`). Remote migrations through `0005_workspace_lifecycle.sql` were applied.

## Not verified yet

- **PHYSICAL IPHONE:** not tested; no physical iPhone was available. Manual acceptance: pair from Settings, send a text request, upload a PNG and download the resulting PDF, then run a follow-up rename.
- Duplicate suppression under forced relay redelivery, live local-model repair, and notification display remain unverified. Chrome's native chooser required keyboard focus/navigation to select the PNG, after which normal attachment, encrypted transfer, conversion, and download all worked; no extension file-URL permission change was needed.
- Notification display has not been observed with browser permission enabled.
- One deliberately vague queued test request returned `None`; the known-good offline “Is my Mac online?” request returned exactly one correct response. Vague requests that do not map to a safe registered tool plan still need clearer wording.
- Notch visual checks remain for actual hover expansion, drag/drop chips, task handoff/character animation, stop, notch-specific result actions and drag-out, follow-up pipelines, Reduce Motion, global shortcut, output-folder/onboarding behavior, and display changes. Full-chat Open, Reveal, and Copy passed.
- Repository hygiene found no remaining paths matching `* 2*`; the 179 tracked duplicate paths were removed in `022e64f`, and one stale untracked `docs/BUILD_STATUS 2.md` copy was removed during final review.
