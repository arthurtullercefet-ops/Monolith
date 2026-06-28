-- Monolith production step 01
-- Run after monolith-supabase-schema.sql.
-- Adds production-safe profile creation, trainer invite codes, plans/subscriptions
-- and influencer/referral tracking.

create extension if not exists "pgcrypto";

-- 1) Create/update a profile automatically when Supabase Auth creates a user.
create or replace function public.handle_new_monolith_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  requested_role text;
  safe_role public.monolith_role;
  display_name text;
begin
  requested_role := coalesce(new.raw_user_meta_data ->> 'role', 'student');

  if requested_role = 'personal' then
    requested_role := 'trainer_basic';
  end if;

  if requested_role not in ('student', 'influencer', 'trainer_basic', 'trainer_plus', 'admin') then
    requested_role := 'student';
  end if;

  safe_role := requested_role::public.monolith_role;
  display_name := coalesce(
    nullif(new.raw_user_meta_data ->> 'full_name', ''),
    nullif(split_part(coalesce(new.email, ''), '@', 1), ''),
    'Monolith User'
  );

  insert into public.profiles (id, email, full_name, role)
  values (new.id, coalesce(new.email, ''), display_name, safe_role)
  on conflict (id) do update
  set
    email = excluded.email,
    full_name = coalesce(nullif(public.profiles.full_name, ''), excluded.full_name),
    updated_at = now();

  return new;
end;
$$;

drop trigger if exists on_auth_user_created_monolith on auth.users;

create trigger on_auth_user_created_monolith
after insert on auth.users
for each row execute function public.handle_new_monolith_user();

-- 2) Trainer invite codes. Students accept these codes through an RPC,
-- so students do not need direct table read access to every invite.
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

drop trigger if exists trainer_invites_touch_updated_at on public.trainer_invites;

create trigger trainer_invites_touch_updated_at
before update on public.trainer_invites
for each row execute function public.touch_updated_at();

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
  invite_record public.trainer_invites%rowtype;
  student_role public.monolith_role;
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
  for update;

  if not found then
    raise exception 'Invalid or expired trainer invite code.';
  end if;

  if invite_record.trainer_id = auth.uid() then
    raise exception 'Student and trainer cannot be the same account.';
  end if;

  update public.trainer_students
  set status = 'ended'
  where student_id = auth.uid()
    and trainer_id <> invite_record.trainer_id
    and status = 'active';

  insert into public.trainer_students (trainer_id, student_id, status)
  values (invite_record.trainer_id, auth.uid(), 'active')
  on conflict (trainer_id, student_id) do update
  set status = 'active';

  update public.trainer_invites
  set uses_count = uses_count + 1
  where id = invite_record.id;

  return invite_record.trainer_id;
end;
$$;

grant execute on function public.create_trainer_invite(integer, integer) to authenticated;
grant execute on function public.accept_trainer_invite(text) to authenticated;

-- 3) Product/plan structure. Payments can connect to these records later.
create table if not exists public.app_plans (
  key text primary key,
  name text not null,
  role public.monolith_role not null,
  monthly_price_cents integer not null default 0 check (monthly_price_cents >= 0),
  currency text not null default 'USD',
  is_public boolean not null default true,
  features jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

drop trigger if exists app_plans_touch_updated_at on public.app_plans;

create trigger app_plans_touch_updated_at
before update on public.app_plans
for each row execute function public.touch_updated_at();

alter table public.app_plans enable row level security;

drop policy if exists "app_plans_select_public" on public.app_plans;
create policy "app_plans_select_public"
on public.app_plans for select
using (is_public = true);

insert into public.app_plans (key, name, role, monthly_price_cents, currency, features)
values
  ('student_monthly', 'Aluno', 'student', 399, 'USD', '["checkins", "workouts", "measurements", "photos", "monthly_report"]'::jsonb),
  ('influencer_free', 'Influencer', 'influencer', 0, 'USD', '["public_profile", "audience", "challenges"]'::jsonb),
  ('trainer_basic', 'Personal Trainer Basic', 'trainer_basic', 0, 'USD', '["students", "workouts", "diets", "monthly_reports"]'::jsonb),
  ('trainer_plus', 'Personal Trainer Plus', 'trainer_plus', 0, 'USD', '["students", "workouts", "diets", "monthly_reports", "products", "automations"]'::jsonb)
on conflict (key) do update
set
  name = excluded.name,
  role = excluded.role,
  monthly_price_cents = excluded.monthly_price_cents,
  currency = excluded.currency,
  features = excluded.features,
  updated_at = now();

create table if not exists public.subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  plan_key text not null references public.app_plans(key),
  status text not null default 'trialing' check (status in ('trialing', 'active', 'past_due', 'paused', 'canceled')),
  provider text,
  provider_customer_id text,
  provider_subscription_id text,
  current_period_start timestamptz,
  current_period_end timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, plan_key)
);

