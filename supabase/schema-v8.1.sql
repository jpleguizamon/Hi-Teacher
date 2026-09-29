-- =====================================================================
-- Hi Teacher 8.1 — app do aluno
-- =====================================================================
-- Precisa da 8.0 instalada antes (supabase/schema-v8.sql).
-- Como rodar: Supabase → SQL Editor → New query → colar este arquivo inteiro → Run.
-- É seguro rodar mais de uma vez. Não apaga nada.
-- Explicação no HI-TEACHER.md, seção "App do aluno (8.1)".

-- ---------------------------------------------------------------------
-- O que o aluno ligado a um professor pode ver sobre esse professor.
-- O app do professor atualiza sozinho.
-- ---------------------------------------------------------------------
create table if not exists public.teacher_public (
  id uuid primary key default gen_random_uuid(),
  teacher_id uuid not null unique references auth.users (id) on delete cascade,
  display_name text,              -- nome de exibição (ex.: Prof. JP)
  full_name text,                 -- nome completo (só pro recibo)
  document text,                  -- CPF/CNPJ (só pro recibo)
  photo text,
  city text,
  state text,                     -- UF: feriados estaduais certos nas aulas do aluno
  breaks jsonb not null default '[]'::jsonb,     -- férias/recesso gerais (sem os de um aluno só)
  settings jsonb not null default '{}'::jsonb,   -- duração padrão, início das cobranças, critérios, instrumentos...
  show_evaluations boolean not null default false, -- "Mostrar avaliações para os alunos"
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- O que é de UM aluno e o app do aluno precisa, mas o app do professor calcula a partir dos
-- outros alunos (sem expor os outros): se a aula é em grupo, mensalidade padrão e férias
-- só daquele aluno. Uma linha por aluno com acesso ao app.
create table if not exists public.student_view (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null unique references public.students (id) on delete cascade,
  teacher_id uuid not null references auth.users (id) on delete cascade,
  info jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Pedido cancelado pelo próprio aluno ("Cancelar pedido" / "cancelar aviso").
alter table public.join_requests drop constraint if exists join_requests_status_check;
alter table public.join_requests add constraint join_requests_status_check
  check (status in ('pending', 'approved', 'rejected', 'waitlist', 'cancelled'));
alter table public.student_requests drop constraint if exists student_requests_status_check;
alter table public.student_requests add constraint student_requests_status_check
  check (status in ('pending', 'accepted', 'rejected', 'cancelled'));

do $$
declare t text;
begin
  foreach t in array array['teacher_public','student_view'] loop
    execute format('drop trigger if exists hi_touch on public.%I', t);
    execute format('create trigger hi_touch before insert or update on public.%I for each row execute function public.hi_touch_updated_at()', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- Funções
-- ---------------------------------------------------------------------

-- Professores dos alunos ligados a mim (aluno/responsável).
create or replace function public.hi_my_teacher_ids() returns setof uuid
language sql stable security definer set search_path = public as $$
  select distinct s.teacher_id from public.students s
   where s.id in (select student_id from public.student_links where user_id = auth.uid()) and not s.deleted
$$;

-- A chave aceita pedidos novos? (chave ativa = pedidos não pausados)
create or replace function public.hi_teacher_accepts(tid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.teacher_codes where teacher_id = tid and active)
$$;

-- Procurar uma chave: só confirma que existe e mostra o nome de exibição do professor
-- (e a lista de instrumentos dele, pro formulário). Não expõe a tabela.
-- Pode ser usada antes de criar a conta (a tela pede a chave antes do cadastro).
create or replace function public.hi_find_teacher_code(p_code text)
returns table (teacher_id uuid, display_name text, instruments jsonb, accepting boolean)
language sql stable security definer set search_path = public as $$
  select c.teacher_id,
         coalesce(nullif(p.display_name, ''), 'Professor') as display_name,
         coalesce(p.settings -> 'instruments', '[]'::jsonb) as instruments,
         c.active as accepting
    from public.teacher_codes c
    left join public.teacher_public p on p.teacher_id = c.teacher_id
   where upper(c.code) = upper(trim(coalesce(p_code, '')))
   limit 1
$$;

-- Meus pedidos de entrada, com o nome do professor (quem pediu ainda não lê teacher_public).
create or replace function public.hi_my_join_requests()
returns table (id uuid, teacher_id uuid, role text, student_name text, status text, student_id uuid,
               created_at timestamptz, answered_at timestamptz, teacher_name text)
language sql stable security definer set search_path = public as $$
  select j.id, j.teacher_id, j.role, j.student_name, j.status, j.student_id, j.created_at, j.answered_at,
         coalesce(nullif(p.display_name, ''), 'Professor')
    from public.join_requests j
    left join public.teacher_public p on p.teacher_id = j.teacher_id
   where j.user_id = auth.uid()
   order by j.created_at desc
$$;

-- ---------------------------------------------------------------------
-- Regras de acesso (RLS)
-- ---------------------------------------------------------------------
alter table public.teacher_public enable row level security;
alter table public.student_view enable row level security;

-- teacher_public: o professor escreve a dele; aluno/responsável lê só a do professor com quem tem vínculo.
drop policy if exists "tpub_select" on public.teacher_public;
create policy "tpub_select" on public.teacher_public for select to authenticated
  using (teacher_id = auth.uid() or teacher_id in (select public.hi_my_teacher_ids()));
drop policy if exists "tpub_insert" on public.teacher_public;
create policy "tpub_insert" on public.teacher_public for insert to authenticated with check (teacher_id = auth.uid());
drop policy if exists "tpub_update" on public.teacher_public;
create policy "tpub_update" on public.teacher_public for update to authenticated
  using (teacher_id = auth.uid()) with check (teacher_id = auth.uid());

-- student_view: o professor escreve a dos alunos dele; aluno/responsável lê só a própria.
drop policy if exists "sview_select" on public.student_view;
create policy "sview_select" on public.student_view for select to authenticated
  using (teacher_id = auth.uid() or student_id in (select public.hi_my_student_ids()));
drop policy if exists "sview_insert" on public.student_view;
create policy "sview_insert" on public.student_view for insert to authenticated
  with check (teacher_id = auth.uid() and public.hi_owns_student(student_id));
drop policy if exists "sview_update" on public.student_view;
create policy "sview_update" on public.student_view for update to authenticated
  using (teacher_id = auth.uid()) with check (teacher_id = auth.uid() and public.hi_owns_student(student_id));

-- join_requests: só cria com o próprio user_id, pendente, e pra chave que está aceitando
-- pedidos; quem pediu pode cancelar enquanto está pendente.
drop policy if exists "join_insert" on public.join_requests;
create policy "join_insert" on public.join_requests for insert to authenticated
  with check (user_id = auth.uid() and status = 'pending' and student_id is null and answered_at is null
              and teacher_id <> auth.uid() and public.hi_teacher_accepts(teacher_id));
drop policy if exists "join_cancel_own" on public.join_requests;
create policy "join_cancel_own" on public.join_requests for update to authenticated
  using (user_id = auth.uid() and status = 'pending')
  with check (user_id = auth.uid() and status = 'cancelled' and student_id is null);

-- student_requests: aluno/responsável cria só pra aluno ligado a ele e vê só os seus;
-- pode cancelar o seu enquanto o professor não respondeu. O professor lê e responde.
drop policy if exists "sreq_select" on public.student_requests;
create policy "sreq_select" on public.student_requests for select to authenticated
  using ((author_user_id = auth.uid() and student_id in (select public.hi_my_student_ids())) or public.hi_owns_student(student_id));
drop policy if exists "sreq_cancel_own" on public.student_requests;
create policy "sreq_cancel_own" on public.student_requests for update to authenticated
  using (author_user_id = auth.uid() and status = 'pending')
  with check (author_user_id = auth.uid() and status = 'cancelled' and response is null);

-- ---------------------------------------------------------------------
-- Permissões
-- ---------------------------------------------------------------------
revoke all on public.teacher_public, public.student_view from anon;
grant select, insert, update on public.teacher_public, public.student_view to authenticated;

revoke execute on function public.hi_my_teacher_ids(), public.hi_teacher_accepts(uuid),
  public.hi_find_teacher_code(text), public.hi_my_join_requests() from public;
grant execute on function public.hi_my_teacher_ids(), public.hi_teacher_accepts(uuid),
  public.hi_my_join_requests() to authenticated;
-- A chave é conferida na tela antes de criar a conta: por isso também para anon.
grant execute on function public.hi_find_teacher_code(text) to anon, authenticated;

notify pgrst, 'reload schema';
