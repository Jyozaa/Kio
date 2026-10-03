# Security

## File-operation boundary

- Convert and Reel dispatch only typed native operations through `ToolExecutor`; there is no arbitrary shell, AppleScript, GUI automation, or generated-code execution.
- Inputs are inspected as artifacts. Outputs use conflict-safe destinations, transformations preserve originals, and temporary media results are verified before publication.
- Reel uses a pinned bundled runtime, safe URL handling, explicit argument arrays, and output format verification. It does not read browser cookies, accept account credentials, or bypass DRM.
- Public HTTP(S) URL validation rejects local/private hosts and unsafe schemes. News requires HTTPS feeds, validates the initial and redirected host, caps each response at 2 MB, and parses feed XML without loading arbitrary pages.

## Local data

- Session integrations are opt-in; hook files contain bounded lifecycle metadata only and are written atomically with restrictive permissions.
- Clipboard history is opt-in and bounded by entries, retention, and image storage. Concealed/transient types are skipped where the pasteboard exposes them.
- News metadata and configuration are local and bounded. Kio performs no background feed requests.
- Cue's microphone and Speech Recognition permissions are requested only after the user starts Follow My Voice.

See [Privacy](PRIVACY.md) for details and limitations of the local stores.

## Build and distribution

The pinned Reel runtime manifest records versions and SHA-256 hashes. Runtime artifacts and wheels are rejected if hashes do not match. Public local builds are ad-hoc signed; development signing is optional and described in [Development signing](DEVELOPMENT_SIGNING.md). macOS controls code-signing, Keychain, and privacy prompts.

## Reporting

Do not include private media URLs, project paths, clipboard data, or session identifiers in public bug reports. Share a minimal reproduction and the exact Kio build. For a security issue, use GitHub's private vulnerability reporting for this repository.
