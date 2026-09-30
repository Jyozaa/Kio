#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Credential-free, non-interactive checks. No desktop actions, microphone or Gemini.
scripts/check.sh
mkdir -p "$HOME/Library/Caches/Kio"
check_root="$(mktemp -d "$HOME/Library/Caches/Kio/check-all.XXXXXX")"
trap 'rm -rf "$check_root"' EXIT
KIO_BUILD_OUTPUT="$check_root/Kio.app" scripts/build-unsigned-app.sh
scripts/agent.sh scripts/check-artifact.py "$check_root/Kio.app"
scripts/agent.sh -m companion_agent.training train \
  --dataset fixtures/trajectories/autonomy-export/train.jsonl \
  --output "$check_root/training-smoke" --steps 1 --device cpu
scripts/agent.sh scripts/privacy-audit.py
printf 'Checks passed. Tested artifact: %s\nTraining metadata: %s\n' "$check_root/Kio.app" "$check_root/training-smoke/kio_training.json"
