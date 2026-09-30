// Hi Teacher: funciona instalado e sem internet (8.3).
// Sempre tenta a internet primeiro (assim cada atualização chega na hora); sem internet, usa a
// última cópia guardada do app e das bibliotecas. Dados (Supabase) nunca passam por aqui.
const CACHE = "hi-teacher-v1";
const CORE = ["./", "./index.html", "./manifest.json", "./icon-192.png", "./icon-512.png"];
self.addEventListener("install", e => {
  self.skipWaiting();
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(CORE)).catch(() => {}));
});
self.addEventListener("activate", e => {
  e.waitUntil(caches.keys().then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener("fetch", e => {
  const req = e.request;
  if (req.method !== "GET") return;
  const url = new URL(req.url);
  const own = url.origin === self.location.origin;
  const lib = /(^|\.)cdn\.jsdelivr\.net$/.test(url.hostname) && /supabase-js|jszip/.test(url.pathname) || url.hostname === "cdn.sheetjs.com";
  if (!own && !lib) return;
  e.respondWith(
    fetch(req).then(res => {
      if (res && (res.ok || res.type === "opaque")) { const copy = res.clone(); caches.open(CACHE).then(c => c.put(req, copy)).catch(() => {}); }
      return res;
    }).catch(() => caches.match(req, { ignoreSearch: own }).then(hit => hit || (req.mode === "navigate" ? caches.match("./index.html") : Response.error())))
  );
});
