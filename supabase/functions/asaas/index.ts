// Hi Teacher 8.50 — cobrança automática pelo Asaas.
//
// Cada professor liga a própria conta do Asaas (cola a chave de API no app). O dinheiro cai direto
// na conta dele; o Hi Teacher não passa pelo meio. Esta função:
//   - connect:    confere a chave, guarda trancada (AES-GCM com o segredo ASAAS_SECRET) e cadastra o aviso
//                 de pagamento (webhook) na conta do professor;
//   - disconnect: tira o aviso e apaga a chave;
//   - charge:     gera a cobrança do mês de cada aluno (Pix, boleto ou cartão: o aluno escolhe na página);
//   - cancel:     apaga uma cobrança que ainda não foi paga;
//   - aviso do Asaas (?hook=<professor>): marca a cobrança como paga, vencida ou apagada. O app lê e dá baixa.
// Planos do app (conta do Asaas do DONO do app, segredo ASAAS_HI_KEY):
//   - plan_status / plan_checkout / plan_cancel: assinatura mensal do plano do professor (Pix, boleto ou cartão);
//   - plan_setup (só o dono do app): cadastra o aviso de pagamento dos planos na conta dele;
//   - aviso do Asaas (?plan=1): fatura paga → plano ativado por 1 mês (uma vez por pagamento).
// A chave nunca volta para o app. Quem chama precisa estar logado (menos o aviso do Asaas, que vem com o
// código secreto do professor no cabeçalho asaas-access-token).
//
// Publicar com "Verify JWT" DESLIGADO (o Asaas não manda o login do Supabase); a função confere o login sozinha.
// Segredos (Supabase → Edge Functions → Secrets): ASAAS_SECRET (um texto longo qualquer, só seu).
// Para os planos: ASAAS_HI_KEY (chave de API da conta do Asaas do dono do app) e, para testar,
// ASAAS_HI_SANDBOX = true. Sem ASAAS_HI_KEY, o app continua pedindo o plano por e-mail, como antes.
// SUPABASE_URL, SUPABASE_ANON_KEY e SUPABASE_SERVICE_ROLE_KEY o Supabase já fornece. Passo a passo no HI-TEACHER.md, seção 8.50.
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const SECRET = Deno.env.get("ASAAS_SECRET") ?? "";
const HI_KEY = Deno.env.get("ASAAS_HI_KEY") ?? "";
const HI_SANDBOX = /^(1|true|sim)$/i.test(Deno.env.get("ASAAS_HI_SANDBOX") ?? "");
// Preço de cada plano (R$ por mês). Tem de ser igual ao PLANS do app (index.html).
const PLAN_PRICES: Record<string, { name: string; value: number }> = { bronze: { name: "Bronze", value: 29 }, silver: { name: "Prata", value: 49 }, gold: { name: "Ouro", value: 79 } };
const PROD = "https://api.asaas.com/v3", SANDBOX = "https://api-sandbox.asaas.com/v3";
const HOOK_EVENTS = ["PAYMENT_RECEIVED", "PAYMENT_CONFIRMED", "PAYMENT_OVERDUE", "PAYMENT_DELETED", "PAYMENT_RESTORED", "PAYMENT_REFUNDED"];
const MAX_ITEMS = 60;

const CORS = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { ...CORS, "Content-Type": "application/json" } });
const db = () => createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } });

// ---------- chave trancada ----------
const enc = new TextEncoder(), dec = new TextDecoder();
async function aesKey() {
  const h = await crypto.subtle.digest("SHA-256", enc.encode(SECRET));
  return crypto.subtle.importKey("raw", h, "AES-GCM", false, ["encrypt", "decrypt"]);
}
const b64 = (u: Uint8Array) => btoa(String.fromCharCode(...u));
const unb64 = (s: string) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
export async function lock(text: string) {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ct = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv }, await aesKey(), enc.encode(text)));
  return b64(iv) + "." + b64(ct);
}
export async function unlock(s: string) {
  const [iv, ct] = s.split(".");
  return dec.decode(await crypto.subtle.decrypt({ name: "AES-GCM", iv: unb64(iv) }, await aesKey(), unb64(ct)));
}

