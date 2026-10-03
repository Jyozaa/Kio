# Release

The app version is maintained in `apps/mac/KioMac.xcodeproj/KioVersion.xcconfig` (currently `0.1.0`). `scripts/package-dmg.sh` prepares the pinned Reel runtime, builds and verifies a Release app bundle, creates `build/release/Kio-<version>.dmg`, verifies the disk image, and writes a SHA-256 checksum beside it. This packaging path does not open Kio.

Run `scripts/check.sh` before packaging. It runs package tests, helper checks, runtime verification, and noninteractive Debug and Release builds; it does not launch the app. A local DMG uses ad-hoc signing and is not notarized. Public distribution requires the appropriate Developer ID signing and notarization process.

`scripts/dev-run.sh` is an explicit local developer workflow that installs and opens the app with an already-existing stable local signing identity. Do not use it for build-only verification. `scripts/build-mac.sh` builds and verifies the app bundle and prints its location without opening it.

GitHub Actions runs macOS build and test checks for pushes to `main` and pull requests. A push of a `v*` tag runs those checks, packages the DMG and checksum, then creates a GitHub release with generated notes.
