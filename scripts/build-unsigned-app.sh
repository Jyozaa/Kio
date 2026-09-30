#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Build tools are developer requirements only. The artifact uses none of them.
export UV_PROJECT_ENVIRONMENT="$HOME/Library/Caches/Kio/package-venv"
uv sync --project agent --locked --no-dev --no-editable --reinstall-package companion-agent
scratch="$HOME/Library/Caches/Kio/swift-release"
swift build --package-path apps/macos --scratch-path "$scratch" -c release
staging_root="$(mktemp -d "${TMPDIR:-/tmp}/Kio-build.XXXXXX")"
staging="$staging_root/Kio.app"
cleanup() { rm -rf "$staging_root"; }
trap cleanup EXIT INT TERM
mkdir -p "$staging/Contents/MacOS" "$staging/Contents/Helpers" "$staging/Contents/Resources/models"
cp "$scratch/release/Kio" "$staging/Contents/MacOS/Kio"
cp apps/macos/Info.plist "$staging/Contents/Info.plist"
cp models/*.json "$staging/Contents/Resources/models/"
python3 scripts/package-cua-driver.py \
  --executable "$staging/Contents/Helpers/cua-driver" \
  --license "$staging/Contents/Resources/cua-driver-LICENSE"
cp third_party/cua-driver.json "$staging/Contents/Resources/"
codesign --verify --strict "$staging/Contents/Helpers/cua-driver"
cp THIRD_PARTY_NOTICES.md "$staging/Contents/Resources/"
mkdir -p "$staging/Contents/Resources/third-party-licenses/laya-mlx" "$staging/Contents/Resources/third-party-licenses/mlx"
cp third_party/laya-mlx/LICENSE third_party/laya-mlx/NOTICE "$staging/Contents/Resources/third-party-licenses/laya-mlx/"
cp third_party/mlx/MLX-LICENSE third_party/mlx/MLX-Metal-LICENSE "$staging/Contents/Resources/third-party-licenses/mlx/"
cp -R third_party/python-licenses "$staging/Contents/Resources/python-licenses"
cp agent/uv.lock "$staging/Contents/Resources/uv.lock"
"$UV_PROJECT_ENVIRONMENT/bin/python" scripts/package-runtime.py "$staging/Contents/Resources/python"
scripts/build-stt.sh
cp "$HOME/Library/Caches/Kio/whisper-build/bin/whisper-cli" "$staging/Contents/Helpers/whisper-cli"
cp "$HOME/Library/Caches/Kio/whisper-source/LICENSE" "$staging/Contents/Resources/whisper-LICENSE"
sdl_prefix="${KIO_SDL2_PREFIX:-/opt/homebrew/opt/sdl2-compat}"
sdl3_prefix="${KIO_SDL3_PREFIX:-/opt/homebrew/opt/sdl3}"
if [[ -x "$HOME/Library/Caches/Kio/whisper-build/bin/whisper-stream" \
      && -f "$sdl_prefix/lib/libSDL2-2.0.0.dylib" \
      && -f "$sdl3_prefix/lib/libSDL3.0.dylib" ]]; then
  cp "$HOME/Library/Caches/Kio/whisper-build/bin/whisper-stream" "$staging/Contents/Helpers/whisper-stream"
  cp "$sdl_prefix/lib/libSDL2-2.0.0.dylib" "$staging/Contents/Helpers/libSDL2-2.0.0.dylib"
  cp "$sdl3_prefix/lib/libSDL3.0.dylib" "$staging/Contents/Helpers/libSDL3.dylib"
  install_name_tool -change "$sdl_prefix/lib/libSDL2-2.0.0.dylib" \
    "@rpath/libSDL2-2.0.0.dylib" "$staging/Contents/Helpers/whisper-stream"
  # CMake records the Homebrew search path; remove it from the distributable
  # and keep only the private helper-relative path below.
  install_name_tool -delete_rpath "$sdl_prefix/lib" "$staging/Contents/Helpers/whisper-stream" 2>/dev/null || true
  install_name_tool -add_rpath "@loader_path" "$staging/Contents/Helpers/whisper-stream" 2>/dev/null || true
  # SDL2-compat loads SDL3 dynamically using its loader-relative search path.
  # Remove Homebrew's absolute rpath and give the copied SDL3 a private id.
  install_name_tool -delete_rpath "@loader_path/../../../../opt/sdl3/lib" \
    "$staging/Contents/Helpers/libSDL2-2.0.0.dylib" 2>/dev/null || true
  install_name_tool -add_rpath "@loader_path" "$staging/Contents/Helpers/libSDL2-2.0.0.dylib" 2>/dev/null || true
  # Give the copied SDL2-compat shim a private install name as well.  Leaving
  # Homebrew's absolute install name here makes the artifact non-portable and
  # can make dyld resolve back into the developer machine.
  install_name_tool -id "@rpath/libSDL2-2.0.0.dylib" \
    "$staging/Contents/Helpers/libSDL2-2.0.0.dylib"
  install_name_tool -id "@rpath/libSDL3.dylib" "$staging/Contents/Helpers/libSDL3.dylib"
fi
# Local ad-hoc signing uses an explicit designated requirement so development
# rebuilds retain the Kio bundle identity. A named identity can be supplied with
# KIO_CODESIGN_IDENTITY; no certificate is created by this script.
# Remove known staging metadata that Apple codesign refuses on bundles, while
# preserving com.apple.quarantine on the artifact or any bundled file.
for attribute in com.apple.provenance com.apple.FinderInfo 'com.apple.fileprovider.fpfs#P'; do
  xattr -dr "$attribute" "$staging" 2>/dev/null || true
done
KIO_CODESIGN_IDENTITY="${KIO_CODESIGN_IDENTITY:--}"
KIO_CODESIGN_REQUIREMENT="${KIO_CODESIGN_REQUIREMENT:-=designated => identifier \"local.companion.dev\"}"
# install_name_tool invalidates an existing Mach-O signature.  Re-sign the
# Kio-owned whisper/SDL stack before sealing the outer bundle so macOS does not
# terminate whisper-stream while dyld loads SDL3.  The vendor CUA binary keeps
# its pinned upstream signature and is never rewritten here.
if [[ -f "$staging/Contents/Helpers/whisper-stream" ]]; then
  codesign --force --sign "$KIO_CODESIGN_IDENTITY" --timestamp=none \
    "$staging/Contents/Helpers/libSDL3.dylib"
  codesign --force --sign "$KIO_CODESIGN_IDENTITY" --timestamp=none \
    "$staging/Contents/Helpers/libSDL2-2.0.0.dylib"
  codesign --force --sign "$KIO_CODESIGN_IDENTITY" --timestamp=none \
    "$staging/Contents/Helpers/whisper-stream"
  codesign --verify --strict "$staging/Contents/Helpers/libSDL3.dylib"
  codesign --verify --strict "$staging/Contents/Helpers/libSDL2-2.0.0.dylib"
  codesign --verify --strict "$staging/Contents/Helpers/whisper-stream"
fi
sign_args=(--force --sign "$KIO_CODESIGN_IDENTITY" --timestamp=none --identifier local.companion.dev)
if [ "$KIO_CODESIGN_IDENTITY" = "-" ]; then
  sign_args+=(--requirements "$KIO_CODESIGN_REQUIREMENT")
fi
codesign "${sign_args[@]}" "$staging"
codesign --verify --strict "$staging"
codesign --verify --strict "$staging/Contents/Helpers/cua-driver"
if [ -n "${KIO_BUILD_OUTPUT:-}" ]; then
  output="$KIO_BUILD_OUTPUT"
  rm -rf "$output"
  mkdir -p "$(dirname "$output")"
  ditto "$staging" "$output"
  printf 'Built temporary artifact %s\n' "$output"
else
  output="/Applications/Kio.app"
  if pgrep -f '/Applications/Kio\.app/Contents/MacOS/Kio' >/dev/null 2>&1; then
    osascript -e 'tell application "Kio" to quit' >/dev/null 2>&1 || true
    for _ in $(seq 1 50); do
      pgrep -f '/Applications/Kio\.app/Contents/MacOS/Kio' >/dev/null 2>&1 || break
      sleep 0.1
    done
  fi
  previous="/Applications/.Kio.app.previous.$$"
  if [ -e "$output" ]; then mv "$output" "$previous"; fi
  if ! ditto "$staging" "$output"; then
    rm -rf "$output"
    [ -e "$previous" ] && mv "$previous" "$output"
    exit 1
  fi
  rm -rf "$previous"
  printf 'Installed canonical app %s\n' "$output"
fi
