-- Monolith production step 28
-- Alertas, Leads deprecation and private Space assets.
-- Safe to run more than once after production step 27. No user data is deleted.

begin;

alter table public.monolith_spaces
  add column if not exists logo_storage_path text,
  add column if not exists cover_storage_path text;

alter table public.monolith_spaces
  drop constraint if exists monolith_spaces_slug_reserved_check;

alter table public.monolith_spaces
  add constraint monolith_spaces_slug_reserved_check
  check (slug not in ('admin', 'login', 'signup', 'monolith', 'support', 'api', 'space', 'profile'));

create or replace function public.monolith_space_slug_available(p_slug text, p_owner_id uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select not exists (
    select 1
    from public.monolith_spaces s
    where s.slug = lower(trim(p_slug))
      and s.owner_id is distinct from coalesce(p_owner_id, auth.uid())
  );
$$;

create or replace function public.monolith_guard_space_asset_paths()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.logo_storage_path is not null
     and new.logo_storage_path !~ ('^' || new.owner_id::text || '/logo/[^/]+$') then
    raise exception 'Invalid logo storage path';
  end if;

  if new.cover_storage_path is not null
     and new.cover_storage_path !~ ('^' || new.owner_id::text || '/cover/[^/]+$') then
    raise exception 'Invalid cover storage path';
  end if;

  return new;
end;
$$;

drop trigger if exists monolith_spaces_guard_asset_paths on public.monolith_spaces;
create trigger monolith_spaces_guard_asset_paths
before insert or update of owner_id, logo_storage_path, cover_storage_path on public.monolith_spaces
for each row execute function public.monolith_guard_space_asset_paths();

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'space-assets',
  'space-assets',
  false,
  5242880,
  array['image/png', 'image/jpeg', 'image/webp']
)
on conflict (id) do update set
  public = false,
  file_size_limit = 5242880,
  allowed_mime_types = array['image/png', 'image/jpeg', 'image/webp'];

drop policy if exists "space_assets_select_member" on storage.objects;
drop policy if exists "space_assets_insert_owner" on storage.objects;
drop policy if exists "space_assets_update_owner" on storage.objects;
drop policy if exists "space_assets_delete_owner" on storage.objects;

create policy "space_assets_select_member"
on storage.objects for select
using (
  bucket_id = 'space-assets'
  and (
    auth.uid()::text = (storage.foldername(name))[1]
    or exists (
      select 1
      from public.monolith_spaces s
      join public.space_memberships sm on sm.space_id = s.id
      where s.owner_id::text = (storage.foldername(storage.objects.name))[1]
        and sm.user_id = auth.uid()
        and s.active = true
    )
    or public.monolith_current_role() = 'admin'
  )
);

create policy "space_assets_insert_owner"
on storage.objects for insert
with check (
  bucket_id = 'space-assets'
  and auth.uid()::text = (storage.foldername(name))[1]
  and (storage.foldername(name))[2] in ('logo', 'cover')
  and public.monolith_current_role() in ('trainer_basic', 'trainer_plus', 'admin')
);

create policy "space_assets_update_owner"
on storage.objects for update
using (
  bucket_id = 'space-assets'
  and auth.uid()::text = (storage.foldername(name))[1]
  and public.monolith_current_role() in ('trainer_basic', 'trainer_plus', 'admin')
)
with check (
  bucket_id = 'space-assets'
  and auth.uid()::text = (storage.foldername(name))[1]
  and (storage.foldername(name))[2] in ('logo', 'cover')
  and public.monolith_current_role() in ('trainer_basic', 'trainer_plus', 'admin')
);

create policy "space_assets_delete_owner"
on storage.objects for delete
using (
  bucket_id = 'space-assets'
  and auth.uid()::text = (storage.foldername(name))[1]
  and public.monolith_current_role() in ('trainer_basic', 'trainer_plus', 'admin')
);

drop policy if exists "leads_interested_insert" on public.trainer_leads;
drop policy if exists "leads_private_read" on public.trainer_leads;
drop policy if exists "leads_trainer_update" on public.trainer_leads;
drop policy if exists "leads_interested_idempotent_update" on public.trainer_leads;
drop policy if exists "lead_events_private" on public.trainer_lead_events;
drop policy if exists "lead_events_insert" on public.trainer_lead_events;

revoke select, insert, update, delete on public.trainer_leads from authenticated;
revoke select, insert, update, delete on public.trainer_lead_events from authenticated;

comment on table public.trainer_leads is 'Deprecated after Monolith step 28. Existing rows are retained for audit only; the app no longer creates or exposes Leads to trainers.';
comment on table public.trainer_lead_events is 'Deprecated after Monolith step 28. Existing rows are retained for audit only; identified map/profile events are no longer collected.';
comment on column public.monolith_spaces.logo_storage_path is 'Private Supabase Storage path in bucket space-assets: {owner_id}/logo/{file}.';
comment on column public.monolith_spaces.cover_storage_path is 'Private Supabase Storage path in bucket space-assets: {owner_id}/cover/{file}.';

revoke all on function public.monolith_space_slug_available(text, uuid) from public;
revoke all on function public.monolith_guard_space_asset_paths() from public;
grant execute on function public.monolith_space_slug_available(text, uuid) to authenticated;

commit;

select
  'Monolith alertas and space assets ready' as status,
  now() as checked_at;
