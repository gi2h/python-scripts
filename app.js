// app.js

const express = require("express");
const { connect } = require("puppeteer-real-browser");
const crypto = require('crypto');

const turnstile = require("./turnstile");
const interstitial = require("./interstitial");

const app = express();
const port = process.env.PORT || 7860;

app.use(express.json());
app.use(express.urlencoded({ extended: true }));

// =====================================================================
// KONFIGURASI  QUEUE & BROWSER (ENV READY)
// =====================================================================
// parseInt() digunakan untuk mengubah string dari env menjadi angka
const MAX_ACTIVE = parseInt(process.env.MAX_ACTIVE, 10) || 2;           
const MAX_QUEUE = parseInt(process.env.MAX_QUEUE, 10) || 4;            
const QUEUE_TIMEOUT = parseInt(process.env.QUEUE_TIMEOUT, 10) || 60000; 
const MAX_CONTEXTS = parseInt(process.env.MAX_CONTEXTS, 10) || 5; // Kita turunkan default ke 5 agar RAM cepat bersih        // Restart browser setiap 10 task agar RAM bersih

let activeTasks = 0;
const tasks = {};
const queue = [];

let browser;
let browserStarting;
let contextCounter = 0;
let isResetting = false;

// =====================================================================
// BROWSER MANAGEMENT
// =====================================================================
async function init_browser(proxyObj) {
    console.log('[BROWSER] init_browser called');

    if (!browser || !browser.isConnected()) {
        browser = null;
        if (!browserStarting) {
            console.log("--- [BROWSER] Instance started ---");
            
            // Suntikkan Proxy via Args (Jauh lebih stabil)
            const proxyArgs = proxyObj?.server ? [`--proxy-server=${proxyObj.server}`] : [];

            browserStarting = connect({
                headless: false, 
                turnstile: true,
                connectOption: {
                    defaultViewport: null,
                    protocolTimeout: 120000 
                },
                disableXvfb: true, 
                args: [
                    "--no-sandbox",
                    "--display=:99",
                    "--disable-gpu",
                    "--disable-dev-shm-usage",
                    "--disable-setuid-sandbox",
                    "--disable-blink-features=AutomationControlled",
                    // DNS Bypass
                    "--host-resolver-rules=MAP challenges.cloudflare.com 104.16.132.229, MAP *.challenges.cloudflare.com 104.16.132.229",
                    "--dns-over-https-mode=secure",
                    "--dns-over-https-templates=https://cloudflare-dns.com/dns-query",
                    ...proxyArgs
                ],
            }).then(ctx => {
                browser = ctx.browser;
                console.log('[BROWSER] Browser connected');
                browser.on('disconnected', () => {
                    browser = null;
                    browserStarting = null; 
                });
                return browser;
            }).catch(err => {
                browserStarting = null;
                throw { usr: "ERROR_CAPTCHA_UNSOLVABLE", api: `launch error: ${err.message}` };
            });
        }
        await browserStarting;
    }

    try {
        const context = await browser.createBrowserContext();
        const page = await context.newPage();
        
        if (proxyObj?.username) {
            await page.authenticate({ 
                username: proxyObj.username, 
                password: proxyObj.password 
            });
        }
        
        page.setDefaultNavigationTimeout(60000);
        return { page, context }; 
    } catch (err) {
        throw { usr: "ERROR_CAPTCHA_UNSOLVABLE", api: `ctx error: ${err.message}` };
    }
}

async function reset_browser() {
    if (isResetting) return;
    isResetting = true;
    browserStarting = null; 
    if (browser) {
        await browser.close().catch(() => {});
        browser = null;
    }
    contextCounter = 0;
    console.log("--- [BROWSER] Instance closed & rotated (RAM Cleared) ---");
    isResetting = false;
}

// =====================================================================
// QUEUE PROCESSOR
// =====================================================================
function processQueue() {
    if (activeTasks >= MAX_ACTIVE || queue.length === 0) return;

    // Ambil antrean terdepan
    const taskId = queue.shift();
    const task = tasks[taskId];

    // Jika task sudah dihapus atau error sebelumnya, lewati
    if (!task || task.status !== "pending") {
        return processQueue();
    }

    // Batalkan timer antrean
    if (task.queueTimer) {
        clearTimeout(task.queueTimer);
        task.queueTimer = null;
    }

    activeTasks++;
    task.status = "processing";

    // Jalankan Task
    executeTask(taskId, task.data).finally(() => {
        activeTasks--;
        // Setelah selesai, panggil processQueue lagi untuk task berikutnya
        setImmediate(() => processQueue());
    });
}

async function executeTask(taskId, data) {
    let ctx = null;
    try {
        if (contextCounter >= MAX_CONTEXTS) {
            await reset_browser();
        }

        ctx = await init_browser(data.proxyObj);
        contextCounter++;

        let result;
        if (data.method === "turnstile") {
            result = await turnstile({ domain: data.domain, siteKey: data.siteKey, action: data.action, cdata: data.cdata, pagedata: data.pagedata }, ctx.page);
        } else if (data.method === "interstitial") {
            result = await interstitial({ domain: data.domain, payload: data.payload }, ctx.page); 
        }

        const solution = {};
        if (data.method === "turnstile") {
            solution.token = result.token;
        } else if (data.method === "interstitial") {
            solution.cf_clearance = result.solution?.clearance || "";
            solution.user_agent = result.solution?.user_agent || "";
            if (result.solution?.__cf_bm) {
                solution.__cf_bm = result.solution.__cf_bm;
            }
        }

        tasks[taskId] = { 
            status: "ready", 
            taskId: taskId,
            solution: solution
        };
        
        // Hapus dari memori otomatis jika tidak di-poll dalam 30 detik
        setTimeout(() => { delete tasks[taskId]; }, 30000);

    } catch (err) {
        console.error(`[Task ${taskId}] Solver error:`, err);
        const usr = err.usr || "ERROR_CAPTCHA_UNSOLVABLE";
        const api = err.api || err.message || String(err);
        
        tasks[taskId] = {
            status: "error",
            taskId: taskId,
            err: {
                usr: usr,
                api: api,
                msg: "Internal solver error occurred."
            } 
        };
        setTimeout(() => { delete tasks[taskId]; }, 10000);

    } finally {
        // BERSIHKAN BROWSER SEGERA (TANPA DELAY)
        if (ctx) {
            try {
                if (ctx.page) await ctx.page.close().catch(() => {});
                if (ctx.context) await ctx.context.close().catch(() => {});
                console.log(`[Task ${taskId}] Browser context cleaned up immediately.`);
            } catch (err) {
                console.error(`[Task ${taskId}] cleanup failed`, err.message);
            }
        }
    }
}

