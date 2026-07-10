-- Monolith production step 07
-- Final bridge for production data.
-- Purpose: make sure all app areas that used to rely on localStorage are backed by Supabase.
-- Safe to run after steps 01-06. It does not delete user data.

create extension if not exists "pgcrypto";

-- Keep progress photos in a private Supabase Storage bucket.
insert into storage.buckets (id, name, public)
values ('progress-photos', 'progress-photos', false)
on conflict (id) do update set public = false;

-- Required app data tables. These should already exist from the base schema.
-- This block gives you an immediate SQL error if one of the production tables is missing.
do $$
declare
  missing_tables text[];
begin
  select array_agg(required_table)
  into missing_tables
  from (
    values
      ('profiles'),
      ('trainer_students'),
      ('trainer_invites'),
      ('trainer_public_profiles'),
      ('daily_checkins'),
      ('checkin_factors'),
      ('body_measurements'),
      ('workout_templates'),
      ('completed_workouts'),
      ('diet_plans'),
      ('food_logs'),
      ('progress_photos'),
      ('app_plans'),
      ('subscriptions'),
      ('influencer_codes'),
      ('referral_attributions')
  ) as required(required_table)
  where to_regclass('public.' || required_table) is null;

  if missing_tables is not null then
    raise exception 'Missing Monolith production tables: %', array_to_string(missing_tables, ', ');
  end if;
end $$;

-- Keep RLS on for every user-data table.
alter table public.profiles enable row level security;
alter table public.trainer_students enable row level security;
alter table public.trainer_invites enable row level security;
alter table public.trainer_public_profiles enable row level security;
alter table public.daily_checkins enable row level security;
alter table public.checkin_factors enable row level security;
alter table public.body_measurements enable row level security;
alter table public.workout_templates enable row level security;
alter table public.completed_workouts enable row level security;
alter table public.diet_plans enable row level security;
alter table public.food_logs enable row level security;
alter table public.progress_photos enable row level security;
alter table public.app_plans enable row level security;
alter table public.subscriptions enable row level security;
alter table public.influencer_codes enable row level security;
alter table public.referral_attributions enable row level security;

-- Re-apply current production scope policies that matter for trainer/student behavior.
drop policy if exists "food_logs_select_owner_or_trainer" on public.food_logs;
drop policy if exists "food_logs_select_owner" on public.food_logs;
create policy "food_logs_select_owner"
on public.food_logs for select
using (student_id = auth.uid());

drop policy if exists "workout_templates_write_owner" on public.workout_templates;
drop policy if exists "workout_templates_write_owner_or_linked" on public.workout_templates;
create policy "workout_templates_write_owner_or_linked"
on public.workout_templates for all
using (
  owner_id = auth.uid()
  or (
    assigned_student_id is not null
    and public.is_trainer_for(assigned_student_id)
  )
)
with check (
  owner_id = auth.uid()
  or (
    assigned_student_id is not null
    and public.is_trainer_for(assigned_student_id)
  )
);

drop policy if exists "diet_plans_write_trainer" on public.diet_plans;
drop policy if exists "diet_plans_write_linked_trainer" on public.diet_plans;
create policy "diet_plans_write_linked_trainer"
on public.diet_plans for all
using (trainer_id = auth.uid() and public.is_trainer_for(student_id))
with check (trainer_id = auth.uid() and public.is_trainer_for(student_id));

-- Helpful indexes for monthly reports and trainer/student dashboards.
create index if not exists daily_checkins_student_date_idx
on public.daily_checkins (student_id, checkin_date desc);

create index if not exists body_measurements_student_date_idx
on public.body_measurements (student_id, measured_at desc);

create index if not exists completed_workouts_student_date_idx
on public.completed_workouts (student_id, completed_at desc);

create index if not exists workout_templates_owner_assigned_idx
on public.workout_templates (owner_id, assigned_student_id);

create index if not exists diet_plans_student_month_idx
on public.diet_plans (student_id, month);

create index if not exists progress_photos_student_period_idx
on public.progress_photos (student_id, period, slot);

create index if not exists checkin_factors_student_sort_idx
on public.checkin_factors (student_id, archived, sort_order);

-- Expected result: this returns one row saying the bridge is ready.
select
  'Monolith Supabase production bridge ready' as status,
  now() as checked_at;
