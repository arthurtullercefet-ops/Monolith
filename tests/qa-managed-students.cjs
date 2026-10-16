// Entirely in-memory Postgres; never connects to Supabase or sends messages.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { PGlite } = require(process.env.MONOLITH_PGLITE || '@electric-sql/pglite');
const dir = path.join(__dirname, '../database');
const uuid = n => `10000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
async function main() {
  const db = new PGlite();
  await db.exec(`create role anon; create role authenticated; create role service_role bypassrls;
    create schema auth; create schema storage;
    create table auth.users(id uuid primary key, email text, raw_user_meta_data jsonb default '{}');
    create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
    create function auth.role() returns text language sql stable as $$ select coalesce(nullif(current_setting('request.jwt.claim.role',true),''),'authenticated') $$;
    create function auth.jwt() returns jsonb language sql stable as $$ select '{}'::jsonb $$;
    create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);
    create table storage.objects(id uuid primary key default gen_random_uuid(),bucket_id text,name text,owner uuid);
    create function storage.foldername(text) returns text[] language sql immutable as $$ select string_to_array($1,'/') $$;
    grant usage on schema public, auth, storage to authenticated, anon;
    grant execute on all functions in schema auth to authenticated,anon;`);
  const files = ['monolith-supabase-schema.sql', ...fs.readdirSync(dir).filter(f=>/^monolith-production-step-\d+.*\.sql$/.test(f)).sort()];
  for (const file of files) {
    const sql = fs.readFileSync(path.join(dir,file),'utf8').replace(/create extension if not exists "?pgcrypto"?;/gi,'');
    let before;
    if (file.includes('step-35')) {
      await db.query(`insert into auth.users(id,email,raw_user_meta_data) values($1,'existing@example.test','{"full_name":"Existing student"}')`,[uuid(90)]);
      before=(await db.query('select to_jsonb(p) as row from profiles p where id=$1',[uuid(90)])).rows[0].row;
    }
    try { await db.exec(sql); } catch(e) { throw new Error(`${file}: ${e.message}`, {cause:e}); }
    if (before) {
      const after=(await db.query('select to_jsonb(p) as row from profiles p where id=$1',[uuid(90)])).rows[0].row;
      for(const key of Object.keys(before)) assert.deepEqual(after[key],before[key],`existing ${key} preserved`);
      assert.equal(after.auth_user_id,uuid(90));
      await db.exec(fs.readFileSync(path.join(dir,'rollback-step-35-managed-students.sql'),'utf8'));
      await db.exec(sql);
    }
  }
  // Fixture accounts exist ONLY in this ephemeral database.
  for(let n=1;n<=4;n++) await db.query(`insert into auth.users(id,email,raw_user_meta_data) values($1,$2,$3)`, [uuid(n),`fixture${n}@example.test`,JSON.stringify({role:n<4?'trainer_basic':'student',full_name:'Fixture'})]);
  await db.exec(`grant select,insert,update,delete on all tables in schema public to authenticated; grant select on all tables in schema public to anon;`);
  const as = async (n,fn,role='authenticated') => {
    await db.exec(`set role ${role};`);
    await db.query(`select set_config('request.jwt.claim.sub',$1,false)`,[n?uuid(n):'']);
    try { return await fn(); } finally { await db.exec('reset role'); }
  };
  const create = (request,name='Managed fixture',email=null,space=null)=>db.query(`select public.create_managed_student($1,$2,null,null,null,$3,$4) as id`,[name,email,space,uuid(request)]);
  const authBefore=(await db.query('select count(*)::int n from auth.users')).rows[0].n;
  const student=(await as(1,()=>create(100))).rows[0].id;
  assert.equal((await as(1,()=>create(100))).rows[0].id,student,'request retry is idempotent');
  assert.equal((await db.query('select count(*)::int n from auth.users')).rows[0].n,authBefore);
  const row=(await db.query('select * from profiles where id=$1',[student])).rows[0];
  assert.equal(row.auth_user_id,null); assert.equal(row.email,null); assert.equal(row.access_mode,'managed');
  assert.equal(row.managed_by,uuid(1));
  assert.equal((await as(1,()=>db.query('select id from profiles where id=$1',[student]))).rows.length,1);
  assert.equal((await as(2,()=>db.query('select id from profiles where id=$1',[student]))).rows.length,0);
  assert.equal((await as(null,()=>db.query('select id from profiles where id=$1',[student]),'anon')).rows.length,0);
  await assert.rejects(as(4,()=>create(101)),/Only trainers/);
  await assert.rejects(as(null,()=>create(101),'anon'),/permission denied/);
  await as(1,()=>db.query('update profiles set trainer_notes=$1 where id=$2',['Private note',student]));
  await as(2,()=>db.query('update profiles set trainer_notes=$1 where id=$2',['Intrusion',student]));
  assert.equal((await db.query('select trainer_notes from profiles where id=$1',[student])).rows[0].trainer_notes,'Private note');
  await assert.rejects(as(1,()=>db.query("update profiles set access_mode='authenticated',auth_user_id=id where id=$1",[student])),/immutable/);
  await assert.rejects(as(1,()=>db.query('update profiles set managed_by=$1 where id=$2',[uuid(2),student])),/immutable/);
  await assert.rejects(db.query("insert into trainer_students(trainer_id,student_id) values($1,$2)",[uuid(2),student]),/cannot be shared/);
  // Simulate a forged managed ID in a JWT: no real Auth identity exists and RLS denies it.
  await db.exec('set role authenticated');
  await db.query("select set_config('request.jwt.claim.sub',$1,false)",[student]);
  assert.equal((await db.query('select id from profiles where id=$1',[student])).rows.length,0);
  await db.exec('reset role');
  await as(1,()=>db.query(`insert into workout_templates(owner_id,assigned_student_id,name,exercises) values($1,$2,'Workout','[]')`,[uuid(1),student]));
  await as(1,()=>db.query(`insert into diet_plans(trainer_id,student_id,month_key,meals) values($1,$2,'2026-10','[]')`,[uuid(1),student]));
  await as(1,()=>db.query(`insert into body_measurements(student_id,measurement_date,weight_kg,notes) values($1,current_date,70,'Assessment')`,[student]));
  await as(1,()=>db.query(`insert into workout_programs(trainer_id,student_id,name,duration_weeks,start_date) values($1,$2,'Program',4,current_date)`,[uuid(1),student]));
  for(const table of ['workout_templates','diet_plans','body_measurements','workout_programs']) {
    assert.equal((await as(2,()=>db.query(`select * from ${table}`))).rows.length,0,`${table} isolated`);
  }
  // Existing billing and calendar RPCs must accept the stable profile ID.
  await as(1,()=>db.query(`select create_monolith_appointment($1,'physical_assessment',current_date,'10:00'::time,30,'UTC',null,null,'Internal reminder',null,$2)`,[student,uuid(200)]));
  await as(1,()=>db.query(`insert into student_billing_profiles(trainer_id,student_id,amount_minor,currency) values($1,$2,10000,'USD')`,[uuid(1),student]));
  await as(1,()=>db.query(`insert into trainer_billing_settings(trainer_id,default_amount_minor) values($1,10000)`,[uuid(1)]));
  await as(1,()=>db.query(`select generate_monolith_student_charges(date_trunc('month',current_date)::date,array[$1::uuid],$2)`,[student,uuid(201)]));
  const charge=(await as(1,()=>db.query('select id from student_charges where student_id=$1',[student]))).rows[0];
  assert.ok(charge);
  await as(1,()=>db.query(`select record_monolith_student_payment($1,1000,now(),'cash',null,'Internal note',$2)`,[charge.id,uuid(202)]));
  for(const table of ['appointments','student_charges','student_payment_receipts']) assert.equal((await as(2,()=>db.query(`select * from ${table}`))).rows.length,0,`${table} isolated`);
  await db.query("select set_config('request.jwt.claim.role','service_role',false)");
  await db.query('update profiles set space_enabled=true where id=$1',[uuid(1)]);
  await db.query("select set_config('request.jwt.claim.role','authenticated',false)");
  await as(1,()=>db.query(`insert into monolith_spaces(owner_id,name,slug) values($1,'Fixture Space','fixture-space')`,[uuid(1)]));
  const space=(await db.query('select id from monolith_spaces where owner_id=$1',[uuid(1)])).rows[0].id;
  const scoped=(await as(1,()=>create(103,'Scoped',null,space))).rows[0].id;
  assert.equal((await db.query('select managed_space_id from profiles where id=$1',[scoped])).rows[0].managed_space_id,space);
  await assert.rejects(as(2,()=>create(104,'Wrong Space',null,space)),/Invalid managed Space owner/);
  await assert.rejects(as(1,()=>db.query('insert into space_memberships(space_id,user_id) values($1,$2)',[space,scoped])),/row-level security/);
  // Seats share the same active link count with a normal authenticated student.
  await db.query(`insert into trainer_students(trainer_id,student_id,status) values($1,$2,'active')`,[uuid(1),uuid(4)]);
  for(let n=0;n<12;n++) await as(1,()=>create(300+n));
  assert.equal((await db.query('select count(distinct student_id)::int n from trainer_students where trainer_id=$1 and status=\'active\'',[uuid(1)])).rows[0].n,15);
  await assert.rejects(as(1,()=>create(400)),/MONOLITH_STUDENT_LIMIT/);
  assert.equal((await db.query('select count(*)::int n from profiles where managed_request_id=$1',[uuid(400)])).rows[0].n,0,'capacity error rolls back the new profile');
  await as(1,()=>db.query("update trainer_students set status='paused' where student_id=$1",[scoped]));
  await as(1,()=>create(401));
  await assert.rejects(db.query("update trainer_students set status='active' where student_id=$1",[scoped]),/MONOLITH_STUDENT_LIMIT/);
  assert.equal((await db.query('select count(*)::int n from auth.users')).rows[0].n,authBefore);
  await assert.rejects(db.exec(fs.readFileSync(path.join(dir,'rollback-step-35-managed-students.sql'),'utf8')),/Rollback refused/);
  await db.exec('rollback');
  assert.equal((await db.query('select count(*)::int n from auth.users')).rows[0].n,authBefore);
  await db.close();
  console.log('managed students: isolated Postgres identity, ownership, RLS, billing, calendar, idempotency and shared capacity passed');
}
main().catch(e=>{ console.error(e); process.exitCode=1; });
