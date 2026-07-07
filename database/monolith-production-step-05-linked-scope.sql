-- Monolith production step 05
-- Tightens trainer/student scope for production data.
-- Run this after monolith-production-step-04-trainer-checkin-write.sql.

drop policy if exists "workout_templates_write_owner" on public.workout_templates;
drop policy if exists "workout_templates_write_owner_or_linked" on public.workout_templates;

create policy "workout_templates_write_owner_or_linked"
on public.workout_templates for all
using (owner_id = auth.uid())
with check (
  owner_id = auth.uid()
  and (
    assigned_student_id is null
    or assigned_student_id = auth.uid()
    or public.is_trainer_for(assigned_student_id)
  )
);

drop policy if exists "diet_plans_write_trainer" on public.diet_plans;
drop policy if exists "diet_plans_write_linked_trainer" on public.diet_plans;

create policy "diet_plans_write_linked_trainer"
on public.diet_plans for all
using (
  trainer_id = auth.uid()
  and public.is_trainer_for(student_id)
)
with check (
  trainer_id = auth.uid()
  and public.is_trainer_for(student_id)
);

drop policy if exists "food_logs_select_owner_or_trainer" on public.food_logs;
drop policy if exists "food_logs_select_owner" on public.food_logs;

create policy "food_logs_select_owner"
on public.food_logs for select
using (student_id = auth.uid());
