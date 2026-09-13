const assert = require("node:assert/strict");
const fs = require("node:fs");
const http = require("node:http");
const path = require("node:path");

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
  const address = server.address();
  return { server, origin: `http://127.0.0.1:${address.port}` };
}

function installVoiceMocks() {
  const mock = {
    recognitionMode: "manual",
    recognitions: [],
    mediaRequests: 0,
    activeTracks: 0,
    trackStops: 0,
    recognitionStarts: 0,
    activeTracksAtRecognitionStart: [],
    recognitionAborts: 0,
    speechHold: false,
    speechStarts: 0,
    speechCancels: 0,
    currentUtterance: null
  };

  Object.defineProperty(navigator, "mediaDevices", {
    configurable: true,
    value: {
      async getUserMedia() {
        mock.mediaRequests += 1;
        mock.activeTracks += 1;
        let stopped = false;
        return {
          getTracks() {
            return [{
              stop() {
                if (stopped) return;
                stopped = true;
                mock.trackStops += 1;
                mock.activeTracks -= 1;
              }
            }];
          }
        };
      }
    }
  });

  class MockRecognition {
    constructor() {
      this.continuous = false;
      this.interimResults = false;
      this.maxAlternatives = 1;
      this.lang = "";
      mock.recognitions.push(this);
    }

    start() {
      mock.recognitionStarts += 1;
      mock.activeTracksAtRecognitionStart.push(mock.activeTracks);
      if (mock.recognitionMode === "throw") {
        const error = new Error("mock-start-failure");
        error.name = "InvalidStateError";
        throw error;
      }
      if (["auto", "auto-end"].includes(mock.recognitionMode)) {
        queueMicrotask(() => {
          this.onstart?.();
          if (mock.recognitionMode === "auto-end") setTimeout(() => this.onend?.(), 10);
        });
      }
    }

    stop() {
      queueMicrotask(() => this.onend?.());
    }

    abort() {
      mock.recognitionAborts += 1;
      queueMicrotask(() => this.onend?.());
    }

    emitStart() {
      this.onstart?.();
    }

    emitEnd() {
      this.onend?.();
    }
  }

  class MockUtterance {
    constructor(text) {
      this.text = text;
      this.lang = "";
      this.volume = 1;
      this.rate = 1;
      this.pitch = 1;
      this.onend = null;
      this.onerror = null;
    }
  }

  Object.defineProperty(window, "SpeechRecognition", { configurable: true, value: undefined });
  Object.defineProperty(window, "webkitSpeechRecognition", { configurable: true, value: MockRecognition });
  Object.defineProperty(window, "SpeechSynthesisUtterance", { configurable: true, value: MockUtterance });
  Object.defineProperty(window, "speechSynthesis", {
    configurable: true,
    value: {
      getVoices() { return []; },
      speak(utterance) {
        mock.speechStarts += 1;
        mock.currentUtterance = utterance;
        if (!mock.speechHold) queueMicrotask(() => utterance.onend?.());
      },
      cancel() {
        mock.speechCancels += 1;
        mock.currentUtterance = null;
      }
    }
  });

  window.__voiceMock = mock;
}

async function loginStudent(page, origin) {
  await page.goto(`${origin}/index.html?qa=monolith-v108`, { waitUntil: "domcontentloaded" });
  await page.waitForFunction(() => !document.body.classList.contains("auth-resolving"));
  await page.locator("#loginEmail").fill("aluno@monolith.app");
  await page.locator("#loginPassword").fill("123456");
  await page.locator("#loginButton").click();
  await page.waitForFunction(() => document.body.classList.contains("authenticated"));
}

async function openIsolatedVoiceSession(page) {
  const eligible = await page.evaluate(async () => {
    const workout = {
      id: "voice-memory-only",
      ownerId: "personal-memory-only",
      assignedStudentId: currentAccount().id,
      name: "Voice memory fixture",
      goal: "Isolated test",
      exercises: [{
        id: "voice-exercise-memory-only",
        name: "Agachamento",
        sets: [
          { weight: 20, reps: 8, type: "working_set", rest: 60 },
          { weight: 30, reps: 9, type: "warmup", rest: 75 },
          { weight: 40, reps: 10, type: "failure", rest: 90 }
        ]
      }]
    };
    const allowed = window.monolithQaHooks.openVoiceTestSession(workout);
    await window.monolithVoiceTest.beginVisual();
    return allowed;
  });
  assert.equal(eligible, true);
}

