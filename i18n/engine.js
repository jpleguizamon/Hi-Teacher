// Versão em inglês (8.42). Este arquivo só roda com o app em inglês.
// Troca, na tela, cada texto em português pelo inglês do dicionário (i18n/en-dict.json).
// Não muda nenhum dado salvo: só o que aparece. Montado por tools/i18n-build.js.
(function(){
"use strict";
const D = new Map(Object.entries(__DICT__));
const P = __PATS__;
const esc = s => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
const norm = s => s.replace(/\s+/g, " ").trim();
const LETTER = /[A-Za-zÀ-ÿ]/;

// Frases com partes que mudam ("{0} alunos"): viram uma busca com lacunas.
const pats = [];
for (const [src, dst] of P) {
  const parts = src.split(/(\{\d+\})/);
  let re = "^", lit = 0, key = "";
  const idx = [];
  parts.forEach((p, i) => {
    const m = /^\{(\d+)\}$/.exec(p);
    // Lacuna colada numa palavra ("aluno{1}") é só final de plural/gênero: no máximo 4 letras.
    const glued = m && (/[A-Za-zÀ-ÿ]$/.test(parts[i - 1] || "") || /^[A-Za-zÀ-ÿ]/.test(parts[i + 1] || ""));
    // Duas lacunas seguidas ("{0}{1}"): a primeira pega o texto todo, a segunda fica com o que sobrar.
    const nextGap = /^\{\d+\}$/.test(parts[i + 1] || "") || (parts[i + 1] === "" && /^\{\d+\}$/.test(parts[i + 2] || ""));
    // Colada numa palavra: final curto ("s", "es", "ões") ou um trecho que começa com espaço/pontuação.
    if (m) { idx.push(+m[1]); re += glued ? "([A-Za-zÀ-ÿ]{0,3}(?:\\s.*?)?|[\\s,;:(·.].*?)" : nextGap ? "(.*)" : "(.*?)"; }
    else if (p) { re += esc(p); lit += p.replace(/\s/g, "").length; if (p.trim().length > key.length) key = p.trim(); }
  });
  // "{0} de {1}" é curto demais (trocaria palavras soltas); "com {0}" (palavra no começo) pode.
  if (!key || (lit < 4 && !/^[A-Za-zÀ-ÿ]+ \{\d+\}$/.test(src))) continue;
  pats.push({ re: new RegExp(re + "$", "s"), idx, dst, key, lit, sep: / · | • /.test(src) });
}
pats.sort((a, b) => b.lit - a.lit);

const cache = new Map();
function trCore(core, depth, onlySep){
  const hit = D.get(core);
  if (hit !== undefined) return hit;
  if (depth > 2) return null;
  for (const p of pats) {
    if (onlySep && !p.sep) continue;
    if (core.indexOf(p.key) < 0) continue;
    const m = p.re.exec(core);
    if (!m) continue;
    // Frase curta não pode engolir um texto montado ("02/11 a 05/11 · todos os alunos").
    if (p.lit < 12 && m.slice(1).some(x => x && SEP.test(x))) continue;
    return p.dst.replace(/\{(\d+)(:th)?\}/g, (_, n, th) => {
      const i = p.idx.indexOf(+n);
      const v = i >= 0 ? (m[i + 1] || "") : "";
      if (th && /^\d+$/.test(v)) return ordinal(+v);
      return trPiece(v, depth + 1);
    });
  }
  return null;
}
function ordinal(n){ const t = n % 100, u = n % 10; return n + (t >= 11 && t <= 13 ? "th" : u === 1 ? "st" : u === 2 ? "nd" : u === 3 ? "rd" : "th"); }
function trPiece(v, depth){
  const c = norm(v);
  if (!c || !LETTER.test(c)) return v;
  const r = depth > 2 ? D.get(c) : trAny(c, depth);
  if (r == null) return v;
  const lead = /^\s*/.exec(v)[0], trail = /\s*$/.exec(v)[0];
  return lead + r + trail;
}
// Texto montado por partes: "Violão · ind.", "Pontualidade 5", "Pago em 08/08." etc.
const SEP = /( · | • | \| | — )/;
function trParts(core, strict){
  if (SEP.test(core)) {
    const ps = core.split(SEP);
    let changed = false, missed = false;
    const out = ps.map((x, i) => { if (i % 2) return x; const r = trAny(x.trim(), 1); if (r != null) { changed = true; return r; } if (/[A-Za-zÀ-ÿ]{4,}/.test(x) && !/^[A-ZÀ-Ý][\wÀ-ÿ'.-]*( [A-ZÀ-Ý][\wÀ-ÿ'.-]*)*$/.test(x.trim())) missed = true; return x; });
    if (strict && missed) return null;
    return changed ? out.join("") : null;
  }
  if (strict) return null;
  let m = /^(.*?[^\d\s:(])(\s*:?\s*(?:\d[\d.,/:%h ]*|\(\d+\)))$/.exec(core);
  if (m) { const r = trAny(m[1], 1); if (r != null) return r + m[2]; }
  m = /^(.*?)([.:!?…]+)$/.exec(core);
  if (m && m[1]) { const r = trAny(m[1], 1); if (r != null) return r + m[2]; }
  m = /^(\d[\d.,/:%h ]*\s*)(.*[^\d\s])$/.exec(core);
  if (m) { const r = trAny(m[2], 1); if (r != null) return m[1] + r; }
  // "Rótulo: valor" só quando os dois lados têm tradução.
  m = /^([^:]{2,40}): (.+)$/.exec(core);
  if (m) { const a = trAny(m[1], 1), b2 = /[A-Za-zÀ-ÿ]/.test(m[2]) ? trAny(m[2], 1) : m[2]; if (a != null && b2 != null) return a + ": " + b2; }
  return null;
}
const PT_WORDS = /\b(de|do|da|dos|das|os|as|com|para|pra|todos|todas|uma|um|que|não|sem|aula|aulas|aluno|alunos|casa|em|no|na|ao)\b/gi;
function ptScore(t){ return (t.match(/[ãõçáéíóúâêôà]/gi) || []).length + (t.match(PT_WORDS) || []).length * 2; }
function trAny(core, depth = 0){
  const hit = D.get(core);
  if (hit !== undefined) return hit;
  // Partes separadas por " · ": primeiro cada parte (se todas têm tradução), depois a frase inteira.
  if (SEP.test(core)) {
    // Duas leituras (frase com " · " do código, ou parte por parte): fica a que sobra menos português.
    const r0 = trCore(core, depth, true), q0 = trParts(core, true);
    if (r0 != null && q0 != null) return ptScore(q0) < ptScore(r0) ? q0 : r0;
    if (r0 != null) return r0;
    if (q0 != null) return q0;
  }
  const r = trCore(core, depth);
  if (r != null) return r;
  if (depth > 2) return null;
  const q = trParts(core);
  if (q != null) return q;
  // "· Ainda vai acontecer", "(hoje)": símbolo na frente.
  let m = /^([·•\-–—(]\s*)(.+?)(\)?)$/.exec(core);
  if (m && m[2] !== core) { const t = trAny(m[2], depth + 1); if (t != null) return m[1] + t + m[3]; }
  // Pedaço em minúscula no meio da frase ("forma de C"): tenta como começo de frase.
  const c0 = core.charAt(0);
  if (c0 !== c0.toUpperCase()) {
    const up = c0.toUpperCase() + core.slice(1);
    const u = D.has(up) ? D.get(up) : trCore(up, depth);
    if (u) return /^[A-Z][a-z]/.test(u) && !/^(I|I'm|I'll|I've|January|February|March|April|May|June|July|August|September|October|November|December|Sunday|Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|English|Portuguese|Pix|WhatsApp|Google|Apple|Hi Teacher)\b/.test(u) ? u.charAt(0).toLowerCase() + u.slice(1) : u;
  }
  return null;
}
function tr(s){
  if (typeof s !== "string" || !s || !LETTER.test(s)) return s;
  let r = cache.get(s);
  if (r !== undefined) return r;
  const core = norm(s);
  let t = trAny(core);
  if (t == null && /\n/.test(s)) {
    // mensagem de várias linhas: cada linha sozinha
    const ls = s.split("\n");
    const out = ls.map(l => trPiece(l, 0));
    if (out.some((x, i) => x !== ls[i])) r = out.join("\n");
  }
  if (r === undefined) r = t == null ? s : (/^\s*/.exec(s)[0] + t + /\s*$/.exec(s)[0]);
  if (cache.size > 20000) cache.clear();
  cache.set(s, r);
  return r;
}
window.hiTr = tr;
window.hiTrList = a => a.map(tr);
window.APP_LOCALE = "en-US";

// Link do WhatsApp com texto pronto (?text=...).
function trUrl(url){
  if (typeof url !== "string" || !/wa\.me|whatsapp/i.test(url) || !/[?&]text=/.test(url)) return url;
  return url.replace(/([?&]text=)([^&#]*)/, (_, a, t) => {
    let d; try { d = decodeURIComponent(t.replace(/\+/g, " ")); } catch(e) { return a + t; }
    return a + encodeURIComponent(tr(d));
  });
}
window.hiTrUrl = trUrl;

// ---------- tela ----------
const ATTRS = ["placeholder", "title", "aria-label", "alt", "data-help", "data-tip", "label"];
const SKIP = { SCRIPT: 1, STYLE: 1, TEXTAREA: 1, NOSCRIPT: 1, CODE: 1 };
function skipEl(el){ return !el || el.nodeType !== 1 ? false : !!(SKIP[el.nodeName] || el.isContentEditable || el.hasAttribute("data-no-tr")); }
// Caixa de texto: o que a pessoa digita fica, mas a dica (placeholder) é traduzida.
function skipAttrs(el){ return !el || el.nodeType !== 1 ? true : !!(el.nodeName === "SCRIPT" || el.nodeName === "STYLE" || el.isContentEditable || el.hasAttribute("data-no-tr")); }
// Texto que já foi traduzido não passa de novo (o inglês não pode ser "traduzido" outra vez).
const done = new WeakMap();
function trText(n){
  const p = n.parentNode;
  if (!p || skipEl(p) || (p.closest && p.closest("[data-no-tr],[contenteditable=true]"))) return;
  const v = n.nodeValue;
  if (done.get(n) === v) return;
  const t = tr(v);
  if (t !== v) n.nodeValue = t;
  done.set(n, t);
}
function trEl(el){
  if (skipAttrs(el)) return;
  for (const a of ATTRS) {
    const v = el.getAttribute(a);
    if (v) { const t = tr(v); if (t !== v) el.setAttribute(a, t); }
  }
  if (el.nodeName === "INPUT" && /^(button|submit|reset)$/i.test(el.type) && el.value) { const t = tr(el.value); if (t !== el.value) el.value = t; }
  if (el.nodeName === "A") {
    const h = el.getAttribute("href");
    if (h) {
      let t = trUrl(h);
      if (/^privacidade\.html/.test(t)) t = t.replace(/^privacidade\.html/, "privacy.html");
      if (t !== h) el.setAttribute("href", t);
    }
  }
}
const FILTER = { acceptNode: n => (n.nodeType === 1 && skipEl(n) && n.nodeName !== "TEXTAREA") ? 2 : 1 };
function trTree(root){
  if (!root) return;
  if (root.nodeType === 3) return trText(root);
  if (root.nodeType === 1) { if (skipEl(root)) { if (root.nodeName === "TEXTAREA") trEl(root); return; } trEl(root); }
  else if (root.nodeType !== 11) return;
  const w = document.createTreeWalker(root, 5, FILTER);
  let n;
  while ((n = w.nextNode())) { if (n.nodeType === 3) trText(n); else trEl(n); }
}
window.hiTrTree = trTree;
const obs = new MutationObserver(ms => {
  for (const m of ms) {
    if (m.type === "childList") m.addedNodes.forEach(trTree);
    else if (m.type === "characterData") trText(m.target);
    else if (m.type === "attributes") trEl(m.target);
  }
});
obs.observe(document.documentElement, { subtree: true, childList: true, characterData: true, attributes: true, attributeFilter: ATTRS.concat(["value", "href"]) });
document.documentElement.lang = "en";
trTree(document.documentElement);
document.addEventListener("DOMContentLoaded", () => { trTree(document.documentElement); document.title = tr(document.title); });

// ---------- textos que não passam pela tela ----------
const nAlert = window.alert, nConfirm = window.confirm, nPrompt = window.prompt;
window.alert = m => nAlert.call(window, tr(String(m ?? "")));
window.confirm = m => nConfirm.call(window, tr(String(m ?? "")));
window.prompt = (m, d) => nPrompt.call(window, tr(String(m ?? "")), d);
const nOpen = window.open;
window.open = function(url, ...rest){ return nOpen.call(window, trUrl(url), ...rest); };
try {
  if (navigator.share) { const nShare = navigator.share.bind(navigator); navigator.share = d => nShare(d ? Object.assign({}, d, d.text ? { text: tr(d.text) } : {}, d.title ? { title: tr(d.title) } : {}) : d); }
} catch(e) {}
try {
  if (navigator.clipboard && navigator.clipboard.writeText) { const nw = navigator.clipboard.writeText.bind(navigator.clipboard); navigator.clipboard.writeText = t => nw(tr(t)); }
} catch(e) {}
try {
  if (window.Notification) {
    const N = window.Notification;
    const W = function(title, o){ return new N(tr(title), o && o.body ? Object.assign({}, o, { body: tr(o.body) }) : o); };
    W.prototype = N.prototype;
    Object.defineProperty(W, "permission", { get: () => N.permission });
    W.requestPermission = (...a) => N.requestPermission(...a);
    window.Notification = W;
  }
} catch(e) {}
try {
  const C = CanvasRenderingContext2D.prototype, f = C.fillText, s = C.strokeText, mt = C.measureText;
  C.fillText = function(t, ...r){ return f.call(this, tr(String(t)), ...r); };
  C.strokeText = function(t, ...r){ return s.call(this, tr(String(t)), ...r); };
  C.measureText = function(t){ return mt.call(this, tr(String(t))); };
} catch(e) {}
})();
