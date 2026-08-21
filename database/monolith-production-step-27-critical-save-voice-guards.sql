-- Step 27: critical pre-launch save guards.
-- Fixes shared trigger field access, Voice command constraints and privacy gates.
-- Safe to rerun. It does not delete existing user data.

begin;

create or replace function public.monolith_validate_daily_checkin_date()
returns trigger
language plpgsql
as $$
begin
  if new.checkin_date > current_date then
    raise exception 'Check-in date cannot be in the future.';
  end if;
  return new;
end;
$$;

create or replace function public.monolith_validate_body_measurement_date()
returns trigger
language plpgsql
as $$
begin
  if new.measurement_date > current_date then
    raise exception 'Measurement date cannot be in the future.';
  end if;
  return new;
end;
$$;

create or replace function public.monolith_validate_completed_workout_date()
returns trigger
language plpgsql
as $$
begin
  if new.completed_at > now() + interval '5 minutes' then
    raise exception 'Workout completion date cannot be in the future.';
  end if;
  return new;
end;
$$;

drop trigger if exists daily_checkins_validate_date on public.daily_checkins;
create trigger daily_checkins_validate_date
before insert or update on public.daily_checkins
for each row execute function public.monolith_validate_daily_checkin_date();

drop trigger if exists body_measurements_validate_date on public.body_measurements;
create trigger body_measurements_validate_date
before insert or update on public.body_measurements
for each row execute function public.monolith_validate_body_measurement_date();

drop trigger if exists completed_workouts_validate_date on public.completed_workouts;
create trigger completed_workouts_validate_date
before insert or update on public.completed_workouts
for each row execute function public.monolith_validate_completed_workout_date();

comment on function public.monolith_validate_daily_checkin_date() is 'Monolith Step 27: validates only daily_checkins.checkin_date.';
comment on function public.monolith_validate_body_measurement_date() is 'Monolith Step 27: validates only body_measurements.measurement_date.';
comment on function public.monolith_validate_completed_workout_date() is 'Monolith Step 27: validates only completed_workouts.completed_at.';

do $$
begin
  if to_regclass('public.workout_voice_commands') is not null then
    alter table public.workout_voice_commands
      drop constraint if exists workout_voice_commands_intent_check;

    alter table public.workout_voice_commands
      add constraint workout_voice_commands_intent_check check (intent in (
        'start_workout',
        'select_exercise',
        'record_set',
        'repeat_set',
        'correct_set',
        'undo',
        'start_rest',
        'next_exercise',
        'query_sets',
        'query_weight',
        'query_current_exercise',
        'query_next_set',
        'query_remaining_sets',
        'repeat_instruction',
        'finish_workout',
        'confirm',
        'cancel',
        'unknown'
      ));

    alter table public.workout_voice_commands
      drop constraint if exists workout_voice_commands_status_check;

    alter table public.workout_voice_commands
      add constraint workout_voice_commands_status_check check (status in (
        'received',
        'confirmed',
        'interpreted',
        'applied',
        'rejected',
        'undone',
        'duplicate'
      ));
  end if;
end;
$$;

create unique index if not exists completed_workouts_student_client_request_uidx
on public.completed_workouts (student_id, client_request_id)
where client_request_id is not null;

create unique index if not exists daily_checkins_student_client_request_uidx
on public.daily_checkins (student_id, client_request_id)
where client_request_id is not null;

create unique index if not exists body_measurements_student_client_request_uidx
on public.body_measurements (student_id, client_request_id)
where client_request_id is not null;

drop policy if exists "anamneses_select_scoped_submitted" on public.student_anamneses;
drop policy if exists "student_anamneses_select_scoped" on public.student_anamneses;
drop policy if exists "student_anamneses_select_owner_or_trainer" on public.student_anamneses;
create policy "anamneses_select_scoped_submitted"
on public.student_anamneses for select
using (
  student_id = auth.uid()
  or (
    public.monolith_current_role() in ('trainer_basic', 'trainer_plus', 'admin')
    and public.is_trainer_for(student_id)
    and status in ('submitted', 'reviewed')
    and consent is true
  )
);

grant execute on function public.monolith_validate_daily_checkin_date() to authenticated;
grant execute on function public.monolith_validate_body_measurement_date() to authenticated;
grant execute on function public.monolith_validate_completed_workout_date() to authenticated;

commit;

select
  'Monolith critical save and voice guards ready' as status,
  now() as checked_at;
