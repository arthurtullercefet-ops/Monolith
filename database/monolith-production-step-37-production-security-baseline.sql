-- Step 37: checked-in copy of existing production signup/role/link protections.
-- Already present in production on 2026-11-23; apply only when rebuilding a backend.
begin;

CREATE OR REPLACE FUNCTION public.handle_new_monolith_user()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  requested_role text;
  safe_role public.monolith_role;
  display_name text;
begin
  requested_role := coalesce(new.raw_user_meta_data ->> 'role', 'student');

  if requested_role = 'personal' then
    requested_role := 'trainer_basic';
  end if;

  if requested_role not in ('student', 'influencer', 'trainer_basic') then
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
$function$;

CREATE OR REPLACE FUNCTION public.monolith_guard_profile_role()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog', 'public'
AS $function$
BEGIN
  IF current_user IN ('postgres','service_role') THEN RETURN NEW; END IF;
  IF TG_OP = 'UPDATE' THEN
    IF NEW.role IS DISTINCT FROM OLD.role THEN
      RAISE EXCEPTION 'Account roles are managed by Monolith' USING ERRCODE='42501';
    END IF;
  ELSIF NEW.role::text NOT IN ('student','influencer','trainer_basic') THEN
    RAISE EXCEPTION 'Privileged account roles cannot be self-assigned' USING ERRCODE='42501';
  END IF;
  RETURN NEW;
END; $function$;

CREATE OR REPLACE FUNCTION public.monolith_guard_relationship_identity()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog', 'public'
AS $function$
BEGIN
  IF current_user IN ('postgres','service_role') THEN RETURN NEW; END IF;
  IF NEW.id IS DISTINCT FROM OLD.id OR NEW.trainer_id IS DISTINCT FROM OLD.trainer_id
     OR NEW.student_id IS DISTINCT FROM OLD.student_id
     OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'Relationship identity cannot be changed' USING ERRCODE='42501';
  END IF;
  IF NEW.status NOT IN ('paused','ended') THEN
    RAISE EXCEPTION 'Active relationships require accepting a valid trainer invite' USING ERRCODE='42501';
  END IF;
  RETURN NEW;
END; $function$;
drop trigger if exists profiles_guard_account_role on public.profiles;
create trigger profiles_guard_account_role before insert or update of role on public.profiles
for each row execute function public.monolith_guard_profile_role();
drop trigger if exists trainer_students_guard_relationship_identity on public.trainer_students;
create trigger trainer_students_guard_relationship_identity before update on public.trainer_students
for each row execute function public.monolith_guard_relationship_identity();
drop policy if exists trainer_students_insert_trainer on public.trainer_students;
drop policy if exists trainer_students_insert_student_accept on public.trainer_students;
drop policy if exists trainer_students_update_trainer on public.trainer_students;
create policy trainer_students_update_trainer on public.trainer_students
for update to authenticated
using (trainer_id = auth.uid() and public.monolith_current_role()::text in ('trainer_basic','trainer_plus','admin'))
with check (trainer_id = auth.uid() and public.monolith_current_role()::text in ('trainer_basic','trainer_plus','admin')
  and status in ('paused','ended'));
revoke execute on function public.monolith_guard_profile_role() from public, anon, authenticated;
revoke execute on function public.monolith_guard_relationship_identity() from public, anon, authenticated;
commit;
