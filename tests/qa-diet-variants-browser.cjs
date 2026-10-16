// Demo accounts and local browser memory only; every external request is blocked.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),http=require('node:http');
let playwright;try{playwright=require('playwright');}catch{playwright=require(require.resolve('playwright',{paths:[path.join(process.env.USERPROFILE,'.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules')]}));}
async function main(){
  const root=path.resolve(__dirname,'..');
  const server=http.createServer((req,res)=>{const file=path.join(root,new URL(req.url,'http://localhost').pathname.replace(/^\//,'')||'index.html');if(!file.startsWith(root+path.sep))return res.writeHead(403).end();fs.readFile(file,(e,b)=>e?res.writeHead(404).end():res.writeHead(200,{'Content-Type':file.endsWith('.html')?'text/html; charset=utf-8':'text/plain'}).end(b));});
  await new Promise(r=>server.listen(0,'127.0.0.1',r));
  const origin=`http://127.0.0.1:${server.address().port}`;
  const executablePath=[process.env.MONOLITH_TEST_BROWSER,'C:/Program Files/Google/Chrome/Application/chrome.exe','C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe'].find(p=>p&&fs.existsSync(p));
  const browser=await playwright.chromium.launch({headless:true,...(executablePath?{executablePath}:{})});
  const context=await browser.newContext({acceptDownloads:true,viewport:{width:1280,height:1000}});
  await context.route('**/*',r=>new URL(r.request().url()).origin===origin?r.continue():r.abort());
  const page=await context.newPage(),errors=[];page.on('pageerror',e=>errors.push(e.message));
  const confirm=async()=>{await page.locator('#confirmActionConfirmation').click();await page.waitForFunction(()=>!document.getElementById('actionConfirmationModal').classList.contains('active'));};
  try{
    await page.goto(origin,{waitUntil:'domcontentloaded'});
    await page.waitForFunction(()=>!document.body.classList.contains('auth-resolving'));
    await page.locator('#loginEmail').fill('personal@monolith.app');await page.locator('#loginPassword').fill('123456');await page.locator('#loginButton').click();
    await page.waitForFunction(()=>document.body.classList.contains('authenticated'));
    await page.evaluate(async()=>{saveDietPlans({});setSelectedStudentForPersonal('aluno-demo');showScreen('nutrition',{skipDirtyGuard:true});await renderNutrition();clearDirty('diet');});
    const add=async(name,calories,items)=>{
      await page.locator('#newDietVariantButton').click();
      await page.locator('#dietPlanName').fill(name);await page.locator('#dietCalories').fill(calories);
      await page.locator('#dietMealCount').selectOption('1');await page.locator('.meal-items').fill(items);
      const variant=await page.locator('#dietVariant').inputValue();
      await page.locator('#saveDietPlanButton').click();await confirm();
      await page.waitForFunction(key=>Object.values(loadDietPlans()).some(p=>p.variantKey===key),variant);
      await page.locator('#publishDietButton').click();await confirm();
      await page.waitForFunction(key=>Object.values(loadDietPlans()).find(p=>p.variantKey===key)?.status==='published',variant);
      return variant;
    };
    const high=await add('High Day — treino','2600','100g arroz\n120g frango\n100g brócolis');
    const low=await add('Low Day — descanso','1800','80g batata, 150g peixe, legumes');
    assert.notEqual(high,low);assert.equal(await page.evaluate(()=>Object.values(loadDietPlans()).length),2);
    await page.locator('#dietVariant').selectOption(high);
    await page.waitForFunction(()=>document.getElementById('dietPlanName').value==='High Day — treino');
    assert.equal(await page.locator('#dietCalories').inputValue(),'2600');
    assert.deepEqual(await page.locator('#dietPreview .diet-food-items li').allTextContents(),['100g arroz','120g frango','100g brócolis']);
    await page.locator('#dietPlanName').fill('High Day revised');
    await page.locator('#dietVariant').selectOption(low);
    await page.locator('#cancelActionConfirmation').click();
    assert.equal(await page.locator('#dietVariant').inputValue(),high,'cancelled navigation keeps the original diet selected');
    assert.equal(await page.locator('#dietPlanName').inputValue(),'High Day revised');
    await page.locator('#saveDietPlanButton').click();await confirm();
    await page.waitForFunction(()=>Object.values(loadDietPlans()).some(p=>p.name==='High Day revised'));
    assert.equal(await page.evaluate(k=>Object.values(loadDietPlans()).find(p=>p.variantKey===k).calories,low),'1800');
    assert.deepEqual(await page.evaluate(()=>dietFoodLines('1,5g sal, 100g arroz; 120g frango')),['1,5g sal','100g arroz','120g frango']);
    assert.deepEqual(await page.evaluate(()=>dietFoodLines('100g frango, sem pele\n100g arroz')),['100g frango, sem pele','100g arroz']);
    const csv=await page.evaluate(()=>{
      const rows=[dietCsvHeader(),...Object.values(loadDietPlans()).map(p=>['Aluno Demo',p.month,'Almoço',p.meals[0].items,'500','30','50','10','','','','2600','150','300','70',p.name,p.variantKey])];
      const validation=validateDietCsv(rows.map(r=>r.map(csvEscapeDiet).join(';')).join('\n'),'aluno-demo',studentsForPersonal('personal-demo'));
      return {valid:validation.valid,names:validation.plans.map(p=>p.name),keys:validation.plans.map(p=>p.variantKey)};
    });
    assert.ok(csv.valid);assert.equal(csv.names.length,2);assert.ok(csv.keys.includes(high)&&csv.keys.includes(low));
    // Create a range prescription through the real editor.
    await page.evaluate(()=>showScreen('workouts',{skipDirtyGuard:true}));
    await page.locator('#newWorkoutButton').click();
    await page.locator('#workoutStudent').selectOption('aluno-demo');
    await page.locator('#workoutName').fill('Range verification');
    await page.locator('#exerciseBuilder .exercise-name').first().fill('Range exercise');
    await page.setViewportSize({width:390,height:900});
    await page.locator('#exerciseBuilder [data-preset="3x10-12"]').first().click();
    await page.setViewportSize({width:1280,height:1000});
    assert.deepEqual(await page.locator('#exerciseBuilder .set-reps').evaluateAll(nodes=>nodes.map(n=>n.value)),['10-12','10-12','10-12']);
    await page.locator('#exerciseBuilder .set-reps').first().fill('12-10');
    assert.equal(await page.locator('#exerciseBuilder .set-reps').first().evaluate(el=>validateNumericField(el)),false);
    await page.locator('#exerciseBuilder .set-reps').first().fill('10–12');
    assert.equal(await page.locator('#exerciseBuilder .set-reps').first().evaluate(el=>validateNumericField(el)),true);
    await page.locator('#saveWorkoutButton').click();await confirm();
    await page.waitForFunction(()=>!document.getElementById('workoutModal').classList.contains('active'));
    const workout=await page.evaluate(()=>JSON.parse(localStorage.getItem('monolith.workouts')).find(w=>w.name==='Range verification'));
    assert.equal(workout.exercises[0].sets[0].reps,'10-12');
    // Student receives both published diets, with distinct contents and no editing.
    await page.evaluate(async()=>{clearDirty('diet');localStorage.setItem('monolith.sessionUserId','aluno-demo');applyAuthState();showScreen('nutrition',{skipDirtyGuard:true});await renderNutrition();});
    await page.locator('#studentDietVariant').selectOption(low);
    assert.match(await page.locator('#studentDietView').innerText(),/Low Day/);
    assert.deepEqual(await page.locator('#studentDietView .diet-food-items li').allTextContents(),['80g batata','150g peixe','legumes']);
    await page.locator('#studentDietVariant').selectOption(high);
    assert.match(await page.locator('#studentDietView').innerText(),/High Day revised/);
    assert.equal(await page.locator('#studentDietView input').count(),0);
    for(const lang of ['en','es','pt']){await page.evaluate(l=>applyLanguage(l),lang);assert.match(await page.locator('#studentDietView').innerText(),/High Day revised/);}
    const screenshots=path.join(root,'artifacts','diet-variants');fs.mkdirSync(screenshots,{recursive:true});
    await page.locator('#studentDietView').screenshot({path:path.join(screenshots,'student-diet-desktop.png')});
    await page.setViewportSize({width:390,height:900});
    await page.locator('#studentDietView').screenshot({path:path.join(screenshots,'student-diet-mobile.png')});
    await page.setViewportSize({width:1280,height:1000});
    await page.evaluate(()=>showScreen('workouts',{skipDirtyGuard:true}));
    await page.locator(`#workoutList [data-workout-id="${workout.id}"].open-workout-session-v2`).click();
    assert.equal(await page.locator('#sessionExercises .session-reps').first().inputValue(),'','target range is never recorded as actual repetitions');
    assert.match(await page.locator('#sessionExercises td.reps-cell').first().innerText(),/10-12/);
    await page.locator('#sessionExercises .session-reps').first().fill('11');
    await page.locator('#finishExercise').click();
    await page.waitForFunction(()=>JSON.parse(localStorage.getItem('monolith.completedWorkouts')||'[]').some(w=>w.workoutName==='Range verification'));
    const performed=await page.evaluate(()=>JSON.parse(localStorage.getItem('monolith.completedWorkouts')).find(w=>w.workoutName==='Range verification').exercises[0].sets[0]);
    assert.equal(performed.reps,'11');assert.equal(performed.targetReps,'10-12');
    assert.deepEqual(errors,[]);
    console.log('diet variants: browser creation, independent edits, dirty navigation, publication, student selection, food lines, CSV round-trip, PT/EN/ES and rep-range execution passed');
  }finally{await context.close();await browser.close();await new Promise(r=>server.close(r));}
}
main().catch(e=>{console.error(e);process.exitCode=1;});
