-- Monolith production step 14
-- Adds numeric validation, authorship, scoped write policies and an audit trail.
-- Existing QA records are preserved and marked as suspicious instead of being deleted.
-- Safe to run more than once after production step 13.

create or replace function public.monolith_text_number_in_range(
  p_value text,
  p_min numeric,
  p_max numeric
)
returns boolean
language plpgsql
immutable
as $$
declare
  normalized text := replace(trim(coalesce(p_value, '')), ',', '.');
  parsed numeric;
begin
  if normalized = '' then
    return true;
  end if;
  if normalized !~ '^\d+(\.\d+)?$' then
    return false;
  end if;
  parsed := normalized::numeric;
  return parsed between p_min and p_max;
exception when others then
  return false;
end;
$$;

create or replace function public.monolith_workout_json_is_plausible(p_exercises jsonb)
returns boolean
language plpgsql
immutable
as $$
declare
  exercise_item jsonb;
  set_item jsonb;
begin
  if p_exercises is null then
    return true;
  end if;
  if jsonb_typeof(p_exercises) <> 'array' then
    return false;
  end if;
  for exercise_item in select value from jsonb_array_elements(p_exercises)
  loop
    if exercise_item ? 'sets' and jsonb_typeof(exercise_item -> 'sets') <> 'array' then
      return false;
    end if;
    for set_item in select value from jsonb_array_elements(coalesce(exercise_item -> 'sets', '[]'::jsonb))
    loop
      if not public.monolith_text_number_in_range(set_item ->> 'weight', 0, 600)
         or not public.monolith_text_number_in_range(set_item ->> 'reps', 1, 100)
         or not public.monolith_text_number_in_range(set_item ->> 'rest', 0, 900) then
        return false;
      end if;
    end loop;
  end loop;
  return true;
exception when others then
  return false;
end;
$$;

create or replace function public.monolith_diet_meals_are_plausible(p_meals jsonb)
returns boolean
language plpgsql
immutable
as $$
declare
  meal jsonb;
begin
  if p_meals is null then
    return true;
  end if;
  if jsonb_typeof(p_meals) <> 'array' then
    return false;
  end if;
  for meal in select value from jsonb_array_elements(p_meals)
  loop
    if not public.monolith_text_number_in_range(meal ->> 'calories', 1, 10000)
       or not public.monolith_text_number_in_range(meal ->> 'protein', 0, 1000)
       or not public.monolith_text_number_in_range(meal ->> 'carbs', 0, 1000)
       or not public.monolith_text_number_in_range(meal ->> 'fat', 0, 1000) then
      return false;
    end if;
  end loop;
  return true;
exception when others then
  return false;
end;
$$;

alter table public.daily_checkins
  add column if not exists created_by uuid references public.profiles(id) on delete set null,
  add column if not exists updated_by uuid references public.profiles(id) on delete set null,
  add column if not exists answered_by uuid references public.profiles(id) on delete set null,
  add column if not exists last_corrected_by uuid references public.profiles(id) on delete set null,
  add column if not exists is_suspicious boolean not null default false,
  add column if not exists suspicious_reason text;

alter table public.body_measurements
  add column if not exists created_by uuid references public.profiles(id) on delete set null,
  add column if not exists updated_by uuid references public.profiles(id) on delete set null,
  add column if not exists is_suspicious boolean not null default false,
  add column if not exists suspicious_reason text;

alter table public.workout_templates
  add column if not exists created_by uuid references public.profiles(id) on delete set null,
  add column if not exists updated_by uuid references public.profiles(id) on delete set null,
  add column if not exists is_suspicious boolean not null default false,
  add column if not exists suspicious_reason text;

alter table public.completed_workouts
  add column if not exists created_by uuid references public.profiles(id) on delete set null,
  add column if not exists updated_by uuid references public.profiles(id) on delete set null,
  add column if not exists is_suspicious boolean not null default false,
  add column if not exists suspicious_reason text;

