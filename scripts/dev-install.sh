#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA="${KIO_DERIVED_DATA_PATH:-$(getconf DARWIN_USER_DIR)KioDerivedData}"
SOURCE_APP="${1:-$DERIVED_DATA/Build/Products/Debug/Kio.app}"
TARGET_APP="${KIO_DEV_APP_PATH:-$HOME/Applications/Kio.app}"
IDENTITY="$(/usr/bin/python3 "$ROOT/scripts/dev_signing.py" resolve)"

bundle_id() {
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null || true
}

if [[ ! -d "$SOURCE_APP" ]]; then
  echo "Debug app bundle not found: $SOURCE_APP" >&2
  exit 1
fi
if [[ "$(bundle_id "$SOURCE_APP")" != "app.kio.mac" ]]; then
  echo "Refusing to install source app with unexpected bundle identifier: $(bundle_id "$SOURCE_APP")" >&2
  exit 1
fi

TARGET_DIR="$(dirname "$TARGET_APP")"
mkdir -p "$TARGET_DIR"
if [[ -e "$TARGET_APP" ]]; then
  EXISTING_ID="$(bundle_id "$TARGET_APP")"
  if [[ "$EXISTING_ID" != "app.kio.mac" ]]; then
    echo "Refusing to replace $TARGET_APP because its bundle identifier is '$EXISTING_ID' (expected app.kio.mac). Choose another KIO_DEV_APP_PATH or resolve the identity conflict first." >&2
    exit 2
  fi
fi

STAGING_ROOT="$(mktemp -d "$TARGET_DIR/.Kio-install.XXXXXX")"
STAGED_APP="$STAGING_ROOT/Kio.app"
cleanup() { rm -rf "$STAGING_ROOT"; }
trap cleanup EXIT INT TERM

ditto "$SOURCE_APP" "$STAGED_APP"
xattr -cr "$STAGED_APP"
REEL="$STAGED_APP/Contents/Resources/Reel"
while IFS= read -r -d '' candidate; do
  if file -b "$candidate" | grep -q 'Mach-O'; then
    codesign --force --sign "$IDENTITY" --timestamp=none "$candidate"
  fi
done < <(find "$REEL" -type f -print0)
codesign --force --sign "$IDENTITY" --timestamp=none --identifier app.kio.mac "$STAGED_APP"
codesign --verify --strict --verbose=2 "$STAGED_APP"
while IFS= read -r -d '' candidate; do
  if file -b "$candidate" | grep -q 'Mach-O'; then
    codesign --verify --strict --verbose=2 "$candidate"
  fi
done < <(find "$REEL" -type f -print0)
codesign -dr - "$STAGED_APP" 2>&1

SOURCE_APP_REAL="$(cd "$SOURCE_APP" && pwd -P)"
TARGET_APP_REAL="$(cd "$TARGET_DIR" && pwd -P)/$(basename "$TARGET_APP")"

# Stop only the canonical install or this exact build output. Several unrelated
# Kio-branded apps share the executable name and bundle ID on this Mac. Using
# Apple Events here can also block on a first-run Automation permission dialog.
# Legacy Kio (local.companion.dev) and other Kio app copies are left untouched.
for _ in $(seq 1 100); do
  RUNNING=0
  while IFS= read -r PID; do
    [[ -n "$PID" ]] || continue
    COMMAND="$(ps -p "$PID" -o command= 2>/dev/null || true)"
    [[ "$COMMAND" == *"/Contents/MacOS/Kio" ]] || continue
    APP_PATH="${COMMAND%/Contents/MacOS/Kio}"
    [[ "$(bundle_id "$APP_PATH")" == "app.kio.mac" ]] || continue
    APP_PATH_REAL="$(cd "$APP_PATH" 2>/dev/null && pwd -P || true)"
    [[ "$APP_PATH_REAL" == "$TARGET_APP_REAL" || "$APP_PATH_REAL" == "$SOURCE_APP_REAL" ]] || continue
    RUNNING=1
    kill -TERM "$PID" 2>/dev/null || true
  done < <(pgrep -x Kio 2>/dev/null || true)
  [[ "$RUNNING" == 0 ]] && break
  sleep 0.1
done
if [[ "${RUNNING:-0}" != 0 ]]; then
  echo "The canonical/debug Kio process is still running; refusing to replace a live app bundle." >&2
  exit 1
fi

/usr/bin/swift "$ROOT/scripts/atomic-replace-app.swift" "$STAGED_APP" "$TARGET_APP"
echo "Installed Kio at $TARGET_APP with signing identity $IDENTITY"
