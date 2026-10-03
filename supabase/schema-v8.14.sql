-- =====================================================================
-- Hi Teacher 8.14 — privacidade (LGPD), notificações no celular e avisos para os alunos
-- =====================================================================
-- Precisa da 8.0, 8.1, 8.1.1 e 8.3 instaladas antes.
-- Como rodar: Supabase → SQL Editor → New query → colar este arquivo inteiro → Run.
-- É seguro rodar mais de uma vez. Não apaga nenhum dado que já existe.
-- Sem este arquivo o app continua funcionando como antes: só ficam escondidos "Excluir
-- minha conta", as notificações no celular e os avisos para os alunos.
-- Explicação no HI-TEACHER.md, seção "8.14".

-- ---------------------------------------------------------------------
-- 1. Consentimento (Termos e Política de Privacidade)
-- ---------------------------------------------------------------------
-- Quando e qual versão do texto a pessoa aceitou. guardian_consent: "Sou o responsável legal
-- e autorizo o uso dos dados deste aluno" (obrigatório para menor de 18 ou pedido do responsável).
alter table public.join_requests add column if not exists consent_at timestamptz;
alter table public.join_requests add column if not exists consent_version text;
alter table public.join_requests add column if not exists guardian_consent boolean;
alter table public.student_links add column if not exists consent_at timestamptz;
alter table public.student_links add column if not exists consent_version text;

-- Pedido de entrada com o consentimento. O servidor confere as caixas (não dá para pular).
create or replace function public.hi_create_join_request_v2(p_code text, p_role text, p_student_name text,
  p_student_phone text default null, p_student_birth_date date default null, p_instrument text default null,
  p_guardian_name text default null, p_guardian_phone text default null,
  p_consent_version text default null, p_guardian_consent boolean default false)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  tid uuid;
  act boolean;
  rid uuid;
  minor boolean;
begin
  if coalesce(trim(p_consent_version), '') = '' then
    raise exception 'Marque "Li e concordo com os Termos e a Política de Privacidade"' using errcode = 'P0001';
  end if;
  minor := p_student_birth_date is not null and p_student_birth_date > (current_date - interval '18 years');
  if (p_role = 'guardian' or minor) and not coalesce(p_guardian_consent, false) then
    raise exception 'Falta a autorização do responsável legal' using errcode = 'P0001';
  end if;
  perform public.hi_code_attempt();
  select teacher_id, active into tid, act from public.teacher_codes where upper(code) = upper(trim(coalesce(p_code, '')));
  if tid is null then raise exception 'Chave não encontrada' using errcode = 'P0001'; end if;
  if not act then raise exception 'Este professor não está aceitando pedidos agora' using errcode = 'P0001'; end if;
  if tid = uid then raise exception 'Essa é a sua própria chave' using errcode = 'P0001'; end if;
  if coalesce(trim(p_student_name), '') = '' then raise exception 'Falta o nome do aluno' using errcode = 'P0001'; end if;
  insert into public.join_requests (teacher_id, user_id, role, student_name, student_phone, student_birth_date, instrument,
                                    guardian_name, guardian_phone, consent_at, consent_version, guardian_consent)
    values (tid, uid, case when p_role = 'guardian' then 'guardian' else 'student' end, trim(p_student_name),
            nullif(trim(p_student_phone), ''), p_student_birth_date, nullif(trim(p_instrument), ''),
            nullif(trim(p_guardian_name), ''), nullif(trim(p_guardian_phone), ''),
            now(), left(trim(p_consent_version), 20), coalesce(p_guardian_consent, false))
    returning id into rid;
  return rid;
end $$;
revoke execute on function public.hi_create_join_request_v2(text, text, text, text, date, text, text, text, text, boolean) from public, anon;
grant execute on function public.hi_create_join_request_v2(text, text, text, text, date, text, text, text, text, boolean) to authenticated;

-- O vínculo novo herda o consentimento do pedido de entrada da mesma pessoa.
create or replace function public.hi_link_consent() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.consent_at is null then
    select j.consent_at, j.consent_version into new.consent_at, new.consent_version
      from public.join_requests j
     where j.user_id = new.user_id and j.consent_at is not null
       and j.teacher_id = (select teacher_id from public.students where id = new.student_id)
     order by j.created_at desc limit 1;
  end if;
  return new;
