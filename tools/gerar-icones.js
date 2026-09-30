// Gera os ícones do app instalável (pasta icons/) a partir da logo "Hi teacher" que está
// embutida no index.html. Como rodar (na pasta do repositório, com Node e Playwright):
//   node tools/gerar-icones.js
// Fundo preto #05060B com brilho ciano; logo branca centralizada. Nos tamanhos pequenos
// (favicon) a logo cursiva inteira fica ilegível, então usa só o "Hi" em ciano.
const fs = require("fs");
const path = require("path");
let chromium;
try { ({ chromium } = require("playwright")); } catch (e) { ({ chromium } = require("/opt/node22/lib/node_modules/playwright")); }

const root = path.join(__dirname, "..");
const html = fs.readFileSync(path.join(root, "index.html"), "utf8");
const m = /class="side-logo-img" src="data:image\/png;base64,([^"]+)"/.exec(html);
if (!m) throw new Error("Logo não encontrada no index.html");
const logo = m[1];
const outDir = path.join(root, "icons");
fs.mkdirSync(outDir, { recursive: true });

// size: lado do PNG; logoW: largura da logo em relação ao lado; mono: só o "Hi" em ciano.
const ICONS = [
  { file: "icon-192.png", size: 192, logoW: 0.78 },
  { file: "icon-512.png", size: 512, logoW: 0.78 },
  { file: "icon-maskable-512.png", size: 512, logoW: 0.6 },   // 20% de margem de cada lado
  { file: "apple-touch-icon.png", size: 180, logoW: 0.78 },
  { file: "favicon-32.png", size: 32, mono: true }
];

(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage();
  await page.setContent("<html><body></body></html>");
  for (const ic of ICONS) {
    const data = await page.evaluate(async ({ logo, ic }) => {
      const img = new Image();
      img.src = "data:image/png;base64," + logo;
      await img.decode();
      const S = ic.size;
      const c = document.createElement("canvas"); c.width = c.height = S;
      const x = c.getContext("2d");
      x.fillStyle = "#05060B"; x.fillRect(0, 0, S, S);
      const g = x.createRadialGradient(S * 0.5, S * 0.42, S * 0.04, S * 0.5, S * 0.5, S * 0.72);
      g.addColorStop(0, "rgba(47,211,242,0.42)"); g.addColorStop(0.45, "rgba(30,136,229,0.18)"); g.addColorStop(1, "rgba(5,6,11,0)");
      x.fillStyle = g; x.fillRect(0, 0, S, S);
      // Recorte: logo inteira ou só a primeira palavra ("Hi"), achada pela primeira coluna vazia larga.
      let sx = 0, sw = img.width;
      const probe = document.createElement("canvas"); probe.width = img.width; probe.height = img.height;
      const px = probe.getContext("2d"); px.drawImage(img, 0, 0);
      const a = px.getImageData(0, 0, img.width, img.height).data;
      const colFull = cx => { for (let y = 0; y < img.height; y++) if (a[(y * img.width + cx) * 4 + 3] > 20) return true; return false; };
      let first = 0; while (first < img.width && !colFull(first)) first++;
      let last = img.width - 1; while (last > 0 && !colFull(last)) last--;
      sx = first; sw = last - first + 1;
      if (ic.mono) {
        let end = first, gap = 0;
        for (let cx = first; cx < last; cx++) { if (colFull(cx)) { end = cx; gap = 0; } else if (++gap > img.width * 0.02) break; }
        sw = end - first + 1;
      }
      // Linhas com desenho (tira a sobra transparente de cima e de baixo).
      const rowFull = cy => { for (let cx = sx; cx < sx + sw; cx++) if (a[(cy * img.width + cx) * 4 + 3] > 20) return true; return false; };
      let sy = 0; while (sy < img.height - 1 && !rowFull(sy)) sy++;
      let ey = img.height - 1; while (ey > sy && !rowFull(ey)) ey--;
      const sh = ey - sy + 1;
      const box = ic.mono ? S * 0.8 : S * ic.logoW;
      const k = Math.min(box / sw, (ic.mono ? S * 0.8 : S * 0.6) / sh);
      const w = sw * k, h = sh * k;
      const piece = document.createElement("canvas"); piece.width = sw; piece.height = sh;
      const pc = piece.getContext("2d"); pc.drawImage(img, sx, sy, sw, sh, 0, 0, sw, sh);
      if (ic.mono) { pc.globalCompositeOperation = "source-in"; pc.fillStyle = "#2FD3F2"; pc.fillRect(0, 0, sw, sh); }
      x.imageSmoothingQuality = "high";
      x.drawImage(piece, (S - w) / 2, (S - h) / 2, w, h);
      return c.toDataURL("image/png").split(",")[1];
    }, { logo, ic });
    fs.writeFileSync(path.join(outDir, ic.file), Buffer.from(data, "base64"));
    console.log("icons/" + ic.file);
  }
  await browser.close();
})();
