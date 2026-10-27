-- =====================================================================
-- Hi Teacher 8.50 — cobrança automática pelo Asaas
-- =====================================================================
-- Rodar depois da 8.45. Como rodar: Supabase → SQL Editor → New query → colar este arquivo inteiro → Run.
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

-- 6) Esta versão.
insert into public.schema_versions (version) values ('8.50') on conflict (version) do nothing;
