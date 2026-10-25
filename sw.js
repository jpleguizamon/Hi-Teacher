// Hi Teacher: app instalável e sem internet (8.4).
// O index.html registra este arquivo como "sw.js?v=<APP_VERSION>": subir o APP_VERSION cria um
// service worker novo, com cache novo, e o app mostra "Nova versão disponível · Atualizar".
//  - Página (index.html): rede primeiro; sem internet, a última cópia guardada. Nunca cache primeiro.
//  - Arquivos do próprio app (manifesto, ícones): cache primeiro, atualizando por baixo.
//  - Bibliotecas do CDN (supabase-js, SheetJS, JSZip, Tesseract): guardadas na primeira vez que
//    carregam (nada é baixado antes: o Tesseract só entra se o professor usar o OCR).
//  - Nunca passa pelo cache: Supabase (*.supabase.co), métodos diferentes de GET e respostas de erro.
//  - Notificações (8.14): mostra o que a função send-push mandou e, ao tocar, abre (ou traz pra
//    frente) o app já na página certa (?p=inicio | aulas | avisos | financeiro).
const VERSION = new URL(self.location.href).searchParams.get("v") || "dev";
const SW_REV = "8.48";   // sobe junto com o APP_VERSION quando o próprio service worker muda
const CACHE = `hi-teacher-${SW_REV}-${VERSION}`;
const CORE = ["./", "./index.html", "./privacidade.html", "./privacy.html", "./i18n/en.js", "./manifest.webmanifest", "./icons/icon-192.png", "./icons/logo-text-light.png", "./icons/icon-512.png", "./icons/icon-maskable-512.png", "./icons/apple-touch-icon.png", "./icons/favicon-32.png", "./icons/logo-text.png"];
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

// ---------- Notificações (push) ----------
// App em inglês (8.42): a página guarda o idioma em "hi-lang" e os avisos são traduzidos aqui.
const PUSH_EN = [["Notificações ativas", "Notifications are on"], ["Teste enviado com sucesso.", "Test sent successfully."], ["Resposta do professor", "Reply from your teacher"], ["O professor respondeu ao seu recado.", "Your teacher replied to your message."], ["Novo recado", "New message"], ["{0} avisou que vai faltar na aula de {1}", "{0} said they'll miss the lesson on {1}"], ["{0} avisou que vai faltar", "{0} said they'll miss a lesson"], ["{0} avisou que pagou", "{0} said they've paid"], ["{0} pediu uma alteração nos dados", "{0} asked to change their details"], ["{0} pediu para remarcar a aula de {1}", "{0} asked to reschedule the lesson on {1}"], ["{0} pediu para remarcar uma aula", "{0} asked to reschedule a lesson"], ["{0} escolheu um horário de reposição", "{0} picked a time for a make-up lesson"], ["{0} pediu para apagar os dados", "{0} asked to delete their data"], ["Pedido de entrada", "Request to join"], ["{0} quer entrar", "{0} wants to join"], ["Aula remarcada", "Lesson rescheduled"], ["Aula cancelada", "Lesson canceled"], ["Sua aula de {0} foi remarcada", "Your lesson on {0} was rescheduled"], ["Sua aula de {0} foi cancelada", "Your lesson on {0} was canceled"], ["Reposição marcada", "Make-up lesson scheduled"], ["{0} às {1}", "{0} at {1}"], ["Aviso de {0}", "Notice from {0}"], ["Novo aviso do seu professor", "New notice from your teacher"], ["Mensalidade em atraso", "Monthly fee overdue"], ["Confira o financeiro", "Check your payments in the app"], ["Aviso da escola", "School notice"], ["Novo aviso", "New notice"], ["A escola mandou um interessado para você.", "The school sent you a lead."], ["Um aluno foi passado para você. Toque para aceitar.", "A student was transferred to you. Tap to accept."], ["Escola", "School"], ["Um professor pediu para entrar na escola", "A teacher asked to join the school"], ["{0} pediu para entrar na escola", "{0} asked to join the school"]];
function pushTr(t){
  t = String(t || "");
  for (const [pt, en] of PUSH_EN) {
    const names = [];
    const re = new RegExp("^" + pt.replace(/[.*+?^${}()|[\]\\]/g, "\\$&").replace(/\\\{(\d)\\\}/g, (_, n) => { names.push(+n); return "(.+?)"; }) + "$");
    const m = re.exec(t);
    if (m) return en.replace(/\{(\d)\}/g, (_, n) => pushTr(m[names.indexOf(+n) + 1]) );
  }
  return t;
}
async function pushLang(){ try { const c = await caches.open("hi-lang"); const r = await c.match("./__lang"); return r ? await r.text() : "pt"; } catch (x) { return "pt"; } }
self.addEventListener("push", e => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (x) { d = { body: e.data ? e.data.text() : "" }; }
  e.waitUntil(pushLang().then(l => { if (l === "en") { d.title = pushTr(d.title); d.body = pushTr(d.body); } }).then(() => self.registration.showNotification(d.title || "Hi Teacher", {
    body: d.body || "",
    icon: "icons/icon-192.png",
    badge: "icons/icon-192.png",
    tag: d.tag || undefined,
    data: { url: d.url || "./" },
    requireInteraction: false
  })));
});
// Abre (ou traz pra frente) o app na página do aviso. Com o app já aberto, só pede pra ele trocar de página.
async function openFromNotification(rawUrl){
  const url = new URL(rawUrl || "./", self.registration.scope).href;
  const p = new URL(url).searchParams.get("p");
  const all = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
  const open = all.find(c => c.url.startsWith(self.registration.scope));
  if (open) {
    try { await open.focus(); } catch (x) {}
    if (p) open.postMessage({ type: "open-page", p });
    return "focused";
  }
  await self.clients.openWindow(url);
  return "opened";
}
self.addEventListener("notificationclick", e => {
  e.notification.close();
  e.waitUntil(openFromNotification(e.notification.data && e.notification.data.url));
});
