-- =====================================================================
-- Hi Teacher 8.23 — escola com vários professores (dono de escola)
-- =====================================================================
-- Precisa da 8.0, 8.1, 8.1.1, 8.3 e 8.14 instaladas antes.
-- Como rodar: Supabase → SQL Editor → New query → colar este arquivo inteiro → Run.
-- É seguro rodar mais de uma vez. Não apaga nenhum dado que já existe.
-- Sem este arquivo o app continua funcionando como antes: só a parte de escola fica
-- indisponível ("Escola" em Configurações avisa que falta atualizar o servidor).
-- Explicação no HI-TEACHER.md, seção "Escola (8.23)".

-- ---------------------------------------------------------------------
-- 1. Escola = organização do tipo "school" (já existia desde a 8.0, sem tela)
-- ---------------------------------------------------------------------
-- Chave da escola (o professor usa para pedir para entrar). Única, sem diferenciar maiúsculas.
alter table public.organizations add column if not exists code text;
create unique index if not exists organizations_code_key on public.organizations (upper(code)) where code is not null;
-- Um dono tem no máximo uma escola.
create unique index if not exists organizations_one_school_per_owner on public.organizations (owner_id) where kind = 'school';

-- Vínculo do professor com a escola: pedido (pending) até o dono aceitar (active).
-- Os vínculos que já existiam (dono da organização "solo") ficam "active", como sempre.
alter table public.org_members add column if not exists status text not null default 'active';
alter table public.org_members drop constraint if exists org_members_status_check;
alter table public.org_members add constraint org_members_status_check check (status in ('pending', 'active'));
alter table public.org_members add column if not exists display_name text not null default '';
-- Regra de pagamento do professor: {"type": "lesson"|"hour"|"percent"|"fixed", "value": número}.
alter table public.org_members add column if not exists pay_rule jsonb not null default '{}'::jsonb;
alter table public.org_members add column if not exists answered_at timestamptz;

-- Pedido pendente não conta como membro (não lê a organização nem grava nela).
create or replace function public.hi_member_org_ids() returns setof uuid
language sql stable security definer set search_path = public as $$
  select id from public.organizations where owner_id = auth.uid()
  union
  select org_id from public.org_members where user_id = auth.uid() and status = 'active'
$$;

-- Ninguém coloca outra pessoa numa organização direto pela tabela: o professor pede com a
-- chave e o dono aceita (funções abaixo). O app nunca mexeu nesta tabela direto; só a
-- hi_ensure_teacher grava o vínculo do próprio dono na organização "solo".
drop policy if exists "orgm_insert" on public.org_members;
create policy "orgm_insert" on public.org_members for insert to authenticated
  with check (org_id in (select public.hi_owned_org_ids()) and user_id = auth.uid());
drop policy if exists "orgm_update" on public.org_members;

-- ---------------------------------------------------------------------
-- 2. Resumo que cada professor publica para o dono da escola
-- ---------------------------------------------------------------------
-- Uma linha por professor por escola. O app do professor calcula com o mesmo motor de aulas
-- dele e grava: alunos ativos, aulas dadas, horas, faltas, cancelamentos, valores do mês e
-- as aulas dos próximos dias (nome do aluno, instrumento, horário, situação). Nunca vão
-- observações, objetivos, avaliações nem anotações da aula.
create table if not exists public.school_reports (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  teacher_id uuid not null references auth.users (id) on delete cascade,
  data jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (org_id, teacher_id)
);
drop trigger if exists hi_touch on public.school_reports;
create trigger hi_touch before insert or update on public.school_reports for each row execute function public.hi_touch_updated_at();
alter table public.school_reports enable row level security;

drop policy if exists "srep_select" on public.school_reports;
create policy "srep_select" on public.school_reports for select to authenticated
  using (teacher_id = auth.uid() or org_id in (select id from public.organizations where owner_id = auth.uid() and kind = 'school'));
drop policy if exists "srep_insert" on public.school_reports;
create policy "srep_insert" on public.school_reports for insert to authenticated
  with check (teacher_id = auth.uid() and exists (select 1 from public.org_members m join public.organizations o on o.id = m.org_id
    where m.org_id = school_reports.org_id and m.user_id = auth.uid() and m.status = 'active' and o.kind = 'school'));
drop policy if exists "srep_update" on public.school_reports;
create policy "srep_update" on public.school_reports for update to authenticated
  using (teacher_id = auth.uid())
  with check (teacher_id = auth.uid() and exists (select 1 from public.org_members m join public.organizations o on o.id = m.org_id
    where m.org_id = school_reports.org_id and m.user_id = auth.uid() and m.status = 'active' and o.kind = 'school'));
revoke all on public.school_reports from anon, authenticated;
grant select, insert, update on public.school_reports to authenticated;