alter table public.diet_plans
  add column if not exists created_by uuid references public.profiles(id) on delete set null,
  add column if not exists updated_by uuid references public.profiles(id) on delete set null,
  add column if not exists is_suspicious boolean not null default false,
  add column if not exists suspicious_reason text;

alter table public.food_logs
  add column if not exists created_by uuid references public.profiles(id) on delete set null,
  add column if not exists updated_by uuid references public.profiles(id) on delete set null;

alter table public.progress_photos
  add column if not exists created_by uuid references public.profiles(id) on delete set null,
  add column if not exists updated_by uuid references public.profiles(id) on delete set null;

alter table public.checkin_factors
  add column if not exists created_by uuid references public.profiles(id) on delete set null,
  add column if not exists updated_by uuid references public.profiles(id) on delete set null;

-- Preserve legacy authorship conservatively. These values describe ownership, not a verified actor.
update public.daily_checkins set created_by = student_id where created_by is null;
update public.daily_checkins set updated_by = created_by where updated_by is null;
update public.daily_checkins set answered_by = student_id where answered_by is null;
update public.body_measurements set created_by = student_id where created_by is null;
update public.body_measurements set updated_by = created_by where updated_by is null;
update public.workout_templates set created_by = owner_id where created_by is null and owner_id is not null;
update public.workout_templates set updated_by = created_by where updated_by is null;
update public.completed_workouts set created_by = student_id where created_by is null;
update public.completed_workouts set updated_by = created_by where updated_by is null;
update public.diet_plans set created_by = trainer_id where created_by is null;
update public.diet_plans set updated_by = created_by where updated_by is null;
update public.food_logs set created_by = student_id where created_by is null;
update public.food_logs set updated_by = created_by where updated_by is null;
update public.progress_photos set created_by = student_id where created_by is null;
update public.progress_photos set updated_by = created_by where updated_by is null;

-- Existing outliers remain available for QA, but are visibly classified.
-- Each backfill runs only before its constraint exists, keeping the migration idempotent.
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'daily_checkins_weight_range_check') then
    update public.daily_checkins
    set is_suspicious = true,
        suspicious_reason = coalesce(suspicious_reason, 'Legacy value outside the expected body-weight range')
    where weight_kg is not null and weight_kg not between 20 and 500;
  end if;

  if not exists (select 1 from pg_constraint where conname = 'body_measurements_ranges_check') then
    update public.body_measurements
    set is_suspicious = true,
        suspicious_reason = coalesce(suspicious_reason, 'Legacy body measurement outside the expected range')
    where (weight_kg is not null and weight_kg not between 20 and 500)
       or (body_fat_percent is not null and body_fat_percent not between 1 and 70)
       or (waist_cm is not null and waist_cm not between 20 and 300)
       or (chest_cm is not null and chest_cm not between 20 and 300)
       or (arm_cm is not null and arm_cm not between 20 and 300)
       or (leg_cm is not null and leg_cm not between 20 and 300)
       or (hip_cm is not null and hip_cm not between 20 and 300);
  end if;

  if not exists (select 1 from pg_constraint where conname = 'workout_templates_values_check') then
    update public.workout_templates
    set is_suspicious = true,
        suspicious_reason = coalesce(suspicious_reason, 'Legacy workout value outside the expected range')
    where not public.monolith_workout_json_is_plausible(exercises);
  end if;

  if not exists (select 1 from pg_constraint where conname = 'completed_workouts_values_check') then
    update public.completed_workouts
    set is_suspicious = true,
        suspicious_reason = coalesce(suspicious_reason, 'Legacy completed-workout value outside the expected range')
    where not public.monolith_workout_json_is_plausible(exercises);
  end if;

  if not exists (select 1 from pg_constraint where conname = 'diet_plans_values_check') then
    update public.diet_plans
    set is_suspicious = true,
        suspicious_reason = coalesce(suspicious_reason, 'Legacy nutrition value outside the expected range')
    where not public.monolith_text_number_in_range(calories, 1, 10000)
       or not public.monolith_text_number_in_range(protein, 0, 1000)
       or not public.monolith_text_number_in_range(carbs, 0, 1000)
       or not public.monolith_text_number_in_range(fat, 0, 1000)
       or not public.monolith_diet_meals_are_plausible(meals);
  end if;
