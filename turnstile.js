/**
 * API_TURNSTILE (v17.0 - Perfect Synergy with Real-Browser)
 */
async function turnstile({ domain, siteKey, action, cdata, pagedata }, page) {
    const timeout = 120000; 
    const startTime = Date.now();

    try {
        await page.setDefaultNavigationTimeout(timeout);
        
        let targetHost = domain;
        try { targetHost = new URL(domain).hostname; } catch (e) {}

        const htmlContent = `
            <!DOCTYPE html>
            <html lang="en">
            <head>
                <meta charset="utf-8">
                <meta name="viewport" content="width=device-width, initial-scale=1.0">
                <title>Verification</title>
                <style>
                    body { 
                        margin: 0; padding: 0; display: flex; justify-content: center; align-items: center; height: 100vh; background-color: #f9f9f9; 
                        font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
                    }
                    #cf-container { margin: auto; }
                </style>
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
                                callback: function (token) {
                                    window.__cfToken = token;
                                    var c = document.createElement('input');
                                    c.type = 'hidden';
                                    c.name = 'cf-response';
                                    c.value = token;
                                    document.body.appendChild(c);
                                },
                                'error-callback': function(code) { 
                                    window.__cfError = code; 
                                },
                                'expired-callback': function() {
                                    window.__cfToken = null;
                                }
                            });
                        } catch(e) { 
                            window.__cfError = 'render_err: ' + e.message; 
                        }
                    };
                </script>
                <script src="https://challenges.cloudflare.com/turnstile/v0/api.js?onload=onloadTurnstileCallback" defer></script>
            </body>
            </html>
        `;

        await page.setRequestInterception(true);
        
        // Hapus listener sebelumnya untuk mencegah memory leak
        page.removeAllListeners("request");
        
        let intercepted = false;
        page.on("request", async (request) => {
            try {
                // Intercept HANYA navigasi dokumen utama pertama
                if (!intercepted && request.isNavigationRequest() && request.frame() === page.mainFrame()) {
                    intercepted = true;
                    await request.respond({ 
                        status: 200, 
                        contentType: "text/html", 
                        body: htmlContent 
                    });
                } else {
                    await request.continue();
                }
            } catch (e) {
                // Abaikan error jika request dibatalkan oleh browser
            }
        });

        console.log(`[ts] Navigasi ke: ${domain}`);
        await page.goto(domain, { waitUntil: "domcontentloaded" }).catch(() => {});

        let lastLogSec = -1;
        let lastClickTime = 0;

        while (Date.now() - startTime < timeout) {
            // 1. Cek Token
            const token = await page.evaluate(() => {
                return window.__cfToken || 
                       document.querySelector('[name="cf-response"]')?.value || 
                       document.querySelector('input[name="cf-turnstile-response"]')?.value;
            }).catch(() => null);

            if (token && token.length > 10) {
                console.log(`[ts] ✅ Token didapat! (${token.length} chars)`);
                return { token, type: "turnstile" };
            }

            // 2. Cek Error Cloudflare
            const errCode = await page.evaluate(() => window.__cfError).catch(() => null);
            if (errCode) {
                if (String(errCode).includes('300030')) {
                    throw new Error(`Invalid Sitekey (Error 300030). Pastikan websiteKey valid untuk domain ${targetHost}.`);
                }
                if (String(errCode).includes('600010')) {
                    throw new Error(`Bot detected (Error 600010). IP atau Browser terdeteksi sebagai otomasi.`);
                }
                throw new Error(`Widget error code: ${errCode}`);
            }

            // 3. Log status periodik (setiap 5 detik)
            const elapsed = Math.floor((Date.now() - startTime) / 1000);
            if (elapsed % 5 === 0 && elapsed > 0 && elapsed !== lastLogSec) {
                lastLogSec = elapsed;
                console.log(`[ts] Menunggu token... (${elapsed}s)`);
            }

            // 4. Simulasi Interaksi Manusia
            // Kita lakukan klik fisik dengan jeda (mouse down -> delay -> mouse up)
            if (elapsed >= 3 && (Date.now() - lastClickTime > 4000)) {
                try {
                    const iframes = await page.$$('iframe');
                    for (const frameElement of iframes) {
                        const src = await frameElement.evaluate(el => el.src).catch(() => "");
                        if (src.includes("challenges.cloudflare.com")) {
                            const box = await frameElement.boundingBox().catch(() => null);
                            if (box && box.width > 0 && box.height > 0) {
                                // Gerakkan mouse ke area checkbox
                                await page.mouse.move(box.x + 30, box.y + (box.height / 2), { steps: 5 }).catch(() => {});
                                await page.mouse.down().catch(() => {});
                                // Jeda natural 50-150ms sebelum melepas klik
                                await new Promise(r => setTimeout(r, 50 + Math.random() * 100));
                                await page.mouse.up().catch(() => {});
                                
                                lastClickTime = Date.now();
                            }
                        }
                    }
                } catch (e) {}
            }

            await new Promise(r => setTimeout(r, 1000));
        }
        throw new Error("timeout error");
    } catch (e) {
        throw { usr: "ERROR_CAPTCHA_UNSOLVABLE", api: e.message };
    } finally {
        try { await page.setRequestInterception(false); } catch {}
    }
}
module.exports = turnstile;