-- ---------------------------------------------------------------------
-- 3. Funções (o app só usa estas)
-- ---------------------------------------------------------------------
-- Chave nova: "ESC-" + 5 números, sem repetir.
create or replace function public.hi_school_make_code() returns text
language plpgsql volatile security definer set search_path = public as $$
declare c text; n int := 0;
begin
  loop
    c := 'ESC-' || lpad((floor(random() * 100000))::int::text, 5, '0');
    exit when not exists (select 1 from public.organizations where upper(code) = c);
    n := n + 1;
    if n > 50 then raise exception 'Não consegui gerar a chave da escola'; end if;
  end loop;
  return c;
end $$;

-- Minha escola (como dono ou professor), ou null.
create or replace function public.hi_my_school() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare uid uuid := auth.uid(); r record;
begin
  if uid is null then raise exception 'not authenticated'; end if;
  select o.id, o.name, o.code, o.owner_id, m.id as member_id, m.status, m.pay_rule, m.created_at as since,
         (select om.display_name from public.org_members om where om.org_id = o.id and om.user_id = o.owner_id) as owner_name
    into r
    from public.org_members m join public.organizations o on o.id = m.org_id
   where m.user_id = uid and o.kind = 'school'
   order by (o.owner_id = uid) desc, m.created_at desc limit 1;
  if r.id is null then return null; end if;
  return jsonb_build_object('org_id', r.id, 'name', r.name, 'owner', r.owner_id = uid, 'status', r.status,
    'code', case when r.owner_id = uid then r.code else null end, 'member_id', r.member_id,
    'pay_rule', r.pay_rule, 'owner_name', coalesce(r.owner_name, ''), 'since', r.since);
end $$;

-- Cria a escola do dono (que continua sendo professor: o vínculo dele entra como "owner").
create or replace function public.hi_create_school(p_name text, p_display text default '') returns jsonb
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); oid uuid; nm text := btrim(coalesce(p_name, ''));
begin
  if uid is null then raise exception 'not authenticated'; end if;
  if not exists (select 1 from public.teacher_data where teacher_id = uid) then raise exception 'Só conta de professor pode criar escola'; end if;
  if nm = '' or length(nm) > 80 then raise exception 'Nome da escola inválido'; end if;
  if exists (select 1 from public.org_members m join public.organizations o on o.id = m.org_id
              where m.user_id = uid and o.kind = 'school' and o.owner_id <> uid) then
    raise exception 'Você já faz parte de outra escola. Saia dela antes de criar a sua.';
  end if;
  select id into oid from public.organizations where owner_id = uid and kind = 'school';
  if oid is null then
    insert into public.organizations (name, kind, owner_id, code) values (nm, 'school', uid, public.hi_school_make_code()) returning id into oid;
  else
    update public.organizations set name = nm where id = oid;
  end if;
  insert into public.org_members (org_id, user_id, role, status, display_name, answered_at)
    values (oid, uid, 'owner', 'active', left(btrim(coalesce(p_display, '')), 80), now())
    on conflict (org_id, user_id) do update set role = 'owner', status = 'active',
      display_name = case when excluded.display_name <> '' then excluded.display_name else org_members.display_name end;
  return public.hi_my_school();
end $$;

-- Confere a chave da escola antes de pedir para entrar.
create or replace function public.hi_find_school(p_code text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r record;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select o.id, o.name, (select om.display_name from public.org_members om where om.org_id = o.id and om.user_id = o.owner_id) as owner_name
    into r from public.organizations o where o.kind = 'school' and upper(o.code) = upper(btrim(coalesce(p_code, '')));
  if r.id is null then return null; end if;
  return jsonb_build_object('name', r.name, 'owner_name', coalesce(r.owner_name, ''));
end $$;

-- O professor pede para entrar na escola (fica pendente até o dono aceitar).
create or replace function public.hi_join_school(p_code text, p_display text default '') returns jsonb
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); oid uuid;
begin
  if uid is null then raise exception 'not authenticated'; end if;
  if not exists (select 1 from public.teacher_data where teacher_id = uid) then raise exception 'Só conta de professor pode entrar numa escola'; end if;
  select id into oid from public.organizations where kind = 'school' and upper(code) = upper(btrim(coalesce(p_code, '')));
  if oid is null then raise exception 'Chave da escola não encontrada'; end if;
  if exists (select 1 from public.org_members m join public.organizations o on o.id = m.org_id
              where m.user_id = uid and o.kind = 'school' and o.id <> oid) then
    raise exception 'Você já faz parte de outra escola. Saia dela antes.';
  end if;
  insert into public.org_members (org_id, user_id, role, status, display_name)
    values (oid, uid, 'teacher', 'pending', left(btrim(coalesce(p_display, '')), 80))
    on conflict (org_id, user_id) do update set display_name = case when excluded.display_name <> '' then excluded.display_name else org_members.display_name end;
  return public.hi_my_school();
end $$;