end $$;
drop trigger if exists hi_link_consent on public.student_links;
create trigger hi_link_consent before insert on public.student_links for each row execute function public.hi_link_consent();

-- "Atualizamos os termos": quem já tinha acesso aceita a versão nova.
create or replace function public.hi_accept_terms(p_version text) returns integer
language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  update public.student_links set consent_at = now(), consent_version = left(trim(p_version), 20)
   where user_id = auth.uid();
  get diagnostics n = row_count;
  return n;
end $$;
revoke execute on function public.hi_accept_terms(text) from public, anon;
grant execute on function public.hi_accept_terms(text) to authenticated;

-- ---------------------------------------------------------------------
-- 2. Pedido "apagar também os meus dados" (recado do aluno para o professor)
-- ---------------------------------------------------------------------
alter table public.student_requests drop constraint if exists student_requests_type_check;
alter table public.student_requests add constraint student_requests_type_check
  check (type in ('absence', 'payment_notice', 'change_data', 'song_request', 'reschedule', 'makeup_request', 'delete_data'));

-- ---------------------------------------------------------------------
-- 3. Excluir conta (só a própria; nunca a de outra pessoa)
-- ---------------------------------------------------------------------
-- Registro para diagnóstico: quem pediu, se deu certo e quantas linhas saíram. Ninguém lê
-- pelo app (só pelo painel do Supabase).
create table if not exists public.account_deletions (
  id bigserial primary key,
  user_id uuid not null,
  role text,
  result text not null,
  detail jsonb,
  created_at timestamptz not null default now()
);
alter table public.account_deletions enable row level security;
revoke all on public.account_deletions from anon, authenticated;
revoke all on sequence public.account_deletions_id_seq from anon, authenticated;

-- Conta que é de professor (tem dados de professor).
create or replace function public.hi_is_teacher_account(uid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.teacher_data where teacher_id = uid)
      or exists (select 1 from public.user_data where user_id = uid)
      or exists (select 1 from public.organizations where owner_id = uid)
      or exists (select 1 from public.students where teacher_id = uid)
$$;
revoke execute on function public.hi_is_teacher_account(uuid) from public, anon, authenticated;

-- Aluno/responsável: apaga o login e tudo o que a pessoa criou no app (vínculos, pedidos de
-- entrada, recados, caderno de estudo, notificações). O cadastro do aluno no professor
-- continua (aulas e pagamentos são do professor) e fica sem acesso ao app.
create or replace function public.hi_delete_my_student_account(p_reason text default null) returns jsonb
language plpgsql security definer set search_path = public, auth as $$
declare
  uid uuid := auth.uid();
  d jsonb;
begin
  if uid is null then raise exception 'Entre na sua conta antes' using errcode = '42501'; end if;
  if public.hi_is_teacher_account(uid) then
    insert into public.account_deletions (user_id, role, result, detail) values (uid, 'student', 'refused', jsonb_build_object('why', 'teacher_account'));
    return jsonb_build_object('ok', false, 'error', 'Esta conta também é de professor. Exclua pelo app do professor (Configurações → Conta).');
  end if;
  begin
    d := jsonb_build_object(
      'reason', left(coalesce(p_reason, ''), 300),
      'links', (select count(*) from public.student_links where user_id = uid),
      'join_requests', (select count(*) from public.join_requests where user_id = uid),
      'requests', (select count(*) from public.student_requests where author_user_id = uid),
      'journals', (select count(*) from public.student_journal where user_id = uid),
      'push', (select count(*) from public.push_subscriptions where user_id = uid));
    delete from public.push_subscriptions where user_id = uid;
    delete from public.notify_prefs where user_id = uid;
    delete from public.student_journal where user_id = uid;
    delete from public.student_requests where author_user_id = uid;
    delete from public.join_requests where user_id = uid;
    delete from public.student_links where user_id = uid;
    delete from public.code_lookups where user_id = uid;
    delete from auth.users where id = uid;
    insert into public.account_deletions (user_id, role, result, detail) values (uid, 'student', 'ok', d);
    return jsonb_build_object('ok', true);
  exception when others then
    insert into public.account_deletions (user_id, role, result, detail) values (uid, 'student', 'error', jsonb_build_object('error', sqlerrm, 'state', sqlstate));
    return jsonb_build_object('ok', false, 'error', 'Não foi possível excluir agora. Tente de novo mais tarde.');
  end;
