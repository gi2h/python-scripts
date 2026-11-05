// app.js — Railway Cloudflare Solver (Optimized & Turnstile Safe)

const express  = require("express");
const { connect } = require("puppeteer-real-browser");
const crypto   = require("crypto");

const turnstile    = require("./turnstile");
const interstitial = require("./interstitial");

const app = express();
const port = process.env.PORT || 7860;

app.use(express.json());
app.use(express.urlencoded({ extended: true }));

// ============================================================
// CONFIGURATION
// ============================================================
const MAX_ACTIVE    = parseInt(process.env.MAX_ACTIVE, 10)    || 2;
const MAX_QUEUE     = parseInt(process.env.MAX_QUEUE, 10)     || 4;
const QUEUE_TIMEOUT = parseInt(process.env.QUEUE_TIMEOUT, 10) || 60000;
const MAX_CONTEXTS  = parseInt(process.env.MAX_CONTEXTS, 10)  || 5; // Turunkan ke 5 agar RAM cepat bersih
const TASK_TIMEOUT  = parseInt(process.env.TASK_TIMEOUT, 10)  || 120000;

let activeTasks     = 0;
let browser         = null;
let browserStarting = null;
let contextCounter  = 0;
let isResetting     = false;

const tasks = Object.create(null);
const queue = [];

// ============================================================
// BROWSER MANAGEMENT (Railway Optimized)
// ============================================================
async function init_browser() {
    if (!browser || !browser.isConnected()) {
        if (!browserStarting) {
            console.log("[BROWSER] Meluncurkan Chromium (Railway Safe Mode)...");
            
            browserStarting = connect({
                headless: false,      // Wajib false agar Cloudflare lolos
                turnstile: true,      
                disableXvfb: false,   // Wajib false agar Railway menjalankan Xvfb
                customConfig: {
                    chromePath: process.env.CHROME_PATH || '/usr/bin/chromium',
                    args: [
                        '--no-sandbox',
                        '--disable-setuid-sandbox',
                        '--disable-dev-shm-usage',
                        
                        // 🛑 MATIKAN GPU (Hemat RAM & Aman untuk Turnstile)
                        '--disable-gpu',
                        '--disable-software-rasterizer',
                        
                        // 🧠 BATASI MEMORI V8 (Mencegah OOM)
                        '--js-flags="--max-old-space-size=256"',
                        '--renderer-process-limit=2', // Biarkan 2 proses untuk mencegah Cloudflare block
                        
                        // 🚫 MATIKAN FITUR LATAR BELAKANG
                        '--disable-background-networking',
                        '--disable-component-update',
                        '--disable-default-apps',
                        '--disable-extensions',
                        '--disable-sync',
                        '--mute-audio',
                        '--no-first-run',
                        '--disable-features=Translate,BackForwardCache,AcceptCHFrame,MediaRouter,OptimizationHints,RenderDocument'
                    ]
                }
            }).then(ctx => {
                browser = ctx.browser;
                console.log("[BROWSER] Chromium berhasil diluncurkan!");
                
                browser.on("disconnected", () => {
                    console.log("[BROWSER] Disconnected");
                    browser = null;
                    browserStarting = null;
                });
                return browser;
            }).catch(err => {
                browserStarting = null;
                throw new Error("Launch failed: " + err.message);
            });
        }
        await browserStarting;
    }

    const context = await browser.createBrowserContext();
    const page = await context.newPage();
    page.setDefaultNavigationTimeout(60000);
    page.setDefaultTimeout(30000);
    return { page, context };
}

async function reset_browser() {
    if (isResetting) return;
    isResetting = true;
    try {
        if (browser && browser.isConnected()) {
            await browser.close().catch(() => {});
        }
        browser = null;
        browserStarting = null;
        contextCounter = 0;
        console.log("[BROWSER] Chromium di-reset (RAM Cleared).");
    } finally {
        isResetting = false;
    }
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
        const task   = tasks[taskId];

        if (!task || task.status !== "pending") continue;

        if (task.queueTimer) {
            clearTimeout(task.queueTimer);
            task.queueTimer = null;
        }

        activeTasks++;
        task.status = "processing";

        executeTask(taskId, task.data)
            .catch(err => { console.error("[TASK ERROR]", taskId, err.message); })
            .finally(() => {
                activeTasks--;
                setImmediate(processQueue);
            });
    }
}

