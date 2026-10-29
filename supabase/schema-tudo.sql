-- =====================================================================
-- Hi Teacher: TODAS as atualizações do servidor num arquivo só (até a 8.45)
-- Como rodar: Supabase → SQL Editor → New query → colar tudo → Run.
-- Seguro rodar mais de uma vez: só instala o que ainda falta e não apaga nenhum dado.
-- Ao final mostra uma tabela dizendo o que está instalado.
-- =====================================================================

-- Tabela base do app (já existe no servidor; aqui só garante, sem mexer em nada).
create table if not exists public.user_data (
  user_id uuid primary key references auth.users (id) on delete cascade,
  data jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

-- ---------- 8.0 ----------
do $hi$ begin
  if not (to_regclass('public.teacher_data') is not null) then
    raise notice 'Instalando 8.0...';
    execute $hiq$

create or replace function public.hi_touch_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  if tg_op = 'UPDATE' then new.created_at := old.created_at; end if;
  return new;
end $$;

-- Tabelas sincronizadas pelo app (alunos, aulas, reposições, pagamentos):
-- updated_at = hora do servidor (o app baixa "o que mudou desde a última vez" por ele);
-- changed_at = hora em que a alteração foi feita no aparelho. Vale a alteração mais
-- recente por linha: se chegar uma mais antiga que a da nuvem (ex.: aparelho que ficou
-- offline), a da nuvem é mantida e o updated_at avança, pra o aparelho baixar a vencedora.
create or replace function public.hi_touch_lww() returns trigger
language plpgsql as $$
begin
  if tg_op = 'UPDATE' then
    if new.changed_at is not null and old.changed_at is not null and new.changed_at < old.changed_at then
      new := old;
    end if;
    new.created_at := old.created_at;
  end if;
  if new.changed_at is null then new.changed_at := now(); end if;
  new.updated_at := now();
  return new;
end $$;

-- teacher_data: junta chave por chave (configurações, metas, agenda...). Cada chave traz a
-- hora da alteração em key_times; vale a mais recente de cada chave, então dois aparelhos
-- mexendo em coisas diferentes (ex.: metas num, configurações no outro) não se apagam.
create or replace function public.hi_teacher_data_merge() returns trigger
language plpgsql as $$
declare
  k text;
  merged jsonb;
  times jsonb;
begin
  new.data := coalesce(new.data, '{}'::jsonb);
  new.key_times := coalesce(new.key_times, '{}'::jsonb);
  if tg_op = 'UPDATE' then
    merged := coalesce(old.data, '{}'::jsonb);
    times := coalesce(old.key_times, '{}'::jsonb);
    for k in select jsonb_object_keys(new.data) loop
      if coalesce(new.key_times ->> k, '9999') >= coalesce(times ->> k, '') then
        merged := merged || jsonb_build_object(k, new.data -> k);
        times := times || jsonb_build_object(k, coalesce(new.key_times -> k, to_jsonb(to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'))));
      end if;
    end loop;
    new.data := merged;
    new.key_times := times;
    new.created_at := old.created_at;
    if new.storage_mode = 'json' and old.storage_mode is distinct from 'json' then new.json_since := now(); end if;
  elsif new.storage_mode = 'json' then
    new.json_since := now();
  end if;
  new.updated_at := now();
  return new;
end $$;

-- ---------------------------------------------------------------------
-- Tabelas
-- ---------------------------------------------------------------------

create table if not exists public.organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null default '',
  kind text not null default 'solo' check (kind in ('solo', 'school')),
  owner_id uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
-- Uma organização "solo" por professor (os alunos particulares dele).
create unique index if not exists organizations_one_solo_per_owner on public.organizations (owner_id) where kind = 'solo';

create table if not exists public.org_members (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  role text not null default 'teacher' check (role in ('owner', 'teacher')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (org_id, user_id)
);

create table if not exists public.students (
  id uuid primary key default gen_random_uuid(),
  org_id uuid references public.organizations (id),
  teacher_id uuid not null references auth.users (id) on delete cascade,
  legacy_id text,                 -- id numérico do aluno no JSON antigo (student.id)
  name text,
  active boolean,
  instrument text,
  level text,
  days jsonb,
  "time" text,
  lesson_frequency text,
  entry date,
  exit date,
  pay_to text,
  value numeric,
  position integer,               -- ordem do aluno na lista
  extra jsonb not null default '{}'::jsonb,   -- todo o resto do aluno
  deleted boolean not null default false,     -- excluído no app (a linha fica)
  changed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists students_teacher_updated on public.students (teacher_id, updated_at);
create index if not exists students_teacher_legacy on public.students (teacher_id, legacy_id);
create index if not exists students_org on public.students (org_id);

-- Só do professor: nunca vai para o aluno nem para o responsável.
create table if not exists public.student_private (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null unique references public.students (id) on delete cascade,
  teacher_id uuid not null references auth.users (id) on delete cascade,
  observations text,
  objective text,
  needs_review jsonb,
  themes jsonb,                   -- temas vinculados com a nota de desempenho de cada um
  extra jsonb not null default '{}'::jsonb,
  deleted boolean not null default false,
  changed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists student_private_teacher_updated on public.student_private (teacher_id, updated_at);

create table if not exists public.lessons (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.students (id) on delete cascade,
  teacher_id uuid not null references auth.users (id) on delete cascade,
  date date,
  "time" text,
  status text,
  reason text,
  makeup_id text,
  taught text,
  homework text,
  scores jsonb,
  eval_skipped boolean,
  position integer,
  extra jsonb not null default '{}'::jsonb,
  deleted boolean not null default false,
  changed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists lessons_teacher_updated on public.lessons (teacher_id, updated_at);
create index if not exists lessons_student on public.lessons (student_id);

create table if not exists public.makeups (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.students (id) on delete cascade,
  teacher_id uuid not null references auth.users (id) on delete cascade,
  legacy_id text,                 -- id "mk..." da reposição no JSON
  origin_date date,
  date date,
  "time" text,
  status text,
  reason text,
  kind text,
  dismissed_at date,
  position integer,
  extra jsonb not null default '{}'::jsonb,
  deleted boolean not null default false,
  changed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists makeups_teacher_updated on public.makeups (teacher_id, updated_at);
create index if not exists makeups_student on public.makeups (student_id);

-- Une paidMonths/paidDates (kind "month") e charges (kind "lesson" / "package").
create table if not exists public.payments (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.students (id) on delete cascade,
  teacher_id uuid not null references auth.users (id) on delete cascade,
  kind text check (kind in ('month', 'lesson', 'package')),
  ref text,                       -- AAAA-MM, data da aula ou início do pacote
  value numeric,
  paid boolean,
  paid_at date,
  legacy_id text,                 -- id "ch..." da cobrança no JSON
  position integer,
  extra jsonb not null default '{}'::jsonb,
  deleted boolean not null default false,
  changed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists payments_teacher_updated on public.payments (teacher_id, updated_at);
create index if not exists payments_student on public.payments (student_id);

-- Tudo que é só do professor (configurações, metas, organizador de aulas, faturamento,
-- contagem de alunos, agenda, lista de espera, mensagens prontas). Uma linha por professor.
create table if not exists public.teacher_data (
  id uuid primary key default gen_random_uuid(),
  teacher_id uuid not null unique references auth.users (id) on delete cascade,
  org_id uuid references public.organizations (id),
  data jsonb not null default '{}'::jsonb,
  key_times jsonb not null default '{}'::jsonb,
  storage_mode text check (storage_mode in ('json', 'tables')),  -- chave de volta: 'json' = todos os aparelhos voltam pro user_data
  migrated_at timestamptz,        -- quando os dados do JSON foram copiados para as tabelas
  json_at timestamptz,            -- updated_at do user_data que foi copiado
  migration_lock_at timestamptz,  -- trava: um aparelho migrando por vez
  migration_lock_by text,
  migration_error text,           -- último motivo de falha (diagnóstico)
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.teacher_data add column if not exists json_since timestamptz;  -- quando voltou pro modo JSON

-- ---- Preparadas para a 8.1 (sem tela nenhuma na 8.0) ----

create table if not exists public.student_links (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.students (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  role text not null default 'student' check (role in ('student', 'guardian')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (student_id, user_id)
);
create index if not exists student_links_user on public.student_links (user_id);

create table if not exists public.teacher_codes (
  id uuid primary key default gen_random_uuid(),
  teacher_id uuid not null unique references auth.users (id) on delete cascade,
  code text not null check (upper(code) ~ '^[A-Z]{1,4}[0-9]{3}$'),  -- iniciais + 3 números, ex.: JP543
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists teacher_codes_code_ci on public.teacher_codes (upper(code));

create table if not exists public.join_requests (
  id uuid primary key default gen_random_uuid(),
  teacher_id uuid not null references auth.users (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  role text not null default 'student' check (role in ('student', 'guardian')),
  student_name text,
  student_phone text,
  student_birth_date date,
  instrument text,
  guardian_name text,
  guardian_phone text,
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected', 'waitlist')),
  student_id uuid references public.students (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  answered_at timestamptz
);
create index if not exists join_requests_teacher on public.join_requests (teacher_id, status);
create index if not exists join_requests_user on public.join_requests (user_id, status);
-- No máximo 1 pedido pendente por usuário/professor.
create unique index if not exists join_requests_one_pending on public.join_requests (user_id, teacher_id) where status = 'pending';

create table if not exists public.student_requests (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.students (id) on delete cascade,
  author_user_id uuid not null references auth.users (id) on delete cascade,
  type text not null check (type in ('absence', 'payment_notice', 'change_data')),
  payload jsonb not null default '{}'::jsonb,
  status text not null default 'pending' check (status in ('pending', 'accepted', 'rejected')),
  response text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  answered_at timestamptz
);
create index if not exists student_requests_student on public.student_requests (student_id, status);

-- ---------------------------------------------------------------------
-- Triggers de updated_at
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['organizations','org_members','student_links','teacher_codes','join_requests','student_requests'] loop
    execute format('drop trigger if exists hi_touch on public.%I', t);
    execute format('create trigger hi_touch before insert or update on public.%I for each row execute function public.hi_touch_updated_at()', t);
  end loop;
  foreach t in array array['students','student_private','lessons','makeups','payments'] loop
    execute format('drop trigger if exists hi_touch on public.%I', t);
    execute format('create trigger hi_touch before insert or update on public.%I for each row execute function public.hi_touch_lww()', t);
  end loop;
end $$;
drop trigger if exists hi_touch on public.teacher_data;
create trigger hi_touch before insert or update on public.teacher_data for each row execute function public.hi_teacher_data_merge();

-- Pedidos de entrada: no máximo 3 pendentes por usuário e 1 pendente por usuário/professor.
create or replace function public.hi_join_requests_limit() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  -- Pedido em nome de outra pessoa: a regra de acesso recusa; não conta nada aqui.
  if tg_op = 'INSERT' and new.user_id is distinct from auth.uid() then return new; end if;
  if new.status = 'pending' then
    if (select count(*) from public.join_requests where user_id = new.user_id and status = 'pending' and id <> new.id) >= 3 then
      raise exception 'Limite de 3 pedidos pendentes por usuário' using errcode = 'P0001';
    end if;
    if exists (select 1 from public.join_requests where user_id = new.user_id and teacher_id = new.teacher_id and status = 'pending' and id <> new.id) then
      raise exception 'Já existe um pedido pendente para este professor' using errcode = 'P0001';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists hi_join_limit on public.join_requests;
create trigger hi_join_limit before insert or update of status on public.join_requests for each row execute function public.hi_join_requests_limit();

-- ---------------------------------------------------------------------
-- Funções usadas nas regras (security definer evita regras que se chamam em círculo)
-- ---------------------------------------------------------------------
create or replace function public.hi_my_student_ids() returns setof uuid
language sql stable security definer set search_path = public as $$
  select student_id from public.student_links where user_id = auth.uid()
$$;

create or replace function public.hi_owns_student(sid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.students where id = sid and teacher_id = auth.uid())
$$;

create or replace function public.hi_owned_org_ids() returns setof uuid
language sql stable security definer set search_path = public as $$
  select id from public.organizations where owner_id = auth.uid()
$$;

create or replace function public.hi_member_org_ids() returns setof uuid
language sql stable security definer set search_path = public as $$
  select id from public.organizations where owner_id = auth.uid()
  union
  select org_id from public.org_members where user_id = auth.uid()
$$;

-- Aluno de uma organização da qual eu sou dono (o dono da escola lê o que é da escola).
create or replace function public.hi_student_in_my_org(sid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.students s where s.id = sid and s.org_id in (select id from public.organizations where owner_id = auth.uid()))
$$;

-- Garante a organização "solo", o vínculo de dono e a linha de teacher_data do professor
-- logado. Chamada pelo app ao entrar. Devolve o id da organização.
create or replace function public.hi_ensure_teacher(p_name text default '') returns uuid
language plpgsql security invoker set search_path = public as $$
declare
  uid uuid := auth.uid();
  oid uuid;
begin
  if uid is null then raise exception 'not authenticated'; end if;
  select id into oid from public.organizations where owner_id = uid and kind = 'solo';
  if oid is null then
    insert into public.organizations (name, kind, owner_id) values (coalesce(p_name, ''), 'solo', uid)
      on conflict (owner_id) where kind = 'solo' do nothing;
    select id into oid from public.organizations where owner_id = uid and kind = 'solo';
  end if;
  insert into public.org_members (org_id, user_id, role) values (oid, uid, 'owner') on conflict (org_id, user_id) do nothing;
  insert into public.teacher_data (teacher_id, org_id) values (uid, oid) on conflict (teacher_id) do nothing;
  update public.teacher_data set org_id = oid where teacher_id = uid and org_id is null;
  return oid;
end $$;

-- Trava da migração: só um aparelho por vez (a trava vence sozinha em 10 minutos).
create or replace function public.hi_try_migration_lock(p_device text) returns boolean
language plpgsql security invoker set search_path = public as $$
declare n int;
begin
  update public.teacher_data
     set migration_lock_at = now(), migration_lock_by = p_device
   where teacher_id = auth.uid()
     and (migration_lock_at is null or migration_lock_at < now() - interval '10 minutes' or migration_lock_by = p_device);
  get diagnostics n = row_count;
  return n > 0;
end $$;

create or replace function public.hi_release_migration_lock(p_device text) returns void
language sql security invoker set search_path = public as $$
  update public.teacher_data set migration_lock_at = null, migration_lock_by = null
   where teacher_id = auth.uid() and migration_lock_by = p_device
$$;

-- ---------------------------------------------------------------------
-- Regras de acesso (RLS)
-- ---------------------------------------------------------------------
alter table public.organizations enable row level security;
alter table public.org_members enable row level security;
alter table public.students enable row level security;
alter table public.student_private enable row level security;
alter table public.lessons enable row level security;
alter table public.makeups enable row level security;
alter table public.payments enable row level security;
alter table public.teacher_data enable row level security;
alter table public.student_links enable row level security;
alter table public.teacher_codes enable row level security;
alter table public.join_requests enable row level security;
alter table public.student_requests enable row level security;

-- organizations: o dono lê e altera; membros leem.
drop policy if exists "org_select" on public.organizations;
create policy "org_select" on public.organizations for select to authenticated
  using (owner_id = auth.uid() or id in (select public.hi_member_org_ids()));
drop policy if exists "org_insert" on public.organizations;
create policy "org_insert" on public.organizations for insert to authenticated
  with check (owner_id = auth.uid());
drop policy if exists "org_update" on public.organizations;
create policy "org_update" on public.organizations for update to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());

-- org_members: cada um lê o próprio vínculo; o dono da organização lê e gerencia todos.
drop policy if exists "orgm_select" on public.org_members;
create policy "orgm_select" on public.org_members for select to authenticated
  using (user_id = auth.uid() or org_id in (select public.hi_owned_org_ids()));
drop policy if exists "orgm_insert" on public.org_members;
create policy "orgm_insert" on public.org_members for insert to authenticated
  with check (org_id in (select public.hi_owned_org_ids()));
drop policy if exists "orgm_update" on public.org_members;
create policy "orgm_update" on public.org_members for update to authenticated
  using (org_id in (select public.hi_owned_org_ids())) with check (org_id in (select public.hi_owned_org_ids()));
drop policy if exists "orgm_delete" on public.org_members;
create policy "orgm_delete" on public.org_members for delete to authenticated
  using (org_id in (select public.hi_owned_org_ids()) and user_id <> auth.uid());

-- students: professor (teacher_id) lê e escreve; dono da organização lê; aluno/responsável
-- vinculado só lê a própria linha.
drop policy if exists "students_select" on public.students;
create policy "students_select" on public.students for select to authenticated
  using (teacher_id = auth.uid()
      or org_id in (select public.hi_owned_org_ids())
      or (id in (select public.hi_my_student_ids()) and not deleted));
drop policy if exists "students_insert" on public.students;
create policy "students_insert" on public.students for insert to authenticated
  with check (teacher_id = auth.uid() and (org_id is null or org_id in (select public.hi_member_org_ids())));
drop policy if exists "students_update" on public.students;
create policy "students_update" on public.students for update to authenticated
  using (teacher_id = auth.uid())
  with check (teacher_id = auth.uid() and (org_id is null or org_id in (select public.hi_member_org_ids())));

-- student_private: SÓ o professor dono. Nunca aluno nem responsável.
drop policy if exists "private_select" on public.student_private;
create policy "private_select" on public.student_private for select to authenticated
  using (teacher_id = auth.uid());
drop policy if exists "private_insert" on public.student_private;
create policy "private_insert" on public.student_private for insert to authenticated
  with check (teacher_id = auth.uid() and public.hi_owns_student(student_id));
drop policy if exists "private_update" on public.student_private;
create policy "private_update" on public.student_private for update to authenticated
  using (teacher_id = auth.uid()) with check (teacher_id = auth.uid() and public.hi_owns_student(student_id));

-- lessons, makeups, payments: mesma regra.
do $$
declare t text;
begin
  foreach t in array array['lessons','makeups','payments'] loop
    execute format('drop policy if exists "%s_select" on public.%I', t, t);
    execute format($p$create policy "%s_select" on public.%I for select to authenticated
      using (teacher_id = auth.uid()
          or public.hi_student_in_my_org(student_id)
          or (student_id in (select public.hi_my_student_ids()) and not deleted))$p$, t, t);
    execute format('drop policy if exists "%s_insert" on public.%I', t, t);
    execute format('create policy "%s_insert" on public.%I for insert to authenticated with check (teacher_id = auth.uid() and public.hi_owns_student(student_id))', t, t);
    execute format('drop policy if exists "%s_update" on public.%I', t, t);
    execute format('create policy "%s_update" on public.%I for update to authenticated using (teacher_id = auth.uid()) with check (teacher_id = auth.uid() and public.hi_owns_student(student_id))', t, t);
  end loop;
end $$;

-- teacher_data: SÓ o professor dono.
drop policy if exists "tdata_select" on public.teacher_data;
create policy "tdata_select" on public.teacher_data for select to authenticated using (teacher_id = auth.uid());
drop policy if exists "tdata_insert" on public.teacher_data;
create policy "tdata_insert" on public.teacher_data for insert to authenticated
  with check (teacher_id = auth.uid() and (org_id is null or org_id in (select public.hi_member_org_ids())));
drop policy if exists "tdata_update" on public.teacher_data;
create policy "tdata_update" on public.teacher_data for update to authenticated
  using (teacher_id = auth.uid()) with check (teacher_id = auth.uid() and (org_id is null or org_id in (select public.hi_member_org_ids())));

-- student_links: o professor cria/remove os links dos alunos dele; aluno/responsável só lê os próprios.
drop policy if exists "links_select" on public.student_links;
create policy "links_select" on public.student_links for select to authenticated
  using (user_id = auth.uid() or public.hi_owns_student(student_id));
drop policy if exists "links_insert" on public.student_links;
create policy "links_insert" on public.student_links for insert to authenticated
  with check (public.hi_owns_student(student_id));
drop policy if exists "links_update" on public.student_links;
create policy "links_update" on public.student_links for update to authenticated
  using (public.hi_owns_student(student_id)) with check (public.hi_owns_student(student_id));
drop policy if exists "links_delete" on public.student_links;
create policy "links_delete" on public.student_links for delete to authenticated
  using (public.hi_owns_student(student_id));

-- teacher_codes: só o professor dono lê e altera a própria chave (a busca do aluno será por RPC na 8.1).
drop policy if exists "codes_select" on public.teacher_codes;
create policy "codes_select" on public.teacher_codes for select to authenticated using (teacher_id = auth.uid());
drop policy if exists "codes_insert" on public.teacher_codes;
create policy "codes_insert" on public.teacher_codes for insert to authenticated with check (teacher_id = auth.uid());
drop policy if exists "codes_update" on public.teacher_codes;
create policy "codes_update" on public.teacher_codes for update to authenticated using (teacher_id = auth.uid()) with check (teacher_id = auth.uid());

-- join_requests: quem pede cria só com o próprio user_id (pendente) e lê só os seus;
-- o professor lê e responde os pedidos com o teacher_id dele.
drop policy if exists "join_select" on public.join_requests;
create policy "join_select" on public.join_requests for select to authenticated
  using (user_id = auth.uid() or teacher_id = auth.uid());
drop policy if exists "join_insert" on public.join_requests;
create policy "join_insert" on public.join_requests for insert to authenticated
  with check (user_id = auth.uid() and status = 'pending' and student_id is null and answered_at is null and teacher_id <> auth.uid());
drop policy if exists "join_update" on public.join_requests;
create policy "join_update" on public.join_requests for update to authenticated
  using (teacher_id = auth.uid())
  with check (teacher_id = auth.uid() and (student_id is null or public.hi_owns_student(student_id)));

-- student_requests: aluno/responsável cria e lê os do próprio student_id; o professor lê e responde.
drop policy if exists "sreq_select" on public.student_requests;
create policy "sreq_select" on public.student_requests for select to authenticated
  using (student_id in (select public.hi_my_student_ids()) or public.hi_owns_student(student_id));
drop policy if exists "sreq_insert" on public.student_requests;
create policy "sreq_insert" on public.student_requests for insert to authenticated
  with check (author_user_id = auth.uid() and student_id in (select public.hi_my_student_ids()) and status = 'pending' and response is null and answered_at is null);
drop policy if exists "sreq_update" on public.student_requests;
create policy "sreq_update" on public.student_requests for update to authenticated
  using (public.hi_owns_student(student_id)) with check (public.hi_owns_student(student_id));

-- ---------------------------------------------------------------------
-- Permissões (GRANT) — sem isso o Supabase responde 42501 "permission denied",
-- como já aconteceu com user_data. Nada de DELETE nas tabelas de dados: o app
-- marca "deleted" em vez de apagar.
-- ---------------------------------------------------------------------
grant usage on schema public to authenticated;
revoke all on public.organizations, public.org_members, public.students, public.student_private,
  public.lessons, public.makeups, public.payments, public.teacher_data, public.student_links,
  public.teacher_codes, public.join_requests, public.student_requests from anon;
grant select, insert, update on public.organizations, public.students, public.student_private,
  public.lessons, public.makeups, public.payments, public.teacher_data, public.teacher_codes
  to authenticated;
grant select, insert, update, delete on public.org_members, public.student_links to authenticated;
grant select, insert on public.join_requests, public.student_requests to authenticated;
-- Responder um pedido: o professor só muda a situação, o aluno criado e a hora da resposta.
revoke update on public.join_requests, public.student_requests from authenticated;
grant update (status, student_id, answered_at) on public.join_requests to authenticated;
grant update (status, response, answered_at) on public.student_requests to authenticated;

revoke execute on function public.hi_my_student_ids(), public.hi_owns_student(uuid), public.hi_owned_org_ids(),
  public.hi_member_org_ids(), public.hi_student_in_my_org(uuid), public.hi_ensure_teacher(text),
  public.hi_try_migration_lock(text), public.hi_release_migration_lock(text) from public, anon;
grant execute on function public.hi_my_student_ids(), public.hi_owns_student(uuid), public.hi_owned_org_ids(),
  public.hi_member_org_ids(), public.hi_student_in_my_org(uuid), public.hi_ensure_teacher(text),
  public.hi_try_migration_lock(text), public.hi_release_migration_lock(text) to authenticated;

-- Avisa a API (PostgREST) que o esquema mudou.
notify pgrst, 'reload schema';

-- 8.45: grava esta versão (a lista de versões fica no servidor).
create table if not exists public.schema_versions (version text primary key, applied_at timestamptz not null default now());
alter table public.schema_versions enable row level security;
revoke all on public.schema_versions from anon, authenticated;
insert into public.schema_versions (version) values ('8.0') on conflict (version) do nothing;

$hiq$;
  else raise notice '8.0 já estava instalada.';
  end if;
end $hi$;

-- ---------- 8.1 ----------
do $hi$ begin
  if not (to_regclass('public.student_view') is not null) then
    raise notice 'Instalando 8.1...';
    execute $hiq$

create table if not exists public.teacher_public (
  id uuid primary key default gen_random_uuid(),
  teacher_id uuid not null unique references auth.users (id) on delete cascade,
  display_name text,              -- nome de exibição (ex.: Prof. JP)
  full_name text,                 -- nome completo (só pro recibo)
  document text,                  -- CPF/CNPJ (só pro recibo)
  photo text,
  city text,
  state text,                     -- UF: feriados estaduais certos nas aulas do aluno
  breaks jsonb not null default '[]'::jsonb,     -- férias/recesso gerais (sem os de um aluno só)
  settings jsonb not null default '{}'::jsonb,   -- duração padrão, início das cobranças, critérios, instrumentos...
  show_evaluations boolean not null default false, -- "Mostrar avaliações para os alunos"
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- O que é de UM aluno e o app do aluno precisa, mas o app do professor calcula a partir dos
-- outros alunos (sem expor os outros): se a aula é em grupo, mensalidade padrão e férias
-- só daquele aluno. Uma linha por aluno com acesso ao app.
create table if not exists public.student_view (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null unique references public.students (id) on delete cascade,
  teacher_id uuid not null references auth.users (id) on delete cascade,
  info jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Pedido cancelado pelo próprio aluno ("Cancelar pedido" / "cancelar aviso").
alter table public.join_requests drop constraint if exists join_requests_status_check;
alter table public.join_requests add constraint join_requests_status_check
  check (status in ('pending', 'approved', 'rejected', 'waitlist', 'cancelled'));
alter table public.student_requests drop constraint if exists student_requests_status_check;
alter table public.student_requests add constraint student_requests_status_check
  check (status in ('pending', 'accepted', 'rejected', 'cancelled'));

do $$
declare t text;
begin
  foreach t in array array['teacher_public','student_view'] loop
    execute format('drop trigger if exists hi_touch on public.%I', t);
    execute format('create trigger hi_touch before insert or update on public.%I for each row execute function public.hi_touch_updated_at()', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- Funções
-- ---------------------------------------------------------------------

-- Professores dos alunos ligados a mim (aluno/responsável).
create or replace function public.hi_my_teacher_ids() returns setof uuid
language sql stable security definer set search_path = public as $$
  select distinct s.teacher_id from public.students s
   where s.id in (select student_id from public.student_links where user_id = auth.uid()) and not s.deleted
$$;

-- A chave aceita pedidos novos? (chave ativa = pedidos não pausados)
create or replace function public.hi_teacher_accepts(tid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.teacher_codes where teacher_id = tid and active)
$$;

-- Procurar uma chave: só confirma que existe e mostra o nome de exibição do professor
-- (e a lista de instrumentos dele, pro formulário). Não expõe a tabela.
-- Pode ser usada antes de criar a conta (a tela pede a chave antes do cadastro).
create or replace function public.hi_find_teacher_code(p_code text)
returns table (teacher_id uuid, display_name text, instruments jsonb, accepting boolean)
language sql stable security definer set search_path = public as $$
  select c.teacher_id,
         coalesce(nullif(p.display_name, ''), 'Professor') as display_name,
         coalesce(p.settings -> 'instruments', '[]'::jsonb) as instruments,
         c.active as accepting
    from public.teacher_codes c
    left join public.teacher_public p on p.teacher_id = c.teacher_id
   where upper(c.code) = upper(trim(coalesce(p_code, '')))
   limit 1
$$;

-- Meus pedidos de entrada, com o nome do professor (quem pediu ainda não lê teacher_public).
create or replace function public.hi_my_join_requests()
returns table (id uuid, teacher_id uuid, role text, student_name text, status text, student_id uuid,
               created_at timestamptz, answered_at timestamptz, teacher_name text)
language sql stable security definer set search_path = public as $$
  select j.id, j.teacher_id, j.role, j.student_name, j.status, j.student_id, j.created_at, j.answered_at,
         coalesce(nullif(p.display_name, ''), 'Professor')
    from public.join_requests j
    left join public.teacher_public p on p.teacher_id = j.teacher_id
   where j.user_id = auth.uid()
   order by j.created_at desc
$$;

-- ---------------------------------------------------------------------
-- Regras de acesso (RLS)
-- ---------------------------------------------------------------------
alter table public.teacher_public enable row level security;
alter table public.student_view enable row level security;

-- teacher_public: o professor escreve a dele; aluno/responsável lê só a do professor com quem tem vínculo.
drop policy if exists "tpub_select" on public.teacher_public;
create policy "tpub_select" on public.teacher_public for select to authenticated
  using (teacher_id = auth.uid() or teacher_id in (select public.hi_my_teacher_ids()));
drop policy if exists "tpub_insert" on public.teacher_public;
create policy "tpub_insert" on public.teacher_public for insert to authenticated with check (teacher_id = auth.uid());
drop policy if exists "tpub_update" on public.teacher_public;
create policy "tpub_update" on public.teacher_public for update to authenticated
  using (teacher_id = auth.uid()) with check (teacher_id = auth.uid());

-- student_view: o professor escreve a dos alunos dele; aluno/responsável lê só a própria.
drop policy if exists "sview_select" on public.student_view;
create policy "sview_select" on public.student_view for select to authenticated
  using (teacher_id = auth.uid() or student_id in (select public.hi_my_student_ids()));
drop policy if exists "sview_insert" on public.student_view;
create policy "sview_insert" on public.student_view for insert to authenticated
  with check (teacher_id = auth.uid() and public.hi_owns_student(student_id));
drop policy if exists "sview_update" on public.student_view;
create policy "sview_update" on public.student_view for update to authenticated
  using (teacher_id = auth.uid()) with check (teacher_id = auth.uid() and public.hi_owns_student(student_id));

-- join_requests: só cria com o próprio user_id, pendente, e pra chave que está aceitando
-- pedidos; quem pediu pode cancelar enquanto está pendente.
drop policy if exists "join_insert" on public.join_requests;
create policy "join_insert" on public.join_requests for insert to authenticated
  with check (user_id = auth.uid() and status = 'pending' and student_id is null and answered_at is null
              and teacher_id <> auth.uid() and public.hi_teacher_accepts(teacher_id));
drop policy if exists "join_cancel_own" on public.join_requests;
create policy "join_cancel_own" on public.join_requests for update to authenticated
  using (user_id = auth.uid() and status = 'pending')
  with check (user_id = auth.uid() and status = 'cancelled' and student_id is null);

-- student_requests: aluno/responsável cria só pra aluno ligado a ele e vê só os seus;
-- pode cancelar o seu enquanto o professor não respondeu. O professor lê e responde.
drop policy if exists "sreq_select" on public.student_requests;
create policy "sreq_select" on public.student_requests for select to authenticated
  using ((author_user_id = auth.uid() and student_id in (select public.hi_my_student_ids())) or public.hi_owns_student(student_id));
drop policy if exists "sreq_cancel_own" on public.student_requests;
create policy "sreq_cancel_own" on public.student_requests for update to authenticated
  using (author_user_id = auth.uid() and status = 'pending')
  with check (author_user_id = auth.uid() and status = 'cancelled' and response is null);

-- ---------------------------------------------------------------------
-- Permissões
-- ---------------------------------------------------------------------
revoke all on public.teacher_public, public.student_view from anon;
grant select, insert, update on public.teacher_public, public.student_view to authenticated;

revoke execute on function public.hi_my_teacher_ids(), public.hi_teacher_accepts(uuid),
  public.hi_find_teacher_code(text), public.hi_my_join_requests() from public;
grant execute on function public.hi_my_teacher_ids(), public.hi_teacher_accepts(uuid),
  public.hi_my_join_requests() to authenticated;
-- A chave é conferida na tela antes de criar a conta: por isso também para anon.
grant execute on function public.hi_find_teacher_code(text) to anon, authenticated;

notify pgrst, 'reload schema';

-- 8.45: grava esta versão (a lista de versões fica no servidor).
create table if not exists public.schema_versions (version text primary key, applied_at timestamptz not null default now());
alter table public.schema_versions enable row level security;
revoke all on public.schema_versions from anon, authenticated;
insert into public.schema_versions (version) values ('8.1') on conflict (version) do nothing;

$hiq$;
  else raise notice '8.1 já estava instalada.';
  end if;
end $hi$;

-- ---------- 8.1.1 ----------
do $hi$ begin
  if not (to_regclass('public.lesson_private') is not null) then
    raise notice 'Instalando 8.1.1...';
    execute $hiq$

create table if not exists public.lesson_private (
  id uuid primary key,
  lesson_id uuid not null unique references public.lessons (id) on delete cascade,
  student_id uuid not null references public.students (id) on delete cascade,
  teacher_id uuid not null references auth.users (id) on delete cascade,
  scores jsonb,
  extra jsonb not null default '{}'::jsonb,
  deleted boolean not null default false,
  changed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists lesson_private_teacher_updated on public.lesson_private (teacher_id, updated_at);
drop trigger if exists hi_touch on public.lesson_private;
create trigger hi_touch before insert or update on public.lesson_private for each row execute function public.hi_touch_lww();

alter table public.lesson_private enable row level security;
drop policy if exists "lprivate_select" on public.lesson_private;
create policy "lprivate_select" on public.lesson_private for select to authenticated using (teacher_id = auth.uid());
drop policy if exists "lprivate_insert" on public.lesson_private;
create policy "lprivate_insert" on public.lesson_private for insert to authenticated
  with check (teacher_id = auth.uid() and public.hi_owns_student(student_id));
drop policy if exists "lprivate_update" on public.lesson_private;
create policy "lprivate_update" on public.lesson_private for update to authenticated
  using (teacher_id = auth.uid()) with check (teacher_id = auth.uid() and public.hi_owns_student(student_id));
revoke all on public.lesson_private from anon;
grant select, insert, update on public.lesson_private to authenticated;

-- Garantia no servidor: nota que chegar em lessons (ex.: app antigo ainda aberto) é movida
-- na hora pra lesson_private e não fica visível pro aluno.
create or replace function public.hi_lesson_scores_to_private(lid uuid, sid uuid, tid uuid, sc jsonb, at timestamptz) returns void
language sql security definer set search_path = public as $$
  insert into public.lesson_private (id, lesson_id, student_id, teacher_id, scores, changed_at)
    values (lid, lid, sid, tid, sc, coalesce(at, now()))
    on conflict (id) do update set scores = excluded.scores, deleted = false,
      changed_at = greatest(public.lesson_private.changed_at, excluded.changed_at)
$$;
revoke execute on function public.hi_lesson_scores_to_private(uuid, uuid, uuid, jsonb, timestamptz) from public, anon, authenticated;
-- Alteração: move antes de gravar.
create or replace function public.hi_lessons_scores_before_update() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.scores is not null and new.scores <> 'null'::jsonb then
    perform public.hi_lesson_scores_to_private(new.id, new.student_id, new.teacher_id, new.scores, new.changed_at);
  end if;
  new.scores := null;
  return new;
end $$;
drop trigger if exists hi_move_scores on public.lessons;
create trigger hi_move_scores before update on public.lessons for each row
  when (new.scores is not null) execute function public.hi_lessons_scores_before_update();
-- Aula nova: a aula precisa existir antes (chave estrangeira), então move logo depois.
create or replace function public.hi_lessons_scores_after_insert() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.scores is not null and new.scores <> 'null'::jsonb then
    perform public.hi_lesson_scores_to_private(new.id, new.student_id, new.teacher_id, new.scores, new.changed_at);
  end if;
  update public.lessons set scores = null where id = new.id;
  return null;
end $$;
drop trigger if exists hi_move_scores_ins on public.lessons;
create trigger hi_move_scores_ins after insert on public.lessons for each row
  when (new.scores is not null) execute function public.hi_lessons_scores_after_insert();

-- Notas que já estão na nuvem: move de uma vez (a trigger acima faz o trabalho).
update public.lessons set scores = scores where scores is not null;

-- Dados do aluno que são só do professor e estavam em students.extra (ex.: frequência de
-- avaliação, campos desconhecidos) vão pra student_private.extra. Ficam em students só os
-- que o app do aluno usa.
do $$
declare
  pub text[] := array['id','timesByDay','biweeklyStart','trackingSince','duration','locationType','locationDetail',
    'phone','birthDate','guardianName','guardianPhone','dueDay','packageSize','packageStart','packagePrice','lessonPrice','format'];
begin
  update public.student_private p
     set extra = p.extra || coalesce((select jsonb_object_agg(k, v) from jsonb_each(s.extra) e(k, v) where k <> all(pub)), '{}'::jsonb)
    from public.students s
   where s.id = p.student_id and exists (select 1 from jsonb_object_keys(s.extra) k where k <> all(pub));
  update public.students s
     set extra = coalesce((select jsonb_object_agg(k, v) from jsonb_each(s.extra) e(k, v) where k = any(pub)), '{}'::jsonb)
   where exists (select 1 from jsonb_object_keys(s.extra) k where k <> all(pub));
end $$;

-- ---------------------------------------------------------------------
-- 2. Conta de aluno não vira professor por engano
-- ---------------------------------------------------------------------
-- Conta com vínculo ou pedido de aluno e sem nenhum dado de professor.
create or replace function public.hi_is_student_only(uid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select (exists (select 1 from public.student_links where user_id = uid)
          or exists (select 1 from public.join_requests where user_id = uid))
     and not exists (select 1 from public.teacher_data where teacher_id = uid)
     and not exists (select 1 from public.user_data where user_id = uid)
     and not exists (select 1 from public.organizations where owner_id = uid)
$$;
revoke execute on function public.hi_is_student_only(uuid) from public, anon;
grant execute on function public.hi_is_student_only(uuid) to authenticated;

create or replace function public.hi_ensure_teacher(p_name text default '') returns uuid
language plpgsql security invoker set search_path = public as $$
declare
  uid uuid := auth.uid();
  oid uuid;
begin
  if uid is null then raise exception 'not authenticated'; end if;
  if public.hi_is_student_only(uid) then
    raise exception 'Conta de aluno: não cria dados de professor' using errcode = 'P0001';
  end if;
  select id into oid from public.organizations where owner_id = uid and kind = 'solo';
  if oid is null then
    insert into public.organizations (name, kind, owner_id) values (coalesce(p_name, ''), 'solo', uid)
      on conflict (owner_id) where kind = 'solo' do nothing;
    select id into oid from public.organizations where owner_id = uid and kind = 'solo';
  end if;
  insert into public.org_members (org_id, user_id, role) values (oid, uid, 'owner') on conflict (org_id, user_id) do nothing;
  insert into public.teacher_data (teacher_id, org_id) values (uid, oid) on conflict (teacher_id) do nothing;
  update public.teacher_data set org_id = oid where teacher_id = uid and org_id is null;
  return oid;
end $$;

-- ---------------------------------------------------------------------
-- 3. Chave mais difícil de adivinhar
-- ---------------------------------------------------------------------
-- Chaves novas: 2 letras + 4 números (as de 3 números continuam valendo).
alter table public.teacher_codes drop constraint if exists teacher_codes_code_check;
alter table public.teacher_codes add constraint teacher_codes_code_check check (upper(code) ~ '^[A-Z]{1,4}[0-9]{3,4}$');

-- Tentativas de chave por usuário (no máximo 10 a cada 10 minutos). Só as funções mexem.
create table if not exists public.code_lookups (
  id bigserial primary key,
  user_id uuid not null,
  at timestamptz not null default now()
);
create index if not exists code_lookups_user_at on public.code_lookups (user_id, at);
alter table public.code_lookups enable row level security;
revoke all on public.code_lookups from anon, authenticated;

create or replace function public.hi_code_attempt() returns void
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Entre na sua conta antes de usar a chave' using errcode = '42501'; end if;
  delete from public.code_lookups where at < now() - interval '1 day';
  if (select count(*) from public.code_lookups where user_id = uid and at > now() - interval '10 minutes') >= 10 then
    raise exception 'Muitas tentativas, espere alguns minutos' using errcode = 'P0001';
  end if;
  insert into public.code_lookups (user_id) values (uid);
end $$;
revoke execute on function public.hi_code_attempt() from public, anon, authenticated;

-- Procurar a chave: só logado, sem devolver o teacher_id.
drop function if exists public.hi_find_teacher_code(text);
create function public.hi_find_teacher_code(p_code text)
returns table (display_name text, instruments jsonb, accepting boolean)
language plpgsql security definer set search_path = public as $$
begin
  perform public.hi_code_attempt();
  return query
  select coalesce(nullif(p.display_name, ''), 'Professor'),
         coalesce(p.settings -> 'instruments', '[]'::jsonb),
         c.active
    from public.teacher_codes c
    left join public.teacher_public p on p.teacher_id = c.teacher_id
   where upper(c.code) = upper(trim(coalesce(p_code, '')))
   limit 1;
end $$;
revoke execute on function public.hi_find_teacher_code(text) from public, anon;
grant execute on function public.hi_find_teacher_code(text) to authenticated;

-- Pedido de entrada: o servidor acha o professor pela chave.
create or replace function public.hi_create_join_request(p_code text, p_role text, p_student_name text,
  p_student_phone text default null, p_student_birth_date date default null, p_instrument text default null,
  p_guardian_name text default null, p_guardian_phone text default null)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  tid uuid;
  act boolean;
  rid uuid;
begin
  perform public.hi_code_attempt();
  select teacher_id, active into tid, act from public.teacher_codes where upper(code) = upper(trim(coalesce(p_code, '')));
  if tid is null then raise exception 'Chave não encontrada' using errcode = 'P0001'; end if;
  if not act then raise exception 'Este professor não está aceitando pedidos agora' using errcode = 'P0001'; end if;
  if tid = uid then raise exception 'Essa é a sua própria chave' using errcode = 'P0001'; end if;
  if coalesce(trim(p_student_name), '') = '' then raise exception 'Falta o nome do aluno' using errcode = 'P0001'; end if;
  insert into public.join_requests (teacher_id, user_id, role, student_name, student_phone, student_birth_date, instrument, guardian_name, guardian_phone)
    values (tid, uid, case when p_role = 'guardian' then 'guardian' else 'student' end, trim(p_student_name),
            nullif(trim(p_student_phone), ''), p_student_birth_date, nullif(trim(p_instrument), ''),
            nullif(trim(p_guardian_name), ''), nullif(trim(p_guardian_phone), ''))
    returning id into rid;
  return rid;
end $$;
revoke execute on function public.hi_create_join_request(text, text, text, text, date, text, text, text) from public, anon;
grant execute on function public.hi_create_join_request(text, text, text, text, date, text, text, text) to authenticated;

-- Pedido direto na tabela não pode mais (só pela função acima, que confere a chave).
drop policy if exists "join_insert" on public.join_requests;
revoke insert on public.join_requests from authenticated;

-- Meus pedidos: sem o teacher_id.
drop function if exists public.hi_my_join_requests();
create function public.hi_my_join_requests()
returns table (id uuid, role text, student_name text, status text, student_id uuid,
               created_at timestamptz, answered_at timestamptz, teacher_name text)
language sql stable security definer set search_path = public as $$
  select j.id, j.role, j.student_name, j.status, j.student_id, j.created_at, j.answered_at,
         coalesce(nullif(p.display_name, ''), 'Professor')
    from public.join_requests j
    left join public.teacher_public p on p.teacher_id = j.teacher_id
   where j.user_id = auth.uid()
   order by j.created_at desc
$$;
revoke execute on function public.hi_my_join_requests() from public, anon;
grant execute on function public.hi_my_join_requests() to authenticated;

notify pgrst, 'reload schema';

-- 8.45: grava esta versão (a lista de versões fica no servidor).
create table if not exists public.schema_versions (version text primary key, applied_at timestamptz not null default now());
alter table public.schema_versions enable row level security;
revoke all on public.schema_versions from anon, authenticated;
insert into public.schema_versions (version) values ('8.1.1') on conflict (version) do nothing;

$hiq$;
  else raise notice '8.1.1 já estava instalada.';
  end if;
end $hi$;

-- ---------- 8.3 ----------
do $hi$ begin
  if not (to_regclass('public.student_journal') is not null) then
    raise notice 'Instalando 8.3...';
    execute $hiq$

create table if not exists public.student_journal (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.students (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  teacher_id uuid references auth.users (id) on delete cascade,  -- preenchido pelo servidor
  data jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (student_id, user_id),
  constraint student_journal_size check (octet_length(data::text) <= 600000)
);
create index if not exists student_journal_teacher on public.student_journal (teacher_id, updated_at);

-- O professor da linha vem do cadastro do aluno (quem escreve não escolhe).
create or replace function public.hi_journal_teacher() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.teacher_id := (select teacher_id from public.students where id = new.student_id);
  new.updated_at := now();
  if tg_op = 'INSERT' then new.created_at := now(); end if;
  return new;
end $$;
drop trigger if exists hi_journal_teacher on public.student_journal;
create trigger hi_journal_teacher before insert or update on public.student_journal
  for each row execute function public.hi_journal_teacher();

alter table public.student_journal enable row level security;
drop policy if exists "sjournal_select" on public.student_journal;
create policy "sjournal_select" on public.student_journal for select to authenticated
  using ((user_id = auth.uid() and student_id in (select public.hi_my_student_ids())) or public.hi_owns_student(student_id));
drop policy if exists "sjournal_insert" on public.student_journal;
create policy "sjournal_insert" on public.student_journal for insert to authenticated
  with check (user_id = auth.uid() and student_id in (select public.hi_my_student_ids()));
drop policy if exists "sjournal_update" on public.student_journal;
create policy "sjournal_update" on public.student_journal for update to authenticated
  using (user_id = auth.uid() and student_id in (select public.hi_my_student_ids()))
  with check (user_id = auth.uid() and student_id in (select public.hi_my_student_ids()));
revoke all on public.student_journal from anon;
grant select, insert, update on public.student_journal to authenticated;

-- ---------------------------------------------------------------------
-- 2. Pedidos novos do aluno para o professor
--    song_request: "quero aprender esta música"; reschedule: remarcar uma aula num horário
--    vago do professor; makeup_request: marcar uma reposição pendente num horário vago.
-- ---------------------------------------------------------------------
alter table public.student_requests drop constraint if exists student_requests_type_check;
alter table public.student_requests add constraint student_requests_type_check
  check (type in ('absence', 'payment_notice', 'change_data', 'song_request', 'reschedule', 'makeup_request'));

-- No máximo 20 pedidos esperando resposta por conta (evita encher a caixa do professor).
create or replace function public.hi_student_requests_limit() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'pending' and (select count(*) from public.student_requests
       where author_user_id = new.author_user_id and status = 'pending' and id <> new.id) >= 20 then
    raise exception 'Muitos pedidos esperando o professor. Espere ele responder.' using errcode = 'P0001';
  end if;
  return new;
end $$;
drop trigger if exists hi_sreq_limit on public.student_requests;
create trigger hi_sreq_limit before insert on public.student_requests
  for each row execute function public.hi_student_requests_limit();

notify pgrst, 'reload schema';

-- 8.45: grava esta versão (a lista de versões fica no servidor).
create table if not exists public.schema_versions (version text primary key, applied_at timestamptz not null default now());
alter table public.schema_versions enable row level security;
revoke all on public.schema_versions from anon, authenticated;
insert into public.schema_versions (version) values ('8.3') on conflict (version) do nothing;

$hiq$;
  else raise notice '8.3 já estava instalada.';
  end if;
end $hi$;

-- ---------- 8.14 ----------
do $hi$ begin
  if not (to_regclass('public.account_deletions') is not null) then
    raise notice 'Instalando 8.14...';
    execute $hiq$

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

-- ---------------------------------------------------------------------
-- 6. Permissão para a função de envio (send-push)
-- ---------------------------------------------------------------------
-- A função usa a chave de serviço (service_role) e precisa ler quem é o autor e quem recebe.
-- Nos projetos novos do Supabase essa permissão não vem sozinha.
grant usage on schema public to service_role;
grant select on public.students, public.student_links, public.student_requests, public.join_requests,
  public.lessons, public.makeups, public.teacher_public, public.announcements,
  public.announcement_targets to service_role;
grant select, insert, update, delete on public.push_subscriptions, public.push_log to service_role;
grant select on public.notify_prefs to service_role;
grant usage, select on sequence public.push_log_id_seq to service_role;

notify pgrst, 'reload schema';

-- 8.45: grava esta versão (a lista de versões fica no servidor).
create table if not exists public.schema_versions (version text primary key, applied_at timestamptz not null default now());
alter table public.schema_versions enable row level security;
revoke all on public.schema_versions from anon, authenticated;
insert into public.schema_versions (version) values ('8.14') on conflict (version) do nothing;

$hiq$;
  else raise notice '8.14 já estava instalada.';
  end if;
end $hi$;

-- ---------- 8.23 ----------
do $hi$ begin
  if not (exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='hi_create_school')) then
    raise notice 'Instalando 8.23...';
    execute $hiq$

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

-- 8.45: grava esta versão (a lista de versões fica no servidor).
create table if not exists public.schema_versions (version text primary key, applied_at timestamptz not null default now());
alter table public.schema_versions enable row level security;
revoke all on public.schema_versions from anon, authenticated;
insert into public.schema_versions (version) values ('8.23') on conflict (version) do nothing;

$hiq$;
  else raise notice '8.23 já estava instalada.';
  end if;
end $hi$;

-- ---------- 8.24 ----------
do $hi$ begin
  if not (to_regclass('public.school_notices') is not null) then
    raise notice 'Instalando 8.24...';
    execute $hiq$

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

-- 8.45: grava esta versão (a lista de versões fica no servidor).
create table if not exists public.schema_versions (version text primary key, applied_at timestamptz not null default now());
alter table public.schema_versions enable row level security;
revoke all on public.schema_versions from anon, authenticated;
insert into public.schema_versions (version) values ('8.24') on conflict (version) do nothing;

$hiq$;
  else raise notice '8.24 já estava instalada.';
  end if;
end $hi$;

-- ---------- 8.35 ----------
do $hi$ begin
  if not (to_regclass('public.leads') is not null) then
    raise notice 'Instalando 8.35...';
    execute $hiq$

create table if not exists public.lead_links (
  teacher_id uuid primary key references auth.users(id) on delete cascade,
  token text not null unique,
  active boolean not null default true,
  created_at timestamptz not null default now()
);
alter table public.lead_links enable row level security;
-- Sem regras de leitura: só pelas funções abaixo.

-- Fichas enviadas. O app do professor passa cada uma para a lista de espera e apaga daqui.
create table if not exists public.leads (
  id uuid primary key default gen_random_uuid(),
  teacher_id uuid not null references auth.users(id) on delete cascade,
  data jsonb not null,
  created_at timestamptz not null default now()
);
create index if not exists leads_teacher_idx on public.leads (teacher_id, created_at);
alter table public.leads enable row level security;
drop policy if exists leads_teacher_select on public.leads;
create policy leads_teacher_select on public.leads for select to authenticated using (teacher_id = auth.uid());
drop policy if exists leads_teacher_delete on public.leads;
create policy leads_teacher_delete on public.leads for delete to authenticated using (teacher_id = auth.uid());

-- O professor pega (ou cria) o próprio link; p_active pausa ou reativa.
create or replace function public.hi_my_lead_link(p_active boolean default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); r record;
begin
  if uid is null then raise exception 'not authenticated'; end if;
  insert into public.lead_links (teacher_id, token)
    values (uid, replace(gen_random_uuid()::text, '-', ''))
    on conflict (teacher_id) do nothing;
  if p_active is not null then update public.lead_links set active = p_active where teacher_id = uid; end if;
  select token, active into r from public.lead_links where teacher_id = uid;
  return jsonb_build_object('token', r.token, 'active', r.active);
end $$;
revoke execute on function public.hi_my_lead_link(boolean) from public, anon;
grant execute on function public.hi_my_lead_link(boolean) to authenticated;

-- Quem abre o link (sem conta) vê o nome do professor e o que ele ensina.
create or replace function public.hi_lead_form(p_token text) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
           'name', coalesce(nullif(p.display_name, ''), 'Professor'),
           'instruments', coalesce(p.settings -> 'instruments', '[]'::jsonb),
           'active', l.active)
    from public.lead_links l
    left join public.teacher_public p on p.teacher_id = l.teacher_id
   where l.token = trim(coalesce(p_token, ''))
   limit 1;
$$;
revoke execute on function public.hi_lead_form(text) from public;
grant execute on function public.hi_lead_form(text) to anon, authenticated;

-- Enviar a ficha. Limites: 20 fichas por hora e 200 guardadas por professor.
create or replace function public.hi_submit_lead(p_token text, p_data jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare tid uuid; act boolean; n int; d jsonb := coalesce(p_data, '{}'::jsonb);
begin
  select teacher_id, active into tid, act from public.lead_links where token = trim(coalesce(p_token, ''));
  if tid is null then raise exception 'Link não encontrado. Peça um link novo para o professor.' using errcode = 'P0001'; end if;
  if not act then raise exception 'Este professor não está recebendo fichas agora.' using errcode = 'P0001'; end if;
  if jsonb_typeof(d) <> 'object' or length(d::text) > 4000 then raise exception 'Ficha inválida.' using errcode = 'P0001'; end if;
  if coalesce(trim(d ->> 'name'), '') = '' then raise exception 'Escreva o nome.' using errcode = 'P0001'; end if;
  select count(*) into n from public.leads where teacher_id = tid and created_at > now() - interval '1 hour';
  if n >= 20 then raise exception 'Muitas fichas agora. Tente de novo mais tarde.' using errcode = 'P0001'; end if;
  select count(*) into n from public.leads where teacher_id = tid;
  if n >= 200 then raise exception 'O professor está com muitas fichas para ver. Tente de novo mais tarde.' using errcode = 'P0001'; end if;
  insert into public.leads (teacher_id, data) values (tid, jsonb_build_object(
    'name', left(trim(d ->> 'name'), 80),
    'age', left(coalesce(d ->> 'age', ''), 3),
    'guardian', left(coalesce(d ->> 'guardian', ''), 80),
    'phone', left(coalesce(d ->> 'phone', ''), 30),
    'instrument', left(coalesce(d ->> 'instrument', ''), 60),
    'time', left(coalesce(d ->> 'time', ''), 5),
    'notes', left(coalesce(d ->> 'notes', ''), 600),
    'days', case when jsonb_typeof(d -> 'days') = 'array' and jsonb_array_length(d -> 'days') <= 7 then d -> 'days' else '[]'::jsonb end));
end $$;
revoke execute on function public.hi_submit_lead(text, jsonb) from public;
grant execute on function public.hi_submit_lead(text, jsonb) to anon, authenticated;

-- 8.45: grava esta versão (a lista de versões fica no servidor).
create table if not exists public.schema_versions (version text primary key, applied_at timestamptz not null default now());
alter table public.schema_versions enable row level security;
revoke all on public.schema_versions from anon, authenticated;
insert into public.schema_versions (version) values ('8.35') on conflict (version) do nothing;

$hiq$;
  else raise notice '8.35 já estava instalada.';
  end if;
end $hi$;

-- ---------- 8.36 ----------
do $hi$ begin
  if not (coalesce((select string_agg(pg_get_functiondef(p.oid),' ') from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='hi_join_school'),'') like '%hi_code_attempt%') then
    raise notice 'Instalando 8.36...';
    execute $hiq$

drop policy if exists "links_insert" on public.student_links;
create policy "links_insert" on public.student_links for insert to authenticated
  with check (public.hi_owns_student(student_id)
              and exists (select 1 from public.join_requests jr
                           where jr.teacher_id = auth.uid() and jr.user_id = student_links.user_id));
drop policy if exists "links_update" on public.student_links;
create policy "links_update" on public.student_links for update to authenticated
  using (public.hi_owns_student(student_id))
  with check (public.hi_owns_student(student_id)
              and exists (select 1 from public.join_requests jr
                           where jr.teacher_id = auth.uid() and jr.user_id = student_links.user_id));

-- 2) Chave da escola: o mesmo limite de tentativas da chave do professor (10 a cada 10 minutos),
--    pra ninguém ficar testando chaves até achar as escolas.
create or replace function public.hi_find_school(p_code text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare r record;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  perform public.hi_code_attempt();
  select o.id, o.name, (select om.display_name from public.org_members om where om.org_id = o.id and om.user_id = o.owner_id) as owner_name
    into r from public.organizations o where o.kind = 'school' and upper(o.code) = upper(btrim(coalesce(p_code, '')));
  if r.id is null then return null; end if;
  return jsonb_build_object('name', r.name, 'owner_name', coalesce(r.owner_name, ''));
end $$;

create or replace function public.hi_join_school(p_code text, p_display text default '') returns jsonb
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); oid uuid;
begin
  if uid is null then raise exception 'not authenticated'; end if;
  if not exists (select 1 from public.teacher_data where teacher_id = uid) then raise exception 'Só conta de professor pode entrar numa escola'; end if;
  perform public.hi_code_attempt();
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

-- 3) Notificações: só aceitar endereços dos serviços de notificação de verdade
--    (Google/Android e Chrome, Firefox, Windows/Edge, Apple). Vale para os novos; os que já existem ficam.
alter table public.push_subscriptions drop constraint if exists push_endpoint_host;
alter table public.push_subscriptions add constraint push_endpoint_host check (
  endpoint ~ '^https://([a-z0-9-]+\.)*(fcm\.googleapis\.com|push\.services\.mozilla\.com|notify\.windows\.com|push\.apple\.com)/'
) not valid;

-- 8.45: grava esta versão (a lista de versões fica no servidor).
create table if not exists public.schema_versions (version text primary key, applied_at timestamptz not null default now());
alter table public.schema_versions enable row level security;
revoke all on public.schema_versions from anon, authenticated;
insert into public.schema_versions (version) values ('8.36') on conflict (version) do nothing;

$hiq$;
  else raise notice '8.36 já estava instalada.';
  end if;
end $hi$;

-- ---------- 8.38 ----------
do $hi$ begin
  if not (to_regclass('public.teacher_plans') is not null) then
    raise notice 'Instalando 8.38...';
    execute $hiq$

create table if not exists public.teacher_plans (
  teacher_id uuid primary key references auth.users(id) on delete cascade,
  plan text not null default 'trial' check (plan in ('trial','free','bronze','silver','gold','school')),
  trial_until date not null default (current_date + 14),
  paid_until date,
  requested text check (requested in ('free','bronze','silver','gold','school')),
  requested_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.teacher_plans enable row level security;
drop policy if exists teacher_plans_select on public.teacher_plans;
create policy teacher_plans_select on public.teacher_plans for select to authenticated using (teacher_id = auth.uid());
revoke insert, update, delete on public.teacher_plans from anon, authenticated;

-- Quem administra os planos (o dono do app).
create table if not exists public.app_admins (
  user_id uuid primary key references auth.users(id) on delete cascade
);
alter table public.app_admins enable row level security;
revoke all on public.app_admins from anon, authenticated;

create or replace function public.hi_is_app_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.app_admins where user_id = auth.uid());
$$;
revoke execute on function public.hi_is_app_admin() from public, anon;
grant execute on function public.hi_is_app_admin() to authenticated;

-- O professor lê o próprio plano. No primeiro acesso, começa o teste de 14 dias.
create or replace function public.hi_my_plan() returns jsonb
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); r public.teacher_plans;
begin
  if uid is null then raise exception 'not authenticated' using errcode = '42501'; end if;
  insert into public.teacher_plans (teacher_id) values (uid) on conflict (teacher_id) do nothing;
  select * into r from public.teacher_plans where teacher_id = uid;
  return jsonb_build_object('plan', r.plan, 'trial_until', r.trial_until, 'paid_until', r.paid_until,
    'requested', r.requested, 'requested_at', r.requested_at, 'today', current_date,
    'admin', public.hi_is_app_admin());
end $$;
revoke execute on function public.hi_my_plan() from public, anon;
grant execute on function public.hi_my_plan() to authenticated;

-- O professor escolhe um plano. Grátis vale na hora (até 5 alunos ativos);
-- os pagos ficam como pedido até o dono do app confirmar o pagamento.
create or replace function public.hi_choose_plan(p_plan text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); n int;
begin
  if uid is null then raise exception 'not authenticated' using errcode = '42501'; end if;
  if p_plan not in ('free','bronze','silver','gold','school') then raise exception 'Plano inválido.' using errcode = 'P0001'; end if;
  insert into public.teacher_plans (teacher_id) values (uid) on conflict (teacher_id) do nothing;
  if p_plan = 'free' then
    select count(*) into n from public.students where teacher_id = uid and coalesce(active, true);
    if n > 5 then raise exception 'O plano Grátis vai até 5 alunos ativos.' using errcode = 'P0001'; end if;
    update public.teacher_plans set plan = 'free', requested = null, requested_at = null, updated_at = now() where teacher_id = uid;
  else
    update public.teacher_plans set requested = p_plan, requested_at = now(), updated_at = now() where teacher_id = uid;
  end if;
  return public.hi_my_plan();
end $$;
revoke execute on function public.hi_choose_plan(text) from public, anon;
grant execute on function public.hi_choose_plan(text) to authenticated;

-- Dono do app: lista dos professores com plano, pedido e alunos ativos.
create or replace function public.hi_admin_plans() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.hi_is_app_admin() then raise exception 'Só o dono do app.' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(x order by x->>'requested_at' desc nulls last, x->>'name') from (
    select jsonb_build_object(
      'id', u.id, 'email', u.email,
      'name', coalesce(nullif(tp.display_name, ''), split_part(u.email, '@', 1)),
      'created_at', u.created_at,
      'plan', coalesce(p.plan, 'trial'), 'trial_until', p.trial_until, 'paid_until', p.paid_until,
      'requested', p.requested, 'requested_at', p.requested_at,
      'students', (select count(*) from public.students s where s.teacher_id = u.id and coalesce(s.active, true))) as x
    from public.teacher_data td
    join auth.users u on u.id = td.teacher_id
    left join public.teacher_plans p on p.teacher_id = u.id
    left join public.teacher_public tp on tp.teacher_id = u.id) q), '[]'::jsonb);
end $$;
revoke execute on function public.hi_admin_plans() from public, anon;
grant execute on function public.hi_admin_plans() to authenticated;

-- Dono do app: ativa (ou renova) o plano de um professor por N meses.
create or replace function public.hi_admin_set_plan(p_teacher uuid, p_plan text, p_months int) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.hi_is_app_admin() then raise exception 'Só o dono do app.' using errcode = '42501'; end if;
  if p_plan not in ('free','bronze','silver','gold','school') then raise exception 'Plano inválido.' using errcode = 'P0001'; end if;
  insert into public.teacher_plans (teacher_id) values (p_teacher) on conflict (teacher_id) do nothing;
  update public.teacher_plans set
    plan = p_plan,
    paid_until = case when p_plan = 'free' then null
                      else greatest(coalesce(paid_until, current_date), current_date) + make_interval(months => greatest(coalesce(p_months, 1), 1)) end,
    requested = null, requested_at = null, updated_at = now()
  where teacher_id = p_teacher;
end $$;
revoke execute on function public.hi_admin_set_plan(uuid, text, int) from public, anon;
grant execute on function public.hi_admin_set_plan(uuid, text, int) to authenticated;

-- Dono do app (troque o email se você entra com outro).
insert into public.app_admins (user_id)
  select id from auth.users where lower(email) = lower('profjpleguizamon@gmail.com')
  on conflict (user_id) do nothing;

-- 8.45: grava esta versão (a lista de versões fica no servidor).
create table if not exists public.schema_versions (version text primary key, applied_at timestamptz not null default now());
alter table public.schema_versions enable row level security;
revoke all on public.schema_versions from anon, authenticated;
insert into public.schema_versions (version) values ('8.38') on conflict (version) do nothing;

$hiq$;
  else raise notice '8.38 já estava instalada.';
  end if;
end $hi$;

-- ---------- 8.41 ----------
do $hi$ begin
  if not (exists (select 1 from information_schema.columns where table_schema='public' and table_name='teacher_plans' and column_name='ref_code')) then
    raise notice 'Instalando 8.41...';
    execute $hiq$

alter table public.teacher_plans add column if not exists ref_code text;
alter table public.teacher_plans add column if not exists referred_by uuid references auth.users(id) on delete set null;
alter table public.teacher_plans add column if not exists ref_rewarded boolean not null default false;
alter table public.teacher_plans add column if not exists credit_months int not null default 0;
create unique index if not exists teacher_plans_ref_code on public.teacher_plans (ref_code) where ref_code is not null;

-- O professor lê o próprio plano (agora com o código de indicação e os meses ganhos).
create or replace function public.hi_my_plan() returns jsonb
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); r public.teacher_plans; c text; tries int := 0;
begin
  if uid is null then raise exception 'not authenticated' using errcode = '42501'; end if;
  insert into public.teacher_plans (teacher_id) values (uid) on conflict (teacher_id) do nothing;
  select * into r from public.teacher_plans where teacher_id = uid;
  while r.ref_code is null and tries < 5 loop
    tries := tries + 1;
    c := upper(substr(md5(random()::text || clock_timestamp()::text), 1, 6));
    begin
      update public.teacher_plans set ref_code = c where teacher_id = uid and ref_code is null;
    exception when unique_violation then null;
    end;
    select * into r from public.teacher_plans where teacher_id = uid;
  end loop;
  return jsonb_build_object('plan', r.plan, 'trial_until', r.trial_until, 'paid_until', r.paid_until,
    'requested', r.requested, 'requested_at', r.requested_at, 'today', current_date,
    'admin', public.hi_is_app_admin(),
    'ref_code', r.ref_code, 'credit_months', r.credit_months, 'referred', r.referred_by is not null,
    'ref_count', (select count(*) from public.teacher_plans x where x.referred_by = uid),
    'ref_paid', (select count(*) from public.teacher_plans x where x.referred_by = uid and x.ref_rewarded));
end $$;
revoke execute on function public.hi_my_plan() from public, anon;
grant execute on function public.hi_my_plan() to authenticated;

-- Conta nova que entrou pelo link de um colega: guarda quem indicou (uma vez só, e só antes de pagar).
create or replace function public.hi_set_referrer(p_code text) returns boolean
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); ref uuid; me public.teacher_plans;
begin
  if uid is null then raise exception 'not authenticated' using errcode = '42501'; end if;
  insert into public.teacher_plans (teacher_id) values (uid) on conflict (teacher_id) do nothing;
  select * into me from public.teacher_plans where teacher_id = uid;
  if me.referred_by is not null or me.paid_until is not null then return false; end if;
  select teacher_id into ref from public.teacher_plans where ref_code = upper(btrim(coalesce(p_code, '')));
  if ref is null or ref = uid then return false; end if;
  update public.teacher_plans set referred_by = ref, updated_at = now() where teacher_id = uid;
  return true;
end $$;
revoke execute on function public.hi_set_referrer(text) from public, anon;
grant execute on function public.hi_set_referrer(text) to authenticated;

-- Dono do app: lista com indicação e data de cadastro.
create or replace function public.hi_admin_plans() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.hi_is_app_admin() then raise exception 'Só o dono do app.' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(x order by x->>'requested_at' desc nulls last, x->>'name') from (
    select jsonb_build_object(
      'id', u.id, 'email', u.email,
      'name', coalesce(nullif(tp.display_name, ''), split_part(u.email, '@', 1)),
      'created_at', u.created_at,
      'plan', coalesce(p.plan, 'trial'), 'trial_until', p.trial_until, 'paid_until', p.paid_until,
      'requested', p.requested, 'requested_at', p.requested_at,
      'credit_months', coalesce(p.credit_months, 0),
      'referred_by', (select coalesce(nullif(rp.display_name, ''), split_part(ru.email, '@', 1))
                        from auth.users ru left join public.teacher_public rp on rp.teacher_id = ru.id where ru.id = p.referred_by),
      'students', (select count(*) from public.students s where s.teacher_id = u.id and coalesce(s.active, true))) as x
    from public.teacher_data td
    join auth.users u on u.id = td.teacher_id
    left join public.teacher_plans p on p.teacher_id = u.id
    left join public.teacher_public tp on tp.teacher_id = u.id) q), '[]'::jsonb);
end $$;
revoke execute on function public.hi_admin_plans() from public, anon;
grant execute on function public.hi_admin_plans() to authenticated;

-- Dono do app: ativa (ou renova) um plano. Soma os meses ganhos por indicação e, na primeira
-- vez que um indicado paga, dá 1 mês para quem indicou.
create or replace function public.hi_admin_set_plan(p_teacher uuid, p_plan text, p_months int) returns void
language plpgsql security definer set search_path = public as $$
declare me public.teacher_plans; m int := greatest(coalesce(p_months, 1), 1);
begin
  if not public.hi_is_app_admin() then raise exception 'Só o dono do app.' using errcode = '42501'; end if;
  if p_plan not in ('free','bronze','silver','gold','school') then raise exception 'Plano inválido.' using errcode = 'P0001'; end if;
  insert into public.teacher_plans (teacher_id) values (p_teacher) on conflict (teacher_id) do nothing;
  select * into me from public.teacher_plans where teacher_id = p_teacher;
  if p_plan = 'free' then
    update public.teacher_plans set plan = 'free', paid_until = null, requested = null, requested_at = null, updated_at = now() where teacher_id = p_teacher;
    return;
  end if;
  update public.teacher_plans set
    plan = p_plan,
    paid_until = greatest(coalesce(paid_until, current_date), current_date) + make_interval(months => m + coalesce(credit_months, 0)),
    credit_months = 0, requested = null, requested_at = null, updated_at = now()
  where teacher_id = p_teacher;
  if me.referred_by is not null and not me.ref_rewarded then
    update public.teacher_plans set ref_rewarded = true where teacher_id = p_teacher;
    update public.teacher_plans set
      paid_until = case when plan in ('bronze','silver','gold','school') and paid_until >= current_date then paid_until + interval '1 month' else paid_until end,
      credit_months = case when plan in ('bronze','silver','gold','school') and paid_until >= current_date then credit_months else credit_months + 1 end,
      updated_at = now()
    where teacher_id = me.referred_by;
  end if;
end $$;
revoke execute on function public.hi_admin_set_plan(uuid, text, int) from public, anon;
grant execute on function public.hi_admin_set_plan(uuid, text, int) to authenticated;

-- 8.45: grava esta versão (a lista de versões fica no servidor).
create table if not exists public.schema_versions (version text primary key, applied_at timestamptz not null default now());
alter table public.schema_versions enable row level security;
revoke all on public.schema_versions from anon, authenticated;
insert into public.schema_versions (version) values ('8.41') on conflict (version) do nothing;

$hiq$;
  else raise notice '8.41 já estava instalada.';
  end if;
end $hi$;

-- ---------- 8.45 ----------
do $hi$ begin
  if not (to_regclass('public.plan_events') is not null and exists (select 1 from information_schema.columns where table_schema='public' and table_name='teacher_plans' and column_name='grace_from')) then
    raise notice 'Instalando 8.45...';
    execute $hiq$

create table if not exists public.schema_versions (
  version text primary key,
  applied_at timestamptz not null default now()
);
alter table public.schema_versions enable row level security;
revoke all on public.schema_versions from anon, authenticated;

-- O que está instalado, pelo que existe no servidor (vale também para o que foi rodado antes desta versão).
create or replace function public.hi_schema_detect() returns text[]
language plpgsql stable security definer set search_path = public as $$
declare out text[] := '{}'; fn text;
begin
  if to_regclass('public.teacher_data') is not null then out := array_append(out, '8.0'); end if;
  if to_regclass('public.student_view') is not null then out := array_append(out, '8.1'); end if;
  if to_regclass('public.lesson_private') is not null then out := array_append(out, '8.1.1'); end if;
  if to_regclass('public.student_journal') is not null then out := array_append(out, '8.3'); end if;
  if to_regclass('public.account_deletions') is not null then out := array_append(out, '8.14'); end if;
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'hi_create_school') then out := array_append(out, '8.23'); end if;
  if to_regclass('public.school_notices') is not null then out := array_append(out, '8.24'); end if;
  if to_regclass('public.leads') is not null then out := array_append(out, '8.35'); end if;
  select string_agg(pg_get_functiondef(p.oid), ' ') into fn from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'hi_join_school';
  if fn like '%hi_code_attempt%' then out := array_append(out, '8.36'); end if;
  if to_regclass('public.teacher_plans') is not null then out := array_append(out, '8.38'); end if;
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'teacher_plans' and column_name = 'ref_code') then out := array_append(out, '8.41'); end if;
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'teacher_plans' and column_name = 'grace_from') then out := array_append(out, '8.44'); end if;
  if to_regclass('public.plan_events') is not null then out := array_append(out, '8.45'); end if;
  return out;
end $$;
revoke execute on function public.hi_schema_detect() from public, anon, authenticated;

-- Dono do app: lista do que já está no servidor.
create or replace function public.hi_schema_status() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.hi_is_app_admin() then raise exception 'Só o dono do app.' using errcode = '42501'; end if;
  return jsonb_build_object('installed', to_jsonb(public.hi_schema_detect()),
    'recorded', coalesce((select jsonb_agg(version order by applied_at) from public.schema_versions), '[]'::jsonb));
end $$;
revoke execute on function public.hi_schema_status() from public, anon;
grant execute on function public.hi_schema_status() to authenticated;

-- 2) Histórico de cada ativação de plano feita pelo dono do app (para separar quem paga de verdade
--    de quem só está com mês ganho por indicação).
create table if not exists public.plan_events (
  id bigint generated always as identity primary key,
  teacher_id uuid not null references auth.users(id) on delete cascade,
  plan text not null,
  months int not null default 0,
  kind text not null default 'paid' check (kind in ('paid','referral','free')),
  created_at timestamptz not null default now()
);
create index if not exists plan_events_teacher on public.plan_events (teacher_id, created_at desc);
alter table public.plan_events enable row level security;
revoke all on public.plan_events from anon, authenticated;

-- Igual à 8.41, e agora guarda a ativação no histórico.
create or replace function public.hi_admin_set_plan(p_teacher uuid, p_plan text, p_months int) returns void
language plpgsql security definer set search_path = public as $$
declare me public.teacher_plans; m int := greatest(coalesce(p_months, 1), 1);
begin
  if not public.hi_is_app_admin() then raise exception 'Só o dono do app.' using errcode = '42501'; end if;
  if p_plan not in ('free','bronze','silver','gold','school') then raise exception 'Plano inválido.' using errcode = 'P0001'; end if;
  insert into public.teacher_plans (teacher_id) values (p_teacher) on conflict (teacher_id) do nothing;
  select * into me from public.teacher_plans where teacher_id = p_teacher;
  if p_plan = 'free' then
    update public.teacher_plans set plan = 'free', paid_until = null, requested = null, requested_at = null, updated_at = now() where teacher_id = p_teacher;
    insert into public.plan_events (teacher_id, plan, months, kind) values (p_teacher, 'free', 0, 'free');
    return;
  end if;
  update public.teacher_plans set
    plan = p_plan,
    paid_until = greatest(coalesce(paid_until, current_date), current_date) + make_interval(months => m + coalesce(credit_months, 0)),
    credit_months = 0, requested = null, requested_at = null, updated_at = now()
  where teacher_id = p_teacher;
  insert into public.plan_events (teacher_id, plan, months, kind) values (p_teacher, p_plan, m, 'paid');
  if me.referred_by is not null and not me.ref_rewarded then
    update public.teacher_plans set ref_rewarded = true where teacher_id = p_teacher;
    update public.teacher_plans set
      paid_until = case when plan in ('bronze','silver','gold','school') and paid_until >= current_date then paid_until + interval '1 month' else paid_until end,
      credit_months = case when plan in ('bronze','silver','gold','school') and paid_until >= current_date then credit_months else credit_months + 1 end,
      updated_at = now()
    where teacher_id = me.referred_by;
    insert into public.plan_events (teacher_id, plan, months, kind)
      select me.referred_by, coalesce(plan, 'trial'), 1, 'referral' from public.teacher_plans where teacher_id = me.referred_by;
  end if;
end $$;
revoke execute on function public.hi_admin_set_plan(uuid, text, int) from public, anon;
grant execute on function public.hi_admin_set_plan(uuid, text, int) to authenticated;

-- Igual à 8.41, mais: quem é o dono do app, último acesso, aulas dos últimos 7 dias,
-- última ativação paga e aluno excluído fora da conta.
create or replace function public.hi_admin_plans() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.hi_is_app_admin() then raise exception 'Só o dono do app.' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(x order by x->>'requested_at' desc nulls last, x->>'name') from (
    select jsonb_build_object(
      'id', u.id, 'email', u.email,
      'name', coalesce(nullif(tp.display_name, ''), split_part(u.email, '@', 1)),
      'created_at', u.created_at,
      'plan', coalesce(p.plan, 'trial'), 'trial_until', p.trial_until, 'paid_until', p.paid_until,
      'requested', p.requested, 'requested_at', p.requested_at,
      'credit_months', coalesce(p.credit_months, 0),
      'referred_by', (select coalesce(nullif(rp.display_name, ''), split_part(ru.email, '@', 1))
                        from auth.users ru left join public.teacher_public rp on rp.teacher_id = ru.id where ru.id = p.referred_by),
      'students', (select count(*) from public.students s where s.teacher_id = u.id and coalesce(s.active, true) and not s.deleted),
      'is_admin', exists (select 1 from public.app_admins a where a.user_id = u.id),
      'last_seen', greatest(u.last_sign_in_at, td.updated_at,
                    (select max(s.updated_at) from public.students s where s.teacher_id = u.id),
                    (select max(l.updated_at) from public.lessons l where l.teacher_id = u.id)),
      'lessons_7d', (select count(*) from public.lessons l where l.teacher_id = u.id and not l.deleted and l.date >= current_date - 7 and l.date <= current_date),
      'last_paid_at', (select max(e.created_at) from public.plan_events e where e.teacher_id = u.id and e.kind = 'paid'),
      'last_paid_months', (select e.months from public.plan_events e where e.teacher_id = u.id and e.kind = 'paid' order by e.created_at desc limit 1)) as x
    from public.teacher_data td
    join auth.users u on u.id = td.teacher_id
    left join public.teacher_plans p on p.teacher_id = u.id
    left join public.teacher_public tp on tp.teacher_id = u.id) q), '[]'::jsonb);
end $$;
revoke execute on function public.hi_admin_plans() from public, anon;
grant execute on function public.hi_admin_plans() to authenticated;

-- 2b) O que a 8.44 fazia: os 3 dias de "esperando o pagamento" valem uma vez só.
-- Quando começaram os 3 dias de espera da última vez. Volta a valer depois que o professor paga.

alter table public.teacher_plans add column if not exists grace_from timestamptz;

create or replace function public.hi_choose_plan(p_plan text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); n int; r public.teacher_plans; fresh boolean;
begin
  if uid is null then raise exception 'not authenticated' using errcode = '42501'; end if;
  if p_plan not in ('free','bronze','silver','gold','school') then raise exception 'Plano inválido.' using errcode = 'P0001'; end if;
  insert into public.teacher_plans (teacher_id) values (uid) on conflict (teacher_id) do nothing;
  if p_plan = 'free' then
    select count(*) into n from public.students where teacher_id = uid and coalesce(active, true) and not coalesce(deleted, false);
    if n > 5 then raise exception 'O plano Grátis vai até 5 alunos ativos.' using errcode = 'P0001'; end if;
    update public.teacher_plans set plan = 'free', requested = null, requested_at = null, updated_at = now() where teacher_id = uid;
  else
    select * into r from public.teacher_plans where teacher_id = uid;
    -- Primeiro pedido, ou já pagou depois do último pedido: ganha os 3 dias. Senão o prazo continua o antigo.
    fresh := r.grace_from is null or (r.paid_until is not null and r.paid_until >= r.grace_from::date);
    update public.teacher_plans set requested = p_plan,
      requested_at = case when fresh then now() else r.grace_from end,
      grace_from = case when fresh then now() else r.grace_from end,
      updated_at = now()
    where teacher_id = uid;
  end if;
  return public.hi_my_plan();
end $$;
revoke execute on function public.hi_choose_plan(text) from public, anon;
grant execute on function public.hi_choose_plan(text) to authenticated;

-- 3) Marca o que já está instalado e esta versão.
insert into public.schema_versions (version) select unnest(public.hi_schema_detect()) on conflict (version) do nothing;
insert into public.schema_versions (version) values ('8.44'), ('8.45') on conflict (version) do nothing;

$hiq$;
  else raise notice '8.45 já estava instalada.';
  end if;
end $hi$;

-- Resultado: tudo que está instalado (precisa listar até 8.45).
select public.hi_schema_detect() as instalado;