end $$;
revoke execute on function public.hi_delete_my_student_account(text) from public, anon;
grant execute on function public.hi_delete_my_student_account(text) to authenticated;

-- Professor: apaga login, organização, alunos, aulas, reposições, pagamentos, dados privados,
-- chave, pedidos, avisos, notificações e o JSON antigo (user_data). Os alunos com acesso
-- perdem o acesso (o vínculo some junto com o cadastro do aluno).
create or replace function public.hi_delete_my_teacher_account(p_reason text default null) returns jsonb
language plpgsql security definer set search_path = public, auth as $$
declare
  uid uuid := auth.uid();
  sids uuid[];
  d jsonb;
begin
  if uid is null then raise exception 'Entre na sua conta antes' using errcode = '42501'; end if;
  begin
    select coalesce(array_agg(id), '{}') into sids from public.students where teacher_id = uid;
    d := jsonb_build_object(
      'reason', left(coalesce(p_reason, ''), 300),
      'students', coalesce(array_length(sids, 1), 0),
      'lessons', (select count(*) from public.lessons where teacher_id = uid),
      'payments', (select count(*) from public.payments where teacher_id = uid),
      'links', (select count(*) from public.student_links where student_id = any(sids)));
    delete from public.announcements where teacher_id = uid;
    delete from public.push_subscriptions where user_id = uid;
    delete from public.notify_prefs where user_id = uid;
    delete from public.student_view where teacher_id = uid;
    delete from public.teacher_public where teacher_id = uid;
    delete from public.student_requests where student_id = any(sids) or author_user_id = uid;
    delete from public.student_journal where student_id = any(sids) or user_id = uid or teacher_id = uid;
    delete from public.join_requests where teacher_id = uid or user_id = uid or student_id = any(sids);
    delete from public.student_links where student_id = any(sids) or user_id = uid;
    delete from public.lesson_private where teacher_id = uid;
    delete from public.lessons where teacher_id = uid;
    delete from public.makeups where teacher_id = uid;
    delete from public.payments where teacher_id = uid;
    delete from public.student_private where teacher_id = uid;
    delete from public.students where teacher_id = uid;
    delete from public.teacher_codes where teacher_id = uid;
    delete from public.teacher_data where teacher_id = uid;
    delete from public.org_members where user_id = uid or org_id in (select id from public.organizations where owner_id = uid);
    delete from public.organizations where owner_id = uid;
    delete from public.user_data where user_id = uid;
    delete from public.code_lookups where user_id = uid;
    delete from auth.users where id = uid;
    insert into public.account_deletions (user_id, role, result, detail) values (uid, 'teacher', 'ok', d);
    return jsonb_build_object('ok', true);
  exception when others then
    insert into public.account_deletions (user_id, role, result, detail) values (uid, 'teacher', 'error', jsonb_build_object('error', sqlerrm, 'state', sqlstate));
    return jsonb_build_object('ok', false, 'error', 'Não foi possível excluir agora. Tente de novo mais tarde.');
  end;
end $$;
revoke execute on function public.hi_delete_my_teacher_account(text) from public, anon;
grant execute on function public.hi_delete_my_teacher_account(text) to authenticated;

