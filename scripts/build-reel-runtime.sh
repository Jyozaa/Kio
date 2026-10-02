#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$ROOT/Packages/KioKit/Sources/KioTools/Resources/ReelRuntime.json"
CACHE="$ROOT/.cache/reel"
ARTIFACTS="$CACHE/artifacts"
RUNTIME="$CACHE/runtime/Reel"
RESOURCE="$ROOT/apps/mac/KioMac/Reel"
WORK="$CACHE/work.$$"

if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
  echo "Reel's pinned runtime currently targets Apple Silicon macOS (arm64)." >&2
  exit 2
fi
mkdir -p "$ARTIFACTS"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

manifest_value() {
  /usr/bin/python3 - "$MANIFEST" "$1" "$2" <<'PY'
import json, sys
m=json.load(open(sys.argv[1]))
component=next(item for item in m["components"] if item["id"] == sys.argv[2])
print(component[sys.argv[3]])
PY
}

fetch_component() {
  local id="$1" field="$2" version url sha dest tmp
  version="$(manifest_value "$id" version)"
  url="$(manifest_value "$id" artifactURL)"
  sha="$(manifest_value "$id" sha256)"
  dest="$ARTIFACTS/$id-$version"
  if [[ -f "$dest" ]] && [[ "$(shasum -a 256 "$dest" | awk '{print $1}')" == "$sha" ]]; then
    printf '%s\n' "$dest"
    return
  fi
  tmp="$dest.download.$$"
  rm -f "$tmp"
  echo "Fetching pinned $id $version" >&2
  curl --fail --location --retry 3 --silent --show-error "$url" -o "$tmp"
  if [[ "$(shasum -a 256 "$tmp" | awk '{print $1}')" != "$sha" ]]; then
    rm -f "$tmp"
    echo "SHA-256 mismatch for $id; artifact rejected." >&2
    exit 1
  fi
  mv "$tmp" "$dest"
  printf '%s\n' "$dest"
}

manifest_digest="$(
  {
    shasum -a 256 "$MANIFEST" | awk '{print $1}'
    shasum -a 256 "$0" | awk '{print $1}'
  } | shasum -a 256 | awk '{print $1}'
)"
if [[ -f "$RUNTIME/.manifest-sha256" ]] \
  && [[ "$(cat "$RUNTIME/.manifest-sha256")" == "$manifest_digest" ]] \
  && "$RUNTIME/yt-dlp" --version >/dev/null \
  && "$RUNTIME/deno" --version >/dev/null \
  && "$RUNTIME/ffmpeg/bin/ffmpeg" -version >/dev/null \
  && "$RUNTIME/ffmpeg/bin/ffprobe" -version >/dev/null \
  && "$RUNTIME/streamlink/python/bin/python3.12" -B -I -c 'import sys; sys.path.insert(0,sys.argv[1]); from streamlink_cli.main import main; print("streamlink ready")' "$RUNTIME/streamlink/site-packages" >/dev/null; then
  mkdir -p "$(dirname "$RESOURCE")"
  rm -rf "$RESOURCE"
  ditto "$RUNTIME" "$RESOURCE"
  echo "Reel runtime cache is current; copied pinned runtime into the app resources input."
  exit 0
fi

rm -rf "$WORK"
mkdir -p "$WORK/Reel" "$WORK/unpack" "$WORK/Reel/streamlink/site-packages" "$WORK/Reel/Sources"
STAGE="$WORK/Reel"
mkdir -p "$STAGE/LICENSES"
cp "$ROOT/third_party/reel/LICENSE-DENO-MIT.txt" "$STAGE/LICENSES/Deno-MIT.txt"
cp "$ROOT/third_party/reel/LICENSE-ytdlp-Unlicense.txt" "$STAGE/LICENSES/yt-dlp-Unlicense.txt"
cp "$MANIFEST" "$STAGE/reel-runtime.json"

yt_dlp_archive="$(fetch_component yt-dlp artifactURL)"
cp "$yt_dlp_archive" "$STAGE/yt-dlp"
chmod 755 "$STAGE/yt-dlp"

deno_archive="$(fetch_component deno artifactURL)"
mkdir -p "$WORK/deno"
ditto -x -k "$deno_archive" "$WORK/deno"
deno_bin="$(find "$WORK/deno" -type f -name deno -print -quit)"
[[ -n "$deno_bin" ]] || { echo "Pinned Deno archive did not contain the deno executable." >&2; exit 1; }
cp "$deno_bin" "$STAGE/deno"
chmod 755 "$STAGE/deno"

