-- Read-only regression test for Step 38. Fails before the ACL fix.
do $security_test$
declare found_count integer; bad text;
begin
  select count(*), string_agg(p.proname, ', ') filter (where
    has_function_privilege('anon',p.oid,'EXECUTE')
    or not has_function_privilege('authenticated',p.oid,'EXECUTE')
    or not has_function_privilege('service_role',p.oid,'EXECUTE'))
  into found_count,bad from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname in ('accept_influencer_code','confirm_monolith_appointment','correct_daily_checkin','create_monolith_appointment','create_monolith_appointment_series','create_trainer_invite','create_trainer_invite_idempotent','generate_monolith_student_charges','record_monolith_student_payment','request_monolith_appointment_reschedule','reschedule_monolith_appointment','resolve_monolith_reschedule_request','reverse_monolith_student_payment','review_student_anamnesis','set_monolith_appointment_status','set_monolith_student_charge_exempt','update_monolith_appointment_scope','update_monolith_student_charge');
  if found_count <> 18 then raise exception 'Expected 18 application RPCs, found %',found_count; end if;
  if bad is not null then raise exception 'RPC access regression: %',bad; end if;
  if not has_function_privilege('authenticated','public.is_trainer_for(uuid)','EXECUTE')
    or not has_function_privilege('authenticated','public.create_managed_student(text,text,text,date,text,uuid,uuid)','EXECUTE') then
    raise exception 'Authenticated helper/managed-student access lost'; end if;
end
$security_test$;
select '18 RPCs deny anonymous access and preserve authenticated/service access' as result;
