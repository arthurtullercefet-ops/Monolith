-- Monolith production step 03
-- Syncs custom daily check-in checklist/factors per student.
-- Run this after monolith-production-step-02-trainer-map.sql.

create table if not exists public.checkin_factors (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.profiles(id) on delete cascade,
  factor_key text not null,
  group_name text not null,
  name text not null,
  active boolean not null default false,
  positive boolean not null default true,
  sort_order integer not null default 0,
  archived boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (student_id, factor_key)
);

create index if not exists checkin_factors_student_id_idx
on public.checkin_factors (student_id, archived, sort_order);

drop trigger if exists checkin_factors_touch_updated_at on public.checkin_factors;

create trigger checkin_factors_touch_updated_at
before update on public.checkin_factors
for each row execute function public.touch_updated_at();

alter table public.checkin_factors enable row level security;

drop policy if exists "checkin_factors_select_owner_or_trainer" on public.checkin_factors;

create policy "checkin_factors_select_owner_or_trainer"
on public.checkin_factors for select
using (student_id = auth.uid() or public.is_trainer_for(student_id));

drop policy if exists "checkin_factors_write_owner" on public.checkin_factors;

create policy "checkin_factors_write_owner"
on public.checkin_factors for all
using (student_id = auth.uid())
with check (student_id = auth.uid());
