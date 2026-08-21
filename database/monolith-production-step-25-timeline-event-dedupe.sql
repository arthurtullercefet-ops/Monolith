-- Monolith production step 25
-- Timeline event dedupe repair. Safe to run more than once after step 24.
-- No existing records are deleted.

alter table public.transformation_events
  add column if not exists event_key text;

with keyed as (
  select
    id,
    case
      when event_type = 'achievement' and source_id is not null then 'achievement-' || source_id || ':' || student_id::text
      when source_id is not null then event_type || ':' || source_id
      else event_type || ':' || client_request_id::text
    end as base_key,
    row_number() over (
      partition by student_id,
      case
        when event_type = 'achievement' and source_id is not null then 'achievement-' || source_id || ':' || student_id::text
        when source_id is not null then event_type || ':' || source_id
        else event_type || ':' || client_request_id::text
      end
      order by created_at asc, id asc
    ) as duplicate_rank
  from public.transformation_events
  where event_key is null
)
update public.transformation_events te
set event_key = case
  when keyed.duplicate_rank = 1 then keyed.base_key
  else keyed.base_key || ':legacy:' || te.id::text
end
from keyed
where te.id = keyed.id;

create unique index if not exists transformation_events_student_event_key_uidx
on public.transformation_events (student_id, event_key)
where event_key is not null;

create or replace view public.monolith_possible_duplicate_report as
select
  'transformation_events' as table_name,
  student_id,
  event_type as record_type,
  regexp_replace(event_key, ':legacy:[0-9a-f-]+$', '') as duplicate_key,
  count(*) as duplicate_count,
  min(created_at) as first_created_at,
  max(created_at) as last_created_at
from public.transformation_events
where event_key is not null
group by student_id, event_type, regexp_replace(event_key, ':legacy:[0-9a-f-]+$', '')
having count(*) > 1
union all
select
  'completed_workouts' as table_name,
  student_id,
  workout_name as record_type,
  coalesce(client_request_id::text, workout_name || ':' || completed_at::date::text) as duplicate_key,
  count(*) as duplicate_count,
  min(created_at) as first_created_at,
  max(created_at) as last_created_at
from public.completed_workouts
group by student_id, workout_name, coalesce(client_request_id::text, workout_name || ':' || completed_at::date::text)
having count(*) > 1
union all
select
  'body_measurements' as table_name,
  student_id,
  'measurement' as record_type,
  coalesce(client_request_id::text, measurement_date::text) as duplicate_key,
  count(*) as duplicate_count,
  min(created_at) as first_created_at,
  max(created_at) as last_created_at
from public.body_measurements
group by student_id, coalesce(client_request_id::text, measurement_date::text)
having count(*) > 1;

grant select on public.monolith_possible_duplicate_report to authenticated;

select 'Monolith timeline event dedupe ready' as status, now() as checked_at;
