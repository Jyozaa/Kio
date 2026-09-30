#!/bin/bash
set -euo pipefail
COMPANION_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export COMPANION_ROOT
export UV_PROJECT_ENVIRONMENT="${KIO_DEV_ENV:-$HOME/Library/Caches/Kio/development-venv}"
SWIFT_BUILD="${KIO_SWIFT_BUILD:-$HOME/Library/Caches/Kio/swift-build}"
export KIO_HELPER_PYTHON="$UV_PROJECT_ENVIRONMENT/bin/python"
uv sync --project "$COMPANION_ROOT/agent" --locked --no-editable --reinstall-package companion-agent
swift build --package-path "$COMPANION_ROOT/apps/macos" --scratch-path "$SWIFT_BUILD"
export KIO_STT_EXECUTABLE="${KIO_STT_EXECUTABLE:-$HOME/Library/Caches/Kio/whisper-build/bin/whisper-cli}"
KIO_CODESIGN_IDENTITY="${KIO_CODESIGN_IDENTITY:--}"
KIO_CODESIGN_REQUIREMENT="${KIO_CODESIGN_REQUIREMENT:-=designated => identifier \"local.companion.dev\"}"
bundle="/Applications/Kio.app"
staging_root="$(mktemp -d "${TMPDIR:-/tmp}/Kio-dev.XXXXXX")"
staging="$staging_root/Kio.app"
cleanup() { rm -rf "$staging_root"; }
trap cleanup EXIT INT TERM
mkdir -p "$staging/Contents/MacOS" "$staging/Contents/Resources"
cp "$SWIFT_BUILD/debug/Kio" "$staging/Contents/MacOS/Kio.next"
mv -f "$staging/Contents/MacOS/Kio.next" "$staging/Contents/MacOS/Kio"
cp "$COMPANION_ROOT/apps/macos/Info.plist" "$staging/Contents/Info.plist"
printf '%s\n' "$COMPANION_ROOT" > "$staging/Contents/Resources/KioDevelopmentRoot"
for attribute in com.apple.provenance com.apple.FinderInfo 'com.apple.fileprovider.fpfs#P'; do
  xattr -dr "$attribute" "$staging" 2>/dev/null || true
done
sign_args=(--force --sign "$KIO_CODESIGN_IDENTITY" --timestamp=none --identifier local.companion.dev)
if [ "$KIO_CODESIGN_IDENTITY" = "-" ]; then
  sign_args+=(--requirements "$KIO_CODESIGN_REQUIREMENT")
fi
codesign "${sign_args[@]}" "$staging"
codesign --verify --strict "$staging"
if pgrep -f '/Applications/Kio\.app/Contents/MacOS/Kio' >/dev/null 2>&1; then
  osascript -e 'tell application "Kio" to quit' >/dev/null 2>&1 || true
  for _ in $(seq 1 50); do
    pgrep -f '/Applications/Kio\.app/Contents/MacOS/Kio' >/dev/null 2>&1 || break
    sleep 0.1
  done
fi
previous="/Applications/.Kio.app.previous.$$"
if [ -e "$bundle" ]; then mv "$bundle" "$previous"; fi
if ! ditto "$staging" "$bundle"; then
  rm -rf "$bundle"
  [ -e "$previous" ] && mv "$previous" "$bundle"
  exit 1
fi
rm -rf "$previous"
exec "$bundle/Contents/MacOS/Kio"