async function main() {
  const voiceStates = sourceBetween("const voiceStateCopyV2", "function setVoiceVisualStateV2");
  const commandFlow = sourceBetween("async function processVoiceCommandV2", "function html(value");
  assert.match(html, /monolith-v108-voice-capture/);
  assert.doesNotMatch(voiceStates, /unsupported:\s*\["Navegador incompatível"/);
  assert.match(commandFlow, /command\.confidence < 0\.78 && voiceNeedsConfidenceConfirmationV2/);
  assert.match(commandFlow, /voiceIsRecentDuplicateV2\(command\)/);
  assert.match(commandFlow, /commandSynchronized && sessionSynchronized/);

  const { server, origin } = await startStaticServer();
  const browser = await launchBrowser();
  const context = await browser.newContext({ viewport: { width: 390, height: 844 } });
  const blockedExternal = [];
  await context.route("**/*", route => {
    const url = new URL(route.request().url());
    if (url.origin === origin) return route.continue();
    blockedExternal.push(url.href);
    return route.abort();
  });
  await context.addInitScript(installVoiceMocks);
  const page = await context.newPage();
  const pageErrors = [];
  page.on("pageerror", error => pageErrors.push(error.message));

  try {
    await loginStudent(page, origin);
    await openIsolatedVoiceSession(page);
    assert.equal(await page.evaluate(() => window.__voiceMock.mediaRequests), 0, "opening the visual fallback requested microphone access");
    assert.equal(await page.evaluate(() => window.__voiceMock.recognitionStarts), 0, "speech recognition started without a user action");

    await page.evaluate(() => { window.__voiceMock.recognitionMode = "manual"; });
    await page.locator("#voiceTalkNow").click();
    await page.waitForFunction(() => window.__voiceMock.recognitionStarts === 1);
    const beforeStart = await page.evaluate(() => ({
      status: window.monolithVoiceTest.state.status,
      title: document.getElementById("voiceStatusTitle").textContent,
      disabled: document.getElementById("voiceTalkNow").disabled,
      mediaRequests: window.__voiceMock.mediaRequests,
      trackStops: window.__voiceMock.trackStops,
      activeTracksAtStart: window.__voiceMock.activeTracksAtRecognitionStart[0]
    }));
    assert.deepEqual(beforeStart, {
      status: "starting",
      title: "Iniciando reconhecimento",
      disabled: true,
      mediaRequests: 0,
      trackStops: 0,
      activeTracksAtStart: 0
    });

    await page.evaluate(() => window.__voiceMock.recognitions.at(-1).emitStart());
    await page.waitForFunction(() => window.monolithVoiceTest.state.recognitionListening);
    assert.equal(await page.evaluate(() => window.monolithVoiceTest.state.status), "listening");
    assert.equal(await page.evaluate(() => window.monolithVoiceTest.capture()), false, "a concurrent capture was accepted");
    await page.evaluate(() => window.__voiceMock.recognitions.at(-1).emitEnd());
    await page.waitForFunction(() => window.monolithVoiceTest.state.status === "no-speech");

    await page.evaluate(() => {
      window.__voiceMock.speechHold = true;
      window.monolithVoiceTest.speak("Resposta em andamento");
      window.__voiceMock.recognitionMode = "auto";
    });
    await page.waitForFunction(() => window.monolithVoiceTest.state.speaking);
    await page.locator("#voiceTalkNow").click();
    await page.waitForFunction(() => window.monolithVoiceTest.state.recognitionListening);
    const speechResume = await page.evaluate(() => ({
      speaking: window.monolithVoiceTest.state.speaking,
      starts: window.__voiceMock.recognitionStarts,
      cancels: window.__voiceMock.speechCancels,
      mediaRequests: window.__voiceMock.mediaRequests
    }));
    assert.equal(speechResume.speaking, false);
    assert.ok(speechResume.starts >= 2);
    assert.ok(speechResume.cancels >= 1);
    assert.equal(speechResume.mediaRequests, 0, "a redundant getUserMedia capture ran alongside SpeechRecognition");
    await page.evaluate(() => window.__voiceMock.recognitions.at(-1).emitEnd());
    await page.waitForFunction(() => window.monolithVoiceTest.state.status === "no-speech");

    const wakeStartsBefore = await page.evaluate(async () => {
      const state = window.monolithVoiceTest.state;
      window.__voiceMock.speechHold = false;
      window.__voiceMock.recognitionMode = "auto";
      state.localWakeEnabled = true;
      state.captureOnce = false;
      state.paused = false;
      state.active = true;
      state.directListenUntil = 0;
      state.recognition = window.monolithVoiceTest.createRecognition();
      await window.monolithVoiceTest.startRecognition();
      window.__voiceMock.speechHold = true;
      const alternative = { transcript: "hey monolith", confidence: 0.99 };
      const result = [alternative];
      result.isFinal = true;
      window.__wakeResponsePromise = window.monolithVoiceTest.handleResult({ resultIndex: 0, results: [result] });
      return window.__voiceMock.recognitionStarts;
    });
    await page.waitForFunction(() => window.monolithVoiceTest.state.speaking);
    const whileWakeResponseSpeaks = await page.evaluate(() => ({
      status: window.monolithVoiceTest.state.status,
      directListenUntil: window.monolithVoiceTest.state.directListenUntil
    }));
    assert.equal(whileWakeResponseSpeaks.status, "interpreted", "Voice claimed to be listening while its own response was still speaking");
    assert.equal(whileWakeResponseSpeaks.directListenUntil, 0, "the direct-listen window started before the spoken response finished");
    await page.evaluate(() => {
      window.__voiceMock.speechHold = false;
      window.__voiceMock.currentUtterance?.onend?.();
    });
    await page.waitForFunction(starts => window.__voiceMock.recognitionStarts > starts, wakeStartsBefore);
    await page.waitForFunction(() => window.monolithVoiceTest.state.recognitionListening);
    const afterWakeResponse = await page.evaluate(() => ({
      status: window.monolithVoiceTest.state.status,
      directListenUntil: window.monolithVoiceTest.state.directListenUntil,
      now: Date.now()
    }));
    assert.equal(afterWakeResponse.status, "listening");
    assert.ok(afterWakeResponse.directListenUntil > afterWakeResponse.now, "the direct-listen window did not begin after speech ended");
    await page.evaluate(async () => {
      window.monolithVoiceTest.state.localWakeEnabled = false;
      await window.monolithVoiceTest.stop("off");
    });
    await openIsolatedVoiceSession(page);

    const failedStart = await page.evaluate(async () => {
      window.__voiceMock.speechHold = false;
      window.__voiceMock.recognitionMode = "throw";
      return window.monolithVoiceTest.capture();
    });
    assert.equal(failedStart, false);
    assert.equal(await page.evaluate(() => window.monolithVoiceTest.state.status), "error");
    assert.equal(await page.evaluate(() => document.getElementById("voiceTalkNow").disabled), false);

    const noResultStarted = await page.evaluate(async () => {
      window.__voiceMock.recognitionMode = "auto-end";
      return window.monolithVoiceTest.capture();
    });
    assert.equal(noResultStarted, true);
    await page.waitForFunction(() => window.monolithVoiceTest.state.status === "no-speech");
    assert.equal(await page.evaluate(() => document.getElementById("voiceTranscript").textContent), "Nenhuma transcrição recebida.");

    const retryStarted = await page.evaluate(async () => {
      window.__voiceMock.recognitionMode = "auto";
      document.getElementById("voiceResponsesEnabled").checked = false;
      document.getElementById("voiceResponsesEnabled").dispatchEvent(new Event("change", { bubbles: true }));
      return window.monolithVoiceTest.capture();
    });
    assert.equal(retryStarted, true);

    const interim = await page.evaluate(async () => {
      const alternative = { transcript: "80 quilos", confidence: 0.99 };
      const result = [alternative];
      result.isFinal = false;
      await window.monolithVoiceTest.handleResult({ resultIndex: 0, results: [result] });
      return {
        transcript: document.getElementById("voiceTranscript").textContent,
        completed: document.querySelectorAll(".set-done-v2.done").length
      };
    });
    assert.deepEqual(interim, { transcript: "80 quilos", completed: 0 });

    const applied = await page.evaluate(async () => {
      const event = () => {
        const alternative = { transcript: "80 quilos 10 repetições", confidence: 0.99 };
        const result = [alternative];
        result.isFinal = true;
        return { resultIndex: 0, results: [result] };
      };
      const recognition = window.__voiceMock.recognitions.at(-1);
      await window.monolithVoiceTest.handleResult(event());
      recognition.onresult(event());
      await Promise.resolve();
      return {
        transcript: document.getElementById("voiceTranscript").textContent,
        status: window.monolithVoiceTest.state.status,
        rows: [...document.querySelectorAll("#sessionExercises tr[data-set-index]")].map(row => ({
          weight: row.querySelector(".session-weight").value,
          reps: row.querySelector(".session-reps").value,
          type: row.querySelector(".session-type").value,
          rest: row.querySelector(".session-rest").value,
          done: row.querySelector(".set-done-v2").classList.contains("done")
        })),
        appliedHistory: window.monolithVoiceTest.state.history.filter(item => item.status === "applied" && item.label === "Série registrada").length
      };
    });
    assert.equal(applied.transcript, "80 quilos 10 repetições");
    assert.equal(applied.status, "sync-pending");
    assert.equal(applied.rows.filter(row => row.done).length, 1);
    assert.deepEqual(applied.rows.slice(1), [
      { weight: "30", reps: "9", type: "warmup", rest: "75", done: false },
      { weight: "40", reps: "10", type: "failure", rest: "90", done: false }
    ]);
    assert.equal(applied.appliedHistory, 1);

    const translations = await page.evaluate(() => {
      const titles = {};
      for (const language of ["en", "es", "pt"]) {
        applyLanguage(language);
        window.monolithVoiceTest.setVisualState("no-speech");
        titles[language] = document.getElementById("voiceStatusTitle").textContent;
      }
      const fallback = document.getElementById("voiceManualCommand");
      return { titles, fallbackVisible: !fallback.hidden && getComputedStyle(fallback).display !== "none" };
    });
    assert.deepEqual(translations.titles, { en: "No speech recognized", es: "No se reconoció ninguna voz", pt: "Nenhuma fala reconhecida" });
    assert.equal(translations.fallbackVisible, true);

    assert.equal(pageErrors.length, 0, pageErrors.join("\n"));
    assert.ok(blockedExternal.some(url => url.includes("cdn.jsdelivr.net")), "external dependencies were not intercepted as expected");
    console.log("qa-v108-voice: all isolated voice checks passed");
  } finally {
    await context.close();
    await browser.close();
    await new Promise(resolve => server.close(resolve));
  }
}

main().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
