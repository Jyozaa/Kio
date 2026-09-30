import { useCallback, useEffect, useRef, useState } from "react";
import {
  acknowledgeTransfer,
  clearIdentity,
  downloadEncryptedFile,
  decryptPayload,
  encryptPayload,
  errorText,
  invitationFromLocation,
  loadHistory,
  loadIdentity,
  pairPhone,
  randomID,
  saveHistory,
  uploadEncryptedFile,
  MAX_FILE_BYTES,
  type EnvelopePayload,
  type PhoneIdentity,
} from "./crypto";

type AgentName = "kio" | "pip" | "pixel" | "zip" | "echo" | "clerk" | "courier";
interface HistoryItem { id: string; role: "user" | "kio" | "agent" | "status"; text: string; speaker?: string; agent?: AgentName; name?: string; size?: number; mime?: string; attachmentBlob?: Blob; createdAt: string }
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

export default function App() {
  const [identity, setIdentity] = useState<PhoneIdentity>();
  const [messages, setMessages] = useState<HistoryItem[]>([]);
  const [downloadURLs, setDownloadURLs] = useState<Record<string, string>>({});
  const [status, setStatus] = useState<DeviceStatus>({ macOnline: false, macLastSeen: null });
  const [request, setRequest] = useState("");
  const [file, setFile] = useState<File>();
  const [pairing, setPairing] = useState(Boolean(invitationFromLocation()));
  const [deviceName, setDeviceName] = useState("My iPhone");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [showDeviceMenu, setShowDeviceMenu] = useState(false);
  const listRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    void Promise.all([loadIdentity(), loadHistory<HistoryItem>()]).then(([savedIdentity, savedMessages]) => {
      setIdentity(savedIdentity);
      setMessages(savedMessages.sort((a, b) => a.createdAt.localeCompare(b.createdAt)));
      if (!savedIdentity && !invitationFromLocation()) setPairing(false);
    }).catch(() => setError("I couldn't open this device's saved Kio session."));
  }, []);

  const append = useCallback((item: HistoryItem) => {
    setMessages((current) => current.some((entry) => entry.id === item.id) ? current : [...current, item]);
    void saveHistory(item);
  }, []);

  useEffect(() => {
    listRef.current?.scrollTo({ top: listRef.current.scrollHeight, behavior: "smooth" });
  }, [messages]);

  useEffect(() => {
    const urls: Record<string, string> = {};
    for (const message of messages) if (message.attachmentBlob) urls[message.id] = URL.createObjectURL(message.attachmentBlob);
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
          if (!inboxResponse.ok) throw new Error(await errorText(inboxResponse));
          const data = await inboxResponse.json() as { messages: RelayEnvelope[] };
          for (const envelope of data.messages) {
            try {
              if (envelope.senderID !== identity.macDeviceID) throw new Error("Unexpected sender");
              const payload = await decryptPayload<EnvelopePayload>(identity, identity.macPublicKey, envelope.nonce, envelope.ciphertext);
              let attachmentBlob: Blob | undefined;
              if (payload.attachmentID && payload.attachmentNonce) {
                const bytes = await downloadEncryptedFile(identity, identity.macPublicKey, payload.attachmentID, payload.attachmentNonce);
                if (payload.artifactSize !== bytes.byteLength) throw new Error("Transfer size did not verify");
                attachmentBlob = new Blob([bytes], { type: payload.artifactMime || "application/octet-stream" });
                await acknowledgeTransfer(identity, payload.attachmentID);
              }
              const knownAgents: AgentName[] = ["kio", "pip", "pixel", "zip", "echo", "clerk", "courier"];
              const agent = knownAgents.includes(payload.agent as AgentName) ? payload.agent as AgentName : undefined;
              const item: HistoryItem = {
                id: envelope.id,
                role: agent && agent !== "kio" ? "agent" : payload.type === "progress" && !payload.speaker ? "status" : "kio",
                speaker: payload.speaker || (agent ? agent[0].toUpperCase() + agent.slice(1) : undefined),
                agent,
                text: payload.text,
                name: payload.artifactName,
                size: payload.artifactSize,
                mime: payload.artifactMime,
                attachmentBlob,
                createdAt: payload.createdAt ?? envelope.createdAt,
              };
              append(item);
              if ((payload.type === "result" || payload.type === "error") && document.hidden && Notification.permission === "granted") {
                new Notification("Kio", { body: payload.type === "result" ? "Your Mac finished a Kio request." : "Kio needs your attention." });
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
  }, [identity, append]);

  const addFile = (selected?: File) => {
    setError("");
    if (selected && selected.size > MAX_FILE_BYTES) {
      setError("Choose a file smaller than 50 MB for secure phone transfer.");
      return;
    }
    setFile(selected);
  };

  const send = async () => {
    if (!identity || busy || (!request.trim() && !file)) return;
    setBusy(true);
    setError("");
    const text = request.trim() || (file ? `Use the attached file: ${file.name}` : "");
    const createdAt = new Date().toISOString();
    const taskID = randomID();
    append({ id: taskID, role: "user", text, name: file?.name, size: file?.size, createdAt });
    setRequest("");
    const chosenFile = file;
    setFile(undefined);
    try {
      const deviceResponse = await fetch(apiURL(identity.relayURL, "/devices"), { headers: { authorization: `Bearer ${identity.authToken}` } });
      if (!deviceResponse.ok) throw new Error(await errorText(deviceResponse));
      const deviceData = await deviceResponse.json() as { devices: Array<{ id: string; publicKey: string }> };
      const mac = deviceData.devices.find((device) => device.id === identity.macDeviceID);
      if (!mac) throw new Error("The paired Mac is no longer available. Pair this phone again from Kio Settings.");
      const transfer = chosenFile ? await uploadEncryptedFile(identity, identity.macDeviceID, mac.publicKey, chosenFile) : undefined;
      const payload: EnvelopePayload = {
        type: "request", text, taskID, createdAt,
        ...(chosenFile && transfer ? { artifactName: chosenFile.name, artifactMime: chosenFile.type || "application/octet-stream", artifactSize: chosenFile.size, attachmentID: transfer.id, attachmentNonce: transfer.nonce } : {}),
      };
      const sealed = await encryptPayload(identity, mac.publicKey, payload);
      const response = await fetch(apiURL(identity.relayURL, "/messages"), {
        method: "POST",
        headers: { "content-type": "application/json", authorization: `Bearer ${identity.authToken}` },
        body: JSON.stringify({ recipientID: identity.macDeviceID, ...sealed }),
      });
      if (!response.ok) throw new Error(await errorText(response));
      if (!status.macOnline) append({ id: randomID(), role: "status", text: "Mac offline · this task will start when Kio reconnects.", createdAt: new Date().toISOString() });
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Couldn't queue that message.");
    } finally {
      setBusy(false);
    }
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
          {"Notification" in window && <button onClick={() => { void Notification.requestPermission(); setShowDeviceMenu(false); }}>Enable completion notifications</button>}
          <button className="danger-action" onClick={() => { setShowDeviceMenu(false); void unpair(); }}>Unpair this device</button>
        </div>}
      </div>
    </header>
    <div className="crew"><span>YOUR CREW</span><div className="crew-row">{(["pip", "pixel", "zip", "echo", "clerk", "courier"] as AgentName[]).map((agent) => <AgentFace key={agent} agent={agent} size={23} />)}<small>Pip · Pixel · Zip · Echo · Clerk</small></div></div>
    <section className="conversation" ref={listRef} aria-live="polite">
      {messages.length === 0 && <div className="welcome"><AgentFace agent="kio" size={52} /><h2>What can I help with?</h2><p>Send a request and your Mac will take it from here.</p></div>}
      {messages.map((message) => <article key={message.id} className={`message ${message.role} agent-${message.agent ?? "kio"}`}>
        {(message.role === "kio" || message.role === "agent") && <div className="message-speaker"><AgentFace agent={message.agent ?? "kio"} size={22} /><span className="speaker">{message.speaker ?? "Kio"}</span></div>}
        <div className="bubble">{message.text}{message.name && <div className="file-pill"><span>▧</span><span>{message.name}<small>{prettySize(message.size)}</small></span></div>}{downloadURLs[message.id] && message.name && <a className="download-result" download={message.name} href={downloadURLs[message.id]}>Download to this phone ↓</a>}</div>
        <time>{new Date(message.createdAt).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })}</time>
      </article>)}
      {error && <p className="error inline-error" role="alert">{error}</p>}
    </section>
    <footer className="composer-area">
      <p className={`offline-note ${status.macOnline ? "hidden" : ""}`}><span>◌</span> Mac offline. Your task will start when Kio reconnects.</p>
      {file && <div className="selected-file">▧ {file.name} <button onClick={() => setFile(undefined)} aria-label="Remove attachment">×</button></div>}
      <div className="composer">
        <label className="attach" aria-label="Attach a file">＋<input type="file" onChange={(event) => addFile(event.target.files?.[0])} /></label>
        <textarea value={request} onChange={(event) => setRequest(event.target.value)} onKeyDown={(event) => { if (event.key === "Enter" && !event.shiftKey) { event.preventDefault(); void send(); } }} placeholder="Message Kio" rows={1} />
        <button className="send" onClick={() => void send()} disabled={busy || (!request.trim() && !file)} aria-label="Send message">{busy ? "…" : "↑"}</button>
      </div>
      <p className="composer-foot">Encrypted between this phone and your Mac</p>
      {!window.matchMedia("(display-mode: standalone)").matches && <p className="install-hint">In Safari: <strong>Share → Add to Home Screen</strong></p>}
    </footer>
  </main>;
}

function AgentFace({ agent, size }: { agent: AgentName; size: number }) {
  return <span className={`agent-face ${agent}`} style={{ width: size, height: size }} aria-label={`${agent} character`}><i /><i /></span>;
}
