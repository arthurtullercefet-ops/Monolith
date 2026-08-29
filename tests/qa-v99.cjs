const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { chromium } = require("playwright");

const baseUrl = process.env.BASE_URL || "http://127.0.0.1:4174/";
const artifactDir = path.resolve(__dirname, "..", "artifacts", "qa-v99");

async function launchBrowser() {
  try {
    return await chromium.launch({ headless: true, channel: "chrome" });
  } catch (_) {
    return chromium.launch({ headless: true });
  }
}

async function loginDemo(page, role = "personal") {
  await page.goto(`${baseUrl}${baseUrl.includes("?") ? "&" : "?"}qa=monolith-v99`, { waitUntil: "domcontentloaded" });
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
        reportResults,
        hashAfterLeavingStats: location.hash
      };
    });

    assert.equal(core.build, "monolith-v99-qa-report-state-voice");
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