-- ---------------------------------------------------------------------
-- 4. Notificações no celular (push)
-- ---------------------------------------------------------------------
-- Um aparelho por linha. Cada pessoa só vê, cria e apaga as dela.
create table if not exists public.push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  role text not null default 'teacher' check (role in ('teacher', 'student', 'guardian')),
  endpoint text not null unique,
  p256dh text not null,
  auth text not null,
  device_label text,
  created_at timestamptz not null default now(),
  last_ok_at timestamptz,
  active boolean not null default true
);
create index if not exists push_subscriptions_user on public.push_subscriptions (user_id);
alter table public.push_subscriptions enable row level security;
drop policy if exists "push_select" on public.push_subscriptions;
create policy "push_select" on public.push_subscriptions for select to authenticated using (user_id = auth.uid());
drop policy if exists "push_insert" on public.push_subscriptions;
create policy "push_insert" on public.push_subscriptions for insert to authenticated with check (user_id = auth.uid());
drop policy if exists "push_update" on public.push_subscriptions;
create policy "push_update" on public.push_subscriptions for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
drop policy if exists "push_delete" on public.push_subscriptions;
create policy "push_delete" on public.push_subscriptions for delete to authenticated using (user_id = auth.uid());
revoke all on public.push_subscriptions from anon;
grant select, insert, update, delete on public.push_subscriptions to authenticated;

-- Ativar neste aparelho. Se o aparelho estava ligado a outra conta (celular emprestado),
-- passa a ser desta (o endereço do aparelho é secreto, só o próprio navegador conhece).
create or replace function public.hi_push_subscribe(p_endpoint text, p_p256dh text, p_auth text, p_role text, p_label text default null)
returns uuid
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); rid uuid;
begin
  if uid is null then raise exception 'not authenticated' using errcode = '42501'; end if;
  if coalesce(p_endpoint, '') !~ '^https://' or length(p_endpoint) > 1000 then raise exception 'Endereço inválido' using errcode = 'P0001'; end if;
  if (select count(*) from public.push_subscriptions where user_id = uid) >= 10 then
    delete from public.push_subscriptions where id in (select id from public.push_subscriptions where user_id = uid order by created_at limit 1);
  end if;
  delete from public.push_subscriptions where endpoint = p_endpoint;
  insert into public.push_subscriptions (user_id, role, endpoint, p256dh, auth, device_label)
    values (uid, case when p_role in ('teacher', 'student', 'guardian') then p_role else 'teacher' end, p_endpoint,
            left(p_p256dh, 200), left(p_auth, 100), left(p_label, 80))
    returning id into rid;
  return rid;
end $$;
revoke execute on function public.hi_push_subscribe(text, text, text, text, text) from public, anon;
grant execute on function public.hi_push_subscribe(text, text, text, text, text) to authenticated;

-- Preferências: liga/desliga por tipo de aviso e "Não enviar das 22h às 7h".
-- (Uma tabela para professor e aluno: a função de envio lê num lugar só.)
create table if not exists public.notify_prefs (
  user_id uuid primary key default auth.uid() references auth.users (id) on delete cascade,
  prefs jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);
alter table public.notify_prefs enable row level security;
drop policy if exists "nprefs_select" on public.notify_prefs;
create policy "nprefs_select" on public.notify_prefs for select to authenticated using (user_id = auth.uid());
drop policy if exists "nprefs_insert" on public.notify_prefs;
create policy "nprefs_insert" on public.notify_prefs for insert to authenticated with check (user_id = auth.uid());
drop policy if exists "nprefs_update" on public.notify_prefs;
create policy "nprefs_update" on public.notify_prefs for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
revoke all on public.notify_prefs from anon;
grant select, insert, update on public.notify_prefs to authenticated;
drop trigger if exists hi_touch on public.notify_prefs;
create trigger hi_touch before insert or update on public.notify_prefs for each row execute function public.hi_touch_updated_at();
alter table public.notify_prefs add column if not exists created_at timestamptz not null default now();

-- Registro de envios (limite por minuto e "no máximo 1 por semana" da mensalidade).
-- Só a função de envio mexe (chave de serviço).
create table if not exists public.push_log (
  id bigserial primary key,
  sender uuid not null,
  kind text not null,
  ref text,
  sent integer not null default 0,
  created_at timestamptz not null default now()
);
create index if not exists push_log_sender_at on public.push_log (sender, created_at);
create index if not exists push_log_kind_ref on public.push_log (kind, ref, created_at);
alter table public.push_log enable row level security;
revoke all on public.push_log from anon, authenticated;
revoke all on sequence public.push_log_id_seq from anon, authenticated;

