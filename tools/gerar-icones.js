// Gera os ícones do app instalável (pasta icons/) a partir do símbolo da logo
// (icons/logo-mark.svg: balão de "Hi" com o H feito de duas colcheias ligadas).
// Como rodar (na pasta do repositório, com Node e Playwright):
//   node tools/gerar-icones.js
// Fundo preto #05060B com brilho azul e o símbolo centralizado. O favicon é só o símbolo, sem fundo.
const fs = require("fs");
const path = require("path");
let chromium;
try { ({ chromium } = require("playwright")); } catch (e) { ({ chromium } = require("/opt/node22/lib/node_modules/playwright")); }

const root = path.join(__dirname, "..");
const svg = fs.readFileSync(path.join(root, "icons", "logo-mark.svg"), "utf8");
const outDir = path.join(root, "icons");

// size: lado do PNG; markW: tamanho do símbolo em relação ao lado; bare: sem fundo.
const ICONS = [
  { file: "icon-192.png", size: 192, markW: 0.7 },
  { file: "icon-512.png", size: 512, markW: 0.7 },
  { file: "icon-maskable-512.png", size: 512, markW: 0.56 },   // área segura do ícone "maskable"
  { file: "apple-touch-icon.png", size: 180, markW: 0.7 },
  { file: "favicon-32.png", size: 32, markW: 1, bare: true }
];

(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage();
  await page.setContent("<html><body></body></html>");
  for (const ic of ICONS) {
    const data = await page.evaluate(async ({ svg, ic }) => {
      const img = new Image();
      img.src = "data:image/svg+xml;charset=utf-8," + encodeURIComponent(svg);
      await img.decode();
      const S = ic.size;
      const c = document.createElement("canvas"); c.width = c.height = S;
      const x = c.getContext("2d");
      if (!ic.bare) {
        x.fillStyle = "#05060B"; x.fillRect(0, 0, S, S);
        const g = x.createRadialGradient(S * 0.5, S * 0.45, S * 0.05, S * 0.5, S * 0.5, S * 0.7);
        g.addColorStop(0, "rgba(47,180,242,0.35)"); g.addColorStop(0.5, "rgba(30,98,224,0.14)"); g.addColorStop(1, "rgba(5,6,11,0)");
        x.fillStyle = g; x.fillRect(0, 0, S, S);
      }
      const w = S * ic.markW;
      x.imageSmoothingQuality = "high";
      x.drawImage(img, (S - w) / 2, (S - w) / 2, w, w);
      return c.toDataURL("image/png").split(",")[1];
    }, { svg, ic });
    fs.writeFileSync(path.join(outDir, ic.file), Buffer.from(data, "base64"));
    console.log("icons/" + ic.file);
  }
  await browser.close();
})();
