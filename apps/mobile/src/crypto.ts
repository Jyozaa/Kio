export interface PairingInvitation {
  version: 1;
  relayURL: string;
  workspaceID: string;
  macDeviceID: string;
  pairingID: string;
  oneTimeToken: string;
  macPublicKey: string;
}

export interface PhoneIdentity {
  version: 1;
  workspaceID: string;
  deviceID: string;
  deviceName: string;
  authToken: string;
  macDeviceID: string;
  macPublicKey: string;
  privateKey: CryptoKey;
  relayURL: string;
}

export interface EnvelopePayload {
  type: "request" | "message" | "progress" | "result" | "error";
  text: string;
  artifactName?: string;
  artifactSize?: number;
  artifactMime?: string;
  attachmentID?: string;
  attachmentNonce?: string;
  taskID?: string;
  createdAt: string;
}

const database = "kio-mobile";
const identityStore = "identity";
const historyStore = "history";
export const MAX_FILE_BYTES = 50 * 1024 * 1024;

function openDatabase(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(database, 1);
    request.onupgradeneeded = () => {
      const db = request.result;
      db.createObjectStore(identityStore);
      db.createObjectStore(historyStore, { keyPath: "id" });
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

async function storeValue<T>(storeName: string, key: IDBValidKey, value: T): Promise<void> {
  const db = await openDatabase();
  await new Promise<void>((resolve, reject) => {
    const transaction = db.transaction(storeName, "readwrite");
    if (storeName === historyStore) transaction.objectStore(storeName).put(value);
    else transaction.objectStore(storeName).put(value, key);
    transaction.oncomplete = () => resolve();
    transaction.onerror = () => reject(transaction.error);
  });
  db.close();
}

async function readValue<T>(storeName: string, key: IDBValidKey): Promise<T | undefined> {
  const db = await openDatabase();
  const result = await new Promise<T | undefined>((resolve, reject) => {
    const request = db.transaction(storeName).objectStore(storeName).get(key);
    request.onsuccess = () => resolve(request.result as T | undefined);
    request.onerror = () => reject(request.error);
  });
  db.close();
  return result;
}

export async function loadIdentity(): Promise<PhoneIdentity | undefined> {
  return readValue(identityStore, "current");
}

export async function clearIdentity(): Promise<void> {
  const db = await openDatabase();
  await new Promise<void>((resolve, reject) => {
    const transaction = db.transaction([identityStore, historyStore], "readwrite");
    transaction.objectStore(identityStore).clear();
    transaction.objectStore(historyStore).clear();
    transaction.oncomplete = () => resolve();
    transaction.onerror = () => reject(transaction.error);
  });
  db.close();
}

export async function saveHistory<T extends { id: string }>(entry: T): Promise<void> {
  return storeValue(historyStore, entry.id, entry);
}

export async function loadHistory<T>(): Promise<T[]> {
  const db = await openDatabase();
  const result = await new Promise<T[]>((resolve, reject) => {
    const request = db.transaction(historyStore).objectStore(historyStore).getAll();
    request.onsuccess = () => resolve(request.result as T[]);
    request.onerror = () => reject(request.error);
  });
  db.close();
  return result;
}

function bytesToBase64(value: ArrayBuffer | Uint8Array): string {
  const bytes = value instanceof Uint8Array ? value : new Uint8Array(value);
  let binary = "";
  for (let start = 0; start < bytes.length; start += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(start, start + 0x8000));
  }
  return btoa(binary);
}

function base64ToBytes(value: string): Uint8Array<ArrayBuffer> {
  let normalized = value.replaceAll("-", "+").replaceAll("_", "/");
  if (normalized.length % 4 !== 0) normalized += "=".repeat(4 - normalized.length % 4);
  const binary = atob(normalized);
  const bytes = new Uint8Array(new ArrayBuffer(binary.length));
  for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);
  return bytes;
}

function randomToken(bytes = 32): string {
  return bytesToBase64(crypto.getRandomValues(new Uint8Array(bytes))).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

export function encodeInvitation(invitation: PairingInvitation): string {
  return bytesToBase64(new TextEncoder().encode(JSON.stringify(invitation))).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

export function invitationURL(invitation: PairingInvitation): string {
  const base = new URL("/", invitation.relayURL);
  base.hash = `pair=${encodeInvitation(invitation)}`;
  return base.toString();
}

export function invitationFromLocation(): PairingInvitation | undefined {
  const token = new URLSearchParams(location.hash.slice(1)).get("pair");
  if (!token) return;
  try {
    const normalized = token.replaceAll("-", "+").replaceAll("_", "/");
    const value = JSON.parse(new TextDecoder().decode(base64ToBytes(normalized))) as PairingInvitation;
    const relayURL = new URL(value.relayURL);
    if (value.version !== 1 || !["https:", "http:"].includes(relayURL.protocol) || !value.pairingID || !value.oneTimeToken || !value.macPublicKey) return;
    return value;
  } catch {
    return;
  }
}

export async function pairPhone(invitation: PairingInvitation, deviceName: string): Promise<PhoneIdentity> {
  const generated = await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, ["deriveBits"]);
  const publicBytes = await crypto.subtle.exportKey("raw", generated.publicKey);
  const privateBytes = await crypto.subtle.exportKey("pkcs8", generated.privateKey);
  const privateKey = await crypto.subtle.importKey("pkcs8", privateBytes, { name: "ECDH", namedCurve: "P-256" }, false, ["deriveBits"]);
  const deviceID = randomToken(16);
  const authToken = randomToken(32);
  const response = await fetch(new URL("/api/pairings/complete", invitation.relayURL), {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      pairingID: invitation.pairingID,
      oneTimeToken: invitation.oneTimeToken,
      deviceID,
      deviceName: deviceName.trim().slice(0, 48) || "My iPhone",
      publicKey: bytesToBase64(publicBytes),
      authToken,
    }),
  });
  if (!response.ok) throw new Error(await errorText(response));
  const result = await response.json() as { workspaceID: string; macDeviceID: string };
  if (result.workspaceID !== invitation.workspaceID || result.macDeviceID !== invitation.macDeviceID) throw new Error("That pairing code doesn't match the Mac that created it.");
  const identity: PhoneIdentity = {
    version: 1,
    workspaceID: result.workspaceID,
    deviceID,
    deviceName: deviceName.trim().slice(0, 48) || "My iPhone",
    authToken,
    macDeviceID: result.macDeviceID,
    macPublicKey: invitation.macPublicKey,
    privateKey,
    relayURL: invitation.relayURL,
  };
  await storeValue(identityStore, "current", identity);
  history.replaceState(null, "", location.pathname);
  return identity;
}

