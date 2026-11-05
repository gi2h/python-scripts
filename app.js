// app.js — Solver (Recycle Chromium Only, No Container Restart)

const express  = require("express");
const { connect } = require("puppeteer-real-browser");
const crypto   = require("crypto");
const fs       = require("fs");
const path     = require("path");
const { execSync } = require("child_process");

const turnstile    = require("./turnstile");
const interstitial = require("./interstitial");

const app = express();
const port = process.env.PORT || 7860;
app.use(express.json());
app.use(express.urlencoded({ extended: true }));

// ============================================================
// CONFIG
// ============================================================
const MAX_ACTIVE    = parseInt(process.env.MAX_ACTIVE, 10)    || 2;
const MAX_QUEUE     = parseInt(process.env.MAX_QUEUE, 10)     || 4;
const QUEUE_TIMEOUT = parseInt(process.env.QUEUE_TIMEOUT, 10) || 60000;
const MAX_CONTEXTS  = parseInt(process.env.MAX_CONTEXTS, 10)  || 5;
const TASK_TIMEOUT  = parseInt(process.env.TASK_TIMEOUT, 10)  || 120000;

// RAM thresholds (total container, termasuk Chromium)
const RAM_SOFT_MB   = parseInt(process.env.RAM_SOFT_MB, 10)   || 380;
const RAM_HARD_MB   = parseInt(process.env.RAM_HARD_MB, 10)   || 460;

// Interval pengawas
const HEALTH_MS     = parseInt(process.env.HEALTH_MS, 10)     || 30000;
const CLEANUP_MS    = parseInt(process.env.CLEANUP_MS, 10)    || 300000;

let activeTasks     = 0;
let browser         = null;
let browserStarting = null;
let contextCounter  = 0;
let isResetting     = false;

const tasks = Object.create(null);
const queue = [];

const LAUNCH_OPTS = {
    headless: false,
    turnstile: true,
    disableXvfb: false,
    customConfig: {
        chromePath: process.env.CHROME_PATH || "/usr/bin/chromium",
        args: [
            "--no-sandbox",
            "--disable-setuid-sandbox",
            "--disable-dev-shm-usage",
            "--disable-gpu",
            "--disable-software-rasterizer",
            "--js-flags=--max-old-space-size=256",
            "--renderer-process-limit=2",
            "--disable-background-networking",
            "--disable-component-update",
            "--disable-default-apps",
            "--disable-extensions",
            "--disable-sync",
            "--mute-audio",
            "--no-first-run",
            "--disable-features=Translate,BackForwardCache,AcceptCHFrame,MediaRouter,OptimizationHints,RenderDocument"
        ]
    }
};

// ============================================================
// RAM / STORAGE HELPERS
// ============================================================
function getContainerRAM_MB() {
    // cgroup v2
    try {
        const v = fs.readFileSync("/sys/fs/cgroup/memory.current", "utf8").trim();
        return Math.round(parseInt(v, 10) / 1024 / 1024);
    } catch (_) {}
    // cgroup v1
    try {
        const v = fs.readFileSync("/sys/fs/cgroup/memory/memory.usage_in_bytes", "utf8").trim();
        return Math.round(parseInt(v, 10) / 1024 / 1024);
    } catch (_) {}
    return Math.round(process.memoryUsage().rss / 1024 / 1024);
}

async function killStrayChromeXvfb() {
    // Bunuh sisa proses Chromium/Xvfb yang mungkin jadi zombie
    try {
        execSync("pkill -9 -f 'chrome|chromium|Xvfb|xvfb-run' || true", { stdio: "ignore", shell: "/bin/sh" });
    } catch (_) {}
}

async function cleanupStorage() {
    // Bersihkan folder profile Chromium sementara & cache
    try {
        const cleanupTargets = ["/tmp", "/root/.cache", "/home/node/.cache"];
        let removed = 0;
        for (const base of cleanupTargets) {
            if (!fs.existsSync(base)) continue;
            for (const entry of fs.readdirSync(base)) {
                if (
                    entry.startsWith("puppeteer_dev_chrome_profile-") ||
                    entry.startsWith("puppeteer_dev_profile-") ||
                    entry.startsWith(".org.chromium.Chromium") ||
                    entry.startsWith("lighthouse.")
                ) {
                    try {
                        fs.rmSync(path.join(base, entry), { recursive: true, force: true });
                        removed++;
                    } catch (_) {}
                }
            }
        }
        if (removed) console.log(`[CLEANUP] Hapus ${removed} folder profile Chromium`);
    } catch (e) {
        console.warn("[CLEANUP] Gagal:", e.message);
    }
}

// ============================================================
// BROWSER MANAGEMENT
// ============================================================
async function init_browser() {
    if (!browser || !browser.isConnected()) {
        if (!browserStarting) {
            console.log("[BROWSER] Launching Chromium...");
            browserStarting = connect(LAUNCH_OPTS)
                .then(ctx => {
                    browser = ctx.browser;
                    console.log("[BROWSER] Connected");
                    browser.on("disconnected", () => {
                        console.log("[BROWSER] Disconnected");
                        browser = null;
                        browserStarting = null;
                    });
                    return browser;
                })
                .catch(err => {
                    browserStarting = null;
                    browser = null;
                    throw new Error("Launch failed: " + err.message);
                });
        }
        await browserStarting;
    }

    const context = await browser.createBrowserContext();
    const page = await context.newPage();
    page.setDefaultNavigationTimeout(120000);
    page.setDefaultTimeout(120000);
    return { page, context };
}

