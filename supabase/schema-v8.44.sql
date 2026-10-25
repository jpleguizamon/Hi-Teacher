-- =====================================================================
-- Hi Teacher 8.44 — os 3 dias de "esperando o pagamento" valem uma vez só
-- =====================================================================
-- Precisa da 8.38 instalada antes.
-- Como rodar: Supabase → SQL Editor → New query → colar este arquivo inteiro → Run.
-- É seguro rodar mais de uma vez. Não apaga nenhum dado.
-- Sem este arquivo o app continua igual (pedir o plano de novo dava mais 3 dias).
-- Explicação no HI-TEACHER.md, seção "Consertos do plano de prioridades (8.44)".

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
