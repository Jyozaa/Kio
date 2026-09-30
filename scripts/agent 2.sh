#!/bin/bash
set -euo pipefail
runtime="${KIO_DEV_ENV:-$HOME/Library/Caches/Kio/development-venv}"
exec "$runtime/bin/python" "$@"