// Recycle HANYA Chromium + Xvfb, bukan Node.js
async function recycleChromium(reason = "manual") {
    if (isResetting) return;
    isResetting = true;
    console.log(`[RECYCLE] Chromium+Xvfb (${reason})`);
    try {
        if (browser) {
            try { await browser.close(); } catch (_) {}  // close() mematikan Chromium
        }
        browser = null;
        browserStarting = null;
        contextCounter = 0;

        // Bunuh sisa Xvfb jika ada
        await killStrayChromeXvfb();

        // Bersihkan storage setelah close
        await cleanupStorage();
    } finally {
        isResetting = false;
    }
}

// ============================================================
// HEALTH LOOP (deteksi crash + RAM + storage)
// ============================================================
async function healthTick() {
    // 1. Deteksi disconnect
    if (browser && !browser.isConnected()) {
        console.warn("[HEALTH] Browser disconnected → recycle");
        await recycleChromium("disconnected");
        return;
    }

    // 2. Deteksi hang (respons lambat)
    if (browser && browser.isConnected()) {
        try {
            await Promise.race([
                browser.pages(),
                new Promise((_, rej) => setTimeout(() => rej(new Error("timeout")), 5000))
            ]);
        } catch (e) {
            console.warn("[HEALTH] Browser unresponsive:", e.message, "→ recycle");
            await recycleChromium("unresponsive");
            return;
        }
    }

    // 3. RAM check (total container, termasuk Chromium)
    const rss = getContainerRAM_MB();
    if (rss >= RAM_HARD_MB) {
        console.warn(`[HEALTH] RAM kritis ${rss}MB ≥ ${RAM_HARD_MB}MB → recycle`);
        await recycleChromium("ram-hard");
    } else if (rss >= RAM_SOFT_MB && activeTasks === 0 && browser) {
        console.log(`[HEALTH] RAM tinggi ${rss}MB ≥ ${RAM_SOFT_MB}MB → recycle (idle)`);
        await recycleChromium("ram-soft");
    }
}

function startLoops() {
    setInterval(() => {
        healthTick().catch(e => console.error("[HEALTH] error:", e.message));
    }, HEALTH_MS).unref?.();

    setInterval(() => {
        cleanupStorage().catch(() => {});
    }, CLEANUP_MS).unref?.();
}

// ============================================================
// TASK MANAGEMENT
// ============================================================
function removeTaskLater(taskId, delay = 30000) {
    setTimeout(() => { delete tasks[taskId]; }, delay).unref?.();
}

function processQueue() {
    while (activeTasks < MAX_ACTIVE && queue.length > 0) {
        const taskId = queue.shift();
        const task = tasks[taskId];
        if (!task || task.status !== "pending") continue;
        if (task.queueTimer) { clearTimeout(task.queueTimer); task.queueTimer = null; }

        activeTasks++;
        task.status = "processing";
        executeTask(taskId, task.data)
            .catch(err => console.error("[TASK ERROR]", taskId, err?.message || err))
            .finally(() => {
                activeTasks--;
                setImmediate(processQueue);
            });
    }
}

function withTimeout(factory, ms) {
    let timer;
    const timeout = new Promise((_, rej) => {
        timer = setTimeout(() => rej(new Error("Task timeout")), ms);
        timer.unref?.();
    });
    return Promise.race([factory(), timeout]).finally(() => clearTimeout(timer));
}

async function executeTask(taskId, data) {
    let ctx = null;
    try {
        if (contextCounter >= MAX_CONTEXTS) {
            await recycleChromium("max-contexts");
        }

        ctx = await init_browser();
        contextCounter++;
        const page = ctx.page;

        let result;
        if (data.method === "turnstile") {
            result = await withTimeout(
                () => turnstile({
                    domain: data.domain, siteKey: data.siteKey,
                    action: data.action, cdata: data.cdata, pagedata: data.pagedata
                }, page), TASK_TIMEOUT
            );
        } else if (data.method === "interstitial") {
            result = await withTimeout(
                () => interstitial({ domain: data.domain, payload: data.payload }, page), TASK_TIMEOUT
            );
        } else {
            throw new Error(`Unknown method: ${data.method}`);
        }

        const solution = {};
        if (data.method === "turnstile") solution.token = result.token;
        else if (data.method === "interstitial") {
            solution.cf_clearance = result.solution?.clearance || "";
            solution.user_agent = result.solution?.user_agent || "";
            if (result.solution?.__cf_bm) solution.__cf_bm = result.solution.__cf_bm;
        }

        tasks[taskId] = { status: "ready", taskId, solution };
        removeTaskLater(taskId);

    } catch (err) {
        console.error(`[Task ${taskId}] error:`, err?.api || err?.message || err);
        tasks[taskId] = {
            status: "error", taskId,
            err: { usr: err?.usr || "ERROR_CAPTCHA_UNSOLVABLE", api: err?.api || err?.message || String(err) }
        };
        removeTaskLater(taskId, 10000);

        // Jika error terindikasi page crash / page closed, jadwalkan recycle
        const msg = (err?.api || err?.message || "").toLowerCase();
        if (msg.includes("page closed") || msg.includes("target closed") || msg.includes("crash")) {
            recycleChromium("page-crash").catch(() => {});
        }
    } finally {
        if (ctx) {
            try { if (ctx.page)    await ctx.page.close().catch(() => {}); } catch (_) {}
            try { if (ctx.context) await ctx.context.close().catch(() => {}); } catch (_) {}
        }
    }
}

