-- Monolith production step 09
-- Progress photo Storage repair.
-- Safe to run after steps 01-08. It does not delete photos or user data.

insert into storage.buckets (id, name, public)
values ('progress-photos', 'progress-photos', false)
on conflict (id) do update set public = false;

alter table public.progress_photos enable row level security;

drop policy if exists "progress_photos_select_owner_or_trainer" on public.progress_photos;
create policy "progress_photos_select_owner_or_trainer"
on public.progress_photos for select
using (student_id = auth.uid() or public.is_trainer_for(student_id));

drop policy if exists "progress_photos_write_owner" on public.progress_photos;
create policy "progress_photos_write_owner"
on public.progress_photos for all
using (student_id = auth.uid())
with check (student_id = auth.uid());

drop policy if exists "progress_photos_storage_select_owner_or_trainer" on storage.objects;
drop policy if exists "progress_photos_storage_write_owner" on storage.objects;
drop policy if exists "progress_photos_storage_insert_owner" on storage.objects;
drop policy if exists "progress_photos_storage_update_owner" on storage.objects;
drop policy if exists "progress_photos_storage_delete_owner" on storage.objects;

create policy "progress_photos_storage_select_owner_or_trainer"
on storage.objects for select
using (
  bucket_id = 'progress-photos'
  and (
    (storage.foldername(name))[1] = auth.uid()::text
    or (
      (storage.foldername(name))[1] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      and public.is_trainer_for(((storage.foldername(name))[1])::uuid)
    )
  )
);

create policy "progress_photos_storage_insert_owner"
on storage.objects for insert
with check (
  bucket_id = 'progress-photos'
  and (storage.foldername(name))[1] = auth.uid()::text
);

create policy "progress_photos_storage_update_owner"
on storage.objects for update
using (
  bucket_id = 'progress-photos'
  and (storage.foldername(name))[1] = auth.uid()::text
)
with check (
  bucket_id = 'progress-photos'
  and (storage.foldername(name))[1] = auth.uid()::text
);

create policy "progress_photos_storage_delete_owner"
on storage.objects for delete
using (
  bucket_id = 'progress-photos'
  and (storage.foldername(name))[1] = auth.uid()::text
);

create index if not exists progress_photos_student_month_angle_idx
on public.progress_photos (student_id, photo_month, angle);

select
  'Monolith photo storage ready' as status,
  now() as checked_at;
