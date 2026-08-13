-- Monolith production step 23
-- Adds persisted student language, voice and unit preferences.
-- Safe to run more than once after step 22.

alter table public.profiles
  add column if not exists voice_language text not null default 'auto',
  add column if not exists voice_gender text not null default 'neutral';

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'profiles_voice_language_check'
      and conrelid = 'public.profiles'::regclass
  ) then
    alter table public.profiles
      add constraint profiles_voice_language_check
      check (voice_language in ('auto', 'pt-BR', 'en-US', 'es-419'));
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conname = 'profiles_voice_gender_check'
      and conrelid = 'public.profiles'::regclass
  ) then
    alter table public.profiles
      add constraint profiles_voice_gender_check
      check (voice_gender in ('neutral', 'feminine', 'masculine'));
  end if;
end
$$;

comment on column public.profiles.language is
  'Application language: pt, en or es.';
comment on column public.profiles.weight_unit is
  'Preferred display and spoken weight unit. Canonical stored workout weights remain kilograms.';
comment on column public.profiles.voice_language is
  'Monolith Voice locale. auto follows the application language.';
comment on column public.profiles.voice_gender is
  'Preferred speech synthesis voice presentation when supported by the device.';
