-- Step 36: named diets within a month and ranges in prescribed workout sets.
-- No student, meal, workout, Auth identity or existing diet is rewritten.
begin;
alter table public.diet_plans
  add column plan_name text not null default '',
  add column variant_key text not null default 'default';
alter table public.diet_plans
  add constraint diet_plans_name_check check (length(plan_name) <= 120),
  add constraint diet_plans_variant_key_check check (
    variant_key = 'default' or variant_key ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'),
  add constraint diet_plans_named_variant_check check (variant_key = 'default' or nullif(btrim(plan_name),'') is not null),
  drop constraint diet_plans_student_id_month_key_key,
  add constraint diet_plans_trainer_student_month_variant_key unique(trainer_id,student_id,month_key,variant_key);
comment on column public.diet_plans.variant_key is
  'Stable variant identity, independent of display name. Existing monthly diets retain the default variant; additional diets use a client UUID.';
comment on column public.diet_plans.plan_name is
  'Trainer-authored label, e.g. High Day or Low Day. Blank legacy names display as the localized default diet label.';

create function monolith_private.guard_diet_variant_identity() returns trigger
language plpgsql set search_path = '' as $$
begin
  if (new.id,new.trainer_id,new.student_id,new.month_key,new.variant_key)
    is distinct from (old.id,old.trainer_id,old.student_id,old.month_key,old.variant_key) then
    raise exception 'Diet identity is immutable; create a separate copy instead' using errcode='42501';
  end if;
  return new;
end $$;
revoke all on function monolith_private.guard_diet_variant_identity() from public,anon,authenticated;
create trigger diet_plans_guard_variant_identity before update on public.diet_plans
  for each row execute function monolith_private.guard_diet_variant_identity();

create function public.monolith_prescribed_reps_are_valid(p_value text) returns boolean
language plpgsql immutable set search_path = '' as $$
declare v text := btrim(coalesce(p_value,'')); parts text[]; begin
  if v = '' then return true; end if;
  v := regexp_replace(translate(v, '–—−', '---'), '\s', '', 'g');
  if v !~ '^\d{1,3}(-\d{1,3})?$' then return false; end if;
  parts := string_to_array(v,'-');
  return parts[1]::integer between 1 and 100
    and (array_length(parts,1)=1 or (parts[2]::integer between parts[1]::integer and 100));
exception when others then return false;
end $$;
create function public.monolith_prescribed_workout_is_plausible(p_exercises jsonb) returns boolean
language plpgsql immutable set search_path = '' as $$
declare ex jsonb; s jsonb; begin
  if p_exercises is null then return true; end if;
  if jsonb_typeof(p_exercises) <> 'array' then return false; end if;
  for ex in select value from jsonb_array_elements(p_exercises) loop
    if ex ? 'sets' and jsonb_typeof(ex->'sets') <> 'array' then return false; end if;
    for s in select value from jsonb_array_elements(coalesce(ex->'sets','[]'::jsonb)) loop
      if not public.monolith_text_number_in_range(s->>'weight',0,600)
        or not public.monolith_prescribed_reps_are_valid(s->>'reps')
        or not public.monolith_text_number_in_range(s->>'rest',0,900) then return false; end if;
    end loop;
  end loop;
  return true;
exception when others then return false;
end $$;
-- Only prescriptions accept ranges. Completed workouts still require numeric reps.
alter table public.workout_templates drop constraint workout_templates_values_check;
alter table public.workout_templates add constraint workout_templates_values_check
  check (public.monolith_prescribed_workout_is_plausible(exercises)) not valid;
notify pgrst, 'reload schema';
commit;