export async function encryptPayload(identity: PhoneIdentity, recipientPublicKey: string, payload: EnvelopePayload): Promise<{ nonce: string; ciphertext: string }> {
  const key = await deriveAESKey(identity, recipientPublicKey, ["encrypt"]);
  const nonce = crypto.getRandomValues(new Uint8Array(12));
  const ciphertext = await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce }, key, new TextEncoder().encode(JSON.stringify(payload)));
  return { nonce: bytesToBase64(nonce), ciphertext: bytesToBase64(ciphertext) };
}

export async function decryptPayload<T>(identity: PhoneIdentity, senderPublicKey: string, nonce: string, ciphertext: string): Promise<T> {
  const key = await deriveAESKey(identity, senderPublicKey, ["decrypt"]);
  const clear = await crypto.subtle.decrypt({ name: "AES-GCM", iv: base64ToBytes(nonce) }, key, base64ToBytes(ciphertext));
  return JSON.parse(new TextDecoder().decode(clear)) as T;
}

async function deriveAESKey(identity: PhoneIdentity, peerPublicKey: string, usages: KeyUsage[]): Promise<CryptoKey> {
  const publicKey = await crypto.subtle.importKey("raw", base64ToBytes(peerPublicKey), { name: "ECDH", namedCurve: "P-256" }, false, []);
  const shared = await crypto.subtle.deriveBits({ name: "ECDH", public: publicKey }, identity.privateKey, 256);
  const material = await crypto.subtle.importKey("raw", shared, "HKDF", false, ["deriveKey"]);
  return crypto.subtle.deriveKey(
    { name: "HKDF", hash: "SHA-256", salt: new TextEncoder().encode(identity.workspaceID), info: new TextEncoder().encode("Kio relay envelope v1") },
    material,
    { name: "AES-GCM", length: 256 },
    false,
    usages,
  );
}

export async function uploadEncryptedFile(identity: PhoneIdentity, recipientID: string, recipientPublicKey: string, file: File): Promise<{ id: string; nonce: string }> {
  if (file.size <= 0 || file.size > MAX_FILE_BYTES) throw new Error("Choose a file smaller than 50 MB.");
  const key = await deriveAESKey(identity, recipientPublicKey, ["encrypt"]);
  const nonce = crypto.getRandomValues(new Uint8Array(12));
  const ciphertext = await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce }, key, await file.arrayBuffer());
  const response = await fetch(new URL(`/api/files?recipientID=${encodeURIComponent(recipientID)}`, identity.relayURL), {
    method: "POST",
    headers: { authorization: `Bearer ${identity.authToken}`, "content-type": "application/octet-stream", "x-kio-file-size": String(file.size) },
    body: ciphertext,
  });
  if (!response.ok) throw new Error(await errorText(response));
  const transfer = await response.json() as { id: string };
  return { id: transfer.id, nonce: bytesToBase64(nonce) };
}

export async function downloadEncryptedFile(identity: PhoneIdentity, senderPublicKey: string, transferID: string, nonce: string): Promise<ArrayBuffer> {
  const response = await fetch(new URL(`/api/files/${encodeURIComponent(transferID)}`, identity.relayURL), {
    headers: { authorization: `Bearer ${identity.authToken}` },
  });
  if (!response.ok) throw new Error(await errorText(response));
  const encrypted = await response.arrayBuffer();
  if (encrypted.byteLength > MAX_FILE_BYTES + 16) throw new Error("That encrypted file is larger than Kio allows.");
  const key = await deriveAESKey(identity, senderPublicKey, ["decrypt"]);
  return crypto.subtle.decrypt({ name: "AES-GCM", iv: base64ToBytes(nonce) }, key, encrypted);
}

export async function acknowledgeTransfer(identity: PhoneIdentity, transferID: string): Promise<void> {
  await fetch(new URL(`/api/files/${encodeURIComponent(transferID)}/ack`, identity.relayURL), {
    method: "POST", headers: { authorization: `Bearer ${identity.authToken}` },
  });
}

export function bytesToBase64ForAPI(bytes: Uint8Array): string { return bytesToBase64(bytes); }
export function randomID(): string { return randomToken(16); }

export async function errorText(response: Response): Promise<string> {
  try { return ((await response.json()) as { error?: string }).error ?? `Relay error (${response.status})`; }
  catch { return `Relay error (${response.status})`; }
}