// =====================================================================
// ROUTES
// =====================================================================
app.get("/", (req, res) => {
    res.status(200).json({
        status: "ok",
        message: "ready",
        active: activeTasks,
        queue: queue.length,
        uptime: `${Math.floor(process.uptime())}s`
    });
});

app.post("/solve", async (req, res) => {
    const body = req.body;
    const reqTaskId = body.taskId;

    // --- PROSES POLLING ---
    if (reqTaskId) {
        const existingTask = tasks[reqTaskId];
        if (!existingTask) {
            return res.status(200).json({
                status: "error",
                taskId: reqTaskId,
                err: { usr: "TASK_NOT_FOUND", api: "Task not found or expired." }
            });
        }
        
        // Jika client polling dan task sudah selesai/error, hapus dari memori
        if (existingTask.status !== "pending" && existingTask.status !== "processing") {
            delete tasks[reqTaskId];
        }

        // 🔥 PERBAIKAN DI SINI: Hanya kirim data yang aman (tanpa timer) 🔥
        const safeResponse = {
            status: existingTask.status,
            taskId: existingTask.taskId,
            solution: existingTask.solution || null,
            err: existingTask.err || null
        };
        return res.status(200).json(safeResponse);
    }

    // --- VALIDASI INPUT ---
    if (body.method !== "CloudflareTask" || typeof body.task !== "object") {
        return res.status(400).json({ status: "error", err: { usr: "BAD_PARAMETERS" } });
    }

    const task = body.task;
    const method = (task.type || "").toLowerCase();
    const domain = task.websiteUrl;
    const siteKey = task.websiteKey;
    const rawProxy = task.proxy;

    // --- CEK QUEUE PENUH ---
    if (queue.length >= MAX_QUEUE) {
        return res.status(429).json({
            status: "error",
            err: { usr: "QUEUE_FULL", msg: "Slot antrean penuh, silakan coba lagi nanti." }
        });
    }

    // --- PARSE PROXY ---
    let proxyObj = null;
    if (rawProxy && typeof rawProxy === 'object' && rawProxy.host) {
        const pType = rawProxy.type || 'http';
        const auth = (rawProxy.user && rawProxy.pass) ? `${rawProxy.user}:${rawProxy.pass}@` : "";
        const proxyString = `${pType}://${auth}${rawProxy.host}:${rawProxy.port}`;
        const u = new URL(proxyString);
        proxyObj = { server: `${u.protocol}//${u.host}`, username: u.username, password: u.password };
    } else if (typeof rawProxy === 'string') {
        const u = new URL(rawProxy);
        proxyObj = { server: `${u.protocol}//${u.host}`, username: u.username, password: u.password };
    }

    // --- BUAT TASK BARU ---
    const newTaskId = crypto.randomUUID().replace(/-/g, '').slice(0, 12);
    tasks[newTaskId] = { status: "pending", taskId: newTaskId };
    
    // Timer jika task terlalu lama di antrean (60 detik)
    const queueTimer = setTimeout(() => {
        const idx = queue.indexOf(newTaskId);
        if (idx !== -1) {
            queue.splice(idx, 1);
            tasks[newTaskId] = {
                status: "error",
                taskId: newTaskId,
                err: { usr: "QUEUE_TIMEOUT", msg: "Antrean gagal, melebihi 60 detik." }
            };
            console.log(`[Task ${newTaskId}] Queue Timeout (60s).`);
            setTimeout(() => { delete tasks[newTaskId]; }, 10000);
        }
    }, QUEUE_TIMEOUT);

    // Simpan data untuk dieksekusi
    tasks[newTaskId].data = { method, domain, siteKey, action: task.action, cdata: task.cdata, pagedata: task.pdata, payload: task.payload, proxyObj };
    tasks[newTaskId].queueTimer = queueTimer;

    queue.push(newTaskId);
    processQueue(); // Coba jalankan jika ada slot kosong

    res.status(202).json({ taskId: newTaskId, status: "pending" });
});

// Error Handler
app.use((err, req, res, next) => {
    res.status(500).json({ status: "error", err: { usr: "INTERNAL_SERVER_ERROR", api: err.message } });
});

// =====================================================================
// STARTUP & SHUTDOWN
// =====================================================================
app.listen(port, '0.0.0.0', () => {
    console.log(`Server running: http://0.0.0.0:${port}`);
    console.log(`[CONFIG] Max Active: ${MAX_ACTIVE} | Max Queue: ${MAX_QUEUE} | Queue Timeout: ${QUEUE_TIMEOUT/1000}s`);
});

const cleanup = async (code) => {
    if (browser) { try { await browser.close(); } catch (e) {} }
    process.exit(code);
};
process.on("SIGINT", () => cleanup(1));
process.on("SIGTERM", () => cleanup(9));
