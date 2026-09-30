import assert from "node:assert/strict";
import { webcrypto } from "node:crypto";

globalThis.crypto ??= webcrypto;

const origin = process.env.KIO_RELAY_URL ?? "http://127.0.0.1:8787";
const encoder = new TextEncoder();
const decoder = new TextDecoder();
const b64 = (bytes) => Buffer.from(bytes).toString("base64url");
const from64 = (text) => Buffer.from(text, "base64url");
const token = () => b64(crypto.getRandomValues(new Uint8Array(32)));
const deviceID = () => b64(crypto.getRandomValues(new Uint8Array(16)));

async function api(path, { method = "GET", auth, body } = {}) {
  const response = await fetch(new URL(`/api${path}`, origin), {
    method,
    headers: { ...(auth ? { authorization: `Bearer ${auth}` } : {}), ...(body ? { "content-type": "application/json" } : {}) },
    ...(body ? { body: JSON.stringify(body) } : {}),
  });
  const data = await response.json();
  return { response, data };
}

async function makeKey() {
  const pair = await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, ["deriveBits"]);
  return { privateKey: pair.privateKey, publicKey: b64(await crypto.subtle.exportKey("raw", pair.publicKey)) };
}

async function keyFor(privateKey, publicKey, workspaceID) {
  const peer = await crypto.subtle.importKey("raw", from64(publicKey), { name: "ECDH", namedCurve: "P-256" }, false, []);
  const secret = await crypto.subtle.deriveBits({ name: "ECDH", public: peer }, privateKey, 256);
  const material = await crypto.subtle.importKey("raw", secret, "HKDF", false, ["deriveKey"]);
  return crypto.subtle.deriveKey({ name: "HKDF", hash: "SHA-256", salt: encoder.encode(workspaceID), info: encoder.encode("Kio relay envelope v1") }, material, { name: "AES-GCM", length: 256 }, false, ["encrypt", "decrypt"]);
}

async function seal(key, value) {
  const nonce = crypto.getRandomValues(new Uint8Array(12));
  const ciphertext = await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce }, key, encoder.encode(JSON.stringify(value)));
  return { nonce: b64(nonce), ciphertext: b64(new Uint8Array(ciphertext)) };
}

async function open(key, envelope) {
  const clear = await crypto.subtle.decrypt({ name: "AES-GCM", iv: from64(envelope.nonce) }, key, from64(envelope.ciphertext));
  return JSON.parse(decoder.decode(clear));
}

const health = await api("/health");
assert.equal(health.response.status, 200, "local relay is healthy");

const mac = await makeKey();
const macID = deviceID();
const macToken = token();
const invitationResponse = await api("/pairings", { method: "POST", auth: macToken, body: { deviceID: macID, deviceName: "Kio Test Mac", publicKey: mac.publicKey } });
assert.equal(invitationResponse.response.status, 200, JSON.stringify(invitationResponse.data));
const invitation = invitationResponse.data;

const phone = await makeKey();
const phoneID = deviceID();
const phoneToken = token();
const pairResponse = await api("/pairings/complete", { method: "POST", body: {
  pairingID: invitation.pairingID,
  oneTimeToken: invitation.oneTimeToken,
  deviceID: phoneID,
  deviceName: "Test Phone",
  publicKey: phone.publicKey,
  authToken: phoneToken,
} });
assert.equal(pairResponse.response.status, 200, JSON.stringify(pairResponse.data));
assert.equal(pairResponse.data.workspaceID, macID);
assert.equal(pairResponse.data.macPublicKey, mac.publicKey);

const replay = await api("/pairings/complete", { method: "POST", body: {
  pairingID: invitation.pairingID, oneTimeToken: invitation.oneTimeToken,
  deviceID: deviceID(), deviceName: "Replay", publicKey: (await makeKey()).publicKey, authToken: token(),
} });
assert.equal(replay.response.status, 410, "pairing codes are one-use");

