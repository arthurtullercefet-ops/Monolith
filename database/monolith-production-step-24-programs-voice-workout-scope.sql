-- Monolith production step 24
-- Repairs the existing Programs and Monolith Voice architecture and locks
-- workout/check-in definitions to trainers with an active student link.
-- Safe to run more than once after production step 23. No records are deleted.

begin;

do $$
begin
  if to_regclass('public.profiles') is null
     or to_regclass('public.workout_templates') is null
     or to_regclass('public.checkin_factors') is null
     or to_regprocedure('public.is_trainer_for(uuid)') is null
     or to_regprocedure('public.monolith_current_role()') is null
     or to_regprocedure('public.touch_updated_at()') is null
     or to_regprocedure('public.monolith_capture_audit()') is null then
    raise exception 'Monolith step 24 requires the base schema and production steps through 14.';
  end if;
end;
$$;

-- This is the same workout_programs table expected by the application and step 15.
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
  if not exists (
    select 1
    from pg_constraint
    where conname = 'workout_programs_schedule_check'
      and conrelid = 'public.workout_programs'::regclass
  ) then
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
using (
  student_id = auth.uid()
  or (
    public.monolith_current_role() in ('trainer_basic', 'trainer_plus', 'admin')
    and public.is_trainer_for(student_id)
  )
);

drop policy if exists "workout_programs_write_linked_trainer" on public.workout_programs;
create policy "workout_programs_write_linked_trainer"
on public.workout_programs for all
using (
  trainer_id = auth.uid()
  and public.monolith_current_role() in ('trainer_basic', 'trainer_plus', 'admin')
  and public.is_trainer_for(student_id)
)
with check (
  trainer_id = auth.uid()
  and public.monolith_current_role() in ('trainer_basic', 'trainer_plus', 'admin')
  and public.is_trainer_for(student_id)
);

grant select, insert, update, delete on public.workout_programs to authenticated;

-- These are the same Voice tables expected by the application and step 22.
create table if not exists public.workout_voice_sessions (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.profiles(id) on delete cascade,
  workout_template_id uuid references public.workout_templates(id) on delete set null,
  session_key text not null,
  status text not null default 'active' check (status in ('active', 'paused', 'completed', 'expired', 'stopped')),
  state jsonb not null default '{}'::jsonb,
  settings jsonb not null default '{}'::jsonb,
  started_at timestamptz not null default now(),
  expires_at timestamptz not null,
  last_command_at timestamptz,
  ended_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (student_id, session_key),
  check (expires_at > started_at),
  check (expires_at <= started_at + interval '2 hours 5 minutes')
);

create table if not exists public.workout_voice_commands (
  id uuid primary key default gen_random_uuid(),
  voice_session_id uuid references public.workout_voice_sessions(id) on delete cascade,
  student_id uuid not null references public.profiles(id) on delete cascade,
  command_id text not null unique,
  intent text not null check (intent in (
    'start_workout', 'select_exercise', 'record_set', 'repeat_set', 'correct_set',
    'undo', 'start_rest', 'next_exercise', 'query_sets', 'query_weight',
    'finish_workout', 'confirm', 'cancel', 'unknown'
  )),
  status text not null check (status in ('received', 'confirmed', 'applied', 'rejected', 'undone', 'duplicate')),
  confidence numeric(4, 3) check (confidence is null or (confidence >= 0 and confidence <= 1)),
  normalized_payload jsonb not null default '{}'::jsonb,
  transcript_excerpt text,
  created_at timestamptz not null default now()
);

create index if not exists workout_voice_sessions_student_status_idx
on public.workout_voice_sessions (student_id, status, updated_at desc);

create index if not exists workout_voice_commands_student_created_idx
on public.workout_voice_commands (student_id, created_at desc);

alter table public.workout_voice_sessions enable row level security;
alter table public.workout_voice_commands enable row level security;

drop trigger if exists workout_voice_sessions_touch_updated_at on public.workout_voice_sessions;
create trigger workout_voice_sessions_touch_updated_at
before update on public.workout_voice_sessions
for each row execute function public.touch_updated_at();

drop policy if exists "voice_sessions_owner_select" on public.workout_voice_sessions;
drop policy if exists "voice_sessions_select_scoped" on public.workout_voice_sessions;
create policy "voice_sessions_select_scoped"
on public.workout_voice_sessions for select
using (
  student_id = auth.uid()
  or (
    public.monolith_current_role() in ('trainer_basic', 'trainer_plus', 'admin')
    and public.is_trainer_for(student_id)
  )
);

drop policy if exists "voice_sessions_owner_insert" on public.workout_voice_sessions;
create policy "voice_sessions_owner_insert"
on public.workout_voice_sessions for insert
with check (
  student_id = auth.uid()
  and public.monolith_current_role() = 'student'
  and (
    workout_template_id is null
    or exists (
      select 1
      from public.workout_templates wt
      where wt.id = workout_voice_sessions.workout_template_id
        and (
          wt.assigned_student_id = auth.uid()
          or (wt.assigned_student_id is null and wt.owner_id = auth.uid())
        )
    )
  )
);

