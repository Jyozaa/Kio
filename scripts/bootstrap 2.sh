#!/usr/bin/env bash
set -euo pipefail

if ! command -v xcodebuild >/dev/null || ! command -v swift >/dev/null; then
  echo 'Install Xcode and its command line tools to build Kio.' >&2
  exit 1
fi
if ! command -v node >/dev/null || ! command -v npm >/dev/null; then
  echo 'Install Node.js and npm to build the mobile PWA and relay.' >&2
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
swift package --package-path "$ROOT/Packages/KioKit" resolve
npm ci --prefix "$ROOT/apps/mobile"
npm ci --prefix "$ROOT/apps/relay"
echo 'Kio local dependencies are ready.'
