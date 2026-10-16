-- Step 35: managed students reuse profiles.id and trainer_students.
-- No Auth users, messages, sessions or demo rows are created.
begin;

create schema if not exists monolith_private;
revoke all on schema monolith_private from public;
grant usage on schema monolith_private to authenticated, anon;

alter table public.profiles
  add column auth_user_id uuid references auth.users(id) on delete cascade,
  add column access_mode text not null default 'authenticated',
  add column managed_by uuid references public.profiles(id) on delete restrict,
  add column managed_space_id uuid references public.monolith_spaces(id) on delete restrict,
  add column contact_phone text,
  add column birth_date date,
  add column trainer_notes text,
  add column managed_request_id uuid;

-- Preserve the original Auth identity and cascade for every existing profile.
-- This only fills the new identity column; no existing values/roles/IDs change.
alter table public.profiles disable trigger profiles_touch_updated_at;
update public.profiles set auth_user_id = id;
alter table public.profiles enable trigger profiles_touch_updated_at;
alter table public.profiles drop constraint profiles_id_fkey;
alter table public.profiles alter column email drop not null;
alter table public.profiles add constraint profiles_access_identity_check check (
  (access_mode = 'authenticated' and auth_user_id = id and auth_user_id is not null
    and managed_by is null and managed_space_id is null and managed_request_id is null)
  or (access_mode = 'managed' and auth_user_id is null and role = 'student'
    and managed_by is not null and managed_by <> id and managed_request_id is not null
    and space_enabled = false)
);
create unique index profiles_managed_request_idx on public.profiles(managed_by, managed_request_id)
  where access_mode = 'managed';
create index profiles_managed_space_idx on public.profiles(managed_space_id) where managed_space_id is not null;
comment on column public.profiles.access_mode is
  'authenticated: id equals auth_user_id. managed: no Auth identity; owner-only clinical/contact record. Conversion is unsupported.';

