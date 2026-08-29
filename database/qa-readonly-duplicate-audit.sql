-- Monolith QA duplicate audit (read-only)
-- This file only selects data. It does not update or delete any record.

-- 1. Inspect every workout card reported during QA.
select
  wt.id,
  wt.owner_id,
  owner.full_name as owner_name,
  wt.assigned_student_id as student_id,
  student.full_name as student_name,
  wt.name,
  wt.goal,
  wt.tag,
  wt.exercises,
  wt.client_request_id,
  wt.created_at,
  wt.updated_at
from public.workout_templates wt
left join public.profiles owner on owner.id = wt.owner_id
left join public.profiles student on student.id = wt.assigned_student_id
where lower(wt.name) in (lower('QA — NÃO EXECUTAR'), lower('ascas'))
order by lower(wt.name), wt.created_at, wt.id;

-- 2. Group workouts with the same owner, destination, name and content.
select
  wt.owner_id,
  owner.full_name as owner_name,
  wt.assigned_student_id as student_id,
  student.full_name as student_name,
  wt.name,
  wt.goal,
  wt.exercises,
  count(*) as matching_records,
  array_agg(wt.id order by wt.created_at, wt.id) as ids,
  array_agg(wt.client_request_id order by wt.created_at, wt.id) as client_request_ids,
  min(wt.created_at) as first_created_at,
  max(wt.created_at) as last_created_at
from public.workout_templates wt
left join public.profiles owner on owner.id = wt.owner_id
left join public.profiles student on student.id = wt.assigned_student_id
group by wt.owner_id, owner.full_name, wt.assigned_student_id, student.full_name, wt.name, wt.goal, wt.exercises
having count(*) > 1
order by matching_records desc, last_created_at desc;

-- 3. Inspect measurements that have identical student, date and values.
select
  bm.student_id,
  student.full_name as student_name,
  bm.measurement_date,
  bm.weight_kg,
  bm.body_fat_percent,
  bm.waist_cm,
  bm.chest_cm,
  bm.arm_cm,
  bm.leg_cm,
  bm.hip_cm,
  bm.notes,
  count(*) as matching_records,
  array_agg(bm.id order by bm.created_at, bm.id) as ids,
  array_agg(bm.client_request_id order by bm.created_at, bm.id) as client_request_ids,
  min(bm.created_at) as first_created_at,
  max(bm.created_at) as last_created_at
from public.body_measurements bm
left join public.profiles student on student.id = bm.student_id
group by
  bm.student_id,
  student.full_name,
  bm.measurement_date,
  bm.weight_kg,
  bm.body_fat_percent,
  bm.waist_cm,
  bm.chest_cm,
  bm.arm_cm,
  bm.leg_cm,
  bm.hip_cm,
  bm.notes
having count(*) > 1
order by matching_records desc, bm.measurement_date desc;
