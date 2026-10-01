#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA="${KIO_DERIVED_DATA_PATH:-$(getconf DARWIN_USER_DIR)KioDerivedData}"
VERSION="$("$ROOT/scripts/version.sh")"
SIGNING_MODE="${KIO_BUILD_SIGNING_MODE:-public}"

case "$SIGNING_MODE" in
  public)
    # Public/CI/DMG builds deliberately remain identity-free and reproducible.
    SIGNING_ARGS=(CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY=-)
    ;;
  development)
    IDENTITY="${KIO_DEV_CODESIGN_IDENTITY:-$(/usr/bin/python3 "$ROOT/scripts/dev_signing.py" resolve)}"
    # Xcode's identity picker ignores untrusted local self-signed identities.
    # Compile without signing, then apply Kio's stable local identity below.
    SIGNING_ARGS=(CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY=-)
    ;;
  *)
    echo "Unknown KIO_BUILD_SIGNING_MODE '$SIGNING_MODE' (use public or development)." >&2
    exit 2
    ;;
esac

# Downloads/builds pinned helper artifacts only during an explicit developer/package build.
# Normal Kio.app execution never downloads or installs Reel components.
"$ROOT/scripts/build-reel-runtime.sh"

xcodebuild -quiet \
  -project "$ROOT/apps/mac/KioMac.xcodeproj" \
  -scheme KioMac \
  -configuration "${CONFIGURATION:-Release}" \
  -destination 'platform=macOS' \
  -skipPackagePluginValidation \
  -derivedDataPath "$DERIVED_DATA" \
  KIO_VERSION="$VERSION" \
  "${SIGNING_ARGS[@]}" \
  build

APP="$DERIVED_DATA/Build/Products/${CONFIGURATION:-Release}/Kio.app"
xattr -cr "$APP"
REEL="$APP/Contents/Resources/Reel"
if [[ ! -x "$REEL/yt-dlp" || ! -x "$REEL/deno" || ! -x "$REEL/ffmpeg/bin/ffmpeg" || ! -x "$REEL/streamlink/python/bin/python3.12" ]]; then
  echo "Built Kio.app is missing one or more bundled Reel runtime executables." >&2
  exit 1
fi
/usr/bin/python3 - "$REEL" <<'PY'
from pathlib import Path
import shutil, sys
root = Path(sys.argv[1])
for cache in root.rglob("__pycache__"):
    shutil.rmtree(cache)
for bytecode in root.rglob("*.pyc"):
    bytecode.unlink()
PY
SIGNING_ID="-"
if [[ "$SIGNING_MODE" == "development" ]]; then
  SIGNING_ID="$IDENTITY"
fi

# Sign actual nested Mach-O files first. Python source files are data and are not signed.
while IFS= read -r -d '' candidate; do
  if file -b "$candidate" | grep -q 'Mach-O'; then
    codesign --force --sign "$SIGNING_ID" --timestamp=none "$candidate"
  fi
done < <(find "$REEL" -type f -print0)
codesign --force --sign "$SIGNING_ID" --timestamp=none --identifier app.kio.mac "$APP"
codesign --verify --strict --verbose=2 "$APP"
while IFS= read -r -d '' candidate; do
  if file -b "$candidate" | grep -q 'Mach-O'; then
    codesign --verify --strict --verbose=2 "$candidate"
  fi
done < <(find "$REEL" -type f -print0)
if [[ "$SIGNING_MODE" == "development" ]]; then
  echo "Signing mode: development ($IDENTITY)"
else
  echo "Signing mode: public (ad hoc; no personal identity required)"
fi
printf 'Built app: %s\n' "$APP"