end;
$$;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'daily_checkins_weight_range_check') then
    alter table public.daily_checkins add constraint daily_checkins_weight_range_check
      check (weight_kg is null or weight_kg between 20 and 500) not valid;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'daily_checkins_counts_check') then
    alter table public.daily_checkins add constraint daily_checkins_counts_check
      check (completed >= 0 and total >= 0 and completed <= total) not valid;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'body_measurements_ranges_check') then
    alter table public.body_measurements add constraint body_measurements_ranges_check check (
      (weight_kg is null or weight_kg between 20 and 500)
      and (body_fat_percent is null or body_fat_percent between 1 and 70)
      and (waist_cm is null or waist_cm between 20 and 300)
      and (chest_cm is null or chest_cm between 20 and 300)
      and (arm_cm is null or arm_cm between 20 and 300)
      and (leg_cm is null or leg_cm between 20 and 300)
      and (hip_cm is null or hip_cm between 20 and 300)
    ) not valid;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'workout_templates_values_check') then
    alter table public.workout_templates add constraint workout_templates_values_check
      check (public.monolith_workout_json_is_plausible(exercises)) not valid;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'completed_workouts_values_check') then
    alter table public.completed_workouts add constraint completed_workouts_values_check
      check (public.monolith_workout_json_is_plausible(exercises)) not valid;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'completed_workouts_counts_check') then
    alter table public.completed_workouts add constraint completed_workouts_counts_check check (
      completed_exercises >= 0 and total_exercises >= 0 and completed_exercises <= total_exercises
      and completed_sets >= 0 and total_sets >= 0 and completed_sets <= total_sets
    ) not valid;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'diet_plans_values_check') then
    alter table public.diet_plans add constraint diet_plans_values_check check (
      public.monolith_text_number_in_range(calories, 1, 10000)
      and public.monolith_text_number_in_range(protein, 0, 1000)
      and public.monolith_text_number_in_range(carbs, 0, 1000)
      and public.monolith_text_number_in_range(fat, 0, 1000)
      and public.monolith_diet_meals_are_plausible(meals)
    ) not valid;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'diet_plans_month_key_check') then
    alter table public.diet_plans add constraint diet_plans_month_key_check
      check (month_key ~ '^\d{4}-(0[1-9]|1[0-2])$') not valid;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'student_anamneses_sleep_hours_check') then
    alter table public.student_anamneses add constraint student_anamneses_sleep_hours_check check (
      public.monolith_text_number_in_range(answers ->> 'sleepHours', 0, 24)
    ) not valid;
  end if;
end;
$$;

create or replace function public.monolith_validate_record_dates()
returns trigger
language plpgsql
as $$
begin
  if tg_table_name = 'daily_checkins' and new.checkin_date > current_date then
    raise exception 'Check-in date cannot be in the future.';
  elsif tg_table_name = 'body_measurements' and new.measurement_date > current_date then
    raise exception 'Measurement date cannot be in the future.';
  elsif tg_table_name = 'completed_workouts' and new.completed_at > now() + interval '5 minutes' then
    raise exception 'Workout completion date cannot be in the future.';
  end if;
  return new;
end;
$$;

drop trigger if exists daily_checkins_validate_date on public.daily_checkins;
create trigger daily_checkins_validate_date before insert or update on public.daily_checkins
for each row execute function public.monolith_validate_record_dates();

drop trigger if exists body_measurements_validate_date on public.body_measurements;
create trigger body_measurements_validate_date before insert or update on public.body_measurements
for each row execute function public.monolith_validate_record_dates();

