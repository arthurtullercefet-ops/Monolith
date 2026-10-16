-- Optional structural rollback. Never deletes/exports/converts managed students.
-- If any managed record exists, rollback aborts: retain step 35 and disable the
-- creation entry point instead of discarding students or their related data.
begin;
lock table public.profiles in access exclusive mode;
do $$ begin
  if exists (select 1 from public.profiles where access_mode = 'managed') then
    raise exception 'Rollback refused: managed students exist. Preserve step 35 and all student data.';
  end if;
end $$;
drop trigger trainer_students_guard_capacity on public.trainer_students;
drop trigger profiles_guard_managed_identity on public.profiles;
do $$ declare r record; begin
  for r in select tablename,policyname from pg_policies where schemaname = 'public'
    and policyname in ('managed_owner_scope','profiles_managed_scope','profiles_managed_owner_read',
      'profiles_managed_owner_update','memberships_no_managed_identity')
  loop execute format('drop policy %I on public.%I', r.policyname,r.tablename); end loop;
end $$;
drop function public.create_managed_student(text,text,text,date,text,uuid,uuid);
drop function monolith_private.create_managed_student(text,text,text,date,text,uuid,uuid);
drop function monolith_private.guard_student_capacity();
drop function monolith_private.guard_profile_identity();
drop function monolith_private.managed_scope(uuid);
drop function monolith_private.owns_managed(uuid);
drop function monolith_private.authenticated_identity(uuid);
alter table public.profiles add constraint profiles_id_fkey foreign key(id) references auth.users(id) on delete cascade;
alter table public.profiles
  drop constraint profiles_access_identity_check,
  drop column auth_user_id, drop column access_mode, drop column managed_by,
  drop column managed_space_id, drop column contact_phone, drop column birth_date,
  drop column trainer_notes, drop column managed_request_id;
alter table public.profiles alter column email set not null;
-- Keep the existing report view as security_invoker: do not restore an RLS bypass.
notify pgrst, 'reload schema';
commit;
