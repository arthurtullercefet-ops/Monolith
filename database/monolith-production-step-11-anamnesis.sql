-- Monolith production step 11
-- Adds the student health questionnaire with student-owned writes and linked-trainer read access.

create table if not exists public.student_anamneses (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null unique references public.profiles(id) on delete cascade,
  answers jsonb not null default '{}'::jsonb,
  risk_flags jsonb not null default '[]'::jsonb,
  medical_clearance_recommended boolean not null default false,
  consent boolean not null default false,
  status text not null default 'submitted' check (status in ('draft', 'submitted', 'reviewed')),
  submitted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

drop trigger if exists student_anamneses_touch_updated_at on public.student_anamneses;
create trigger student_anamneses_touch_updated_at
before update on public.student_anamneses
for each row execute function public.touch_updated_at();

alter table public.student_anamneses enable row level security;

drop policy if exists "student_anamneses_select_owner_or_trainer" on public.student_anamneses;
create policy "student_anamneses_select_owner_or_trainer"
on public.student_anamneses for select
using (student_id = auth.uid() or public.is_trainer_for(student_id));

drop policy if exists "student_anamneses_insert_owner" on public.student_anamneses;
create policy "student_anamneses_insert_owner"
on public.student_anamneses for insert
with check (student_id = auth.uid());

drop policy if exists "student_anamneses_update_owner" on public.student_anamneses;
create policy "student_anamneses_update_owner"
on public.student_anamneses for update
using (student_id = auth.uid())
with check (student_id = auth.uid());

create index if not exists student_anamneses_student_updated_idx
on public.student_anamneses (student_id, updated_at desc);
