# Release

Kio does not have a published release yet. `scripts/build-mac.sh` creates an ad-hoc signed local `.app` without an Apple Developer identity. `scripts/package-dmg.sh` packages it as a compressed DMG and writes a SHA-256 checksum. GitHub distribution becomes available when a remote is configured and a version tag is pushed.
