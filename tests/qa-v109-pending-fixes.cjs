const assert = require("node:assert/strict");
const fs = require("node:fs");
const http = require("node:http");
const path = require("node:path");
const vm = require("node:vm");

const root = path.resolve(__dirname, "..");
const html = fs.readFileSync(path.join(root, "index.html"), "utf8");

function sourceBetween(start, end) {
  const startIndex = html.indexOf(start);
  const endIndex = html.indexOf(end, startIndex);
  assert.ok(startIndex >= 0, `Missing source marker: ${start}`);
  assert.ok(endIndex > startIndex, `Missing source marker: ${end}`);
  return html.slice(startIndex, endIndex);
}

function loadChromium() {
  try {
    return require("playwright").chromium;
  } catch {
    const bundledModules = path.join(process.env.USERPROFILE || "", ".cache", "codex-runtimes", "codex-primary-runtime", "dependencies", "node", "node_modules");
    return require(require.resolve("playwright", { paths: [bundledModules] })).chromium;
  }
}

async function launchBrowser() {
  const chromium = loadChromium();
  const executablePath = [
    process.env.MONOLITH_TEST_BROWSER,
    "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe",
    "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe",
    "C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe"
  ].find(candidate => candidate && fs.existsSync(candidate));
  return chromium.launch({ headless: true, ...(executablePath ? { executablePath } : {}) });
}

function contentType(filePath) {
  return ({
    ".html": "text/html; charset=utf-8",
    ".js": "text/javascript; charset=utf-8",
    ".json": "application/json; charset=utf-8",
    ".webmanifest": "application/manifest+json; charset=utf-8",
    ".svg": "image/svg+xml; charset=utf-8"
  })[path.extname(filePath).toLowerCase()] || "application/octet-stream";
}

async function startStaticServer() {
  const server = http.createServer((request, response) => {
    const pathname = decodeURIComponent(new URL(request.url, "http://127.0.0.1").pathname);
    const requested = pathname === "/" ? "/index.html" : pathname;
    const filePath = path.resolve(root, `.${requested}`);
    if (!filePath.startsWith(`${root}${path.sep}`)) {
      response.writeHead(403).end("Forbidden");
      return;
    }
    fs.readFile(filePath, (error, data) => {
      if (error) {
        response.writeHead(error.code === "ENOENT" ? 404 : 500).end("Not found");
        return;
      }
      response.writeHead(200, { "Content-Type": contentType(filePath), "Cache-Control": "no-store" });
      response.end(data);
    });
  });
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  return { server, origin: `http://127.0.0.1:${server.address().port}` };
}

async function verifyDownloadCore() {
  const timers = [];
  const revoked = [];
  const blobs = [];
  const links = [];

  class MockLink {
    constructor() {
      this.download = "";
      this.dataset = {};
      this.style = {};
      this.listeners = new Map();
      this.canceled = false;
    }

    addEventListener(type, listener) {
      this.listeners.set(type, listener);
    }

    setAttribute() {}

    click() {
      this.listeners.get("click")?.({ defaultPrevented: this.canceled });
    }

    remove() {
      this.removed = true;
    }
  }

  const context = vm.createContext({
    Blob,
    navigator: {},
    URL: {
      createObjectURL(blob) {
        blobs.push(blob);
        return `blob:monolith-${blobs.length}`;
      },
      revokeObjectURL(url) {
        revoked.push(url);
      }
    },
    document: {
      body: { appendChild(node) { node.appended = true; } },
      createElement() {
        const link = new MockLink();
        links.push(link);
        return link;
      }
    },
    window: { setTimeout(callback, delay) { timers.push({ callback, delay }); } },
    logAppError() {}
  });

  const block = sourceBetween("const activeDownloadUrls", "let reportExportSequence");
  vm.runInContext(`${block}\nthis.downloadTextFileForTest = downloadTextFile;`, context);
  assert.equal(context.downloadTextFileForTest("blank.csv", "text/csv", "   \n"), false);
  assert.equal(links.length, 0, "blank output created a download element");

  assert.equal(context.downloadTextFileForTest("Relatório <> final.html", "text/html", "<!doctype html><title>Monolith</title>"), true);
  assert.equal(context.downloadTextFileForTest("dietas final.csv", "text/csv", "student;meal\nAna;Breakfast"), true);
  assert.equal(blobs[0].type, "text/html;charset=utf-8");
  assert.equal(blobs[1].type, "text/csv;charset=utf-8");
  assert.equal(links[0].download, "Relatorio-final.html");
  assert.equal(links[1].download, "dietas-final.csv");
  for (const blob of blobs) {
    const bytes = new Uint8Array(await blob.arrayBuffer());
    assert.deepEqual([...bytes.slice(0, 3)], [0xEF, 0xBB, 0xBF]);
  }
  assert.equal(revoked.length, 0, "object URL was revoked before the browser could consume it");
  timers.filter(timer => timer.delay >= 30000).forEach(timer => timer.callback());
  assert.deepEqual(revoked.sort(), ["blob:monolith-1", "blob:monolith-2"]);
}

