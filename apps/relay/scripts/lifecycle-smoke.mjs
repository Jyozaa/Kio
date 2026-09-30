import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";

const origin = process.env.KIO_RELAY_URL ?? "http://127.0.0.1:8787";
const now = Math.floor(Date.now() / 1000);
const old = now - 31 * 86_400;
const ids = {
  abandonedWorkspace: "lifecycle-abandoned-workspace",
  abandonedMac: "lifecycle-abandoned-mac-id",
  activeWorkspace: "lifecycle-active-workspace",
  activeMac: "lifecycle-active-mac-id",
  pairedWorkspace: "lifecycle-paired-workspace",
  pairedMac: "lifecycle-paired-mac-id",
  revokedPhone: "lifecycle-revoked-phone-id",
  envelope: "lifecycle-expired-envelope",
  pairing: "0123456789abcdef0123456789abcdef",
  transfer: "0123456789abcdef0123456789abcdee",
};

function sql(command) {
  const output = execFileSync("npx", ["wrangler", "d1", "execute", "kio-relay", "--local", "--json", "--command", command, "--config", "wrangler.jsonc"], { encoding: "utf8" });
  return JSON.parse(output);
}

sql(`
DELETE FROM pairing_requests WHERE id = '${ids.pairing}';
DELETE FROM envelopes WHERE id = '${ids.envelope}';
DELETE FROM transfers WHERE id = '${ids.transfer}';
DELETE FROM devices WHERE id IN ('${ids.abandonedMac}', '${ids.activeMac}', '${ids.pairedMac}', '${ids.revokedPhone}');
DELETE FROM workspaces WHERE id IN ('${ids.abandonedWorkspace}', '${ids.activeWorkspace}', '${ids.pairedWorkspace}');
DELETE FROM pairing_ip_limits WHERE ip_hash = 'lifecycle-ip';
DELETE FROM transfer_device_limits WHERE device_id = '${ids.revokedPhone}';`);

const seed = `
INSERT INTO workspaces (id, mac_device_id, created_at, phone_paired_at) VALUES
  ('${ids.abandonedWorkspace}', '${ids.abandonedMac}', ${old}, NULL),
  ('${ids.activeWorkspace}', '${ids.activeMac}', ${old}, NULL),
  ('${ids.pairedWorkspace}', '${ids.pairedMac}', ${old}, ${old});
INSERT INTO devices (id, workspace_id, role, display_name, public_key, credential_hash, created_at, last_seen, revoked_at) VALUES
  ('${ids.abandonedMac}', '${ids.abandonedWorkspace}', 'mac', 'Old Mac', 'test-key', 'hash-abandoned-mac', ${old}, ${old}, NULL),
  ('${ids.activeMac}', '${ids.activeWorkspace}', 'mac', 'Active Mac', 'test-key', 'hash-active-mac', ${old}, ${now}, NULL),
  ('${ids.pairedMac}', '${ids.pairedWorkspace}', 'mac', 'Paired Mac', 'test-key', 'hash-paired-mac', ${old}, ${old}, NULL),
  ('${ids.revokedPhone}', '${ids.pairedWorkspace}', 'phone', 'Revoked Phone', 'test-key', 'hash-revoked-phone', ${old}, ${old}, ${old});
INSERT INTO pairing_requests (id, workspace_id, mac_device_id, token_hash, created_at, expires_at, consumed_at)
VALUES ('${ids.pairing}', '${ids.pairedWorkspace}', '${ids.pairedMac}', 'test-token', ${old}, ${now - 1}, NULL);
INSERT INTO envelopes (id, workspace_id, sender_id, recipient_id, nonce, ciphertext, created_at, expires_at, consumed_at)
VALUES ('${ids.envelope}', '${ids.pairedWorkspace}', '${ids.pairedMac}', '${ids.revokedPhone}', 'nonce', 'ciphertext', ${now - 100}, ${now + 3600}, ${now - 10});
INSERT INTO transfers (id, workspace_id, sender_id, recipient_id, size_bytes, created_at, expires_at)
VALUES ('${ids.transfer}', '${ids.pairedWorkspace}', '${ids.pairedMac}', '${ids.revokedPhone}', 1, ${old}, ${now - 1});
INSERT INTO transfer_chunks (transfer_id, chunk_index, encrypted_chunk) VALUES ('${ids.transfer}', 0, X'01');
INSERT INTO pairing_ip_limits (ip_hash, window_start, request_count, expires_at) VALUES ('lifecycle-ip', ${old}, 1, ${now - 1});
INSERT INTO transfer_device_limits (device_id, window_start, request_count, expires_at) VALUES ('${ids.revokedPhone}', ${old}, 1, ${now - 1});`;
sql(seed);

const scheduled = await fetch(new URL("/cdn-cgi/local/scheduled", origin));
assert.equal(scheduled.ok, true, `scheduled cleanup trigger failed: ${scheduled.status} ${await scheduled.text()}`);

const workspaces = sql(`SELECT id FROM workspaces WHERE id IN ('${ids.abandonedWorkspace}', '${ids.activeWorkspace}', '${ids.pairedWorkspace}')`)[0].results.map((row) => row.id);
assert.deepEqual(workspaces.sort(), [ids.activeWorkspace, ids.pairedWorkspace].sort(), "stale never-paired workspaces are removed while active and ever-paired workspaces remain");
assert.equal(sql(`SELECT id FROM devices WHERE id = '${ids.revokedPhone}'`)[0].results.length, 0, "revoked phone credentials are removed after the retention period");
assert.equal(sql(`SELECT id FROM pairing_requests WHERE id = '${ids.pairing}'`)[0].results.length, 0, "expired pairing requests are removed");
assert.equal(sql(`SELECT id FROM envelopes WHERE id = '${ids.envelope}'`)[0].results.length, 0, "acknowledged envelopes are removed");
assert.equal(sql(`SELECT id FROM transfers WHERE id = '${ids.transfer}'`)[0].results.length, 0, "expired transfers are removed");
assert.equal(sql(`SELECT transfer_id FROM transfer_chunks WHERE transfer_id = '${ids.transfer}'`)[0].results.length, 0, "transfer chunks are removed with their transfer");
assert.equal(sql("SELECT ip_hash FROM pairing_ip_limits WHERE ip_hash = 'lifecycle-ip'")[0].results.length, 0, "expired IP limits are removed");
assert.equal(sql(`SELECT device_id FROM transfer_device_limits WHERE device_id = '${ids.revokedPhone}'`)[0].results.length, 0, "expired device limits are removed");

console.log("Relay lifecycle smoke passed: abandoned never-paired workspace cleanup, active and ever-paired retention, revoked device retention, and stale row cleanup.");
