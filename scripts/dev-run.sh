#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY="$(/usr/bin/python3 "$ROOT/scripts/dev_signing.py" setup)"
DERIVED_DATA="${KIO_DERIVED_DATA_PATH:-$(getconf DARWIN_USER_DIR)KioDerivedData}"

KIO_BUILD_SIGNING_MODE=development \
KIO_DEV_CODESIGN_IDENTITY="$IDENTITY" \
KIO_DERIVED_DATA_PATH="$DERIVED_DATA" \
CONFIGURATION=Debug \
  "$ROOT/scripts/build-mac.sh"

"$ROOT/scripts/dev-install.sh" "$DERIVED_DATA/Build/Products/Debug/Kio.app"
open -na "${KIO_DEV_APP_PATH:-$HOME/Applications/Kio.app}"
