-- Monolith production step 33
-- Manual student billing control. This module records external payments but never processes money.
-- Additive and safe to run more than once after production step 32.

alter table public.trainer_students
  add column if not exists active_since timestamptz;

update public.trainer_students
set active_since = coalesce(active_since, created_at, now())
where active_since is null;

alter table public.trainer_students
  alter column active_since set default now(),
  alter column active_since set not null;

create or replace function public.monolith_set_trainer_student_active_since()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    new.active_since := coalesce(new.active_since, new.created_at, now());
  elsif new.status = 'active' and old.status is distinct from 'active' then
    new.active_since := now();
  elsif new.active_since is null then
    new.active_since := coalesce(old.active_since, new.created_at, now());
  end if;
  return new;
end;
$$;

drop trigger if exists trainer_students_set_active_since on public.trainer_students;
create trigger trainer_students_set_active_since
before insert or update of status, active_since on public.trainer_students
for each row execute function public.monolith_set_trainer_student_active_since();

create table if not exists public.trainer_billing_settings (
  trainer_id uuid primary key references public.profiles(id) on delete cascade,
  default_amount_minor bigint not null default 0 check (default_amount_minor >= 0),
  default_currency text not null default 'USD' check (default_currency ~ '^[A-Z]{3}$'),
  default_charge_type text not null default 'monthly' check (default_charge_type in ('monthly', 'session_package')),
  default_description text,
  default_package_sessions integer check (default_package_sessions is null or default_package_sessions between 1 and 1000),
  default_due_offset_days integer not null default 0 check (default_due_offset_days between -31 and 31),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.student_billing_profiles (
  id uuid primary key default gen_random_uuid(),
  trainer_id uuid not null references public.profiles(id) on delete cascade,
  student_id uuid not null references public.profiles(id) on delete cascade,
  billing_enabled boolean not null default true,
  amount_minor bigint check (amount_minor is null or amount_minor >= 0),
  currency text check (currency is null or currency ~ '^[A-Z]{3}$'),
  charge_type text check (charge_type is null or charge_type in ('monthly', 'session_package')),
  description text,
  package_sessions integer check (package_sessions is null or package_sessions between 1 and 1000),
  cycle_anchor_day integer check (cycle_anchor_day is null or cycle_anchor_day between 1 and 31),
  due_offset_days integer check (due_offset_days is null or due_offset_days between -31 and 31),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (trainer_id, student_id)
);

create table if not exists public.student_charges (
  id uuid primary key default gen_random_uuid(),
  trainer_id uuid not null references public.profiles(id) on delete cascade,
  student_id uuid not null references public.profiles(id) on delete cascade,
  billing_profile_id uuid references public.student_billing_profiles(id) on delete set null,
  competency_month date not null,
  period_start date not null,
  period_end date not null,
  due_date date not null,
  charge_type text not null check (charge_type in ('monthly', 'session_package')),
  description text,
  package_sessions integer check (package_sessions is null or package_sessions between 1 and 1000),
  amount_minor bigint not null check (amount_minor >= 0),
  currency text not null check (currency ~ '^[A-Z]{3}$'),
  lifecycle_status text not null default 'open' check (lifecycle_status in ('open', 'exempt', 'voided')),
  exempt_reason text,
  client_request_id text not null,
  created_by uuid not null references public.profiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (trainer_id, client_request_id),
  unique (trainer_id, student_id, period_start),
  check (date_trunc('month', competency_month)::date = competency_month),
  check (period_end > period_start),
  check ((lifecycle_status = 'exempt' and nullif(btrim(exempt_reason), '') is not null) or lifecycle_status <> 'exempt')
);

create table if not exists public.student_payment_receipts (
  id uuid primary key default gen_random_uuid(),
  charge_id uuid not null references public.student_charges(id) on delete cascade,
  trainer_id uuid not null references public.profiles(id) on delete cascade,
  student_id uuid not null references public.profiles(id) on delete cascade,
  amount_minor bigint not null check (amount_minor > 0),
  paid_at timestamptz not null,
  status text not null default 'posted' check (status in ('posted', 'reversed')),
  reversed_at timestamptz,
  reversed_by uuid references public.profiles(id) on delete set null,
  reversal_reason text,
  client_request_id text not null,
  created_by uuid not null references public.profiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (trainer_id, client_request_id),
  check ((status = 'reversed' and reversed_at is not null and nullif(btrim(reversal_reason), '') is not null) or status = 'posted')
);

create table if not exists public.student_payment_private_details (
  receipt_id uuid primary key references public.student_payment_receipts(id) on delete cascade,
  trainer_id uuid not null references public.profiles(id) on delete cascade,
  payment_method text not null check (payment_method in ('cash', 'bank_transfer', 'pix', 'zelle', 'external_card', 'other')),
  other_method text,
  private_notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check ((payment_method = 'other' and nullif(btrim(other_method), '') is not null) or payment_method <> 'other')
);

create table if not exists public.student_charge_private_notes (
  charge_id uuid primary key references public.student_charges(id) on delete cascade,
  trainer_id uuid not null references public.profiles(id) on delete cascade,
  note text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.student_billing_events (
  id bigint generated always as identity primary key,
  charge_id uuid not null references public.student_charges(id) on delete cascade,
  trainer_id uuid not null references public.profiles(id) on delete cascade,
  student_id uuid not null references public.profiles(id) on delete cascade,
  actor_id uuid references public.profiles(id) on delete set null,
  event_type text not null,
  previous_values jsonb not null default '{}'::jsonb,
  new_values jsonb not null default '{}'::jsonb,
  reason text,
  created_at timestamptz not null default now()
);

create index if not exists student_billing_profiles_trainer_idx on public.student_billing_profiles (trainer_id, billing_enabled, student_id);
create index if not exists student_charges_trainer_competency_idx on public.student_charges (trainer_id, competency_month, due_date);
create index if not exists student_charges_student_idx on public.student_charges (student_id, period_start desc);
create index if not exists student_payment_receipts_charge_idx on public.student_payment_receipts (charge_id, paid_at desc);
create index if not exists student_billing_events_charge_idx on public.student_billing_events (charge_id, created_at desc);

drop trigger if exists trainer_billing_settings_touch_updated_at on public.trainer_billing_settings;
create trigger trainer_billing_settings_touch_updated_at before update on public.trainer_billing_settings
for each row execute function public.touch_updated_at();

drop trigger if exists student_billing_profiles_touch_updated_at on public.student_billing_profiles;
create trigger student_billing_profiles_touch_updated_at before update on public.student_billing_profiles
for each row execute function public.touch_updated_at();

drop trigger if exists student_charges_touch_updated_at on public.student_charges;
create trigger student_charges_touch_updated_at before update on public.student_charges
for each row execute function public.touch_updated_at();

drop trigger if exists student_payment_receipts_touch_updated_at on public.student_payment_receipts;
create trigger student_payment_receipts_touch_updated_at before update on public.student_payment_receipts
for each row execute function public.touch_updated_at();

drop trigger if exists student_payment_private_details_touch_updated_at on public.student_payment_private_details;
create trigger student_payment_private_details_touch_updated_at before update on public.student_payment_private_details
for each row execute function public.touch_updated_at();

drop trigger if exists student_charge_private_notes_touch_updated_at on public.student_charge_private_notes;
create trigger student_charge_private_notes_touch_updated_at before update on public.student_charge_private_notes
for each row execute function public.touch_updated_at();

alter table public.trainer_billing_settings enable row level security;
alter table public.student_billing_profiles enable row level security;
alter table public.student_charges enable row level security;
alter table public.student_payment_receipts enable row level security;
alter table public.student_payment_private_details enable row level security;
alter table public.student_charge_private_notes enable row level security;
alter table public.student_billing_events enable row level security;

drop policy if exists "trainer_billing_settings_owner_all" on public.trainer_billing_settings;
create policy "trainer_billing_settings_owner_all" on public.trainer_billing_settings for all
using (trainer_id = auth.uid())
with check (
  trainer_id = auth.uid()
  and exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.role in ('trainer_basic', 'trainer_plus', 'admin')
  )
);

drop policy if exists "student_billing_profiles_trainer_select" on public.student_billing_profiles;
create policy "student_billing_profiles_trainer_select" on public.student_billing_profiles for select
using (trainer_id = auth.uid());

drop policy if exists "student_billing_profiles_trainer_insert" on public.student_billing_profiles;
create policy "student_billing_profiles_trainer_insert" on public.student_billing_profiles for insert
with check (trainer_id = auth.uid() and public.monolith_active_trainer_student(auth.uid(), student_id));

drop policy if exists "student_billing_profiles_trainer_update" on public.student_billing_profiles;
create policy "student_billing_profiles_trainer_update" on public.student_billing_profiles for update
using (trainer_id = auth.uid())
with check (
  trainer_id = auth.uid()
  and public.monolith_active_trainer_student(auth.uid(), student_id)
);

drop policy if exists "student_charges_select_scoped" on public.student_charges;
create policy "student_charges_select_scoped" on public.student_charges for select
using (trainer_id = auth.uid() or student_id = auth.uid());

drop policy if exists "student_charges_trainer_insert" on public.student_charges;
create policy "student_charges_trainer_insert" on public.student_charges for insert
with check (
  trainer_id = auth.uid()
  and created_by = auth.uid()
  and public.monolith_active_trainer_student(auth.uid(), student_id)
);

drop policy if exists "student_charges_trainer_update" on public.student_charges;
create policy "student_charges_trainer_update" on public.student_charges for update
using (trainer_id = auth.uid()) with check (trainer_id = auth.uid());

drop policy if exists "student_payment_receipts_select_scoped" on public.student_payment_receipts;
create policy "student_payment_receipts_select_scoped" on public.student_payment_receipts for select
using (trainer_id = auth.uid() or student_id = auth.uid());

drop policy if exists "student_payment_private_details_trainer_all" on public.student_payment_private_details;
create policy "student_payment_private_details_trainer_all" on public.student_payment_private_details for all
using (trainer_id = auth.uid()) with check (trainer_id = auth.uid());

drop policy if exists "student_charge_private_notes_trainer_all" on public.student_charge_private_notes;
create policy "student_charge_private_notes_trainer_all" on public.student_charge_private_notes for all
using (trainer_id = auth.uid()) with check (trainer_id = auth.uid());

drop policy if exists "student_billing_events_trainer_select" on public.student_billing_events;
create policy "student_billing_events_trainer_select" on public.student_billing_events for select
using (trainer_id = auth.uid());

create or replace function public.monolith_anchor_date(p_month date, p_anchor_day integer)
returns date
language sql
immutable
as $$
  select make_date(
    extract(year from date_trunc('month', p_month))::integer,
    extract(month from date_trunc('month', p_month))::integer,
    least(greatest(p_anchor_day, 1), extract(day from (date_trunc('month', p_month) + interval '1 month - 1 day'))::integer)
  );
$$;

create or replace function public.generate_monolith_student_charges(
  p_competency_month date,
  p_student_ids uuid[],
  p_client_request_id text
)
returns setof public.student_charges
language plpgsql
security definer
set search_path = public
as $$
declare
  v_trainer_id uuid := auth.uid();
  v_month date := date_trunc('month', p_competency_month)::date;
  v_settings public.trainer_billing_settings%rowtype;
  v_student_id uuid;
  v_link public.trainer_students%rowtype;
  v_profile public.student_billing_profiles%rowtype;
  v_anchor integer;
  v_period_start date;
  v_period_end date;
  v_amount bigint;
  v_currency text;
  v_type text;
  v_description text;
  v_sessions integer;
  v_due_offset integer;
  v_charge public.student_charges%rowtype;
begin
  if v_trainer_id is null or not exists (
    select 1 from public.profiles p where p.id = v_trainer_id and p.role in ('trainer_basic', 'trainer_plus', 'admin')
  ) then raise exception 'Only trainers can generate charges'; end if;
  select * into v_settings from public.trainer_billing_settings where trainer_id = v_trainer_id;
  if not found then raise exception 'Configure billing defaults before generating charges'; end if;
  if cardinality(p_student_ids) is null or cardinality(p_student_ids) = 0 then raise exception 'Select at least one student'; end if;
  if nullif(btrim(p_client_request_id), '') is null then raise exception 'A request key is required'; end if;

  foreach v_student_id in array p_student_ids loop
    select * into v_link from public.trainer_students
    where trainer_id = v_trainer_id and student_id = v_student_id and status = 'active';
    if not found then continue; end if;
    select * into v_profile from public.student_billing_profiles
    where trainer_id = v_trainer_id and student_id = v_student_id;
    if found and not v_profile.billing_enabled then continue; end if;

    v_anchor := coalesce(v_profile.cycle_anchor_day, extract(day from (v_link.active_since at time zone coalesce((select timezone from public.profiles where id = v_trainer_id), 'UTC')))::integer);
    v_period_start := public.monolith_anchor_date(v_month, v_anchor);
    v_period_end := public.monolith_anchor_date((v_month + interval '1 month')::date, v_anchor);
    v_amount := coalesce(v_profile.amount_minor, v_settings.default_amount_minor);
    v_currency := coalesce(v_profile.currency, v_settings.default_currency);
    v_type := coalesce(v_profile.charge_type, v_settings.default_charge_type);
    v_description := coalesce(nullif(btrim(v_profile.description), ''), nullif(btrim(v_settings.default_description), ''), case when v_type = 'monthly' then 'Mensalidade' else 'Pacote de sessões' end);
    v_sessions := case when v_type = 'session_package' then coalesce(v_profile.package_sessions, v_settings.default_package_sessions) else null end;
    v_due_offset := coalesce(v_profile.due_offset_days, v_settings.default_due_offset_days, 0);
    if v_amount is null or v_amount <= 0 then raise exception 'Charge amount must be greater than zero'; end if;

    insert into public.student_charges (
      trainer_id, student_id, billing_profile_id, competency_month, period_start, period_end,
      due_date, charge_type, description, package_sessions, amount_minor, currency,
      client_request_id, created_by
    ) values (
      v_trainer_id, v_student_id, v_profile.id, v_month, v_period_start, v_period_end,
      v_period_start + v_due_offset, v_type, v_description, v_sessions, v_amount, v_currency,
      p_client_request_id || ':' || v_student_id::text, v_trainer_id
    )
    on conflict (trainer_id, student_id, period_start) do nothing
    returning * into v_charge;
    if found then
      insert into public.student_billing_events (charge_id, trainer_id, student_id, actor_id, event_type, new_values)
      values (v_charge.id, v_trainer_id, v_student_id, v_trainer_id, 'charge_created', jsonb_build_object('amount_minor', v_charge.amount_minor, 'currency', v_charge.currency, 'due_date', v_charge.due_date));
      return next v_charge;
    end if;
  end loop;
end;
$$;

create or replace function public.record_monolith_student_payment(
  p_charge_id uuid,
  p_amount_minor bigint,
  p_paid_at timestamptz,
  p_payment_method text,
  p_other_method text,
  p_private_notes text,
  p_client_request_id text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_charge public.student_charges%rowtype;
  v_receipt_id uuid;
  v_paid_minor bigint;
  v_paid_at timestamptz;
begin
  select * into v_charge from public.student_charges
  where id = p_charge_id and trainer_id = auth.uid() and lifecycle_status = 'open'
  for update;
  if not found then raise exception 'Charge not found or not open'; end if;
  if nullif(btrim(p_client_request_id), '') is null then raise exception 'A request key is required'; end if;
  select id into v_receipt_id from public.student_payment_receipts
  where trainer_id = auth.uid() and client_request_id = p_client_request_id;
  if v_receipt_id is not null then
    if not exists (select 1 from public.student_payment_receipts where id = v_receipt_id and charge_id = p_charge_id) then
      raise exception 'Payment request key was already used for another charge';
    end if;
    return v_receipt_id;
  end if;
  if p_amount_minor is null or p_amount_minor <= 0 then raise exception 'Payment amount must be positive'; end if;
  if p_payment_method not in ('cash', 'bank_transfer', 'pix', 'zelle', 'external_card', 'other') then raise exception 'Invalid payment method'; end if;
  if p_payment_method = 'other' and nullif(btrim(p_other_method), '') is null then raise exception 'Describe the payment method'; end if;
  select coalesce(sum(amount_minor), 0) into v_paid_minor
  from public.student_payment_receipts where charge_id = p_charge_id and status = 'posted';
  if v_paid_minor + p_amount_minor > v_charge.amount_minor then raise exception 'Payment exceeds the outstanding balance'; end if;
  v_paid_at := coalesce(p_paid_at, now());

  insert into public.student_payment_receipts (
    charge_id, trainer_id, student_id, amount_minor, paid_at, client_request_id, created_by
  ) values (
    v_charge.id, v_charge.trainer_id, v_charge.student_id, p_amount_minor, v_paid_at, p_client_request_id, auth.uid()
  ) returning id into v_receipt_id;
  insert into public.student_payment_private_details (receipt_id, trainer_id, payment_method, other_method, private_notes)
  values (v_receipt_id, auth.uid(), p_payment_method, nullif(btrim(p_other_method), ''), nullif(btrim(p_private_notes), ''));
  insert into public.student_billing_events (charge_id, trainer_id, student_id, actor_id, event_type, new_values)
  values (v_charge.id, v_charge.trainer_id, v_charge.student_id, auth.uid(), 'payment_recorded', jsonb_build_object('receipt_id', v_receipt_id, 'amount_minor', p_amount_minor, 'paid_at', v_paid_at));
  return v_receipt_id;
end;
$$;

create or replace function public.reverse_monolith_student_payment(p_receipt_id uuid, p_reason text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_receipt public.student_payment_receipts%rowtype;
begin
  if char_length(btrim(coalesce(p_reason, ''))) < 2 then raise exception 'A reversal reason is required'; end if;
  update public.student_payment_receipts
  set status = 'reversed', reversed_at = now(), reversed_by = auth.uid(), reversal_reason = btrim(p_reason)
  where id = p_receipt_id and trainer_id = auth.uid() and status = 'posted'
  returning * into v_receipt;
  if not found then raise exception 'Receipt not found or already reversed'; end if;
  insert into public.student_billing_events (charge_id, trainer_id, student_id, actor_id, event_type, previous_values, reason)
  values (v_receipt.charge_id, v_receipt.trainer_id, v_receipt.student_id, auth.uid(), 'payment_reversed', jsonb_build_object('receipt_id', v_receipt.id, 'amount_minor', v_receipt.amount_minor), btrim(p_reason));
  return v_receipt.id;
end;
$$;

create or replace function public.update_monolith_student_charge(
  p_charge_id uuid,
  p_amount_minor bigint,
  p_due_date date,
  p_description text,
  p_private_notes text,
  p_reason text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_charge public.student_charges%rowtype;
  v_has_receipts boolean;
  v_paid_minor bigint;
begin
  select * into v_charge from public.student_charges where id = p_charge_id and trainer_id = auth.uid() for update;
  if not found then raise exception 'Charge not found'; end if;
  if p_amount_minor is null or p_amount_minor <= 0 then raise exception 'Invalid amount'; end if;
  if p_due_date is null then raise exception 'A due date is required'; end if;
  select exists (select 1 from public.student_payment_receipts where charge_id = p_charge_id and status = 'posted') into v_has_receipts;
  select coalesce(sum(amount_minor), 0) into v_paid_minor
  from public.student_payment_receipts where charge_id = p_charge_id and status = 'posted';
  if p_amount_minor < v_paid_minor then raise exception 'Charge amount cannot be lower than the amount already received'; end if;
  if v_has_receipts and char_length(btrim(coalesce(p_reason, ''))) < 2 then raise exception 'A correction reason is required after receiving a payment'; end if;
  update public.student_charges
  set amount_minor = p_amount_minor, due_date = p_due_date, description = nullif(btrim(p_description), '')
  where id = p_charge_id;
  insert into public.student_charge_private_notes (charge_id, trainer_id, note)
  values (p_charge_id, auth.uid(), coalesce(p_private_notes, ''))
  on conflict (charge_id) do update set note = excluded.note, updated_at = now();
  insert into public.student_billing_events (charge_id, trainer_id, student_id, actor_id, event_type, previous_values, new_values, reason)
  values (
    v_charge.id, v_charge.trainer_id, v_charge.student_id, auth.uid(), 'charge_adjusted',
    jsonb_build_object('amount_minor', v_charge.amount_minor, 'due_date', v_charge.due_date, 'description', v_charge.description),
    jsonb_build_object('amount_minor', p_amount_minor, 'due_date', p_due_date, 'description', p_description),
    nullif(btrim(p_reason), '')
  );
  return p_charge_id;
end;
$$;

create or replace function public.set_monolith_student_charge_exempt(p_charge_id uuid, p_exempt boolean, p_reason text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_charge public.student_charges%rowtype;
begin
  select * into v_charge from public.student_charges where id = p_charge_id and trainer_id = auth.uid() for update;
  if not found then raise exception 'Charge not found'; end if;
  if p_exempt is null then raise exception 'Exemption state is required'; end if;
  if p_exempt and char_length(btrim(coalesce(p_reason, ''))) < 2 then raise exception 'An exemption reason is required'; end if;
  if p_exempt and exists (select 1 from public.student_payment_receipts where charge_id = p_charge_id and status = 'posted') then
    raise exception 'A charge with payments cannot be exempted';
  end if;
  update public.student_charges
  set lifecycle_status = case when p_exempt then 'exempt' else 'open' end,
      exempt_reason = case when p_exempt then btrim(p_reason) else null end
  where id = p_charge_id;
  insert into public.student_billing_events (charge_id, trainer_id, student_id, actor_id, event_type, previous_values, new_values, reason)
  values (
    v_charge.id, v_charge.trainer_id, v_charge.student_id, auth.uid(),
    case when p_exempt then 'charge_exempted' else 'charge_reopened' end,
    jsonb_build_object('lifecycle_status', v_charge.lifecycle_status),
    jsonb_build_object('lifecycle_status', case when p_exempt then 'exempt' else 'open' end),
    nullif(btrim(p_reason), '')
  );
  return p_charge_id;
end;
$$;

revoke all on function public.generate_monolith_student_charges(date, uuid[], text) from public;
revoke all on function public.record_monolith_student_payment(uuid, bigint, timestamptz, text, text, text, text) from public;
revoke all on function public.reverse_monolith_student_payment(uuid, text) from public;
revoke all on function public.update_monolith_student_charge(uuid, bigint, date, text, text, text) from public;
revoke all on function public.set_monolith_student_charge_exempt(uuid, boolean, text) from public;

grant execute on function public.generate_monolith_student_charges(date, uuid[], text) to authenticated;
grant execute on function public.record_monolith_student_payment(uuid, bigint, timestamptz, text, text, text, text) to authenticated;
grant execute on function public.reverse_monolith_student_payment(uuid, text) to authenticated;
grant execute on function public.update_monolith_student_charge(uuid, bigint, date, text, text, text) to authenticated;
grant execute on function public.set_monolith_student_charge_exempt(uuid, boolean, text) to authenticated;

revoke all on public.trainer_billing_settings, public.student_billing_profiles, public.student_charges, public.student_payment_receipts, public.student_payment_private_details, public.student_charge_private_notes, public.student_billing_events from anon, authenticated;
grant select, insert, update on public.trainer_billing_settings, public.student_billing_profiles to authenticated;
grant select on public.student_charges, public.student_payment_receipts, public.student_billing_events to authenticated;
grant select on public.student_payment_private_details, public.student_charge_private_notes to authenticated;

notify pgrst, 'reload schema';

select
  to_regclass('public.trainer_billing_settings') is not null as billing_settings_ready,
  to_regclass('public.student_charges') is not null as student_charges_ready,
  to_regclass('public.student_payment_receipts') is not null as payment_receipts_ready;