// ============================================================
// SOLVER TASK
// ============================================================
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
        // Reset browser setiap 5 task agar RAM tidak menumpuk
        if (contextCounter >= MAX_CONTEXTS) {
            await reset_browser();
        }

        ctx = await init_browser();
        contextCounter++;

        const page = ctx.page;

        if (data.proxyObj) {
            console.warn(`[Task ${taskId}] Proxy per-task diabaikan di Railway Launch Mode.`);
        }

        let result;
        if (data.method === "turnstile") {
            result = await withTimeout(
                () => turnstile({
                    domain:   data.domain,
                    siteKey:  data.siteKey,
                    action:   data.action,
                    cdata:    data.cdata,
                    pagedata: data.pagedata
                }, page),
                TASK_TIMEOUT
            );
        } else if (data.method === "interstitial") {
            result = await withTimeout(
                () => interstitial({ domain: data.domain, payload: data.payload }, page),
                TASK_TIMEOUT
            );
        } else {
            throw new Error(`Unknown method: ${data.method}`);
        }

        const solution = {};
        if (data.method === "turnstile") {
            solution.token = result.token;
        } else if (data.method === "interstitial") {
            solution.cf_clearance = result.solution?.clearance  || "";
            solution.user_agent   = result.solution?.user_agent || "";
            if (result.solution?.__cf_bm) {
                solution.__cf_bm = result.solution.__cf_bm;
            }
        }

        tasks[taskId] = { status: "ready", taskId, solution };
        removeTaskLater(taskId);

    } catch (err) {
        console.error(`[Task ${taskId}] Solver error:`, err);
        const usr = err.usr || "ERROR_CAPTCHA_UNSOLVABLE";
        const api = err.api || err.message || String(err);

        tasks[taskId] = {
            status: "error",
            taskId,
            err: { usr, api, msg: "Internal solver error occurred." }
        };
        removeTaskLater(taskId, 10000);

    } finally {
        if (ctx) {
            try {
                // Bersihkan context SEGERA agar RAM langsung turun
                if (ctx.page)    await ctx.page.close().catch(() => {});
                if (ctx.context) await ctx.context.close().catch(() => {});
                console.log(`[Task ${taskId}] Browser context cleaned up.`);
            } catch (err) {
                console.error(`[Task ${taskId}] Cleanup failed:`, err.message);
            }
        }
    }
}

// ============================================================
// ROUTES
// ============================================================
app.get("/", (req, res) => {
    res.status(200).json({
        status: "ok",
        message: "Railway Solver Ready",
        browserConnected: !!(browser && browser.isConnected()),
        active: activeTasks,
        queue: queue.length,
        uptime: `${Math.floor(process.uptime())}s`
    });
});

