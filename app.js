// app.js — Ubuntu Pr oot (Context Recycl i ng Mode)
const express  = require("express");
const { connect } = require("puppeteer-real-browser");
const crypto   = require("crypto");
const fs       = require("fs");
const path     = require("path");

const turnstile    = require("./turnstile");
const interstitial = require("./interstitial");

const app = express();
const port = process.env.PORT || 7860;
app.use(express.json());
app.use(express.urlencoded({ extended: true }));

const MAX_ACTIVE    = parseInt(process.env.MAX_ACTIVE, 10)    || 1;
const MAX_QUEUE     = parseInt(process.env.MAX_QUEUE, 10)     || 5;
const QUEUE_TIMEOUT = parseInt(process.env.QUEUE_TIMEOUT, 10) || 60000;
const TASK_TIMEOUT  = parseInt(process.env.TASK_TIMEOUT, 10)  || 120000;

let activeTasks     = 0;
let browser         = null;
let browserStarting = null;

const tasks = Object.create(null);
const queue = [];

// ============================================================
// BROWSER MANAGEMENT (Sekali Jalan, Context Berkali-kali)
// ============================================================
async function init_browser() {
    if (!browser || !browser.isConnected()) {
        if (!browserStarting) {
            console.log("[BROWSER] Meluncurkan Chromium...");
            browserStarting = connect({
                headless: false, 
                turnstile: true,
                customConfig: {
                    chromePath: "/usr/bin/chromium",
                    args: [
                        '--no-sandbox',
                        '--disable-gpu',
                        '--disable-dev-shm-usage',
                        // 🛠️ Dinaikkan untuk RAM >1GB
                        '--js-flags="--max-old-space-size=512"',
                        '--disable-background-networking',
                        '--disable-component-update',
                        '--disable-default-apps',
                        '--disable-extensions',
                        '--disable-sync'
                    ]
                }
            }).then(ctx => {
                browser = ctx.browser;
                console.log("[BROWSER] Chromium berhasil diluncurkan!");
                browser.on("disconnected", () => {
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

    // Buat Context (Incognito) baru yang bersih
    const context = await browser.createBrowserContext();
    const page = await context.newPage();
    
    // 🛠️ SINKRONISASI TIMEOUT: Harus 120.000 sesuai turnstile.js
    page.setDefaultNavigationTimeout(120000);
    page.setDefaultTimeout(120000);
    
    return { page, context };
}

// ============================================================
// SOLVER TASK (Dengan Context Cleanup)
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
        ctx = await init_browser();
        const page = ctx.page;

        let result;
        if (data.method === "turnstile") {
            result = await withTimeout(() => turnstile(data, page), TASK_TIMEOUT);
        } else if (data.method === "interstitial") {
            result = await withTimeout(() => interstitial(data, page), TASK_TIMEOUT);
        }

        const solution = {};
        if (data.method === "turnstile") {
            solution.token = result.token;
        } else if (data.method === "interstitial") {
            solution.cf_clearance = result.solution?.clearance || "";
            solution.user_agent = result.solution?.user_agent || "";
        }

        tasks[taskId] = { status: "ready", taskId, solution };
        setTimeout(() => delete tasks[taskId], 30000).unref?.();

    } catch (err) {
        console.error(`[Task ${taskId}] Error:`, err.message || err);
        tasks[taskId] = { status: "error", taskId, err: { usr: "ERROR_CAPTCHA_UNSOLVABLE", api: err.message } };
        setTimeout(() => delete tasks[taskId], 10000).unref?.();
    } finally {
        if (ctx) {
            try {
                // 🔥 KUNCI UTAMA: Cukup tutup tab dan context-nya (RAM langsung bersih)
                if (ctx.page) await ctx.page.close().catch(() => {});
                if (ctx.context) await ctx.context.close().catch(() => {});
                console.log(`[Task ${taskId}] Context dibersihkan.`);
            } catch (e) {}
        }
    }
}

function processQueue() {
    while (activeTasks < MAX_ACTIVE && queue.length > 0) {
        const taskId = queue.shift();
        const task   = tasks[taskId];
        if (!task || task.status !== "pending") continue;
        if (task.queueTimer) { clearTimeout(task.queueTimer); task.queueTimer = null; }
        
        activeTasks++;
        task.status = "processing";
        executeTask(taskId, task.data).finally(() => {
            activeTasks--;
            setImmediate(processQueue);
        });
    }
}

// ============================================================
// AUTO-CLEANUP (Pembersih Storage Berkala)
// ============================================================
setInterval(() => {
    try {
        const targetDirs = ["/tmp", "/root/.cache"];
        let removed = 0;
        for (const dir of targetDirs) {
            if (!fs.existsSync(dir)) continue;
            for (const entry of fs.readdirSync(dir)) {
                // Hapus folder cache Chromium sisa task sebelumnya
                if (entry.startsWith("puppeteer_dev_") || entry.startsWith(".org.chromium.Chromium")) {
                    fs.rmSync(path.join(dir, entry), { recursive: true, force: true });
                    removed++;
                }
            }
        }
        if (removed > 0) console.log(`[CLEANUP] Membersihkan ${removed} folder sisa di storage.`);
    } catch (e) {}
}, 300000).unref?.(); // Jalan setiap 5 menit

// ============================================================
// ROUTES
// ============================================================
app.get("/", (req, res) => res.status(200).json({ 
    status: "ok", 
    browserAlive: !!(browser && browser.isConnected()),
    active: activeTasks,
    queue: queue.length,
    ramMB: Math.round(process.memoryUsage().rss / 1024 / 1024)
}));

app.post("/solve", async (req, res) => {
    const body = req.body;
    if (body.taskId) {
        const existingTask = tasks[body.taskId];
        if (!existingTask) return res.status(200).json({ status: "error", err: { usr: "TASK_NOT_FOUND" } });
        if (existingTask.status !== "pending" && existingTask.status !== "processing") delete tasks[body.taskId];
        return res.status(200).json(existingTask);
    }

    if (body.method !== "CloudflareTask" || typeof body.task !== "object") {
        return res.status(400).json({ status: "error", err: { usr: "BAD_PARAMETERS" } });
    }

    if (queue.length >= MAX_QUEUE) return res.status(429).json({ status: "error", err: { usr: "QUEUE_FULL" } });

    const newTaskId = crypto.randomUUID().replace(/-/g, "").slice(0, 12);
    tasks[newTaskId] = { status: "pending", taskId: newTaskId, data: {
        method: (body.task.type || "").toLowerCase(),
        domain: body.task.websiteUrl,
        siteKey: body.task.websiteKey,
        action: body.task.action,
        cdata: body.task.cdata,
        pagedata: body.task.pdata,
        payload: body.task.payload
    }};
    
    queue.push(newTaskId);
    processQueue();
    res.status(202).json({ taskId: newTaskId, status: "pending" });
});

app.listen(port, "0.0.0.0", () => {
    console.log(`====================================`);
    console.log(`Server Proot berjalan di port ${port}`);
    console.log(`Context Recycling Mode: AKTIF`);
    console.log(`====================================`);
});