drop policy if exists "voice_sessions_owner_update" on public.workout_voice_sessions;
create policy "voice_sessions_owner_update"
on public.workout_voice_sessions for update
using (student_id = auth.uid() and public.monolith_current_role() = 'student')
with check (
  student_id = auth.uid()
  and public.monolith_current_role() = 'student'
  and (
    workout_template_id is null
    or exists (
      select 1
      from public.workout_templates wt
      where wt.id = workout_voice_sessions.workout_template_id
        and (
          wt.assigned_student_id = auth.uid()
          or (wt.assigned_student_id is null and wt.owner_id = auth.uid())
        )
    )
  )
);

drop policy if exists "voice_sessions_owner_delete" on public.workout_voice_sessions;
create policy "voice_sessions_owner_delete"
on public.workout_voice_sessions for delete
using (student_id = auth.uid() and public.monolith_current_role() = 'student');

drop policy if exists "voice_commands_owner_select" on public.workout_voice_commands;
drop policy if exists "voice_commands_select_scoped" on public.workout_voice_commands;
create policy "voice_commands_select_scoped"
on public.workout_voice_commands for select
using (
  student_id = auth.uid()
  or (
    public.monolith_current_role() in ('trainer_basic', 'trainer_plus', 'admin')
    and public.is_trainer_for(student_id)
  )
);

drop policy if exists "voice_commands_owner_insert" on public.workout_voice_commands;
create policy "voice_commands_owner_insert"
on public.workout_voice_commands for insert
with check (
  student_id = auth.uid()
  and public.monolith_current_role() = 'student'
  and (
    voice_session_id is null
    or exists (
      select 1
      from public.workout_voice_sessions vs
      where vs.id = workout_voice_commands.voice_session_id
        and vs.student_id = auth.uid()
    )
  )
);

drop policy if exists "voice_commands_owner_update" on public.workout_voice_commands;
create policy "voice_commands_owner_update"
on public.workout_voice_commands for update
using (student_id = auth.uid() and public.monolith_current_role() = 'student')
with check (
  student_id = auth.uid()
  and public.monolith_current_role() = 'student'
  and (
    voice_session_id is null
    or exists (
      select 1
      from public.workout_voice_sessions vs
      where vs.id = workout_voice_commands.voice_session_id
        and vs.student_id = auth.uid()
    )
  )
);

grant select, insert, update, delete on public.workout_voice_sessions to authenticated;
grant select, insert, update on public.workout_voice_commands to authenticated;
revoke delete on public.workout_voice_commands from authenticated;

-- Students may execute assigned workouts but cannot create, alter or delete
-- trainer-authored templates, including by calling the API directly.
alter table public.workout_templates enable row level security;

drop policy if exists "workout_templates_select_owner_assigned_or_trainer" on public.workout_templates;
drop policy if exists "workout_templates_select_scoped" on public.workout_templates;
create policy "workout_templates_select_scoped"
on public.workout_templates for select
using (
  owner_id = auth.uid()
  or assigned_student_id = auth.uid()
  or (
    assigned_student_id is not null
    and public.monolith_current_role() in ('trainer_basic', 'trainer_plus', 'admin')
    and public.is_trainer_for(assigned_student_id)
  )
);

drop policy if exists "workout_templates_write_owner" on public.workout_templates;
drop policy if exists "workout_templates_write_owner_or_linked" on public.workout_templates;
drop policy if exists "workout_templates_write_scoped" on public.workout_templates;
drop policy if exists "workout_templates_write_linked_trainer" on public.workout_templates;
create policy "workout_templates_write_linked_trainer"
on public.workout_templates for all
using (
  owner_id = auth.uid()
  and public.monolith_current_role() in ('trainer_basic', 'trainer_plus', 'admin')
  and (assigned_student_id is null or public.is_trainer_for(assigned_student_id))
)
with check (
  owner_id = auth.uid()
  and public.monolith_current_role() in ('trainer_basic', 'trainer_plus', 'admin')
  and (assigned_student_id is null or public.is_trainer_for(assigned_student_id))
);

-- Daily task definitions belong to the linked trainer. Students only answer
-- the resulting daily check-in; they cannot redefine the global checklist.
alter table public.checkin_factors enable row level security;

drop policy if exists "checkin_factors_write_owner" on public.checkin_factors;
drop policy if exists "checkin_factors_write_owner_or_trainer" on public.checkin_factors;
drop policy if exists "checkin_factors_write_scoped" on public.checkin_factors;
drop policy if exists "checkin_factors_write_linked_trainer" on public.checkin_factors;
create policy "checkin_factors_write_linked_trainer"
on public.checkin_factors for all
using (
  public.monolith_current_role() in ('trainer_basic', 'trainer_plus', 'admin')
  and public.is_trainer_for(student_id)
)
with check (
  public.monolith_current_role() in ('trainer_basic', 'trainer_plus', 'admin')
  and public.is_trainer_for(student_id)
);

notify pgrst, 'reload schema';

commit;

select
  'Monolith programs, voice and student workout scope ready' as status,
  to_regclass('public.workout_programs') is not null as workout_programs_ready,
  to_regclass('public.workout_voice_sessions') is not null as voice_sessions_ready,
  to_regclass('public.workout_voice_commands') is not null as voice_commands_ready,
  now() as checked_at;
