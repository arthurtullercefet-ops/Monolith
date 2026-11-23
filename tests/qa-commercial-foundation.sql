-- Transactional integration assertions. Harness wraps migration + this file in
-- BEGIN/ROLLBACK. Uses existing trainer identities; creates no Auth users.
-- Never run without the explicit rollback harness.
create temporary table commercial_test_context (trainer uuid, other_trainer uuid, auth_count bigint);
insert into commercial_test_context
select (array_agg(id order by id))[1], (array_agg(id order by id))[2], (select count(*) from auth.users)
from public.profiles where role in ('trainer_basic','trainer_plus') and access_mode='authenticated';
do $$ begin
  if (select other_trainer is null from commercial_test_context) then
    raise exception 'Tests require two existing trainer identities';
  end if;
end $$;
grant select on commercial_test_context to authenticated, service_role;

-- RED was observed before implementation: current-account RPC did not exist.

do $$ declare prices jsonb; begin
  select jsonb_object_agg(plan_key || '_' || market, monthly_price_minor) into prices from public.app_plan_prices;
  assert prices @> '{"trainer_basic_US":3499,"trainer_pro_US":4999,"trainer_basic_BR":2990,"trainer_pro_BR":3990}'::jsonb, 'regional prices';
  assert (select features from public.app_plans where key='trainer_basic') = (select features from public.app_plans where key='trainer_pro'), 'same core features';
  assert not exists(select 1 from public.app_plans where key in ('student_monthly','trainer_plus','influencer_free') and is_public), 'legacy products hidden, not deleted';
  assert (select count(*) from auth.users) = (select auth_count from commercial_test_context), 'no Auth users created';
end $$;

select set_config('request.jwt.claim.sub',(select trainer::text from commercial_test_context),true);
set local role authenticated;
do $$ declare s jsonb; begin
  s:=public.get_monolith_commercial_state();
  assert (s->>'student_limit')::int >= 15, 'existing capacity preserved';
  assert s->>'source'='legacy', 'legacy access explicitly marked';
  assert (s->>'checkout_available')::boolean=false, 'no false checkout';
  assert (s->'policy'->>'student_access_included')::boolean, 'student included';
  assert (s->'policy'->>'discovery_free')::boolean, 'discovery free';
  begin
    insert into public.subscriptions(user_id,plan_key,status,provider,current_period_start,current_period_end)
      values(auth.uid(),'trainer_pro','active','stripe',now(),now()+interval '1 month');
    raise exception 'client self-activation accepted';
  exception when insufficient_privilege then null; end;
  begin
    update public.app_plan_prices set monthly_price_minor=1;
    raise exception 'client catalog editing accepted';
  exception when insufficient_privilege then null; end;
  begin
    insert into public.trainer_access_grants(trainer_id,grant_kind,student_limit,plan_key)
      values(auth.uid(),'beta',500,'trainer_pro');
    raise exception 'client grant editing accepted';
  exception when insufficient_privilege then null; end;
  begin
    perform public.preview_monolith_referral_commission(auth.uid(),'USD',1000,0,0,0);
    raise exception 'client commission preview accepted';
  exception when insufficient_privilege then null; end;
end $$;
reset role;

-- No current grant: do not infer Pro from a privileged role.
update public.trainer_access_grants set revoked_at=now()
where trainer_id=(select other_trainer from commercial_test_context);
select set_config('request.jwt.claim.sub',(select other_trainer::text from commercial_test_context),true);
set local role authenticated;
do $$ declare s jsonb; begin
  s:=public.get_monolith_commercial_state();
  assert (s->>'student_limit')::int=0, 'no role-based paid quota';
  begin
    perform public.create_managed_student('Transactional quota fixture',null,null,null,null,null,gen_random_uuid());
    raise exception 'no-subscription activation accepted';
  exception when raise_exception then
    if sqlerrm <> 'MONOLITH_SUBSCRIPTION_REQUIRED' then raise; end if;
  end;
end $$;
reset role;

-- A granted beta allowance overrides the commercial seat count without changing identity.
update public.trainer_access_grants set revoked_at=null,grant_kind='beta',student_limit=5,plan_key='trainer_basic'
where trainer_id=(select other_trainer from commercial_test_context);
select set_config('request.jwt.claim.sub',(select other_trainer::text from commercial_test_context),true);
set local role authenticated;
do $$ declare s jsonb; begin
  s:=public.get_monolith_commercial_state();
  assert (s->>'student_limit')::int=5 and s->>'source'='beta', 'explicit beta seats';
  assert (select count(*) from public.trainer_access_grants)=1, 'grant self scope';
end $$;
reset role;

-- Basic: active managed/authenticated links use the same authoritative count.
select set_config('request.jwt.claim.sub',(select trainer::text from commercial_test_context),true);
set local role authenticated;
do $$ declare s jsonb; request_id uuid:=gen_random_uuid(); a uuid; b uuid; begin
  s:=public.get_monolith_commercial_state();
  while (s->>'active_students')::int < (s->>'student_limit')::int loop
    a:=public.create_managed_student('Transactional seat fixture',null,null,null,null,null,request_id);
    b:=public.create_managed_student('Transactional seat fixture',null,null,null,null,null,request_id);
    assert a=b, 'managed creation retry idempotent';
    request_id:=gen_random_uuid();
    s:=public.get_monolith_commercial_state();
  end loop;
  assert not (s->>'can_add_student')::boolean, 'full plan state';
  begin
    perform public.create_managed_student('Over limit fixture',null,null,null,null,null,gen_random_uuid());
    raise exception 'Basic extra activation accepted';
  exception when raise_exception then
    if sqlerrm <> 'MONOLITH_STUDENT_LIMIT' then raise; end if;
  end;
