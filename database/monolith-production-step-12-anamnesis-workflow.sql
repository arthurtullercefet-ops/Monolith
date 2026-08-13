-- Monolith production step 12
-- Completes the anamnesis workflow with drafts, explicit consent and trainer read receipts.
-- Safe to run more than once after step 11.

alter table public.student_anamneses
  add column if not exists draft_saved_at timestamptz,
  add column if not exists consent_accepted_at timestamptz,
  add column if not exists important_updated_at timestamptz;

update public.student_anamneses
set
  consent_accepted_at = case
    when consent and consent_accepted_at is null then coalesce(submitted_at, updated_at, created_at)
    else consent_accepted_at
  end,
  important_updated_at = coalesce(important_updated_at, updated_at, created_at)
where consent_accepted_at is null
   or important_updated_at is null;

create table if not exists public.student_anamnesis_reads (
  anamnesis_id uuid not null references public.student_anamneses(id) on delete cascade,
  trainer_id uuid not null references public.profiles(id) on delete cascade,
  viewed_at timestamptz not null default now(),
  primary key (anamnesis_id, trainer_id)
);

alter table public.student_anamnesis_reads enable row level security;

drop policy if exists "student_anamneses_select_owner_or_trainer" on public.student_anamneses;
create policy "student_anamneses_select_owner_or_trainer"
on public.student_anamneses for select
using (
  student_id = auth.uid()
  or (
    consent = true
    and status in ('submitted', 'reviewed')
    and public.is_trainer_for(student_id)
  )
);

drop policy if exists "student_anamnesis_reads_select_linked_trainer" on public.student_anamnesis_reads;
create policy "student_anamnesis_reads_select_linked_trainer"
on public.student_anamnesis_reads for select
using (
  trainer_id = auth.uid()
  and exists (
    select 1
    from public.student_anamneses sa
    where sa.id = student_anamnesis_reads.anamnesis_id
      and sa.consent = true
      and sa.status in ('submitted', 'reviewed')
      and public.is_trainer_for(sa.student_id)
  )
);

drop policy if exists "student_anamnesis_reads_insert_linked_trainer" on public.student_anamnesis_reads;
create policy "student_anamnesis_reads_insert_linked_trainer"
on public.student_anamnesis_reads for insert
with check (
  trainer_id = auth.uid()
  and exists (
    select 1
    from public.student_anamneses sa
    where sa.id = student_anamnesis_reads.anamnesis_id
      and sa.consent = true
      and sa.status in ('submitted', 'reviewed')
      and public.is_trainer_for(sa.student_id)
  )
);

drop policy if exists "student_anamnesis_reads_update_linked_trainer" on public.student_anamnesis_reads;
create policy "student_anamnesis_reads_update_linked_trainer"
on public.student_anamnesis_reads for update
using (trainer_id = auth.uid())
with check (
  trainer_id = auth.uid()
  and exists (
    select 1
    from public.student_anamneses sa
    where sa.id = student_anamnesis_reads.anamnesis_id
      and sa.consent = true
      and sa.status in ('submitted', 'reviewed')
      and public.is_trainer_for(sa.student_id)
  )
);

create index if not exists student_anamnesis_reads_trainer_viewed_idx
on public.student_anamnesis_reads (trainer_id, viewed_at desc);

