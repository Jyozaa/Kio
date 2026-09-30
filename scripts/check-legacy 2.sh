#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export UV_PROJECT_ENVIRONMENT="${KIO_DEV_ENV:-$HOME/Library/Caches/Kio/development-venv}"
uv sync --project agent --locked --no-editable --reinstall-package companion-agent
uv run --project agent --no-editable ruff check agent
uv run --project agent --no-editable ruff format --check agent
uv run --project agent --no-editable pytest
swift build --package-path apps/macos --scratch-path "$HOME/Library/Caches/Kio/swift-build"
swift test --package-path apps/macos --scratch-path "$HOME/Library/Caches/Kio/swift-build"
