// app.js - PERSISTENT BROWSER POOL

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
// KONFIGURASI
// =====================================================================
const MAX_ACTIVE = 3;
const MAX_QUEUE = 12;
const QUEUE_TIMEOUT = 60000;

let activeTasks = 0;
const tasks = {};
const queue = [];

// Browser Pool
const browserPool = []; // [{ browser, busy }]
let poolReady = false;
let isInitializing = false;

// =====================================================================
// BROWSER POOL INIT (Sekali saja)
// =====================================================================
async function initPool() {
    if (poolReady || isInitializing) return;
    isInitializing = true;
    
    console.log(`[POOL] Initializing ${MAX_ACTIVE} persistent browsers...`);
    
    for (let i = 0; i < MAX_ACTIVE; i++) {
        try {
            const { browser, page } = await connect({
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
                    "--host-resolver-rules=MAP challenges.cloudflare.com 104.16.132.229, MAP *.challenges.cloudflare.com 104.16.132.229",
                    "--dns-over-https-mode=secure",
                    "--dns-over-https-templates=https://cloudflare-dns.com/dns-query"
                ],
            });
            
            // Tutup page default, kita akan buka page sendiri per task
            await page.close().catch(() => {});
            
            browser.on('disconnected', () => {
                const slot = browserPool.find(s => s.browser === browser);
                if (slot) {
                    slot.browser = null;
                    slot.busy = false;
                    console.log(`[POOL] Browser ${i} disconnected. Will re-init on next use.`);
                }
            });
            
            browserPool.push({ browser, busy: false, id: i });
            console.log(`[POOL] Browser ${i} ready`);
        } catch (err) {
            console.error(`[POOL] Browser ${i} failed: ${err.message}`);
            browserPool.push({ browser: null, busy: false, id: i });
        }
    }
    
    poolReady = true;
    isInitializing = false;
    console.log(`[POOL] Pool ready with ${browserPool.filter(s => s.browser).length}/${MAX_ACTIVE} browsers`);
}

// =====================================================================
// ACQUIRE / RELEASE
// =====================================================================
async function acquireBrowser() {
    // Tunggu jika semua busy
    while (true) {
        for (const slot of browserPool) {
            if (!slot.busy) {
                slot.busy = true;
                
                // Kalau browser crash, re-init
                if (!slot.browser || !slot.browser.isConnected()) {
                    console.log(`[POOL] Re-initializing browser ${slot.id}...`);
                    try {
                        const { browser, page } = await connect({
                            headless: false, turnstile: true,
                            connectOption: { defaultViewport: null, protocolTimeout: 120000 },
                            disableXvfb: true, 
                            args: ["--no-sandbox", "--display=:99", "--disable-gpu", "--disable-dev-shm-usage",
                                   "--disable-setuid-sandbox", "--disable-blink-features=AutomationControlled",
                                   "--host-resolver-rules=MAP challenges.cloudflare.com 104.16.132.229, MAP *.challenges.cloudflare.com 104.16.132.229",
                                   "--dns-over-https-mode=secure", "--dns-over-https-templates=https://cloudflare-dns.com/dns-query"]
                        });
                        await page.close().catch(() => {});
                        slot.browser = browser;
                    } catch (e) {
                        slot.busy = false;
                        throw new Error(`Cannot re-init browser: ${e.message}`);
                    }
                }
                return slot;
            }
        }
        await new Promise(r => setTimeout(r, 200));
    }
}

function releaseBrowser(slot) {
    slot.busy = false;
}

// =====================================================================
// QUEUE PROCESSOR
// =====================================================================
function processQueue() {
    if (activeTasks >= MAX_ACTIVE || queue.length === 0) return;

    const taskId = queue.shift();
    const task = tasks[taskId];

    if (!task || task.status !== "pending") {
        return processQueue();
    }

    if (task.queueTimer) {
        clearTimeout(task.queueTimer);
        task.queueTimer = null;
    }

    activeTasks++;
    task.status = "processing";

    executeTask(taskId, task.data).finally(() => {
        activeTasks--;
        setImmediate(() => processQueue());
    });
}

async function executeTask(taskId, data) {
    let context = null;
    let page = null;
    let slot = null;
    
    try {
        slot = await acquireBrowser();
        
        // Buat CONTEXT BARU di browser yang di-reuse (isolasi penuh!)
        context = await slot.browser.createBrowserContext();
        page = await context.newPage();
        
        if (data.proxyObj?.username) {
            await page.authenticate({
                username: data.proxyObj.username,
                password: data.proxyObj.password
            });
        }
        
        page.setDefaultNavigationTimeout(60000);
        
        let result;
        if (data.method === "turnstile") {
            result = await turnstile({ domain: data.domain, siteKey: data.siteKey, action: data.action, cdata: data.cdata, pagedata: data.pagedata }, page);
        } else if (data.method === "interstitial") {
            result = await interstitial({ domain: data.domain, payload: data.payload }, page); 
        }
        
        const solution = {};
        if (data.method === "turnstile") {
            solution.token = result.token;
        } else if (data.method === "interstitial") {
            solution.cf_clearance = result.solution?.clearance || "";
            solution.user_agent = result.solution?.user_agent || "";
            if (result.solution?.__cf_bm) solution.__cf_bm = result.solution.__cf_bm;
        }
        
        tasks[taskId] = { status: "ready", taskId, solution };
        setTimeout(() => { delete tasks[taskId]; }, 30000);
        
    } catch (err) {
        console.error(`[Task ${taskId}] Error:`, err);
        tasks[taskId] = {
            status: "error", taskId,
            err: { usr: err.usr || "ERROR_CAPTCHA_UNSOLVABLE", api: err.api || err.message }
        };
        setTimeout(() => { delete tasks[taskId]; }, 10000);
    } finally {
        // Close PAGE dan CONTEXT (bukan browser!)
        if (page) await page.close().catch(() => {});
        if (context) await context.close().catch(() => {});
        if (slot) releaseBrowser(slot);
    }
}

