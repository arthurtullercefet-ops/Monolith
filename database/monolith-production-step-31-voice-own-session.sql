-- Monolith production step 31
-- Allows any authenticated profile to persist only its own Voice workout session.
-- Trainers still cannot create or update Voice sessions for linked students.
-- Safe to run more than once after production step 30.

begin;

drop policy if exists "voice_sessions_owner_insert" on public.workout_voice_sessions;
create policy "voice_sessions_owner_insert"
on public.workout_voice_sessions for insert
with check (
  student_id = auth.uid()
  and (
    workout_template_id is null
    or exists (
      select 1
      from public.workout_templates wt
      where wt.id = workout_voice_sessions.workout_template_id
        and (
          wt.assigned_student_id = auth.uid()
          or (wt.owner_id = auth.uid() and wt.assigned_student_id is null)
        )
    )
  )
);

drop policy if exists "voice_sessions_owner_update" on public.workout_voice_sessions;
create policy "voice_sessions_owner_update"
on public.workout_voice_sessions for update
using (student_id = auth.uid())
with check (
  student_id = auth.uid()
  and (
    workout_template_id is null
    or exists (
      select 1
      from public.workout_templates wt
      where wt.id = workout_voice_sessions.workout_template_id
        and (
          wt.assigned_student_id = auth.uid()
          or (wt.owner_id = auth.uid() and wt.assigned_student_id is null)
        )
    )
  )
);

drop policy if exists "voice_sessions_owner_delete" on public.workout_voice_sessions;
create policy "voice_sessions_owner_delete"
on public.workout_voice_sessions for delete
using (student_id = auth.uid());

drop policy if exists "voice_commands_owner_insert" on public.workout_voice_commands;
create policy "voice_commands_owner_insert"
on public.workout_voice_commands for insert
with check (
  student_id = auth.uid()
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
using (student_id = auth.uid())
with check (
  student_id = auth.uid()
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

notify pgrst, 'reload schema';

commit;

select
  'Monolith own Voice sessions ready' as status,
  now() as checked_at;
