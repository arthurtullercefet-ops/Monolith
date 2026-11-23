// Generates an isolated, non-exposed PostgreSQL fixture using the exact production
// helper/trigger bodies with schema qualification rewritten. No Auth or real profiles.
const fs=require('node:fs'),path=require('node:path');
const schema=process.argv[2];
if(!/^monolith_qa_[a-z0-9_]+$/.test(schema||''))throw Error('Explicit QA schema required');
const migration=fs.readFileSync(path.join(__dirname,'../database/monolith-production-step-40-commercial-foundation.sql'),'utf8');
function source(start){
  const a=migration.indexOf(start);if(a<0)throw Error('Production function not found');
  const b=migration.indexOf('$$;',a);if(b<0)throw Error('Function end not found');
  return migration.slice(a,b+3).replaceAll('monolith_private.',schema+'.').replaceAll('public.',schema+'.');
}
const trainer='71000000-0000-4000-8000-000000000001',other='71000000-0000-4000-8000-000000000002';
const a='72000000-0000-4000-8000-000000000001',b='72000000-0000-4000-8000-000000000002',c='72000000-0000-4000-8000-000000000003';
const setup=`create schema ${schema};revoke all on schema ${schema} from public,anon,authenticated;
create type ${schema}.monolith_role as enum('student','trainer_basic','trainer_plus','admin');
create table ${schema}.profiles(id uuid primary key,role ${schema}.monolith_role,access_mode text,managed_by uuid);
create table ${schema}.trainer_students(id uuid primary key default gen_random_uuid(),trainer_id uuid,student_id uuid,status text);
create table ${schema}.trainer_access_grants(trainer_id uuid,student_limit integer,plan_key text,grant_kind text,revoked_at timestamptz,expires_at timestamptz);
create table ${schema}.subscriptions(user_id uuid,plan_key text,status text,provider text,current_period_start timestamptz,current_period_end timestamptz,server_verified_at timestamptz);
create table ${schema}.app_plans(key text,student_limit integer);
insert into ${schema}.profiles values('${trainer}','trainer_basic','authenticated',null),('${other}','trainer_basic','authenticated',null),
('${a}','student','authenticated',null),('${b}','student','authenticated',null),('${c}','student','authenticated',null);
insert into ${schema}.trainer_access_grants values('${trainer}',1,'trainer_basic','beta',null,null),('${other}',1,'trainer_basic','beta',null,null);
${source('create function monolith_private.trainer_commercial_access')}
${source('create or replace function monolith_private.guard_student_capacity')}
create trigger capacity before insert or update on ${schema}.trainer_students for each row execute function ${schema}.guard_student_capacity();
create function ${schema}.try_activate(student uuid,delay_seconds integer) returns jsonb language plpgsql as $$
declare started timestamptz:=clock_timestamp();outcome text;begin
  begin
    insert into ${schema}.trainer_students(trainer_id,student_id,status) values('${trainer}',student,'active');
    outcome:='admitted';perform pg_sleep(delay_seconds);
  exception when raise_exception or feature_not_supported then outcome:=sqlerrm;end;
  return jsonb_build_object('outcome',outcome,'backend_pid',pg_backend_pid(),'started_at',started,'elapsed_ms',extract(epoch from clock_timestamp()-started)*1000);
end $$;
`;
const assertRace=`do $$ begin
assert (select count(*) from ${schema}.trainer_students where trainer_id='${trainer}' and status='active')=1,'two connections consumed one last seat';
insert into ${schema}.trainer_students(trainer_id,student_id,status) values('${other}','${c}','active');
begin
update ${schema}.trainer_students set trainer_id='${trainer}' where trainer_id='${other}';
raise exception 'active reassignment bypassed quota';
exception when raise_exception then if sqlerrm<>'MONOLITH_STUDENT_LIMIT' then raise;end if;end;
end $$;select 'last-seat and reassignment assertions passed' as result;`;
const isolation=`begin isolation level repeatable read;select ${schema}.try_activate('${c}',0) as result;rollback;`;
console.log(JSON.stringify({schema,setup,race:[`select ${schema}.try_activate('${a}',8) as result;`,`select ${schema}.try_activate('${b}',8) as result;`],assertRace,isolation,cleanup:`drop schema ${schema} cascade;`}));

