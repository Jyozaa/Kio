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
if [[ "$SIGNING_MODE" == "development" ]]; then
  # Sign after clearing build attributes with Kio's stable local certificate.
  codesign --force --deep --sign "$IDENTITY" --timestamp=none --identifier app.kio.mac "$APP"
  codesign --verify --deep --strict "$APP"
  echo "Signing mode: development ($IDENTITY)"
else
  codesign --force --deep --sign - --identifier app.kio.mac "$APP"
  codesign --verify --deep --strict "$APP"
  echo "Signing mode: public (ad hoc; no personal identity required)"
fi
printf 'Built app: %s\n' "$APP"
