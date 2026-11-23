-- Step 39 regression checks: ACLs and validator behavior only; no user writes.
do $test$
declare bad text;
begin
  select string_agg(p.proname, ', ') into bad
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.prosecdef and has_function_privilege('anon',p.oid,'EXECUTE');
  if bad is not null then raise exception 'Anonymous privileged function access remains: %',bad; end if;

  select string_agg(p.proname, ', ') into bad
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.prosecdef and p.prorettype='trigger'::regtype
    and has_function_privilege('authenticated',p.oid,'EXECUTE');
  if bad is not null then raise exception 'Privileged triggers still callable by clients: %',bad; end if;

  select string_agg(p.proname, ', ') into bad
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and not exists (
    select 1 from unnest(coalesce(p.proconfig,array[]::text[])) c where c like 'search_path=%');
  if bad is not null then raise exception 'Mutable search paths: %',bad; end if;

  select string_agg(p.proname, ', ') into bad
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname in ('is_trainer_for','monolith_current_role',
    'monolith_active_trainer_student','monolith_space_slug_available','monolith_student_has_active_trainer')
    and not has_function_privilege('authenticated',p.oid,'EXECUTE');
  if bad is not null then raise exception 'Authenticated helper access lost: %',bad; end if;

  if public.monolith_text_number_in_range('12.5',0,20) is not true
    or public.monolith_text_number_in_range('9999',0,20) is not false
    or public.monolith_diet_meals_are_plausible('[{"calories":200,"protein":20}]'::jsonb) is not true
    or public.monolith_valid_timezone('America/New_York') is not true
    or public.monolith_valid_timezone('Invalid/Monolith') is not false
    or public.monolith_anchor_date('2026-02-01'::date,31) <> '2026-02-28'::date then
    raise exception 'Validator/search-path behavior changed'; end if;
end
$test$;
select 'Helper/trigger permissions and explicit search paths verified' as result;
