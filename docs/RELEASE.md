# Release

Kio's project version has one source in `apps/mac/KioMac.xcodeproj/KioVersion.xcconfig`. Local packages use that version (currently `0.1.0`). A release tag such as `v0.2.0` automatically sets the app marketing version and produces `Kio-0.2.0.dmg` plus `Kio-0.2.0.dmg.sha256`. `KIO_VERSION_OVERRIDE=0.2.0` can be used to build a local versioned artifact without a Git tag; otherwise packaging falls back to the project version.

Run `scripts/package-dmg.sh` to build a Release `.app`, verify its signature, create a compressed DMG, and write a SHA-256 checksum. On 2026-09-30 this produced `build/release/Kio-0.1.0.dmg`; `hdiutil verify` and `shasum -a 256 -c` both passed. `scripts/check.sh` is the canonical local/CI verification command and installs the locked npm dependencies before building the PWA and relay.

Local development and public packaging use separate identities. `scripts/dev-run.sh` selects the already-existing stable local **Kio Local Development** identity and installs `~/Applications/Kio.app`; it does not generate or import signing keys. `scripts/package-dmg.sh` builds ad-hoc and does not require an Apple Development certificate. That DMG is not notarized and may require a local Gatekeeper override to run; public distribution requires the appropriate Developer ID signing and notarization workflow.

GitHub Actions publishes a tagged release only after the full check and packaging steps succeed. No release is created by local packaging. The latest DMG is a local build artifact, not a published release.
