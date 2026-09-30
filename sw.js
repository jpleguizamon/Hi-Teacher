// Hi Teacher: app instalável e sem internet (8.4).
// O index.html registra este arquivo como "sw.js?v=<APP_VERSION>": subir o APP_VERSION cria um
// service worker novo, com cache novo, e o app mostra "Nova versão disponível · Atualizar".
//  - Página (index.html): rede primeiro; sem internet, a última cópia guardada. Nunca cache primeiro.
//  - Arquivos do próprio app (manifesto, ícones): cache primeiro, atualizando por baixo.
//  - Bibliotecas do CDN (supabase-js, SheetJS, JSZip, Tesseract): guardadas na primeira vez que
//    carregam (nada é baixado antes: o Tesseract só entra se o professor usar o OCR).
//  - Nunca passa pelo cache: Supabase (*.supabase.co), métodos diferentes de GET e respostas de erro.
const VERSION = new URL(self.location.href).searchParams.get("v") || "dev";
const CACHE = `hi-teacher-${VERSION}`;
const CORE = ["./", "./index.html", "./manifest.webmanifest", "./icons/icon-192.png", "./icons/icon-512.png", "./icons/icon-maskable-512.png", "./icons/apple-touch-icon.png", "./icons/favicon-32.png"];
const LIB_HOSTS = /(^|\.)(cdn\.jsdelivr\.net|cdn\.sheetjs\.com|unpkg\.com|tessdata\.projectnaptha\.com)$/;

self.addEventListener("install", e => {
  // Guarda o básico pra abrir sem internet. Não chama skipWaiting: a versão nova espera o
  // usuário tocar em "Atualizar" (o professor pode estar digitando).
  e.waitUntil(caches.open(CACHE).then(c => Promise.all(CORE.map(u => fetch(u, { cache: "reload" }).then(r => r.ok ? c.put(u, r) : null).catch(() => null)))));
});
self.addEventListener("activate", e => {
  e.waitUntil(caches.keys().then(keys => Promise.all(keys.filter(k => k.startsWith("hi-teacher") && k !== CACHE).map(k => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener("message", e => { if (e.data && e.data.type === "SKIP_WAITING") self.skipWaiting(); });

function put(req, res){ caches.open(CACHE).then(c => c.put(req, res)).catch(() => {}); }
// Página: rede primeiro. A cópia fica guardada sem os parâmetros da URL (?armazenamento=...,
// links do Supabase), então qualquer endereço do app abre offline; a resposta da rede vai
// sempre para a URL pedida, com os parâmetros e o #access_token intactos.
async function page(req){
  try {
    const res = await fetch(req);
    if (res && res.ok && res.type === "basic") put("./index.html", res.clone());
    return res;
  } catch (err) {
    const hit = (await caches.match("./index.html")) || (await caches.match("./"));
    if (hit) return hit;
    throw err;
  }
}
async function own(req){
  const hit = await caches.match(req, { ignoreSearch: true });
  const net = fetch(req).then(res => { if (res && res.ok) put(req, res.clone()); return res; }).catch(() => null);
  return hit || (await net) || Response.error();
}
async function lib(req){
  const hit = await caches.match(req.url);
  if (hit) return hit;
  // Busca em modo CORS pra poder conferir se deu certo (resposta opaca não diz se é erro).
  try {
    const res = await fetch(new Request(req.url, { mode: "cors", credentials: "omit" }));
    if (res && res.ok) { put(req.url, res.clone()); return res; }
    return res;
  } catch (err) { return fetch(req); }
}
self.addEventListener("fetch", e => {
  const req = e.request;
  if (req.method !== "GET") return;
  let url;
  try { url = new URL(req.url); } catch (x) { return; }
  if (url.protocol !== "https:" && url.protocol !== "http:") return;
  if (/(^|\.)supabase\.co$/.test(url.hostname)) return;   // dados, login, tempo real: sempre direto
  if (url.origin === self.location.origin) {
    if (req.mode === "navigate") { e.respondWith(page(req)); return; }
    if (/\/sw\.js$/.test(url.pathname)) return;
    e.respondWith(own(req));
    return;
  }
  if (LIB_HOSTS.test(url.hostname)) e.respondWith(lib(req));
});
