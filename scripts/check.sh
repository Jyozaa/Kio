#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA="${KIO_DERIVED_DATA_PATH:-$(getconf DARWIN_USER_DIR)KioDerivedData}"
SWIFT_BUILD_PATH="${KIO_SWIFT_BUILD_PATH:-$(getconf DARWIN_USER_DIR)KioSwiftBuild}"
git -C "$ROOT" diff --check
"$ROOT/scripts/build-reel-runtime.sh"
export KIO_REEL_RUNTIME_ROOT="$ROOT/.cache/reel/runtime/Reel"
python3 -m unittest discover -s "$ROOT/scripts/tests" -p 'test_*.py'
swift test --package-path "$ROOT/Packages/KioKit" --build-path "$SWIFT_BUILD_PATH"
xcodebuild -quiet \
  -project "$ROOT/apps/mac/KioMac.xcodeproj" \
  -scheme KioMac \
  -configuration Debug \
  -destination 'platform=macOS' \
  -skipPackagePluginValidation \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY=- \
  build
xcodebuild -quiet \
  -project "$ROOT/apps/mac/KioMac.xcodeproj" \
  -scheme KioMac \
  -configuration Release \
  -destination 'platform=macOS' \
  -skipPackagePluginValidation \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY=- \
  build
npm ci --prefix "$ROOT/apps/mobile"
npm --prefix "$ROOT/apps/mobile" run build
npm --prefix "$ROOT/apps/mobile" test
npm ci --prefix "$ROOT/apps/relay"
npm --prefix "$ROOT/apps/relay" run typecheck
npm --prefix "$ROOT/apps/relay" test
