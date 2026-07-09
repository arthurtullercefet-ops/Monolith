-- Monolith production step 06
-- Repairs trainer invite RPC/table/policies without deleting data.
-- Run after the base schema and production step 01.

create extension if not exists "pgcrypto";

create table if not exists public.trainer_invites (
  id uuid primary key default gen_random_uuid(),
  trainer_id uuid not null references public.profiles(id) on delete cascade,
  code text not null unique,
  status text not null default 'active' check (status in ('active', 'revoked', 'expired')),
  max_uses integer check (max_uses is null or max_uses > 0),
  uses_count integer not null default 0 check (uses_count >= 0),
  expires_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists trainer_invites_trainer_id_idx
on public.trainer_invites (trainer_id);

create index if not exists trainer_invites_code_idx
on public.trainer_invites (upper(code));

alter table public.trainer_invites enable row level security;

drop policy if exists "trainer_invites_select_own" on public.trainer_invites;
create policy "trainer_invites_select_own"
on public.trainer_invites for select
using (trainer_id = auth.uid());

drop policy if exists "trainer_invites_insert_own_trainer" on public.trainer_invites;
create policy "trainer_invites_insert_own_trainer"
on public.trainer_invites for insert
with check (
  trainer_id = auth.uid()
  and exists (
    select 1
    from public.profiles p
    where p.id = auth.uid()
      and p.role in ('trainer_basic', 'trainer_plus', 'admin')
  )
);

drop policy if exists "trainer_invites_update_own" on public.trainer_invites;
create policy "trainer_invites_update_own"
on public.trainer_invites for update
using (trainer_id = auth.uid())
with check (trainer_id = auth.uid());

drop policy if exists "trainer_invites_delete_own" on public.trainer_invites;
create policy "trainer_invites_delete_own"
on public.trainer_invites for delete
using (trainer_id = auth.uid());

create or replace function public.create_trainer_invite(
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
  new_code text;
begin
  select role into trainer_role
  from public.profiles
  where id = auth.uid();

  if trainer_role not in ('trainer_basic', 'trainer_plus', 'admin') then
    raise exception 'Only trainers can create invite codes.';
  end if;

  loop
    new_code := 'MONO-' || upper(substr(encode(gen_random_bytes(6), 'hex'), 1, 12));
    exit when not exists (
      select 1 from public.trainer_invites where upper(code) = upper(new_code)
    );
  end loop;

  insert into public.trainer_invites (trainer_id, code, max_uses, expires_at)
  values (
    auth.uid(),
    new_code,
    p_max_uses,
    case
      when p_expires_days is null then null
      else now() + make_interval(days => greatest(p_expires_days, 1))
    end
  );

  return new_code;
end;
$$;

create or replace function public.accept_trainer_invite(invite_code text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  student_role public.monolith_role;
  invite_record public.trainer_invites%rowtype;
begin
  select role into student_role
  from public.profiles
  where id = auth.uid();

  if student_role <> 'student' then
    raise exception 'Only student accounts can accept trainer invite codes.';
  end if;

  select *
  into invite_record
  from public.trainer_invites
  where upper(code) = upper(trim(invite_code))
    and status = 'active'
    and (expires_at is null or expires_at > now())
    and (max_uses is null or uses_count < max_uses)
  order by created_at desc
  limit 1;

  if invite_record.id is null then
    raise exception 'Invalid or expired trainer invite code.';
  end if;

  if invite_record.trainer_id = auth.uid() then
    raise exception 'Trainer and student must be different accounts.';
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

grant execute on function public.create_trainer_invite(integer, integer) to authenticated;
grant execute on function public.accept_trainer_invite(text) to authenticated;
