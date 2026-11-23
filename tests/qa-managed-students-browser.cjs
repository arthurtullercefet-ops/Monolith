const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const root = path.resolve(__dirname,'..');
let playwright;
try { playwright = require('playwright'); } catch {
  playwright = require(require.resolve('playwright',{paths:[path.join(process.env.USERPROFILE,'.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules')]}));
}
async function main() {
  const server=http.createServer((req,res)=>{
    const file=path.join(root,new URL(req.url,'http://localhost').pathname.replace(/^\//,'')||'index.html');
    if(!file.startsWith(root+path.sep)) return res.writeHead(403).end();
    fs.readFile(file,(e,b)=>e?res.writeHead(404).end():res.writeHead(200,{'Content-Type':file.endsWith('.html')?'text/html; charset=utf-8':'text/plain'}).end(b));
  });
  await new Promise(r=>server.listen(0,'127.0.0.1',r));
  const origin=`http://127.0.0.1:${server.address().port}`;
  const executablePath=[process.env.MONOLITH_TEST_BROWSER,'C:/Program Files/Google/Chrome/Application/chrome.exe','C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe'].find(p=>p&&fs.existsSync(p));
  const browser=await playwright.chromium.launch({headless:true,...(executablePath?{executablePath}:{})});
  const context=await browser.newContext({viewport:{width:1280,height:900}});
  await context.route('**/*',r=>new URL(r.request().url()).origin===origin?r.continue():r.abort());
  await context.addInitScript(()=>{
    const rows=JSON.parse(sessionStorage.getItem('mockStudents')||'[]');
    window.mock={rows,calls:[],delay:0,fail:false,authCalls:0,studentLimit:15,planKey:'trainer_basic',commercialDelay:0,commercialError:false};
    const client={
      auth:{getSession:async()=>({data:{session:null}}),onAuthStateChange:()=>({data:{subscription:{unsubscribe(){}}}})},
      from(table) {
        let filters={}; const q={select(){return q},eq(k,v){filters[k]=v;return q},in(){return q},order(){return q},limit(){return q},
          then(resolve){
            const data=table==='profiles'?rows:table==='trainer_students'?rows.map(p=>({student_id:p.id,status:'active',created_at:'2026-10-16T12:00:00Z'})):[];
            return Promise.resolve({data,error:null}).then(resolve);
          }}; return q;
      },
      async rpc(name,payload) {
        if(name==='get_monolith_commercial_state') {
          await new Promise(resolve=>setTimeout(resolve,window.mock.commercialDelay));
          if(window.mock.commercialError) return {data:null,error:{message:'Capacity service unavailable'}};
          return {data:{
          is_trainer:true,plan_key:window.mock.planKey,source:window.mock.studentLimit===0?'none':window.mock.planKey==='trainer_pro'?'subscription':'legacy',student_limit:window.mock.studentLimit,
          active_students:rows.length,can_add_student:rows.length<window.mock.studentLimit,over_limit:rows.length>window.mock.studentLimit,checkout_available:false,
          policy:{student_access_included:true,discovery_free:true,default_commission_bps:1500},
          prices:[
            {plan_key:'trainer_basic',market:'US',currency:'USD',monthly_price_minor:3499,name:'Personal Basic',student_limit:15},
            {plan_key:'trainer_pro',market:'US',currency:'USD',monthly_price_minor:4999,name:'Personal Pro',student_limit:50},
            {plan_key:'trainer_basic',market:'BR',currency:'BRL',monthly_price_minor:2990,name:'Personal Basic',student_limit:15},
            {plan_key:'trainer_pro',market:'BR',currency:'BRL',monthly_price_minor:3990,name:'Personal Pro',student_limit:50}
          ]},error:null};
        }
        if(name!=='create_managed_student') return {data:null,error:{message:'Unsupported fixture RPC: '+name}};
        window.mock.calls.push({name,payload});
        await new Promise(r=>setTimeout(r,window.mock.delay));
        if(window.mock.studentLimit===0) return {data:null,error:{message:'MONOLITH_SUBSCRIPTION_REQUIRED',code:'P0001'}};
        let row=rows.find(p=>p.request===payload.p_request_id);
        if(!row){row={id:'20000000-0000-4000-8000-'+String(rows.length+1).padStart(12,'0'),request:payload.p_request_id,full_name:payload.p_full_name,email:payload.p_email,role:'student',access_mode:'managed',managed_by:'10000000-0000-4000-8000-000000000001',trainer_notes:payload.p_notes};rows.push(row);sessionStorage.setItem('mockStudents',JSON.stringify(rows));}
        if(window.mock.fail){window.mock.fail=false;return {data:null,error:{message:'Network failed after commit'}};}
        return {data:row.id,error:null};
      }
    };
    window.supabase={createClient:()=>client};
  });
  const page=await context.newPage(); const errors=[];
  page.on('pageerror',e=>errors.push(e.message));
  const login=async()=>{
    await page.goto(origin,{waitUntil:'domcontentloaded'});
    await page.waitForFunction(()=>!document.body.classList.contains('auth-resolving'));
    if (!await page.evaluate(()=>document.body.classList.contains('authenticated'))) {
      await page.locator('#loginEmail').fill('personal@monolith.app');
      await page.locator('#loginPassword').fill('123456');
      await page.locator('#loginButton').click();
    }
    await page.waitForFunction(()=>document.body.classList.contains('authenticated'));
    await page.evaluate(()=>{
      const trainer={id:'10000000-0000-4000-8000-000000000001',name:'Isolated trainer',email:'trainer@example.test',role:'personal',source:'supabase',dbRole:'trainer_basic'};
      saveAccounts([trainer]);localStorage.setItem('monolith.sessionUserId',trainer.id);
      renderClientCards([]);
      document.querySelectorAll('.screen').forEach(s=>s.classList.toggle('active',s.id==='clients'));
    });
  };
  try {
    await login();
    await page.locator('#managedStudentButton').click();
    await page.locator('#managedStudentName').fill('Managed <Student>');
    await page.locator('#managedStudentNotes').fill('Trainer-only notes');
    await page.evaluate(()=>{window.mock.delay=120;window.mock.fail=true;document.getElementById('managedStudentForm').requestSubmit();document.getElementById('managedStudentForm').requestSubmit();});
    await page.waitForFunction(()=>!managedStudentPending);
    assert.equal(await page.evaluate(()=>window.mock.calls.length),1,'rapid double submit creates one request');
    assert.match(await page.locator('#managedStudentNotice').innerText(),/Não foi possível confirmar/);
    assert.equal(await page.locator('#studentPlanLimitBadge').innerText(),'0/15','failed confirmation does not optimistically change seat count');
    const request=await page.evaluate(()=>window.mock.calls[0].payload.p_request_id);
    await login();
    await page.locator('#managedStudentButton').click();
    assert.equal(await page.locator('#managedStudentName').inputValue(),'Managed <Student>','pending request survives refresh');
    await page.locator('#saveManagedStudent').click();
    await page.waitForFunction(()=>!managedStudentPending);
    assert.equal(await page.evaluate(()=>window.mock.calls[0].payload.p_request_id),request);
    assert.equal(await page.locator('#clientList .coach-card').count(),1);
    assert.match(await page.locator('#clientList').innerText(),/Sem acesso ao aplicativo/);
    assert.equal(await page.locator('#studentPlanLimitBadge').innerText(),'1/15');
    assert.equal(await page.evaluate(()=>window.mock.rows.length),1);
    assert.equal(await page.evaluate(()=>window.mock.calls[0].payload.p_email),null);
    assert.equal(await page.evaluate(()=>document.querySelector('#clientList h3').textContent),'Managed <Student>','name is safely escaped');
    assert.equal(await page.locator('#clientList [data-student-screen="anamnesis"]').count(),0);
    assert.equal(await page.evaluate(()=>{const id=window.mock.rows[0].id;localStorage.setItem('monolith.sessionUserId',id);return currentAccount();}),null,'managed cache entry cannot become an app session');
    await page.evaluate(()=>localStorage.setItem('monolith.sessionUserId','10000000-0000-4000-8000-000000000001'));
    for(const [language,label] of [['en','No app access'],['es','Sin acceso a la aplicación'],['pt','Sem acesso ao aplicativo']]) {
      await page.evaluate(lang=>{applyLanguage(lang);renderClientCards(studentsForPersonal(currentAccount().id));},language);
      assert.ok((await page.locator('#clientList').innerText()).includes(label));
    }
    await login();
    await page.evaluate(()=>renderClientList());
    assert.equal(await page.locator('#clientList .coach-card').count(),1,'saved student survives refresh');
    assert.equal(await page.locator('#studentPlanLimitBadge').innerText(),'1/15');
    assert.equal(await page.evaluate(async()=>{
      const student=studentsForPersonal(currentAccount().id)[0];student.email='aluno@monolith.app';
      saveAccounts([currentAccount(),student]);await ensureDemoAccounts();
      return studentsForPersonal('10000000-0000-4000-8000-000000000001').filter(s=>s.id===student.id).length;
    }),1,'contact email never controls identity or excludes a managed student');
    // A normal successful creation must refresh authoritative capacity.
    await page.locator('#managedStudentButton').click();
    await page.locator('#managedStudentName').fill('Second managed fixture');
    await page.locator('#saveManagedStudent').click();
    await page.waitForFunction(()=>!managedStudentPending);
    assert.equal(await page.locator('#studentPlanLimitBadge').innerText(),'2/15','normal successful save refreshes capacity');

    // Delayed backend results while Profile is already rendered must refresh its heading.
    await page.evaluate(async()=>{
      renderProfile();
      window.mock.studentLimit=50;window.mock.planKey='trainer_pro';window.mock.commercialDelay=60;
      await loadMonolithCommercialState(currentAccount(),{force:true});
    });
    assert.match(await page.locator('#profilePlan').innerText(),/Personal Pro/,'async read refreshes profile heading');
    await page.evaluate(async()=>{
      window.mock.commercialError=true;
      await loadMonolithCommercialState(currentAccount(),{force:true});
    });
    assert.ok(!(await page.locator('#profilePlan').innerText()).includes('Pro'),'failed refresh removes stale paid heading');

    // A definitive zero-seat rejection must not become a locked retry draft.
    await page.evaluate(async()=>{
      window.mock.commercialError=false;window.mock.studentLimit=0;window.mock.planKey=null;
      await loadMonolithCommercialState(currentAccount(),{force:true});
    });
    await page.locator('#managedStudentButton').click();
    await page.locator('#managedStudentName').fill('Rejected fixture');
    await page.locator('#saveManagedStudent').click();
    await page.waitForFunction(()=>!managedStudentPending);
    assert.match(await page.locator('#managedStudentNotice').innerText(),/Assinatura/i);
    assert.equal(await page.locator('#managedStudentName').evaluate(el=>el.readOnly),false);
    assert.equal(await page.evaluate(()=>managedStudentSubmission),null);
    assert.equal(await page.evaluate(()=>localStorage.getItem(pendingManagedStudentKey(currentAccount()))),null);
    assert.deepEqual(errors,[]);
    console.log('managed students: browser duplicate-submit, ambiguous failure, refresh retry, seat count, escaping, session rejection and PT/EN/ES passed');
  } finally {await context.close();await browser.close();await new Promise(r=>server.close(r));}
}
main().catch(e=>{console.error(e);process.exitCode=1;});
