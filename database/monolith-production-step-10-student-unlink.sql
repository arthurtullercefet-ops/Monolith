-- Monolith production step 10
-- Allows a student to unlink their own trainer relationship.
-- Run after monolith-production-step-01.sql.

alter table public.trainer_students enable row level security;

drop policy if exists "trainer_students_update_student_own" on public.trainer_students;
create policy "trainer_students_update_student_own"
on public.trainer_students for update
using (student_id = auth.uid())
with check (student_id = auth.uid() and status in ('paused', 'ended'));

drop policy if exists "trainer_students_delete_student_own" on public.trainer_students;
create policy "trainer_students_delete_student_own"
on public.trainer_students for delete
using (student_id = auth.uid());
