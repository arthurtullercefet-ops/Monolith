-- Monolith production step 19
-- Contextual feedback (without media) and private transformation timeline.
-- Safe to run more than once after production step 18. No user data is deleted.

create table if not exists public.contextual_feedback (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.profiles(id) on delete cascade,
  trainer_id uuid references public.profiles(id) on delete set null,
  context_type text not null check (context_type in ('workout', 'exercise', 'checkin')),
  context_id text,
  context_label text,
  difficulty smallint check (difficulty between 1 and 5),
  comment text check (char_length(comment) <= 1000),
  flags text[] not null default '{}',
  status text not null default 'pending' check (status in ('pending', 'reviewed', 'resolved')),
  trainer_response text check (char_length(trainer_response) <= 1000),
  responded_by uuid references public.profiles(id) on delete set null,
  responded_at timestamptz,
  client_request_id uuid not null unique,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (comment is not null or difficulty is not null or cardinality(flags) > 0),
  check (flags <@ array['replacement','question','discomfort','too_easy','too_hard']::text[])
);

create table if not exists public.transformation_events (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.profiles(id) on delete cascade,
  trainer_id uuid references public.profiles(id) on delete set null,
  event_type text not null check (event_type in ('workout', 'record', 'weight', 'measurement', 'photo', 'streak', 'diet', 'program', 'achievement', 'feedback')),
  source_id text,
  title text not null check (char_length(title) between 1 and 160),
  details jsonb not null default '{}'::jsonb,
  occurred_at timestamptz not null default now(),
  client_request_id uuid not null unique,
  created_at timestamptz not null default now()
);

create index if not exists contextual_feedback_student_date_idx on public.contextual_feedback (student_id, created_at desc);
create index if not exists contextual_feedback_trainer_status_idx on public.contextual_feedback (trainer_id, status, created_at desc);
create index if not exists transformation_events_student_date_idx on public.transformation_events (student_id, occurred_at desc);

create or replace function public.monolith_guard_feedback_update()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  new.updated_at = now();
  if auth.uid() = old.student_id then
    new.student_id = old.student_id;
    new.trainer_id = old.trainer_id;
    new.trainer_response = old.trainer_response;
    new.responded_by = old.responded_by;
    new.responded_at = old.responded_at;
    new.status = old.status;
  elsif old.trainer_id = auth.uid() and public.is_trainer_for(old.student_id) then
    new.student_id = old.student_id;
    new.trainer_id = old.trainer_id;
    new.context_type = old.context_type;
    new.context_id = old.context_id;
    new.context_label = old.context_label;
    new.difficulty = old.difficulty;
    new.comment = old.comment;
    new.flags = old.flags;
    new.client_request_id = old.client_request_id;
    if new.trainer_response is distinct from old.trainer_response then
      new.responded_by = auth.uid();
      new.responded_at = now();
      if new.status = 'pending' then new.status = 'reviewed'; end if;
    end if;
  else
    raise exception 'Feedback update is not allowed';
  end if;
  return new;
end;
$$;

drop trigger if exists contextual_feedback_guard_update on public.contextual_feedback;
create trigger contextual_feedback_guard_update before update on public.contextual_feedback
for each row execute function public.monolith_guard_feedback_update();

alter table public.contextual_feedback enable row level security;
alter table public.transformation_events enable row level security;

drop policy if exists "feedback_private_select" on public.contextual_feedback;
drop policy if exists "feedback_student_insert" on public.contextual_feedback;
drop policy if exists "feedback_linked_update" on public.contextual_feedback;
drop policy if exists "timeline_private_select" on public.transformation_events;
drop policy if exists "timeline_owner_insert" on public.transformation_events;

create policy "feedback_private_select" on public.contextual_feedback for select
using (student_id = auth.uid() or (trainer_id = auth.uid() and public.is_trainer_for(student_id)));

create policy "feedback_student_insert" on public.contextual_feedback for insert
with check (
  student_id = auth.uid()
  and (trainer_id is null or exists (
    select 1 from public.trainer_students ts
    where ts.student_id = auth.uid() and ts.trainer_id = contextual_feedback.trainer_id and ts.status = 'active'
  ))
);

create policy "feedback_linked_update" on public.contextual_feedback for update
using (student_id = auth.uid() or (trainer_id = auth.uid() and public.is_trainer_for(student_id)))
with check (student_id = auth.uid() or (trainer_id = auth.uid() and public.is_trainer_for(student_id)));

create policy "timeline_private_select" on public.transformation_events for select
using (student_id = auth.uid() or (trainer_id = auth.uid() and public.is_trainer_for(student_id)));

create policy "timeline_owner_insert" on public.transformation_events for insert
with check (
  student_id = auth.uid()
  or (trainer_id = auth.uid() and public.is_trainer_for(student_id))
);

grant select, insert, update on public.contextual_feedback to authenticated;
grant select, insert on public.transformation_events to authenticated;
