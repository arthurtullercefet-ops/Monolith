-- Monolith production step 15
-- Adds trainer-authored workout programs and calendar assignments.
-- Safe to run more than once after production step 14.

create table if not exists public.workout_programs (
  id uuid primary key default gen_random_uuid(),
  trainer_id uuid not null references public.profiles(id) on delete cascade,
  student_id uuid not null references public.profiles(id) on delete cascade,
  name text not null check (char_length(trim(name)) between 2 and 120),
  duration_weeks integer not null check (duration_weeks in (4, 8, 12)),
  start_date date not null,
  status text not null default 'active' check (status in ('draft', 'active', 'paused', 'completed', 'archived')),
  schedule jsonb not null default '[]'::jsonb,
  client_request_id text,
  created_by uuid references public.profiles(id) on delete set null,
  updated_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists workout_programs_client_request_uidx
on public.workout_programs (client_request_id)
where client_request_id is not null;

create index if not exists workout_programs_student_status_idx
on public.workout_programs (student_id, status, start_date desc);

create index if not exists workout_programs_trainer_status_idx
on public.workout_programs (trainer_id, status, updated_at desc);

create or replace function public.monolith_program_schedule_is_valid(p_schedule jsonb)
returns boolean
language plpgsql
immutable
as $$
declare
  item jsonb;
  day_number integer;
begin
  if p_schedule is null or jsonb_typeof(p_schedule) <> 'array' or jsonb_array_length(p_schedule) > 7 then
    return false;
  end if;
  for item in select value from jsonb_array_elements(p_schedule)
  loop
    if jsonb_typeof(item) <> 'object' then return false; end if;
    day_number := nullif(item ->> 'dayOfWeek', '')::integer;
    if day_number not between 0 and 6 then return false; end if;
    if coalesce(item ->> 'kind', 'workout') not in ('workout', 'rest') then return false; end if;
    if coalesce(item ->> 'kind', 'workout') = 'workout'
       and nullif(item ->> 'workoutId', '') is null then return false; end if;
  end loop;
  return true;
exception when others then
  return false;
end;
$$;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'workout_programs_schedule_check') then
    alter table public.workout_programs add constraint workout_programs_schedule_check
      check (public.monolith_program_schedule_is_valid(schedule)) not valid;
  end if;
end;
$$;

create or replace function public.monolith_set_program_metadata()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'INSERT' then
    new.created_by = auth.uid();
    new.trainer_id = auth.uid();
  else
    new.created_by = old.created_by;
    new.trainer_id = old.trainer_id;
  end if;
  if new.status = 'active' then
    update public.workout_programs
    set status = 'paused', updated_at = now(), updated_by = auth.uid()
    where student_id = new.student_id and id <> new.id and status = 'active';
  end if;
  new.updated_by = auth.uid();
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists workout_programs_set_metadata on public.workout_programs;
create trigger workout_programs_set_metadata
before insert or update on public.workout_programs
for each row execute function public.monolith_set_program_metadata();

drop trigger if exists workout_programs_capture_audit on public.workout_programs;
create trigger workout_programs_capture_audit
after insert or update or delete on public.workout_programs
for each row execute function public.monolith_capture_audit();

alter table public.workout_programs enable row level security;

drop policy if exists "workout_programs_select_scoped" on public.workout_programs;
create policy "workout_programs_select_scoped"
on public.workout_programs for select
using (student_id = auth.uid() or public.is_trainer_for(student_id));

drop policy if exists "workout_programs_write_linked_trainer" on public.workout_programs;
create policy "workout_programs_write_linked_trainer"
on public.workout_programs for all
using (trainer_id = auth.uid() and public.is_trainer_for(student_id))
with check (trainer_id = auth.uid() and public.is_trainer_for(student_id));

grant select, insert, update, delete on public.workout_programs to authenticated;

select 'Monolith workout programs ready' as status, now() as checked_at;