-- ---------------------------------------------------------------------
-- 5. Avisos para os alunos
-- ---------------------------------------------------------------------
create table if not exists public.announcements (
  id uuid primary key default gen_random_uuid(),
  teacher_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  title text not null check (char_length(title) between 1 and 120),
  body text not null check (char_length(body) between 1 and 500),
  expires_at timestamptz,
  audience text,                  -- descrição pro professor ("Todos", "Violão", "Turma seg 18:00"...)
  push boolean not null default true,
  created_at timestamptz not null default now()
);
create index if not exists announcements_teacher on public.announcements (teacher_id, created_at desc);

create table if not exists public.announcement_targets (
  id uuid primary key default gen_random_uuid(),
  announcement_id uuid not null references public.announcements (id) on delete cascade,
  student_id uuid not null references public.students (id) on delete cascade,
  read_at timestamptz,
  unique (announcement_id, student_id)
);
create index if not exists announcement_targets_student on public.announcement_targets (student_id);

-- Avisos que ainda valem e têm como destinatário um aluno ligado a mim.
create or replace function public.hi_my_announcement_ids() returns setof uuid
language sql stable security definer set search_path = public as $$
  select t.announcement_id from public.announcement_targets t
    join public.announcements a on a.id = t.announcement_id
   where t.student_id in (select student_id from public.student_links where user_id = auth.uid())
     and (a.expires_at is null or a.expires_at > now())
$$;
create or replace function public.hi_owns_announcement(aid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.announcements where id = aid and teacher_id = auth.uid())
$$;
revoke execute on function public.hi_my_announcement_ids(), public.hi_owns_announcement(uuid) from public, anon;
grant execute on function public.hi_my_announcement_ids(), public.hi_owns_announcement(uuid) to authenticated;

alter table public.announcements enable row level security;
alter table public.announcement_targets enable row level security;

-- announcements: o professor lê, cria e apaga os dele (sem editar depois de enviado);
-- aluno/responsável lê só os que valem e são para o aluno ligado a ele.
drop policy if exists "ann_select" on public.announcements;
create policy "ann_select" on public.announcements for select to authenticated
  using (teacher_id = auth.uid() or id in (select public.hi_my_announcement_ids()));
drop policy if exists "ann_insert" on public.announcements;
create policy "ann_insert" on public.announcements for insert to authenticated with check (teacher_id = auth.uid());
drop policy if exists "ann_delete" on public.announcements;
create policy "ann_delete" on public.announcements for delete to authenticated using (teacher_id = auth.uid());

-- announcement_targets: o professor cria/lê os dos avisos dele (só para alunos dele);
-- aluno/responsável lê os seus e só marca o "visto" (read_at).
drop policy if exists "annt_select" on public.announcement_targets;
create policy "annt_select" on public.announcement_targets for select to authenticated
  using (public.hi_owns_announcement(announcement_id)
      or (student_id in (select public.hi_my_student_ids()) and announcement_id in (select public.hi_my_announcement_ids())));
drop policy if exists "annt_insert" on public.announcement_targets;
create policy "annt_insert" on public.announcement_targets for insert to authenticated
  with check (public.hi_owns_announcement(announcement_id) and public.hi_owns_student(student_id) and read_at is null);
drop policy if exists "annt_update" on public.announcement_targets;
create policy "annt_update" on public.announcement_targets for update to authenticated
  using (student_id in (select public.hi_my_student_ids()) and announcement_id in (select public.hi_my_announcement_ids()))
  with check (student_id in (select public.hi_my_student_ids()));
drop policy if exists "annt_delete" on public.announcement_targets;
create policy "annt_delete" on public.announcement_targets for delete to authenticated
  using (public.hi_owns_announcement(announcement_id));

revoke all on public.announcements, public.announcement_targets from anon;
revoke update on public.announcements, public.announcement_targets from authenticated;
grant select, insert, delete on public.announcements, public.announcement_targets to authenticated;
grant update (read_at) on public.announcement_targets to authenticated;

notify pgrst, 'reload schema';
