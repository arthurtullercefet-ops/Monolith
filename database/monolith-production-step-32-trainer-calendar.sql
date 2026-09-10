-- Monolith production step 32
-- Private trainer calendar, weekly recurrence, student confirmation and rescheduling.
-- Additive and safe to run more than once after production step 31.

alter table public.profiles
  add column if not exists timezone text not null default 'UTC';

create table if not exists public.appointment_series (
  id uuid primary key default gen_random_uuid(),
  trainer_id uuid not null references public.profiles(id) on delete cascade,
  student_id uuid references public.profiles(id) on delete set null,
  appointment_type text not null check (appointment_type in ('in_person_training', 'online_training', 'anamnesis', 'physical_assessment', 'meeting', 'other', 'private_block')),
  timezone text not null,
  start_date date not null,
  start_time time not null,
  duration_minutes integer not null check (duration_minutes between 5 and 1440),
  weekdays smallint[] not null,
  end_date date not null,
  occurrence_limit integer not null check (occurrence_limit between 1 and 100),
  location text,
  meeting_url text,
  shared_notes text,
  status text not null default 'active' check (status in ('active', 'ended', 'cancelled')),
  client_request_id text not null,
  created_by uuid not null references public.profiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (trainer_id, client_request_id),
  check (cardinality(weekdays) between 1 and 7),
  check (end_date >= start_date and end_date <= start_date + 366)
);

create table if not exists public.appointments (
  id uuid primary key default gen_random_uuid(),
  series_id uuid references public.appointment_series(id) on delete set null,
  rescheduled_from_id uuid references public.appointments(id) on delete set null,
  trainer_id uuid not null references public.profiles(id) on delete cascade,
  student_id uuid references public.profiles(id) on delete set null,
  appointment_type text not null check (appointment_type in ('in_person_training', 'online_training', 'anamnesis', 'physical_assessment', 'meeting', 'other', 'private_block')),
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  timezone text not null,
  location text,
  meeting_url text,
  shared_notes text,
  status text not null default 'awaiting_confirmation' check (status in ('awaiting_confirmation', 'confirmed', 'completed', 'cancelled', 'rescheduled', 'no_show')),
  client_request_id text not null,
  created_by uuid not null references public.profiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (trainer_id, client_request_id),
  check (ends_at > starts_at),
  check ((student_id is null and appointment_type = 'private_block') or student_id is not null)
);

