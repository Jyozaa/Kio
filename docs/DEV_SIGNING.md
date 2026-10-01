# Local development signing

Run the development app with:

```sh
bash scripts/dev-run.sh
```

The helper uses the already-existing self-signed **Kio Local Development** identity configured in `~/.config/kio/dev-signing.env`. It keeps the app identifier `app.kio.mac` and installs to `~/Applications/Kio.app`, then verifies the signature and opens that installed bundle. It does not require an Apple account or an Apple Development certificate.

The private signing key stays in the local Keychain. `scripts/setup-dev-signing.sh` selects an identity that already exists; it never creates, imports, exports, or rotates a certificate or private key. If no local Kio identity is available, the script reports that and `scripts/build-mac.sh` remains available for an ad-hoc build. No private key, exported certificate bundle, or credential belongs in the repository. The saved configuration contains a public certificate fingerprint only.

Inspect the installed identity with:

```sh
codesign -dv --verbose=4 "$HOME/Applications/Kio.app"
codesign -dr - "$HOME/Applications/Kio.app"
```

`scripts/build-mac.sh` and `scripts/package-dmg.sh` use the public ad-hoc signing path and do not silently use the local identity. Release signing and notarization are separate; see [Release](RELEASE.md). A stable identity helps macOS recognize successive local builds as the same app. Repeated local installs retained the same designated requirement, and the installer completed without Apple Events. Keychain access and other privacy prompts are controlled by macOS; this test does not establish that every such prompt is permanently suppressed. Record the actual result in [Build status](BUILD_STATUS.md).