create function monolith_private.guard_profile_identity() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    if new.access_mode = 'authenticated' then new.auth_user_id := new.id;
    elsif current_user not in ('postgres', 'service_role') then
      raise exception 'MANAGED_USE_CREATE_RPC' using errcode = '42501';
    end if;
  else
    if (new.id, new.access_mode, new.auth_user_id, new.managed_by, new.managed_space_id, new.managed_request_id)
       is distinct from
       (old.id, old.access_mode, old.auth_user_id, old.managed_by, old.managed_space_id, old.managed_request_id) then
      raise exception 'Profile identity and managed ownership are immutable' using errcode = '42501';
    end if;
  end if;
  if new.access_mode = 'managed' then
    if new.role <> 'student' or new.space_enabled or nullif(btrim(new.full_name), '') is null
       or length(new.full_name) > 200 or length(new.email) > 254
       or (nullif(new.email, '') is not null and new.email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$')
       or length(new.contact_phone) > 40 or length(new.trainer_notes) > 10000
       or new.birth_date > current_date or new.birth_date < date '1900-01-01' then
      raise exception 'MANAGED_INVALID_CONTACT' using errcode = '22023';
    end if;
  end if;
  return new;
end $$;
create trigger profiles_guard_managed_identity before insert or update on public.profiles
  for each row execute function monolith_private.guard_profile_identity();

-- Private helpers avoid recursive profile policies and are not exposed as REST RPCs.
create function monolith_private.managed_scope(target uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select not exists (select 1 from public.profiles where id = target and access_mode = 'managed')
    or exists (select 1 from public.profiles p where p.id = target and p.access_mode = 'managed'
      and auth.uid() is not null and (p.managed_by = auth.uid()
        or exists (select 1 from public.profiles a where a.id = auth.uid() and a.role = 'admin' and a.access_mode = 'authenticated')));
$$;
create function monolith_private.owns_managed(target uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select auth.uid() is not null and exists (select 1 from public.profiles p
    where p.id = target and p.access_mode = 'managed' and p.managed_by = auth.uid());
$$;
create function monolith_private.authenticated_identity(target uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.profiles where id = target and access_mode = 'authenticated');
$$;

create policy profiles_managed_scope on public.profiles as restrictive for all
  using (monolith_private.managed_scope(id)) with check (monolith_private.managed_scope(id));
create policy profiles_managed_owner_read on public.profiles for select to authenticated
  using (monolith_private.owns_managed(id));
create policy profiles_managed_owner_update on public.profiles for update to authenticated
  using (monolith_private.owns_managed(id)) with check (monolith_private.owns_managed(id));

-- Existing data policies still determine allowed operations. This additional AND
-- gate prevents any permissive Space/link policy from leaking managed students.
do $$ declare r record; begin
  for r in select table_name, column_name from information_schema.columns
    where table_schema = 'public' and column_name in ('student_id','assigned_student_id')
      and exists (select 1 from information_schema.tables t where t.table_schema = 'public'
        and t.table_name = columns.table_name and t.table_type = 'BASE TABLE')
  loop
    execute format('create policy managed_owner_scope on public.%I as restrictive for all using (monolith_private.managed_scope(%I)) with check (monolith_private.managed_scope(%I))', r.table_name, r.column_name, r.column_name);
  end loop;
end $$;
-- This existing reporting view reads student data and must honor the new gates.
alter view public.monolith_possible_duplicate_report set (security_invoker = true);
create policy memberships_no_managed_identity on public.space_memberships as restrictive for all
  using (monolith_private.authenticated_identity(user_id))
  with check (monolith_private.authenticated_identity(user_id));

create function monolith_private.guard_student_capacity() returns trigger
language plpgsql security definer set search_path = '' as $$
declare owner_id uuid; owner_role public.monolith_role; begin
  select managed_by into owner_id from public.profiles where id = new.student_id and access_mode = 'managed';
  if owner_id is not null and owner_id <> new.trainer_id then
    raise exception 'Managed students cannot be shared or transferred' using errcode = '42501';
  end if;
  if new.status <> 'active' then return new; end if;
  if tg_op = 'UPDATE' then
    if old.status = 'active' then return new; end if;
  end if;
  -- Same lock for managed creation, invitations and relationship activation.
  select role into owner_role from public.profiles where id = new.trainer_id for update;
  if owner_role not in ('trainer_basic','trainer_plus','admin') or owner_role is null then
    raise exception 'Only trainers can own students' using errcode = '42501';
  end if;
  -- An INSERT ... ON CONFLICT retry of an already active link is not a new seat.
  if exists (select 1 from public.trainer_students where trainer_id = new.trainer_id
      and student_id = new.student_id and status = 'active') then return new; end if;
  if (select count(distinct student_id) from public.trainer_students
      where trainer_id = new.trainer_id and status = 'active') >= 15 then
    raise exception 'MONOLITH_STUDENT_LIMIT' using errcode = 'P0001';
  end if;
  return new;
end $$;
create trigger trainer_students_guard_capacity before insert or update on public.trainer_students
  for each row execute function monolith_private.guard_student_capacity();

create function monolith_private.create_managed_student(
  p_full_name text, p_email text, p_phone text, p_birth_date date,
  p_notes text, p_space_id uuid, p_request_id uuid
) returns uuid language plpgsql security definer set search_path = '' as $$
declare trainer uuid := auth.uid(); trainer_role public.monolith_role; student uuid; begin
  if trainer is null then raise exception 'Authentication required' using errcode = '42501'; end if;
  select role into trainer_role from public.profiles
    where id = trainer and access_mode = 'authenticated' for update;
  if trainer_role is null or trainer_role not in ('trainer_basic','trainer_plus','admin') then
    raise exception 'Only trainers can create managed students' using errcode = '42501';
  end if;
  if p_request_id is null or nullif(btrim(p_full_name), '') is null then
    raise exception 'MANAGED_INVALID_CONTACT' using errcode = '22023';
  end if;
  select id into student from public.profiles where managed_by = trainer and managed_request_id = p_request_id;
  if student is not null then return student; end if;
  if p_space_id is not null and not exists (select 1 from public.monolith_spaces
      where id = p_space_id and owner_id = trainer and active and public.monolith_space_enabled(trainer)) then
    raise exception 'Invalid managed Space owner' using errcode = '42501';
  end if;
  student := gen_random_uuid();
  insert into public.profiles(id, auth_user_id, access_mode, managed_by, managed_space_id,
      managed_request_id, full_name, email, contact_phone, birth_date, trainer_notes, role)
    values (student, null, 'managed', trainer, p_space_id, p_request_id, btrim(p_full_name),
      nullif(btrim(p_email), ''), nullif(btrim(p_phone), ''), p_birth_date, nullif(btrim(p_notes), ''), 'student');
  insert into public.trainer_students(trainer_id, student_id, status) values (trainer, student, 'active');
  return student;
end $$;

-- Public entry point is an invoker wrapper. The privileged implementation is private.
create function public.create_managed_student(
  p_full_name text, p_email text, p_phone text, p_birth_date date,
  p_notes text, p_space_id uuid, p_request_id uuid
) returns uuid language sql security invoker set search_path = '' as $$
  select monolith_private.create_managed_student(p_full_name,p_email,p_phone,p_birth_date,p_notes,p_space_id,p_request_id);
$$;
revoke all on all functions in schema monolith_private from public, anon, authenticated;
grant execute on function monolith_private.managed_scope(uuid) to anon, authenticated;
grant execute on function monolith_private.owns_managed(uuid) to anon, authenticated;
grant execute on function monolith_private.authenticated_identity(uuid) to anon, authenticated;
grant execute on function monolith_private.create_managed_student(text,text,text,date,text,uuid,uuid) to authenticated;
revoke all on function public.create_managed_student(text,text,text,date,text,uuid,uuid) from public, anon;
grant execute on function public.create_managed_student(text,text,text,date,text,uuid,uuid) to authenticated;
notify pgrst, 'reload schema';
commit;