// =====================================================================
// ROUTES (sama seperti sebelumnya)
// =====================================================================
app.get("/", (req, res) => {
    res.json({
        status: "ok",
        active: activeTasks,
        queue: queue.length,
        pool: browserPool.map(s => ({ id: s.id, busy: s.busy, alive: !!(s.browser && s.browser.isConnected()) }))
    });
});

app.post("/solve", async (req, res) => {
    const body = req.body;
    const reqTaskId = body.taskId;

    if (reqTaskId) {
        const existingTask = tasks[reqTaskId];
        if (!existingTask) return res.json({ status: "error", taskId: reqTaskId, err: { usr: "TASK_NOT_FOUND" } });
        if (existingTask.status !== "pending" && existingTask.status !== "processing") delete tasks[reqTaskId];
        return res.json(existingTask);
    }

    if (body.method !== "CloudflareTask" || typeof body.task !== "object") {
        return res.status(400).json({ status: "error", err: { usr: "BAD_PARAMETERS" } });
    }

    const task = body.task;
    const method = (task.type || "").toLowerCase();
    const domain = task.websiteUrl;
    const siteKey = task.websiteKey;
    const rawProxy = task.proxy;

    if (queue.length >= MAX_QUEUE) {
        return res.status(429).json({ status: "error", err: { usr: "QUEUE_FULL", msg: "Slot antrean penuh, coba lagi." } });
    }

    let proxyObj = null;
    if (rawProxy && typeof rawProxy === 'object' && rawProxy.host) {
        const pType = rawProxy.type || 'http';
        const auth = (rawProxy.user && rawProxy.pass) ? `${rawProxy.user}:${rawProxy.pass}@` : "";
        const u = new URL(`${pType}://${auth}${rawProxy.host}:${rawProxy.port}`);
        proxyObj = { server: `${u.protocol}//${u.host}`, username: u.username, password: u.password };
    } else if (typeof rawProxy === 'string') {
        const u = new URL(rawProxy);
        proxyObj = { server: `${u.protocol}//${u.host}`, username: u.username, password: u.password };
    }

    const newTaskId = crypto.randomUUID().replace(/-/g, '').slice(0, 12);
    tasks[newTaskId] = { status: "pending", taskId: newTaskId };
    
    const queueTimer = setTimeout(() => {
        const idx = queue.indexOf(newTaskId);
        if (idx !== -1) {
            queue.splice(idx, 1);
            tasks[newTaskId] = { status: "error", taskId: newTaskId, err: { usr: "QUEUE_TIMEOUT" } };
            setTimeout(() => { delete tasks[newTaskId]; }, 10000);
        }
    }, QUEUE_TIMEOUT);

    tasks[newTaskId].data = { method, domain, siteKey, action: task.action, cdata: task.cdata, pagedata: task.pdata, payload: task.payload, proxyObj };
    tasks[newTaskId].queueTimer = queueTimer;

    queue.push(newTaskId);
    
    // Pre-init pool saat request pertama datang
    if (!poolReady) await initPool();
    
    processQueue();
    res.status(202).json({ taskId: newTaskId, status: "pending" });
});

// Error Handler
app.use((err, req, res, next) => {
    res.status(500).json({ status: "error", err: { usr: "INTERNAL_SERVER_ERROR", api: err.message } });
});

// =====================================================================
// STARTUP & SHUTDOWN
// =====================================================================
app.listen(port, '0.0.0.0', async () => {
    console.log(`Server running: http://0.0.0.0:${port}`);
    console.log(`[CONFIG] Pool: ${MAX_ACTIVE} browsers | Queue: ${MAX_QUEUE} | Queue Timeout: ${QUEUE_TIMEOUT/1000}s`);
    
    // Pre-init pool supaya request pertama tidak lambat
    await initPool();
});

const cleanup = async (code) => {
    console.log('Shutting down...');
    for (const slot of browserPool) {
        if (slot.browser) {
            try { await slot.browser.close(); } catch (e) {}
        }
    }
    process.exit(code);
};
process.on("SIGINT", () => cleanup(1));
process.on("SIGTERM", () => cleanup(9));
