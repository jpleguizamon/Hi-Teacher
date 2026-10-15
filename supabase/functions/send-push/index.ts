// Hi Teacher 8.14 (+ app Android 8.31) — envio de notificações no celular (push).
//
// O app NÃO diz para quem enviar: manda só o tipo do evento e o id do registro. Esta função
// confere no banco quem é o autor (pelo login) e calcula sozinha quem recebe:
//   - recado do aluno (request) / pedido de entrada (join)  → o professor dele
//   - resposta do professor (answer)                         → quem mandou o recado
//   - aula cancelada/remarcada (lesson), reposição (makeup),
//     aviso do professor (announcement), mensalidade (late)  → os alunos/responsáveis ligados
//   - teste (test)                                           → a própria pessoa
// Texto sem dados sensíveis (sem valores, notas ou motivos).
// Limite: 30 envios por minuto por pessoa. Aparelho que o serviço de push diz que não existe
// mais (404/410) é removido.
//
// App Android próprio (8.31): o aparelho com o app instalado é guardado com o código do Firebase
// (endereço começando com FCM_PREFIX) e recebe pelo Firebase; o resto continua pelo push do navegador.
//
// Segredos (Supabase → Edge Functions → Secrets): VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY e
// VAPID_SUBJECT (ex.: mailto:seu-email); para o app Android, FCM_SERVICE_ACCOUNT (o arquivo da
// "conta de serviço" do Firebase, inteiro). SUPABASE_URL e SUPABASE_SERVICE_ROLE_KEY o Supabase
// já fornece sozinho. Passo a passo no HI-TEACHER.md, seção 8.14.
import webpush from "npm:web-push@3.6.7";
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const VAPID_PUBLIC = Deno.env.get("VAPID_PUBLIC_KEY") ?? "";
const VAPID_PRIVATE = Deno.env.get("VAPID_PRIVATE_KEY") ?? "";
const VAPID_SUBJECT = Deno.env.get("VAPID_SUBJECT") ?? "mailto:contato@hiteacher.app";
const FCM_SA = Deno.env.get("FCM_SERVICE_ACCOUNT") ?? "";
const RATE_PER_MIN = 30;
export const FCM_PREFIX = "https://fcm.googleapis.com/hi-teacher-app/";

// ---------- Firebase (app Android) ----------
const b64url = (b: Uint8Array | string) => btoa(typeof b === "string" ? b : String.fromCharCode(...b)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
let fcmAuth: { token: string; exp: number; project: string } | null = null;
async function fcmAccess(): Promise<{ token: string; project: string }> {
  if (fcmAuth && fcmAuth.exp > Date.now() + 60_000) return fcmAuth;
  if (!FCM_SA) throw Object.assign(new Error("Falta a chave do Firebase (FCM_SERVICE_ACCOUNT) nos segredos da função"), { statusCode: 500 });
  const sa = JSON.parse(FCM_SA);
  const now = Math.floor(Date.now() / 1000);
  const head = b64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const claim = b64url(JSON.stringify({ iss: sa.client_email, scope: "https://www.googleapis.com/auth/firebase.messaging", aud: "https://oauth2.googleapis.com/token", iat: now, exp: now + 3600 }));
  const der = Uint8Array.from(atob(String(sa.private_key).replace(/-----[^-]+-----/g, "").replace(/\s+/g, "")), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey("pkcs8", der, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"]);
  const sig = new Uint8Array(await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(`${head}.${claim}`)));
  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion: `${head}.${claim}.${b64url(sig)}` }),
  });
  const j = await res.json().catch(() => ({}));
  if (!res.ok || !j.access_token) throw Object.assign(new Error(`Firebase recusou a chave: ${j.error_description ?? j.error ?? res.status}`), { statusCode: 401 });
  fcmAuth = { token: j.access_token, exp: Date.now() + (Number(j.expires_in) || 3600) * 1000, project: sa.project_id };
  return fcmAuth;
}
// Manda só dados: o próprio app monta a notificação (título, texto e a página que abre ao tocar).
export async function sendFcm(endpoint: string, payload: string): Promise<{ statusCode: number }> {
  const { token, project } = await fcmAccess();
  const p = JSON.parse(payload);
  const page = /[?&]p=([a-z]+)/.exec(String(p.url ?? ""))?.[1] ?? "";
  const res = await fetch(`https://fcm.googleapis.com/v1/projects/${project}/messages:send`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify({ message: { token: endpoint.slice(FCM_PREFIX.length), data: { title: String(p.title ?? ""), body: String(p.body ?? ""), page, tag: String(p.tag ?? "") }, android: { priority: "HIGH", ttl: "86400s" } } }),
  });
  if (res.ok) return { statusCode: res.status };
  const body = await res.text();
  // Aparelho que desinstalou o app ou trocou de código: o Firebase diz UNREGISTERED (404).
  const gone = res.status === 404 || /UNREGISTERED|registration-token-not-registered/.test(body);
  throw Object.assign(new Error(body.slice(0, 200)), { statusCode: gone ? 410 : res.status, body: body.slice(0, 200) });
}

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};
const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

