-- Monolith production step 22
-- Monolith Voice Beta: bounded workout voice sessions and idempotent command receipts.
-- Additive and safe to run more than once after step 21.

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
  -- Kept null by the web client by default. No audio is stored in this table.
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
create policy "voice_sessions_owner_select"
on public.workout_voice_sessions for select
using (student_id = auth.uid());

drop policy if exists "voice_sessions_owner_insert" on public.workout_voice_sessions;
create policy "voice_sessions_owner_insert"
on public.workout_voice_sessions for insert
with check (student_id = auth.uid());

drop policy if exists "voice_sessions_owner_update" on public.workout_voice_sessions;
create policy "voice_sessions_owner_update"
on public.workout_voice_sessions for update
using (student_id = auth.uid())
with check (student_id = auth.uid());

drop policy if exists "voice_sessions_owner_delete" on public.workout_voice_sessions;
create policy "voice_sessions_owner_delete"
on public.workout_voice_sessions for delete
using (student_id = auth.uid());

drop policy if exists "voice_commands_owner_select" on public.workout_voice_commands;
create policy "voice_commands_owner_select"
on public.workout_voice_commands for select
using (student_id = auth.uid());

drop policy if exists "voice_commands_owner_insert" on public.workout_voice_commands;
create policy "voice_commands_owner_insert"
on public.workout_voice_commands for insert
with check (student_id = auth.uid());

-- Allows a retry with the same command_id to resolve idempotently for its owner.
drop policy if exists "voice_commands_owner_update" on public.workout_voice_commands;
create policy "voice_commands_owner_update"
on public.workout_voice_commands for update
using (student_id = auth.uid())
with check (student_id = auth.uid());

grant select, insert, update, delete on public.workout_voice_sessions to authenticated;
grant select, insert, update on public.workout_voice_commands to authenticated;
