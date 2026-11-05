/**
 * turnstile.js — Anti-Crash Edition
 */
async function turnstile({ domain, siteKey, action, cdata, pagedata }, page) {
    const timeout = 120000;
    const startTime = Date.now();

    // Handler global agar error page TIDAK mematikan Node.js
    const onError = (e) => console.warn("[ts] page error:", e?.message || e);
    const onPageError = (e) => console.warn("[ts] pageerror:", e?.message || e);
    const onCrash = () => console.warn("[ts] PAGE CRASHED");
    page.on("error", onError);
    page.on("pageerror", onPageError);
    page.on("crash", onCrash);

    let requestHandler = null;

    try {
        await page.setDefaultNavigationTimeout(timeout);

        let targetHost = domain;
        try { targetHost = new URL(domain).hostname; } catch (_) {}

        const htmlContent = `
            <!DOCTYPE html>
            <html lang="en">
            <head><meta charset="utf-8"><title>Verify</title>
            <style>body{margin:0;padding:0;display:flex;justify-content:center;align-items:center;height:100vh;background:#f9f9f9;}#cf-container{margin:auto;}</style>
            </head>
            <body>
                <div id="cf-container" class="cf-turnstile"></div>
                <script>
                    window.__cfError = null;
                    window.__cfToken = null;
                    window.onloadTurnstileCallback = function () {
                        try {
                            turnstile.render('#cf-container', {
                                sitekey: '${siteKey}',
                                ${action ? `action: '${action}',` : ""}
                                ${cdata ? `cData: '${cdata}',` : ""}
                                ${pagedata ? `chlPageData: '${pagedata}',` : ""}
                                callback: function (t) {
                                    window.__cfToken = t;
                                    var c = document.createElement('input');
                                    c.type = 'hidden'; c.name = 'cf-response'; c.value = t;
                                    document.body.appendChild(c);
                                },
                                'error-callback': function(code) { window.__cfError = code; },
                                'expired-callback': function() { window.__cfToken = null; }
                            });
                        } catch (e) { window.__cfError = 'render_err: ' + e.message; }
                    };
                </script>
                <script src="https://challenges.cloudflare.com/turnstile/v0/api.js?onload=onloadTurnstileCallback" defer></script>
            </body>
            </html>
        `;

        // Interception aman
        try { await page.setRequestInterception(true); } catch (_) {}

        let intercepted = false;
        requestHandler = async (request) => {
            try {
                if (!intercepted && request.isNavigationRequest() && request.frame() === page.mainFrame()) {
                    intercepted = true;
                    await request.respond({ status: 200, contentType: "text/html", body: htmlContent });
                } else {
                    await request.continue();
                }
            } catch (_) { /* request already handled/aborted */ }
        };
        page.on("request", requestHandler);

        console.log(`[ts] Navigate: ${domain}`);
        try {
            await page.goto(domain, { waitUntil: "domcontentloaded", timeout });
        } catch (_) { /* navigasi boleh gagal, yg penting interceptor sudah kirim HTML */ }

        // Lepas listener agar tidak ganggu resource berikutnya
        try { page.off("request", requestHandler); } catch (_) { try { page.removeListener("request", requestHandler); } catch(__){} }
        requestHandler = null;

        let lastLogSec = -1;
        let lastClickTime = 0;

        while (Date.now() - startTime < timeout) {
            // Jika page tertutup / crash, lempar error agar recycle
            let closed = false;
            try { closed = page.isClosed(); } catch (_) { closed = true; }
            if (closed) throw new Error("page closed unexpectedly");

            // Baca token
            let token = null;
            try {
                token = await page.evaluate(() => {
                    return window.__cfToken ||
                        document.querySelector('[name="cf-response"]')?.value ||
                        document.querySelector('input[name="cf-turnstile-response"]')?.value ||
                        null;
                });
            } catch (_) { /* evaluate timeout / detached → abaikan */ }

            if (token && typeof token === "string" && token.length > 10) {
                console.log(`[ts] ✅ Token OK (${token.length} chars)`);
                return { token, type: "turnstile" };
            }

            // Baca error widget
            let errCode = null;
            try { errCode = await page.evaluate(() => window.__cfError); } catch (_) {}
            if (errCode) {
                const s = String(errCode);
                if (s.includes("300030")) throw new Error(`Invalid Sitekey (300030) for ${targetHost}`);
                if (s.includes("600010")) throw new Error(`Bot detected (600010)`);
                if (s.includes("render_err")) throw new Error(`Render err: ${s}`);
                throw new Error(`Widget error: ${s}`);
            }

            // Log periodik
            const elapsed = Math.floor((Date.now() - startTime) / 1000);
            if (elapsed % 5 === 0 && elapsed > 0 && elapsed !== lastLogSec) {
                lastLogSec = elapsed;
                console.log(`[ts] Waiting (${elapsed}s)`);
            }

            // Simulasi klik fisik (aman)
            if (elapsed >= 3 && (Date.now() - lastClickTime > 4000)) {
                try {
                    const iframes = await page.$$("iframe");
                    for (const fe of iframes) {
                        let src = "";
                        try { src = await fe.evaluate(el => el.src); } catch (_) {}
                        if (!src.includes("challenges.cloudflare.com")) continue;

                        let box = null;
                        try { box = await fe.boundingBox(); } catch (_) {}
                        if (box && box.width > 0 && box.height > 0) {
                            await page.mouse.move(box.x + 30, box.y + box.height / 2, { steps: 5 }).catch(() => {});
                            await page.mouse.down().catch(() => {});
                            await new Promise(r => setTimeout(r, 50 + Math.random() * 100));
                            await page.mouse.up().catch(() => {});
                            lastClickTime = Date.now();
                        }
                    }
                } catch (_) {}
            }

            await new Promise(r => setTimeout(r, 1000));
        }
        throw new Error("timeout: token tidak didapat");

    } catch (e) {
        throw { usr: "ERROR_CAPTCHA_UNSOLVABLE", api: e?.message || String(e) };
    } finally {
        // Cleanup listener & interception
        try { if (requestHandler) page.off("request", requestHandler); } catch (_) {}
        try { page.off("error", onError); } catch (_) {}
        try { page.off("pageerror", onPageError); } catch (_) {}
        try { page.off("crash", onCrash); } catch (_) {}
        try { await page.setRequestInterception(false); } catch (_) {}
    }
}
module.exports = turnstile;
