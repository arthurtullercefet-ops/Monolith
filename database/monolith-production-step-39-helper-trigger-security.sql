-- Step 39: approved helper/trigger permissions and explicit validator search paths.
-- Scoped follow-up to step38, avoiding defaults, policy changes and trigger replacement.
-- Removes client RPC invocation of trigger functions; PostgreSQL trigger execution remains intact.
-- Restricts five privileged helpers to authenticated callers.
-- Fixes 17 mutable search paths while keeping public schema resolution.
begin;
revoke execute on function public.monolith_guard_space_entitlement() from public, anon, authenticated;
revoke execute on function public.handle_new_monolith_user() from public, anon, authenticated;
revoke execute on function public.is_trainer_for(student uuid) from public, anon;
revoke execute on function public.monolith_active_trainer_student(p_trainer_id uuid, p_student_id uuid) from public, anon;
revoke execute on function public.monolith_capture_appointment_event() from public, anon, authenticated;
revoke execute on function public.monolith_capture_audit() from public, anon, authenticated;
revoke execute on function public.monolith_current_role() from public, anon;
revoke execute on function public.monolith_guard_feedback_update() from public, anon, authenticated;
revoke execute on function public.monolith_guard_lead_insert() from public, anon, authenticated;
revoke execute on function public.monolith_guard_lead_update() from public, anon, authenticated;
revoke execute on function public.monolith_guard_space_asset_paths() from public, anon, authenticated;
revoke execute on function public.monolith_keep_achievement_immutable() from public, anon, authenticated;
revoke execute on function public.monolith_space_slug_available(p_slug text, p_owner_id uuid) from public, anon;
revoke execute on function public.monolith_student_has_active_trainer(p_student_id uuid) from public, anon;
revoke execute on function public.monolith_version_student_anamnesis() from public, anon, authenticated;
revoke execute on function public.sync_diet_plan_supplements_from_json() from public, anon, authenticated;

alter function public.monolith_anchor_date(p_month date, p_anchor_day integer) set search_path = pg_catalog, public, pg_temp;
alter function public.monolith_diet_meals_are_plausible(p_meals jsonb) set search_path = pg_catalog, public, pg_temp;
alter function public.monolith_preserve_body_measurement_scope() set search_path = pg_catalog, public, pg_temp;
alter function public.monolith_program_schedule_is_valid(p_schedule jsonb) set search_path = pg_catalog, public, pg_temp;
alter function public.monolith_set_authorship() set search_path = pg_catalog, public, pg_temp;
alter function public.monolith_set_checkin_authorship() set search_path = pg_catalog, public, pg_temp;
alter function public.monolith_set_diet_publication() set search_path = pg_catalog, public, pg_temp;
alter function public.monolith_set_program_metadata() set search_path = pg_catalog, public, pg_temp;
alter function public.monolith_text_number_in_range(p_value text, p_min numeric, p_max numeric) set search_path = pg_catalog, public, pg_temp;
alter function public.monolith_touch_body_measurement() set search_path = pg_catalog, public, pg_temp;
alter function public.monolith_valid_timezone(p_timezone text) set search_path = pg_catalog, public, pg_temp;
alter function public.monolith_validate_body_measurement_date() set search_path = pg_catalog, public, pg_temp;
alter function public.monolith_validate_completed_workout_date() set search_path = pg_catalog, public, pg_temp;
alter function public.monolith_validate_daily_checkin_date() set search_path = pg_catalog, public, pg_temp;
alter function public.monolith_validate_record_dates() set search_path = pg_catalog, public, pg_temp;
alter function public.monolith_workout_json_is_plausible(p_exercises jsonb) set search_path = pg_catalog, public, pg_temp;
alter function public.touch_updated_at() set search_path = pg_catalog, public, pg_temp;
commit;