create index if not exists subscriptions_user_id_idx
on public.subscriptions (user_id);

drop trigger if exists subscriptions_touch_updated_at on public.subscriptions;

create trigger subscriptions_touch_updated_at
before update on public.subscriptions
for each row execute function public.touch_updated_at();

alter table public.subscriptions enable row level security;

drop policy if exists "subscriptions_select_self" on public.subscriptions;
create policy "subscriptions_select_self"
on public.subscriptions for select
using (user_id = auth.uid());

drop policy if exists "subscriptions_insert_self" on public.subscriptions;
create policy "subscriptions_insert_self"
on public.subscriptions for insert
with check (user_id = auth.uid());

drop policy if exists "subscriptions_update_self" on public.subscriptions;
create policy "subscriptions_update_self"
on public.subscriptions for update
using (user_id = auth.uid())
with check (user_id = auth.uid());

-- 4) Influencer/referral structure. This can later feed attribution and commissions.
create table if not exists public.influencer_codes (
  id uuid primary key default gen_random_uuid(),
  influencer_id uuid not null references public.profiles(id) on delete cascade,
  code text not null unique,
  status text not null default 'active' check (status in ('active', 'paused', 'revoked')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists influencer_codes_influencer_id_idx
on public.influencer_codes (influencer_id);

drop trigger if exists influencer_codes_touch_updated_at on public.influencer_codes;

create trigger influencer_codes_touch_updated_at
before update on public.influencer_codes
for each row execute function public.touch_updated_at();

alter table public.influencer_codes enable row level security;

drop policy if exists "influencer_codes_select_own" on public.influencer_codes;
create policy "influencer_codes_select_own"
on public.influencer_codes for select
using (influencer_id = auth.uid());

drop policy if exists "influencer_codes_write_own_influencer" on public.influencer_codes;
create policy "influencer_codes_write_own_influencer"
on public.influencer_codes for all
using (influencer_id = auth.uid())
with check (
  influencer_id = auth.uid()
  and exists (
    select 1
    from public.profiles p
    where p.id = auth.uid()
      and p.role in ('influencer', 'admin')
  )
);

create table if not exists public.referral_attributions (
  id uuid primary key default gen_random_uuid(),
  referred_user_id uuid not null references public.profiles(id) on delete cascade,
  influencer_code_id uuid references public.influencer_codes(id) on delete set null,
  raw_code text,
  created_at timestamptz not null default now(),
  unique (referred_user_id)
);

alter table public.referral_attributions enable row level security;

drop policy if exists "referral_attributions_select_self_or_influencer" on public.referral_attributions;
create policy "referral_attributions_select_self_or_influencer"
on public.referral_attributions for select
using (
  referred_user_id = auth.uid()
  or exists (
    select 1
    from public.influencer_codes ic
    where ic.id = referral_attributions.influencer_code_id
      and ic.influencer_id = auth.uid()
  )
);

drop policy if exists "referral_attributions_insert_self" on public.referral_attributions;
create policy "referral_attributions_insert_self"
on public.referral_attributions for insert
with check (referred_user_id = auth.uid());

create or replace function public.accept_influencer_code(raw_code text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  code_record public.influencer_codes%rowtype;
begin
  select *
  into code_record
  from public.influencer_codes
  where upper(code) = upper(trim(raw_code))
    and status = 'active'
  limit 1;

  insert into public.referral_attributions (referred_user_id, influencer_code_id, raw_code)
  values (auth.uid(), code_record.id, trim(raw_code))
  on conflict (referred_user_id) do update
  set
    influencer_code_id = excluded.influencer_code_id,
    raw_code = excluded.raw_code;

  return code_record.id;
end;
$$;

grant execute on function public.accept_influencer_code(text) to authenticated;
