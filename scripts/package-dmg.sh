#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$("$ROOT/scripts/version.sh")"
CONFIGURATION=Release KIO_VERSION_OVERRIDE="$VERSION" "$ROOT/scripts/build-mac.sh"
DERIVED_DATA="${KIO_DERIVED_DATA_PATH:-$(getconf DARWIN_USER_DIR)KioDerivedData}"
APP="$DERIVED_DATA/Build/Products/Release/Kio.app"
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/Kio-DMG.XXXXXX")"
DIST="$ROOT/build/release"
DMG="$DIST/Kio-$VERSION.dmg"

mkdir -p "$DIST"
ditto "$APP" "$STAGING/Kio.app"
xattr -cr "$STAGING/Kio.app"
codesign --verify --deep --strict "$STAGING/Kio.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname Kio -srcfolder "$STAGING" -ov -format UDZO "$DMG"
hdiutil verify "$DMG"
shasum -a 256 "$DMG" > "$DMG.sha256"
printf 'DMG: %s\nChecksum: %s\n' "$DMG" "$DMG.sha256"
