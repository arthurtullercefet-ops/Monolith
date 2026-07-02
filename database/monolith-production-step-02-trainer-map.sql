-- Monolith production step 02
-- Adds the trainer public profile used by the future trainer map/search.
-- Run this after monolith-production-step-01.sql.

create table if not exists public.trainer_public_profiles (
  trainer_id uuid primary key references public.profiles(id) on delete cascade,
  service_types text[] not null default '{}',
  appear_on_map boolean not null default false,
  full_name text not null,
  professional_name text not null,
  social_url text not null,
  bio text not null,
  training_formats text[] not null default '{}',
  city text not null,
  state text not null,
  zip_code text not null,
  travel_availability text not null,
  travel_notes text,
  hourly_price numeric(10, 2) not null default 0 check (hourly_price >= 0),
  monthly_price numeric(10, 2) not null default 0 check (monthly_price >= 0),
  online_monthly_price numeric(10, 2) check (online_monthly_price is null or online_monthly_price >= 0),
  free_first_consultation boolean,
  package_discounts boolean,
  specialties text[] not null default '{}',
  target_clients text[] not null default '{}',
  certified_status text check (certified_status is null or certified_status in ('yes', 'no', 'in_progress')),
  certification_name text,
  years_experience integer check (years_experience is null or years_experience >= 0),
  liability_insurance text check (liability_insurance is null or liability_insurance in ('yes', 'no', 'prefer_not')),
  responsibility_accepted boolean not null default false,
  availability text[] not null default '{}',
  languages text[] not null default '{}',
  display_authorization text not null check (display_authorization in ('app_only', 'app_and_social', 'no')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint trainer_public_profiles_required_arrays check (
    array_length(service_types, 1) is not null
    and array_length(training_formats, 1) is not null
    and array_length(specialties, 1) is not null
    and array_length(target_clients, 1) is not null
    and array_length(languages, 1) is not null
  ),
  constraint trainer_public_profiles_map_visibility check (
    appear_on_map = false or display_authorization in ('app_only', 'app_and_social')
  ),
  constraint trainer_public_profiles_responsibility check (responsibility_accepted = true)
);

create index if not exists trainer_public_profiles_map_idx
on public.trainer_public_profiles (appear_on_map, city, state);

create index if not exists trainer_public_profiles_specialties_idx
on public.trainer_public_profiles using gin (specialties);

create index if not exists trainer_public_profiles_training_formats_idx
on public.trainer_public_profiles using gin (training_formats);

drop trigger if exists trainer_public_profiles_touch_updated_at on public.trainer_public_profiles;

create trigger trainer_public_profiles_touch_updated_at
before update on public.trainer_public_profiles
for each row execute function public.touch_updated_at();

alter table public.trainer_public_profiles enable row level security;

drop policy if exists "trainer_public_profiles_select_own_or_visible" on public.trainer_public_profiles;
create policy "trainer_public_profiles_select_own_or_visible"
on public.trainer_public_profiles for select
using (
  trainer_id = auth.uid()
  or (
    appear_on_map = true
    and display_authorization in ('app_only', 'app_and_social')
  )
);

drop policy if exists "trainer_public_profiles_insert_own_trainer" on public.trainer_public_profiles;
create policy "trainer_public_profiles_insert_own_trainer"
on public.trainer_public_profiles for insert
with check (
  trainer_id = auth.uid()
  and responsibility_accepted = true
  and exists (
    select 1
    from public.profiles p
    where p.id = auth.uid()
      and p.role in ('trainer_basic', 'trainer_plus', 'admin')
  )
);

drop policy if exists "trainer_public_profiles_update_own_trainer" on public.trainer_public_profiles;
create policy "trainer_public_profiles_update_own_trainer"
on public.trainer_public_profiles for update
using (trainer_id = auth.uid())
with check (
  trainer_id = auth.uid()
  and responsibility_accepted = true
  and exists (
    select 1
    from public.profiles p
    where p.id = auth.uid()
      and p.role in ('trainer_basic', 'trainer_plus', 'admin')
  )
);
