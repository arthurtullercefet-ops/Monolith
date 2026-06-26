-- Monolith trainer/student link policy
-- Run this in Supabase SQL Editor after the original schema.
-- It allows a logged-in student to accept a trainer invite code by linking their own account.

do $$
begin
  if not exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'trainer_students'
      and policyname = 'trainer_students_insert_student_accept'
  ) then
    create policy "trainer_students_insert_student_accept"
    on public.trainer_students for insert
    with check (
      student_id = auth.uid()
      and status in ('pending', 'active')
    );
  end if;
end
$$;
