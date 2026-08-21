-- Monolith production step 26
-- Supplement plan for diet prescriptions.
-- Safe to run more than once. No existing records are deleted.

alter table public.diet_plans
  add column if not exists supplements jsonb not null default '[]'::jsonb;

create table if not exists public.diet_plan_supplements (
  id uuid primary key default gen_random_uuid(),
  diet_plan_id uuid not null references public.diet_plans(id) on delete cascade,
  name text not null,
  brand text,
  dosage text not null,
  frequency text not null,
  timing text,
  instructions text,
  start_date date,
  end_date date,
  product_url text,
  source_type text not null default 'manual',
  partner_name text,
  is_sponsored boolean not null default false,
  sort_order integer not null default 0,
  created_by uuid not null references public.profiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint diet_plan_supplements_source_type_check check (source_type in ('manual', 'partner_catalog')),
  constraint diet_plan_supplements_dates_check check (end_date is null or start_date is null or end_date >= start_date),
  constraint diet_plan_supplements_url_check check (
    product_url is null
    or (
      length(product_url) <= 500
      and product_url ~* '^https?://'
      and product_url !~* '^(javascript|data):'
    )
  ),
  constraint diet_plan_supplements_partner_check check (
    is_sponsored = false
    or nullif(trim(coalesce(partner_name, '')), '') is not null
  )
);

alter table public.diet_plan_supplements enable row level security;

create index if not exists diet_plan_supplements_plan_order_idx
on public.diet_plan_supplements (diet_plan_id, sort_order);

create index if not exists diet_plan_supplements_created_by_idx
on public.diet_plan_supplements (created_by);

drop trigger if exists diet_plan_supplements_touch_updated_at on public.diet_plan_supplements;
create trigger diet_plan_supplements_touch_updated_at
before update on public.diet_plan_supplements
for each row execute function public.touch_updated_at();

create or replace function public.sync_diet_plan_supplements_from_json()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from public.diet_plan_supplements
  where diet_plan_id = new.id;

  insert into public.diet_plan_supplements (
    diet_plan_id,
    name,
    brand,
    dosage,
    frequency,
    timing,
    instructions,
    start_date,
    end_date,
    product_url,
    source_type,
    partner_name,
    is_sponsored,
    sort_order,
    created_by
  )
  select
    new.id,
    nullif(trim(item.value ->> 'name'), ''),
    nullif(trim(item.value ->> 'brand'), ''),
    nullif(trim(item.value ->> 'dosage'), ''),
    nullif(trim(item.value ->> 'frequency'), ''),
    nullif(trim(item.value ->> 'timing'), ''),
    nullif(trim(item.value ->> 'instructions'), ''),
    nullif(item.value ->> 'startDate', '')::date,
    nullif(item.value ->> 'endDate', '')::date,
    nullif(trim(coalesce(item.value ->> 'productUrl', item.value ->> 'product_url')), ''),
    coalesce(nullif(item.value ->> 'sourceType', ''), nullif(item.value ->> 'source_type', ''), 'manual'),
    nullif(trim(coalesce(item.value ->> 'partnerName', item.value ->> 'partner_name')), ''),
    coalesce(nullif(item.value ->> 'isSponsored', '')::boolean, nullif(item.value ->> 'is_sponsored', '')::boolean, false),
    coalesce((item.value ->> 'sortOrder')::integer, (item.value ->> 'sort_order')::integer, item.ordinality::integer - 1),
    new.trainer_id
  from jsonb_array_elements(coalesce(new.supplements, '[]'::jsonb)) with ordinality as item(value, ordinality)
  where nullif(trim(item.value ->> 'name'), '') is not null
    and nullif(trim(item.value ->> 'dosage'), '') is not null
    and nullif(trim(item.value ->> 'frequency'), '') is not null;

  return new;
end;
$$;

drop trigger if exists diet_plans_sync_supplements_from_json on public.diet_plans;
create trigger diet_plans_sync_supplements_from_json
after insert or update of supplements on public.diet_plans
for each row execute function public.sync_diet_plan_supplements_from_json();

drop policy if exists "diet_plan_supplements_select_scoped" on public.diet_plan_supplements;
create policy "diet_plan_supplements_select_scoped"
on public.diet_plan_supplements for select
using (
  exists (
    select 1
    from public.diet_plans dp
    where dp.id = diet_plan_supplements.diet_plan_id
      and (
        dp.student_id = auth.uid()
        or (dp.trainer_id = auth.uid() and public.is_trainer_for(dp.student_id))
      )
  )
);

drop policy if exists "diet_plan_supplements_write_linked_trainer" on public.diet_plan_supplements;
create policy "diet_plan_supplements_write_linked_trainer"
on public.diet_plan_supplements for all
using (
  exists (
    select 1
    from public.diet_plans dp
    where dp.id = diet_plan_supplements.diet_plan_id
      and dp.trainer_id = auth.uid()
      and public.is_trainer_for(dp.student_id)
  )
)
with check (
  created_by = auth.uid()
  and exists (
    select 1
    from public.diet_plans dp
    where dp.id = diet_plan_supplements.diet_plan_id
      and dp.trainer_id = auth.uid()
      and public.is_trainer_for(dp.student_id)
  )
);

grant select, insert, update, delete on public.diet_plan_supplements to authenticated;

select 'Monolith supplement plan ready' as status, now() as checked_at;