type Recipient = { user_id: string; student?: boolean };
type Plan = { recipients: Recipient[]; title: string; body: string; url: string; pref: string; dedupe?: string; weekly?: boolean };

const firstName = (n: unknown) => String(n ?? "").trim().split(/\s+/)[0] || "Aluno";
const ddmm = (iso: unknown) => { const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(iso ?? "")); return m ? `${m[3]}/${m[2]}` : ""; };
const brToDdmm = (br: unknown) => { const m = /^(\d{2})\/(\d{2})/.exec(String(br ?? "")); return m ? `${m[1]}/${m[2]}` : ""; };

// Hora em São Paulo (para "Não enviar das 22h às 7h").
function spHour(now = new Date()): number {
  return Number(new Intl.DateTimeFormat("en-US", { timeZone: "America/Sao_Paulo", hour: "numeric", hour12: false }).format(now)) % 24;
}

// deno-lint-ignore no-explicit-any
type DB = any;

async function linkedUsers(db: DB, studentIds: string[]): Promise<Recipient[]> {
  if (!studentIds.length) return [];
  const { data } = await db.from("student_links").select("user_id").in("student_id", studentIds);
  const seen = new Set<string>();
  return (data ?? []).filter((l: { user_id: string }) => !seen.has(l.user_id) && seen.add(l.user_id)).map((l: { user_id: string }) => ({ user_id: l.user_id, student: true }));
}

async function teacherName(db: DB, teacherId: string): Promise<string> {
  const { data } = await db.from("teacher_public").select("display_name").eq("teacher_id", teacherId).maybeSingle();
  return (data?.display_name || "professor").trim();
}

