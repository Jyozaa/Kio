import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { webcrypto } from "node:crypto";

Object.defineProperty(globalThis, "crypto", { value: webcrypto, configurable: true });
const { decryptPayload, encryptPayload } = await import("../src/crypto.ts");

function bytes(value) {
  let normalized = value.replaceAll("-", "+").replaceAll("_", "/");
  if (normalized.length % 4) normalized += "=".repeat(4 - normalized.length % 4);
  return Buffer.from(normalized, "base64");
}

function b64url(value) {
  return Buffer.from(value).toString("base64url");
}

function privateJWK(privateKey, publicKey) {
  const point = bytes(publicKey);
  assert.equal(point.length, 65);
  assert.equal(point[0], 4);
  return {
    kty: "EC", crv: "P-256", x: b64url(point.subarray(1, 33)), y: b64url(point.subarray(33)),
    d: b64url(bytes(privateKey)), ext: true, key_ops: ["deriveBits"],
  };
}

test("PWA decrypts the shared Swift relay crypto vector", async () => {
  const fixtureURL = new URL("../../../Packages/KioKit/Tests/KioSyncTests/Fixtures/relay-crypto-vector.json", import.meta.url);
  const fixture = JSON.parse(await readFile(fixtureURL, "utf8"));
  const phonePrivate = await crypto.subtle.importKey("jwk", privateJWK(fixture.phonePrivateKey, fixture.phonePublicKey), { name: "ECDH", namedCurve: "P-256" }, false, ["deriveBits"]);
  const opened = await decryptPayload(
    { privateKey: phonePrivate, workspaceID: fixture.workspaceID },
    fixture.macPublicKey,
    fixture.nonce,
    fixture.ciphertext,
  );
  assert.equal(JSON.stringify(opened), fixture.plaintext);
});

test("PWA encrypts/decrypts multi-attachment manifests and legacy single-file payloads", async () => {
  const sender = await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, ["deriveBits"]);
  const recipient = await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, ["deriveBits"]);
  const senderPublic = b64url(await crypto.subtle.exportKey("raw", sender.publicKey));
  const recipientPublic = b64url(await crypto.subtle.exportKey("raw", recipient.publicKey));
  const senderIdentity = { privateKey: sender.privateKey, workspaceID: "mobile-test-workspace" };
  const recipientIdentity = { privateKey: recipient.privateKey, workspaceID: "mobile-test-workspace" };
  const modern = {
    type: "request", text: "Summarize these photos", taskID: "multi-1", createdAt: new Date(0).toISOString(),
    attachments: [
      { transferID: "transfer-a", nonce: "nonce-a", name: "receipt-1.jpg", size: 1200, mime: "image/jpeg" },
      { transferID: "transfer-b", nonce: "nonce-b", name: "receipt-2.jpg", size: 1400, mime: "image/jpeg" },
    ],
  };
  const sealedModern = await encryptPayload(senderIdentity, recipientPublic, modern);
  assert.deepEqual(await decryptPayload(recipientIdentity, senderPublic, sealedModern.nonce, sealedModern.ciphertext), modern);

  const legacy = {
    type: "request", text: "Read this photo", taskID: "legacy-1", createdAt: new Date(0).toISOString(),
    artifactName: "receipt.jpg", artifactSize: 1200, artifactMime: "image/jpeg",
    attachmentID: "legacy-transfer", attachmentNonce: "legacy-nonce",
  };
  const sealedLegacy = await encryptPayload(senderIdentity, recipientPublic, legacy);
  assert.deepEqual(await decryptPayload(recipientIdentity, senderPublic, sealedLegacy.nonce, sealedLegacy.ciphertext), legacy);
});
