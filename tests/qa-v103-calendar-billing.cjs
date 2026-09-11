const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { chromium } = require("playwright");

const baseUrl = process.env.BASE_URL || "http://127.0.0.1:4174/";
const artifactDir = path.resolve(__dirname, "..", "artifacts", "qa-v103");

async function launchBrowser() {
  try {
    return await chromium.launch({ headless: true, channel: "chrome" });
  } catch (_) {
    return chromium.launch({ headless: true });
  }
}

async function loginDemo(page, role) {
  await page.goto(`${baseUrl}?qa=monolith-v104`, { waitUntil: "domcontentloaded" });
  await page.locator("#loginEmail").fill(`${role}@monolith.app`);
  await page.locator("#loginPassword").fill("123456");
  await page.locator("#loginButton").click();
  await page.waitForFunction(() => document.body.classList.contains("authenticated"));
}

async function main() {
  fs.mkdirSync(artifactDir, { recursive: true });
  const browser = await launchBrowser();
  const context = await browser.newContext({ viewport: { width: 1440, height: 900 } });
  const page = await context.newPage();
  const pageErrors = [];
  page.on("pageerror", error => pageErrors.push(error.message));

  try {
    await loginDemo(page, "personal");
    const hooks = await page.evaluate(() => ({
      build: window.MONOLITH_BUILD,
      money: ["150,00", "1.234,56", "1,234.56", "-10", "abc"].map(value => window.monolithBillingTest.parseMoneyMinor(value)),
      scheduleHook: typeof window.monolithRenderSchedule,
      billingHook: typeof window.monolithRenderBilling
    }));
    assert.equal(hooks.build, "monolith-v104-final-qa-fixes");
    assert.deepEqual(hooks.money, [15000, 123456, 123456, null, null]);
    assert.equal(hooks.scheduleHook, "function");
    assert.equal(hooks.billingHook, "function");
    await page.waitForFunction(() => document.activeElement?.id === "mainContent");
    assert.notEqual(await page.locator(".skip-link").evaluate(element => document.activeElement === element), true);

    await page.evaluate(() => showScreen("schedule", { skipDirtyGuard: true }));
    await page.locator("#newAppointmentButton").click();
    const tomorrow = await page.evaluate(() => {
      const date = new Date();
      date.setDate(date.getDate() + 1);
      return new Date(date.getTime() - date.getTimezoneOffset() * 60000).toISOString().slice(0, 10);
    });
    await page.locator("#appointmentStudent").selectOption("aluno-demo");
    await page.locator("#appointmentType").selectOption("in_person_training");
    await page.locator("#appointmentDate").fill(tomorrow);
    await page.locator("#appointmentTime").fill("10:30");
    await page.locator("#appointmentDuration").fill("60");
    await page.locator("#appointmentSharedNotes").fill("Bring water");
    await page.locator("#appointmentPrivateNotes").fill("PRIVATE QA NOTE");
    await page.locator("#saveAppointmentButton").click();
    await page.waitForFunction(() => !document.getElementById("appointmentModal").classList.contains("active"));
    await page.waitForFunction(() => document.getElementById("scheduleCalendar").innerText.includes("Aluno Demo"));
    await page.screenshot({ path: path.join(artifactDir, "trainer-schedule.png"), fullPage: true });
    await page.locator("#scheduleCalendar [data-appointment-id]").first().click();
    assert.match(await page.locator("#appointmentDetails").innerText(), /PRIVATE QA NOTE/);

    await page.evaluate(() => showScreen("payments", { skipDirtyGuard: true }));
    await page.locator("#billingDefaultAmount").fill("150.00");
    await page.locator("#billingDefaultCurrency").selectOption("USD");
    await page.locator("#billingDefaultType").selectOption("monthly");
    await page.locator("#billingDefaultDescription").fill("Monthly coaching");
    await page.locator("#saveBillingDefaultsButton").click();
    await page.waitForFunction(() => window.monolithBillingTest.state.settings?.amountMinor === 15000);
    await page.locator("#prepareChargesButton").click();
    assert.equal(await page.locator("#billingPreviewList input:checked").count(), 1);
    await page.locator("#confirmBillingPreview").click();
    await page.waitForFunction(() => document.querySelectorAll("#billingList .billing-row").length === 1);
    assert.match(await page.locator("#billingList").innerText(), /150[,.]00/);

    await page.locator('[data-billing-action="payment"]').click();
    await page.locator("#paymentAmount").fill("50.00");
    await page.locator("#paymentMethod").selectOption("bank_transfer");
    await page.locator("#paymentPrivateNotes").fill("PRIVATE PAYMENT NOTE");
    await page.locator("#paymentReceiptForm button[type=submit]").click();
    await page.waitForFunction(() => document.getElementById("billingList").innerText.includes("50"));
    await page.locator("#billingList details summary").click();
    const trainerBillingText = await page.locator("#billingList").innerText();
    assert.match(trainerBillingText, /Atrasado/);
    assert.match(trainerBillingText, /Transferência bancária/);

    await page.screenshot({ path: path.join(artifactDir, "trainer-payments.png"), fullPage: true });

    await page.evaluate(() => {
      localStorage.setItem("monolith.sessionUserId", "aluno-demo");
      applyAuthState();
      showScreen("schedule", { skipDirtyGuard: true });
    });
    await page.waitForFunction(() => document.getElementById("scheduleCalendar").innerText.includes("Aluno Demo"));
    await page.locator("#scheduleCalendar [data-appointment-id]").first().click();
    const studentAppointmentText = await page.locator("#appointmentDetails").innerText();
    assert.doesNotMatch(studentAppointmentText, /PRIVATE QA NOTE/);
    assert.match(studentAppointmentText, /Confirmar presença/);
    await page.locator('[data-appointment-action="confirm"]').click();
    await page.waitForFunction(() => document.getElementById("appointmentDetails").innerText.includes("Confirmado"));

    await page.locator('[data-appointment-action="request-reschedule"]').click();
    const proposedDate = await page.evaluate(date => {
      const value = new Date(`${date}T12:00:00Z`);
      value.setUTCDate(value.getUTCDate() + 1);
      return value.toISOString().slice(0, 10);
    }, tomorrow);
    await page.locator("#rescheduleReason").fill("Need a different time");
    await page.locator("#rescheduleSlot1").fill(`${proposedDate}T11:45`);
    await page.locator("#rescheduleRequestForm button[type=submit]").click();
    await page.waitForFunction(() => !document.getElementById("rescheduleRequestModal").classList.contains("active"));
    await page.waitForFunction(() => document.getElementById("appointmentDetails").innerText.includes("Need a different time"));
    await page.locator("#closeAppointmentDetails").click();

    await page.evaluate(() => {
      localStorage.setItem("monolith.sessionUserId", "personal-demo");
      applyAuthState();
      showScreen("schedule", { skipDirtyGuard: true });
    });
    await page.waitForFunction(() => document.getElementById("scheduleCalendar").innerText.includes("Aluno Demo"));
    await page.locator("#scheduleCalendar [data-appointment-id]").first().click();
    await page.locator('[data-appointment-action="accept-request"]').click();
    await page.waitForFunction(() => document.getElementById("actionConfirmationModal").classList.contains("active"));
    assert.equal(await page.locator("#actionConfirmationSelect option").count(), 1);
    await page.locator("#confirmActionConfirmation").click();
    await page.waitForFunction(() => document.getElementById("appointmentModal").classList.contains("active"));
    assert.equal(await page.locator("#appointmentDate").inputValue(), proposedDate);
    assert.equal(await page.locator("#appointmentTime").inputValue(), "11:45");
    await page.locator("#saveAppointmentButton").click();
    await page.waitForFunction(() => !document.getElementById("appointmentModal").classList.contains("active"));
    const rescheduleState = await page.evaluate(() => ({
      statuses: window.monolithScheduleTest.state.appointments.map(item => item.status),
      requestStatuses: window.monolithScheduleTest.state.requests.map(item => item.status)
    }));
    assert.ok(rescheduleState.statuses.includes("rescheduled"));
    assert.ok(rescheduleState.statuses.includes("awaiting_confirmation"));
    assert.ok(rescheduleState.requestStatuses.includes("accepted"));

    await page.evaluate(() => {
      localStorage.setItem("monolith.sessionUserId", "aluno-demo");
      applyAuthState();
      showScreen("schedule", { skipDirtyGuard: true });
    });
    await page.waitForFunction(() => document.getElementById("scheduleCalendar").innerText.includes("Aluno Demo"));
    const studentScheduleText = await page.locator("#schedule").innerText();
    assert.doesNotMatch(studentScheduleText, /PRIVATE QA NOTE/);
    assert.equal(await page.locator("#appointmentDetailsPanel").isHidden(), true);

    await page.setViewportSize({ width: 390, height: 844 });
    const mobileSchedule = await page.evaluate(() => ({
      pageWidth: document.documentElement.scrollWidth,
      viewportWidth: document.documentElement.clientWidth,
      visible: document.getElementById("schedule").classList.contains("active")
    }));
    assert.equal(mobileSchedule.visible, true);
    assert.ok(mobileSchedule.pageWidth <= mobileSchedule.viewportWidth + 2, `mobile schedule overflowed: ${JSON.stringify(mobileSchedule)}`);
    await page.screenshot({ path: path.join(artifactDir, "student-schedule-mobile.png"), fullPage: true });
    await page.locator('[data-schedule-view="month"]').click();
    await page.waitForSelector("#scheduleCalendar .schedule-month");
    const mobileMonth = await page.locator("#scheduleCalendar").evaluate(element => ({
      clientWidth: element.clientWidth,
      scrollWidth: element.scrollWidth,
      overflowX: getComputedStyle(element).overflowX,
      pageWidth: document.documentElement.scrollWidth,
      viewportWidth: document.documentElement.clientWidth
    }));
    assert.equal(mobileMonth.overflowX, "auto");
    assert.ok(mobileMonth.scrollWidth > mobileMonth.clientWidth);
    assert.ok(mobileMonth.pageWidth <= mobileMonth.viewportWidth + 2);
    assert.equal(await page.locator(".skip-link").evaluate(element => document.activeElement === element), false);
    await page.screenshot({ path: path.join(artifactDir, "student-schedule-month-mobile.png"), fullPage: true });

    await page.setViewportSize({ width: 1440, height: 900 });

    await page.evaluate(() => showScreen("payments", { skipDirtyGuard: true }));
    await page.waitForFunction(() => document.querySelectorAll("#billingList .billing-row").length === 1);
    const studentBillingText = await page.locator("#billingList").innerText();
    assert.match(studentBillingText, /Atrasado/);
    assert.doesNotMatch(studentBillingText, /Transferência bancária|PRIVATE PAYMENT NOTE|Registrar pagamento|Editar cobrança/);

    const translations = await page.evaluate(async () => {
      const result = {};
      for (const language of ["en", "es"]) {
        applyLanguage(language);
        await showScreen("schedule", { skipDirtyGuard: true });
        result[`${language}Schedule`] = document.getElementById("schedule").innerText;
        await showScreen("payments", { skipDirtyGuard: true });
        result[`${language}Payments`] = document.getElementById("payments").innerText;
      }
      return result;
    });
    assert.match(translations.enSchedule, /Schedule|My appointments/);
    assert.doesNotMatch(translations.enSchedule, /Novo compromisso|Pendências da agenda|Pedir remarcação/);
    assert.match(translations.enPayments, /Payments|Manual tracking/);
    assert.doesNotMatch(translations.enPayments, /Configuração padrão|Vencimento|Recebido/);
    assert.match(translations.esSchedule, /Agenda|Mis citas/);
    assert.doesNotMatch(translations.esSchedule, /Novo compromisso|Pedir remarcação/);
    assert.match(translations.esPayments, /Pagos|Control manual/);

    await page.setViewportSize({ width: 390, height: 844 });
    await page.evaluate(() => showScreen("payments", { skipDirtyGuard: true }));
    const mobile = await page.evaluate(() => ({
      pageWidth: document.documentElement.scrollWidth,
      viewportWidth: document.documentElement.clientWidth,
      visible: document.getElementById("payments").classList.contains("active")
    }));
    assert.equal(mobile.visible, true);
    assert.ok(mobile.pageWidth <= mobile.viewportWidth + 2, `mobile page overflowed: ${JSON.stringify(mobile)}`);
    await page.screenshot({ path: path.join(artifactDir, "student-payments-mobile.png"), fullPage: true });

    const step32 = fs.readFileSync(path.resolve(__dirname, "..", "database", "monolith-production-step-32-trainer-calendar.sql"), "utf8");
    const step33 = fs.readFileSync(path.resolve(__dirname, "..", "database", "monolith-production-step-33-student-billing.sql"), "utf8");
    assert.match(step32, /appointments_select_scoped/);
    assert.match(step32, /student_id = auth\.uid\(\)/);
    assert.match(step32, /revoke all on public\.appointment_series,[\s\S]*from anon, authenticated;/);
    assert.doesNotMatch(step32, /grant select, insert, update on public\.appointment_private_notes/);
    assert.match(step33, /student_charges_select_scoped/);
    assert.match(step33, /Payment exceeds the outstanding balance/);
    assert.match(step33, /trainer_students_set_active_since/);
    assert.match(step33, /v_link\.active_since/);
    assert.match(step33, /student_billing_profiles_trainer_update[\s\S]*monolith_active_trainer_student\(auth\.uid\(\), student_id\)/);
    assert.match(step33, /lifecycle_status = 'open'[\s\S]*for update;/i);
    assert.match(step33, /revoke all on public\.trainer_billing_settings,[\s\S]*from anon, authenticated;/);
    assert.doesNotMatch(step33, /grant select, insert, update on public\.trainer_billing_settings, public\.student_billing_profiles, public\.student_charges/);
    assert.deepEqual(pageErrors, [], `browser errors: ${JSON.stringify(pageErrors)}`);
    console.log("Monolith v103 calendar and billing QA passed.");
  } finally {
    await browser.close();
  }
}

main().catch(error => {
  console.error(error.stack || error);
  process.exitCode = 1;
});
