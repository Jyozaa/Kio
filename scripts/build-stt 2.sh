#!/bin/bash
set -euo pipefail
# Build an unmodified pinned upstream runtime outside the source checkout.
cache="${KIO_STT_CACHE:-$HOME/Library/Caches/Kio}"
mkdir -p "$cache"
archive="$cache/whisper-v1.9.4.tar.gz"
if [[ ! -f "$archive" ]]; then
  curl --fail --location https://github.com/ggml-org/whisper.cpp/archive/refs/tags/v1.9.4.tar.gz -o "$archive"
fi
expected="57e280cee375ab02425b806ad5146b99f6eb9357e3c2b31357c8a6af2e2e44ae"
actual="$(shasum -a 256 "$archive" | cut -d ' ' -f 1)"
[[ "$actual" == "$expected" ]] || { echo "whisper.cpp source checksum mismatch" >&2; exit 1; }
mkdir -p "$cache/whisper-source"
tar -xzf "$archive" -C "$cache/whisper-source" --strip-components 1
sdk="${KIO_MACOS_SDK:-$(xcode-select -p)/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk}"
if [[ ! -d "$sdk" ]]; then sdk="$(xcrun --show-sdk-path)"; fi
cmake_args=(
  -DCMAKE_OSX_SYSROOT="$sdk" -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF
  -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF -DGGML_METAL=ON
)
# whisper-stream is an official whisper.cpp local microphone sample.  Build it
# when the locally available SDL2 development package is present; the packaged
# app then carries the dylib beside the helper and never relies on Homebrew at
# runtime.  The normal whisper-cli path remains available without SDL2.
sdl_prefix="${KIO_SDL2_PREFIX:-/opt/homebrew/opt/sdl2-compat}"
sdl3_prefix="${KIO_SDL3_PREFIX:-/opt/homebrew/opt/sdl3}"
if [[ -d "$sdl_prefix" && -f "$sdl_prefix/lib/libSDL2-2.0.0.dylib" \
      && -f "$sdl3_prefix/lib/libSDL3.0.dylib" ]]; then
  cmake_args+=(
    -DWHISPER_BUILD_EXAMPLES=ON -DWHISPER_SDL2=ON
    -DSDL2_DIR="$sdl_prefix/lib/cmake/SDL2"
  )
else
  cmake_args+=(-DWHISPER_BUILD_EXAMPLES=OFF -DWHISPER_SDL2=OFF)
fi
cmake -S "$cache/whisper-source" -B "$cache/whisper-build" \
  "${cmake_args[@]}"
cmake --build "$cache/whisper-build" --target whisper-cli -j 4
if [[ -f "$sdl_prefix/lib/libSDL2-2.0.0.dylib" && -f "$sdl3_prefix/lib/libSDL3.0.dylib" ]]; then
  cmake --build "$cache/whisper-build" --target whisper-stream -j 4
fi
