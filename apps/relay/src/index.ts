interface Env { DB: D1Database; ASSETS: Fetcher }

interface DeviceRow {
  id: string;
  workspace_id: string;
  role: "mac" | "phone";
  display_name: string;
  public_key: string;
  credential_hash: string;
  last_seen: number;
  revoked_at: number | null;
}

interface PairingRow {
  id: string;
  workspace_id: string;
  mac_device_id: string;
  token_hash: string;
  expires_at: number;
  consumed_at: number | null;
}

interface EnvelopeRow {
  id: string;
  workspace_id: string;
  sender_id: string;
  recipient_id: string;
  nonce: string;
  ciphertext: string;
  created_at: number;
  display_name: string;
  public_key: string;
}

const MAX_CIPHERTEXT_CHARS = 900_000;
const ENVELOPE_TTL_SECONDS = 24 * 60 * 60;
const PAIRING_TTL_SECONDS = 5 * 60;
const MAC_ONLINE_SECONDS = 45;
const TRANSFER_TTL_SECONDS = 24 * 60 * 60;
const MAX_FILE_BYTES = 50 * 1024 * 1024;
const MAX_WORKSPACE_TRANSFER_BYTES = 64 * 1024 * 1024;
const MAX_GLOBAL_TRANSFER_BYTES = 384 * 1024 * 1024;
const MAX_WORKSPACE_CREATIONS_PER_IP_DAY = 5;
const MAX_TRANSFER_UPLOADS_PER_DEVICE_HOUR = 12;
const FILE_CHUNK_BYTES = 1_000_000;

function json(body: unknown, status = 200, headers: HeadersInit = {}): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store", ...headers } });
}

function error(message: string, status: number): Response { return json({ error: message }, status); }

function base64URL(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

function decodeBase64(value: string): Uint8Array | undefined {
  try {
    const normalized = value.replaceAll("-", "+").replaceAll("_", "/");
    const raw = atob(normalized);
    return Uint8Array.from(raw, (character) => character.charCodeAt(0));
  } catch { return; }
}

async function sha256(value: string): Promise<string> {
  return base64URL(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value))));
}

async function allowWorkspaceCreation(request: Request, env: Env, now: number): Promise<boolean> {
  const source = request.headers.get("CF-Connecting-IP")?.trim() || "local-unknown";
  const ipHash = await sha256(`kio-workspace-creation-v1:${source}`);
  const dayStart = Math.floor(now / 86_400) * 86_400;
  const result = await env.DB.prepare(`INSERT INTO pairing_ip_limits (ip_hash, window_start, request_count, expires_at)
    VALUES (?, ?, 1, ?)
    ON CONFLICT (ip_hash, window_start) DO UPDATE SET request_count = request_count + 1, expires_at = excluded.expires_at
    WHERE request_count < ?`)
    .bind(ipHash, dayStart, dayStart + 2 * 86_400, MAX_WORKSPACE_CREATIONS_PER_IP_DAY).run();
  return result.meta.changes > 0;
}

async function allowTransferUpload(deviceID: string, env: Env, now: number): Promise<boolean> {
  const hourStart = Math.floor(now / 3_600) * 3_600;
  const result = await env.DB.prepare(`INSERT INTO transfer_device_limits (device_id, window_start, request_count, expires_at)
    VALUES (?, ?, 1, ?)
    ON CONFLICT (device_id, window_start) DO UPDATE SET request_count = request_count + 1, expires_at = excluded.expires_at
    WHERE request_count < ?`)
    .bind(deviceID, hourStart, hourStart + 2 * 3_600, MAX_TRANSFER_UPLOADS_PER_DEVICE_HOUR).run();
  return result.meta.changes > 0;
}

function randomToken(size = 32): string { return base64URL(crypto.getRandomValues(new Uint8Array(size))); }
function validID(value: unknown): value is string { return typeof value === "string" && /^[A-Za-z0-9_-]{16,80}$/.test(value); }
function validPublicKey(value: unknown): value is string {
  if (typeof value !== "string") return false;
  const bytes = decodeBase64(value);
  return bytes?.length === 65 && bytes[0] === 4;
}

