#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RELAY="$ROOT/apps/relay"
cd "$RELAY"

if ! npx wrangler whoami >/dev/null 2>&1; then
  echo 'Cloudflare authentication is required. Run `npx wrangler login`, finish the browser authorization, then run this script again.' >&2
  exit 1
fi

DATABASE_ID="$(npx wrangler d1 list --json | node -e '
let input = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => input += chunk);
process.stdin.on("end", () => {
  try {
    const rows = JSON.parse(input);
    const match = rows.find((row) => row.name === "kio-relay");
    if (match) process.stdout.write(match.uuid ?? match.database_id ?? "");
  } catch {}
});
')"

if [ -z "$DATABASE_ID" ]; then
  npx wrangler d1 create kio-relay --location weur --update-config --binding DB
else
  node --input-type=module - "$DATABASE_ID" <<'NODE'
import { readFileSync, writeFileSync } from 'node:fs';
const path = 'wrangler.jsonc';
const config = JSON.parse(readFileSync(path, 'utf8'));
const database = config.d1_databases.find((entry) => entry.binding === 'DB');
if (!database) throw new Error('D1 binding DB is missing from wrangler.jsonc');
database.database_id = process.argv[2];
writeFileSync(path, `${JSON.stringify(config, null, 2)}\n`);
NODE
fi

npx wrangler d1 migrations apply kio-relay --remote --config "$RELAY/wrangler.jsonc"
npm ci --prefix "$ROOT/apps/mobile"
npm --prefix "$ROOT/apps/mobile" run build
npx wrangler deploy --config "$RELAY/wrangler.jsonc"
