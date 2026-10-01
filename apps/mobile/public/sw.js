const CACHE = "kio-shell-v2";
const SHELL = ["/", "/manifest.webmanifest", "/kio.svg", "/kio-192.png", "/kio-512.png", "/apple-touch-icon.png"];
function saveSharedInput(value) {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open("kio-mobile", 2);
    request.onupgradeneeded = () => {
      const db = request.result;
      if (!db.objectStoreNames.contains("identity")) db.createObjectStore("identity");
      if (!db.objectStoreNames.contains("history")) db.createObjectStore("history", { keyPath: "id" });
      if (!db.objectStoreNames.contains("shares")) db.createObjectStore("shares");
    };
    request.onerror = () => reject(request.error);
    request.onsuccess = () => {
      const db = request.result;
      const transaction = db.transaction("shares", "readwrite");
      transaction.objectStore("shares").put(value, "pending");
      transaction.oncomplete = () => { db.close(); resolve(); };
      transaction.onerror = () => { db.close(); reject(transaction.error); };
    };
  });
}
self.addEventListener("install", (event) => event.waitUntil(caches.open(CACHE).then((cache) => cache.addAll(SHELL)).then(() => self.skipWaiting())));
self.addEventListener("activate", (event) => event.waitUntil(caches.keys().then((keys) => Promise.all(keys.filter((key) => key.startsWith("kio-shell-") && key !== CACHE).map((key) => caches.delete(key)))).then(() => self.clients.claim())));
self.addEventListener("message", (event) => { if (event.data === "SKIP_WAITING") void self.skipWaiting(); });
self.addEventListener("fetch", (event) => {
  const url = new URL(event.request.url);
  if (event.request.method === "POST" && url.origin === self.location.origin && url.pathname === "/share-target") {
    event.respondWith((async () => {
      try {
        const form = await event.request.formData();
        const files = form.getAll("files").filter((item) => item instanceof File && item.size > 0);
        const text = [form.get("title"), form.get("url"), form.get("text")]
          .filter((item) => typeof item === "string" && item.trim())
          .map((item) => String(item).trim()).join("\n\n").slice(0, 2_000);
        const totalBytes = files.reduce((sum, file) => sum + file.size, 0);
        if (files.length <= 8 && totalBytes <= 150 * 1024 * 1024) {
          await saveSharedInput({ text, files, createdAt: new Date().toISOString() });
        }
      } catch {
        // If local storage is unavailable, return to Kio without retaining shared content.
      }
      return Response.redirect(new URL("/", self.location.origin), 303);
    })());
    return;
  }
  if (event.request.method !== "GET" || url.origin !== self.location.origin || url.pathname.startsWith("/api/")) return;
  event.respondWith(fetch(event.request).then((response) => {
    if (response.ok && (url.pathname === "/" || url.pathname.startsWith("/assets/"))) {
      const copy = response.clone();
      void caches.open(CACHE).then((cache) => cache.put(event.request, copy));
    }
    return response;
  }).catch(async () => (await caches.match(event.request)) ?? (await caches.match("/"))));
});
