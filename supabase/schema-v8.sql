-- =====================================================================
-- Hi Teacher 8.0 — dados em tabelas (base do app do aluno e das escolas)
-- =====================================================================
-- Como rodar: Supabase → SQL Editor → New query → colar este arquivo inteiro → Run.
-- É seguro rodar mais de uma vez (create if not exists, drop policy if exists...).
-- Não apaga nada: a tabela user_data (JSON antigo) continua intacta, como backup.
-- Explicação completa no HI-TEACHER.md, seção "Dados em tabelas (8.0)".

-- ---------------------------------------------------------------------
-- Funções de apoio
-- ---------------------------------------------------------------------

-- updated_at automático (tabelas sem "changed_at").
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
