#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$ROOT/apps/mac/KioMac.xcodeproj/KioVersion.xcconfig"

if [[ -n "${KIO_VERSION_OVERRIDE:-}" ]]; then
  VERSION="$KIO_VERSION_OVERRIDE"
elif [[ "${GITHUB_REF_NAME:-}" == v* ]]; then
  VERSION="${GITHUB_REF_NAME#v}"
else
  VERSION="$(sed -nE 's/^KIO_VERSION[[:space:]]*=[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+).*$/\1/p' "$CONFIG" | head -n 1)"
fi

if [[ ! "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  echo "Kio version must use MAJOR.MINOR.PATCH (got '$VERSION')." >&2
  exit 2
fi

printf '%s\n' "$VERSION"
