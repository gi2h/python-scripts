/**
 * API_TURNSTILE (v15.0 Fixed URL Intercept + Checkbox Clicker)
 */
async function turnstile({ domain, siteKey, action, cdata, pagedata }, page) {
    const timeout = 120000; // 120 detik
    const startTime = Date.now();

    try {
        await page.setDefaultNavigationTimeout(timeout);
        
        // Ambil hostname murni (misal: memecoinwatch.ai) untuk Intersepsi URL
        let targetHost = domain;
        try { targetHost = new URL(domain).hostname; } catch (e) {}

        const htmlContent = `
            <!DOCTYPE html>
            <html lang="en">
            <head><meta charset="utf-8"><title>Verify</title></head>
            <body style="padding:50px; display:flex; justify-content:center;">
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
        page.removeAllListeners("request");
        
        page.on("request", async (request) => {
            try {
                // FIX: Hanya intercept document yang mengandung targetHost (bukan exact match)
                if (request.url().includes(targetHost) && request.resourceType() === "document") {
                    console.log(`[ts] Injecting minimal HTML ke: ${request.url()}`);
                    await request.respond({
                        status: 200,
                        contentType: "text/html",
                        body: htmlContent
                    });
                } else {
                    await request.continue();
                }
            } catch (e) {
                // Abaikan error jika request sudah di-handle
            }
        });

        console.log(`[ts] Navigasi ke: ${domain}`);
        await page.goto(domain, { waitUntil: "domcontentloaded" }).catch(() => {});

        let lastState = "";
        let hasClicked = false;

        while (Date.now() - startTime < timeout) {
            // 1. Cek Token
            const token = await page.evaluate(() => {
                if (window.__cfToken) return window.__cfToken;
                const el = document.querySelector('[name="cf-response"]');
                return el ? el.value : null;
            }).catch(() => null);

            if (token && token.length > 10) {
                console.log(`[ts] ✅ Token didapat! (${token.length} chars)`);
                await page.setRequestInterception(false).catch(() => {});
                return { token, type: "turnstile" };
            }

            // 2. Cek Error Render
            const errCode = await page.evaluate(() => window.__cfError).catch(() => null);
            if (errCode) {
                console.log(`[ts] ❌ Widget Error: ${errCode}`);
                throw new Error(`Widget error code: ${errCode}`);
            }

            // 3. Inspeksi Iframe & Klik Checkbox Dinamis
            const frames = page.frames();
            const cfFrame = frames.find(f => f.url().includes("challenges.cloudflare.com"));
            
            if (cfFrame) {
                try {
                    const frameData = await cfFrame.evaluate(() => {
                        const text = (document.body?.innerText || "").trim().replace(/\s+/g, " ");
                        const checkbox = document.querySelector('input[type="checkbox"]');
                        
                        // Jika ada checkbox dan belum dicentang, klik!
                        if (checkbox && !checkbox.checked) {
                            checkbox.click();
                            return { text, clicked: true };
                        }
                        return { text, clicked: false };
                    }).catch(() => ({ text: "", clicked: false }));

                    // Log isi iframe setiap 5 detik
                    const elapsed = Math.floor((Date.now() - startTime) / 1000);
                    if (elapsed > 0 && elapsed % 5 === 0 && elapsed !== lastState) {
                        lastState = elapsed;
                        console.log(`[ts-iframe] ${elapsed}s | Text: "${frameData.text.slice(0, 60)}"`);
                    }

                    // Fallback klik menggunakan kursor fisik jika DOM tidak bisa di-klik
                    if ((frameData.text.includes("Verify you are human") || frameData.text.includes("Verify")) && !hasClicked) {
                        console.log(`[ts] 👀 Mencoba klik fisik pada koordinat checkbox...`);
                        const iframeElement = await page.$('iframe[src*="challenges.cloudflare.com"]');
                        if (iframeElement) {
                            const box = await iframeElement.boundingBox();
                            if (box) {
                                await page.mouse.click(box.x + 30, box.y + (box.height / 2));
                                hasClicked = true;
                            }
                        }
                    }
                } catch (e) {
                    // Abaikan error cross-origin di dalam iframe
                }
            } else {
                const elapsed = Math.floor((Date.now() - startTime) / 1000);
                if (elapsed > 0 && elapsed % 5 === 0 && elapsed !== lastState) {
                    lastState = elapsed;
                    console.log(`[ts] ${elapsed}s — Menunggu iframe Cloudflare...`);
                }
            }

            await new Promise(r => setTimeout(r, 1000));
        }

        throw new Error("timeout error");

    } catch (e) {
        console.error('[ts] Error:', e.message);
        throw { 
            usr: "ERROR_CAPTCHA_UNSOLVABLE", 
            api: e.message || String(e) 
        };
    } finally {
        try {
            await page.setRequestInterception(false);
        } catch {}
    }
}

module.exports = turnstile;