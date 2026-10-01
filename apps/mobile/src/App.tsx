import { useCallback, useEffect, useRef, useState } from "react";
import {
  acknowledgeTransfer,
  clearIdentity,
  consumeSharedInput,
  deleteQueuedRequest,
  downloadEncryptedFile,
  decryptPayload,
  encryptPayload,
  errorText,
  invitationFromLocation,
  loadHistory,
  loadIdentity,
  loadQueuedRequests,
  pairPhone,
  randomID,
  saveHistory,
  saveQueuedRequest,
  uploadEncryptedFile,
  MAX_FILE_BYTES,
  type EnvelopePayload,
  type QueuedRequest,
  type PhoneIdentity,
} from "./crypto";

type AgentName = "kio" | "pip" | "pixel" | "zip" | "echo" | "clerk" | "courier" | "scribe" | "table" | "lens" | "scout" | "patch";
interface HistoryAttachment { name: string; size: number; mime: string; blob: Blob }
interface HistoryItem { id: string; taskID?: string; role: "user" | "kio" | "agent" | "status"; text: string; speaker?: string; agent?: AgentName; name?: string; size?: number; mime?: string; attachmentBlob?: Blob; attachments?: HistoryAttachment[]; createdAt: string }
interface RelayEnvelope { id: string; senderID: string; nonce: string; ciphertext: string; createdAt: string }
interface DeviceStatus { macOnline: boolean; macLastSeen: string | null }

function apiURL(base: string, path: string): URL {
  return new URL(`/api${path}`, base);
}

function prettySize(size?: number): string {
  if (!size) return "";
  if (size < 1024) return `${size} B`;
  if (size < 1024 * 1024) return `${(size / 1024).toFixed(0)} KB`;
  return `${(size / 1024 / 1024).toFixed(1)} MB`;
}

async function showKioNotification(body: string, taskID?: string) {
  if (!("Notification" in window) || Notification.permission !== "granted") return;
  const options: NotificationOptions = { body, icon: "/kio-192.png", badge: "/kio-192.png", ...(taskID ? { tag: `kio-${taskID}` } : {}) };
  if ("serviceWorker" in navigator) {
    const registration = await navigator.serviceWorker.ready;
    await registration.showNotification("Kio", options);
  } else {
    new Notification("Kio", options);
  }
}