drop trigger if exists completed_workouts_validate_date on public.completed_workouts;
create trigger completed_workouts_validate_date before insert or update on public.completed_workouts
for each row execute function public.monolith_validate_record_dates();

create or replace function public.monolith_set_authorship()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'INSERT' then
    new.created_by = coalesce(auth.uid(), new.created_by);
  else
    new.created_by = old.created_by;
  end if;
  new.updated_by = coalesce(auth.uid(), old.updated_by, new.created_by);
  return new;
end;
$$;

create or replace function public.monolith_set_checkin_authorship()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'INSERT' then
    new.created_by = coalesce(auth.uid(), new.created_by);
    new.answered_by = coalesce(auth.uid(), new.answered_by);
  else
    new.created_by = old.created_by;
    new.answered_by = old.answered_by;
  end if;
  new.updated_by = coalesce(auth.uid(), old.updated_by, new.created_by);
  return new;
end;
$$;

drop trigger if exists daily_checkins_set_authorship on public.daily_checkins;
create trigger daily_checkins_set_authorship before insert or update on public.daily_checkins
for each row execute function public.monolith_set_checkin_authorship();

do $$
declare
  target_table text;
begin
  foreach target_table in array array[
    'body_measurements', 'workout_templates', 'completed_workouts', 'diet_plans',
    'food_logs', 'progress_photos', 'checkin_factors'
  ]
  loop
    execute format('drop trigger if exists %I on public.%I', target_table || '_set_authorship', target_table);
    execute format(
      'create trigger %I before insert or update on public.%I for each row execute function public.monolith_set_authorship()',
      target_table || '_set_authorship', target_table
    );
  end loop;
end;
$$;

create table if not exists public.data_change_audit (
  id uuid primary key default gen_random_uuid(),
  table_name text not null,
  record_id uuid,
  student_id uuid references public.profiles(id) on delete set null,
  actor_id uuid references public.profiles(id) on delete set null,
  action text not null check (action in ('insert', 'update', 'delete', 'correction')),
  changed_fields jsonb not null default '[]'::jsonb,
  reason text,
  client_request_id text,
  created_at timestamptz not null default now()
);

create index if not exists data_change_audit_student_date_idx
on public.data_change_audit (student_id, created_at desc);

create index if not exists data_change_audit_actor_date_idx
on public.data_change_audit (actor_id, created_at desc);

create or replace function public.monolith_capture_audit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  old_row jsonb := case when tg_op = 'INSERT' then '{}'::jsonb else to_jsonb(old) end;
  new_row jsonb := case when tg_op = 'DELETE' then '{}'::jsonb else to_jsonb(new) end;
  source_row jsonb := case when tg_op = 'DELETE' then old_row else new_row end;
  changed jsonb;
begin
  if tg_op = 'UPDATE' then
    select coalesce(jsonb_agg(key order by key), '[]'::jsonb)
    into changed
    from jsonb_each(new_row)
    where key not in ('updated_at', 'updated_by')
      and old_row -> key is distinct from new_row -> key;
  else
    changed := jsonb_build_array('record');
  end if;

  insert into public.data_change_audit (
    table_name,
    record_id,
    student_id,
    actor_id,
    action,
    changed_fields,
    client_request_id
  ) values (
    tg_table_name,
    nullif(source_row ->> 'id', '')::uuid,
    coalesce(nullif(source_row ->> 'student_id', ''), nullif(source_row ->> 'assigned_student_id', ''))::uuid,
    auth.uid(),
    lower(tg_op),
    changed,
    nullif(source_row ->> 'client_request_id', '')
  );
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

do $$
declare
  target_table text;
begin
  foreach target_table in array array[
    'daily_checkins', 'body_measurements', 'workout_templates', 'completed_workouts',
    'diet_plans', 'food_logs', 'progress_photos', 'checkin_factors'
  ]
  loop
    execute format('drop trigger if exists %I on public.%I', target_table || '_capture_audit', target_table);
    execute format(
      'create trigger %I after insert or update or delete on public.%I for each row execute function public.monolith_capture_audit()',
      target_table || '_capture_audit', target_table
    );
  end loop;
