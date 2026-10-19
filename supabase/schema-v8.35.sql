-- =====================================================================
-- Hi Teacher 8.35 — ficha de matrícula por link
-- =====================================================================
-- Precisa da 8.0 e da 8.1 instaladas antes.
-- Como rodar: Supabase → SQL Editor → New query → colar este arquivo inteiro → Run.
-- É seguro rodar mais de uma vez. Não apaga nenhum dado que já existe.
-- Sem este arquivo o app continua igual; só a ficha de matrícula por link fica escondida.
-- Explicação no HI-TEACHER.md, seção "Gastos, ficha, pesquisa e resumo (8.35)".

-- Um link por professor (o token vai no endereço: ?ficha=TOKEN).
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
