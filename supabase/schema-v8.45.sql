-- =====================================================================
-- Hi Teacher 8.45 — conferir as atualizações do servidor e números da tela Assinaturas
-- =====================================================================
-- Precisa da 8.38 e da 8.41 instaladas antes. Já inclui a 8.44 (não precisa rodar a 8.44 separada).
-- Como rodar: Supabase → SQL Editor → New query → colar este arquivo inteiro → Run.
-- É seguro rodar mais de uma vez. Não apaga nenhum dado.
-- Sem este arquivo o app continua igual; só não mostra o que falta rodar e os números novos.
-- Explicação no HI-TEACHER.md, seção "Base firme (8.45)".

-- 1) Quais atualizações do servidor já foram rodadas. A partir daqui, cada arquivo grava a
--    sua versão no fim e recusa rodar se já existir uma versão mais nova (ele desfaria mudanças).
-- 8.45: não deixa rodar este arquivo por cima de uma versão mais nova (ele desfaria mudanças).
do $$ declare newer boolean; begin
  if to_regclass('public.schema_versions') is not null then
    execute 'select exists (select 1 from public.schema_versions where string_to_array(version, ''.'')::int[] > string_to_array($1, ''.'')::int[])' into newer using '8.45';
    if newer then
      raise exception 'Este arquivo (8.45) é mais antigo que o que já está no servidor. Não rode: ele desfaria mudanças mais novas.';
    end if;
  end if;
end $$;

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
