// Gera os ícones do app instalável (pasta icons/) a partir do símbolo da logo
// e do APK Android (android/app/src/main/res/mipmap-*) a partir de icons/logo-mark.svg:
// a coruja branca de óculos e capelo azuis dentro do círculo azul (8.54).
// Como rodar (na pasta do repositório, com Node e Playwright):
//   node tools/gerar-icones.js
// Fundo preto #05060B liso (sem brilho) e a coruja centralizada. No Android, o "foreground" é sem fundo
// (o fundo preto vem de @color/bg) e com margem, porque o celular corta o ícone em círculo/gota.
const fs = require("fs");
const path = require("path");
let chromium;
try { ({ chromium } = require("playwright")); } catch (e) { ({ chromium } = require("/opt/node22/lib/node_modules/playwright")); }

const root = path.join(__dirname, "..");
const svg = fs.readFileSync(path.join(root, "icons", "logo-mark.svg"), "utf8");
const outDir = path.join(root, "icons");

// size: lado do PNG; markW: tamanho do símbolo em relação ao lado.
const ICONS = [
  { file: "icon-192.png", size: 192, markW: 0.88 },
  { file: "icon-512.png", size: 512, markW: 0.88 },
  { file: "icon-maskable-512.png", size: 512, markW: 0.76 },   // área segura do ícone "maskable"
  { file: "apple-touch-icon.png", size: 180, markW: 0.88 },
  { file: "favicon-32.png", size: 32, markW: 1 }
];
const RES = path.join(root, "android", "app", "src", "main", "res");
for (const [d, n] of [["mdpi", 48], ["hdpi", 72], ["xhdpi", 96], ["xxhdpi", 144], ["xxxhdpi", 192]]) {
  ICONS.push({ dir: path.join(RES, "mipmap-" + d), file: "ic_launcher.png", size: n, markW: 0.94 });
  ICONS.push({ dir: path.join(RES, "mipmap-" + d), file: "ic_launcher_foreground.png", size: n * 2.25, markW: 0.6, bare: true });
}

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
      if (!ic.bare) { x.fillStyle = "#05060B"; x.fillRect(0, 0, S, S); }
      const w = S * ic.markW;
      x.imageSmoothingQuality = "high";
      x.drawImage(img, (S - w) / 2, (S - w) / 2, w, w);
      return c.toDataURL("image/png").split(",")[1];
    }, { svg, ic });
    const out = path.join(ic.dir || outDir, ic.file);
    fs.writeFileSync(out, Buffer.from(data, "base64"));
    console.log(path.relative(root, out));
  }
  await browser.close();
})();
