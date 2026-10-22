-- =====================================================================
-- Hi Teacher 8.41 — "Indique um professor" e números da tela Assinaturas
-- =====================================================================
-- Precisa da 8.38 instalada antes.
-- Como rodar: Supabase → SQL Editor → New query → colar este arquivo inteiro → Run.
-- É seguro rodar mais de uma vez. Não apaga nenhum dado.
-- Sem este arquivo o app continua igual; só o "Indique um professor" fica escondido.
-- Explicação no HI-TEACHER.md, seção "Indicação, aviso do teste e números (8.41)".
--
-- Regra da indicação: cada professor tem um código. Quem cria a conta pelo link de um colega
-- fica marcado como indicado por ele. Quando o indicado passa a pagar um plano (o dono do app
-- ativa), quem indicou ganha 1 mês: se já paga, o plano dele vai 1 mês mais longe; se ainda
-- não paga, o mês fica guardado e entra na próxima ativação dele.

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
