# CUA Driver capability audit

Kio pins CUA Driver **0.30.4** from the official release tag
[`cua-driver-rs-v0.30.4`](https://github.com/trycua/cua/releases/tag/cua-driver-rs-v0.30.4).
GitHub labels the component release as a pre-release because the monorepo has
independent product channels; the release notes state that plain CUA Driver
SemVer releases are stable. This is the newest compatible release reviewed for
this build. Kio does not track `main` or nightly builds.

Pinned universal archive:

- URL: `https://github.com/trycua/cua/releases/download/cua-driver-rs-v0.30.4/cua-driver-rs-0.30.4-darwin-universal.tar.gz`
- SHA-256: `9c75a186f89352fb522dc67791575f8c9e8081a38795af2706e103d41fa72be4`
- Extracted executable SHA-256: `49f901451242ca039ed27dc9d0bdf9eac97b90a4bdbe8dc8805487c13c34ceb6`
- Vendor signature: `Developer ID Application: Cua AI, Inc. (YCK386LBJ7)`
- Manifest: [`third_party/cua-driver.json`](../third_party/cua-driver.json)

The release fixes include browser-target filtering, foreground/action polling,
window foreground correctness, and session-scoped trajectory handling. Kio's
wrappers still capability-detect every operation and retain freshness checks;
upgrading the vendor binary does not grant model or coordinate authority.

The embedded helper is copied byte-for-byte and its vendor signature is verified
before Kio's host bundle is signed. Run `scripts/check-artifact.py` against the
canonical app to recheck the archive-independent executable hash, version,
signature, and isolated runtime.

The official browser flow remains `get_browser_state` → `browser_prepare` when
CUA returns `browser_consent_required`/`next_action=browser_prepare` → fresh
structured state. Kio does not use bypass flags, profile edits, or undocumented
browser launch arguments. Existing-profile grants are started only through the
official embedded-host mechanism.

CUA Perception 0.2.1 remains a separately installed, signed extension. It is
not bundled in Kio and is not replaced by Apple Vision, OCR, or Gemini Vision.
