#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
npx wrangler d1 migrations apply kio-relay --local --config wrangler.jsonc
npx wrangler dev --local --ip 127.0.0.1 --port 8787 --config wrangler.jsonc > /tmp/kio-relay-local.log 2>&1 &
worker_pid=$!
cleanup() {
  kill "$worker_pid" 2>/dev/null || true
  wait "$worker_pid" 2>/dev/null || true
}
trap cleanup EXIT

for _ in {1..60}; do
  if curl --silent --fail http://127.0.0.1:8787/api/health >/dev/null; then break; fi
  sleep 1
done
KIO_RELAY_URL=http://127.0.0.1:8787 node scripts/relay-smoke.mjs
KIO_RELAY_URL=http://127.0.0.1:8787 node scripts/lifecycle-smoke.mjs
