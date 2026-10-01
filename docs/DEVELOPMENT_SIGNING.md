# Development signing note

The current signing workflow is documented in [DEV_SIGNING.md](DEV_SIGNING.md). `scripts/dev-run.sh` uses the already-existing **Kio Local Development** identity and keeps the bundle ID `app.kio.mac`; it does not create a private key or certificate. `scripts/build-mac.sh` and `scripts/package-dmg.sh` continue to use ad-hoc signing.

The installer stops only the process launched from the canonical app or the exact Debug build it is installing. Other Kio-branded app copies are left alone even if they share the executable name or bundle ID. It verifies the bundle and replaces `~/Applications/Kio.app`. It avoids Apple Events, which can show a separate Automation prompt. Stable code signing was verified across repeated installs, but macOS Keychain and privacy decisions still depend on the saved user choice. See [current build status](BUILD_STATUS.md) for what was observed and what remains unverified.
