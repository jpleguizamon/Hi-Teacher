-- =====================================================================
-- Hi Teacher 8.38 — planos dos professores (teste grátis de 14 dias)
-- =====================================================================
-- Precisa da 8.0 instalada antes.
-- Como rodar: Supabase → SQL Editor → New query → colar este arquivo inteiro → Run.
-- É seguro rodar mais de uma vez. Não apaga nenhum dado.
-- Sem este arquivo o app continua igual (sem planos e sem limite de alunos).
-- Explicação no HI-TEACHER.md, seção "Planos e login com Google (8.38)".
--
-- IMPORTANTE: no fim do arquivo, o email do dono do app (quem ativa os planos). Se você
-- entra no app com outro email, troque antes de rodar.

-- Plano de cada professor. Só o servidor muda esta tabela (pelas funções abaixo).
--   plan: trial (teste) | free | bronze | silver | gold | school
--   trial_until: fim do teste grátis (14 dias a partir do primeiro acesso com planos)
--   paid_until: até quando o plano pago está pago (o dono do app marca)
--   requested: plano que o professor escolheu e ainda não pagou
-- 8.45: não deixa rodar este arquivo por cima de uma versão mais nova (ele desfaria mudanças).
do $$ declare newer boolean; begin
  if to_regclass('public.schema_versions') is not null then
    execute 'select exists (select 1 from public.schema_versions where string_to_array(version, ''.'')::int[] > string_to_array($1, ''.'')::int[])' into newer using '8.38';
    if newer then
      raise exception 'Este arquivo (8.38) é mais antigo que o que já está no servidor. Não rode: ele desfaria mudanças mais novas.';
    end if;
  end if;
end $$;

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
