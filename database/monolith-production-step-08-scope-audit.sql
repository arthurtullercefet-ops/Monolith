-- Monolith production step 08
-- Permission scope audit for student/trainer data.
-- Safe to run after steps 01-07. It does not delete user data.

alter table public.daily_checkins enable row level security;
alter table public.checkin_factors enable row level security;
alter table public.body_measurements enable row level security;
alter table public.workout_templates enable row level security;
alter table public.completed_workouts enable row level security;
alter table public.diet_plans enable row level security;
alter table public.food_logs enable row level security;
alter table public.progress_photos enable row level security;

drop policy if exists "daily_checkins_select_owner_or_trainer" on public.daily_checkins;
create policy "daily_checkins_select_owner_or_trainer"
on public.daily_checkins for select
using (student_id = auth.uid() or public.is_trainer_for(student_id));

drop policy if exists "daily_checkins_write_owner" on public.daily_checkins;
drop policy if exists "daily_checkins_write_owner_or_trainer" on public.daily_checkins;
create policy "daily_checkins_write_owner_or_trainer"
on public.daily_checkins for all
using (student_id = auth.uid() or public.is_trainer_for(student_id))
with check (student_id = auth.uid() or public.is_trainer_for(student_id));

drop policy if exists "checkin_factors_select_owner_or_trainer" on public.checkin_factors;
create policy "checkin_factors_select_owner_or_trainer"
on public.checkin_factors for select
using (student_id = auth.uid() or public.is_trainer_for(student_id));

drop policy if exists "checkin_factors_write_owner" on public.checkin_factors;
drop policy if exists "checkin_factors_write_owner_or_trainer" on public.checkin_factors;
create policy "checkin_factors_write_owner_or_trainer"
on public.checkin_factors for all
using (student_id = auth.uid() or public.is_trainer_for(student_id))
with check (student_id = auth.uid() or public.is_trainer_for(student_id));

drop policy if exists "body_measurements_select_owner_or_trainer" on public.body_measurements;
create policy "body_measurements_select_owner_or_trainer"
on public.body_measurements for select
using (student_id = auth.uid() or public.is_trainer_for(student_id));

drop policy if exists "body_measurements_write_owner" on public.body_measurements;
create policy "body_measurements_write_owner"
on public.body_measurements for all
using (student_id = auth.uid())
with check (student_id = auth.uid());

drop policy if exists "completed_workouts_select_owner_or_trainer" on public.completed_workouts;
create policy "completed_workouts_select_owner_or_trainer"
on public.completed_workouts for select
using (student_id = auth.uid() or public.is_trainer_for(student_id));

drop policy if exists "completed_workouts_write_owner" on public.completed_workouts;
create policy "completed_workouts_write_owner"
on public.completed_workouts for all
using (student_id = auth.uid())
with check (student_id = auth.uid());

drop policy if exists "progress_photos_select_owner_or_trainer" on public.progress_photos;
create policy "progress_photos_select_owner_or_trainer"
on public.progress_photos for select
using (student_id = auth.uid() or public.is_trainer_for(student_id));

drop policy if exists "progress_photos_write_owner" on public.progress_photos;
create policy "progress_photos_write_owner"
on public.progress_photos for all
using (student_id = auth.uid())
with check (student_id = auth.uid());

drop policy if exists "diet_plans_select_student_or_trainer" on public.diet_plans;
drop policy if exists "diet_plans_select_student_or_linked_trainer" on public.diet_plans;
create policy "diet_plans_select_student_or_linked_trainer"
on public.diet_plans for select
using (
  student_id = auth.uid()
  or (trainer_id = auth.uid() and public.is_trainer_for(student_id))
);

drop policy if exists "diet_plans_write_trainer" on public.diet_plans;
drop policy if exists "diet_plans_write_linked_trainer" on public.diet_plans;
create policy "diet_plans_write_linked_trainer"
on public.diet_plans for all
using (trainer_id = auth.uid() and public.is_trainer_for(student_id))
with check (trainer_id = auth.uid() and public.is_trainer_for(student_id));

drop policy if exists "food_logs_select_owner_or_trainer" on public.food_logs;
drop policy if exists "food_logs_select_owner" on public.food_logs;
create policy "food_logs_select_owner"
on public.food_logs for select
using (student_id = auth.uid());

drop policy if exists "food_logs_write_owner" on public.food_logs;
create policy "food_logs_write_owner"
on public.food_logs for all
using (student_id = auth.uid())
with check (student_id = auth.uid());

drop policy if exists "workout_templates_select_owner_assigned_or_trainer" on public.workout_templates;
drop policy if exists "workout_templates_select_scoped" on public.workout_templates;
create policy "workout_templates_select_scoped"
on public.workout_templates for select
using (
  owner_id = auth.uid()
  or assigned_student_id = auth.uid()
  or (assigned_student_id is not null and public.is_trainer_for(assigned_student_id))
);

drop policy if exists "workout_templates_write_owner" on public.workout_templates;
drop policy if exists "workout_templates_write_owner_or_linked" on public.workout_templates;
create policy "workout_templates_write_owner_or_linked"
on public.workout_templates for all
using (
  owner_id = auth.uid()
  and (assigned_student_id is null or public.is_trainer_for(assigned_student_id))
)
with check (
  owner_id = auth.uid()
  and (assigned_student_id is null or public.is_trainer_for(assigned_student_id))
);

create index if not exists daily_checkins_student_date_idx
on public.daily_checkins (student_id, checkin_date desc);

create index if not exists body_measurements_student_date_idx
on public.body_measurements (student_id, measurement_date desc);

create index if not exists completed_workouts_student_date_idx
on public.completed_workouts (student_id, completed_at desc);

create index if not exists workout_templates_owner_assigned_idx
on public.workout_templates (owner_id, assigned_student_id);

create index if not exists diet_plans_student_month_idx
on public.diet_plans (student_id, month_key);

create index if not exists progress_photos_student_month_angle_idx
on public.progress_photos (student_id, photo_month, angle);

create index if not exists checkin_factors_student_sort_idx
on public.checkin_factors (student_id, archived, sort_order);

select
  'Monolith scope audit policies ready' as status,
  now() as checked_at;
