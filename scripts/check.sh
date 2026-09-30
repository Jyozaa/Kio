#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA="${KIO_DERIVED_DATA_PATH:-$(getconf DARWIN_USER_DIR)KioDerivedData}"
swift test --package-path "$ROOT/Packages/KioKit"
xcodebuild -quiet \
  -project "$ROOT/apps/mac/KioMac.xcodeproj" \
  -scheme KioMac \
  -configuration Debug \
  -destination 'platform=macOS' \
  -skipPackagePluginValidation \
  -derivedDataPath "$DERIVED_DATA" \
  build
npm ci --prefix "$ROOT/apps/mobile"
npm --prefix "$ROOT/apps/mobile" run build
npm ci --prefix "$ROOT/apps/relay"
npm --prefix "$ROOT/apps/relay" run typecheck
npm --prefix "$ROOT/apps/relay" test
