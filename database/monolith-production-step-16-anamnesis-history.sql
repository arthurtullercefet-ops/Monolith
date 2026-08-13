-- Monolith production step 16
-- Adds immutable anamnesis versions and a linked-trainer review action.
-- Safe to run more than once after steps 11 through 14.

alter table public.student_anamneses
  add column if not exists version integer not null default 1,
  add column if not exists last_reviewed_at timestamptz,
  add column if not exists last_reviewed_by uuid references public.profiles(id) on delete set null;

create table if not exists public.student_anamnesis_versions (
  id uuid primary key default gen_random_uuid(),
  anamnesis_id uuid not null references public.student_anamneses(id) on delete cascade,
  student_id uuid not null references public.profiles(id) on delete cascade,
  version integer not null,
  snapshot jsonb not null,
  changed_at timestamptz not null default now(),
  changed_by uuid references public.profiles(id) on delete set null,
  unique (anamnesis_id, version)
);

create index if not exists student_anamnesis_versions_student_idx
on public.student_anamnesis_versions (student_id, changed_at desc);

create or replace function public.monolith_version_student_anamnesis()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if row(
    old.answers,
    old.risk_flags,
    old.medical_clearance_recommended,
    old.consent,
    old.status,
    old.submitted_at
  ) is distinct from row(
    new.answers,
    new.risk_flags,
    new.medical_clearance_recommended,
    new.consent,
    new.status,
    new.submitted_at
  ) then
    insert into public.student_anamnesis_versions (
      anamnesis_id,
      student_id,
      version,
      snapshot,
      changed_by
    ) values (
      old.id,
      old.student_id,
      old.version,
      jsonb_build_object(
        'answers', old.answers,
        'risk_flags', old.risk_flags,
        'medical_clearance_recommended', old.medical_clearance_recommended,
        'consent', old.consent,
        'status', old.status,
        'submitted_at', old.submitted_at,
        'draft_saved_at', old.draft_saved_at,
        'consent_accepted_at', old.consent_accepted_at,
        'important_updated_at', old.important_updated_at,
        'created_at', old.created_at,
        'updated_at', old.updated_at
      ),
      auth.uid()
    ) on conflict (anamnesis_id, version) do nothing;
    new.version := greatest(old.version + 1, new.version);
  end if;
  return new;
end;
$$;

drop trigger if exists student_anamneses_version_history on public.student_anamneses;
create trigger student_anamneses_version_history
before update on public.student_anamneses
for each row execute function public.monolith_version_student_anamnesis();

alter table public.student_anamnesis_versions enable row level security;

drop policy if exists "student_anamnesis_versions_select_scoped" on public.student_anamnesis_versions;
create policy "student_anamnesis_versions_select_scoped"
on public.student_anamnesis_versions for select
using (
  student_id = auth.uid()
  or public.is_trainer_for(student_id)
);

create or replace function public.review_student_anamnesis(p_anamnesis_id uuid)
returns public.student_anamneses
language plpgsql
security definer
set search_path = public
as $$
declare
  v_record public.student_anamneses;
begin
  select * into v_record
  from public.student_anamneses
  where id = p_anamnesis_id;

  if v_record.id is null
     or v_record.consent is not true
     or v_record.status not in ('submitted', 'reviewed')
     or not public.is_trainer_for(v_record.student_id) then
    raise exception 'anamnesis_not_accessible';
  end if;

  update public.student_anamneses
  set
    status = 'reviewed',
    last_reviewed_at = now(),
    last_reviewed_by = auth.uid()
  where id = p_anamnesis_id
  returning * into v_record;

  insert into public.student_anamnesis_reads (anamnesis_id, trainer_id, viewed_at)
  values (p_anamnesis_id, auth.uid(), now())
  on conflict (anamnesis_id, trainer_id)
  do update set viewed_at = excluded.viewed_at;

  return v_record;
end;
$$;

revoke all on public.student_anamnesis_versions from anon;
grant select on public.student_anamnesis_versions to authenticated;
grant execute on function public.review_student_anamnesis(uuid) to authenticated;

select 'Monolith anamnesis history ready' as status, now() as checked_at;