create table if not exists public.appointment_private_notes (
  appointment_id uuid primary key references public.appointments(id) on delete cascade,
  trainer_id uuid not null references public.profiles(id) on delete cascade,
  note text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.appointment_reschedule_requests (
  id uuid primary key default gen_random_uuid(),
  appointment_id uuid not null references public.appointments(id) on delete cascade,
  trainer_id uuid not null references public.profiles(id) on delete cascade,
  student_id uuid not null references public.profiles(id) on delete cascade,
  reason text not null,
  proposed_slots jsonb not null default '[]'::jsonb,
  status text not null default 'pending' check (status in ('pending', 'accepted', 'rejected')),
  replacement_appointment_id uuid references public.appointments(id) on delete set null,
  client_request_id text not null,
  resolved_by uuid references public.profiles(id) on delete set null,
  resolved_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (student_id, client_request_id),
  check (char_length(btrim(reason)) between 2 and 1000),
  check (jsonb_typeof(proposed_slots) = 'array' and jsonb_array_length(proposed_slots) between 1 and 3)
);

create table if not exists public.appointment_events (
  id bigint generated always as identity primary key,
  appointment_id uuid not null references public.appointments(id) on delete cascade,
  trainer_id uuid not null references public.profiles(id) on delete cascade,
  student_id uuid references public.profiles(id) on delete set null,
  actor_id uuid references public.profiles(id) on delete set null,
  event_type text not null,
  from_status text,
  to_status text,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists appointments_trainer_starts_idx on public.appointments (trainer_id, starts_at);
create index if not exists appointments_student_starts_idx on public.appointments (student_id, starts_at) where student_id is not null;
create index if not exists appointments_series_idx on public.appointments (series_id, starts_at) where series_id is not null;
create index if not exists appointment_requests_trainer_status_idx on public.appointment_reschedule_requests (trainer_id, status, created_at desc);
create index if not exists appointment_events_appointment_idx on public.appointment_events (appointment_id, created_at desc);

drop trigger if exists appointment_series_touch_updated_at on public.appointment_series;
create trigger appointment_series_touch_updated_at before update on public.appointment_series
for each row execute function public.touch_updated_at();

drop trigger if exists appointments_touch_updated_at on public.appointments;
create trigger appointments_touch_updated_at before update on public.appointments
for each row execute function public.touch_updated_at();

drop trigger if exists appointment_private_notes_touch_updated_at on public.appointment_private_notes;
create trigger appointment_private_notes_touch_updated_at before update on public.appointment_private_notes
for each row execute function public.touch_updated_at();

drop trigger if exists appointment_reschedule_requests_touch_updated_at on public.appointment_reschedule_requests;
create trigger appointment_reschedule_requests_touch_updated_at before update on public.appointment_reschedule_requests
for each row execute function public.touch_updated_at();

create or replace function public.monolith_active_trainer_student(p_trainer_id uuid, p_student_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select (auth.uid() = p_trainer_id or auth.uid() = p_student_id) and exists (
    select 1 from public.trainer_students ts
    where ts.trainer_id = p_trainer_id
      and ts.student_id = p_student_id
      and ts.status = 'active'
  );
$$;

create or replace function public.monolith_valid_timezone(p_timezone text)
returns boolean
language sql
stable
as $$
  select exists (select 1 from pg_timezone_names where name = p_timezone);
$$;

create or replace function public.monolith_capture_appointment_event()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.appointment_events (
    appointment_id, trainer_id, student_id, actor_id, event_type, from_status, to_status, details
  ) values (
    new.id,
    new.trainer_id,
    new.student_id,
    auth.uid(),
    case
      when tg_op = 'INSERT' then 'created'
      when old.status is distinct from new.status then 'status_changed'
      else 'updated'
    end,
    case when tg_op = 'UPDATE' then old.status else null end,
    new.status,
    case when tg_op = 'UPDATE' then jsonb_build_object('previous_starts_at', old.starts_at, 'starts_at', new.starts_at) else '{}'::jsonb end
  );
  return new;
end;
$$;

drop trigger if exists appointments_capture_event on public.appointments;
create trigger appointments_capture_event
after insert or update on public.appointments
for each row execute function public.monolith_capture_appointment_event();

alter table public.appointment_series enable row level security;
alter table public.appointments enable row level security;
alter table public.appointment_private_notes enable row level security;
alter table public.appointment_reschedule_requests enable row level security;
alter table public.appointment_events enable row level security;

drop policy if exists "appointment_series_select_scoped" on public.appointment_series;
create policy "appointment_series_select_scoped" on public.appointment_series for select
using (trainer_id = auth.uid() or student_id = auth.uid());

drop policy if exists "appointment_series_trainer_insert" on public.appointment_series;
create policy "appointment_series_trainer_insert" on public.appointment_series for insert
with check (
  trainer_id = auth.uid()
  and created_by = auth.uid()
  and (student_id is null or public.monolith_active_trainer_student(auth.uid(), student_id))
);

drop policy if exists "appointment_series_trainer_update" on public.appointment_series;
create policy "appointment_series_trainer_update" on public.appointment_series for update
using (trainer_id = auth.uid()) with check (trainer_id = auth.uid());

drop policy if exists "appointments_select_scoped" on public.appointments;
create policy "appointments_select_scoped" on public.appointments for select
using (trainer_id = auth.uid() or student_id = auth.uid());

drop policy if exists "appointments_trainer_insert" on public.appointments;
create policy "appointments_trainer_insert" on public.appointments for insert
with check (
  trainer_id = auth.uid()
  and created_by = auth.uid()
  and (student_id is null or public.monolith_active_trainer_student(auth.uid(), student_id))
);

drop policy if exists "appointments_trainer_update" on public.appointments;
create policy "appointments_trainer_update" on public.appointments for update
using (trainer_id = auth.uid()) with check (trainer_id = auth.uid());

drop policy if exists "appointment_private_notes_trainer_all" on public.appointment_private_notes;
create policy "appointment_private_notes_trainer_all" on public.appointment_private_notes for all
using (trainer_id = auth.uid()) with check (trainer_id = auth.uid());

drop policy if exists "appointment_requests_select_scoped" on public.appointment_reschedule_requests;
create policy "appointment_requests_select_scoped" on public.appointment_reschedule_requests for select
using (trainer_id = auth.uid() or student_id = auth.uid());

drop policy if exists "appointment_events_select_scoped" on public.appointment_events;
create policy "appointment_events_select_scoped" on public.appointment_events for select
using (trainer_id = auth.uid() or student_id = auth.uid());

create or replace function public.create_monolith_appointment(
  p_student_id uuid,
  p_appointment_type text,
  p_start_date date,
  p_start_time time,
  p_duration_minutes integer,
  p_timezone text,
  p_location text,
  p_meeting_url text,
  p_shared_notes text,
  p_private_notes text,
  p_client_request_id text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_trainer_id uuid := auth.uid();
  v_id uuid;
  v_starts_at timestamptz;
  v_type text := case when p_student_id is null then 'private_block' else p_appointment_type end;
begin
  if v_trainer_id is null or not exists (
    select 1 from public.profiles p where p.id = v_trainer_id and p.role in ('trainer_basic', 'trainer_plus', 'admin')
  ) then raise exception 'Only trainers can create appointments'; end if;
  if p_student_id is not null and not public.monolith_active_trainer_student(v_trainer_id, p_student_id) then
    raise exception 'Student is not actively linked to this trainer';
  end if;
  if p_duration_minutes is null or p_duration_minutes not between 5 and 1440 then raise exception 'Invalid duration'; end if;
  if not public.monolith_valid_timezone(p_timezone) then raise exception 'Invalid timezone'; end if;
  if nullif(btrim(p_client_request_id), '') is null then raise exception 'A request key is required'; end if;

  select id into v_id from public.appointments
  where trainer_id = v_trainer_id and client_request_id = p_client_request_id;
  if v_id is not null then return v_id; end if;

  v_starts_at := (p_start_date + p_start_time) at time zone p_timezone;
  insert into public.appointments (
    trainer_id, student_id, appointment_type, starts_at, ends_at, timezone,
    location, meeting_url, shared_notes, status, client_request_id, created_by
  ) values (
    v_trainer_id, p_student_id, v_type, v_starts_at,
    v_starts_at + make_interval(mins => p_duration_minutes), p_timezone,
    nullif(btrim(p_location), ''), nullif(btrim(p_meeting_url), ''), nullif(btrim(p_shared_notes), ''),
    case when p_student_id is null then 'confirmed' else 'awaiting_confirmation' end,
    p_client_request_id, v_trainer_id
  ) returning id into v_id;

  if nullif(btrim(p_private_notes), '') is not null then
    insert into public.appointment_private_notes (appointment_id, trainer_id, note)
    values (v_id, v_trainer_id, btrim(p_private_notes));
  end if;
  return v_id;
end;
$$;

create or replace function public.create_monolith_appointment_series(
  p_student_id uuid,
  p_appointment_type text,
  p_start_date date,
  p_start_time time,
  p_duration_minutes integer,
  p_timezone text,
  p_weekdays smallint[],
  p_end_date date,
  p_occurrence_limit integer,
  p_location text,
  p_meeting_url text,
  p_shared_notes text,
  p_private_notes text,
  p_client_request_id text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_trainer_id uuid := auth.uid();
  v_series_id uuid;
  v_type text := case when p_student_id is null then 'private_block' else p_appointment_type end;
  v_day date;
  v_appointment_id uuid;
  v_starts_at timestamptz;
begin
  if v_trainer_id is null or not exists (
    select 1 from public.profiles p where p.id = v_trainer_id and p.role in ('trainer_basic', 'trainer_plus', 'admin')
  ) then raise exception 'Only trainers can create appointment series'; end if;
  if p_student_id is not null and not public.monolith_active_trainer_student(v_trainer_id, p_student_id) then
    raise exception 'Student is not actively linked to this trainer';
  end if;
  if p_duration_minutes is null or p_duration_minutes not between 5 and 1440 then raise exception 'Invalid duration'; end if;
  if p_occurrence_limit is null or p_occurrence_limit not between 1 and 100 then raise exception 'Invalid occurrence limit'; end if;
  if p_end_date < p_start_date or p_end_date > p_start_date + 366 then raise exception 'Invalid recurrence range'; end if;
  if p_weekdays is null or cardinality(p_weekdays) not between 1 and 7 or exists (select 1 from unnest(p_weekdays) d where d not between 1 and 7) then
    raise exception 'Invalid weekdays';
  end if;
  if not public.monolith_valid_timezone(p_timezone) then raise exception 'Invalid timezone'; end if;
  if nullif(btrim(p_client_request_id), '') is null then raise exception 'A request key is required'; end if;

  select id into v_series_id from public.appointment_series
  where trainer_id = v_trainer_id and client_request_id = p_client_request_id;
  if v_series_id is not null then return v_series_id; end if;

  insert into public.appointment_series (
    trainer_id, student_id, appointment_type, timezone, start_date, start_time,
    duration_minutes, weekdays, end_date, occurrence_limit, location, meeting_url,
    shared_notes, client_request_id, created_by
  ) values (
    v_trainer_id, p_student_id, v_type, p_timezone, p_start_date, p_start_time,
    p_duration_minutes, p_weekdays, p_end_date, p_occurrence_limit,
    nullif(btrim(p_location), ''), nullif(btrim(p_meeting_url), ''), nullif(btrim(p_shared_notes), ''),
    p_client_request_id, v_trainer_id
  ) returning id into v_series_id;

  for v_day in
    select candidate::date
    from generate_series(p_start_date, p_end_date, interval '1 day') candidate
    where extract(isodow from candidate)::smallint = any(p_weekdays)
    order by candidate
    limit p_occurrence_limit
  loop
    v_starts_at := (v_day + p_start_time) at time zone p_timezone;
    insert into public.appointments (
      series_id, trainer_id, student_id, appointment_type, starts_at, ends_at, timezone,
      location, meeting_url, shared_notes, status, client_request_id, created_by
    ) values (
      v_series_id, v_trainer_id, p_student_id, v_type, v_starts_at,
      v_starts_at + make_interval(mins => p_duration_minutes), p_timezone,
      nullif(btrim(p_location), ''), nullif(btrim(p_meeting_url), ''), nullif(btrim(p_shared_notes), ''),
      case when p_student_id is null then 'confirmed' else 'awaiting_confirmation' end,
      p_client_request_id || ':' || v_day::text, v_trainer_id
    ) returning id into v_appointment_id;
    if nullif(btrim(p_private_notes), '') is not null then
      insert into public.appointment_private_notes (appointment_id, trainer_id, note)
      values (v_appointment_id, v_trainer_id, btrim(p_private_notes));
    end if;
  end loop;
  return v_series_id;
end;
$$;

create or replace function public.update_monolith_appointment_scope(
  p_appointment_id uuid,
  p_scope text,
  p_start_date date,
  p_start_time time,
  p_duration_minutes integer,
  p_timezone text,
  p_appointment_type text,
  p_location text,
  p_meeting_url text,
  p_shared_notes text,
  p_private_notes text
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_trainer_id uuid := auth.uid();
  v_target public.appointments%rowtype;
  v_new_start timestamptz;
  v_delta interval;
  v_count integer := 0;
begin
  select * into v_target from public.appointments where id = p_appointment_id and trainer_id = v_trainer_id;
  if not found then raise exception 'Appointment not found'; end if;
  if p_scope not in ('this', 'future', 'all') then raise exception 'Invalid update scope'; end if;
  if p_duration_minutes is null or p_duration_minutes not between 5 and 1440 then raise exception 'Invalid duration'; end if;
  if not public.monolith_valid_timezone(p_timezone) then raise exception 'Invalid timezone'; end if;
  v_new_start := (p_start_date + p_start_time) at time zone p_timezone;
  v_delta := v_new_start - v_target.starts_at;

  update public.appointments a set
    starts_at = a.starts_at + v_delta,
    ends_at = a.starts_at + v_delta + make_interval(mins => p_duration_minutes),
    timezone = p_timezone,
    appointment_type = case when a.student_id is null then 'private_block' else p_appointment_type end,
    location = nullif(btrim(p_location), ''),
    meeting_url = nullif(btrim(p_meeting_url), ''),
    shared_notes = nullif(btrim(p_shared_notes), '')
  where a.trainer_id = v_trainer_id and (
    a.id = v_target.id
    or (v_target.series_id is not null and p_scope = 'future' and a.series_id = v_target.series_id and a.starts_at >= v_target.starts_at)
    or (v_target.series_id is not null and p_scope = 'all' and a.series_id = v_target.series_id)
  );
  get diagnostics v_count = row_count;

  insert into public.appointment_private_notes (appointment_id, trainer_id, note)
  select a.id, v_trainer_id, coalesce(p_private_notes, '')
  from public.appointments a
  where a.trainer_id = v_trainer_id and (
    a.id = v_target.id
    or (v_target.series_id is not null and p_scope = 'future' and a.series_id = v_target.series_id and a.starts_at >= v_new_start)
    or (v_target.series_id is not null and p_scope = 'all' and a.series_id = v_target.series_id)
  )
  on conflict (appointment_id) do update set note = excluded.note, updated_at = now();
  return v_count;
end;
$$;

create or replace function public.set_monolith_appointment_status(
  p_appointment_id uuid,
  p_status text,
  p_scope text default 'this'
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_target public.appointments%rowtype;
  v_count integer;
begin
  if p_status is null or p_status not in ('awaiting_confirmation', 'confirmed', 'completed', 'cancelled', 'no_show') then raise exception 'Invalid status'; end if;
  if p_scope is null or p_scope not in ('this', 'future', 'all') then raise exception 'Invalid scope'; end if;
  select * into v_target from public.appointments where id = p_appointment_id and trainer_id = auth.uid();
  if not found then raise exception 'Appointment not found'; end if;
  update public.appointments a set status = p_status
  where a.trainer_id = auth.uid() and (
    a.id = v_target.id
    or (v_target.series_id is not null and p_scope = 'future' and a.series_id = v_target.series_id and a.starts_at >= v_target.starts_at)
    or (v_target.series_id is not null and p_scope = 'all' and a.series_id = v_target.series_id)
  );
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

create or replace function public.confirm_monolith_appointment(p_appointment_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_id uuid;
begin
  update public.appointments
  set status = 'confirmed'
  where id = p_appointment_id
    and student_id = auth.uid()
    and status = 'awaiting_confirmation'
  returning id into v_id;
  if v_id is null then raise exception 'Appointment cannot be confirmed'; end if;
  return v_id;
end;
$$;

create or replace function public.request_monolith_appointment_reschedule(
  p_appointment_id uuid,
  p_reason text,
  p_proposed_slots jsonb,
  p_client_request_id text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_appointment public.appointments%rowtype;
  v_id uuid;
begin
  select * into v_appointment from public.appointments
  where id = p_appointment_id and student_id = auth.uid() and status in ('awaiting_confirmation', 'confirmed');
  if not found then raise exception 'Appointment cannot be rescheduled'; end if;
  if char_length(btrim(coalesce(p_reason, ''))) not between 2 and 1000 then raise exception 'A reason is required'; end if;
  if p_proposed_slots is null or jsonb_typeof(p_proposed_slots) <> 'array' or jsonb_array_length(p_proposed_slots) not between 1 and 3 then
    raise exception 'Provide between one and three proposed slots';
  end if;
  if nullif(btrim(p_client_request_id), '') is null then raise exception 'A request key is required'; end if;
  select id into v_id from public.appointment_reschedule_requests
  where student_id = auth.uid() and client_request_id = p_client_request_id;
  if v_id is not null then return v_id; end if;
  if exists (select 1 from public.appointment_reschedule_requests where appointment_id = p_appointment_id and status = 'pending') then
    raise exception 'A pending reschedule request already exists';
  end if;
  insert into public.appointment_reschedule_requests (
    appointment_id, trainer_id, student_id, reason, proposed_slots, client_request_id
  ) values (
    v_appointment.id, v_appointment.trainer_id, auth.uid(), btrim(p_reason), p_proposed_slots, p_client_request_id
  ) returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.resolve_monolith_reschedule_request(
  p_request_id uuid,
  p_action text,
  p_start_date date default null,
  p_start_time time default null,
  p_duration_minutes integer default null,
  p_timezone text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_request public.appointment_reschedule_requests%rowtype;
  v_old public.appointments%rowtype;
  v_new_id uuid;
  v_start timestamptz;
begin
  select * into v_request from public.appointment_reschedule_requests
  where id = p_request_id and trainer_id = auth.uid() and status = 'pending';
  if not found then raise exception 'Reschedule request not found'; end if;
  if p_action = 'reject' then
    update public.appointment_reschedule_requests
    set status = 'rejected', resolved_by = auth.uid(), resolved_at = now()
    where id = p_request_id;
    return null;
  end if;
  if p_action is distinct from 'accept' then raise exception 'Invalid action'; end if;
  select * into v_old from public.appointments where id = v_request.appointment_id and trainer_id = auth.uid();
  if not found then raise exception 'Appointment not found'; end if;
  if p_start_date is null or p_start_time is null or p_duration_minutes is null or p_duration_minutes not between 5 and 1440 then raise exception 'New schedule is required'; end if;
  if not public.monolith_valid_timezone(coalesce(p_timezone, v_old.timezone)) then raise exception 'Invalid timezone'; end if;
  v_start := (p_start_date + p_start_time) at time zone coalesce(p_timezone, v_old.timezone);
  update public.appointments set status = 'rescheduled' where id = v_old.id;
  insert into public.appointments (
    rescheduled_from_id, trainer_id, student_id, appointment_type, starts_at, ends_at,
    timezone, location, meeting_url, shared_notes, status, client_request_id, created_by
  ) values (
    v_old.id, v_old.trainer_id, v_old.student_id, v_old.appointment_type, v_start,
    v_start + make_interval(mins => p_duration_minutes), coalesce(p_timezone, v_old.timezone),
    v_old.location, v_old.meeting_url, v_old.shared_notes, 'awaiting_confirmation',
    'reschedule-request:' || v_request.id::text, auth.uid()
  ) returning id into v_new_id;
  insert into public.appointment_private_notes (appointment_id, trainer_id, note)
  select v_new_id, auth.uid(), note from public.appointment_private_notes where appointment_id = v_old.id
  on conflict (appointment_id) do nothing;
  update public.appointment_reschedule_requests
  set status = 'accepted', replacement_appointment_id = v_new_id, resolved_by = auth.uid(), resolved_at = now()
  where id = p_request_id;
  return v_new_id;
end;
$$;

create or replace function public.reschedule_monolith_appointment(
  p_appointment_id uuid,
  p_start_date date,
  p_start_time time,
  p_duration_minutes integer,
  p_timezone text,
  p_client_request_id text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old public.appointments%rowtype;
  v_new_id uuid;
  v_start timestamptz;
begin
  select * into v_old from public.appointments where id = p_appointment_id and trainer_id = auth.uid();
  if not found then raise exception 'Appointment not found'; end if;
  if p_duration_minutes is null or p_duration_minutes not between 5 and 1440 then raise exception 'Invalid duration'; end if;
  if not public.monolith_valid_timezone(p_timezone) then raise exception 'Invalid timezone'; end if;
  if nullif(btrim(p_client_request_id), '') is null then raise exception 'A request key is required'; end if;
  select id into v_new_id from public.appointments where trainer_id = auth.uid() and client_request_id = p_client_request_id;
  if v_new_id is not null then return v_new_id; end if;
  v_start := (p_start_date + p_start_time) at time zone p_timezone;
  update public.appointments set status = 'rescheduled' where id = v_old.id;
  insert into public.appointments (
    rescheduled_from_id, trainer_id, student_id, appointment_type, starts_at, ends_at,
    timezone, location, meeting_url, shared_notes, status, client_request_id, created_by
  ) values (
    v_old.id, v_old.trainer_id, v_old.student_id, v_old.appointment_type, v_start,
    v_start + make_interval(mins => p_duration_minutes), p_timezone,
    v_old.location, v_old.meeting_url, v_old.shared_notes,
    case when v_old.student_id is null then 'confirmed' else 'awaiting_confirmation' end,
    p_client_request_id, auth.uid()
  ) returning id into v_new_id;
  insert into public.appointment_private_notes (appointment_id, trainer_id, note)
  select v_new_id, auth.uid(), note from public.appointment_private_notes where appointment_id = v_old.id
  on conflict (appointment_id) do nothing;
  return v_new_id;
end;
$$;

revoke all on function public.create_monolith_appointment(uuid, text, date, time, integer, text, text, text, text, text, text) from public;
revoke all on function public.create_monolith_appointment_series(uuid, text, date, time, integer, text, smallint[], date, integer, text, text, text, text, text) from public;
revoke all on function public.update_monolith_appointment_scope(uuid, text, date, time, integer, text, text, text, text, text, text) from public;
revoke all on function public.set_monolith_appointment_status(uuid, text, text) from public;
revoke all on function public.confirm_monolith_appointment(uuid) from public;
revoke all on function public.request_monolith_appointment_reschedule(uuid, text, jsonb, text) from public;
revoke all on function public.resolve_monolith_reschedule_request(uuid, text, date, time, integer, text) from public;
revoke all on function public.reschedule_monolith_appointment(uuid, date, time, integer, text, text) from public;
revoke all on function public.monolith_active_trainer_student(uuid, uuid) from public;

grant execute on function public.create_monolith_appointment(uuid, text, date, time, integer, text, text, text, text, text, text) to authenticated;
grant execute on function public.create_monolith_appointment_series(uuid, text, date, time, integer, text, smallint[], date, integer, text, text, text, text, text) to authenticated;
grant execute on function public.update_monolith_appointment_scope(uuid, text, date, time, integer, text, text, text, text, text, text) to authenticated;
grant execute on function public.set_monolith_appointment_status(uuid, text, text) to authenticated;
grant execute on function public.confirm_monolith_appointment(uuid) to authenticated;
grant execute on function public.request_monolith_appointment_reschedule(uuid, text, jsonb, text) to authenticated;
grant execute on function public.resolve_monolith_reschedule_request(uuid, text, date, time, integer, text) to authenticated;
grant execute on function public.reschedule_monolith_appointment(uuid, date, time, integer, text, text) to authenticated;
grant execute on function public.monolith_active_trainer_student(uuid, uuid) to authenticated;

revoke all on public.appointment_series, public.appointments, public.appointment_private_notes, public.appointment_reschedule_requests, public.appointment_events from anon, authenticated;
grant select on public.appointment_series, public.appointments, public.appointment_reschedule_requests, public.appointment_events to authenticated;
grant select on public.appointment_private_notes to authenticated;

notify pgrst, 'reload schema';

select
  to_regclass('public.appointments') is not null as appointments_ready,
  to_regclass('public.appointment_series') is not null as appointment_series_ready,
  to_regclass('public.appointment_reschedule_requests') is not null as reschedule_requests_ready;
