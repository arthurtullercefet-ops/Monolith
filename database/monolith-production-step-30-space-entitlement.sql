-- Monolith production step 30
-- Plus Space entitlement gate for menu, Space settings and private assets.
-- Safe to run more than once after production step 29. No Spaces, files or memberships are deleted.

begin;

alter table public.profiles
  add column if not exists space_enabled boolean not null default false;

comment on column public.profiles.space_enabled is
  'Commercial entitlement for the Plus Space add-on. Only backend/admin/payment automation should enable it.';

update public.profiles p
set space_enabled = true
where p.space_enabled is false
  and p.role in ('trainer_basic', 'trainer_plus', 'admin')
  and exists (
    select 1
    from public.monolith_spaces s
    where s.owner_id = p.id
  );

create or replace function public.monolith_guard_space_entitlement()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' and new.space_enabled is true then
    if coalesce(auth.role(), '') <> 'service_role'
       and public.monolith_current_role() is distinct from 'admin' then
      raise exception 'Plus Space entitlement is managed by Monolith';
    end if;
  end if;

  if tg_op = 'UPDATE' and new.space_enabled is distinct from old.space_enabled then
    if coalesce(auth.role(), '') <> 'service_role'
       and public.monolith_current_role() is distinct from 'admin' then
      raise exception 'Plus Space entitlement is managed by Monolith';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists profiles_guard_space_entitlement on public.profiles;
create trigger profiles_guard_space_entitlement
before insert or update of space_enabled on public.profiles
for each row execute function public.monolith_guard_space_entitlement();

create or replace function public.monolith_space_enabled(target_trainer uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.profiles p
    where p.id = coalesce(target_trainer, auth.uid())
      and p.role in ('trainer_basic', 'trainer_plus', 'admin')
      and p.space_enabled is true
  );
$$;

revoke all on function public.monolith_space_enabled(uuid) from public;
revoke all on function public.monolith_space_enabled(uuid) from anon;
revoke all on function public.monolith_guard_space_entitlement() from public;
revoke all on function public.monolith_guard_space_entitlement() from anon;
grant execute on function public.monolith_space_enabled(uuid) to authenticated;

drop policy if exists "spaces_member_read" on public.monolith_spaces;
drop policy if exists "spaces_owner_write" on public.monolith_spaces;

create policy "spaces_member_read"
on public.monolith_spaces for select
using (
  active
  and public.monolith_space_enabled(owner_id)
  and public.is_space_member(id)
);

create policy "spaces_owner_write"
on public.monolith_spaces for all
using (
  owner_id = auth.uid()
  and public.monolith_space_enabled(auth.uid())
)
with check (
  owner_id = auth.uid()
  and public.monolith_space_enabled(auth.uid())
);

drop policy if exists "memberships_owner_write" on public.space_memberships;
create policy "memberships_owner_write"
on public.space_memberships for all
using (
  exists (
    select 1
    from public.monolith_spaces s
    where s.id = space_memberships.space_id
      and s.owner_id = auth.uid()
      and public.monolith_space_enabled(s.owner_id)
  )
)
with check (
  exists (
    select 1
    from public.monolith_spaces s
    where s.id = space_memberships.space_id
      and s.owner_id = auth.uid()
      and public.monolith_space_enabled(s.owner_id)
  )
);

drop policy if exists "space_assets_select_member" on storage.objects;
drop policy if exists "space_assets_insert_owner" on storage.objects;
drop policy if exists "space_assets_update_owner" on storage.objects;
drop policy if exists "space_assets_delete_owner" on storage.objects;

create policy "space_assets_select_member"
on storage.objects for select
using (
  bucket_id = 'space-assets'
  and case
    when (storage.foldername(name))[1] ~* '^[0-9a-f-]{36}$'
      then public.monolith_space_enabled(((storage.foldername(name))[1])::uuid)
    else false
  end
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
  and public.monolith_space_enabled(auth.uid())
);

create policy "space_assets_update_owner"
on storage.objects for update
using (
  bucket_id = 'space-assets'
  and auth.uid()::text = (storage.foldername(name))[1]
  and public.monolith_space_enabled(auth.uid())
)
with check (
  bucket_id = 'space-assets'
  and auth.uid()::text = (storage.foldername(name))[1]
  and (storage.foldername(name))[2] in ('logo', 'cover')
  and public.monolith_space_enabled(auth.uid())
);

create policy "space_assets_delete_owner"
on storage.objects for delete
using (
  bucket_id = 'space-assets'
  and auth.uid()::text = (storage.foldername(name))[1]
  and public.monolith_space_enabled(auth.uid())
);

commit;

select
  'Monolith Plus Space entitlement ready' as status,
  now() as checked_at;