app.post("/solve", async (req, res) => {
    try {
        const body = req.body;
        const reqTaskId = body.taskId;

        // --- POLLING ---
        if (reqTaskId) {
            const existingTask = tasks[reqTaskId];
            if (!existingTask) {
                return res.status(200).json({
                    status: "error",
                    taskId: reqTaskId,
                    err: { usr: "TASK_NOT_FOUND", api: "Task not found or expired." }
                });
            }

            if (existingTask.status !== "pending" && existingTask.status !== "processing") {
                delete tasks[reqTaskId];
            }

            return res.status(200).json({
                status:   existingTask.status,
                taskId:   existingTask.taskId,
                solution: existingTask.solution || null,
                err:      existingTask.err      || null
            });
        }

        // --- VALIDASI INPUT ---
        if (body.method !== "CloudflareTask" || typeof body.task !== "object") {
            return res.status(400).json({ status: "error", err: { usr: "BAD_PARAMETERS" } });
        }

        const task     = body.task;
        const method   = (task.type || "").toLowerCase();
        const domain   = task.websiteUrl;
        const siteKey  = task.websiteKey;
        const rawProxy = task.proxy;

        if (queue.length >= MAX_QUEUE) {
            return res.status(429).json({
                status: "error",
                err: { usr: "QUEUE_FULL", msg: "Slot antrean penuh." }
            });
        }

        // --- PARSE PROXY ---
        let proxyObj = null;
        try {
            if (rawProxy && typeof rawProxy === "object" && rawProxy.host) {
                const pType = rawProxy.type || "http";
                const auth  = (rawProxy.user && rawProxy.pass) ? `${rawProxy.user}:${rawProxy.pass}@` : "";
                const u     = new URL(`${pType}://${auth}${rawProxy.host}:${rawProxy.port}`);
                proxyObj = { server: `${u.protocol}//${u.host}`, username: u.username, password: u.password };
            } else if (typeof rawProxy === "string" && rawProxy.length > 0) {
                const u = new URL(rawProxy);
                proxyObj = { server: `${u.protocol}//${u.host}`, username: u.username, password: u.password };
            }
        } catch (e) {
            return res.status(400).json({
                status: "error",
                err: { usr: "BAD_PROXY", api: e.message }
            });
        }

        // --- BUAT TASK BARU ---
        const newTaskId = crypto.randomUUID().replace(/-/g, "").slice(0, 12);
        tasks[newTaskId] = { status: "pending", taskId: newTaskId };

        const queueTimer = setTimeout(() => {
            const idx = queue.indexOf(newTaskId);
            if (idx !== -1) {
                queue.splice(idx, 1);
                tasks[newTaskId] = {
                    status: "error",
                    taskId: newTaskId,
                    err: { usr: "QUEUE_TIMEOUT", msg: `Antrean gagal, melebihi ${QUEUE_TIMEOUT/1000} detik.` }
                };
                removeTaskLater(newTaskId, 10000);
            }
        }, QUEUE_TIMEOUT);
        queueTimer.unref?.();

        tasks[newTaskId].data = {
            method, domain, siteKey,
            action:   task.action,
            cdata:    task.cdata,
            pagedata: task.pdata,
            payload:  task.payload,
            proxyObj
        };
        tasks[newTaskId].queueTimer = queueTimer;

        queue.push(newTaskId);
        processQueue();

        return res.status(202).json({ taskId: newTaskId, status: "pending" });

    } catch (err) {
        console.error("[SOLVE ERROR]", err);
        return res.status(500).json({
            status: "error",
            err: { usr: "INTERNAL_SERVER_ERROR", api: err.message }
        });
    }
});

// ============================================================
// ERROR HANDLER
// ============================================================
app.use((err, req, res, next) => {
    console.error("[EXPRESS ERROR]", err);
    if (res.headersSent) return next(err);
    res.status(500).json({ status: "error", message: err.message || "Internal server error" });
});

// ============================================================
// STARTUP
// ============================================================
const server = app.listen(port, "0.0.0.0", () => {
    console.log("====================================");
    console.log("Railway Chromium Solver (Safe Mode)");
    console.log("Port:", port);
    console.log("CHROME_PATH:", process.env.CHROME_PATH || '/usr/bin/chromium');
    console.log("MAX_CONTEXTS:", MAX_CONTEXTS);
    console.log("====================================");
});

// ============================================================
// SHUTDOWN
// ============================================================
let shuttingDown = false;
async function cleanup(signal) {
    if (shuttingDown) return;
    shuttingDown = true;
    console.log("[SHUTDOWN]", signal);

    server.close();

    for (const task of Object.values(tasks)) {
        if (task.queueTimer) clearTimeout(task.queueTimer);
    }

    if (browser && browser.isConnected()) {
        await browser.close().catch(() => {});
    }

    process.exit(0);
}

process.on("SIGINT",  () => cleanup("SIGINT"));
process.on("SIGTERM", () => cleanup("SIGTERM"));
process.on("unhandledRejection", err => { console.error("[UNHANDLED REJECTION]", err); });
process.on("uncaughtException",  err => { console.error("[UNCAUGHT EXCEPTION]",  err); });
