#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA="${KIO_DERIVED_DATA_PATH:-$(getconf DARWIN_USER_DIR)KioDashboardDerivedData}"
SWIFT_BUILD_PATH="${KIO_SWIFT_BUILD_PATH:-$(getconf DARWIN_USER_DIR)KioDashboardSwiftBuild}"
XCODE_PROJECT_ROOT="$ROOT"

git -C "$ROOT" diff --check
"$ROOT/scripts/build-reel-runtime.sh"
export KIO_REEL_RUNTIME_ROOT="$ROOT/.cache/reel/runtime/Reel"
python3 -m unittest discover -s "$ROOT/scripts/tests" -p 'test_*.py'
swift test --package-path "$ROOT/Packages/KioKit" --build-path "$SWIFT_BUILD_PATH"

# Xcode's recursive file coordination can stall on Desktop/File Provider checkouts.
# Build from a short-lived source snapshot there; CI and ordinary checkouts build in place.
if [[ "$ROOT/" == "$HOME/Desktop/"* ]]; then
  XCODE_SOURCE_COPY="$(mktemp -d "${TMPDIR:-/tmp}/KioXcodeBuild.XXXXXX")"
  cleanup_xcode_source_copy() {
    python3 - "$XCODE_SOURCE_COPY" <<'PY'
from pathlib import Path
import shutil
import sys
import tempfile

path = Path(sys.argv[1]).resolve()
assert path.parent == Path(tempfile.gettempdir()).resolve()
assert path.name.startswith("KioXcodeBuild.")
shutil.rmtree(path)
PY
  }
  trap cleanup_xcode_source_copy EXIT
  mkdir -p "$XCODE_SOURCE_COPY/apps/mac" "$XCODE_SOURCE_COPY/Packages/KioKit"
  rsync -a --exclude=ReelRuntime --exclude=.DS_Store "$ROOT/apps/mac/KioMac/" "$XCODE_SOURCE_COPY/apps/mac/KioMac/"
  ditto "$ROOT/apps/mac/KioMac.xcodeproj" "$XCODE_SOURCE_COPY/apps/mac/KioMac.xcodeproj"
  ditto "$ROOT/Packages/KioKit/Package.swift" "$XCODE_SOURCE_COPY/Packages/KioKit/Package.swift"
  ditto "$ROOT/Packages/KioKit/Sources" "$XCODE_SOURCE_COPY/Packages/KioKit/Sources"
  XCODE_PROJECT_ROOT="$XCODE_SOURCE_COPY"
fi

for configuration in Debug Release; do
  xcodebuild -quiet \
    -project "$XCODE_PROJECT_ROOT/apps/mac/KioMac.xcodeproj" \
    -scheme KioMac \
    -configuration "$configuration" \
    -destination 'platform=macOS' \
    -skipPackagePluginValidation \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY=- \
    build
done
