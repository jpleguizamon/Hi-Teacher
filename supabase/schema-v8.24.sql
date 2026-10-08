-- =====================================================================
-- Hi Teacher 8.24 — escola: salas, passar aluno, fila da escola e avisos da escola
-- =====================================================================
-- Precisa da 8.0, 8.1, 8.1.1, 8.3, 8.14 e 8.23 instaladas antes.
-- Como rodar: Supabase → SQL Editor → New query → colar este arquivo inteiro → Run.
-- É seguro rodar mais de uma vez. Não apaga nenhum dado que já existe.
-- Sem este arquivo a escola da 8.23 continua funcionando; só ficam escondidos as salas,
-- "Passar para outro professor", o substituto, encaminhar interessados e os avisos da escola.
-- Explicação no HI-TEACHER.md, seção "Escola (8.24)".

-- ---------------------------------------------------------------------
-- 1. Salas da escola
-- ---------------------------------------------------------------------
alter table public.organizations add column if not exists rooms jsonb not null default '[]'::jsonb;

-- Minha escola (como dono ou professor), agora com as salas.
create or replace function public.hi_my_school() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare uid uuid := auth.uid(); r record;
begin
  if uid is null then raise exception 'not authenticated'; end if;
  select o.id, o.name, o.code, o.owner_id, o.rooms, m.id as member_id, m.status, m.pay_rule, m.created_at as since,
         (select om.display_name from public.org_members om where om.org_id = o.id and om.user_id = o.owner_id) as owner_name
    into r
    from public.org_members m join public.organizations o on o.id = m.org_id
   where m.user_id = uid and o.kind = 'school'
   order by (o.owner_id = uid) desc, m.created_at desc limit 1;
  if r.id is null then return null; end if;
  return jsonb_build_object('org_id', r.id, 'name', r.name, 'owner', r.owner_id = uid, 'status', r.status,
    'code', case when r.owner_id = uid then r.code else null end, 'member_id', r.member_id,
    'pay_rule', r.pay_rule, 'owner_name', coalesce(r.owner_name, ''), 'since', r.since,
    'rooms', case when r.status = 'active' then coalesce(r.rooms, '[]'::jsonb) else '[]'::jsonb end, 'v824', true);
end $$;

create or replace function public.hi_school_set_rooms(p_rooms jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare oid uuid := public.hi_school_owned();
begin
  if jsonb_typeof(p_rooms) <> 'array' or jsonb_array_length(p_rooms) > 50 then raise exception 'Lista de salas inválida'; end if;
  if exists (select 1 from jsonb_array_elements(p_rooms) e where jsonb_typeof(e) <> 'string' or length(e #>> '{}') > 40 or btrim(e #>> '{}') = '') then
    raise exception 'Nome de sala inválido';
  end if;
  update public.organizations set rooms = p_rooms where id = oid;
end $$;

-- Escola ativa de quem chama (professor ativo ou dono), ou null.
create or replace function public.hi_school_active_org() returns uuid
language sql stable security definer set search_path = public as $$
  select m.org_id from public.org_members m join public.organizations o on o.id = m.org_id
   where m.user_id = auth.uid() and m.status = 'active' and o.kind = 'school' limit 1
$$;

-- Colegas da escola (nome e id), para escolher substituto ou para quem passar um aluno.
create or replace function public.hi_school_peers() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare oid uuid := public.hi_school_active_org();
begin
  if oid is null then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', m.user_id, 'name', coalesce(nullif(m.display_name, ''), r.data ->> 'name', 'Professor'), 'owner', m.role = 'owner') order by m.display_name)
    from public.org_members m left join public.school_reports r on r.org_id = m.org_id and r.teacher_id = m.user_id
   where m.org_id = oid and m.status = 'active' and m.user_id <> auth.uid()), '[]'::jsonb);
end $$;

-- Salas ocupadas pelos colegas nos próximos 7 dias (só dia, horário, duração, sala e nome do professor).
create or replace function public.hi_school_room_busy() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare oid uuid := public.hi_school_active_org();
begin
  if oid is null then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('name', coalesce(nullif(m.display_name, ''), r.data ->> 'name', 'Professor'),
      'd', a ->> 'd', 't', a ->> 't', 'm', a -> 'm', 'r', a ->> 'r'))
    from public.school_reports r
    join public.org_members m on m.org_id = r.org_id and m.user_id = r.teacher_id and m.status = 'active'
    cross join lateral jsonb_array_elements(case when jsonb_typeof(r.data -> 'agenda') = 'array' then r.data -> 'agenda' else '[]'::jsonb end) a
   where r.org_id = oid and r.teacher_id <> auth.uid() and coalesce(a ->> 'r', '') <> '' and coalesce(a ->> 's', '') = ''), '[]'::jsonb);
