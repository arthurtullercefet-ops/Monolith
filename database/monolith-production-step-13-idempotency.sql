-- Monolith production step 13
-- Adds persistent idempotency to critical writes without deleting or rewriting user data.
-- Safe to run more than once after production step 12.

alter table public.daily_checkins
  add column if not exists client_request_id text;

alter table public.body_measurements
  add column if not exists client_request_id text;

alter table public.workout_templates
  add column if not exists client_request_id text;

alter table public.completed_workouts
  add column if not exists client_request_id text;

alter table public.diet_plans
  add column if not exists client_request_id text;

alter table public.food_logs
  add column if not exists client_request_id text;

alter table public.progress_photos
  add column if not exists client_request_id text;

alter table public.student_anamneses
  add column if not exists client_request_id text;

alter table public.trainer_invites
  add column if not exists client_request_id text;

create unique index if not exists daily_checkins_client_request_id_uidx
on public.daily_checkins (client_request_id);

create unique index if not exists body_measurements_client_request_id_uidx
on public.body_measurements (client_request_id);

create unique index if not exists workout_templates_client_request_id_uidx
on public.workout_templates (client_request_id);

create unique index if not exists completed_workouts_client_request_id_uidx
on public.completed_workouts (client_request_id);

create unique index if not exists diet_plans_client_request_id_uidx
on public.diet_plans (client_request_id);

create unique index if not exists food_logs_client_request_id_uidx
on public.food_logs (client_request_id);

create unique index if not exists progress_photos_client_request_id_uidx
on public.progress_photos (client_request_id);

create unique index if not exists student_anamneses_client_request_id_uidx
on public.student_anamneses (client_request_id);

create unique index if not exists trainer_invites_client_request_id_uidx
on public.trainer_invites (client_request_id);

create or replace function public.create_trainer_invite_idempotent(
  p_client_request_id text,
  p_expires_days integer default 30,
  p_max_uses integer default null
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  trainer_role public.monolith_role;
  existing_code text;
  new_code text;
begin
  if nullif(trim(p_client_request_id), '') is null then
    raise exception 'A client request id is required.';
  end if;

  select role into trainer_role
  from public.profiles
  where id = auth.uid();

  if trainer_role is null or trainer_role not in ('trainer_basic', 'trainer_plus', 'admin') then
    raise exception 'Only trainers can create invite codes.';
  end if;

  select code into existing_code
  from public.trainer_invites
  where trainer_id = auth.uid()
    and client_request_id = p_client_request_id
  limit 1;

  if existing_code is not null then
    return existing_code;
  end if;

  loop
    new_code := 'MONO-' || upper(substr(encode(gen_random_bytes(6), 'hex'), 1, 12));
    exit when not exists (
      select 1 from public.trainer_invites where upper(code) = upper(new_code)
    );
  end loop;

  begin
    insert into public.trainer_invites (
      trainer_id,
      code,
      max_uses,
      expires_at,
      client_request_id
    )
    values (
      auth.uid(),
      new_code,
      p_max_uses,
      case
        when p_expires_days is null then null
        else now() + make_interval(days => greatest(p_expires_days, 1))
      end,
      p_client_request_id
    );
  exception when unique_violation then
    select code into existing_code
    from public.trainer_invites
    where trainer_id = auth.uid()
      and client_request_id = p_client_request_id
    limit 1;

    if existing_code is null then
      raise;
    end if;
    return existing_code;
  end;

  return new_code;
end;
$$;

-- Retrying the same acceptance no longer consumes another use of the invite.
create or replace function public.accept_trainer_invite(invite_code text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  student_role public.monolith_role;
  invite_record public.trainer_invites%rowtype;
  relationship_active boolean := false;
begin
  select role into student_role
  from public.profiles
  where id = auth.uid();

  if student_role is distinct from 'student' then
    raise exception 'Only student accounts can accept trainer invite codes.';
  end if;

  select *
  into invite_record
  from public.trainer_invites
  where upper(code) = upper(trim(invite_code))
    and status = 'active'
    and (expires_at is null or expires_at > now())
  order by created_at desc
  limit 1
  for update;

  if invite_record.id is null then
    raise exception 'Invalid or expired trainer invite code.';
  end if;

  if invite_record.trainer_id = auth.uid() then
    raise exception 'Trainer and student must be different accounts.';
  end if;

  select exists (
    select 1
    from public.trainer_students ts
    where ts.trainer_id = invite_record.trainer_id
      and ts.student_id = auth.uid()
      and ts.status = 'active'
  ) into relationship_active;

  if relationship_active then
    return invite_record.trainer_id;
  end if;

  if invite_record.max_uses is not null
     and invite_record.uses_count >= invite_record.max_uses then
    raise exception 'Invalid or expired trainer invite code.';
  end if;

  update public.trainer_students
  set status = 'ended'
  where student_id = auth.uid()
    and trainer_id <> invite_record.trainer_id
    and status = 'active';

  insert into public.trainer_students (trainer_id, student_id, status)
  values (invite_record.trainer_id, auth.uid(), 'active')
  on conflict (trainer_id, student_id)
  do update set status = 'active';

  update public.trainer_invites
  set uses_count = uses_count + 1
  where id = invite_record.id;

  return invite_record.trainer_id;
end;
$$;

grant execute on function public.create_trainer_invite_idempotent(text, integer, integer) to authenticated;
grant execute on function public.accept_trainer_invite(text) to authenticated;
