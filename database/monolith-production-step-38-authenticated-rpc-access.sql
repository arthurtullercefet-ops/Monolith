-- Step 38: remove anonymous access to 18 authenticated business RPCs.
-- Each already has an explicit authenticated EXECUTE grant in production.
-- Does not modify function bodies, helpers, triggers, RLS policies or default privileges.
begin;
revoke execute on function public.accept_influencer_code(raw_code text) from public, anon;
revoke execute on function public.confirm_monolith_appointment(p_appointment_id uuid) from public, anon;
revoke execute on function public.correct_daily_checkin(p_checkin_id uuid, p_items jsonb, p_weight_kg numeric, p_score integer, p_completed integer, p_total integer, p_reason text, p_client_request_id text) from public, anon;
revoke execute on function public.create_monolith_appointment(p_student_id uuid, p_appointment_type text, p_start_date date, p_start_time time without time zone, p_duration_minutes integer, p_timezone text, p_location text, p_meeting_url text, p_shared_notes text, p_private_notes text, p_client_request_id text) from public, anon;
revoke execute on function public.create_monolith_appointment_series(p_student_id uuid, p_appointment_type text, p_start_date date, p_start_time time without time zone, p_duration_minutes integer, p_timezone text, p_weekdays smallint[], p_end_date date, p_occurrence_limit integer, p_location text, p_meeting_url text, p_shared_notes text, p_private_notes text, p_client_request_id text) from public, anon;
revoke execute on function public.create_trainer_invite(p_expires_days integer, p_max_uses integer) from public, anon;
revoke execute on function public.create_trainer_invite_idempotent(p_client_request_id text, p_expires_days integer, p_max_uses integer) from public, anon;
revoke execute on function public.generate_monolith_student_charges(p_competency_month date, p_student_ids uuid[], p_client_request_id text) from public, anon;
revoke execute on function public.record_monolith_student_payment(p_charge_id uuid, p_amount_minor bigint, p_paid_at timestamp with time zone, p_payment_method text, p_other_method text, p_private_notes text, p_client_request_id text) from public, anon;
revoke execute on function public.request_monolith_appointment_reschedule(p_appointment_id uuid, p_reason text, p_proposed_slots jsonb, p_client_request_id text) from public, anon;
revoke execute on function public.reschedule_monolith_appointment(p_appointment_id uuid, p_start_date date, p_start_time time without time zone, p_duration_minutes integer, p_timezone text, p_client_request_id text) from public, anon;
revoke execute on function public.resolve_monolith_reschedule_request(p_request_id uuid, p_action text, p_start_date date, p_start_time time without time zone, p_duration_minutes integer, p_timezone text) from public, anon;
revoke execute on function public.reverse_monolith_student_payment(p_receipt_id uuid, p_reason text) from public, anon;
revoke execute on function public.review_student_anamnesis(p_anamnesis_id uuid) from public, anon;
revoke execute on function public.set_monolith_appointment_status(p_appointment_id uuid, p_status text, p_scope text) from public, anon;
revoke execute on function public.set_monolith_student_charge_exempt(p_charge_id uuid, p_exempt boolean, p_reason text) from public, anon;
revoke execute on function public.update_monolith_appointment_scope(p_appointment_id uuid, p_scope text, p_start_date date, p_start_time time without time zone, p_duration_minutes integer, p_timezone text, p_appointment_type text, p_location text, p_meeting_url text, p_shared_notes text, p_private_notes text) from public, anon;
revoke execute on function public.update_monolith_student_charge(p_charge_id uuid, p_amount_minor bigint, p_due_date date, p_description text, p_private_notes text, p_reason text) from public, anon;
commit;