end;
$$;

create table if not exists public.checkin_corrections (
  id uuid primary key default gen_random_uuid(),
  checkin_id uuid not null references public.daily_checkins(id) on delete cascade,
  student_id uuid not null references public.profiles(id) on delete cascade,
  corrected_by uuid not null references public.profiles(id) on delete restrict,
  old_values jsonb not null,
  new_values jsonb not null,
  reason text not null check (char_length(trim(reason)) between 3 and 500),
  client_request_id text not null unique,
  created_at timestamptz not null default now()
);

create index if not exists checkin_corrections_student_date_idx
on public.checkin_corrections (student_id, created_at desc);

create or replace function public.monolith_current_role()
returns public.monolith_role
language sql
stable
security definer
set search_path = public
as $$
  select role from public.profiles where id = auth.uid();
$$;

create or replace function public.monolith_student_has_active_trainer(p_student_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.trainer_students
    where student_id = p_student_id and status = 'active'
  );
$$;

create or replace function public.correct_daily_checkin(
  p_checkin_id uuid,
  p_items jsonb,
  p_weight_kg numeric,
  p_score integer,
  p_completed integer,
  p_total integer,
  p_reason text,
  p_client_request_id text
)
returns public.daily_checkins
language plpgsql
security definer
set search_path = public
as $$
declare
  current_record public.daily_checkins%rowtype;
  updated_record public.daily_checkins%rowtype;
begin
  if nullif(trim(p_client_request_id), '') is null then
    raise exception 'A client request id is required.';
  end if;
  if char_length(trim(coalesce(p_reason, ''))) not between 3 and 500 then
    raise exception 'A correction reason between 3 and 500 characters is required.';
  end if;

  select * into current_record
  from public.daily_checkins
  where id = p_checkin_id
  for update;

  if current_record.id is null or not public.is_trainer_for(current_record.student_id) then
    raise exception 'You cannot correct this check-in.';
  end if;

  select dc.* into updated_record
  from public.daily_checkins dc
  join public.checkin_corrections cc on cc.checkin_id = dc.id
  where cc.client_request_id = p_client_request_id
  limit 1;
  if updated_record.id is not null then
    return updated_record;
  end if;

  update public.daily_checkins
  set items = coalesce(p_items, '[]'::jsonb),
      weight_kg = p_weight_kg,
      score = p_score,
      completed = p_completed,
      total = p_total,
      last_corrected_by = auth.uid(),
      updated_by = auth.uid()
  where id = current_record.id
  returning * into updated_record;

  insert into public.checkin_corrections (
    checkin_id, student_id, corrected_by, old_values, new_values, reason, client_request_id
  ) values (
    current_record.id,
    current_record.student_id,
    auth.uid(),
    jsonb_build_object(
      'items', current_record.items,
      'weight_kg', current_record.weight_kg,
      'score', current_record.score,
      'completed', current_record.completed,
      'total', current_record.total
    ),
    jsonb_build_object(
      'items', updated_record.items,
      'weight_kg', updated_record.weight_kg,
      'score', updated_record.score,
      'completed', updated_record.completed,
      'total', updated_record.total
    ),
    trim(p_reason),
    p_client_request_id
  );

  insert into public.data_change_audit (
    table_name, record_id, student_id, actor_id, action, changed_fields, reason, client_request_id
  ) values (
    'daily_checkins', current_record.id, current_record.student_id, auth.uid(), 'correction',
    '["items", "weight_kg", "score", "completed", "total"]'::jsonb,
    trim(p_reason), p_client_request_id
  );

  return updated_record;
end;
$$;

alter table public.data_change_audit enable row level security;
alter table public.checkin_corrections enable row level security;

drop policy if exists "data_change_audit_select_scoped" on public.data_change_audit;
create policy "data_change_audit_select_scoped"
on public.data_change_audit for select
using (
  actor_id = auth.uid()
  or student_id = auth.uid()
  or public.is_trainer_for(student_id)
  or public.monolith_current_role() = 'admin'
);

