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
// A chave nunca volta para o app. Quem chama precisa estar logado (menos o aviso do Asaas, que vem com o
// código secreto do professor no cabeçalho asaas-access-token).
//
// Publicar com "Verify JWT" DESLIGADO (o Asaas não manda o login do Supabase); a função confere o login sozinha.
// Segredos (Supabase → Edge Functions → Secrets): ASAAS_SECRET (um texto longo qualquer, só seu).
// SUPABASE_URL, SUPABASE_ANON_KEY e SUPABASE_SERVICE_ROLE_KEY o Supabase já fornece. Passo a passo no HI-TEACHER.md, seção 8.50.
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const SECRET = Deno.env.get("ASAAS_SECRET") ?? "";
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

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "method" }, 405);
  if (!SECRET || SECRET.length < 16) return json({ error: "Falta o segredo ASAAS_SECRET na função (Supabase → Edge Functions → Secrets)." }, 500);
  try {
    const hookFor = new URL(req.url).searchParams.get("hook");
    if (hookFor) return /^[0-9a-f-]{36}$/.test(hookFor) ? await hook(hookFor, req) : json({ error: "forbidden" }, 401);
    const jwt = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
    const { data: u } = await createClient(SUPABASE_URL, ANON_KEY, { auth: { persistSession: false } }).auth.getUser(jwt);
    if (!u?.user) return json({ error: "Entre na sua conta antes" }, 401);
    const b = await req.json().catch(() => ({}));
    if (b.action === "connect") return await connect(u.user.id, u.user.email ?? "", b);
    if (b.action === "disconnect") return await disconnect(u.user.id);
    if (b.action === "charge") return await charge(u.user.id, b);
    if (b.action === "cancel") return await cancel(u.user.id, b);
    return json({ error: "Ação inválida" }, 400);
  } catch (e) {
    return json({ error: `Não deu certo agora: ${(e as Error).message}` }, 500);
  }
});
