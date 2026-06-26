-- Monolith database bootstrap for Supabase
-- Run this in Supabase SQL Editor after creating the project.

create extension if not exists "pgcrypto";

create type public.monolith_role as enum (
  'student',
  'influencer',
  'trainer_basic',
  'trainer_plus',
  'admin'
);

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  full_name text not null,
  role public.monolith_role not null default 'student',
  weight_unit text not null default 'kg' check (weight_unit in ('kg', 'lb')),
  language text not null default 'pt' check (language in ('pt', 'en', 'es')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.trainer_students (
  id uuid primary key default gen_random_uuid(),
  trainer_id uuid not null references public.profiles(id) on delete cascade,
  student_id uuid not null references public.profiles(id) on delete cascade,
  status text not null default 'active' check (status in ('pending', 'active', 'paused', 'ended')),
  created_at timestamptz not null default now(),
  unique (trainer_id, student_id)
);

create table public.daily_checkins (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.profiles(id) on delete cascade,
  checkin_date date not null,
  weight_kg numeric(7, 2),
  score integer not null default 0 check (score between 0 and 100),
  completed integer not null default 0,
  total integer not null default 0,
  items jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (student_id, checkin_date)
);

create table public.body_measurements (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.profiles(id) on delete cascade,
  measurement_date date not null,
  weight_kg numeric(7, 2),
  body_fat_percent numeric(5, 2),
  waist_cm numeric(6, 2),
  chest_cm numeric(6, 2),
  arm_cm numeric(6, 2),
  leg_cm numeric(6, 2),
  hip_cm numeric(6, 2),
  notes text,
  created_at timestamptz not null default now()
);

create table public.workout_templates (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid references public.profiles(id) on delete cascade,
  assigned_student_id uuid references public.profiles(id) on delete cascade,
  name text not null,
  goal text,
  tag text,
  exercises jsonb not null default '[]'::jsonb,
  is_library boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.completed_workouts (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.profiles(id) on delete cascade,
  workout_template_id uuid references public.workout_templates(id) on delete set null,
  workout_name text not null,
  completed_at timestamptz not null default now(),
  completed_exercises integer not null default 0,
  total_exercises integer not null default 0,
  completed_sets integer not null default 0,
  total_sets integer not null default 0,
  exercises jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now()
);

create table public.diet_plans (
  id uuid primary key default gen_random_uuid(),
  trainer_id uuid not null references public.profiles(id) on delete cascade,
  student_id uuid not null references public.profiles(id) on delete cascade,
  month_key text not null,
  calories text,
  protein text,
  carbs text,
  fat text,
  meals jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (student_id, month_key)
);

create table public.food_logs (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.profiles(id) on delete cascade,
  log_date date not null,
  note text,
  meals jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (student_id, log_date)
);

create table public.progress_photos (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.profiles(id) on delete cascade,
  photo_month text not null,
  angle text not null check (angle in ('front', 'side', 'back')),
  storage_path text not null,
  created_at timestamptz not null default now(),
  unique (student_id, photo_month, angle)
);

create or replace function public.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger profiles_touch_updated_at
before update on public.profiles
for each row execute function public.touch_updated_at();

create trigger daily_checkins_touch_updated_at
before update on public.daily_checkins
for each row execute function public.touch_updated_at();

create trigger workout_templates_touch_updated_at
before update on public.workout_templates
for each row execute function public.touch_updated_at();

create trigger diet_plans_touch_updated_at
before update on public.diet_plans
for each row execute function public.touch_updated_at();

create trigger food_logs_touch_updated_at
before update on public.food_logs
for each row execute function public.touch_updated_at();

create or replace function public.is_trainer_for(student uuid)
returns boolean
language sql
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.trainer_students ts
    where ts.student_id = student
      and ts.trainer_id = auth.uid()
      and ts.status = 'active'
  );
$$;

alter table public.profiles enable row level security;
alter table public.trainer_students enable row level security;
alter table public.daily_checkins enable row level security;
alter table public.body_measurements enable row level security;
alter table public.workout_templates enable row level security;
alter table public.completed_workouts enable row level security;
alter table public.diet_plans enable row level security;
alter table public.food_logs enable row level security;
alter table public.progress_photos enable row level security;

create policy "profiles_select_self_or_linked"
on public.profiles for select
using (
  id = auth.uid()
  or public.is_trainer_for(id)
  or exists (
    select 1 from public.trainer_students ts
    where ts.trainer_id = profiles.id
      and ts.student_id = auth.uid()
      and ts.status = 'active'
  )
);

create policy "profiles_insert_self"
on public.profiles for insert
with check (id = auth.uid());

create policy "profiles_update_self"
on public.profiles for update
using (id = auth.uid())
with check (id = auth.uid());

create policy "trainer_students_select_linked"
on public.trainer_students for select
using (trainer_id = auth.uid() or student_id = auth.uid());

create policy "trainer_students_insert_trainer"
on public.trainer_students for insert
with check (trainer_id = auth.uid());

create policy "trainer_students_insert_student_accept"
on public.trainer_students for insert
with check (
  student_id = auth.uid()
  and status in ('pending', 'active')
);

create policy "trainer_students_update_trainer"
on public.trainer_students for update
using (trainer_id = auth.uid())
with check (trainer_id = auth.uid());

create policy "daily_checkins_select_owner_or_trainer"
on public.daily_checkins for select
using (student_id = auth.uid() or public.is_trainer_for(student_id));

create policy "daily_checkins_write_owner"
on public.daily_checkins for all
using (student_id = auth.uid())
with check (student_id = auth.uid());

create policy "body_measurements_select_owner_or_trainer"
on public.body_measurements for select
using (student_id = auth.uid() or public.is_trainer_for(student_id));

create policy "body_measurements_write_owner"
on public.body_measurements for all
using (student_id = auth.uid())
with check (student_id = auth.uid());

create policy "workout_templates_select_owner_assigned_or_trainer"
on public.workout_templates for select
using (
  is_library
  or owner_id = auth.uid()
  or assigned_student_id = auth.uid()
  or public.is_trainer_for(assigned_student_id)
);

create policy "workout_templates_write_owner"
on public.workout_templates for all
using (owner_id = auth.uid())
with check (owner_id = auth.uid());

create policy "completed_workouts_select_owner_or_trainer"
on public.completed_workouts for select
using (student_id = auth.uid() or public.is_trainer_for(student_id));

create policy "completed_workouts_write_owner"
on public.completed_workouts for all
using (student_id = auth.uid())
with check (student_id = auth.uid());

create policy "diet_plans_select_student_or_trainer"
on public.diet_plans for select
using (student_id = auth.uid() or trainer_id = auth.uid());

create policy "diet_plans_write_trainer"
on public.diet_plans for all
using (trainer_id = auth.uid())
with check (trainer_id = auth.uid());

create policy "food_logs_select_owner_or_trainer"
on public.food_logs for select
using (student_id = auth.uid() or public.is_trainer_for(student_id));

create policy "food_logs_write_owner"
on public.food_logs for all
using (student_id = auth.uid())
with check (student_id = auth.uid());

create policy "progress_photos_select_owner_or_trainer"
on public.progress_photos for select
using (student_id = auth.uid() or public.is_trainer_for(student_id));

create policy "progress_photos_write_owner"
on public.progress_photos for all
using (student_id = auth.uid())
with check (student_id = auth.uid());

insert into storage.buckets (id, name, public)
values ('progress-photos', 'progress-photos', false)
on conflict (id) do nothing;

create policy "progress_photos_storage_select_owner_or_trainer"
on storage.objects for select
using (
  bucket_id = 'progress-photos'
  and (
    (storage.foldername(name))[1] = auth.uid()::text
    or public.is_trainer_for(((storage.foldername(name))[1])::uuid)
  )
);

create policy "progress_photos_storage_write_owner"
on storage.objects for all
using (
  bucket_id = 'progress-photos'
  and (storage.foldername(name))[1] = auth.uid()::text
)
with check (
  bucket_id = 'progress-photos'
  and (storage.foldername(name))[1] = auth.uid()::text
);
