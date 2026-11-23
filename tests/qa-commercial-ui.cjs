const assert = require('node:assert/strict');
const path = require('node:path');
const { chromium } = require('playwright');
const commercial = require('../assets/monolith-commercial.js');

// Breaks caught: stale loading quota, role-inferred Pro, currency/seat mismatch,
// invalid numeric state, unsafe profile labels and enabled checkout.
const prices = [
  {plan_key:'trainer_basic',market:'US',currency:'USD',monthly_price_minor:3499,name:'Personal Basic',student_limit:15},
  {plan_key:'trainer_pro',market:'US',currency:'USD',monthly_price_minor:4999,name:'Personal Pro',student_limit:50},
  {plan_key:'trainer_basic',market:'BR',currency:'BRL',monthly_price_minor:2990,name:'Personal Basic',student_limit:15},
  {plan_key:'trainer_pro',market:'BR',currency:'BRL',monthly_price_minor:3990,name:'Personal Pro',student_limit:50}
];
const state = {
  is_trainer:true,plan_key:'trainer_pro',source:'subscription',student_limit:50,active_students:16,
  can_add_student:true,over_limit:false,checkout_available:false,
  policy:{student_access_included:true,discovery_free:true,default_commission_bps:1500},prices
};
async function main() {
  assert.match(commercial.formatPrice(prices[2],'pt'),/R\$\s*29,90/);
  assert.match(commercial.formatPrice(prices[0],'en'),/\$34\.99/);
  assert.equal(commercial.capacityView(state,'loaded','pt').badge,'16/50');
  assert.equal(commercial.capacityView(state,'loaded','pt').canAdd,true);
  assert.equal(commercial.capacityView({...state,student_limit:15,can_add_student:false,over_limit:true},'loaded','pt').canAdd,false);
  assert.equal(commercial.capacityView(state,'loading','pt').badge,'—','loading ignores stale quota');
  assert.equal(commercial.capacityView(state,'error','pt').badge,'—','error ignores stale quota');
  assert.equal(commercial.capacityView({...state,student_limit:NaN},'loaded','pt').badge,'—','invalid quota not trusted');
  assert.equal(commercial.capacityView({...state,student_limit:0,active_students:0,can_add_student:false},'loaded','pt').badge,'0/0');
  assert.equal(commercial.capacityView({...state,is_trainer:false},'loaded','en').badge,'Included');
  assert.throws(()=>commercial.formatPrice({...prices[0],currency:'BAD'},'pt'));
  const html=commercial.settingsHTML(state,{status:'loaded',language:'pt'});
  assert.match(html,/Personal Pro/);
  assert.match(html,/R\$[^<]*39,90/);
  assert.match(html,/US\$/);
  const malicious=commercial.settingsHTML({...state,prices:[{...prices[0],name:'<img src=x onerror=alert(1)>'}]},{status:'loaded',language:'pt'});
  assert.ok(!malicious.includes('<img'));
  assert.ok(!commercial.settingsHTML(state,{status:'error',language:'pt'}).includes('34,99'));

  let browser;
  try { browser=await chromium.launch({headless:true,channel:'chrome'}); }
  catch { browser=await chromium.launch({headless:true}); }
  const page=await browser.newPage();
  try {
    await page.setContent('<main id="commercial"></main>');
    await page.addScriptTag({path:path.resolve(__dirname,'../assets/monolith-commercial.js')});
    await page.evaluate(s=>{document.querySelector('#commercial').innerHTML=MonolithCommercial.settingsHTML(s,{status:'loaded',language:'pt'});},state);
    assert.equal(await page.locator('#commercial tbody tr').count(),4);
    assert.equal(await page.locator('#commercial button:not([disabled])').count(),0,'no fake purchase action');
    assert.match(await page.locator('#commercial').innerText(),/15%/);
    assert.match(await page.locator('#commercial').innerText(),/Brasil/);
    assert.match(await page.locator('#commercial').innerText(),/incluído/i);
    await page.evaluate(s=>{document.querySelector('#commercial').innerHTML=MonolithCommercial.settingsHTML(s,{status:'loading',language:'pt'});},state);
    assert.equal(await page.locator('#commercial tbody tr').count(),0,'loading hides stale catalog');
    // Exercise the actual application's account/capacity views, not just helper HTML.
    await page.goto((process.env.BASE_URL || 'http://127.0.0.1:4174/')+'?qa=monolith-v109',{waitUntil:'domcontentloaded'});
    await page.locator('#loginEmail').fill('personal@monolith.app');
    await page.locator('#loginPassword').fill('123456');
    await page.locator('#loginButton').click();
    await page.waitForFunction(()=>document.body.classList.contains('authenticated'));
    await page.waitForTimeout(300);
    await page.locator('.nav-btn[data-screen="profile"]').first().click();
    await page.evaluate(s=>{
      monolithCommercialStates.set(currentAccount().id,{status:'loaded',data:s});
      renderProfile();renderStudentPlanLimit();
    },state);
    assert.equal(await page.locator('#studentPlanLimitBadge').textContent(),'16/50');
    assert.match(await page.locator('#profilePlan').textContent(),/Personal Pro/);
    assert.equal(await page.locator('#commercialAccountSettings tbody tr').count(),4);
    assert.equal(await page.locator('#manageSubscriptionButton').isDisabled(),true);
    await page.screenshot({path:path.resolve(__dirname,'../artifacts/commercial-settings-pt.png'),fullPage:true});
    await page.evaluate(()=>applyLanguage('en'));
    assert.match(await page.locator('#commercialAccountSettings').innerText(),/Brazil/,'catalog refreshes with language');
    await page.evaluate(s=>{
      monolithCommercialStates.set(currentAccount().id,{status:'error',data:s});
      renderProfile();renderStudentPlanLimit();
    },state);
    assert.equal(await page.locator('#studentPlanLimitBadge').textContent(),'—');
    assert.equal(await page.locator('#commercialAccountSettings tbody tr').count(),0);
    await page.evaluate(()=>{
      localStorage.setItem('monolith.sessionUserId','aluno-demo');
      renderProfile();renderStudentPlanLimit();
    });
    assert.match(await page.locator('#commercialAccountSettings').innerText(),/included/i,'account switch hides former trainer subscription');
    assert.equal(await page.locator('#studentPlanLimitPanel').isHidden(),true);
    console.log('commercial UI: currency, quota, loading/error isolation, safe catalog and disabled checkout passed');
  } finally {await browser.close();}
}
main().catch(e=>{console.error(e);process.exitCode=1;});