// Monta o envio conferindo que quem chamou pode disparar esse evento. Devolve null se não pode.
export async function plan(db: DB, uid: string, type: string, id: string): Promise<Plan | { error: string; status: number }> {
  const notFound = { error: "Registro não encontrado", status: 404 };
  const denied = { error: "Sem permissão para este evento", status: 403 };
  if (type === "test") {
    return { recipients: [{ user_id: uid }], title: "Notificações ativas", body: "Teste enviado com sucesso.", url: "./", pref: "test" };
  }
  if (type === "request" || type === "answer") {
    const { data: r } = await db.from("student_requests").select("id, student_id, author_user_id, type, payload, status").eq("id", id).maybeSingle();
    if (!r) return notFound;
    const { data: s } = await db.from("students").select("id, name, teacher_id").eq("id", r.student_id).maybeSingle();
    if (!s) return notFound;
    if (type === "answer") {
      if (s.teacher_id !== uid) return denied;
      if (!["accepted", "rejected"].includes(r.status)) return { error: "Recado ainda sem resposta", status: 409 };
      return { recipients: [{ user_id: r.author_user_id, student: true }], title: "Resposta do professor", body: "O professor respondeu ao seu recado.", url: "./?p=inicio", pref: "answer", dedupe: `answer:${r.id}` };
    }
    if (r.author_user_id !== uid) return denied;
    const n = firstName(s.name), p = r.payload ?? {};
    const texts: Record<string, [string, string]> = {
      absence: [`${n} avisou que vai faltar${p.date ? ` na aula de ${brToDdmm(p.date)}` : ""}`, "absence"],
      payment_notice: [`${n} avisou que pagou`, "payment"],
      change_data: [`${n} pediu uma alteração nos dados`, "change"],
      reschedule: [`${n} pediu para remarcar${p.date ? ` a aula de ${brToDdmm(p.date)}` : " uma aula"}`, "resched"],
      makeup_request: [`${n} escolheu um horário de reposição`, "resched"],
      delete_data: [`${n} pediu para apagar os dados`, "change"],
    };
    const t = texts[r.type];
    if (!t) return { error: "Este tipo de recado não gera notificação", status: 422 };
    return { recipients: [{ user_id: s.teacher_id }], title: "Novo recado", body: t[0], url: "./?p=inicio", pref: t[1], dedupe: `request:${r.id}` };
  }
  if (type === "join") {
    const { data: j } = await db.from("join_requests").select("id, user_id, teacher_id, student_name, status").eq("id", id).maybeSingle();
    if (!j) return notFound;
    if (j.user_id !== uid) return denied;
    if (j.status !== "pending") return { error: "Pedido não está pendente", status: 409 };
    return { recipients: [{ user_id: j.teacher_id }], title: "Pedido de entrada", body: `${firstName(j.student_name)} quer entrar`, url: "./?p=inicio", pref: "join", dedupe: `join:${j.id}` };
  }
  if (type === "lesson") {
    const { data: l } = await db.from("lessons").select("id, student_id, teacher_id, date, status, reason, deleted").eq("id", id).maybeSingle();
    if (!l || l.deleted) return notFound;
    if (l.teacher_id !== uid) return denied;
    if (l.status !== "noclass") return { error: "Aula sem mudança para avisar", status: 422 };
    const verb = l.reason === "rescheduled" ? "foi remarcada" : "foi cancelada";
    const title = l.reason === "rescheduled" ? "Aula remarcada" : "Aula cancelada";
    return { recipients: await linkedUsers(db, [l.student_id]), title, body: `Sua aula de ${ddmm(l.date)} ${verb}`, url: "./?p=aulas", pref: "lesson", dedupe: `lesson:${l.id}:${l.status}:${l.reason ?? ""}` };
  }
  if (type === "makeup") {
    const { data: m } = await db.from("makeups").select("id, student_id, teacher_id, date, time, status, deleted").eq("id", id).maybeSingle();
    if (!m || m.deleted) return notFound;
    if (m.teacher_id !== uid) return denied;
    if (!m.date) return { error: "Reposição sem data", status: 422 };
    return { recipients: await linkedUsers(db, [m.student_id]), title: "Reposição marcada", body: `${ddmm(m.date)}${m.time ? ` às ${m.time}` : ""}`, url: "./?p=aulas", pref: "lesson", dedupe: `makeup:${m.id}:${m.date}:${m.time ?? ""}` };
  }
  if (type === "announcement") {
    const { data: a } = await db.from("announcements").select("id, teacher_id, push").eq("id", id).maybeSingle();
    if (!a) return notFound;
    if (a.teacher_id !== uid) return denied;
    if (!a.push) return { error: "Aviso sem notificação", status: 422 };
    const { data: t } = await db.from("announcement_targets").select("student_id").eq("announcement_id", a.id);
    const name = await teacherName(db, uid);
    return { recipients: await linkedUsers(db, (t ?? []).map((x: { student_id: string }) => x.student_id)), title: `Aviso de ${name}`, body: "Novo aviso do seu professor", url: "./?p=avisos", pref: "announcement", dedupe: `announcement:${a.id}` };
  }
  if (type === "late") {
    const { data: s } = await db.from("students").select("id, teacher_id, deleted").eq("id", id).maybeSingle();
    if (!s || s.deleted) return notFound;
    if (s.teacher_id !== uid) return denied;
    return { recipients: await linkedUsers(db, [s.id]), title: "Mensalidade em atraso", body: "Confira o financeiro", url: "./?p=financeiro", pref: "late", dedupe: `late:${s.id}`, weekly: true };
  }
  return { error: "Tipo de evento desconhecido", status: 400 };
}

// Quem quer receber agora: preferências por tipo e horário silencioso (padrão ligado para
// aluno/responsável; o aviso continua no sino do app).
export async function filterByPrefs(db: DB, recipients: Recipient[], pref: string, hour = spHour()): Promise<Recipient[]> {
  if (!recipients.length || pref === "test") return recipients;
  const { data } = await db.from("notify_prefs").select("user_id, prefs").in("user_id", recipients.map((r) => r.user_id));
  const by = new Map((data ?? []).map((p: { user_id: string; prefs: Record<string, unknown> }) => [p.user_id, p.prefs ?? {}]));
  const night = hour >= 22 || hour < 7;
  return recipients.filter((r) => {
    const p = (by.get(r.user_id) ?? {}) as Record<string, unknown>;
    if (p[pref] === false) return false;
    const quiet = p.quiet === undefined ? !!r.student : p.quiet === true;
    return !(quiet && night);
  });
}

