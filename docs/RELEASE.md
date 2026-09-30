# Release

Kio's project version has one source in `apps/mac/KioMac.xcodeproj/KioVersion.xcconfig`. Local packages use that version (currently `0.1.0`). A release tag such as `v0.2.0` automatically sets the app marketing version and produces `Kio-0.2.0.dmg` plus `Kio-0.2.0.dmg.sha256`. `KIO_VERSION_OVERRIDE=0.2.0` can be used to build a local versioned artifact without a Git tag; otherwise packaging falls back to the project version.

Run `scripts/package-dmg.sh` to build a Release `.app`, verify its signature, create a compressed DMG, and write a SHA-256 checksum. `scripts/check.sh` is the canonical local/CI verification command and installs the locked npm dependencies before building the PWA and relay.

GitHub Actions publishes a tagged release only after the full check and packaging steps succeed. No release is created by local packaging. Builds use ad-hoc signing when no Apple Developer identity is configured, which is suitable for local testing but does not satisfy Gatekeeper notarization for public distribution.