export default function App() {
  const [identity, setIdentity] = useState<PhoneIdentity>();
  const [messages, setMessages] = useState<HistoryItem[]>([]);
  const [downloadURLs, setDownloadURLs] = useState<Record<string, string>>({});
  const [status, setStatus] = useState<DeviceStatus>({ macOnline: false, macLastSeen: null });
  const [request, setRequest] = useState("");
  const [files, setFiles] = useState<File[]>([]);
  const [queuedTaskIDs, setQueuedTaskIDs] = useState<string[]>([]);
  const [pairing, setPairing] = useState(Boolean(invitationFromLocation()));
  const [deviceName, setDeviceName] = useState("My iPhone");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [showDeviceMenu, setShowDeviceMenu] = useState(false);
  const listRef = useRef<HTMLDivElement>(null);
  const flushingOutbox = useRef(false);

  useEffect(() => {
    void Promise.all([loadIdentity(), loadHistory<HistoryItem>(), consumeSharedInput(), loadQueuedRequests()]).then(([savedIdentity, savedMessages, shared, queued]) => {
      setIdentity(savedIdentity);
      setMessages(savedMessages.sort((a, b) => a.createdAt.localeCompare(b.createdAt)));
      setQueuedTaskIDs(queued.map((item) => item.taskID));
      if (shared) {
        setRequest(shared.text);
        if (shared.files.length <= 8 && shared.files.every((file) => file.size > 0 && file.size <= MAX_FILE_BYTES)
            && shared.files.reduce((sum, file) => sum + file.size, 0) <= 150 * 1024 * 1024) setFiles(shared.files);
        else setError("The shared files exceed Kio's phone attachment limits.");
      }
      if (!savedIdentity && !invitationFromLocation()) setPairing(false);
    }).catch(() => setError("I couldn't open this device's saved Kio session."));
  }, []);

  const append = useCallback((item: HistoryItem) => {
    setMessages((current) => current.some((entry) => entry.id === item.id) ? current : [...current, item]);
    void saveHistory(item);
  }, []);

  const deliverQueued = useCallback(async (item: QueuedRequest, selectedIdentity: PhoneIdentity) => {
    const deviceResponse = await fetch(apiURL(selectedIdentity.relayURL, "/devices"), { headers: { authorization: `Bearer ${selectedIdentity.authToken}` } });
    if (!deviceResponse.ok) throw new Error(await errorText(deviceResponse));
    const deviceData = await deviceResponse.json() as { devices: Array<{ id: string; publicKey: string }> };
    const mac = deviceData.devices.find((device) => device.id === selectedIdentity.macDeviceID);
    if (!mac) throw new Error("The paired Mac is no longer available. Pair this phone again from Kio Settings.");
    const transfers = [...item.transfers];
    for (let index = transfers.length; index < item.files.length; index += 1) {
      const chosenFile = item.files[index];
      const transfer = await uploadEncryptedFile(selectedIdentity, selectedIdentity.macDeviceID, mac.publicKey, chosenFile);
      transfers.push({ transferID: transfer.id, nonce: transfer.nonce, name: chosenFile.name, size: chosenFile.size, mime: chosenFile.type || "application/octet-stream" });
      await saveQueuedRequest({ ...item, transfers });
    }
    const legacy = item.files.length === 1 ? transfers[0] : undefined;
    const payload: EnvelopePayload = {
      type: "request", text: item.text, taskID: item.taskID, createdAt: item.createdAt,
      ...(transfers.length ? { attachments: transfers } : {}),
      ...(legacy ? { artifactName: legacy.name, artifactMime: legacy.mime, artifactSize: legacy.size, attachmentID: legacy.transferID, attachmentNonce: legacy.nonce } : {}),
    };
    const sealed = await encryptPayload(selectedIdentity, mac.publicKey, payload);
    const response = await fetch(apiURL(selectedIdentity.relayURL, "/messages"), {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${selectedIdentity.authToken}` },
      body: JSON.stringify({ recipientID: selectedIdentity.macDeviceID, ...sealed }),
    });
    if (!response.ok) throw new Error(await errorText(response));
    await deleteQueuedRequest(item.taskID);
    setQueuedTaskIDs((current) => current.filter((id) => id !== item.taskID));
    const macStatusResponse = await fetch(apiURL(selectedIdentity.relayURL, "/status"), { headers: { authorization: `Bearer ${selectedIdentity.authToken}` } });
    const macStatus = macStatusResponse.ok ? await macStatusResponse.json() as DeviceStatus : undefined;
    if (macStatus && !macStatus.macOnline) append({ id: randomID(), role: "status", text: "Mac offline · the relay accepted this queued task for Kio to start when it reconnects.", createdAt: new Date().toISOString() });
  }, [append]);

  const flushQueued = useCallback(async (selectedIdentity: PhoneIdentity) => {
    if (flushingOutbox.current) return;
    flushingOutbox.current = true;
    try {
      const queued = await loadQueuedRequests();
      setQueuedTaskIDs(queued.map((item) => item.taskID));
      for (const item of queued) {
        try { await deliverQueued(item, selectedIdentity); }
        catch { break; }
      }
    } finally { flushingOutbox.current = false; }
  }, [deliverQueued]);

  useEffect(() => {
    listRef.current?.scrollTo({ top: listRef.current.scrollHeight, behavior: "smooth" });
  }, [messages]);

  useEffect(() => {
    const urls: Record<string, string> = {};
    for (const message of messages) {
      if (message.attachmentBlob) urls[message.id] = URL.createObjectURL(message.attachmentBlob);
      message.attachments?.forEach((file, index) => { urls[`${message.id}:${index}`] = URL.createObjectURL(file.blob); });
    }
    setDownloadURLs(urls);
    return () => Object.values(urls).forEach(URL.revokeObjectURL);
  }, [messages]);

  useEffect(() => {
    if (!identity) return;
    let stopped = false;
    let controller: AbortController | undefined;
    const poll = async () => {
      while (!stopped) {
        controller = new AbortController();
        try {
          const [statusResponse, inboxResponse] = await Promise.all([
            fetch(apiURL(identity.relayURL, "/status"), { headers: { authorization: `Bearer ${identity.authToken}` }, signal: controller.signal }),
            fetch(apiURL(identity.relayURL, "/inbox?wait=18"), { headers: { authorization: `Bearer ${identity.authToken}` }, signal: controller.signal }),
          ]);
          if (statusResponse.ok) setStatus(await statusResponse.json() as DeviceStatus);
          await flushQueued(identity);
          if (!inboxResponse.ok) throw new Error(await errorText(inboxResponse));
          const data = await inboxResponse.json() as { messages: RelayEnvelope[] };
          for (const envelope of data.messages) {
            try {
              if (envelope.senderID !== identity.macDeviceID) throw new Error("Unexpected sender");
              const payload = await decryptPayload<EnvelopePayload>(identity, identity.macPublicKey, envelope.nonce, envelope.ciphertext);
              const incomingFiles = payload.attachments ?? (payload.attachmentID && payload.attachmentNonce && payload.artifactName
                ? [{ transferID: payload.attachmentID, nonce: payload.attachmentNonce, name: payload.artifactName,
                    size: payload.artifactSize ?? 0, mime: payload.artifactMime || "application/octet-stream" }]
                : []);
              if (incomingFiles.length > 8 || incomingFiles.reduce((sum, file) => sum + file.size, 0) > 150 * 1024 * 1024) throw new Error("The result exceeded Kio's phone transfer limit");
              const resultFiles: HistoryAttachment[] = [];
              for (const file of incomingFiles) {
                const bytes = await downloadEncryptedFile(identity, identity.macPublicKey, file.transferID, file.nonce);
                if (file.size !== bytes.byteLength) throw new Error("Transfer size did not verify");
                resultFiles.push({ name: file.name, size: file.size, mime: file.mime, blob: new Blob([bytes], { type: file.mime }) });
                await acknowledgeTransfer(identity, file.transferID);
              }
              const knownAgents: AgentName[] = ["kio", "pip", "pixel", "zip", "echo", "clerk", "courier", "scribe", "table", "lens", "scout", "patch"];
              const agent = knownAgents.includes(payload.agent as AgentName) ? payload.agent as AgentName : undefined;
              const item: HistoryItem = {
                id: envelope.id,
                role: agent && agent !== "kio" ? "agent" : payload.type === "progress" && !payload.speaker ? "status" : "kio",
                speaker: payload.speaker || (agent ? agent[0].toUpperCase() + agent.slice(1) : undefined),
                agent,
                text: payload.text,
                name: resultFiles.length ? resultFiles.map((file) => file.name).join(", ") : payload.artifactName,
                size: resultFiles.length ? resultFiles.reduce((sum, file) => sum + file.size, 0) : payload.artifactSize,
                mime: resultFiles[0]?.mime ?? payload.artifactMime,
                attachmentBlob: resultFiles.length === 1 ? resultFiles[0].blob : undefined,
                attachments: resultFiles.length > 1 ? resultFiles : undefined,
                createdAt: payload.createdAt ?? envelope.createdAt,
              };
              append(item);
              if ((payload.type === "result" || payload.type === "error") && document.hidden && Notification.permission === "granted") {
                try {
                  await showKioNotification(payload.type === "result" ? "Your Mac finished a Kio request." : "Kio needs your attention.", payload.taskID);
                } catch {
                  // Keep delivery flowing if the browser closes notification access while Kio is running.
                }
              }
            } catch {
              append({ id: randomID(), role: "status", text: "A message arrived but couldn't be verified. It was discarded.", createdAt: new Date().toISOString() });
            }
            await fetch(apiURL(identity.relayURL, `/messages/${encodeURIComponent(envelope.id)}/ack`), {
              method: "POST", headers: { authorization: `Bearer ${identity.authToken}` },
            });
          }
          setError("");
        } catch (caught) {
          if (!stopped && !(caught instanceof DOMException && caught.name === "AbortError")) {
            setError(caught instanceof Error ? caught.message : "The relay is unavailable. Your saved messages are still here.");
            setStatus({ macOnline: false, macLastSeen: null });
            await new Promise((resolve) => window.setTimeout(resolve, 2500));
          }
        }
      }
    };
    void poll();
    return () => { stopped = true; controller?.abort(); };
  }, [identity, append, flushQueued]);

  const addFiles = (selected?: FileList | File[]) => {
    setError("");
    if (!selected) return;
    const incoming = Array.from(selected);
    if (files.length + incoming.length > 8) { setError("Attach up to 8 files per request."); return; }
    if (incoming.some((entry) => entry.size <= 0 || entry.size > MAX_FILE_BYTES)) {
      setError("Each phone attachment must be between 1 byte and 50 MB.");
      return;
    }
    const combined = [...files, ...incoming];
    if (combined.reduce((sum, entry) => sum + entry.size, 0) > 150 * 1024 * 1024) {
      setError("Attachments in one request must total no more than 150 MB.");
      return;
    }
    setFiles(combined);
  };

  const send = async () => {
    if (!identity || busy || (!request.trim() && files.length === 0)) return;
    setBusy(true);
    setError("");
    const text = request.trim() || (files.length ? `Use the attached file${files.length === 1 ? "" : "s"}: ${files.map((entry) => entry.name).join(", ")}` : "");
    const createdAt = new Date().toISOString();
    const taskID = randomID();
    const chosenFiles = files;
    const queued: QueuedRequest = { taskID, text, createdAt, files: chosenFiles, transfers: [] };
    append({ id: taskID, taskID, role: "user", text, name: chosenFiles.map((entry) => entry.name).join(", ") || undefined, size: chosenFiles.reduce((sum, entry) => sum + entry.size, 0), createdAt });
    setRequest("");
    setFiles([]);
    try {
      await saveQueuedRequest(queued);
      setQueuedTaskIDs((current) => [...new Set([...current, taskID])]);
      await deliverQueued(queued, identity);
    } catch (caught) {
      setError(`Saved on this phone. Kio will retry when the relay is available. ${caught instanceof Error ? caught.message : "Couldn't send that message."}`);
    } finally {
      setBusy(false);
    }
  };

  const retryQueued = async (taskID: string) => {
    if (!identity || busy) return;
    setBusy(true);
    setError("");
    try {
      const queued = (await loadQueuedRequests()).find((item) => item.taskID === taskID);
      if (!queued) { setQueuedTaskIDs((current) => current.filter((id) => id !== taskID)); return; }
      await deliverQueued(queued, identity);
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "The queued request is still waiting for a connection.");
    } finally { setBusy(false); }
  };

  const completePairing = async () => {
    const invitation = invitationFromLocation();
    if (!invitation) { setError("That pairing link is missing or expired. Create a fresh QR code in Kio Settings."); return; }
    setBusy(true);
    setError("");
    try {
      const paired = await pairPhone(invitation, deviceName);
      setIdentity(paired);
      setPairing(false);
      append({ id: randomID(), role: "status", text: "This phone is paired with your Mac. Messages and files are encrypted before they leave this device.", createdAt: new Date().toISOString() });
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Pairing failed. Ask your Mac for a fresh QR code.");
    } finally { setBusy(false); }
  };

  const unpair = async () => {
    if (!identity || !window.confirm("Unpair this phone from Kio?")) return;
    try {
      const response = await fetch(apiURL(identity.relayURL, `/devices/${encodeURIComponent(identity.deviceID)}`), {
        method: "DELETE", headers: { authorization: `Bearer ${identity.authToken}` },
      });
      if (!response.ok) throw new Error(await errorText(response));
    } catch (caught) { setError(caught instanceof Error ? caught.message : "The phone could not be revoked right now."); return; }
    await clearIdentity();
    setIdentity(undefined);
    setMessages([]);
    setPairing(false);
  };

  if (!identity || pairing) return <main className="pair-screen">
    <div className="mark"><span>K</span></div>
    <p className="eyebrow">Kio for your phone</p>
    <h1>{invitationFromLocation() ? "Take Kio with you." : "Your Mac, in your pocket."}</h1>
    <p className="lede">Scan the one-time code shown in Kio on your Mac to pair this device. Your Mac stays in control of every task.{invitationFromLocation() ? ` This code connects to ${new URL(invitationFromLocation()!.relayURL).host}.` : ""}</p>
    <label className="field-label" htmlFor="device-name">Device name</label>
    <input id="device-name" className="device-input" value={deviceName} onChange={(event) => setDeviceName(event.target.value)} maxLength={48} />
    <button className="primary pair-button" onClick={() => void completePairing()} disabled={busy || !invitationFromLocation()}>{busy ? "Pairing…" : "Pair with my Mac"}</button>
    {!invitationFromLocation() && <p className="helper">Open Kio on your Mac → Settings → Pair phone, then scan its QR code with your camera.</p>}
    {error && <p className="error" role="alert">{error}</p>}
    <p className="privacy-note">No Kio account. The relay carries encrypted messages and cannot read them.</p>
  </main>;

  return <main className="app-shell">
    <header className="topbar">
      <div className="brand"><AgentFace agent="kio" size={38} /><div><strong>Kio</strong><span>Your Mac companion</span></div></div>
      <div className={`connection ${status.macOnline ? "online" : "offline"}`}><i />{status.macOnline ? "Mac online" : "Mac offline"}</div>
      <div className="device-menu-wrap">
        <button className="more" aria-label="Paired device settings" aria-expanded={showDeviceMenu} onClick={() => setShowDeviceMenu((open) => !open)}>···</button>
        {showDeviceMenu && <div className="device-menu">
          {"Notification" in window && <button onClick={() => {
            void Notification.requestPermission().then((permission) => {
              setError(permission === "granted" ? "" : "Allow notifications in your browser settings to receive Kio completion alerts.");
            });
            setShowDeviceMenu(false);
          }}>{Notification.permission === "granted" ? "Completion notifications enabled" : "Enable completion notifications"}</button>}
          <button className="danger-action" onClick={() => { setShowDeviceMenu(false); void unpair(); }}>Unpair this device</button>
        </div>}
      </div>
    </header>
    <div className="crew"><span>YOUR CREW</span><div className="crew-row">{(["scribe", "table", "lens", "scout", "patch", "pip", "pixel", "zip", "echo", "clerk", "courier"] as AgentName[]).map((agent) => <AgentFace key={agent} agent={agent} size={23} />)}<small>Scribe · Table · Lens · Scout · Patch · Pip · Pixel · Zip · Echo · Clerk · Courier</small></div></div>
    <section className="conversation" ref={listRef} aria-live="polite">
      {messages.length === 0 && <div className="welcome"><AgentFace agent="kio" size={52} /><h2>What can I help with?</h2><p>Send a request and your Mac will take it from here.</p></div>}
      {messages.map((message) => <article key={message.id} className={`message ${message.role} agent-${message.agent ?? "kio"}`}>
        {(message.role === "kio" || message.role === "agent") && <div className="message-speaker"><AgentFace agent={message.agent ?? "kio"} size={22} /><span className="speaker">{message.speaker ?? "Kio"}</span></div>}
        <div className="bubble">{message.text}{message.name && <div className="file-pill"><span>▧</span><span>{message.name}<small>{prettySize(message.size)}</small></span></div>}{downloadURLs[message.id] && message.name && <a className="download-result" download={message.name} href={downloadURLs[message.id]}>Download to this phone ↓</a>}{message.attachments?.map((file, index) => <a key={`${message.id}-${file.name}`} className="download-result" download={file.name} href={downloadURLs[`${message.id}:${index}`]}>Download {file.name} to this phone ↓</a>)}{message.taskID && queuedTaskIDs.includes(message.taskID) && <div className="queued-request"><small>Saved on this phone · waiting to send</small><button disabled={busy} onClick={() => void retryQueued(message.taskID!)}>Retry now</button></div>}</div>
        <time>{new Date(message.createdAt).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })}</time>
      </article>)}
      {error && <p className="error inline-error" role="alert">{error}</p>}
    </section>
    <footer className="composer-area">
      <p className={`offline-note ${status.macOnline ? "hidden" : ""}`}><span>◌</span> Mac offline. Your task will start when Kio reconnects.</p>
      {files.length > 0 && <div className="selected-files">{files.map((file, index) => <div className="selected-file" key={`${file.name}-${file.lastModified}-${index}`}>▧ {file.name} <button onClick={() => setFiles((current) => current.filter((_, fileIndex) => fileIndex !== index))} aria-label={`Remove ${file.name}`}>×</button></div>)}</div>}
      {!request.trim() && files.length === 0 && <button className="workflow-shortcut" onClick={() => setRequest("List my saved workflow templates")}>List saved workflows</button>}
      <div className="composer">
        <label className="attach" aria-label="Attach files">＋<input type="file" multiple onChange={(event) => { addFiles(event.target.files ?? undefined); event.target.value = ""; }} /></label>
        <label className="attach camera" aria-label="Take a photo">▧<input type="file" accept="image/*" capture="environment" onChange={(event) => { addFiles(event.target.files ?? undefined); event.target.value = ""; }} /></label>
        <textarea value={request} onChange={(event) => setRequest(event.target.value)} onKeyDown={(event) => { if (event.key === "Enter" && !event.shiftKey) { event.preventDefault(); void send(); } }} placeholder="Message Kio" rows={1} />
        <button className="send" onClick={() => void send()} disabled={busy || (!request.trim() && files.length === 0)} aria-label="Send message">{busy ? "…" : "↑"}</button>
      </div>
      <p className="composer-foot">Encrypted between this phone and your Mac</p>
      {!window.matchMedia("(display-mode: standalone)").matches && <p className="install-hint">In Safari: <strong>Share → Add to Home Screen</strong></p>}
    </footer>
  </main>;
}

function AgentFace({ agent, size }: { agent: AgentName; size: number }) {
  return <span className={`agent-face ${agent}`} style={{ width: size, height: size }} aria-label={`${agent} character`}><i /><i /></span>;
}
