const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { chromium } = require("playwright");

const baseUrl = process.env.BASE_URL || "http://127.0.0.1:4174/";
const artifactDir = path.resolve(__dirname, "..", "artifacts", "qa-v100");

async function launchBrowser() {
  try {
    return await chromium.launch({ headless: true, channel: "chrome" });
  } catch (_) {
    return chromium.launch({ headless: true });
  }
}

async function loginDemo(page, role = "personal") {
  await page.goto(`${baseUrl}${baseUrl.includes("?") ? "&" : "?"}qa=monolith-v100`, { waitUntil: "domcontentloaded" });
  await page.locator("#loginEmail").fill(`${role}@monolith.app`);
  await page.locator("#loginPassword").fill("123456");
  await page.locator("#loginButton").click();
  await page.waitForFunction(() => document.body.classList.contains("authenticated"), null, { timeout: 15000 });
}

async function main() {
  fs.mkdirSync(artifactDir, { recursive: true });
  const browser = await launchBrowser();
  const context = await browser.newContext({ acceptDownloads: true, viewport: { width: 1366, height: 768 } });
  const page = await context.newPage();
  const pageErrors = [];
  page.on("pageerror", error => pageErrors.push(error.message));

  try {
    await loginDemo(page, "personal");

    const core = await page.evaluate(async () => {
      setSelectedStudentForPersonal("aluno-demo");
      const accountBefore = currentAccount()?.id;
      const selectedBefore = selectedStudentForPersonal();
      const audits = {};
      const dates = {};
      for (const language of ["pt", "en", "es", "pt"]) {
        applyLanguage(language);
        audits[language] = reportFixedTranslationIssues(language);
        dates[language] = localDateLabel("2026-08-12");
      }
      const accountAfter = currentAccount()?.id;
      const selectedAfter = selectedStudentForPersonal();
      const visibleMenu = [...document.querySelectorAll(".nav-btn[data-screen]")]
        .filter(button => getComputedStyle(button).display !== "none")
        .map(button => button.dataset.screen);
      const personal = currentAccount();
      const accountsBeforeSpaceTest = loadAccounts();
      saveAccounts(accountsBeforeSpaceTest.map(account => account.id === personal.id ? { ...account, spaceEnabled: true } : account));
      applyAuthState();
      const visibleMenuWithSpace = [...document.querySelectorAll(".nav-btn[data-screen]")]
        .filter(button => getComputedStyle(button).display !== "none")
        .map(button => button.dataset.screen);
      saveAccounts(accountsBeforeSpaceTest);
      applyAuthState();
      const student = { id: "aluno-demo", role: "student" };
      const voiceWorkoutExecutable = window.monolithQaHooks.voiceWorkoutExecutable;
      const voiceRules = {
        personalOwn: voiceWorkoutExecutable({ ownerId: personal.id, assignedStudentId: "" }, personal),
        personalManagingStudent: voiceWorkoutExecutable({ ownerId: personal.id, assignedStudentId: "aluno-demo" }, personal),
        studentOwn: voiceWorkoutExecutable({ ownerId: personal.id, assignedStudentId: student.id }, student),
        otherStudent: voiceWorkoutExecutable({ ownerId: personal.id, assignedStudentId: "outro-aluno" }, student)
      };
      const flagLabels = [...document.querySelectorAll(".language-button")].map(button => ({
        label: button.getAttribute("aria-label"),
        flag: button.querySelector(".language-flag")?.className || ""
      }));
      const reportStudent = reportStudentFromId("aluno-demo");
      const spaceModes = {
        migratedDefault: spaceFromRemoteRow({ theme_mode: null }).themeMode,
        explicitCustom: spaceFromRemoteRow({ theme_mode: "space" }).themeMode,
        explicitMonolith: spaceFromRemoteRow({ theme_mode: "monolith" }).themeMode
      };
      saveAccounts(accountsBeforeSpaceTest.map(account => account.id === personal.id ? { ...account, spaceEnabled: true } : account));
      applyAuthState();
      applySpaceTheme({ id: "qa-space", ownerId: personal.id, name: "Superman Performance", slug: "superman", themeMode: "monolith" });
      renderProfile();
      const spaceProfile = {
        visible: !document.getElementById("profileSpaceStatusPanel").hidden,
        upgradeHidden: document.getElementById("profileSpaceUpgradePanel").hidden,
        text: document.getElementById("profileSpaceStatusPanel").innerText
      };
      saveAccounts(accountsBeforeSpaceTest);
      applyAuthState();
      const reportResults = {};
      for (const language of ["pt", "en", "es"]) {
        applyLanguage(language);
        const html = monthlyReportHTML(reportStudent);
        reportResults[language] = {
          length: html.length,
          warning: /Aviso de tradu[cç][aã]o|Translation warning|fixed text is still untranslated/i.test(html)
        };
      }
      applyLanguage("pt");
      await showScreen("stats", { skipDirtyGuard: true });
      document.querySelector('[data-stats-tab="photos"]')?.click();
      await showScreen("home", { skipDirtyGuard: true });
      return {
        build: window.MONOLITH_BUILD,
        accountBefore,
        accountAfter,
        selectedBefore,
        selectedAfter,
        audits,
        dates,
        visibleMenu,
        visibleMenuWithSpace,
        voiceRules,
        flagLabels,
        spaceModes,
        spaceProfile,
        reportResults,
        hashAfterLeavingStats: location.hash
      };
    });

    assert.equal(core.build, "monolith-v100-report-diet-language-space");
    assert.equal(core.accountAfter, core.accountBefore, "language switching changed the authenticated account");
    assert.equal(core.selectedAfter, core.selectedBefore, "language switching changed the selected student");
    assert.deepEqual(core.audits.pt, []);
    assert.deepEqual(core.audits.en, []);
    assert.deepEqual(core.audits.es, []);
    assert.equal(core.dates.pt, "12/08/2026");
    assert.equal(core.dates.en, "8/12/2026");
    assert.equal(core.dates.es, "12/08/2026");
    const expectedMenu = ["home", "alerts", "clients", "workouts", "nutrition", "checkin", "stats", "timeline", "programs", "anamnesis"];
    if (core.visibleMenu.includes("space")) expectedMenu.push("space");
    expectedMenu.push("profile");
    assert.deepEqual(core.visibleMenu, expectedMenu);
    assert.deepEqual(core.visibleMenuWithSpace, ["home", "alerts", "clients", "workouts", "nutrition", "checkin", "stats", "timeline", "programs", "anamnesis", "space", "profile"]);
    assert.deepEqual(core.voiceRules, { personalOwn: true, personalManagingStudent: false, studentOwn: true, otherStudent: false });
    assert.equal(core.flagLabels.length, 6);
    assert.ok(core.flagLabels.some(item => item.label === "Português" && item.flag.includes("flag-br")));
    assert.ok(core.flagLabels.some(item => item.label === "English" && item.flag.includes("flag-us")));
    assert.ok(core.flagLabels.some(item => item.label === "Español" && item.flag.includes("flag-es")));
    assert.deepEqual(core.spaceModes, { migratedDefault: "space", explicitCustom: "space", explicitMonolith: "monolith" });
    assert.equal(core.spaceProfile.visible, true);
    assert.equal(core.spaceProfile.upgradeHidden, true);
    assert.match(core.spaceProfile.text, /Superman Performance/);
    assert.match(core.spaceProfile.text, /superman/);
    assert.equal(core.hashAfterLeavingStats, "#inicio");
    Object.values(core.reportResults).forEach(result => {
      assert.ok(result.length > 1000, "monthly report HTML was not generated");
      assert.equal(result.warning, false, "monthly report still contains a translation warning");
    });

    const languageLeaks = await page.evaluate(async () => {
      const screens = ["home", "alerts", "clients", "workouts", "nutrition", "checkin", "stats", "timeline", "programs", "anamnesis", "profile"];
      const forbidden = {
        pt: ["No check-in", "Open file", "Completed workouts", "Select student", "Needs attention", "Open session", "Duplicate", "Delete", "Meal 1", "Account, password and professional information", "The trainer configures"],
        en: ["Início", "Alertas", "Alunos", "Treinos", "Dietas", "Evolução", "Painel do personal", "Gestão de alunos, pendências e resultados", "Adicionar aluno", "Criar dieta", "Precisam de atenção", "Abrir ficha", "Selecionar aluno", "Sem check-in", "Refeição"],
        es: ["Início", "Alunos", "Treinos", "Evolução", "Select student", "Open file", "Needs attention", "Open session"]
      };
      const leaks = [];
      for (const language of ["pt", "en", "es"]) {
        applyLanguage(language);
        for (const screen of screens) {
          await showScreen(screen, { skipDirtyGuard: true, historyMode: "replace" });
          const visible = `${document.querySelector("aside")?.innerText || ""}\n${document.getElementById(screen)?.innerText || ""}`;
          forbidden[language].forEach(term => {
            if (visible.includes(term)) leaks.push({ language, screen, term, context: visible.split("\n").filter(line => line.includes(term)).slice(0, 4) });
          });
        }
      }
      applyLanguage("pt");
      return leaks;
    });
    assert.deepEqual(languageLeaks, [], `fixed text leaked between languages: ${JSON.stringify(languageLeaks)}`);

    const blockedReport = await page.evaluate(async () => {
      const originalHydration = window.hydrateRemoteReportData;
      window.hydrateRemoteReportData = async () => ({ status: "error", results: [] });
      try {
        return await prepareMonthlyReportHTML(reportStudentFromId("aluno-demo"));
      } finally {
        window.hydrateRemoteReportData = originalHydration;
      }
    });
    assert.deepEqual(blockedReport, { html: "", status: "error" }, "a failed report query was rendered as empty/zero data");

    const reportStates = await page.evaluate(() => {
      setSelectedStudentForPersonal("aluno-demo");
      setRemoteDataState("report", "aluno-demo", "loading");
      renderStatsLoadingState();
      const loadingText = `${document.getElementById("studentContextHeader").innerText}\n${document.getElementById("studentStatsReportSummary").innerText}`;
      const loadingDisabled = document.getElementById("openStatsMonthlyReport").disabled && document.getElementById("downloadStatsMonthlyReport").disabled;
      renderStatsErrorState();
      const retryVisible = Boolean(document.querySelector("#studentStatsReportSummary [data-screen-jump='stats']"));
      setRemoteDataState("report", "aluno-demo", "loaded");
      renderStats();
      setReportControlsState("ready");
      return { loadingText, loadingDisabled, retryVisible };
    });
    assert.equal(reportStates.loadingDisabled, true);
    assert.equal(reportStates.retryVisible, true);
    assert.doesNotMatch(reportStates.loadingText, /0%|0 check-ins|Novo aluno/);

    const languagePersistence = await page.evaluate(async () => {
      await persistLanguagePreference("es");
      applyAuthState();
      const spanish = { cached: currentAccount().language, htmlLang: document.documentElement.lang };
      await persistLanguagePreference("en");
      applyAuthState();
      const english = { cached: currentAccount().language, htmlLang: document.documentElement.lang };
      await persistLanguagePreference("pt");
      applyAuthState();
      const portuguese = { cached: currentAccount().language, htmlLang: document.documentElement.lang };
      return { spanish, english, portuguese };
    });
    assert.deepEqual(languagePersistence, {
      spanish: { cached: "es", htmlLang: "es" },
      english: { cached: "en", htmlLang: "en-US" },
      portuguese: { cached: "pt", htmlLang: "pt-BR" }
    });

    const dietIsolation = await page.evaluate(async () => {
      const originalAccounts = loadAccounts();
      const originalPlans = loadDietPlans();
      const trainer = currentAccount();
      const gus = { id: "qa-gus", role: "student", name: "Gusfraba", email: "gus@qa.test", trainerId: trainer.id, plan: "Aluno" };
      const fernando = { id: "qa-fernando", role: "student", name: "Fernando", email: "fernando@qa.test", trainerId: trainer.id, plan: "Aluno" };
      saveAccounts([
        ...originalAccounts.filter(account => ![trainer.id, gus.id, fernando.id].includes(account.id)),
        { ...trainer, students: [...new Set([...(trainer.students || []), gus.id, fernando.id])] },
        gus,
        fernando
      ]);
      const plans = loadDietPlans();
      const gusKey = dietPlanKey(gus.id, "2026-09", trainer.id);
      plans[gusKey] = {
        id: gusKey,
        trainerId: trainer.id,
        studentId: gus.id,
        month: "2026-09",
        calories: "1800",
        protein: "140",
        carbs: "170",
        fat: "55",
        meals: Array.from({ length: 5 }, (_, index) => ({ ...defaultMeal(index), name: `QA TEST ${index + 1}` })),
        supplements: []
      };
      saveDietPlans(plans);
      await showScreen("nutrition", { skipDirtyGuard: true });
      document.getElementById("dietMonth").value = "2026-09";
      document.getElementById("dietStudent").value = gus.id;
      await renderNutrition();
      const gusCalories = document.getElementById("dietCalories").value;
      document.getElementById("dietStudent").value = fernando.id;
      await renderNutrition();
      const fernandoValues = ["dietCalories", "dietProtein", "dietCarbs", "dietFat"].map(id => document.getElementById(id).value);
      const fernandoMealNames = [...document.querySelectorAll("#dietMealBuilder .meal-name")].map(input => input.value);
      const mealCounts = {};
      for (const count of [1, 2, 5, 10]) {
        const select = document.getElementById("dietMealCount");
        select.value = String(count);
        select.dispatchEvent(new Event("change", { bubbles: true }));
        await new Promise(resolve => setTimeout(resolve, 0));
        mealCounts[count] = document.querySelectorAll("#dietMealBuilder .meal-card").length;
      }
      const supplementButton = document.getElementById("addDietSupplement");
      const supplementButtonState = { disabled: supplementButton.disabled, html: supplementButton.outerHTML };
      supplementButton.click();
      supplementButton.click();
      const supplementRows = document.querySelectorAll("#dietSupplementBuilder .supplement-card").length;
      const supplementHtml = document.getElementById("dietSupplementBuilder").innerHTML;
      const scopedKeysDifferent = dietPlanKey(gus.id, "2026-09", trainer.id) !== dietPlanKey(fernando.id, "2026-09", trainer.id);
      const originalRemoteDietLoader = window.loadRemoteDietPlan;
      window.loadRemoteDietPlan = async studentId => {
        await new Promise(resolve => setTimeout(resolve, studentId === gus.id ? 60 : 5));
        return studentId === gus.id ? plans[gusKey] : null;
      };
      document.getElementById("dietStudent").value = gus.id;
      const slowGusRequest = renderNutrition();
      await new Promise(resolve => setTimeout(resolve, 1));
      document.getElementById("dietStudent").value = fernando.id;
      const fastFernandoRequest = renderNutrition();
      await Promise.all([slowGusRequest, fastFernandoRequest]);
      const raceProtectedValues = ["dietCalories", "dietProtein", "dietCarbs", "dietFat"].map(id => document.getElementById(id).value);
      window.loadRemoteDietPlan = originalRemoteDietLoader;
      saveDietPlans(originalPlans);
      saveAccounts(originalAccounts);
      applyAuthState();
      return { gusCalories, fernandoValues, fernandoMealNames, mealCounts, supplementRows, supplementHtml, supplementButtonState, scopedKeysDifferent, raceProtectedValues };
    });
    assert.equal(dietIsolation.gusCalories, "1800");
    assert.deepEqual(dietIsolation.fernandoValues, ["", "", "", ""]);
    assert.ok(dietIsolation.fernandoMealNames.every(name => !name.startsWith("QA TEST")));
    assert.deepEqual(dietIsolation.mealCounts, { 1: 1, 2: 2, 5: 5, 10: 10 });
    assert.equal(dietIsolation.supplementRows, 2, JSON.stringify({ html: dietIsolation.supplementHtml, button: dietIsolation.supplementButtonState, pageErrors }));
    assert.equal(dietIsolation.scopedKeysDifferent, true);
    assert.deepEqual(dietIsolation.raceProtectedValues, ["", "", "", ""]);

    await page.evaluate(async () => {
      await showScreen("workouts", { skipDirtyGuard: true });
      document.getElementById("newWorkoutButton").click();
      window.monolithResetWorkoutBuilder();
      document.querySelector("#exerciseBuilder .add-set-v2").click();
      const rows = [...document.querySelectorAll("#exerciseBuilder .set-row")];
      rows.forEach((row, index) => {
        row.querySelector(".set-weight").value = String((index + 1) * 10);
        row.querySelector(".set-reps").value = String(12 - index);
        row.querySelector(".set-rest").value = String(60 + index * 15);
        row.querySelector(".set-type").value = ["warmup", "working_set", "failure", "drop_set"][index];
      });
    });
    await page.locator("#exerciseBuilder .set-row").nth(3).locator(".remove-set-v2").click();
    await page.locator("#confirmActionConfirmation").click();
    await page.waitForFunction(() => document.querySelectorAll("#exerciseBuilder .set-row").length === 3);
    const afterFourthRemoval = await page.evaluate(() => [...document.querySelectorAll("#exerciseBuilder .set-row")].map(row => ({
      index: row.querySelector(".set-index").textContent,
      weight: row.querySelector(".set-weight").value,
      reps: row.querySelector(".set-reps").value,
      rest: row.querySelector(".set-rest").value,
      type: row.querySelector(".set-type").value
    })));
    assert.deepEqual(afterFourthRemoval.map(row => [row.weight, row.reps, row.rest, row.type]), [
      ["10", "12", "60", "warmup"],
      ["20", "11", "75", "working_set"],
      ["30", "10", "90", "failure"]
    ]);
    await page.locator("#exerciseBuilder .set-row").nth(1).locator(".remove-set-v2").click();
    await page.locator("#confirmActionConfirmation").click();
    await page.waitForFunction(() => document.querySelectorAll("#exerciseBuilder .set-row").length === 2);
    const afterSecondRemoval = await page.evaluate(() => [...document.querySelectorAll("#exerciseBuilder .set-row")].map(row => ({
      index: row.querySelector(".set-index").textContent,
      weight: row.querySelector(".set-weight").value,
      reps: row.querySelector(".set-reps").value,
      rest: row.querySelector(".set-rest").value,
      type: row.querySelector(".set-type").value
    })));
    assert.deepEqual(afterSecondRemoval.map(row => [row.index, row.weight, row.reps, row.rest, row.type]), [
      ["Série 1", "10", "12", "60", "warmup"],
      ["Série 2", "30", "10", "90", "failure"]
    ]);
    await page.evaluate(() => {
      document.getElementById("workoutModal").classList.remove("active");
      setDirtyBaseline("workout");
    });

    const voiceUi = await page.evaluate(async () => {
      const workout = assignedStudentId => ({
        id: `qa-voice-${assignedStudentId || "self"}`,
        ownerId: currentAccount().id,
        assignedStudentId,
        name: "QA Voice",
        goal: "QA",
        exercises: [{ id: "qa-exercise", name: "Agachamento", sets: [{ weight: 20, reps: 10, type: "Normal", rest: 60 }] }]
      });
      const ownEligible = window.monolithQaHooks.openVoiceTestSession(workout(""));
      const ownControlsVisible = !document.getElementById("sessionVoiceButton").hidden && !document.getElementById("monolithVoiceFab").hidden;
      const fallbackStarted = await window.monolithQaHooks.beginVoiceSession({ visualOnly: true });
      const fallbackPanelOpen = document.getElementById("monolithVoicePanel").classList.contains("open");
      const manualInputAvailable = !document.getElementById("voiceManualCommand").disabled;
      window.monolithQaHooks.setVoicePanelOpen(false);
      const panelClosed = !document.getElementById("monolithVoicePanel").classList.contains("open");
      await window.monolithQaHooks.stopVoiceSession("manual");
      const assignedEligible = window.monolithQaHooks.openVoiceTestSession(workout("aluno-demo"));
      const assignedControlsHidden = document.getElementById("sessionVoiceButton").hidden && document.getElementById("monolithVoiceFab").hidden;
      return { ownEligible, ownControlsVisible, fallbackStarted, fallbackPanelOpen, manualInputAvailable, panelClosed, assignedEligible, assignedControlsHidden };
    });
    assert.deepEqual(voiceUi, {
      ownEligible: true,
      ownControlsVisible: true,
      fallbackStarted: true,
      fallbackPanelOpen: true,
      manualInputAvailable: true,
      panelClosed: true,
      assignedEligible: false,
      assignedControlsHidden: true
    });

    await page.evaluate(async () => showScreen("clients", { skipDirtyGuard: true, historyMode: "replace" }));
    const accessibility = await page.evaluate(() => {
      const ids = [...document.querySelectorAll("[id]")].map(element => element.id);
      const duplicateIds = [...new Set(ids.filter((id, index) => ids.indexOf(id) !== index))];
      const unnamedButtons = [...document.querySelectorAll("button")]
        .filter(button => getComputedStyle(button).display !== "none" && !button.hidden && !button.disabled)
        .filter(button => !(button.getAttribute("aria-label") || button.getAttribute("title") || button.innerText.trim()))
        .map(button => button.id || button.className || button.outerHTML.slice(0, 80));
      const studentTargets = [...document.querySelectorAll('[data-student-screen="stats"]')]
        .map(button => button.getAttribute("aria-label") || "")
        .filter(Boolean);
      return { duplicateIds, unnamedButtons, studentTargets };
    });
    assert.deepEqual(accessibility.duplicateIds, []);
    assert.deepEqual(accessibility.unnamedButtons, []);
    assert.ok(accessibility.studentTargets.some(label => label.includes("Aluno Demo")), "student action has no target-specific accessible name");

    await page.evaluate(async () => {
      setSelectedStudentForPersonal("aluno-demo");
      applyLanguage("pt");
      await showScreen("stats", { skipDirtyGuard: true });
      document.querySelector('[data-stats-tab="reports"]')?.click();
    });
    const downloadPromise = page.waitForEvent("download", { timeout: 20000 });
    await page.locator("#downloadStatsMonthlyReport").click();
    const download = await downloadPromise;
    assert.match(download.suggestedFilename(), /^monolith-relatorio-aluno-demo-\d{4}-\d{2}-pt\.html$/);
    const reportPath = path.join(artifactDir, await download.suggestedFilename());
    await download.saveAs(reportPath);
    const downloadedHtml = fs.readFileSync(reportPath, "utf8");
    assert.match(downloadedHtml, /^<!doctype html>/i);
    assert.ok(downloadedHtml.includes("MONOLITH"));

    const popupPromise = page.waitForEvent("popup", { timeout: 10000 });
    await page.locator("#openStatsMonthlyReport").click();
    const popup = await popupPromise;
    await popup.waitForLoadState("domcontentloaded");
    await popup.waitForFunction(() => document.body?.innerText?.length > 100, null, { timeout: 20000 });
    assert.doesNotMatch(await popup.locator("body").innerText(), /Não foi possível criar o relatório|Could not create the report|No se pudo crear el informe/i);
    await popup.close();

    await page.screenshot({ path: path.join(artifactDir, "desktop-1366x768.png"), fullPage: true });
    for (const viewport of [{ width: 360, height: 800 }, { width: 390, height: 844 }, { width: 768, height: 1024 }, { width: 1600, height: 1000 }]) {
      await page.setViewportSize(viewport);
      await page.evaluate(async () => showScreen("home", { skipDirtyGuard: true }));
      const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
      assert.ok(overflow <= 2, `horizontal overflow at ${viewport.width}x${viewport.height}: ${overflow}px`);
      if (viewport.width === 390) await page.screenshot({ path: path.join(artifactDir, "mobile-390x844.png"), fullPage: true });
    }

    await page.setViewportSize({ width: 1366, height: 768 });
    await page.evaluate(async () => {
      setSelectedStudentForPersonal("aluno-demo");
      await showScreen("stats", { skipDirtyGuard: true });
      document.querySelector('[data-stats-tab="reports"]')?.click();
    });
    assert.equal(await page.evaluate(() => location.hash), "#relatorios", "report route was not written before refresh");
    await page.reload({ waitUntil: "domcontentloaded" });
    await page.waitForFunction(() => document.body.classList.contains("authenticated"), null, { timeout: 15000 });
    await page.waitForTimeout(1500);
    const restored = await page.evaluate(() => ({ selected: selectedStudentForPersonal(), hash: location.hash }));
    assert.equal(restored.selected, "aluno-demo");

    const studentContext = await browser.newContext({ viewport: { width: 390, height: 844 } });
    const studentPage = await studentContext.newPage();
    studentPage.on("pageerror", error => pageErrors.push(error.message));
    await loginDemo(studentPage, "aluno");
    const studentMenu = await studentPage.evaluate(() => [...document.querySelectorAll(".nav-btn[data-screen]")]
      .filter(button => getComputedStyle(button).display !== "none")
      .sort((a, b) => Number(getComputedStyle(a).order || 0) - Number(getComputedStyle(b).order || 0))
      .map(button => button.dataset.screen));
    assert.deepEqual(studentMenu, ["home", "workouts", "nutrition", "checkin", "stats", "timeline", "anamnesis", "programs", "trainerMap", "profile"]);
    const studentVoiceUi = await studentPage.evaluate(async () => {
      const workout = assignedStudentId => ({
        id: `qa-student-voice-${assignedStudentId}`,
        ownerId: "personal-demo",
        assignedStudentId,
        name: "QA Student Voice",
        goal: "QA",
        exercises: [{ id: "qa-exercise", name: "Agachamento", sets: [{ weight: 20, reps: 10, type: "Normal", rest: 60 }] }]
      });
      const ownEligible = window.monolithQaHooks.openVoiceTestSession(workout(currentAccount().id));
      const ownControlsVisible = !document.getElementById("sessionVoiceButton").hidden && !document.getElementById("monolithVoiceFab").hidden;
      await window.monolithQaHooks.stopVoiceSession("manual");
      const otherEligible = window.monolithQaHooks.openVoiceTestSession(workout("outro-aluno"));
      const otherControlsHidden = document.getElementById("sessionVoiceButton").hidden && document.getElementById("monolithVoiceFab").hidden;
      return { ownEligible, ownControlsVisible, otherEligible, otherControlsHidden };
    });
    assert.deepEqual(studentVoiceUi, { ownEligible: true, ownControlsVisible: true, otherEligible: false, otherControlsHidden: true });
    await studentPage.evaluate(async () => {
      await showScreen("stats", { skipDirtyGuard: true });
      document.querySelector('[data-stats-tab="reports"]')?.click();
    });
    assert.equal(await studentPage.evaluate(() => location.hash), "#relatorios");
    const studentSessionBeforeReload = await studentPage.evaluate(() => ({
      current: currentAccount()?.id || "",
      sessionId: sessionStorage.getItem("monolith.sessionUserId") || "",
      accounts: sessionStorage.getItem("monolith.accounts") || ""
    }));
    assert.equal(studentSessionBeforeReload.current, "aluno-demo");
    assert.equal(studentSessionBeforeReload.sessionId, "aluno-demo");
    await studentPage.reload({ waitUntil: "domcontentloaded" });
    await studentPage.waitForTimeout(1500);
    const studentRoute = await studentPage.evaluate(() => ({
      current: typeof currentAccount === "function" ? currentAccount()?.id || "" : "missing-function",
      sessionId: sessionStorage.getItem("monolith.sessionUserId") || "",
      hash: location.hash
    }));
    assert.equal(studentRoute.current, "aluno-demo");
    assert.equal(studentRoute.sessionId, "aluno-demo");
    assert.equal(studentRoute.hash, "#relatorios");
    await studentContext.close();

    assert.deepEqual(pageErrors, [], `browser page errors: ${pageErrors.join(" | ")}`);
    console.log(JSON.stringify({ ok: true, baseUrl, reportPath, core, pageErrors }, null, 2));
  } finally {
    await browser.close();
  }
}

main().catch(error => {
  console.error(error.stack || error);
  process.exitCode = 1;
});