end $$;

-- ---------------------------------------------------------------------
-- 2. Passar aluno para outro professor e encaminhar interessados (fila da escola)
-- ---------------------------------------------------------------------
-- kind "student": um professor passa um aluno (com o histórico) para outro professor da escola.
-- kind "lead": o dono encaminha um interessado da fila da escola para um professor.
create table if not exists public.school_transfers (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  from_id uuid not null references auth.users (id) on delete cascade,
  to_id uuid not null references auth.users (id) on delete cascade,
  kind text not null check (kind in ('student', 'lead')),
  data jsonb not null default '{}'::jsonb,
  status text not null default 'pending' check (status in ('pending', 'accepted', 'rejected', 'cancelled')),
  answered_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
drop trigger if exists hi_touch on public.school_transfers;
create trigger hi_touch before insert or update on public.school_transfers for each row execute function public.hi_touch_updated_at();
alter table public.school_transfers enable row level security;
drop policy if exists "stx_select" on public.school_transfers;
create policy "stx_select" on public.school_transfers for select to authenticated
  using (from_id = auth.uid() or to_id = auth.uid() or org_id in (select id from public.organizations where owner_id = auth.uid() and kind = 'school'));
revoke all on public.school_transfers from anon, authenticated;
grant select on public.school_transfers to authenticated;

create or replace function public.hi_school_name_of(p_org uuid, p_user uuid) returns text
language sql stable security definer set search_path = public as $$
  select coalesce(nullif(m.display_name, ''), (select r.data ->> 'name' from public.school_reports r where r.org_id = p_org and r.teacher_id = p_user), 'Professor')
    from public.org_members m where m.org_id = p_org and m.user_id = p_user
$$;

create or replace function public.hi_school_send(p_to uuid, p_kind text, p_data jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare oid uuid := public.hi_school_active_org(); new_id uuid;
begin
  if oid is null then raise exception 'Você não está numa escola'; end if;
  if p_to = auth.uid() then raise exception 'Escolha outro professor'; end if;
  if p_kind not in ('student', 'lead') then raise exception 'Tipo inválido'; end if;
  if p_kind = 'lead' and not exists (select 1 from public.organizations where id = oid and owner_id = auth.uid()) then raise exception 'Só o dono da escola encaminha interessados'; end if;
  if not exists (select 1 from public.org_members where org_id = oid and user_id = p_to and status = 'active') then raise exception 'Esse professor não está na escola'; end if;
  if octet_length(p_data::text) > 400000 then raise exception 'Dados grandes demais para passar'; end if;
  if (select count(*) from public.school_transfers where from_id = auth.uid() and status = 'pending') >= 50 then raise exception 'Muitos envios esperando resposta'; end if;
  insert into public.school_transfers (org_id, from_id, to_id, kind, data) values (oid, auth.uid(), p_to, p_kind, coalesce(p_data, '{}'::jsonb)) returning school_transfers.id into new_id;
  return new_id;
end $$;

-- Pendentes para mim (com o nome de quem mandou).
create or replace function public.hi_school_inbox() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  return coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'kind', t.kind, 'data', t.data, 'created_at', t.created_at,
      'from_id', t.from_id, 'from_name', public.hi_school_name_of(t.org_id, t.from_id)) order by t.created_at)
    from public.school_transfers t where t.to_id = auth.uid() and t.status = 'pending'
      and exists (select 1 from public.org_members m where m.org_id = t.org_id and m.user_id = auth.uid() and m.status = 'active')), '[]'::jsonb);
end $$;

