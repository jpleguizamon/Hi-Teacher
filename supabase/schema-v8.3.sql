-- =====================================================================
-- Hi Teacher 8.3 — estudo em casa, músicas, metas e pedidos novos do aluno
-- =====================================================================
-- Precisa da 8.0, 8.1 e 8.1.1 instaladas antes (schema-v8.sql, schema-v8.1.sql, schema-v8.1.1.sql).
-- Como rodar: Supabase → SQL Editor → New query → colar este arquivo inteiro → Run.
-- É seguro rodar mais de uma vez. Não apaga nada.
-- Sem este arquivo o app continua funcionando: o que o aluno anota fica só no aparelho dele
-- e os pedidos novos (música, remarcação, reposição) ficam escondidos.
-- Explicação no HI-TEACHER.md, seção "8.3".

-- ---------------------------------------------------------------------
-- 1. Caderno do aluno: prática, diário, lição feita, músicas, setlists, metas, presença em eventos.
--    Uma linha por aluno e por conta (aluno e responsável têm cada um a sua).
--    O aluno/responsável escreve a sua; o professor só lê a dos alunos dele.
-- ---------------------------------------------------------------------
create table if not exists public.student_journal (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.students (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  teacher_id uuid references auth.users (id) on delete cascade,  -- preenchido pelo servidor
  data jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (student_id, user_id),
  constraint student_journal_size check (octet_length(data::text) <= 600000)
);
create index if not exists student_journal_teacher on public.student_journal (teacher_id, updated_at);

-- O professor da linha vem do cadastro do aluno (quem escreve não escolhe).
create or replace function public.hi_journal_teacher() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.teacher_id := (select teacher_id from public.students where id = new.student_id);
  new.updated_at := now();
  if tg_op = 'INSERT' then new.created_at := now(); end if;
  return new;
end $$;
drop trigger if exists hi_journal_teacher on public.student_journal;
create trigger hi_journal_teacher before insert or update on public.student_journal
  for each row execute function public.hi_journal_teacher();

alter table public.student_journal enable row level security;
drop policy if exists "sjournal_select" on public.student_journal;
create policy "sjournal_select" on public.student_journal for select to authenticated
  using ((user_id = auth.uid() and student_id in (select public.hi_my_student_ids())) or public.hi_owns_student(student_id));
drop policy if exists "sjournal_insert" on public.student_journal;
create policy "sjournal_insert" on public.student_journal for insert to authenticated
  with check (user_id = auth.uid() and student_id in (select public.hi_my_student_ids()));
drop policy if exists "sjournal_update" on public.student_journal;
create policy "sjournal_update" on public.student_journal for update to authenticated
  using (user_id = auth.uid() and student_id in (select public.hi_my_student_ids()))
  with check (user_id = auth.uid() and student_id in (select public.hi_my_student_ids()));
revoke all on public.student_journal from anon;
grant select, insert, update on public.student_journal to authenticated;

-- ---------------------------------------------------------------------
-- 2. Pedidos novos do aluno para o professor
--    song_request: "quero aprender esta música"; reschedule: remarcar uma aula num horário
--    vago do professor; makeup_request: marcar uma reposição pendente num horário vago.
-- ---------------------------------------------------------------------
alter table public.student_requests drop constraint if exists student_requests_type_check;
alter table public.student_requests add constraint student_requests_type_check
  check (type in ('absence', 'payment_notice', 'change_data', 'song_request', 'reschedule', 'makeup_request'));

-- No máximo 20 pedidos esperando resposta por conta (evita encher a caixa do professor).
create or replace function public.hi_student_requests_limit() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'pending' and (select count(*) from public.student_requests
       where author_user_id = new.author_user_id and status = 'pending' and id <> new.id) >= 20 then
    raise exception 'Muitos pedidos esperando o professor. Espere ele responder.' using errcode = 'P0001';
  end if;
  return new;
end $$;
drop trigger if exists hi_sreq_limit on public.student_requests;
create trigger hi_sreq_limit before insert on public.student_requests
  for each row execute function public.hi_student_requests_limit();

notify pgrst, 'reload schema';
