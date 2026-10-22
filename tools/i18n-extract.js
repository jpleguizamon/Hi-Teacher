// Versão em inglês: acha os textos em português do index.html (marcação + strings do JS).
// Uso: node tools/i18n-extract.js index.html saida.json
// Saída: [{ s: "texto com {0}", n, ctx }] só com o que ainda NÃO está em i18n/en-dict.json.
// Depois de traduzir, junte no en-dict.json ({"português": "inglês"}) e rode tools/i18n-build.js.
const fs = require("fs");
const acorn = require("acorn");
const walk = require("acorn-walk");
const file = process.argv[2];
const out = process.argv[3];
const html = fs.readFileSync(file, "utf8");

const map = new Map();
function add(s, ctx) {
  if (s == null) return;
  if (/\n/.test(s)) { const ls = s.split(/\n+/); if (ls.length > 1) ls.forEach(l => add1(l, ctx)); }
  add1(s, ctx);
}
function add1(s, ctx) {
  s = s.replace(/\s+/g, " ").trim();
  if (!s) return;
  if (!/[A-Za-zÀ-ÿ]{2,}/.test(s)) return;
  const e = map.get(s);
  if (e) { e.n++; return; }
  map.set(s, { s, n: 1, ctx: (ctx || "").replace(/\s+/g, " ").slice(0, 220) });
}

// ---------- HTML fragment -> text segments and attribute values ----------
const ATTRS = ["placeholder", "title", "aria-label", "alt", "data-help", "data-tip", "label", "data-title", "data-label", "data-confirm"];
const ATTR_RE = new RegExp(`\\s(${ATTRS.join("|")})\\s*=\\s*("([^"]*)"|'([^']*)')`, "gi");
function fromHtml(frag, ctx) {
  // frag may contain {N} placeholders (from template literals)
  let m;
  ATTR_RE.lastIndex = 0;
  while ((m = ATTR_RE.exec(frag))) add(decode(m[3] ?? m[4]), ctx);
  // value="..." on buttons / submit inputs
  const vb = /<input[^>]*type\s*=\s*["'](?:button|submit)["'][^>]*>/gi;
  while ((m = vb.exec(frag))) { const v = /\svalue\s*=\s*"([^"]*)"/i.exec(m[0]); if (v) add(decode(v[1]), ctx); }
  // strip script/style/svg-defs, then split on tags
  const body = frag.replace(/<style[\s\S]*?<\/style>/gi, " ").replace(/<script[\s\S]*?<\/script>/gi, " ").replace(/<!--[\s\S]*?-->/g, " ");
  const parts = body.split(/<[^>]*>/);
  for (const p of parts) add(decode(p), ctx);
}
function decode(s) {
  return s.replace(/&nbsp;/g, " ").replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&rarr;/g, "→");
}
const looksHtml = s => /<\/?[a-z][^>]*>/i.test(s);

// ---------- static markup (outside <script>) ----------
const scripts = [];
const reS = /<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/gi;
let mm, last = 0, staticHtml = "";
while ((mm = reS.exec(html))) {
  staticHtml += html.slice(last, mm.index);
  scripts.push(mm[1]);
  last = reS.lastIndex;
}
staticHtml += html.slice(last);
fromHtml(staticHtml.replace(/<head>[\s\S]*?<\/head>/i, m => m.replace(/<style[\s\S]*?<\/style>/gi, "")), "html");
const t = /<title>([^<]*)<\/title>/i.exec(html); if (t) add(t[1], "title");

// ---------- JS ----------
function tplToPattern(node, src) {
  let s = "", k = 0;
  node.quasis.forEach((q, i) => {
    s += q.value.cooked ?? q.value.raw;
    if (i < node.expressions.length) s += `{${k++}}`;
  });
  return s;
}
function concatParts(node, acc) {
  if (node.type === "BinaryExpression" && node.operator === "+") { concatParts(node.left, acc); concatParts(node.right, acc); }
  else acc.push(node);
  return acc;
}
function handleString(s, ctx) {
  if (looksHtml(s)) fromHtml(s, ctx);
  else add(s, ctx);
}
for (const code of scripts) {
  let ast;
  try { ast = acorn.parse(code, { ecmaVersion: "latest", sourceType: "script", allowReturnOutsideFunction: true }); }
  catch (e) { console.error("parse error", e.message); continue; }
  const ctxOf = n => code.slice(Math.max(0, n.start - 60), Math.min(code.length, n.end + 40));
  const inConcat = new Set();
  walk.full(ast, n => {
    if (n.type === "BinaryExpression" && n.operator === "+") {
      const parts = concatParts(n, []);
      if (!parts.some(p => p.type === "Literal" && typeof p.value === "string")) return;
      // only top-level chains
      let s = "", k = 0;
      for (const p of parts) {
        if (p.type === "Literal" && typeof p.value === "string") { s += p.value; }
        else if (p.type === "TemplateLiteral") { s += tplToPattern(p).replace(/\{(\d+)\}/g, () => `{${k++}}`); }
        else s += `{${k++}}`;
      }
      add.__chain = true;
      handleString(s, ctxOf(n));
    }
  });
  walk.full(ast, n => {
    if (n.type === "Literal" && typeof n.value === "string") handleString(n.value, ctxOf(n));
    else if (n.type === "TemplateLiteral") handleString(tplToPattern(n), ctxOf(n));
  });
}

// ---------- filter obvious non-text ----------
const res = [...map.values()].filter(e => {
  const s = e.s;
  if (/^[\w.#\-\[\]=:>,*\s"'()]+$/.test(s) && !/\s/.test(s.trim()) && !/^[A-ZÁ-Ú][a-zá-ú]/.test(s)) return false; // ids, keys, selectors
  if (/^(https?:|mailto:|tel:|data:|blob:|\/|\.\/|#)/.test(s)) return false;
  if (/^[a-z0-9_\-]+( [a-z0-9_\-]+)*$/.test(s) && /-/.test(s)) return false; // class lists
  if (/[{;]\s*[a-z-]+\s*:\s*[^;]+;/.test(s) && !/[À-ÿ]/.test(s)) return false; // css
  if (/^(px|rem|em|vh|vw|%|auto|none|block|flex|inline|hidden|visible|absolute|relative|fixed|transparent)$/i.test(s)) return false;
  return true;
});
for (const x of JSON.parse(fs.readFileSync(__dirname + "/../i18n/extras-servidor.json", "utf8"))) add(x, "server/extra");
let dict = {};
try { dict = JSON.parse(fs.readFileSync(__dirname + "/../i18n/en-dict.json", "utf8")); } catch(e) {}
const skip = new Set(JSON.parse((() => { try { return fs.readFileSync(__dirname + "/../i18n/en-skip.json", "utf8"); } catch(e) { return "[]"; } })()));
const todo = process.argv[4] === "--all" ? res : res.filter(e => !(e.s in dict) && !skip.has(e.s));
fs.writeFileSync(out, JSON.stringify(todo, null, 1));
console.log("faltando", todo.length);
console.log("entries", res.length, "chars", res.reduce((a, e) => a + e.s.length, 0));