// deno-lint-ignore no-explicit-any
export async function handle(req: Request, deps: { db: DB; send: (sub: any, payload: string) => Promise<{ statusCode: number }>; getUser: (jwt: string) => Promise<string | null>; now?: Date }): Promise<Response> {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method === "GET") return json(200, { publicKey: VAPID_PUBLIC });
  if (req.method !== "POST") return json(405, { error: "Método não permitido" });
  const jwt = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  const uid = jwt ? await deps.getUser(jwt) : null;
  if (!uid) return json(401, { error: "Entre na sua conta" });
  let body: { type?: string; id?: string };
  try { body = await req.json(); } catch { return json(400, { error: "Corpo inválido" }); }
  const type = String(body.type ?? ""), id = String(body.id ?? "");
  if (!/^[a-z_]{2,20}$/.test(type) || (type !== "test" && !/^[0-9a-f-]{36}$/i.test(id))) return json(400, { error: "Evento inválido" });
  const db = deps.db, now = deps.now ?? new Date();

  // Limite por minuto (conta toda chamada, permitida ou não).
  const since = new Date(now.getTime() - 60_000).toISOString();
  const { count } = await db.from("push_log").select("id", { count: "exact", head: true }).eq("sender", uid).neq("kind", "sent").gte("created_at", since);
  if ((count ?? 0) >= RATE_PER_MIN) return json(429, { error: "Muitas notificações seguidas. Espere um minuto." });
  const { data: logRow } = await db.from("push_log").insert({ sender: uid, kind: type, ref: id || null, created_at: now.toISOString() }).select("id").single();

  const p = await plan(db, uid, type, id);
  if ("error" in p) return json(p.status, { error: p.error });

  // Não repete o mesmo evento (e a mensalidade, no máximo 1 por semana por aluno).
  if (p.dedupe) {
    let q = db.from("push_log").select("id").eq("kind", "sent").eq("ref", p.dedupe);
    if (p.weekly) q = q.gte("created_at", new Date(now.getTime() - 7 * 86400_000).toISOString());
    const { data: done } = await q.limit(1);
    if (done && done.length) return json(200, { ok: true, sent: 0, skipped: "already_sent" });
  }

  const recipients = await filterByPrefs(db, p.recipients, p.pref, spHour(now));
  let sent = 0, removed = 0, devices = 0, dbError = "";
  const failures: { code: number; msg: string }[] = [];
  if (recipients.length) {
    const { data: subs, error: subsErr } = await db.from("push_subscriptions").select("id, endpoint, p256dh, auth").in("user_id", recipients.map((r) => r.user_id)).eq("active", true);
    if (subsErr) { dbError = String(subsErr.message ?? subsErr).slice(0, 200); console.error("push_subscriptions", dbError); }
    devices = (subs ?? []).length;
    const payload = JSON.stringify({ title: p.title, body: p.body, url: p.url, tag: p.dedupe ?? type });
    for (const s of subs ?? []) {
      try {
        await deps.send({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, payload);
        sent++;
        await db.from("push_subscriptions").update({ last_ok_at: now.toISOString() }).eq("id", s.id);
      } catch (e) {
        const code = (e as { statusCode?: number }).statusCode ?? 0;
        if (code === 404 || code === 410) { await db.from("push_subscriptions").delete().eq("id", s.id); removed++; }
        const msg = String((e as { body?: string }).body ?? (e as Error).message ?? e).slice(0, 200);
        failures.push({ code, msg });
        if (code !== 404 && code !== 410) console.error("push falhou", code, msg);
      }
    }
  }
  if (p.dedupe && type !== "test") await db.from("push_log").insert({ sender: uid, kind: "sent", ref: p.dedupe, sent, created_at: now.toISOString() });
  if (logRow) await db.from("push_log").update({ sent }).eq("id", logRow.id);
  // No teste, devolve o diagnóstico pro app explicar o que deu errado.
  if (type === "test") return json(200, { ok: true, sent, removed, devices, failures, dbError, vapid: !!(VAPID_PUBLIC && VAPID_PRIVATE), fcm: !!FCM_SA });
  return json(200, { ok: true, sent, removed });
}

if (import.meta.main) {
  const admin = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
  if (VAPID_PUBLIC && VAPID_PRIVATE) webpush.setVapidDetails(VAPID_SUBJECT, VAPID_PUBLIC, VAPID_PRIVATE);
  Deno.serve((req) => handle(req, {
    db: admin,
    // deno-lint-ignore no-explicit-any
    send: (sub: any, payload: string) => {
      if (String(sub.endpoint).startsWith(FCM_PREFIX)) return sendFcm(sub.endpoint, payload);
      if (!VAPID_PUBLIC || !VAPID_PRIVATE) return Promise.reject(Object.assign(new Error("Faltam as chaves VAPID nos segredos da função"), { statusCode: 500 }));
      return webpush.sendNotification(sub, payload, { TTL: 86400, urgency: "normal" });
    },
    getUser: async (jwt: string) => { const { data, error } = await admin.auth.getUser(jwt); return error || !data?.user ? null : data.user.id; },
  }));
}
