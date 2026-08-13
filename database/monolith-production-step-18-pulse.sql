-- Monolith production step 18
-- Stores personal-trainer review receipts for Monolith Pulse alerts.
-- Safe to run more than once after production step 17. No user data is deleted.

create table if not exists public.monolith_pulse_reviews (
  id uuid primary key default gen_random_uuid(),
  trainer_id uuid not null references public.profiles(id) on delete cascade,
  student_id uuid not null references public.profiles(id) on delete cascade,
  alert_key text not null check (char_length(alert_key) between 2 and 80),
  alert_fingerprint text not null check (char_length(alert_fingerprint) between 2 and 180),
  reviewed_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  unique (trainer_id, student_id, alert_fingerprint)
);

create index if not exists monolith_pulse_reviews_trainer_idx
on public.monolith_pulse_reviews (trainer_id, reviewed_at desc);

create index if not exists monolith_pulse_reviews_student_idx
on public.monolith_pulse_reviews (student_id, reviewed_at desc);

alter table public.monolith_pulse_reviews enable row level security;

drop policy if exists "pulse_reviews_trainer_select" on public.monolith_pulse_reviews;
drop policy if exists "pulse_reviews_trainer_insert" on public.monolith_pulse_reviews;
drop policy if exists "pulse_reviews_trainer_delete" on public.monolith_pulse_reviews;

create policy "pulse_reviews_trainer_select"
on public.monolith_pulse_reviews for select
using (
  trainer_id = auth.uid()
  and public.is_trainer_for(student_id)
);

create policy "pulse_reviews_trainer_insert"
on public.monolith_pulse_reviews for insert
with check (
  trainer_id = auth.uid()
  and public.is_trainer_for(student_id)
);

create policy "pulse_reviews_trainer_delete"
on public.monolith_pulse_reviews for delete
using (
  trainer_id = auth.uid()
  and public.is_trainer_for(student_id)
);

grant select, insert, delete on public.monolith_pulse_reviews to authenticated;