// ============================================================
// ROUTES
// ============================================================
app.get("/", (req, res) => {
    res.status(200).json({
        status: "ok",
        browserConnected: !!(browser && browser.isConnected()),
        active: activeTasks,
        queue: queue.length,
        uptime: `${Math.floor(process.uptime())}s`,
        ramMB: getContainerRAM_MB()
    });
});

app.post("/solve", async (req, res) => {
    try {
        const body = req.body;
        const reqTaskId = body.taskId;

        // POLLING
        if (reqTaskId) {
            const existingTask = tasks[reqTaskId];
            if (!existingTask) {
                return res.status(200).json({
                    status: "error", taskId: reqTaskId,
                    err: { usr: "TASK_NOT_FOUND", api: "Task not found or expired." }
                });
            }
            if (existingTask.status !== "pending" && existingTask.status !== "processing") {
                delete tasks[reqTaskId];
            }
            return res.status(200).json({
                status: existingTask.status, taskId: existingTask.taskId,
                solution: existingTask.solution || null, err: existingTask.err || null
            });
        }

        // VALIDASI
        if (body.method !== "CloudflareTask" || typeof body.task !== "object") {
            return res.status(400).json({ status: "error", err: { usr: "BAD_PARAMETERS" } });
        }

        const task    = body.task;
        const method  = (task.type || "").toLowerCase();
        const domain  = task.websiteUrl;
        const siteKey = task.websiteKey;

        if (queue.length >= MAX_QUEUE) {
            return res.status(429).json({ status: "error", err: { usr: "QUEUE_FULL", msg: "Antrean penuh." } });
        }

        // BUAT TASK
        const newTaskId = crypto.randomUUID().replace(/-/g, "").slice(0, 12);
        tasks[newTaskId] = { status: "pending", taskId: newTaskId };

        const queueTimer = setTimeout(() => {
            const idx = queue.indexOf(newTaskId);
            if (idx !== -1) {
                queue.splice(idx, 1);
                tasks[newTaskId] = {
                    status: "error", taskId: newTaskId,
                    err: { usr: "QUEUE_TIMEOUT", msg: `Antrean > ${QUEUE_TIMEOUT/1000}s.` }
                };
                removeTaskLater(newTaskId, 10000);
            }
        }, QUEUE_TIMEOUT);
        queueTimer.unref?.();

        tasks[newTaskId].data = {
            method, domain, siteKey,
            action: task.action, cdata: task.cdata,
            pagedata: task.pdata, payload: task.payload
        };
        tasks[newTaskId].queueTimer = queueTimer;

        queue.push(newTaskId);
        processQueue();

        return res.status(202).json({ taskId: newTaskId, status: "pending" });

    } catch (err) {
        console.error("[SOLVE ERROR]", err?.message || err);
        return res.status(500).json({
            status: "error", err: { usr: "INTERNAL_SERVER_ERROR", api: err?.message || String(err) }
        });
    }
});

app.use((err, req, res, next) => {
    console.error("[EXPRESS ERROR]", err?.message || err);
    if (res.headersSent) return next(err);
    res.status(500).json({ status: "error", message: err?.message || "Internal error" });
});

// ============================================================
// STARTUP & SHUTDOWN
// ============================================================
const server = app.listen(port, "0.0.0.0", () => {
    console.log("====================================");
    console.log("Solver (Recycle Chromium Mode)");
    console.log("Port:", port, "| RAM soft:", RAM_SOFT_MB, "MB | hard:", RAM_HARD_MB, "MB");
    console.log("====================================");
    startLoops();
});

let shuttingDown = false;
async function cleanup(signal) {
    if (shuttingDown) return;
    shuttingDown = true;
    console.log("[SHUTDOWN]", signal);
    try { server.close(); } catch (_) {}
    for (const task of Object.values(tasks)) {
        if (task.queueTimer) clearTimeout(task.queueTimer);
    }
    try { if (browser) await browser.close(); } catch (_) {}
    await killStrayChromeXvfb();
    process.exit(0);
}

process.on("SIGINT",  () => cleanup("SIGINT"));
process.on("SIGTERM", () => cleanup("SIGTERM"));
process.on("unhandledRejection", err => console.error("[UNHANDLED REJECTION]", err?.message || err));
process.on("uncaughtException",  err => console.error("[UNCAUGHT EXCEPTION]",  err?.message || err));
