-- Monolith production step 04
-- Allows linked trainers to prescribe/edit student check-in factors and save daily check-ins.
-- Run this after monolith-production-step-03-checkin-factors.sql.

drop policy if exists "daily_checkins_write_owner" on public.daily_checkins;
drop policy if exists "daily_checkins_write_owner_or_trainer" on public.daily_checkins;

create policy "daily_checkins_write_owner_or_trainer"
on public.daily_checkins for all
using (student_id = auth.uid() or public.is_trainer_for(student_id))
with check (student_id = auth.uid() or public.is_trainer_for(student_id));

drop policy if exists "checkin_factors_write_owner" on public.checkin_factors;
drop policy if exists "checkin_factors_write_owner_or_trainer" on public.checkin_factors;

create policy "checkin_factors_write_owner_or_trainer"
on public.checkin_factors for all
using (student_id = auth.uid() or public.is_trainer_for(student_id))
with check (student_id = auth.uid() or public.is_trainer_for(student_id));
