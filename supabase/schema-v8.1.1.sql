-- =====================================================================
-- Hi Teacher 8.1.1 — correções do app do aluno
-- =====================================================================
-- Precisa da 8.0 e da 8.1 instaladas antes (schema-v8.sql e schema-v8.1.sql).
-- Como rodar: Supabase → SQL Editor → New query → colar este arquivo inteiro → Run.
-- É seguro rodar mais de uma vez. Explicação no HI-TEACHER.md, seção "Correções da 8.1.1".

-- ---------------------------------------------------------------------
-- 1. Notas de avaliação só para o professor
-- ---------------------------------------------------------------------
-- As notas por critério (pontualidade, prática...) saem de lessons.scores (que o aluno lê)
-- e vão pra lesson_private (só o professor). id = id da aula.
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