python_archive="$(fetch_component python artifactURL)"
mkdir -p "$WORK/python"
tar -xzf "$python_archive" -C "$WORK/python"
python_prefix="$(/usr/bin/python3 - "$WORK/python" <<'PY'
import os, pathlib, sys
root=pathlib.Path(sys.argv[1])
candidates=[p for p in root.rglob("python3.12") if p.is_file() and os.access(p, os.X_OK) and p.parent.name == "bin"]
for path in sorted(candidates):
    try:
        import subprocess
        if "3.12.14" in subprocess.check_output([str(path), "--version"], stderr=subprocess.STDOUT, text=True, timeout=10):
            print(path.parent.parent)
            break
    except Exception:
        pass
else:
    raise SystemExit("No runnable CPython 3.12.14 arm64 bin/python3.12 found in the pinned archive")
PY
)"
mkdir -p "$STAGE/streamlink/python"
ditto "$python_prefix" "$STAGE/streamlink/python"
python_license="$(find "$python_prefix" -type f \( -name 'LICENSE.txt' -o -name 'LICENSE' \) -print -quit)"
if [[ -n "$python_license" ]]; then cp "$python_license" "$STAGE/LICENSES/Python-PSF.txt"; fi

/usr/bin/python3 - "$MANIFEST" "$ARTIFACTS" "$STAGE/streamlink/site-packages" <<'PY'
import hashlib, json, pathlib, subprocess, sys, urllib.request, zipfile
manifest=json.load(open(sys.argv[1]))
cache=pathlib.Path(sys.argv[2])
destination=pathlib.Path(sys.argv[3])
for wheel in manifest["wheels"]:
    path=cache / (wheel["name"] + "-" + wheel["version"] + ".whl")
    if not path.exists() or hashlib.sha256(path.read_bytes()).hexdigest() != wheel["sha256"]:
        temporary=path.with_suffix(path.suffix+".download")
        print("Fetching pinned Streamlink dependency " + wheel["name"], file=sys.stderr)
        urllib.request.urlretrieve(wheel["url"], temporary)
        if hashlib.sha256(temporary.read_bytes()).hexdigest() != wheel["sha256"]:
            temporary.unlink(missing_ok=True)
            raise SystemExit("SHA-256 mismatch for wheel " + wheel["name"] + "; artifact rejected")
        temporary.replace(path)
    with zipfile.ZipFile(path) as archive:
        for item in archive.infolist():
            candidate=pathlib.PurePosixPath(item.filename)
            if candidate.is_absolute() or ".." in candidate.parts or "\\" in item.filename:
                raise SystemExit("Unsafe path in pinned wheel: " + wheel["name"])
            mode=(item.external_attr >> 16) & 0o170000
            if mode == 0o120000:
                raise SystemExit("Symbolic links are not accepted in pinned wheels: " + wheel["name"])
        archive.extractall(destination)
PY

ffmpeg_archive="$(fetch_component ffmpeg artifactURL)"
lame_archive="$(fetch_component lame artifactURL)"
cp "$ffmpeg_archive" "$STAGE/Sources/ffmpeg-9.0.2.tar.xz"
cp "$lame_archive" "$STAGE/Sources/lame-3.100.tar.gz"
tar -xJf "$ffmpeg_archive" -C "$WORK/unpack"
tar -xzf "$lame_archive" -C "$WORK/unpack"
ffmpeg_source="$WORK/unpack/ffmpeg-9.0.2"
lame_source="$WORK/unpack/lame-3.100"
[[ -d "$ffmpeg_source" && -d "$lame_source" ]] || { echo "Pinned LGPL media source tree was incomplete." >&2; exit 1; }
if grep -q '^lame_init_old$' "$lame_source/include/libmp3lame.sym"; then
  # LAME config makes this obsolete entry static; Apple's ld rejects exporting a static symbol.
  sed -i '' '/^lame_init_old$/d' "$lame_source/include/libmp3lame.sym"
  cat > "$STAGE/Sources/lame-export-list.patch" <<'EOF'
The bundled macOS build removes the obsolete lame_init_old symbol from
include/libmp3lame.sym because LAME 3.100 configures that deprecated function
as static, while Apple's linker rejects it in the exported-symbol list.
This does not change the library API used by FFmpeg (which calls lame_init).
EOF
fi
cp "$ffmpeg_source/COPYING.LGPLv2.1" "$STAGE/LICENSES/FFmpeg-LGPLv2.1.txt"
cp "$lame_source/LICENSE" "$STAGE/LICENSES/LAME-LICENSE.txt"

(
  cd "$lame_source"
  ./configure --prefix="$STAGE/lame" --enable-shared --disable-static --disable-frontend
  make -j"$(sysctl -n hw.ncpu)"
  make install
)
export PKG_CONFIG_PATH="$STAGE/lame/lib/pkgconfig"
(
  cd "$ffmpeg_source"
  ./configure --prefix="$STAGE/ffmpeg" --enable-shared --disable-static --disable-gpl --disable-version3 \
    --disable-nonfree --disable-autodetect --enable-videotoolbox --disable-doc --disable-debug --disable-ffplay --enable-libmp3lame \
    --extra-cflags="-I$STAGE/lame/include" --extra-ldflags="-L$STAGE/lame/lib"
  make -j"$(sysctl -n hw.ncpu)"
  make install
)

