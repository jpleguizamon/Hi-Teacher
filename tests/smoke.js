// Teste automático do Hi Teacher (8.41). Roda antes de cada publicação (.github/workflows/pages.yml)
// e também à mão: node tests/smoke.js. Abre o app num navegador sem tela, com o servidor
// (Supabase) de mentira, e confere:
//   1. o login aparece primeiro e a escolha (professor/escola/aluno) só depois, em conta nova;
//   2. todas as páginas do professor e do aluno abrem sem erro;
//   3. planos: teste grátis, fim do teste, limite de alunos e a tela Assinaturas;
//   4. a versão em inglês (8.42): login em inglês e todas as páginas abrindo sem erro.
// Se algo der errado, sai com erro e a publicação não acontece.
const http = require("http"), fs = require("fs"), path = require("path");
const { chromium } = require("playwright");
const ROOT = path.join(__dirname, "..");
const TYPES = { ".html": "text/html", ".js": "text/javascript", ".json": "application/json", ".webmanifest": "application/manifest+json", ".png": "image/png", ".svg": "image/svg+xml", ".mp3": "audio/mpeg", ".css": "text/css" };
const server = http.createServer((req, res) => {
  const u = decodeURIComponent(req.url.split("?")[0]);
  const f = path.join(ROOT, u === "/" ? "index.html" : u);
  if (!f.startsWith(ROOT) || !fs.existsSync(f) || fs.statSync(f).isDirectory()) { res.writeHead(404); return res.end(); }
  res.writeHead(200, { "Content-Type": TYPES[path.extname(f)] || "application/octet-stream" });
  fs.createReadStream(f).pipe(res);
});
const failures = [];
const check = (ok, what) => { if (!ok) failures.push(what); console.log((ok ? "ok   " : "FALHA") + " " + what); };
// Supabase de mentira: sem conta aberta (ou com uma conta nova, se SESSION=true no teste).
const fakeSupabase = withSession => `
  const anyP = () => new Proxy(function(){}, { get: (t, k) => k === 'then' ? undefined : anyP(), apply: () => anyP() });
  const q = () => { const o = { select: () => o, eq: () => o, neq: () => o, order: () => o, limit: async () => ({ data: [], error: null }), maybeSingle: async () => ({ data: null, error: null }) }; return o; };
  window.supabase = { createClient: () => ({
    rpc: async (n, a) => window.__rpc ? window.__rpc(n, a) : (n === 'hi_my_join_requests' ? { data: [], error: null } : { data: null, error: { message: 'offline' } }),
    auth: { getSession: async () => ({ data: { session: null } }), signInWithOAuth: async () => ({ error: null }),
      onAuthStateChange: cb => { setTimeout(() => cb('INITIAL_SESSION', ${withSession} ? { user: { id: 'new1', email: 'n@x.com' } } : null), 300); return { data: { subscription: { unsubscribe(){} } } }; } },
    from: () => q(), channel: () => anyP(), functions: { invoke: async () => ({ error: { message: 'x' } }) } }) };`;