end $$;
reset role;

-- Verified server-owned subscription raises quota; role and Space are unchanged.
create temporary table commercial_test_identity as
select id,role,space_enabled from public.profiles where id=(select trainer from commercial_test_context);
-- Historical active/provider fields alone are not proof of server verification.
insert into public.subscriptions(user_id,plan_key,status,provider,current_period_start,current_period_end)
select trainer,'trainer_pro','active','stripe',now()-interval '1 minute',now()+interval '1 month' from commercial_test_context;
set local role authenticated;
do $$ begin
  assert (public.get_monolith_commercial_state()->>'student_limit')::int=15, 'unverified historical subscription grants no paid quota';
end $$;
reset role;
delete from public.subscriptions where user_id=(select trainer from commercial_test_context) and plan_key='trainer_pro';
insert into public.subscriptions(user_id,plan_key,status,provider,current_period_start,current_period_end,server_verified_at)
select trainer,'trainer_pro','active','stripe',now()-interval '1 minute',now()+interval '1 month',now() from commercial_test_context;
set local role authenticated;
do $$ declare s jsonb; begin
  s:=public.get_monolith_commercial_state();
  assert (s->>'student_limit')::int=50 and s->>'plan_key'='trainer_pro' and s->>'source'='subscription', 'paid Pro capacity';
  while (s->>'active_students')::int < 50 loop
    perform public.create_managed_student('Transactional Pro fixture',null,null,null,null,null,gen_random_uuid());
    s:=public.get_monolith_commercial_state();
  end loop;
  begin
    perform public.create_managed_student('Over Pro fixture',null,null,null,null,null,gen_random_uuid());
    raise exception 'Pro 51st activation accepted';
  exception when raise_exception then
    if sqlerrm <> 'MONOLITH_STUDENT_LIMIT' then raise; end if;
  end;
end $$;
reset role;
do $$ begin
  assert not exists(select 1 from public.profiles p join commercial_test_identity b using(id)
    where (p.role,p.space_enabled) is distinct from (b.role,b.space_enabled)), 'role and Space preserved';
end $$;

-- Expiration preserves history but prevents new seats; past_due is not paid access.
update public.subscriptions set current_period_start=now()-interval '2 months', current_period_end=now()-interval '1 day'
where user_id=(select trainer from commercial_test_context) and plan_key='trainer_pro';
set local role authenticated;
do $$ declare s jsonb; begin
  s:=public.get_monolith_commercial_state();
  assert (s->>'student_limit')::int=15 and (s->>'active_students')::int=50, 'downgrade preserves 50 links';
  assert (s->>'over_limit')::boolean and not (s->>'can_add_student')::boolean, 'over quota read-only capacity';
  begin
    perform public.create_managed_student('Expired Pro fixture',null,null,null,null,null,gen_random_uuid());
    raise exception 'expired Pro activation accepted';
  exception when raise_exception then
    if sqlerrm <> 'MONOLITH_STUDENT_LIMIT' then raise; end if;
  end;
end $$;
reset role;
update public.subscriptions set status='past_due',current_period_end=now()+interval '1 month'
where user_id=(select trainer from commercial_test_context) and plan_key='trainer_pro';
set local role authenticated;
do $$ begin
  assert (public.get_monolith_commercial_state()->>'student_limit')::int=15, 'past_due grants no purchased quota';
end $$;
reset role;

-- Exact commission arithmetic: net basis, rounding, zero, invalid inputs and agreements.
set local role service_role;
do $$ declare s jsonb; partner uuid; begin
  select trainer into partner from commercial_test_context;
  s:=public.preview_monolith_referral_commission(partner,'USD',4999,0,0,0);
  assert (s->>'rate_bps')::int=1500 and (s->>'commission_minor')::bigint=750, 'US Pro 15 percent half-up';
  s:=public.preview_monolith_referral_commission(partner,'BRL',2990,0,0,0);
  assert (s->>'commission_minor')::bigint=449, 'BR Basic half-up';
  s:=public.preview_monolith_referral_commission(partner,'BRL',3990,100,200,500);
  assert (s->>'eligible_minor')::bigint=3190 and (s->>'commission_minor')::bigint=479, 'net eligible basis';
  assert (public.preview_monolith_referral_commission(partner,'USD',4999,0,0,4999)->>'commission_minor')::bigint=0, 'fully refunded';
  begin
    perform public.preview_monolith_referral_commission(partner,'USD',4999,-1,0,0);
    raise exception 'negative fee accepted';
  exception when invalid_parameter_value then null; end;
  begin
    perform public.preview_monolith_referral_commission(partner,'USD',10,5,5,1);
    raise exception 'excess deductions accepted';
  exception when invalid_parameter_value then null; end;
end $$;
reset role;
insert into public.influencer_commission_terms(influencer_id,commission_bps,agreement_reference)
select trainer,1800,'Transactional legacy agreement' from commercial_test_context;
set local role service_role;
do $$ declare s jsonb; begin
  s:=public.preview_monolith_referral_commission((select trainer from commercial_test_context),'USD',4999,0,0,0);
  assert (s->>'rate_bps')::int=1800 and (s->>'commission_minor')::bigint=900, 'explicit agreement preserved';
end $$;
reset role;

-- Anonymous access to account state and all private helpers remains denied.
select set_config('request.jwt.claim.sub','',true);
set local role anon;
do $$ begin
  begin perform public.get_monolith_commercial_state(); raise exception 'anonymous state accepted';
  exception when insufficient_privilege then null; end;
end $$;
reset role;
do $$ begin
  assert (select count(*) from auth.users)=(select auth_count from commercial_test_context), 'no Auth side effects';
end $$;
-- Harness must ROLLBACK all DDL and fixture rows after these assertions.

