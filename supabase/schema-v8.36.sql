-- =====================================================================
-- Hi Teacher 8.36 — travas de segurança antes do lançamento
-- =====================================================================
-- Precisa da 8.0, 8.1.1, 8.14 e 8.23 instaladas antes.
-- Como rodar: Supabase → SQL Editor → New query → colar este arquivo inteiro → Run.
-- É seguro rodar mais de uma vez. Não apaga nenhum dado e não muda nenhum acesso que já existe.
-- Explicação no HI-TEACHER.md, seção "Revisão para o lançamento (8.36)".

-- 1) Liberar o app para uma conta só se essa conta pediu (join_requests) a este professor.
--    Antes bastava ser dono do aluno: dava para ligar qualquer conta, sem ela querer.
-- 8.45: não deixa rodar este arquivo por cima de uma versão mais nova (ele desfaria mudanças).
do $$ declare newer boolean; begin
  if to_regclass('public.schema_versions') is not null then
    execute 'select exists (select 1 from public.schema_versions where string_to_array(version, ''.'')::int[] > string_to_array($1, ''.'')::int[])' into newer using '8.36';
    if newer then
      raise exception 'Este arquivo (8.36) é mais antigo que o que já está no servidor. Não rode: ele desfaria mudanças mais novas.';
    end if;
  end if;
end $$;

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