mkdir -p "$STAGE/ffmpeg/lib"
cp -a "$STAGE/lame/lib/libmp3lame"*.dylib "$STAGE/ffmpeg/lib/"
rm -rf "$STAGE/lame"
for binary in "$STAGE/ffmpeg/bin/ffmpeg" "$STAGE/ffmpeg/bin/ffprobe"; do
  install_name_tool -add_rpath '@executable_path/../lib' "$binary" 2>/dev/null || true
done
while IFS= read -r -d '' library; do
  install_name_tool -id "@rpath/$(basename "$library")" "$library" 2>/dev/null || true
  install_name_tool -add_rpath '@loader_path' "$library" 2>/dev/null || true
done < <(find "$STAGE/ffmpeg/lib" -type f -name '*.dylib' -print0)
while IFS= read -r -d '' macho; do
  while IFS= read -r rpath; do
    case "$rpath" in
      "$STAGE"/*) install_name_tool -delete_rpath "$rpath" "$macho" ;;
    esac
  done < <(otool -l "$macho" | awk '/cmd LC_RPATH/ { getline; getline; print $2 }')
  while IFS= read -r dependency; do
    case "$dependency" in
      "$STAGE"/*) install_name_tool -change "$dependency" "@rpath/$(basename "$dependency")" "$macho" ;;
    esac
  done < <(otool -L "$macho" | sed -n '2,$s/^[[:space:]]*\([^[:space:]]*\).*/\1/p')
done < <(find "$STAGE/ffmpeg" -type f \( -name 'ffmpeg' -o -name 'ffprobe' -o -name '*.dylib' \) -print0)
cat > "$STAGE/ffmpeg/BUILD-CONFIG.txt" <<'EOF'
FFmpeg 9.0.2 built from the pinned upstream source in ../Sources/ffmpeg-9.0.2.tar.xz.
Configuration: shared LGPL build, --disable-gpl --disable-version3 --disable-nonfree,
with dynamically linked LAME 3.100 (LGPL-2.0-or-later). No x264/x265 or GPL codecs.
The corresponding source archives and this build configuration ship with Reel.
EOF
cat > "$STAGE/THIRD_PARTY_NOTICES.md" <<'EOF'
Reel bundled runtime notices

- yt-dlp 2026.08.19: Unlicense; see LICENSES/yt-dlp-Unlicense.txt.
- Deno 2.9.7 arm64: MIT; see LICENSES/Deno-MIT.txt.
- FFmpeg/ffprobe 9.0.2: built from the accompanying source archives as shared LGPL-2.1-or-later code with GPL, version-3, and nonfree options disabled. The build links shared LAME 3.100 (LGPL-2.0-or-later). Sources and build configuration are included in Sources/ and ffmpeg/BUILD-CONFIG.txt.
- CPython 3.12.14: PSF-2.0; see LICENSES/Python-PSF.txt when included and upstream runtime metadata.
- Streamlink 8.6.0: BSD-2-Clause. Each pinned wheel is listed with its license and upstream URL in reel-runtime.json; wheel license metadata is retained under streamlink/site-packages.
- gallery-dl is not included. It is GPL-2.0-only and the repository does not declare the Kio distribution license needed to determine compatible redistribution terms.
EOF

"$STAGE/yt-dlp" --version | grep -F "$(manifest_value yt-dlp version)" >/dev/null
"$STAGE/deno" --version | grep -F "$(manifest_value deno version)" >/dev/null
"$STAGE/ffmpeg/bin/ffmpeg" -version | grep -F "$(manifest_value ffmpeg version)" >/dev/null
"$STAGE/ffmpeg/bin/ffmpeg" -hide_banner -encoders 2>/dev/null | grep -F 'h264_videotoolbox' >/dev/null
"$STAGE/streamlink/python/bin/python3.12" -B -I -c 'import sys; sys.path.insert(0,sys.argv[1]); from streamlink_cli.main import main; raise SystemExit(main())' "$STAGE/streamlink/site-packages" --version | grep -F "$(manifest_value streamlink version)" >/dev/null
"$STAGE/ffmpeg/bin/ffprobe" -version | grep -F "$(manifest_value ffprobe version)" >/dev/null
printf '%s\n' "$manifest_digest" > "$STAGE/.manifest-sha256"
rm -rf "$RUNTIME"
mkdir -p "$(dirname "$RUNTIME")"
mv "$STAGE" "$RUNTIME"
mkdir -p "$(dirname "$RESOURCE")"
rm -rf "$RESOURCE"
ditto "$RUNTIME" "$RESOURCE"
echo "Prepared pinned Reel runtime in $RUNTIME and copied it to the Kio app resources input."