async function page(browser, url, { session = false, seed = true } = {}) {
  const p = await browser.newPage({ viewport: { width: 390, height: 844 } });
  const errs = [];
  p.on("pageerror", e => errs.push(String(e.stack || e).slice(0, 300)));
  p.on("dialog", d => d.accept());
  await p.route(/googleapis|gstatic|firebase|supabase\.co/, r => r.abort());
  await p.route(/cdn\.jsdelivr\.net\/npm\/@supabase/, r => r.fulfill({ status: 200, contentType: "application/javascript", body: fakeSupabase(session) }));
  if (seed) await p.addInitScript(() => {
    if (localStorage.getItem("seeded")) return; localStorage.setItem("seeded", "1");
    const st = [];
    for (let i = 1; i <= 7; i++) st.push({ id: i, name: "Aluno " + i, instrument: "Violão", days: [1 + (i % 5)], time: "14:00", entry: "2025-01-10", active: true, value: 150, dueDay: 10, lessons: [{ date: "06/10/2026", homework: "Escala", scores: { pontualidade: 5 } }], phone: "31999990000" });
    localStorage.setItem("jp_students_v5", JSON.stringify(st));
    localStorage.setItem("jp_settings_v1", JSON.stringify({ paymentsSince: "2026-01", profile: { name: "Prof", fullName: "Prof Teste" }, location: { city: "Belo Horizonte", state: "MG" }, onboarded: true, instruments: ["Violão", "Piano"], planTrialSeen: true }));
  });
  await p.goto(url);
  await p.waitForTimeout(2000);
  return { p, errs };
}
(async () => {
  await new Promise(r => server.listen(0, r));
  const base = `http://localhost:${server.address().port}/index.html`;
  const browser = await chromium.launch(process.env.CHROMIUM_PATH ? { executablePath: process.env.CHROMIUM_PATH } : {});
  try {
    // 1. Entrada
    { const { p, errs } = await page(browser, base, { seed: false });
      check(await p.evaluate(() => document.getElementById("authForm").style.display === "block"), "sem conta: o login aparece primeiro");
      check(!errs.length, "sem conta: nenhum erro" + (errs.length ? " → " + errs[0] : ""));
      await p.close(); }
    { const { p, errs } = await page(browser, base, { session: true, seed: false });
      check(await p.evaluate(() => document.getElementById("authChoice").style.display === "block"), "conta nova: aparece a escolha professor/escola/aluno");
      check(!errs.length, "conta nova: nenhum erro" + (errs.length ? " → " + errs[0] : ""));
      await p.close(); }
    // 2. Todas as páginas
    { const { p, errs } = await page(browser, base);
      const pages = await p.evaluate(() => [...new Set([...document.querySelectorAll("[data-page]")].map(e => e.dataset.page))]);
      for (const pg of pages) { await p.evaluate(pg => openPage(pg), pg).catch(e => errs.push(pg + ": " + e.message)); await p.waitForTimeout(150); }
      await p.evaluate(() => { openEdit(1); document.querySelectorAll(".modal-bg.show").forEach(m => m.classList.remove("show")); }).catch(e => errs.push("ficha: " + e.message));
      await p.evaluate(() => startDemo()).catch(e => errs.push("demo do aluno: " + e.message));
      await p.waitForTimeout(1200);
      const sp = await p.evaluate(() => [...new Set([...document.querySelectorAll("[data-stu-page]")].map(e => e.dataset.stuPage))]);
      for (const pg of sp) { await p.evaluate(pg => stuOpenPage(pg), pg).catch(e => errs.push("aluno " + pg + ": " + e.message)); await p.waitForTimeout(150); }
      check(pages.length > 10 && sp.length > 10, `abriu ${pages.length} páginas do professor e ${sp.length} do aluno`);
      check(!errs.length, "páginas: nenhum erro" + (errs.length ? " → " + errs.slice(0, 3).join(" | ") : ""));
      await p.close(); }
    // 2b. Consertos da 8.44 (dinheiro, segurança e janelas)
    { const { p, errs } = await page(browser, base);
      const r = await p.evaluate(() => {
        const s = students[0], cur = currentMonthKey(), past = addMonths(cur, -2);
        setMonthPaid(s, past, true);
        raiseStudentValue(s, 170, cur);
        const keptPast = paidMonthValue(s, past) === 150 && paidMonthValue(s, cur) === 170;
        const clean = cleanJoin({ id: "x", instrument: '<img src=x onerror="alert(1)">', student_name: "A<b>" });
        const m = document.getElementById("syncConflictModal"); m.classList.add("show");
        modalDownOn = m; m.click(); const stays = m.classList.contains("show"); m.classList.remove("show");
        return { keptPast, xss: !/[<>"]/.test(clean.instrument + clean.student_name) && clean.id === "x", stays };
      });
      check(r.keptPast, "8.44: mudar a mensalidade não mexe no mês que já foi pago");
      check(r.xss, "8.44: pedido do aluno vira texto simples");
      check(r.stays, "8.44: \"Dados diferentes\" não fecha tocando fora");
      check(!errs.length, "8.44: nenhum erro" + (errs.length ? " → " + errs[0] : ""));
      await p.close(); }
    // 3. Planos
    { const { p, errs } = await page(browser, base);
      const today = new Date().toISOString().slice(0, 10);
      const r = await p.evaluate(async today => {
        hideAuthGate(); authCurrentUser = { id: "u1", email: "t@x.com" };
        const out = {};
        window.__rpc = n => n === "hi_my_plan" ? { data: { plan: "trial", trial_until: today, today }, error: null } : { data: null, error: null };
        await planStart();
        out.trialEnd = document.querySelector("#planGate h1") && document.querySelector("#planGate h1").textContent;
        document.getElementById("planClose").click();
        myPlan = { plan: "trial", trial_until: "2020-01-01", today };
        openPlans(true);
        out.mustClose = !!document.getElementById("planClose");
        myPlan = { plan: "free", today }; document.getElementById("planGate").classList.add("hidden");
        out.limit = planCanAdd(1);
        myPlan = { plan: "silver", paid_until: "2999-01-01", today }; renderProfessorTier();
        out.tier = document.getElementById("profileTierLine").textContent;
        out.canAdd = planCanAdd(1);
        myPlan = { admin: true, plan: "trial", today };
        window.__rpc = n => n === "hi_admin_plans" ? { data: [{ id: "a", email: "a@x.com", name: "Ana", plan: "silver", paid_until: "2999-01-01", students: 10, created_at: today }], error: null } : { data: null, error: null };
        await openPlanAdmin(); await new Promise(r => setTimeout(r, 200));
        out.adminStats = document.querySelectorAll(".adm-stat").length;
        return out;
      }, today).catch(e => ({ err: e.message }));
      check(r.trialEnd === "Seu teste grátis termina hoje", "planos: no último dia do teste abre a tela dos planos");
      check(r.mustClose === false, "planos: com o teste acabado a tela não fecha sem escolher");
      check(r.limit === false, "planos: o Grátis não deixa passar de 5 alunos");
      check(/Prata/.test(r.tier || "") && r.canAdd === true, "planos: Prata mostra o nível e deixa cadastrar");
      check(r.adminStats >= 4, "planos: a tela Assinaturas mostra os números");
      check(!errs.length && !r.err, "planos: nenhum erro" + (errs.length || r.err ? " → " + (r.err || errs[0]) : ""));
      await p.close(); }
    // 4. Inglês
    { const { p, errs } = await page(browser, base + "?lang=en", { seed: false });
      const t = await p.evaluate(() => [document.documentElement.lang, document.getElementById("authForgotBtn").textContent, document.getElementById("authLang").textContent]);
      check(t[0] === "en" && t[1] === "I forgot my password" && /português/.test(t[2]), "inglês: o login aparece em inglês");
      check(!errs.length, "inglês: login sem erro" + (errs.length ? " → " + errs[0] : ""));
      await p.close(); }
    { const { p, errs } = await page(browser, base + "?lang=en");
      await p.evaluate(() => hideAuthGate()).catch(() => {});
      const pages = await p.evaluate(() => [...new Set([...document.querySelectorAll("[data-page]")].map(e => e.dataset.page))]);
      for (const pg of pages) { await p.evaluate(pg => openPage(pg), pg).catch(e => errs.push(pg + ": " + e.message)); await p.waitForTimeout(100); }
      const home = await p.evaluate(() => { openPage("settings"); return document.getElementById("valLang").textContent; });
      check(home === "English", "inglês: Configurações mostra o idioma");
      check(!errs.length, "inglês: páginas sem erro" + (errs.length ? " → " + errs.slice(0, 3).join(" | ") : ""));
      await p.close(); }
    { const { p } = await page(browser, base + "?lang=pt", { seed: false });
      check(await p.evaluate(() => document.documentElement.lang === "pt-BR" && document.getElementById("authForgotBtn").textContent === "Esqueci minha senha" && typeof window.hiTrTree === "undefined"), "português: continua igual (sem tradução carregada)");
      await p.close(); }
  } finally {
    await browser.close();
    server.close();
  }
  if (failures.length) { console.log(`\n${failures.length} falha(s).`); process.exit(1); }
  console.log("\nTudo certo.");
})().catch(e => { console.error(e); process.exit(1); });
