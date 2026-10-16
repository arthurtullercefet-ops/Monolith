// All fixtures live in an ephemeral Postgres. No network or Supabase access.
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const {PGlite}=require(process.env.MONOLITH_PGLITE||'@electric-sql/pglite');
const uuid=n=>`20000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
async function main(){
  const db=new PGlite();
  await db.exec(`create role anon;create role authenticated;create role service_role bypassrls;
    create schema auth;create schema storage;
    create table auth.users(id uuid primary key,email text,raw_user_meta_data jsonb default '{}');
    create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
    create function auth.role() returns text language sql stable as $$ select 'authenticated'::text $$;
    create function auth.jwt() returns jsonb language sql stable as $$ select '{}'::jsonb $$;
    create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);
    create table storage.objects(id uuid primary key default gen_random_uuid(),bucket_id text,name text,owner uuid);
    create function storage.foldername(text) returns text[] language sql immutable as $$ select string_to_array($1,'/') $$;
    grant usage on schema public,auth,storage to authenticated,anon;
    grant execute on all functions in schema auth to authenticated,anon;`);
  const dir=path.join(__dirname,'../database');
  const files=['monolith-supabase-schema.sql',...fs.readdirSync(dir).filter(f=>/^monolith-production-step-\d+.*\.sql$/.test(f)).sort()];
  for(const f of files){
    if(f.includes('step-36')){
      for(let n=1;n<=3;n++) await db.query(`insert into auth.users(id,email,raw_user_meta_data) values($1,$2,$3)`,[uuid(n),`local${n}@example.test`,JSON.stringify({role:n===3?'student':'trainer_basic'})]);
      await db.query(`insert into trainer_students(trainer_id,student_id) values($1,$2)`,[uuid(1),uuid(3)]);
      await db.query(`select set_config('request.jwt.claim.sub',$1,false)`,[uuid(1)]);
      await db.query(`insert into diet_plans(trainer_id,student_id,month_key,calories,meals,publication_status) values($1,$2,'2026-10','2000',$3,null)`,[uuid(1),uuid(3),JSON.stringify([{name:'Existing lunch',items:'100g arroz, 120g frango',calories:'500'}])]);
      await db.query('create temporary table original_diets as select to_jsonb(d) as original from diet_plans d');
    }
    await db.exec(fs.readFileSync(path.join(dir,f),'utf8').replace(/create extension if not exists "?pgcrypto"?;/gi,''));
  }
  const preserved=await db.query(`select (to_jsonb(d)-array['plan_name','variant_key'])=o.original as same from diet_plans d cross join original_diets o`);
  assert.ok(preserved.rows.every(r=>r.same),'all original diet fields preserved');
  await db.exec('grant select,insert,update,delete on all tables in schema public to authenticated;grant select on all tables in schema public to anon;');
  const as=async(n,fn,role='authenticated')=>{await db.exec(`set role ${role}`);await db.query(`select set_config('request.jwt.claim.sub',$1,false)`,[n?uuid(n):'']);try{return await fn();}finally{await db.exec('reset role');}};
  const save=(variant,name,calories,status='published')=>db.query(`insert into diet_plans(trainer_id,student_id,month_key,variant_key,plan_name,calories,meals,publication_status) values($1,$2,'2026-10',$3,$4,$5,$6,$7) on conflict(trainer_id,student_id,month_key,variant_key) do update set plan_name=excluded.plan_name,calories=excluded.calories,meals=excluded.meals,publication_status=excluded.publication_status returning id`,[uuid(1),uuid(3),variant,name,calories,JSON.stringify([{name:'Lunch',items:name==='High Day'?'100g arroz\n120g frango\n100g brócolis':'80g batata\n150g peixe',calories:'500'}]),status]);
  const high=(await as(1,()=>save(uuid(10),'High Day','2600'))).rows[0].id;
  const low=(await as(1,()=>save(uuid(11),'Low Day','1800'))).rows[0].id;
  await as(1,()=>save(uuid(12),'Private draft','2200','draft'));
  assert.equal((await as(1,()=>db.query('select * from diet_plans'))).rows.length,4);
  assert.equal((await as(3,()=>db.query('select * from diet_plans'))).rows.length,3,'student sees legacy + published, never a draft');
  assert.equal((await as(2,()=>db.query('select * from diet_plans'))).rows.length,0);
  assert.equal((await as(null,()=>db.query('select * from diet_plans'),'anon')).rows.length,0);
  assert.equal((await as(1,()=>save(uuid(10),'High Day renamed','2700'))).rows[0].id,high,'renaming retains the same ID');
  assert.equal((await as(1,()=>db.query('select calories from diet_plans where id=$1',[low]))).rows[0].calories,'1800','editing another variant cannot overwrite Low Day');
  await assert.rejects(as(3,()=>db.query("update diet_plans set calories='999' where id=$1 returning id",[high])).then(r=>{assert.equal(r.rows.length,0);throw Error('student write denied');}),/student write denied|row-level security/);
  await assert.rejects(as(2,()=>save(uuid(13),'Other trainer injection','1500')),/row-level security/);
  await assert.rejects(as(1,()=>db.query('update diet_plans set variant_key=$1 where id=$2',[uuid(15),high])),/immutable/);
  for(const v of ['10-12','10–12',' 10 - 12 ','1-100','100','10','']) assert.equal((await db.query('select monolith_prescribed_reps_are_valid($1) ok',[v])).rows[0].ok,true,v);
  for(const v of ['12-10','0-10','10-101','-10','1.5','10-12-15','abc']) assert.equal((await db.query('select monolith_prescribed_reps_are_valid($1) ok',[v])).rows[0].ok,false,v);
  const exercises=reps=>JSON.stringify([{name:'Exercise',sets:[{weight:'50',reps,rest:'90'}]}]);
  await as(1,()=>db.query(`insert into workout_templates(owner_id,assigned_student_id,name,exercises) values($1,$2,'Range workout',$3)`,[uuid(1),uuid(3),exercises('10-12')]));
  await assert.rejects(as(1,()=>db.query(`insert into workout_templates(owner_id,assigned_student_id,name,exercises) values($1,$2,'Invalid range',$3)`,[uuid(1),uuid(3),exercises('12-10')])),/workout_templates_values_check/);
  await assert.rejects(as(3,()=>db.query(`insert into completed_workouts(student_id,workout_name,exercises) values($1,'Performed',$2)`,[uuid(3),exercises('10-12')])),/completed_workouts_values_check/);
  await as(3,()=>db.query(`insert into completed_workouts(student_id,workout_name,exercises) values($1,'Performed',$2)`,[uuid(3),exercises('11')]));
  await as(1,()=>db.query('delete from diet_plans where id=$1',[low]));
  assert.equal((await as(1,()=>db.query('select id from diet_plans where id=$1',[high]))).rows.length,1,'deletion is limited to its selected variant');
  assert.equal((await db.query('select count(*)::int n from auth.users')).rows[0].n,3);
  await db.close();
  console.log('diet variants and rep ranges: isolated Postgres preservation, stable IDs, per-variant edits/deletes, publication RLS and prescription/actual separation passed');
}
main().catch(e=>{console.error(e);process.exitCode=1;});
