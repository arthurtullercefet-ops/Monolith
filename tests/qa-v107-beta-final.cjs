const assert = require("node:assert/strict");
const fs = require("node:fs");
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

async function verifyDownloadDispatch() {
  const timers = [];
  const revoked = [];
  let capturedBlob = null;
  let link = null;

  class MockLink {
    constructor() {
      this.download = "";
      this.dataset = {};
      this.style = {};
      this.listeners = new Map();
      this.removed = false;
      this.clicked = false;
    }

    addEventListener(type, listener) {
      this.listeners.set(type, listener);
    }

    setAttribute() {}

    click() {
      this.clicked = true;
      this.listeners.get("click")?.({ defaultPrevented: false });
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
        capturedBlob = blob;
        return "blob:monolith-report";
      },
      revokeObjectURL(url) {
        revoked.push(url);
      }
    },
    document: {
      body: {
        appendChild(node) {
          node.appended = true;
        }
      },
      createElement(tag) {
        assert.equal(tag, "a");
        link = new MockLink();
        return link;
      }
    },
    window: {
      setTimeout(callback, delay) {
        timers.push({ callback, delay });
        return timers.length;
      }
    },
    logAppError() {}
  });

  const block = sourceBetween("const activeDownloadUrls", "let reportExportSequence");
  vm.runInContext(`${block}\nthis.downloadTextFileForTest = downloadTextFile;`, context);
  const dispatched = context.downloadTextFileForTest("Relatório <> final.html", "text/html", "<!doctype html><title>MONOLITH</title>");

  assert.equal(dispatched, true);
  assert.equal(link.clicked, true);
  assert.equal(link.dataset.monolithDownload, "true");
  assert.match(link.download, /^[A-Za-z0-9.-]+$/);
  assert.match(link.download, /\.html$/);
  assert.equal(capturedBlob.type, "text/html;charset=utf-8");
  const bytes = new Uint8Array(await capturedBlob.arrayBuffer());
  assert.deepEqual([...bytes.slice(0, 3)], [0xEF, 0xBB, 0xBF]);
  assert.match(await capturedBlob.text(), /^<!doctype html>/i);
  assert.equal(revoked.length, 0, "blob URL was revoked before the browser could consume it");

  const removal = timers.find(timer => timer.delay === 0);
  const release = timers.find(timer => timer.delay >= 30000);
  assert.ok(removal, "download link cleanup was not scheduled");
  assert.ok(release, "safe blob URL cleanup was not scheduled");
  removal.callback();
  assert.equal(link.removed, true);
  assert.equal(revoked.length, 0);
  release.callback();
  assert.deepEqual(revoked, ["blob:monolith-report"]);
}

async function verifyBrowserDownloadEvent() {
  let chromium;
  try {
    ({ chromium } = require("playwright"));
  } catch {
    try {
      const bundledModules = path.join(process.env.USERPROFILE || "", ".cache", "codex-runtimes", "codex-primary-runtime", "dependencies", "node", "node_modules");
      ({ chromium } = require(require.resolve("playwright", { paths: [bundledModules] })));
    } catch {
      console.log("qa-v107-beta-final: browser download check skipped (Playwright unavailable)");
      return;
    }
  }

  const browserExecutable = [
    process.env.MONOLITH_TEST_BROWSER,
    "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe",
    "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe",
    "C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe"
  ].find(candidate => candidate && fs.existsSync(candidate));
  const browser = await chromium.launch({ headless: true, ...(browserExecutable ? { executablePath: browserExecutable } : {}) });
  try {
    const page = await browser.newPage({ acceptDownloads: true });
    const block = sourceBetween("const activeDownloadUrls", "let reportExportSequence");
    await page.setContent('<button id="download" type="button">Download</button>');
    await page.addScriptTag({ content: `window.logAppError = function () {}; ${block}\n document.getElementById("download").addEventListener("click", function () { window.downloadDispatched = downloadTextFile("Relatório final.html", "text/html", "<!doctype html><title>MONOLITH</title>"); });` });

    const downloadPromise = page.waitForEvent("download", { timeout: 10000 });
    await page.locator("#download").click();
    const download = await downloadPromise;
    assert.equal(await page.evaluate(() => window.downloadDispatched), true);
    assert.equal(download.suggestedFilename(), "Relatorio-final.html");
    const downloadPath = await download.path();
    const bytes = fs.readFileSync(downloadPath);
    assert.deepEqual([...bytes.subarray(0, 3)], [0xEF, 0xBB, 0xBF]);
    assert.match(bytes.toString("utf8").replace(/^\uFEFF/, ""), /^<!doctype html>/i);
  } finally {
    await browser.close();
  }
}

