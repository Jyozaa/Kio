# Kio build and verification status

Last updated: 2026-09-30

## Current source and app identity

- Checkout: `/Users/joe/Desktop/Kio`, branch `main`.
- At the time of this update, `022e64f` is the cleanup checkpoint; the product changes described below are committed locally in follow-up commits.
- The app used for live Mac checks is built from this checkout at `/var/folders/_5/xssw295j0g3_vhrcrkrm51mw0000gn/0/KioDerivedData/Build/Products/Debug/Kio.app`, bundle ID `app.kio.mac`.
- The older installed app at `/Users/joe/Applications/Kio.app` has bundle ID `local.companion.dev`; it is not the app used for these checks.
- Local changes are not pushed to GitHub. GitHub Actions therefore has no run for this source state.

## Product scope implemented

- Mac notch composer, compact result view, history access, file drops, hover retention, output-folder selection, and character handoff/animation behavior.
- Local fast answers and stricter tool-plan decoding, plus reusable one- and two-step follow-up pipelines.
- Native PDF, image, archive, media, and file-management workflows. ZIP extraction validates paths and checksums, bounds decompression, and rejects unsafe entry types and unsupported encryption.
- Encrypted optional phone relay, PWA notifications, relay workspace lifecycle cleanup, and browser downloads.

## Automated checks

**AUTOMATED TESTED**

- `bash scripts/check.sh` passed after the current product changes: 57 Swift tests, the Xcode Debug build, mobile install/build, relay typecheck, relay smoke and lifecycle checks, and WebCrypto interoperability.
- `./scripts/package-dmg.sh` produced `build/release/Kio-0.1.0.dmg` and its `.sha256` file. The DMG mounted; its app bundle identity/version, code signature integrity, and checksum were verified.
- `git diff --check` passed.
- Remote relay health returned `{"ok":true,"version":1}` and no remote database migrations were pending after deployment.

## Live checks

**LIVE TESTED ON MAC**

- The running process path was verified as the Debug app built from this checkout (`app.kio.mac`), not the older installed app.
- The Mac answered “Is my Mac online?” with “Your Mac is online—it received this request just now.”

**LIVE TESTED ON LAPTOP BROWSER**

- The current-source PWA and local relay were paired in Chrome. The Mac answered the online question, converted a PNG to a PDF, and Chrome downloaded a valid one-page PDF. A follow-up rename created and downloaded `Browser-Followup-2.pdf`, confirming conflict-safe output naming. Both PDFs were checked with `pdfinfo`.
- The same Chrome profile’s deployed PWA was also exercised against the Mac. It converted and downloaded a valid PDF and completed a follow-up rename before the current deployment. After deployment, the paired PWA showed the online Mac response and retained its prior conversation.
- The local relay used for the source-to-source browser round-trip has been stopped. The Mac was returned to the deployed relay URL.

**DEPLOYED**

- Current mobile assets and relay code were deployed to `https://kio-relay.kio-relay.workers.dev` on 2026-09-30 (Worker version `c08c188a-d1e5-462e-8d34-ff9ec017bfbf`). Remote migrations through `0005_workspace_lifecycle.sql` were applied.

## Not verified yet

- **PHYSICAL IPHONE:** not tested; no physical iPhone was available. Manual acceptance: pair from Settings, send a text request, upload a PNG and download the resulting PDF, then run a follow-up rename.
- The notch’s full hover timing, drag-and-drop, agent animation sequence, result actions, reduced-motion behavior, and multi-display targeting still need a focused visual acceptance pass.
- GitHub Actions has not run against the unpushed local commits.