const list = await api("/devices", { auth: macToken });
assert.equal(list.data.devices.length, 2);
const macKey = await keyFor(phone.privateKey, invitation.macPublicKey, invitation.workspaceID);
const phoneKey = await keyFor(mac.privateKey, phone.publicKey, invitation.workspaceID);
const fileNonce = crypto.getRandomValues(new Uint8Array(12));
const fileBytes = Uint8Array.from({ length: 2_350_123 }, (_, index) => index % 251);
const encryptedFile = await crypto.subtle.encrypt({ name: "AES-GCM", iv: fileNonce }, macKey, fileBytes);
const fileUpload = await fetch(new URL(`/api/files?recipientID=${encodeURIComponent(macID)}`, origin), {
  method: "POST",
  headers: { authorization: `Bearer ${phoneToken}`, "content-type": "application/octet-stream", "x-kio-file-size": String(fileBytes.length) },
  body: encryptedFile,
});
const transfer = await fileUpload.json();
assert.equal(fileUpload.status, 201, JSON.stringify(transfer));
const original = { type: "request", text: "Merge these PDFs", taskID: "test-task", attachmentID: transfer.id, attachmentNonce: b64(fileNonce), artifactName: "fixture.txt", artifactSize: fileBytes.length, artifactMime: "text/plain", createdAt: new Date().toISOString() };
const encrypted = await seal(macKey, original);
assert(!encrypted.ciphertext.includes(original.text), "relay envelope must not contain plaintext");
const queued = await api("/messages", { method: "POST", auth: phoneToken, body: { recipientID: macID, ...encrypted } });
assert.equal(queued.response.status, 202);
const inbox = await api("/inbox?wait=0", { auth: macToken });
assert.equal(inbox.data.messages.length, 1, "phone task is queued for the Mac");
assert.equal(inbox.data.messages[0].senderPublicKey, phone.publicKey);
assert.deepEqual(await open(phoneKey, inbox.data.messages[0]), original, "Mac receives the original task only after decrypting it");
const fileDownload = await fetch(new URL(`/api/files/${transfer.id}`, origin), { headers: { authorization: `Bearer ${macToken}` } });
assert.equal(fileDownload.status, 200);
const downloadedFile = await crypto.subtle.decrypt({ name: "AES-GCM", iv: fileNonce }, phoneKey, await fileDownload.arrayBuffer());
assert.deepEqual(new Uint8Array(downloadedFile), fileBytes, "D1 chunk storage returns only encrypted file bytes to the recipient");
const fileAck = await fetch(new URL(`/api/files/${transfer.id}/ack`, origin), { method: "POST", headers: { authorization: `Bearer ${macToken}` } });
assert.equal(fileAck.status, 200, "receiving device can remove a completed transfer");
const deletedFile = await fetch(new URL(`/api/files/${transfer.id}`, origin), { headers: { authorization: `Bearer ${macToken}` } });
assert.equal(deletedFile.status, 404, "acknowledged file object is deleted");

const tamperedBytes = from64(inbox.data.messages[0].ciphertext);
tamperedBytes[0] ^= 1;
const tampered = { ...inbox.data.messages[0], ciphertext: b64(tamperedBytes) };
await assert.rejects(open(phoneKey, tampered), "modified ciphertext must fail authenticated decryption");
await api(`/messages/${inbox.data.messages[0].id}/ack`, { method: "POST", auth: macToken });
const empty = await api("/inbox?wait=0", { auth: macToken });
assert.equal(empty.data.messages.length, 0, "acknowledged tasks leave the inbox");

const resultBytes = encoder.encode("result file bytes");
const resultNonce = crypto.getRandomValues(new Uint8Array(12));
const encryptedResultFile = await crypto.subtle.encrypt({ name: "AES-GCM", iv: resultNonce }, phoneKey, resultBytes);
const resultUpload = await fetch(new URL(`/api/files?recipientID=${encodeURIComponent(phoneID)}`, origin), {
  method: "POST",
  headers: { authorization: `Bearer ${macToken}`, "content-type": "application/octet-stream", "x-kio-file-size": String(resultBytes.length) },
  body: encryptedResultFile,
});
assert.equal(resultUpload.status, 201);
const resultTransfer = await resultUpload.json();
const result = { type: "result", text: "Merged file is ready", artifactName: "merged.pdf", artifactSize: resultBytes.length, artifactMime: "application/pdf", attachmentID: resultTransfer.id, attachmentNonce: b64(resultNonce), taskID: original.taskID };
const encryptedResult = await seal(phoneKey, result);
const reply = await api("/messages", { method: "POST", auth: macToken, body: { recipientID: phoneID, ...encryptedResult } });
assert.equal(reply.response.status, 202);
const phoneInbox = await api("/inbox?wait=0", { auth: phoneToken });
assert.deepEqual(await open(macKey, phoneInbox.data.messages[0]), result, "phone decrypts the local Mac result");
const resultDownload = await fetch(new URL(`/api/files/${resultTransfer.id}`, origin), { headers: { authorization: `Bearer ${phoneToken}` } });
assert.equal(resultDownload.status, 200);
const downloadedResult = await crypto.subtle.decrypt({ name: "AES-GCM", iv: resultNonce }, macKey, await resultDownload.arrayBuffer());
assert.deepEqual(new Uint8Array(downloadedResult), resultBytes, "Mac-to-phone artifact bytes are also encrypted end-to-end");

const oversized = await api("/messages", { method: "POST", auth: phoneToken, body: { recipientID: macID, nonce: encrypted.nonce, ciphertext: b64(new Uint8Array(900_100)) } });
assert.equal(oversized.response.status, 413, "relay rejects oversized envelopes");
const oversizedFile = await fetch(new URL(`/api/files?recipientID=${encodeURIComponent(macID)}`, origin), {
  method: "POST",
  headers: { authorization: `Bearer ${phoneToken}`, "content-type": "application/octet-stream", "x-kio-file-size": String(50 * 1024 * 1024 + 1) },
  body: new Uint8Array([1]),
});
assert.equal(oversizedFile.status, 413, "relay rejects files larger than the phone transfer limit");
const foreignAck = await api(`/messages/${phoneInbox.data.messages[0].id}/ack`, { method: "POST", auth: token() });
assert.equal(foreignAck.response.status, 401, "unknown devices cannot acknowledge messages");

const revoked = await api(`/devices/${phoneID}`, { method: "DELETE", auth: macToken });
assert.equal(revoked.response.status, 200);
const revokedRead = await api("/devices", { auth: phoneToken });
assert.equal(revokedRead.response.status, 401, "revoked phone credentials stop working");

console.log("Relay smoke passed: one-time pairing, device auth, encrypted request/reply and multi-chunk files, tamper detection, queue/ack, size bounds, and revocation.");