// ---------- Asaas ----------
type Acc = { key: string; sandbox: boolean };
async function asaas(acc: Acc, method: string, path: string, body?: unknown) {
  const res = await fetch((acc.sandbox ? SANDBOX : PROD) + path, {
    method,
    headers: { "access_token": acc.key, "Content-Type": "application/json", "User-Agent": "HiTeacher/8.50" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const j = await res.json().catch(() => ({}));
  if (!res.ok) {
    const msg = (j?.errors ?? []).map((e: { description?: string }) => e.description).filter(Boolean).join(" ") || `Asaas respondeu ${res.status}`;
    throw Object.assign(new Error(msg), { status: res.status });
  }
  return j;
}
const onlyDigits = (s: unknown) => String(s ?? "").replace(/\D/g, "");
const isoToday = () => new Date(Date.now() - 3 * 3600_000).toISOString().slice(0, 10); // dia em Brasília

async function account(teacher: string): Promise<(Acc & { row: Record<string, unknown> }) | null> {
  const { data } = await db().from("asaas_accounts").select("*").eq("teacher_id", teacher).maybeSingle();
  if (!data) return null;
  return { key: await unlock(String(data.api_key_enc)), sandbox: !!data.sandbox, row: data };
}

// ---------- ações do professor ----------
async function connect(teacher: string, email: string, b: Record<string, unknown>) {
  const key = String(b.apiKey ?? "").trim();
  const sandbox = !!b.sandbox;
  if (key.length < 20 || key.length > 400) return json({ error: "Chave de API inválida. Copie de novo no Asaas (Integrações → Chave de API)." }, 400);
  const acc = { key, sandbox };
  let name = "";
  try {
    await asaas(acc, "GET", "/finance/balance");
    const info = await asaas(acc, "GET", "/myAccount/commercialInfo").catch(() => ({}));
    name = String(info?.name ?? info?.companyName ?? "").slice(0, 120);
  } catch (e) {
    const st = (e as { status?: number }).status;
    return json({ error: st === 401 ? `O Asaas não aceitou a chave. Confira se ela é da conta ${sandbox ? "de teste (sandbox)" : "de verdade"}.` : `Não consegui falar com o Asaas: ${(e as Error).message}` }, 400);
  }
  const old = await account(teacher).catch(() => null);
  if (old?.row?.hook_id) await asaas(old, "DELETE", `/webhooks/${old.row.hook_id}`).catch(() => {});
  const hookToken = b64(crypto.getRandomValues(new Uint8Array(30)));
  let hookId = null;
  try {
    const h = await asaas(acc, "POST", "/webhooks", {
      name: "Hi Teacher", url: `${SUPABASE_URL}/functions/v1/asaas?hook=${teacher}`, email: email || undefined,
      enabled: true, interrupted: false, apiVersion: 3, sendType: "SEQUENTIALLY", authToken: hookToken, events: HOOK_EVENTS,
    });
    hookId = h?.id ?? null;
  } catch (e) {
    return json({ error: `O Asaas aceitou a chave, mas não deixou cadastrar o aviso de pagamento: ${(e as Error).message}` }, 400);
  }
  const { error } = await db().from("asaas_accounts").upsert({
    teacher_id: teacher, api_key_enc: await lock(key), sandbox, hook_token: hookToken, hook_id: hookId, account_name: name || null, updated_at: new Date().toISOString(),
  });
  if (error) return json({ error: "Não consegui guardar a conta. Confira se o arquivo 8.50 foi rodado no servidor." }, 500);
  return json({ ok: true, name, sandbox });
}

async function disconnect(teacher: string) {
  const acc = await account(teacher).catch(() => null);
  if (acc?.row?.hook_id) await asaas(acc, "DELETE", `/webhooks/${acc.row.hook_id}`).catch(() => {});
  await db().from("asaas_accounts").delete().eq("teacher_id", teacher);
  return json({ ok: true });
}

type Item = { student_uuid: string; month: string; value: number; due_date: string; name: string; doc: string; phone?: string; email?: string; description?: string; fine?: number; interest?: number; discount?: { value: number; type: string; days: number } };
async function charge(teacher: string, b: Record<string, unknown>) {
  const acc = await account(teacher);
  if (!acc) return json({ error: "Ligue a sua conta do Asaas antes (Configurações → Cobrança automática)." }, 400);
  const items = (Array.isArray(b.items) ? b.items : []).slice(0, MAX_ITEMS) as Item[];
  const today = isoToday();
  const out = [];
  for (const it of items) {
    const r: Record<string, unknown> = { student_uuid: it.student_uuid, month: it.month };
    try {
      if (!/^[0-9a-f-]{36}$/.test(String(it.student_uuid)) || !/^\d{4}-\d{2}$/.test(String(it.month))) throw new Error("Pedido inválido.");
      const value = Math.round(Number(it.value) * 100) / 100;
      if (!(value >= 5 && value <= 100000)) throw new Error("O valor precisa ser de pelo menos R$ 5,00.");
      const doc = onlyDigits(it.doc);
      if (doc.length !== 11 && doc.length !== 14) throw new Error("Falta o CPF de quem paga (no cadastro do aluno).");
      // Já existe cobrança aberta ou paga para este aluno e mês: devolve a mesma.
      const { data: old } = await db().from("asaas_charges").select("*").eq("teacher_id", teacher).eq("student_uuid", it.student_uuid).eq("month", it.month).in("status", ["open", "overdue", "paid"]).limit(1);
      if (old && old.length) { out.push({ ...r, ...old[0], reused: true }); continue; }
      // Cliente (quem paga).
      const { data: cust } = await db().from("asaas_customers").select("*").eq("teacher_id", teacher).eq("student_uuid", it.student_uuid).maybeSingle();
      let customer = cust && cust.doc === doc ? String(cust.customer_id) : "";
      if (!customer) {
        const phone = onlyDigits(it.phone);
        const c = await asaas(acc, "POST", "/customers", {
          name: String(it.name ?? "").slice(0, 100) || "Aluno", cpfCnpj: doc, externalReference: it.student_uuid,
          ...(phone.length >= 10 && phone.length <= 11 ? { mobilePhone: phone } : {}), ...(it.email ? { email: String(it.email).slice(0, 120) } : {}),
          notificationDisabled: true,
        });
        customer = String(c.id);
        await db().from("asaas_customers").upsert({ teacher_id: teacher, student_uuid: it.student_uuid, customer_id: customer, doc });
      }
      const due = String(it.due_date) >= today ? String(it.due_date) : today;
      const late = String(it.due_date) < today;
      const p = await asaas(acc, "POST", "/payments", {
        customer, billingType: "UNDEFINED", value, dueDate: due,
        description: String(it.description ?? "").slice(0, 500), externalReference: `${it.student_uuid}|${it.month}`,
        ...(!late && Number(it.fine) > 0 ? { fine: { value: Number(it.fine), type: "PERCENTAGE" } } : {}),
        ...(!late && Number(it.interest) > 0 ? { interest: { value: Number(it.interest) } } : {}),
        ...(!late && it.discount && Number(it.discount.value) > 0 ? { discount: { value: Number(it.discount.value), dueDateLimitDays: Math.max(0, Number(it.discount.days) || 0), type: it.discount.type === "pct" ? "PERCENTAGE" : "FIXED" } } : {}),
      });
      const row = { id: String(p.id), teacher_id: teacher, student_uuid: it.student_uuid, month: it.month, value, due_date: due, status: "open", invoice_url: p.invoiceUrl ?? null };
      await db().from("asaas_charges").upsert(row);
      out.push({ ...r, ...row });
    } catch (e) {
      out.push({ ...r, error: (e as Error).message });
    }
  }
  return json({ ok: true, items: out });
}

async function cancel(teacher: string, b: Record<string, unknown>) {
  const acc = await account(teacher);
  if (!acc) return json({ error: "Conta do Asaas não ligada." }, 400);
  const id = String(b.id ?? "");
  const { data: row } = await db().from("asaas_charges").select("*").eq("teacher_id", teacher).eq("id", id).maybeSingle();
  if (!row) return json({ error: "Cobrança não encontrada." }, 404);
  if (row.status === "paid") return json({ error: "Esta cobrança já foi paga. Para devolver o dinheiro, faça o estorno no Asaas." }, 400);
  await asaas(acc, "DELETE", `/payments/${id}`).catch((e) => { if ((e as { status?: number }).status !== 404) throw e; });
  await db().from("asaas_charges").update({ status: "deleted", updated_at: new Date().toISOString() }).eq("id", id);
  return json({ ok: true });
}

// ---------- aviso do Asaas ----------
const STATUS: Record<string, string> = { PAYMENT_RECEIVED: "paid", PAYMENT_CONFIRMED: "paid", PAYMENT_OVERDUE: "overdue", PAYMENT_DELETED: "deleted", PAYMENT_RESTORED: "open", PAYMENT_REFUNDED: "refunded" };
async function hook(teacher: string, req: Request) {
  const { data: acc } = await db().from("asaas_accounts").select("hook_token").eq("teacher_id", teacher).maybeSingle();
  const token = req.headers.get("asaas-access-token") ?? "";
  if (!acc || !token || token !== acc.hook_token) return json({ error: "forbidden" }, 401);
  const ev = await req.json().catch(() => ({}));
  const st = STATUS[String(ev?.event ?? "")];
  const pay = ev?.payment;
  if (!st || !pay?.id) return json({ ok: true, ignored: true }); // outros avisos: responde 200 para o Asaas não parar a fila
  const { data: row } = await db().from("asaas_charges").select("status").eq("teacher_id", teacher).eq("id", String(pay.id)).maybeSingle();
  if (!row) return json({ ok: true, unknown: true }); // cobrança criada fora do app
  if (row.status === "paid" && st === "overdue") return json({ ok: true });
  const patch: Record<string, unknown> = { status: st, updated_at: new Date().toISOString() };
  if (st === "paid") {
    patch.paid_at = String(pay.clientPaymentDate ?? pay.paymentDate ?? isoToday()).slice(0, 10);
    if (pay.netValue != null) patch.net_value = Number(pay.netValue);
  }
  await db().from("asaas_charges").update(patch).eq("teacher_id", teacher).eq("id", String(pay.id));
  return json({ ok: true });
}

// ---------- planos do app (conta do dono do app) ----------
const hiAcc = (): Acc => ({ key: HI_KEY, sandbox: HI_SANDBOX });
async function planPending(subId: string) {
  const j = await asaas(hiAcc(), "GET", `/subscriptions/${subId}/payments?status=PENDING`).catch(() => null);
  const list = (j?.data ?? []).concat([]);
  if (!list.length) {
    const od = await asaas(hiAcc(), "GET", `/subscriptions/${subId}/payments?status=OVERDUE`).catch(() => null);
    list.push(...(od?.data ?? []));
  }
  list.sort((a: { dueDate: string }, b: { dueDate: string }) => String(a.dueDate).localeCompare(String(b.dueDate)));
  return list[0] ? { invoice_url: list[0].invoiceUrl ?? null, due_date: list[0].dueDate ?? null, value: list[0].value ?? null } : null;
}
async function planStatus(teacher: string, isAdmin: boolean) {
  if (!HI_KEY) return json({ on: false });
  const { data: sub } = await db().from("plan_subs").select("*").eq("teacher_id", teacher).maybeSingle();
  const out: Record<string, unknown> = { on: true, sandbox: HI_SANDBOX };
  if (sub && sub.status === "active" && sub.subscription_id) {
    out.sub = { plan: sub.plan, value: sub.value, since: sub.created_at ? String(sub.created_at).slice(0, 10) : null };
    out.pending = await planPending(String(sub.subscription_id));
  }
  if (isAdmin) { const { data: cfg } = await db().from("app_billing").select("hook_id").eq("id", 1).maybeSingle(); out.hook = !!cfg?.hook_id; }
  return json(out);
}
async function planCheckout(teacher: string, email: string, b: Record<string, unknown>) {
  if (!HI_KEY) return json({ off: true });
  const plan = String(b.plan ?? ""), price = PLAN_PRICES[plan];
  if (!price) return json({ error: "Plano inválido." }, 400);
  const doc = onlyDigits(b.doc);
  if (doc.length !== 11 && doc.length !== 14) return json({ error: "Falta o seu CPF (ou CNPJ). O Asaas pede para gerar a cobrança." }, 400);
  const acc = hiAcc();
  const { data: sub } = await db().from("plan_subs").select("*").eq("teacher_id", teacher).maybeSingle();
  // Mesmo plano já assinado: devolve a fatura em aberto.
  if (sub && sub.status === "active" && sub.subscription_id && sub.plan === plan) {
    const pend = await planPending(String(sub.subscription_id));
    return json({ ok: true, reused: true, url: pend?.invoice_url ?? null });
  }
  let customer = sub?.customer_id ? String(sub.customer_id) : "";
  if (!customer) {
    const c = await asaas(acc, "POST", "/customers", { name: String(b.name ?? "").slice(0, 100) || email || "Professor", cpfCnpj: doc, email: email || undefined, externalReference: teacher, notificationDisabled: false });
    customer = String(c.id);
  }
  // Trocou de plano: a assinatura antiga para (o tempo já pago continua valendo).
  if (sub?.subscription_id && sub.status === "active") await asaas(acc, "DELETE", `/subscriptions/${sub.subscription_id}`).catch(() => {});
  const s = await asaas(acc, "POST", "/subscriptions", {
    customer, billingType: "UNDEFINED", value: price.value, nextDueDate: isoToday(), cycle: "MONTHLY",
    description: `Hi Teacher · plano ${price.name}`, externalReference: `${teacher}|${plan}`,
  });
  await db().from("plan_subs").upsert({ teacher_id: teacher, customer_id: customer, subscription_id: String(s.id), plan, value: price.value, status: "active", updated_at: new Date().toISOString() });
  const pend = await planPending(String(s.id));
  return json({ ok: true, url: pend?.invoice_url ?? null });
}
async function planCancel(teacher: string) {
  if (!HI_KEY) return json({ off: true });
  const { data: sub } = await db().from("plan_subs").select("*").eq("teacher_id", teacher).maybeSingle();
  if (!sub?.subscription_id || sub.status !== "active") return json({ ok: true });
  await asaas(hiAcc(), "DELETE", `/subscriptions/${sub.subscription_id}`).catch((e) => { if ((e as { status?: number }).status !== 404) throw e; });
  await db().from("plan_subs").update({ status: "canceled", updated_at: new Date().toISOString() }).eq("teacher_id", teacher);
  return json({ ok: true });
}
async function planSetup(teacher: string, email: string) {
  if (!HI_KEY) return json({ error: "Falta o segredo ASAAS_HI_KEY na função (a chave da sua conta do Asaas)." }, 400);
  const { data: adm } = await db().from("app_admins").select("user_id").eq("user_id", teacher).maybeSingle();
  if (!adm) return json({ error: "Só o dono do app." }, 403);
  const { data: cfg } = await db().from("app_billing").select("*").eq("id", 1).maybeSingle();
  if (cfg?.hook_id) await asaas(hiAcc(), "DELETE", `/webhooks/${cfg.hook_id}`).catch(() => {});
  const token = b64(crypto.getRandomValues(new Uint8Array(30)));
  const h = await asaas(hiAcc(), "POST", "/webhooks", {
    name: "Hi Teacher · planos", url: `${SUPABASE_URL}/functions/v1/asaas?plan=1`, email: email || undefined,
    enabled: true, interrupted: false, apiVersion: 3, sendType: "SEQUENTIALLY", authToken: token, events: ["PAYMENT_RECEIVED", "PAYMENT_CONFIRMED"],
  });
  await db().from("app_billing").upsert({ id: 1, hook_token: token, hook_id: h?.id ?? null, updated_at: new Date().toISOString() });
  return json({ ok: true });
}
async function planHook(req: Request) {
  const { data: cfg } = await db().from("app_billing").select("hook_token").eq("id", 1).maybeSingle();
  const token = req.headers.get("asaas-access-token") ?? "";
  if (!cfg?.hook_token || token !== cfg.hook_token) return json({ error: "forbidden" }, 401);
  const ev = await req.json().catch(() => ({}));
  const pay = ev?.payment;
  if (!["PAYMENT_RECEIVED", "PAYMENT_CONFIRMED"].includes(String(ev?.event ?? "")) || !pay?.id || !pay?.subscription) return json({ ok: true, ignored: true });
  const { data: sub } = await db().from("plan_subs").select("*").eq("subscription_id", String(pay.subscription)).maybeSingle();
  if (!sub || !PLAN_PRICES[String(sub.plan)]) return json({ ok: true, unknown: true });
  const { error } = await db().rpc("hi_plan_activate", { p_teacher: sub.teacher_id, p_plan: sub.plan, p_months: 1, p_ref: String(pay.id) });
  if (error) return json({ error: error.message }, 500); // o Asaas tenta de novo
  return json({ ok: true });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "method" }, 405);
  if (!SECRET || SECRET.length < 16) return json({ error: "Falta o segredo ASAAS_SECRET na função (Supabase → Edge Functions → Secrets)." }, 500);
  try {
    const params = new URL(req.url).searchParams;
    if (params.get("plan") === "1") return await planHook(req);
    const hookFor = params.get("hook");
    if (hookFor) return /^[0-9a-f-]{36}$/.test(hookFor) ? await hook(hookFor, req) : json({ error: "forbidden" }, 401);
    const jwt = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
    const { data: u } = await createClient(SUPABASE_URL, ANON_KEY, { auth: { persistSession: false } }).auth.getUser(jwt);
    if (!u?.user) return json({ error: "Entre na sua conta antes" }, 401);
    const b = await req.json().catch(() => ({}));
    if (b.action === "plan_status") { const { data: adm } = await db().from("app_admins").select("user_id").eq("user_id", u.user.id).maybeSingle(); return await planStatus(u.user.id, !!adm); }
    if (b.action === "plan_checkout") return await planCheckout(u.user.id, u.user.email ?? "", b);
    if (b.action === "plan_cancel") return await planCancel(u.user.id);
    if (b.action === "plan_setup") return await planSetup(u.user.id, u.user.email ?? "");
    if (b.action === "connect") return await connect(u.user.id, u.user.email ?? "", b);
    if (b.action === "disconnect") return await disconnect(u.user.id);
    if (b.action === "charge") return await charge(u.user.id, b);
    if (b.action === "cancel") return await cancel(u.user.id, b);
    return json({ error: "Ação inválida" }, 400);
  } catch (e) {
    return json({ error: `Não deu certo agora: ${(e as Error).message}` }, 500);
  }
});
