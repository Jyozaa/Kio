import assert from "node:assert/strict";
import { createPrivateKey, webcrypto } from "node:crypto";
import { readFile } from "node:fs/promises";

globalThis.crypto ??= webcrypto;
const fixture = JSON.parse(await readFile(new URL("../../../Packages/KioKit/Tests/KioSyncTests/Fixtures/relay-crypto-vector.json", import.meta.url), "utf8"));
const raw = (value) => Buffer.from(value, "base64url");
const publicRaw = (jwk) => Buffer.concat([Buffer.from([4]), raw(jwk.x), raw(jwk.y)]);

function privateJWK(scalar) {
  const der = Buffer.concat([
    Buffer.from("30310201010420", "hex"), raw(scalar),
    Buffer.from("a00a06082a8648ce3d030107", "hex"),
  ]);
  return createPrivateKey({ key: der, format: "der", type: "sec1" }).export({ format: "jwk" });
}

const mac = privateJWK(fixture.macPrivateKey);
const phone = privateJWK(fixture.phonePrivateKey);
const subtle = crypto.subtle;
const phonePrivate = await subtle.importKey("jwk", { ...phone, key_ops: ["deriveBits"], ext: false }, { name: "ECDH", namedCurve: "P-256" }, false, ["deriveBits"]);
const macPublic = await subtle.importKey("raw", publicRaw(mac), { name: "ECDH", namedCurve: "P-256" }, false, []);
const shared = await subtle.deriveBits({ name: "ECDH", public: macPublic }, phonePrivate, 256);
const hkdf = await subtle.importKey("raw", shared, "HKDF", false, ["deriveKey"]);
const aes = await subtle.deriveKey({
  name: "HKDF", hash: "SHA-256", salt: new TextEncoder().encode(fixture.workspaceID), info: new TextEncoder().encode("Kio relay envelope v1"),
}, hkdf, { name: "AES-GCM", length: 256 }, false, ["encrypt", "decrypt"]);
const nonce = raw(fixture.nonce);
const ciphertext = Buffer.from(await subtle.encrypt({ name: "AES-GCM", iv: nonce }, aes, new TextEncoder().encode(fixture.plaintext))).toString("base64url");
const generated = {
  macPublicKey: publicRaw(mac).toString("base64url"),
  phonePublicKey: publicRaw(phone).toString("base64url"),
  ciphertext,
};

if (!fixture.ciphertext) {
  console.log(JSON.stringify(generated, null, 2));
} else {
  assert.deepEqual(generated, { macPublicKey: fixture.macPublicKey, phonePublicKey: fixture.phonePublicKey, ciphertext: fixture.ciphertext });
  const opened = await subtle.decrypt({ name: "AES-GCM", iv: nonce }, aes, raw(fixture.ciphertext));
  assert.equal(new TextDecoder().decode(opened), fixture.plaintext);
  const corrupt = raw(fixture.ciphertext);
  corrupt[0] ^= 1;
  await assert.rejects(subtle.decrypt({ name: "AES-GCM", iv: nonce }, aes, corrupt));
  console.log("WebCrypto interop vector passed against the shared CryptoKit fixture.");
}