drop policy if exists "checkin_corrections_select_scoped" on public.checkin_corrections;
create policy "checkin_corrections_select_scoped"
on public.checkin_corrections for select
using (student_id = auth.uid() or public.is_trainer_for(student_id));

-- Students answer their own check-ins. Linked trainers correct through correct_daily_checkin(), which requires a reason.
drop policy if exists "daily_checkins_write_owner" on public.daily_checkins;
drop policy if exists "daily_checkins_write_owner_or_trainer" on public.daily_checkins;
drop policy if exists "daily_checkins_insert_owner" on public.daily_checkins;
drop policy if exists "daily_checkins_update_owner" on public.daily_checkins;

create policy "daily_checkins_insert_owner"
on public.daily_checkins for insert
with check (student_id = auth.uid() and answered_by = auth.uid());

create policy "daily_checkins_update_owner"
on public.daily_checkins for update
using (student_id = auth.uid() and checkin_date >= current_date - 7)
with check (student_id = auth.uid() and answered_by = auth.uid() and checkin_date <= current_date);

-- Trainers own checklist definitions. A student may manage their own list only while not linked.
drop policy if exists "checkin_factors_write_owner" on public.checkin_factors;
drop policy if exists "checkin_factors_write_owner_or_trainer" on public.checkin_factors;
drop policy if exists "checkin_factors_write_scoped" on public.checkin_factors;
create policy "checkin_factors_write_scoped"
on public.checkin_factors for all
using (
  public.is_trainer_for(student_id)
  or (
    student_id = auth.uid()
    and public.monolith_current_role() = 'student'
    and not public.monolith_student_has_active_trainer(auth.uid())
  )
)
with check (
  public.is_trainer_for(student_id)
  or (
    student_id = auth.uid()
    and public.monolith_current_role() = 'student'
    and not public.monolith_student_has_active_trainer(auth.uid())
  )
);

-- A linked student cannot edit the trainer's prescription. Standalone students can keep self-created workouts.
drop policy if exists "workout_templates_write_owner" on public.workout_templates;
drop policy if exists "workout_templates_write_owner_or_linked" on public.workout_templates;
drop policy if exists "workout_templates_write_scoped" on public.workout_templates;
create policy "workout_templates_write_scoped"
on public.workout_templates for all
using (
  owner_id = auth.uid()
  and (
    (
      public.monolith_current_role() in ('trainer_basic', 'trainer_plus', 'admin')
      and (assigned_student_id is null or public.is_trainer_for(assigned_student_id))
    )
    or (
      public.monolith_current_role() = 'student'
      and assigned_student_id is null
      and not public.monolith_student_has_active_trainer(auth.uid())
    )
  )
)
with check (
  owner_id = auth.uid()
  and (
    (
      public.monolith_current_role() in ('trainer_basic', 'trainer_plus', 'admin')
      and (assigned_student_id is null or public.is_trainer_for(assigned_student_id))
    )
    or (
      public.monolith_current_role() = 'student'
      and assigned_student_id is null
      and not public.monolith_student_has_active_trainer(auth.uid())
    )
  )
);

revoke all on function public.correct_daily_checkin(uuid, jsonb, numeric, integer, integer, integer, text, text) from public;
revoke all on function public.monolith_current_role() from public;
revoke all on function public.monolith_student_has_active_trainer(uuid) from public;
grant execute on function public.correct_daily_checkin(uuid, jsonb, numeric, integer, integer, integer, text, text) to authenticated;
grant execute on function public.monolith_current_role() to authenticated;
grant execute on function public.monolith_student_has_active_trainer(uuid) to authenticated;
grant select on public.data_change_audit to authenticated;
grant select on public.checkin_corrections to authenticated;

select
  'Monolith validation, authorship, audit and scoped writes ready' as status,
  now() as checked_at;
