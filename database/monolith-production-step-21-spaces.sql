-- Monolith production step 21
-- Multi-tenant visual Spaces with Monolith always present.
-- Safe to run more than once after production step 20. No user data is deleted.

create table if not exists public.monolith_spaces (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles(id) on delete cascade,
  name text not null check (char_length(name) between 2 and 100),
  slug text not null unique check (slug ~ '^[a-z0-9][a-z0-9-]{1,62}$'),
  welcome_message text check (char_length(welcome_message) <= 500),
  logo_url text,
  cover_url text,
  primary_color text not null default '#d4af37' check (primary_color ~ '^#[0-9A-Fa-f]{6}$'),
  accent_color text not null default '#f5f5f5' check (accent_color ~ '^#[0-9A-Fa-f]{6}$'),
  domain text,
  social_links jsonb not null default '{}'::jsonb,
  units jsonb not null default '[]'::jsonb,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.space_memberships (
  id uuid primary key default gen_random_uuid(),
  space_id uuid not null references public.monolith_spaces(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  role text not null default 'member' check (role in ('owner','trainer','member')),
  created_at timestamptz not null default now(),
  unique (space_id, user_id)
);

create index if not exists space_memberships_user_idx on public.space_memberships (user_id, created_at desc);
create unique index if not exists monolith_spaces_owner_unique_idx on public.monolith_spaces (owner_id);

alter table public.monolith_spaces enable row level security;
alter table public.space_memberships enable row level security;

create or replace function public.is_space_member(target_space uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.space_memberships sm
    where sm.space_id = target_space and sm.user_id = auth.uid()
  );
$$;

revoke all on function public.is_space_member(uuid) from public;
revoke all on function public.is_space_member(uuid) from anon;

drop policy if exists "spaces_member_read" on public.monolith_spaces;
drop policy if exists "spaces_owner_write" on public.monolith_spaces;
drop policy if exists "memberships_same_space_read" on public.space_memberships;
drop policy if exists "memberships_owner_write" on public.space_memberships;

create policy "spaces_member_read" on public.monolith_spaces for select
using (active and public.is_space_member(id));
create policy "spaces_owner_write" on public.monolith_spaces for all
using (owner_id = auth.uid()) with check (owner_id = auth.uid());

create policy "memberships_same_space_read" on public.space_memberships for select
using (public.is_space_member(space_id));
create policy "memberships_owner_write" on public.space_memberships for all
using (exists (select 1 from public.monolith_spaces s where s.id = space_memberships.space_id and s.owner_id = auth.uid()))
with check (exists (select 1 from public.monolith_spaces s where s.id = space_memberships.space_id and s.owner_id = auth.uid()));

grant select, insert, update, delete on public.monolith_spaces to authenticated;
grant select, insert, update, delete on public.space_memberships to authenticated;
grant execute on function public.is_space_member(uuid) to authenticated;