async function readJSON(request: Request): Promise<Record<string, unknown> | undefined> {
  const length = Number(request.headers.get("content-length") ?? 0);
  if (length > MAX_CIPHERTEXT_CHARS + 12_000) return;
  try {
    const raw = await request.text();
    if (raw.length > MAX_CIPHERTEXT_CHARS + 12_000) return;
    const body = JSON.parse(raw) as unknown;
    return body && typeof body === "object" && !Array.isArray(body) ? body as Record<string, unknown> : undefined;
  } catch { return; }
}

async function bearerDevice(request: Request, env: Env): Promise<DeviceRow | undefined> {
  const authorization = request.headers.get("authorization") ?? "";
  const match = /^Bearer ([A-Za-z0-9_-]{32,100})$/.exec(authorization);
  if (!match) return;
  const hash = await sha256(match[1]);
  const device = await env.DB.prepare("SELECT id, workspace_id, role, display_name, public_key, credential_hash, last_seen, revoked_at FROM devices WHERE credential_hash = ? AND revoked_at IS NULL")
    .bind(hash).first<DeviceRow>();
  return device ?? undefined;
}

async function route(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);
  const path = url.pathname;
  const now = Math.floor(Date.now() / 1000);

  if (path === "/api/health" && request.method === "GET") return json({ ok: true, version: 1 });

  if (path === "/api/pairings" && request.method === "POST") {
    const body = await readJSON(request);
    const deviceID = body?.deviceID;
    const authToken = request.headers.get("authorization")?.replace(/^Bearer /, "");
    const publicKey = body?.publicKey;
    const deviceName = typeof body?.deviceName === "string" ? body.deviceName.trim().slice(0, 48) : "Kio Mac";
    if (!validID(deviceID) || !authToken || !/^[A-Za-z0-9_-]{32,100}$/.test(authToken) || !validPublicKey(publicKey)) return error("Pairing request is incomplete or invalid.", 400);
    const credentialHash = await sha256(authToken);
    let device: DeviceRow | undefined = await env.DB.prepare("SELECT id, workspace_id, role, display_name, public_key, credential_hash, last_seen, revoked_at FROM devices WHERE credential_hash = ? AND revoked_at IS NULL")
      .bind(credentialHash).first<DeviceRow>() ?? undefined;
    if (device) {
      if (device.role !== "mac" || device.id !== deviceID || device.public_key !== publicKey) return error("This Mac identity does not match the paired device.", 403);
      await env.DB.prepare("UPDATE devices SET last_seen = ? WHERE id = ?").bind(now, device.id).run();
    } else {
      if (!await allowWorkspaceCreation(request, env, now)) return error("This network has created the daily limit of Kio workspaces. Try again tomorrow.", 429);
      const existing = await env.DB.prepare("SELECT id FROM devices WHERE id = ?").bind(deviceID).first<{ id: string }>();
      if (existing) return error("This device identifier is already in use.", 409);
      await env.DB.batch([
        env.DB.prepare("INSERT INTO workspaces (id, mac_device_id, created_at) VALUES (?, ?, ?)").bind(deviceID, deviceID, now),
        env.DB.prepare("INSERT INTO devices (id, workspace_id, role, display_name, public_key, credential_hash, created_at, last_seen) VALUES (?, ?, 'mac', ?, ?, ?, ?, ?)")
          .bind(deviceID, deviceID, deviceName || "Kio Mac", publicKey, credentialHash, now, now),
      ]);
      device = await env.DB.prepare("SELECT id, workspace_id, role, display_name, public_key, credential_hash, last_seen, revoked_at FROM devices WHERE id = ?")
        .bind(deviceID).first<DeviceRow>() ?? undefined;
    }
    if (!device) return error("Kio could not prepare a pairing session.", 500);
    const pairingID = crypto.randomUUID().replaceAll("-", "");
    const oneTimeToken = randomToken();
    await env.DB.prepare("INSERT INTO pairing_requests (id, workspace_id, mac_device_id, token_hash, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?)")
      .bind(pairingID, device.workspace_id, device.id, await sha256(oneTimeToken), now, now + PAIRING_TTL_SECONDS).run();
    return json({ pairingID, oneTimeToken, workspaceID: device.workspace_id, macDeviceID: device.id, macPublicKey: device.public_key, expiresAt: now + PAIRING_TTL_SECONDS });
  }

  if (path === "/api/pairings/complete" && request.method === "POST") {
    const body = await readJSON(request);
    const pairingID = body?.pairingID;
    const oneTimeToken = body?.oneTimeToken;
    const deviceID = body?.deviceID;
    const deviceName = typeof body?.deviceName === "string" ? body.deviceName.trim().slice(0, 48) : "My phone";
    const publicKey = body?.publicKey;
    const authToken = body?.authToken;
    if (typeof pairingID !== "string" || !/^[a-f0-9]{32}$/.test(pairingID) || typeof oneTimeToken !== "string" || !/^[A-Za-z0-9_-]{32,100}$/.test(oneTimeToken) || !validID(deviceID) || !validPublicKey(publicKey) || typeof authToken !== "string" || !/^[A-Za-z0-9_-]{32,100}$/.test(authToken)) return error("Pairing link is invalid or expired. Create a fresh QR code on your Mac.", 400);
    const pairing = await env.DB.prepare("SELECT id, workspace_id, mac_device_id, token_hash, expires_at, consumed_at FROM pairing_requests WHERE id = ?")
      .bind(pairingID).first<PairingRow>();
    if (!pairing || pairing.expires_at < now || pairing.consumed_at || pairing.token_hash !== await sha256(oneTimeToken)) return error("Pairing link is invalid or expired. Create a fresh QR code on your Mac.", 410);
    const existing = await env.DB.prepare("SELECT id FROM devices WHERE id = ? OR credential_hash = ?").bind(deviceID, await sha256(authToken)).first<{ id: string }>();
    if (existing) return error("This device identifier is already paired.", 409);
    const mac = await env.DB.prepare("SELECT public_key FROM devices WHERE id = ? AND workspace_id = ? AND revoked_at IS NULL")
      .bind(pairing.mac_device_id, pairing.workspace_id).first<{ public_key: string }>();
    if (!mac) return error("The Mac for this pairing is no longer available.", 410);
    const claim = await env.DB.prepare("UPDATE pairing_requests SET consumed_at = ? WHERE id = ? AND consumed_at IS NULL AND expires_at > ?")
      .bind(now, pairing.id, now).run();
    if (!claim.meta.changes) return error("That pairing code was already used.", 410);
    await env.DB.prepare("INSERT INTO devices (id, workspace_id, role, display_name, public_key, credential_hash, created_at, last_seen) VALUES (?, ?, 'phone', ?, ?, ?, ?, ?)")
      .bind(deviceID, pairing.workspace_id, deviceName || "My phone", publicKey, await sha256(authToken), now, now).run();
    await env.DB.prepare("UPDATE workspaces SET phone_paired_at = COALESCE(phone_paired_at, ?) WHERE id = ?")
      .bind(now, pairing.workspace_id).run();
    return json({ workspaceID: pairing.workspace_id, macDeviceID: pairing.mac_device_id, macPublicKey: mac.public_key });
  }

  const device = await bearerDevice(request, env);
  if (!device) return error("This device is not paired. Pair it again from Kio on your Mac.", 401);

  if (path === "/api/devices" && request.method === "GET") {
    const result = await env.DB.prepare("SELECT id, role, display_name AS displayName, public_key AS publicKey, last_seen AS lastSeen FROM devices WHERE workspace_id = ? AND revoked_at IS NULL ORDER BY created_at")
      .bind(device.workspace_id).all();
    return json({ devices: result.results });
  }

  if (path === "/api/status" && request.method === "GET") {
    const mac = await env.DB.prepare("SELECT last_seen FROM devices WHERE workspace_id = ? AND role = 'mac' AND revoked_at IS NULL")
      .bind(device.workspace_id).first<{ last_seen: number }>();
    const lastSeen = mac?.last_seen ?? 0;
    return json({ macOnline: lastSeen > now - MAC_ONLINE_SECONDS, macLastSeen: lastSeen ? new Date(lastSeen * 1000).toISOString() : null });
  }

  if (path === "/api/files" && request.method === "POST") {
    const recipientID = url.searchParams.get("recipientID");
    const reportedSize = Number(request.headers.get("x-kio-file-size"));
    const contentLength = Number(request.headers.get("content-length") ?? reportedSize + 16);
    if (!validID(recipientID) || recipientID === device.id || !Number.isSafeInteger(reportedSize) || reportedSize < 1 || reportedSize > MAX_FILE_BYTES || contentLength !== reportedSize + 16) return error("Encrypted file is invalid or larger than 50 MB.", 413);
    const recipient = await env.DB.prepare("SELECT id FROM devices WHERE id = ? AND workspace_id = ? AND revoked_at IS NULL")
      .bind(recipientID, device.workspace_id).first<{ id: string }>();
    if (!recipient) return error("The paired device is unavailable.", 404);
    if (!await allowTransferUpload(device.id, env, now)) return error("This paired device has reached its temporary file-transfer rate limit. Try again in about an hour.", 429);
    const active = await env.DB.prepare(`SELECT
      COALESCE(SUM(CASE WHEN workspace_id = ? THEN size_bytes ELSE 0 END), 0) AS workspace_total,
      COALESCE(SUM(size_bytes), 0) AS global_total
      FROM transfers WHERE expires_at > ?`)
      .bind(device.workspace_id, now).first<{ workspace_total: number; global_total: number }>();
    if ((active?.workspace_total ?? 0) + reportedSize > MAX_WORKSPACE_TRANSFER_BYTES || (active?.global_total ?? 0) + reportedSize > MAX_GLOBAL_TRANSFER_BYTES) return error("The temporary relay is at capacity for this workspace or the free relay tier. Try again after older transfers expire.", 429);
    const encrypted = await request.arrayBuffer();
    if (encrypted.byteLength !== reportedSize + 16) return error("Encrypted file size does not match its metadata.", 400);
    const id = crypto.randomUUID().replaceAll("-", "");
    const statements = [env.DB.prepare(`INSERT INTO transfers (id, workspace_id, sender_id, recipient_id, size_bytes, created_at, expires_at)
      SELECT ?, ?, ?, ?, ?, ?, ?
      WHERE (SELECT COALESCE(SUM(size_bytes), 0) FROM transfers WHERE workspace_id = ? AND expires_at > ?) + ? <= ?
        AND (SELECT COALESCE(SUM(size_bytes), 0) FROM transfers WHERE expires_at > ?) + ? <= ?`)
      .bind(id, device.workspace_id, device.id, recipientID, reportedSize, now, now + TRANSFER_TTL_SECONDS,
        device.workspace_id, now, reportedSize, MAX_WORKSPACE_TRANSFER_BYTES, now, reportedSize, MAX_GLOBAL_TRANSFER_BYTES)];
    for (let offset = 0, index = 0; offset < encrypted.byteLength; offset += FILE_CHUNK_BYTES, index++) {
      const end = Math.min(offset + FILE_CHUNK_BYTES, encrypted.byteLength);
      statements.push(env.DB.prepare("INSERT INTO transfer_chunks (transfer_id, chunk_index, encrypted_chunk) VALUES (?, ?, ?)")
        .bind(id, index, new Uint8Array(encrypted, offset, end - offset)));
    }
    try {
      await env.DB.batch(statements);
    } catch (cause) {
      if (cause instanceof Error && (cause.message.includes("transfer capacity reached") || cause.message.includes("FOREIGN KEY constraint failed"))) return error("The temporary relay is at capacity. Try again after older transfers expire.", 429);
      throw cause;
    }
    return json({ id, expiresAt: now + TRANSFER_TTL_SECONDS }, 201);
  }

  const transferRoute = /^\/api\/files\/([A-Za-z0-9_-]{32})(?:\/(ack))?$/.exec(path);
  if (transferRoute) {
    const transfer = await env.DB.prepare("SELECT id, workspace_id, sender_id, recipient_id, size_bytes, expires_at FROM transfers WHERE id = ? AND workspace_id = ?")
      .bind(transferRoute[1], device.workspace_id).first<{ id: string; workspace_id: string; sender_id: string; recipient_id: string; size_bytes: number; expires_at: number }>();
    if (!transfer || transfer.expires_at <= now || ![transfer.sender_id, transfer.recipient_id].includes(device.id)) return error("That encrypted file has expired or is unavailable.", 404);
    if (transferRoute[2] === "ack" && request.method === "POST") {
      if (device.id !== transfer.recipient_id) return error("Only the receiving device can confirm this transfer.", 403);
      await env.DB.prepare("DELETE FROM transfers WHERE id = ?").bind(transfer.id).run();
      return json({ received: true });
    }
    if (request.method === "GET") {
      const object = await env.DB.prepare("SELECT encrypted_chunk FROM transfer_chunks WHERE transfer_id = ? ORDER BY chunk_index")
        .bind(transfer.id).all<{ encrypted_chunk: ArrayBuffer }>();
      const chunks = object.results.map((row) => row.encrypted_chunk instanceof ArrayBuffer ? new Uint8Array(row.encrypted_chunk) : new Uint8Array(row.encrypted_chunk));
      const encryptedSize = transfer.size_bytes + 16;
      if (chunks.length !== Math.ceil(encryptedSize / FILE_CHUNK_BYTES) || chunks.reduce((total, chunk) => total + chunk.byteLength, 0) !== encryptedSize) return error("The temporary encrypted file is not ready. Retry shortly.", 503);
      const body = new ReadableStream<Uint8Array>({
        start(controller) {
          for (const chunk of chunks) controller.enqueue(chunk);
          controller.close();
        },
      });
      return new Response(body, { headers: { "content-type": "application/octet-stream", "cache-control": "no-store", "content-length": String(encryptedSize) } });
    }
  }

  if (path === "/api/messages" && request.method === "POST") {
    const body = await readJSON(request);
    if (!validID(body?.recipientID) || body.recipientID === device.id || typeof body?.nonce !== "string" || decodeBase64(body.nonce)?.length !== 12 || typeof body?.ciphertext !== "string" || body.ciphertext.length < 24 || body.ciphertext.length > MAX_CIPHERTEXT_CHARS || !decodeBase64(body.ciphertext)) return error("Encrypted message is invalid or too large.", 413);
    const recipient = await env.DB.prepare("SELECT id FROM devices WHERE id = ? AND workspace_id = ? AND revoked_at IS NULL")
      .bind(body.recipientID, device.workspace_id).first<{ id: string }>();
    if (!recipient) return error("The paired device is unavailable.", 404);
    const id = crypto.randomUUID().replaceAll("-", "");
    await env.DB.prepare("INSERT INTO envelopes (id, workspace_id, sender_id, recipient_id, nonce, ciphertext, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)")
      .bind(id, device.workspace_id, device.id, body.recipientID, body.nonce, body.ciphertext, now, now + ENVELOPE_TTL_SECONDS).run();
    return json({ id, queuedAt: new Date(now * 1000).toISOString() }, 202);
  }

  if (path === "/api/inbox" && request.method === "GET") {
    await env.DB.prepare("UPDATE devices SET last_seen = ? WHERE id = ?").bind(now, device.id).run();
    const waitSeconds = Math.min(20, Math.max(0, Number(url.searchParams.get("wait") ?? 0) || 0));
    const deadline = Date.now() + waitSeconds * 1000;
    let messages: EnvelopeRow[] = [];
    do {
      const result = await env.DB.prepare(`SELECT e.id, e.workspace_id, e.sender_id, e.recipient_id, e.nonce, e.ciphertext, e.created_at, d.display_name, d.public_key
        FROM envelopes e JOIN devices d ON d.id = e.sender_id
        WHERE e.recipient_id = ? AND e.consumed_at IS NULL AND e.expires_at > ? AND d.revoked_at IS NULL
        ORDER BY e.created_at LIMIT 20`).bind(device.id, now).all<EnvelopeRow>();
      messages = result.results;
      if (messages.length || Date.now() >= deadline) break;
      await new Promise((resolve) => setTimeout(resolve, 800));
    } while (true);
    return json({ messages: messages.map((message) => ({ id: message.id, senderID: message.sender_id, senderName: message.display_name, senderPublicKey: message.public_key, nonce: message.nonce, ciphertext: message.ciphertext, createdAt: new Date(message.created_at * 1000).toISOString() })) });
  }

  const ack = /^\/api\/messages\/([A-Za-z0-9_-]{32})\/ack$/.exec(path);
  if (ack && request.method === "POST") {
    await env.DB.prepare("UPDATE envelopes SET consumed_at = ? WHERE id = ? AND recipient_id = ? AND workspace_id = ? AND consumed_at IS NULL")
      .bind(now, ack[1], device.id, device.workspace_id).run();
    return json({ acknowledged: true });
  }

  const remove = /^\/api\/devices\/([A-Za-z0-9_-]{16,80})$/.exec(path);
  if (remove && request.method === "DELETE") {
    const target = await env.DB.prepare("SELECT id, role FROM devices WHERE id = ? AND workspace_id = ? AND revoked_at IS NULL")
      .bind(remove[1], device.workspace_id).first<{ id: string; role: "mac" | "phone" }>();
    if (!target) return error("That paired device no longer exists.", 404);
    if (device.id !== target.id && (device.role !== "mac" || target.role !== "phone")) return error("Only this phone or its paired Mac can revoke a device.", 403);
    if (target.role === "mac") return error("Remove the pairing from a phone to revoke it. The Mac identity cannot be removed here.", 409);
    await env.DB.batch([
      env.DB.prepare("UPDATE devices SET revoked_at = ? WHERE id = ?").bind(now, target.id),
      env.DB.prepare("DELETE FROM envelopes WHERE sender_id = ? OR recipient_id = ?").bind(target.id, target.id),
      env.DB.prepare("DELETE FROM transfers WHERE sender_id = ? OR recipient_id = ?").bind(target.id, target.id),
      env.DB.prepare("DELETE FROM transfer_device_limits WHERE device_id = ?").bind(target.id),
    ]);
    return json({ revoked: true });
  }

  return error("Not found.", 404);
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname.startsWith("/api/")) {
      if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: { "access-control-allow-methods": "GET,POST,DELETE,OPTIONS", "access-control-allow-headers": "authorization,content-type", "access-control-max-age": "600" } });
      try { return await route(request, env); }
      catch (cause) {
        const message = cause instanceof Error ? cause.message.toLowerCase() : "";
        if (message.includes("daily row read limit")) return error("The relay has reached today's free database read limit. Try again after midnight UTC.", 503);
        if (message.includes("daily row write limit")) return error("The relay has reached today's free database write limit. Try again after midnight UTC.", 503);
        if (message.includes("storage limit")) return error("The relay's free database storage is full. Try again after expired data is cleaned up.", 507);
        if (message.includes("overloaded") || message.includes("busy")) return error("The relay database is temporarily busy. Try again shortly.", 503);
        return error("The relay could not complete that request. Try again shortly.", 500);
      }
    }
    return env.ASSETS.fetch(request);
  },
  async scheduled(_event: ScheduledController, env: Env, _context: ExecutionContext): Promise<void> {
    const now = Math.floor(Date.now() / 1000);
    const retentionCutoff = now - 30 * 86_400;
    await env.DB.batch([
      env.DB.prepare("DELETE FROM transfers WHERE expires_at <= ?").bind(now),
      env.DB.prepare("DELETE FROM envelopes WHERE expires_at <= ? OR consumed_at IS NOT NULL").bind(now),
      env.DB.prepare("DELETE FROM pairing_requests WHERE expires_at <= ? OR consumed_at IS NOT NULL").bind(now),
      env.DB.prepare("DELETE FROM devices WHERE role = 'phone' AND revoked_at IS NOT NULL AND revoked_at <= ?").bind(retentionCutoff),
      env.DB.prepare("DELETE FROM pairing_ip_limits WHERE expires_at <= ?").bind(now),
      env.DB.prepare("DELETE FROM transfer_device_limits WHERE expires_at <= ?").bind(now),
      env.DB.prepare("DELETE FROM transfer_chunks WHERE NOT EXISTS (SELECT 1 FROM transfers WHERE transfers.id = transfer_chunks.transfer_id)"),
      env.DB.prepare(`DELETE FROM workspaces
        WHERE phone_paired_at IS NULL
          AND created_at <= ?
          AND NOT EXISTS (SELECT 1 FROM devices WHERE devices.workspace_id = workspaces.id AND devices.last_seen > ?)
          AND NOT EXISTS (SELECT 1 FROM devices WHERE devices.workspace_id = workspaces.id AND devices.role = 'phone')
          AND NOT EXISTS (SELECT 1 FROM envelopes WHERE envelopes.workspace_id = workspaces.id)
          AND NOT EXISTS (SELECT 1 FROM transfers WHERE transfers.workspace_id = workspaces.id)
          AND NOT EXISTS (SELECT 1 FROM pairing_requests WHERE pairing_requests.workspace_id = workspaces.id)`)
        .bind(retentionCutoff, retentionCutoff),
    ]);
  },
} satisfies ExportedHandler<Env>;