-- Os que eu mandei (últimos 60 dias), com a resposta.
create or replace function public.hi_school_sent() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  return coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'kind', t.kind, 'status', t.status, 'answered_at', t.answered_at, 'created_at', t.created_at,
      'to_id', t.to_id, 'to_name', public.hi_school_name_of(t.org_id, t.to_id), 'ref', t.data ->> 'ref', 'name', t.data ->> 'name') order by t.created_at desc)
    from public.school_transfers t where t.from_id = auth.uid() and t.created_at > now() - interval '60 days'), '[]'::jsonb);
end $$;

create or replace function public.hi_school_answer_transfer(p_id uuid, p_accept boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  update public.school_transfers set status = case when p_accept then 'accepted' else 'rejected' end, answered_at = now()
   where id = p_id and to_id = auth.uid() and status = 'pending';
end $$;

create or replace function public.hi_school_cancel_transfer(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  update public.school_transfers set status = 'cancelled', answered_at = now() where id = p_id and from_id = auth.uid() and status = 'pending';
end $$;

-- ---------------------------------------------------------------------
-- 3. Avisos da escola (do dono para todos os alunos e professores da escola)
-- ---------------------------------------------------------------------
create table if not exists public.school_notices (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  title text not null check (length(title) between 1 and 120),
  body text not null default '' check (length(body) <= 2000),
  audience text not null default 'all' check (audience in ('all', 'students', 'teachers')),
  expires_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
drop trigger if exists hi_touch on public.school_notices;
create trigger hi_touch before insert or update on public.school_notices for each row execute function public.hi_touch_updated_at();
alter table public.school_notices enable row level security;
drop policy if exists "snot_select" on public.school_notices;
create policy "snot_select" on public.school_notices for select to authenticated
  using (org_id in (select id from public.organizations where owner_id = auth.uid() and kind = 'school')
      or (audience <> 'students' and org_id = public.hi_school_active_org()));
drop policy if exists "snot_insert" on public.school_notices;
create policy "snot_insert" on public.school_notices for insert to authenticated
  with check (org_id in (select id from public.organizations where owner_id = auth.uid() and kind = 'school'));
drop policy if exists "snot_delete" on public.school_notices;
create policy "snot_delete" on public.school_notices for delete to authenticated
  using (org_id in (select id from public.organizations where owner_id = auth.uid() and kind = 'school'));
revoke all on public.school_notices from anon, authenticated;
grant select, insert, delete on public.school_notices to authenticated;

-- Aluno/responsável: avisos da escola dos professores dele (por aluno ligado à conta).
create or replace function public.hi_my_school_notices(p_student_ids uuid[]) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  return coalesce((select jsonb_agg(jsonb_build_object('id', n.id, 'student_id', s.id, 'title', n.title, 'body', n.body,
      'created_at', n.created_at, 'expires_at', n.expires_at, 'school', o.name) order by n.created_at desc)
    from public.student_links l
    join public.students s on s.id = l.student_id
    join public.org_members m on m.user_id = s.teacher_id and m.status = 'active'
    join public.organizations o on o.id = m.org_id and o.kind = 'school'
    join public.school_notices n on n.org_id = o.id and n.audience <> 'teachers'
   where l.user_id = auth.uid() and l.student_id = any(p_student_ids)
     and (n.expires_at is null or n.expires_at > now())), '[]'::jsonb);
end $$;

revoke execute on function public.hi_school_set_rooms(jsonb), public.hi_school_active_org(), public.hi_school_peers(),
  public.hi_school_room_busy(), public.hi_school_name_of(uuid, uuid), public.hi_school_send(uuid, text, jsonb),
  public.hi_school_inbox(), public.hi_school_sent(), public.hi_school_answer_transfer(uuid, boolean),
  public.hi_school_cancel_transfer(uuid), public.hi_my_school_notices(uuid[]) from public, anon;
grant execute on function public.hi_school_set_rooms(jsonb), public.hi_school_active_org(), public.hi_school_peers(),
  public.hi_school_room_busy(), public.hi_school_send(uuid, text, jsonb),
  public.hi_school_inbox(), public.hi_school_sent(), public.hi_school_answer_transfer(uuid, boolean),
  public.hi_school_cancel_transfer(uuid), public.hi_my_school_notices(uuid[]) to authenticated;
