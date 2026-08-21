-- Monolith production step 29
-- Non-destructive Space identity mode toggle.
-- Safe to run more than once after production step 28. No images, Spaces or memberships are deleted.

begin;

alter table public.monolith_spaces
  add column if not exists theme_mode text not null default 'space';

alter table public.monolith_spaces
  drop constraint if exists monolith_spaces_theme_mode_check;

alter table public.monolith_spaces
  add constraint monolith_spaces_theme_mode_check
  check (theme_mode in ('space', 'monolith'));

comment on column public.monolith_spaces.theme_mode is
  'space renders custom Space logo, cover and colors; monolith keeps custom data saved but renders the default Monolith identity.';

commit;

select
  'Monolith space identity mode ready' as status,
  now() as checked_at;
