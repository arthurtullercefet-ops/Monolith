-- Monolith production step 20
-- Configurable onboarding, Instagram lead funnel and transparent achievements.
-- Safe to run more than once after production step 19. No user data is deleted.

create table if not exists public.onboarding_configs (
  trainer_id uuid primary key references public.profiles(id) on delete cascade,
  required_steps text[] not null default array['welcome','terms','anamnesis','goals','measurements','checkin','workout'],
  welcome_message text check (char_length(welcome_message) <= 500),
  updated_at timestamptz not null default now()
);

create table if not exists public.onboarding_progress (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.profiles(id) on delete cascade,
  trainer_id uuid references public.profiles(id) on delete set null,
  completed_steps text[] not null default '{}',
  status text not null default 'active' check (status in ('active','completed')),
  started_at timestamptz not null default now(),
  completed_at timestamptz,
  updated_at timestamptz not null default now(),
  unique (student_id, trainer_id)
);

create table if not exists public.trainer_leads (
  id uuid primary key default gen_random_uuid(),
  trainer_id uuid not null references public.profiles(id) on delete cascade,
  interested_user_id uuid references public.profiles(id) on delete set null,
  name text not null check (char_length(name) between 2 and 120),
  goal text not null check (char_length(goal) between 2 and 240),
  modality text not null check (modality in ('online','in_person','hybrid')),
  city text check (char_length(city) <= 120),
  availability text check (char_length(availability) <= 240),
  instagram text check (char_length(instagram) <= 160),
  notes text check (char_length(notes) <= 500),
  private_notes text check (char_length(private_notes) <= 1000),
  status text not null default 'new' check (status in ('new','contact_started','waiting','assessment_scheduled','converted','not_converted','expired')),
  converted_invite_code text,
  client_request_id uuid not null unique,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.trainer_lead_events (
  id uuid primary key default gen_random_uuid(),
  trainer_id uuid not null references public.profiles(id) on delete cascade,
  lead_id uuid references public.trainer_leads(id) on delete cascade,
  actor_id uuid references public.profiles(id) on delete set null,
  event_type text not null check (event_type in ('profile_view','request_click','form_completed','instagram_opened','status_changed','converted')),
  created_at timestamptz not null default now()
);

create table if not exists public.student_achievements (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.profiles(id) on delete cascade,
  trainer_id uuid references public.profiles(id) on delete set null,
  achievement_key text not null check (char_length(achievement_key) between 2 and 80),
  earned_at timestamptz not null default now(),
  details jsonb not null default '{}'::jsonb,
  unique (student_id, achievement_key)
);

create index if not exists onboarding_progress_trainer_idx on public.onboarding_progress (trainer_id, status, updated_at desc);
create unique index if not exists onboarding_progress_unlinked_student_unique_idx
on public.onboarding_progress (student_id) where trainer_id is null;
create index if not exists trainer_leads_trainer_status_idx on public.trainer_leads (trainer_id, status, created_at desc);
create index if not exists trainer_lead_events_trainer_idx on public.trainer_lead_events (trainer_id, created_at desc);
create index if not exists student_achievements_student_idx on public.student_achievements (student_id, earned_at desc);

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'onboarding_configs_steps_allowed' and conrelid = 'public.onboarding_configs'::regclass) then
    alter table public.onboarding_configs add constraint onboarding_configs_steps_allowed
      check (required_steps <@ array['welcome','terms','anamnesis','goals','measurements','photos','schedule','checkin','workout','diet']::text[]);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'onboarding_progress_steps_allowed' and conrelid = 'public.onboarding_progress'::regclass) then
    alter table public.onboarding_progress add constraint onboarding_progress_steps_allowed
      check (completed_steps <@ array['welcome','terms','anamnesis','goals','measurements','photos','schedule','checkin','workout','diet']::text[]);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'student_achievements_key_allowed' and conrelid = 'public.student_achievements'::regclass) then
    alter table public.student_achievements add constraint student_achievements_key_allowed
      check (achievement_key in ('first_monument','foundation','discipline','structure','consistency','return'));
  end if;
end $$;

create or replace function public.monolith_guard_lead_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or new.interested_user_id is distinct from auth.uid() then
    raise exception 'Lead creation is not allowed';
  end if;
  new.status = 'new';
  new.private_notes = null;
  new.converted_invite_code = null;
  new.created_at = now();
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trainer_leads_guard_insert on public.trainer_leads;
create trigger trainer_leads_guard_insert before insert on public.trainer_leads
for each row execute function public.monolith_guard_lead_insert();

create or replace function public.monolith_guard_lead_update()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() = old.interested_user_id then
    new := old;
  elsif auth.uid() = old.trainer_id then
    new.id = old.id;
    new.trainer_id = old.trainer_id;
    new.interested_user_id = old.interested_user_id;
    new.name = old.name;
    new.goal = old.goal;
    new.modality = old.modality;
    new.city = old.city;
    new.availability = old.availability;
    new.instagram = old.instagram;
    new.notes = old.notes;
    new.client_request_id = old.client_request_id;
    new.created_at = old.created_at;
    new.updated_at = now();
  else
    raise exception 'Lead update is not allowed';
  end if;
  return new;
end;
$$;

drop trigger if exists trainer_leads_guard_update on public.trainer_leads;
create trigger trainer_leads_guard_update before update on public.trainer_leads
for each row execute function public.monolith_guard_lead_update();