-- O professor sai da escola (ou cancela o pedido). O dono não sai da própria escola.
create or replace function public.hi_leave_school() returns void
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'not authenticated'; end if;
  delete from public.school_reports r using public.organizations o
   where r.org_id = o.id and o.kind = 'school' and o.owner_id <> uid and r.teacher_id = uid;
  delete from public.org_members m using public.organizations o
   where m.org_id = o.id and o.kind = 'school' and o.owner_id <> uid and m.user_id = uid;
end $$;

-- Escola da qual eu sou dono (ou erro).
create or replace function public.hi_school_owned() returns uuid
language plpgsql stable security definer set search_path = public as $$
declare oid uuid;
begin
  select id into oid from public.organizations where owner_id = auth.uid() and kind = 'school';
  if oid is null then raise exception 'Só o dono da escola pode fazer isso'; end if;
  return oid;
end $$;

-- Professores da escola (para o dono).
create or replace function public.hi_school_members() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare oid uuid := public.hi_school_owned();
begin
  return coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'user_id', m.user_id, 'role', m.role, 'status', m.status,
      'display_name', m.display_name, 'pay_rule', m.pay_rule, 'created_at', m.created_at, 'answered_at', m.answered_at)
      order by (m.role = 'owner') desc, m.status, m.display_name)
    from public.org_members m where m.org_id = oid), '[]'::jsonb);
end $$;

-- Aceitar (vira "active") ou recusar (apaga o pedido).
create or replace function public.hi_school_answer(p_member uuid, p_accept boolean) returns void
language plpgsql security definer set search_path = public as $$
declare oid uuid := public.hi_school_owned();
begin
  if p_accept then
    update public.org_members set status = 'active', answered_at = now() where id = p_member and org_id = oid and status = 'pending';
  else
    delete from public.org_members where id = p_member and org_id = oid and status = 'pending';
  end if;
end $$;

-- Tirar um professor da escola (o resumo dele some do painel; os dados dele continuam com ele).
create or replace function public.hi_school_remove(p_member uuid) returns void
language plpgsql security definer set search_path = public as $$
declare oid uuid := public.hi_school_owned(); u uuid;
begin
  select user_id into u from public.org_members where id = p_member and org_id = oid and role <> 'owner';
  if u is null then return; end if;
  delete from public.school_reports where org_id = oid and teacher_id = u;
  delete from public.org_members where id = p_member;
end $$;

-- Regra de pagamento de um professor (o dono pode ter uma também, se quiser se pagar).
create or replace function public.hi_school_set_pay(p_member uuid, p_rule jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare oid uuid := public.hi_school_owned(); t text := coalesce(p_rule ->> 'type', ''); v numeric;
begin
  if t = '' then
    update public.org_members set pay_rule = '{}'::jsonb where id = p_member and org_id = oid;
    return;
  end if;
  if t not in ('lesson', 'hour', 'percent', 'fixed') then raise exception 'Regra de pagamento inválida'; end if;
  v := (p_rule ->> 'value')::numeric;
  if v is null or v < 0 or v > 1000000 or (t = 'percent' and v > 100) then raise exception 'Valor inválido'; end if;
  update public.org_members set pay_rule = jsonb_build_object('type', t, 'value', v) where id = p_member and org_id = oid;
end $$;

-- Nova chave (a antiga para de funcionar; quem já está na escola continua).
create or replace function public.hi_school_new_code() returns text
language plpgsql security definer set search_path = public as $$
declare oid uuid := public.hi_school_owned(); c text := public.hi_school_make_code();
begin
  update public.organizations set code = c where id = oid;
  return c;
end $$;

-- Trocar o nome da escola.
create or replace function public.hi_school_rename(p_name text) returns void
language plpgsql security definer set search_path = public as $$
declare oid uuid := public.hi_school_owned(); nm text := btrim(coalesce(p_name, ''));
begin
  if nm = '' or length(nm) > 80 then raise exception 'Nome da escola inválido'; end if;
  update public.organizations set name = nm where id = oid;
end $$;

revoke execute on function public.hi_school_make_code(), public.hi_my_school(), public.hi_create_school(text, text),
  public.hi_find_school(text), public.hi_join_school(text, text), public.hi_leave_school(), public.hi_school_owned(),
  public.hi_school_members(), public.hi_school_answer(uuid, boolean), public.hi_school_remove(uuid),
  public.hi_school_set_pay(uuid, jsonb), public.hi_school_new_code(), public.hi_school_rename(text) from public, anon;
grant execute on function public.hi_my_school(), public.hi_create_school(text, text),
  public.hi_find_school(text), public.hi_join_school(text, text), public.hi_leave_school(),
  public.hi_school_members(), public.hi_school_answer(uuid, boolean), public.hi_school_remove(uuid),
  public.hi_school_set_pay(uuid, jsonb), public.hi_school_new_code(), public.hi_school_rename(text) to authenticated;
