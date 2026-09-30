#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA="${KIO_DERIVED_DATA_PATH:-$(getconf DARWIN_USER_DIR)KioDerivedData}"
VERSION="$("$ROOT/scripts/version.sh")"
xcodebuild -quiet \
  -project "$ROOT/apps/mac/KioMac.xcodeproj" \
  -scheme KioMac \
  -configuration "${CONFIGURATION:-Release}" \
  -destination 'platform=macOS' \
  -skipPackagePluginValidation \
  -derivedDataPath "$DERIVED_DATA" \
  KIO_VERSION="$VERSION" \
  build

APP="$DERIVED_DATA/Build/Products/${CONFIGURATION:-Release}/Kio.app"
xattr -cr "$APP"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
printf 'Built app: %s\n' "$APP"