create or replace function public.monolith_keep_achievement_immutable()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  return old;
end;
$$;

drop trigger if exists student_achievements_keep_immutable on public.student_achievements;
create trigger student_achievements_keep_immutable before update on public.student_achievements
for each row execute function public.monolith_keep_achievement_immutable();

revoke all on function public.monolith_guard_lead_insert() from public;
revoke all on function public.monolith_guard_lead_update() from public;
revoke all on function public.monolith_keep_achievement_immutable() from public;

alter table public.onboarding_configs enable row level security;
alter table public.onboarding_progress enable row level security;
alter table public.trainer_leads enable row level security;
alter table public.trainer_lead_events enable row level security;
alter table public.student_achievements enable row level security;

drop policy if exists "onboarding_config_owner" on public.onboarding_configs;
drop policy if exists "onboarding_config_linked_read" on public.onboarding_configs;
drop policy if exists "onboarding_progress_private" on public.onboarding_progress;
drop policy if exists "onboarding_progress_student_insert" on public.onboarding_progress;
drop policy if exists "onboarding_progress_student_update" on public.onboarding_progress;
drop policy if exists "leads_interested_insert" on public.trainer_leads;
drop policy if exists "leads_private_read" on public.trainer_leads;
drop policy if exists "leads_trainer_update" on public.trainer_leads;
drop policy if exists "leads_interested_idempotent_update" on public.trainer_leads;
drop policy if exists "lead_events_private" on public.trainer_lead_events;
drop policy if exists "lead_events_insert" on public.trainer_lead_events;
drop policy if exists "achievements_private_read" on public.student_achievements;
drop policy if exists "achievements_linked_insert" on public.student_achievements;
drop policy if exists "achievements_idempotent_update" on public.student_achievements;

create policy "onboarding_config_owner" on public.onboarding_configs for all
using (trainer_id = auth.uid()) with check (trainer_id = auth.uid());
create policy "onboarding_config_linked_read" on public.onboarding_configs for select
using (exists (select 1 from public.trainer_students ts where ts.student_id = auth.uid() and ts.trainer_id = onboarding_configs.trainer_id and ts.status = 'active'));

create policy "onboarding_progress_private" on public.onboarding_progress for select
using (student_id = auth.uid() or (trainer_id = auth.uid() and public.is_trainer_for(student_id)));
create policy "onboarding_progress_student_insert" on public.onboarding_progress for insert
with check (student_id = auth.uid() and (trainer_id is null or exists (select 1 from public.trainer_students ts where ts.student_id = auth.uid() and ts.trainer_id = onboarding_progress.trainer_id and ts.status = 'active')));
create policy "onboarding_progress_student_update" on public.onboarding_progress for update
using (student_id = auth.uid()) with check (student_id = auth.uid());

create policy "leads_interested_insert" on public.trainer_leads for insert
with check (
  interested_user_id = auth.uid()
  and exists (
    select 1 from public.profiles p
    where p.id = trainer_leads.trainer_id and p.role in ('trainer_basic', 'trainer_plus')
  )
);
create policy "leads_private_read" on public.trainer_leads for select
using (trainer_id = auth.uid() or interested_user_id = auth.uid());
create policy "leads_trainer_update" on public.trainer_leads for update
using (trainer_id = auth.uid()) with check (trainer_id = auth.uid());
create policy "leads_interested_idempotent_update" on public.trainer_leads for update
using (interested_user_id = auth.uid()) with check (interested_user_id = auth.uid());

create policy "lead_events_private" on public.trainer_lead_events for select
using (trainer_id = auth.uid() or actor_id = auth.uid());
create policy "lead_events_insert" on public.trainer_lead_events for insert
with check (
  actor_id = auth.uid()
  and (
    (
      lead_id is null
      and event_type in ('profile_view','request_click','instagram_opened')
      and exists (
        select 1 from public.trainer_public_profiles tp
        where tp.trainer_id = trainer_lead_events.trainer_id and tp.appear_on_map = true
      )
    )
    or exists (
      select 1 from public.trainer_leads lead
      where lead.id = trainer_lead_events.lead_id
        and lead.trainer_id = trainer_lead_events.trainer_id
        and (
          (lead.interested_user_id = auth.uid() and trainer_lead_events.event_type in ('form_completed','instagram_opened'))
          or (lead.trainer_id = auth.uid() and trainer_lead_events.event_type in ('instagram_opened','status_changed','converted'))
        )
    )
  )
);

create policy "achievements_private_read" on public.student_achievements for select
using (student_id = auth.uid() or (trainer_id = auth.uid() and public.is_trainer_for(student_id)));
create policy "achievements_linked_insert" on public.student_achievements for insert
with check (student_id = auth.uid() or (trainer_id = auth.uid() and public.is_trainer_for(student_id)));
create policy "achievements_idempotent_update" on public.student_achievements for update
using (student_id = auth.uid() or (trainer_id = auth.uid() and public.is_trainer_for(student_id)))
with check (student_id = auth.uid() or (trainer_id = auth.uid() and public.is_trainer_for(student_id)));

grant select, insert, update on public.onboarding_configs to authenticated;
grant select, insert, update on public.onboarding_progress to authenticated;
grant select, insert, update on public.trainer_leads to authenticated;
grant select, insert on public.trainer_lead_events to authenticated;
grant select, insert, update on public.student_achievements to authenticated;
