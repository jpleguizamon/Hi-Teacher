// Monta i18n/en.js (o que o app carrega em inglês) a partir de i18n/engine.js e i18n/en-dict.json.
// Uso: node tools/i18n-build.js
const fs = require("fs"), path = require("path");
const dir = path.join(__dirname, "..", "i18n");
const dict = JSON.parse(fs.readFileSync(path.join(dir, "en-dict.json"), "utf8"));
const exact = {}, pats = [];
for (const [pt, en] of Object.entries(dict)) {
  if (en == null || en === pt) continue;
  if (/\{\d+\}/.test(pt)) pats.push([pt, en]); else exact[pt] = en;
}
const eng = fs.readFileSync(path.join(dir, "engine.js"), "utf8");
const out = eng.replace("__DICT__", JSON.stringify(exact)).replace("__PATS__", JSON.stringify(pats));
fs.writeFileSync(path.join(dir, "en.js"), out);
console.log("en.js:", Object.keys(exact).length, "textos,", pats.length, "frases com partes,", Math.round(out.length / 1024), "KB");
