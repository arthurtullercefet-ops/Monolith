-- Monolith production step 34
-- Persists diet publication, protects measurement authorship and repairs invite generation.
-- Safe to run more than once after production step 33. No existing row is updated or deleted.

alter table public.diet_plans
  add column if not exists publication_status text,
  add column if not exists published_at timestamptz,
  add column if not exists published_by uuid references public.profiles(id) on delete set null;

alter table public.diet_plans
  alter column publication_status set default 'draft';

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'diet_plans_publication_status_check'
  ) then
    alter table public.diet_plans
      add constraint diet_plans_publication_status_check
      check (publication_status is null or publication_status in ('draft', 'published', 'archived'))
      not valid;
  end if;
end;
$$;

create index if not exists diet_plans_student_publication_idx
on public.diet_plans (student_id, month_key, publication_status);

create or replace function public.monolith_set_diet_publication()
returns trigger
language plpgsql
as $$
begin
  if new.publication_status = 'published' then
    if tg_op = 'INSERT' then
      new.published_at = now();
      new.published_by = auth.uid();
    elsif old.publication_status is distinct from 'published' then
      new.published_at = now();
      new.published_by = auth.uid();
    else
      new.published_at = old.published_at;
      new.published_by = old.published_by;
    end if;
  elsif new.publication_status is distinct from 'published' then
    new.published_at = null;
    new.published_by = null;
  end if;
  return new;
end;
$$;

drop trigger if exists diet_plans_set_publication on public.diet_plans;
create trigger diet_plans_set_publication
before insert or update of publication_status on public.diet_plans
for each row execute function public.monolith_set_diet_publication();

alter table public.diet_plans enable row level security;

drop policy if exists "diet_plans_select_student_or_trainer" on public.diet_plans;
drop policy if exists "diet_plans_select_student_or_linked_trainer" on public.diet_plans;
drop policy if exists "diet_plans_select_published_student_or_linked_trainer" on public.diet_plans;

create policy "diet_plans_select_published_student_or_linked_trainer"
on public.diet_plans for select
using (
  (student_id = auth.uid() and coalesce(publication_status, 'published') = 'published')
  or (trainer_id = auth.uid() and public.is_trainer_for(student_id))
);

alter table public.diet_plan_supplements enable row level security;

drop policy if exists "diet_plan_supplements_select_scoped" on public.diet_plan_supplements;
create policy "diet_plan_supplements_select_scoped"
on public.diet_plan_supplements for select
using (
  exists (
    select 1
    from public.diet_plans dp
    where dp.id = diet_plan_supplements.diet_plan_id
      and (
        (dp.student_id = auth.uid() and coalesce(dp.publication_status, 'published') = 'published')
        or (dp.trainer_id = auth.uid() and public.is_trainer_for(dp.student_id))
      )
  )
);

alter table public.body_measurements enable row level security;

create or replace function public.monolith_preserve_body_measurement_scope()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'INSERT' then
    new.created_by = coalesce(auth.uid(), new.created_by);
  else
    new.student_id = old.student_id;
    new.created_by = old.created_by;
  end if;
  new.updated_by = coalesce(auth.uid(), new.updated_by, new.created_by);
  return new;
end;
$$;

drop trigger if exists body_measurements_preserve_scope on public.body_measurements;
create trigger body_measurements_preserve_scope
before insert or update on public.body_measurements
for each row execute function public.monolith_preserve_body_measurement_scope();

drop policy if exists "body_measurements_write_owner" on public.body_measurements;
drop policy if exists "body_measurements_write_owner_or_trainer" on public.body_measurements;
drop policy if exists "body_measurements_insert_owner_or_trainer" on public.body_measurements;
drop policy if exists "body_measurements_update_owner_or_trainer" on public.body_measurements;
drop policy if exists "body_measurements_delete_owner_or_trainer" on public.body_measurements;

create policy "body_measurements_insert_owner_or_trainer"
on public.body_measurements for insert
with check (
  created_by = auth.uid()
  and (student_id = auth.uid() or public.is_trainer_for(student_id))
);

create policy "body_measurements_update_owner_or_trainer"
on public.body_measurements for update
using (
  public.is_trainer_for(student_id)
  or (student_id = auth.uid() and created_by = auth.uid())
)
with check (
  updated_by = auth.uid()
  and (
    public.is_trainer_for(student_id)
    or (student_id = auth.uid() and created_by = auth.uid())
  )
);

create policy "body_measurements_delete_owner_or_trainer"
on public.body_measurements for delete
using (
  public.is_trainer_for(student_id)
  or (student_id = auth.uid() and created_by = auth.uid())
);

create or replace function public.monolith_generate_invite_code()
returns text
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  new_code text;
begin
  loop
    new_code := 'MONO-' || upper(substr(replace(pg_catalog.gen_random_uuid()::text, '-', ''), 1, 12));
    exit when not exists (
      select 1 from public.trainer_invites where upper(code) = upper(new_code)
    );
  end loop;
  return new_code;
end;
$$;

revoke all on function public.monolith_generate_invite_code() from public, anon, authenticated;

create or replace function public.create_trainer_invite(
  p_expires_days integer default 30,
  p_max_uses integer default null
)
returns text
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  trainer_role public.monolith_role;
  new_code text;
begin
  select role into trainer_role from public.profiles where id = auth.uid();
  if trainer_role is null or trainer_role not in ('trainer_basic', 'trainer_plus', 'admin') then
    raise exception 'Only trainers can create invite codes.';
  end if;
  new_code := public.monolith_generate_invite_code();
  insert into public.trainer_invites (trainer_id, code, max_uses, expires_at)
  values (
    auth.uid(),
    new_code,
    p_max_uses,
    case when p_expires_days is null then null else now() + make_interval(days => greatest(p_expires_days, 1)) end
  );
  return new_code;
end;
$$;

create or replace function public.create_trainer_invite_idempotent(
  p_client_request_id text,
  p_expires_days integer default 30,
  p_max_uses integer default null
)
returns text
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  trainer_role public.monolith_role;
  existing_code text;
  new_code text;
begin
  if nullif(trim(p_client_request_id), '') is null then
    raise exception 'A client request id is required.';
  end if;
  select role into trainer_role from public.profiles where id = auth.uid();
  if trainer_role is null or trainer_role not in ('trainer_basic', 'trainer_plus', 'admin') then
    raise exception 'Only trainers can create invite codes.';
  end if;
  select code into existing_code
  from public.trainer_invites
  where trainer_id = auth.uid() and client_request_id = p_client_request_id
  limit 1;
  if existing_code is not null then return existing_code; end if;
  new_code := public.monolith_generate_invite_code();
  begin
    insert into public.trainer_invites (trainer_id, code, max_uses, expires_at, client_request_id)
    values (
      auth.uid(),
      new_code,
      p_max_uses,
      case when p_expires_days is null then null else now() + make_interval(days => greatest(p_expires_days, 1)) end,
      p_client_request_id
    );
  exception when unique_violation then
    select code into existing_code
    from public.trainer_invites
    where trainer_id = auth.uid() and client_request_id = p_client_request_id
    limit 1;
    if existing_code is null then raise; end if;
    return existing_code;
  end;
  return new_code;
end;
$$;

grant execute on function public.create_trainer_invite(integer, integer) to authenticated;
grant execute on function public.create_trainer_invite_idempotent(text, integer, integer) to authenticated;

select pg_notify('pgrst', 'reload schema');

select
  'Monolith diet publication, measure ownership and invite repair ready' as status,
  now() as checked_at;