function verifySourceContracts() {
  assert.match(html, /monolith-v109-pending-fixes/);
  const pulse = sourceBetween("function loadPulseReviews", "function readMemoryList");
  assert.match(pulse, /pulseHydrationSequence/);
  assert.match(pulse, /pulseSourceConfirmed\("pulse-programs"/);
  assert.match(pulse, /shouldCache: isCurrentRequest/);
  assert.match(pulse, /renderPulseLoadingState/);
  assert.match(pulse, /renderPulseErrorState/);

  const reportHydration = sourceBetween("async function hydrateRemoteReportData", "let trainerDashboardHydrationSequence");
  assert.match(reportHydration, /"published-diets"/);
  assert.match(reportHydration, /latestPublishedDietPlan/);
  const statsSummary = sourceBetween("function latestPublishedDietSummaryLabel", "function weightSeries");
  assert.match(statsSummary, /report\.latestPublishedDietPlan/);
  assert.match(statsSummary, /Carregando última dieta/);
  assert.match(statsSummary, /Não foi possível carregar a última dieta/);

  const dietDownloads = sourceBetween("async function downloadDietCsvTemplate", "function previewDietCsv");
  assert.doesNotMatch(dietDownloads, /Modelo de dieta CSV baixado|Dietas exportadas em CSV/);
  assert.match(dietDownloads, /Download do modelo de dieta CSV iniciado/);
  assert.match(dietDownloads, /Download da exportação de dietas CSV iniciado/);
  const workoutDownloads = sourceBetween("function downloadWorkoutCsvTemplateV2", "async function importWorkoutCsvFileV2");
  assert.doesNotMatch(workoutDownloads, /Modelo CSV baixado|Treinos exportados em CSV/);
  assert.match(workoutDownloads, /Download do modelo de treino CSV iniciado/);
  assert.match(workoutDownloads, /Download da exportação de treinos CSV iniciado/);

  for (const key of ["4 semanas", "8 semanas", "12 semanas", "Salvar programa para {name}", "Marcar rascunho", "Orientações separadas das refeições", "Confirme nome, dose e frequência. O Monolith não gera doses automaticamente."]) {
    assert.ok((html.match(new RegExp(`"${key.replace(/[.*+?^${}()|[\\]\\]/g, "\\$&")}"`, "g")) || []).length >= 3, `missing PT/EN/ES key: ${key}`);
  }
}

async function loginPersonal(page, origin) {
  await page.goto(`${origin}/index.html?qa=monolith-v109`, { waitUntil: "domcontentloaded" });
  await page.waitForFunction(() => !document.body.classList.contains("auth-resolving"));
  await page.locator("#loginEmail").fill("personal@monolith.app");
  await page.locator("#loginPassword").fill("123456");
  await page.locator("#loginButton").click();
  await page.waitForFunction(() => document.body.classList.contains("authenticated"));
}

async function captureDownload(page, buttonId, expectedExtension) {
  const downloadPromise = page.waitForEvent("download", { timeout: 10000 });
  await page.evaluate(id => document.getElementById(id).click(), buttonId);
  const download = await downloadPromise;
  const filename = download.suggestedFilename();
  assert.ok(filename.endsWith(expectedExtension), `${buttonId} produced ${filename}`);
  assert.doesNotMatch(filename, /[<>:"/\\|?*]/);
  const filePath = await download.path();
  const bytes = fs.readFileSync(filePath);
  assert.deepEqual([...bytes.subarray(0, 3)], [0xEF, 0xBB, 0xBF]);
  return { filename, text: bytes.toString("utf8").replace(/^\uFEFF/, "") };
}

async function verifyBrowserFlows() {
  const { server, origin } = await startStaticServer();
  const browser = await launchBrowser();
  const context = await browser.newContext({ acceptDownloads: true, viewport: { width: 1280, height: 900 } });
  await context.route("**/*", route => {
    const url = new URL(route.request().url());
    return url.origin === origin ? route.continue() : route.abort();
  });
  const page = await context.newPage();
  const pageErrors = [];
  page.on("pageerror", error => pageErrors.push(error.message));

  try {
    await loginPersonal(page, origin);
    const setup = await page.evaluate(async () => {
      const trainer = currentAccount();
      const student = studentsForPersonal(trainer.id)[0];
      setSelectedStudentForPersonal(student.id);
      cacheDietPlan({
        studentId: student.id,
        trainerId: trainer.id,
        month: "2026-01",
        status: "published",
        publishedAt: "2026-01-10T12:00:00Z",
        calories: "2200",
        protein: "150",
        carbs: "240",
        fat: "70",
        meals: [{ name: "User breakfast", items: "User food", calories: "500", protein: "30", carbs: "50", fat: "15" }],
        supplements: []
      });
      cacheDietPlan({
        studentId: student.id,
        trainerId: trainer.id,
        month: "2025-12",
        status: "published",
        publishedAt: "2026-03-01T12:00:00Z",
        calories: "2100",
        protein: "145",
        carbs: "230",
        fat: "68",
        meals: [{ name: "User lunch", items: "User meal", calories: "650", protein: "45", carbs: "70", fat: "18" }],
        supplements: []
      });
      cacheDietPlan({
        studentId: student.id,
        trainerId: trainer.id,
        month: "2026-09",
        status: "draft",
        updatedAt: "2026-09-13T12:00:00Z",
        meals: [],
        supplements: []
      });
      localStorage.setItem("monolith.workouts", JSON.stringify([{
        id: "isolated-download-workout",
        ownerId: trainer.id,
        assignedStudentId: student.id,
        name: "User workout name",
        goal: "User workout goal",
        tag: "Local",
        exercises: [{ name: "User exercise", sets: [{ reps: "10", weight: "40", rest: "90", type: "working_set" }] }]
      }]));
      setSelectedWorkoutTarget(student.id);
      await window.monolithRefreshWorkoutView();
      renderDietSupplementBuilder([{
        id: "supplement-isolated",
        name: "User supplement name",
        dosage: "User dosage",
        frequency: "User frequency",
        instructions: "Do not translate this user text"
      }]);
      return { studentId: student.id };
    });

    const behavior = await page.evaluate(async studentId => {
      applyLanguage("en");
      updateWriteDestinationUI();
      const english = {
        durations: [...document.querySelectorAll("#programDuration option")].map(option => option.textContent.trim()),
        target: document.getElementById("programSaveTarget").textContent,
        draft: t("Marcar rascunho"),
        guidance: document.querySelector("#dietPlanForm .section-title span")?.textContent,
        supplementNotice: [...document.querySelectorAll("#dietPlanForm .report-line")].find(node => node.dataset.i18nKey === "Confirme nome, dose e frequência. O Monolith não gera doses automaticamente.")?.textContent,
        durationAria: document.getElementById("programDuration")?.getAttribute("aria-label"),
        supplementAria: document.querySelector(".supplement-instructions")?.getAttribute("aria-label"),
        userText: document.querySelector(".supplement-instructions")?.value,
        latestId: latestPublishedDietForStudent(studentId)?.month
      };
      let releaseStaleRequest;
      let staleRequestIsCurrent = true;
      const staleRequest = loadRemoteModule(
        "stale-response-probe",
        studentId,
        () => new Promise(resolve => { releaseStaleRequest = resolve; }),
        { shouldApply: () => staleRequestIsCurrent }
      );
      staleRequestIsCurrent = false;
      setRemoteDataState("stale-response-probe", studentId, "loaded", { count: 99 });
      releaseStaleRequest(["old-response"]);
      const staleResult = await staleRequest;
      const staleState = getRemoteDataState("stale-response-probe", studentId);
      const originalRealAccountCheck = isRealSupabaseAccount;
      isRealSupabaseAccount = () => true;
      ["trainer-checkins", "trainer-diets", "trainer-assigned-workouts", "pulse-completed-workouts"].forEach(module => setRemoteDataState(module, currentAccount().id, "loaded"));
      setRemoteDataState("pulse-programs", currentAccount().id, "loading");
      const pendingProgramSourceConfirmed = pulseSourceConfirmed("pulse-programs", currentAccount().id);
      setRemoteDataState("pulse-programs", currentAccount().id, "empty");
      const settledProgramSourceConfirmed = pulseSourceConfirmed("pulse-programs", currentAccount().id);
      setRemoteDataState("published-diets", studentId, "error");
      const dietError = latestPublishedDietSummaryLabel({}, studentId, currentAccount());
      isRealSupabaseAccount = originalRealAccountCheck;
      applyLanguage("es");
      updateWriteDestinationUI();
      const spanish = {
        durations: [...document.querySelectorAll("#programDuration option")].map(option => option.textContent.trim()),
        target: document.getElementById("programSaveTarget").textContent,
        draft: t("Marcar rascunho"),
        supplementNotice: document.querySelector('[data-i18n="Confirme nome, dose e frequência. O Monolith não gera doses automaticamente."]')?.textContent,
        durationAria: document.getElementById("programDuration")?.getAttribute("aria-label"),
        supplementAria: document.querySelector(".supplement-instructions")?.getAttribute("aria-label"),
        userText: document.querySelector(".supplement-instructions")?.value
      };
      applyLanguage("en");
      return { english, spanish, staleResult, staleState, pendingProgramSourceConfirmed, settledProgramSourceConfirmed, dietError };
    }, setup.studentId);

    assert.deepEqual(behavior.english.durations, ["4 weeks", "8 weeks", "12 weeks"]);
    assert.match(behavior.english.target, /Save program for Aluno Demo/);
    assert.equal(behavior.english.draft, "Move to draft");
    assert.equal(behavior.english.guidance, "Guidance kept separate from meals");
    assert.equal(behavior.english.supplementNotice, "Confirm the name, dose, and frequency. Monolith does not generate doses automatically.");
    assert.equal(behavior.english.durationAria, "Program duration");
    assert.equal(behavior.english.supplementAria, "Instructions 1");
    assert.equal(behavior.english.userText, "Do not translate this user text");
    assert.equal(behavior.english.latestId, "2025-12", "draft or month name was used instead of latest publication ordering");
    assert.equal(behavior.staleResult.status, "stale");
    assert.equal(behavior.staleState.status, "loaded");
    assert.equal(behavior.staleState.count, 99, "an obsolete response replaced the current remote state");
    assert.equal(behavior.pendingProgramSourceConfirmed, false);
    assert.equal(behavior.settledProgramSourceConfirmed, true);
    assert.match(behavior.dietError, /latest diet could not be loaded/i);
    assert.deepEqual(behavior.spanish.durations, ["4 semanas", "8 semanas", "12 semanas"]);
    assert.match(behavior.spanish.target, /Guardar programa para Aluno Demo/);
    assert.equal(behavior.spanish.draft, "Marcar como borrador");
    assert.equal(behavior.spanish.supplementNotice, "Confirma el nombre, la dosis y la frecuencia. Monolith no genera dosis automáticamente.");
    assert.equal(behavior.spanish.durationAria, "Duración del programa");
    assert.equal(behavior.spanish.supplementAria, "Instrucciones 1");
    assert.equal(behavior.spanish.userText, "Do not translate this user text");

    await page.evaluate(() => setReportControlsState("ready"));
    const report = await captureDownload(page, "downloadStatsMonthlyReport", ".html");
    assert.match(report.text, /^<!doctype html>/i);

    const dietTemplate = await captureDownload(page, "downloadDietCsvTemplate", ".csv");
    assert.match(dietTemplate.text, /^student;month;meal;/i);
    assert.match(await page.locator("#dietCsvStatus").innerText(), /download started/i);

    const dietExport = await captureDownload(page, "exportDietCsv", ".csv");
    assert.match(dietExport.text, /User breakfast|User lunch/);
    assert.match(await page.locator("#dietCsvStatus").innerText(), /download started/i);

    const workoutTemplate = await captureDownload(page, "downloadWorkoutCsvTemplate", ".csv");
    assert.match(workoutTemplate.text, /^student;workout;goal;/i);
    assert.match(await page.locator("#workoutCsvStatus").innerText(), /download started/i);

    const workoutExport = await captureDownload(page, "exportWorkoutCsv", ".csv");
    assert.match(workoutExport.text, /User workout name/);
    assert.match(await page.locator("#workoutCsvStatus").innerText(), /download started/i);
    assert.deepEqual(pageErrors, []);
  } finally {
    await context.close();
    await browser.close();
    await new Promise(resolve => server.close(resolve));
  }
}

async function main() {
  verifySourceContracts();
  await verifyDownloadCore();
  await verifyBrowserFlows();
  console.log("qa-v109-pending-fixes: all isolated checks passed");
}

main().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
