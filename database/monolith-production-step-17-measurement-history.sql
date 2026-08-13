-- Monolith production step 17
-- Adds reversible measurement archiving and linked-trainer write scope.
-- Safe to run more than once after production step 16. No user data is deleted.

alter table public.body_measurements
  add column if not exists archived_at timestamptz,
  add column if not exists archived_by uuid references public.profiles(id) on delete set null,
  add column if not exists correction_reason text,
  add column if not exists updated_at timestamptz not null default now();

create index if not exists body_measurements_active_student_date_idx
on public.body_measurements (student_id, measurement_date desc)
where archived_at is null;

create or replace function public.monolith_touch_body_measurement()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  if new.archived_at is distinct from old.archived_at then
    new.archived_by = case when new.archived_at is null then null else auth.uid() end;
  end if;
  return new;
end;
$$;

drop trigger if exists body_measurements_touch_updated_at on public.body_measurements;
create trigger body_measurements_touch_updated_at
before update on public.body_measurements
for each row execute function public.monolith_touch_body_measurement();

alter table public.body_measurements enable row level security;

drop policy if exists "body_measurements_write_owner" on public.body_measurements;
drop policy if exists "body_measurements_write_owner_or_trainer" on public.body_measurements;
drop policy if exists "body_measurements_insert_owner_or_trainer" on public.body_measurements;
drop policy if exists "body_measurements_update_owner_or_trainer" on public.body_measurements;
drop policy if exists "body_measurements_delete_owner_or_trainer" on public.body_measurements;

create policy "body_measurements_insert_owner_or_trainer"
on public.body_measurements for insert
with check (
  student_id = auth.uid()
  or public.is_trainer_for(student_id)
);

create policy "body_measurements_update_owner_or_trainer"
on public.body_measurements for update
using (
  student_id = auth.uid()
  or public.is_trainer_for(student_id)
)
with check (
  student_id = auth.uid()
  or public.is_trainer_for(student_id)
);

create policy "body_measurements_delete_owner_or_trainer"
on public.body_measurements for delete
using (
  student_id = auth.uid()
  or public.is_trainer_for(student_id)
);

grant select, insert, update, delete on public.body_measurements to authenticated;

