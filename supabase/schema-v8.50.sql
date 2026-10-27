-- =====================================================================
-- Hi Teacher 8.50 — cobrança automática pelo Asaas (dos alunos e dos planos do app)
-- =====================================================================
-- Rodar depois da 8.45 (precisa das tabelas dos planos da 8.38/8.41/8.45). Como rodar: Supabase → SQL Editor → New query → colar este arquivo inteiro → Run.
-- É seguro rodar mais de uma vez. Não apaga nenhum dado.
-- Sem este arquivo (e sem a função "asaas") o app continua igual: a cobrança automática só não aparece ligada.
-- Explicação e passo a passo no HI-TEACHER.md, seção "Cobrança automática pelo Asaas (8.50)".

do $$ declare newer boolean; begin
  if to_regclass('public.schema_versions') is not null then
    execute 'select exists (select 1 from public.schema_versions where string_to_array(version, ''.'')::int[] > string_to_array($1, ''.'')::int[])' into newer using '8.50';
    if newer then
      raise exception 'Este arquivo (8.50) é mais antigo que o que já está no servidor. Não rode: ele desfaria mudanças mais novas.';
    end if;
  end if;
end $$;

create table if not exists public.schema_versions (
  version text primary key,
  applied_at timestamptz not null default now()
);
alter table public.schema_versions enable row level security;
revoke all on public.schema_versions from anon, authenticated;

-- 1) Conta do Asaas de cada professor. A chave fica trancada (a função "asaas" tranca e destranca
--    com o segredo ASAAS_SECRET). Ninguém lê esta tabela pelo app, nem o próprio professor.
create table if not exists public.asaas_accounts (
  teacher_id uuid primary key references auth.users(id) on delete cascade,
  api_key_enc text not null,
  sandbox boolean not null default false,
  hook_token text not null,
  hook_id text,
  account_name text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.asaas_accounts enable row level security;
revoke all on public.asaas_accounts from anon, authenticated;

-- 2) Cliente do Asaas de cada aluno (quem paga), para não criar repetido.
create table if not exists public.asaas_customers (
  teacher_id uuid not null references auth.users(id) on delete cascade,
  student_uuid text not null,
  customer_id text not null,
  doc text,
  primary key (teacher_id, student_uuid)
);
alter table public.asaas_customers enable row level security;
revoke all on public.asaas_customers from anon, authenticated;

-- 3) Cobranças geradas. O Asaas avisa a função quando o aluno paga; o app lê e marca o mês como pago.
create table if not exists public.asaas_charges (
  id text primary key,
  teacher_id uuid not null references auth.users(id) on delete cascade,
  student_uuid text not null,
  month text not null,
  value numeric not null,
  due_date date not null,
  status text not null default 'open',
  invoice_url text,
  paid_at date,
  net_value numeric,
  applied boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists asaas_charges_teacher on public.asaas_charges (teacher_id, month);
alter table public.asaas_charges enable row level security;
revoke all on public.asaas_charges from anon, authenticated;
grant select on public.asaas_charges to authenticated;
drop policy if exists asaas_charges_own on public.asaas_charges;
create policy asaas_charges_own on public.asaas_charges for select to authenticated using (teacher_id = auth.uid());

-- 4) O app pergunta se a conta está ligada (sem nunca ver a chave).
create or replace function public.hi_asaas_status() returns jsonb
language sql security definer set search_path = public stable as $$
  select coalesce((select jsonb_build_object('connected', true, 'sandbox', a.sandbox, 'name', a.account_name, 'since', a.created_at::date)
    from public.asaas_accounts a where a.teacher_id = auth.uid()), jsonb_build_object('connected', false));
$$;
revoke execute on function public.hi_asaas_status() from public, anon;
grant execute on function public.hi_asaas_status() to authenticated;

-- 5) O app avisa que já marcou estes pagamentos como pagos (não marca de novo).
create or replace function public.hi_asaas_applied(p_ids text[]) returns integer
language sql security definer set search_path = public as $$
  with u as (update public.asaas_charges set applied = true, updated_at = now()
    where teacher_id = auth.uid() and id = any(p_ids) and not applied returning 1)
  select count(*)::int from u;
$$;
revoke execute on function public.hi_asaas_applied(text[]) from public, anon;
grant execute on function public.hi_asaas_applied(text[]) to authenticated;

-- 6) Planos do app pagos pelo Asaas (na conta do dono do app). Cada professor que escolhe um plano
--    ganha uma assinatura mensal no Asaas; quando a fatura é paga, o plano é ativado sozinho por 1 mês.
create table if not exists public.plan_subs (
  teacher_id uuid primary key references auth.users(id) on delete cascade,
  customer_id text,
  subscription_id text,
  plan text,
  value numeric,
  status text not null default 'none',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists plan_subs_sub on public.plan_subs (subscription_id) where subscription_id is not null;
alter table public.plan_subs enable row level security;
revoke all on public.plan_subs from anon, authenticated;

-- Configuração da cobrança dos planos (código do aviso de pagamento). Uma linha só.
create table if not exists public.app_billing (
  id int primary key default 1 check (id = 1),
  hook_token text,
  hook_id text,
  updated_at timestamptz not null default now()
);
alter table public.app_billing enable row level security;
revoke all on public.app_billing from anon, authenticated;

-- Cada pagamento do Asaas ativa o plano uma vez só (o Asaas pode avisar mais de uma vez).
alter table public.plan_events add column if not exists ref text;
create unique index if not exists plan_events_ref on public.plan_events (ref) where ref is not null;

-- Ativa o plano pago pelo Asaas. Igual ao "Ativar" do dono do app (1 mês, crédito de indicação,
-- prêmio de quem indicou), mas chamado só pelo servidor (função "asaas").
create or replace function public.hi_plan_activate(p_teacher uuid, p_plan text, p_months int, p_ref text) returns boolean
language plpgsql security definer set search_path = public as $$
declare me public.teacher_plans; m int := greatest(coalesce(p_months, 1), 1);
begin
  if p_plan not in ('bronze','silver','gold','school') then raise exception 'Plano inválido.' using errcode = 'P0001'; end if;
  if p_ref is not null and exists (select 1 from public.plan_events where ref = p_ref) then return false; end if;
  insert into public.teacher_plans (teacher_id) values (p_teacher) on conflict (teacher_id) do nothing;
  select * into me from public.teacher_plans where teacher_id = p_teacher for update;
  update public.teacher_plans set
    plan = p_plan,
    paid_until = greatest(coalesce(paid_until, current_date), current_date) + make_interval(months => m + coalesce(credit_months, 0)),
    credit_months = 0, requested = null, requested_at = null, updated_at = now()
  where teacher_id = p_teacher;
  insert into public.plan_events (teacher_id, plan, months, kind, ref) values (p_teacher, p_plan, m, 'paid', p_ref);
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
  return true;
end $$;
revoke execute on function public.hi_plan_activate(uuid, text, int, text) from public, anon, authenticated;
grant execute on function public.hi_plan_activate(uuid, text, int, text) to service_role;

-- 7) Esta versão.
insert into public.schema_versions (version) values ('8.50') on conflict (version) do nothing;