function verifyDietSemantics() {
  const block = sourceBetween("function dietNumericValue", "function renderDietPlan");
  const context = vm.createContext({});
  vm.runInContext(`${block}\nthis.dietCalculatedMealTotalsForTest = dietCalculatedMealTotals; this.normalizedImportedDietTargetsForTest = normalizedImportedDietTargets;`, context);

  const targets = context.normalizedImportedDietTargetsForTest({});
  assert.deepEqual({ ...targets }, { calories: "", protein: "", carbs: "", fat: "" });

  const totals = context.dietCalculatedMealTotalsForTest({
    meals: [
      { calories: 500, protein: 30, carbs: 60, fat: 12 },
      { calories: 700, protein: 50, carbs: 80, fat: 20 }
    ]
  });
  assert.deepEqual({ ...totals }, { calories: 1200, protein: 80, carbs: 140, fat: 32 });
  assert.doesNotMatch(html, /targets\.calories\s*\?\?\s*sums\.calories/);
  assert.match(html, /Metas prescritas não informadas para este plano\./);
  assert.match(html, /Calculado apenas para exibição; não é uma meta prescrita\./);
}

function verifyRoleSafeRecommendations() {
  const summary = sourceBetween("function renderStatsSectionSummaries", "function weightSeries");
  const navigation = sourceBetween(
    'const studentScreenButton = event.target.closest("[data-student-screen]");',
    'const setDone = event.target.closest(".set-done");'
  );
  assert.doesNotMatch(summary, /Publicar a dieta do mês/);
  assert.doesNotMatch(summary, /action:\s*"Criar dieta"/);
  assert.match(summary, /user\?\.role === "student"/);
  assert.match(summary, /Consultar treinos disponíveis/);
  assert.match(navigation, /activeUser\?\.role === "personal"[\s\S]*setSelectedStudentForPersonal\(targetStudentId\)/);
  assert.match(navigation, /activeUser\?\.role === "student" && targetStudentId === activeUser\.id/);
}

function verifyStableSessionHydration() {
  assert.match(html, /<body class="auth-resolving" aria-busy="true">/);
  assert.match(html, /body\.auth-resolving \.auth-screen/);
  assert.match(html, /body\.auth-resolving \.identity-hydration-shell/);
  assert.match(html, /document\.body\.classList\.remove\("auth-resolving"\)/);
  assert.match(html, /\.finally\(\(\) => \{/);
}

function verifyProtectedRegressions() {
  const civilDate = sourceBetween("function localDateLabel", "function normalizeLocalizedTimePunctuation");
  const measureFilter = sourceBetween("function reportUsableBodyMeasures", "function setVolume");
  const report = sourceBetween("function monthlyReportHTML", "const activeDownloadUrls");
  assert.match(civilDate, /timeZone:\s*"UTC"/);
  assert.match(measureFilter, /!includeSuspicious\s*&&\s*bodyMeasureSuspicion\(entry\)\.suspicious/);
  assert.match(report, /series\.length >= 2 && first && latest/);
  assert.match(html, /body\.auth-role-student #dietPlanForm/);
  assert.match(html, /currentAccount\(\)\?\.role !== "personal"/);
}

async function main() {
  assert.match(html, /monolith-v108-voice-capture/);
  await verifyDownloadDispatch();
  await verifyBrowserDownloadEvent();
  verifyDietSemantics();
  verifyRoleSafeRecommendations();
  verifyStableSessionHydration();
  verifyProtectedRegressions();
  console.log("qa-v107-beta-final: all isolated checks passed");
}

main().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
