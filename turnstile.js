/**
 * API_TURNSTILE (v15.0 Fixed URL Intercept + Checkbox Clicker)
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
                                'error-callback': function(code) { window.__cfError = code; }
                            });
                        } catch(e) { window.__cfError = 'render_err'; }
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
                if (request.url().includes(targetHost) && request.resourceType() === "document") {
                    await request.respond({ status: 200, contentType: "text/html", body: htmlContent });
                } else {
                    await request.continue();
                }
            } catch (e) {}
        });

        console.log(`[ts] Navigasi ke: ${domain}`);
        await page.goto(domain, { waitUntil: "domcontentloaded" }).catch(() => {});

        let lastState = "";
        let hasClicked = false;

        while (Date.now() - startTime < timeout) {
            const token = await page.evaluate(() => window.__cfToken || document.querySelector('[name="cf-response"]')?.value).catch(() => null);
            if (token && token.length > 10) {
                console.log(`[ts] ✅ Token didapat! (${token.length} chars)`);
                return { token, type: "turnstile" };
            }

            const errCode = await page.evaluate(() => window.__cfError).catch(() => null);
            if (errCode) throw new Error(`Widget error code: ${errCode}`);

            const frames = page.frames();
            const cfFrame = frames.find(f => f.url().includes("challenges.cloudflare.com"));
            
            if (cfFrame) {
                try {
                    const frameData = await cfFrame.evaluate(() => {
                        const text = (document.body?.innerText || "").trim().replace(/\s+/g, " ");
                        const checkbox = document.querySelector('input[type="checkbox"]');
                        if (checkbox && !checkbox.checked) {
                            checkbox.click();
                            return { text, clicked: true };
                        }
                        return { text, clicked: false };
                    }).catch(() => ({ text: "", clicked: false }));

                    const elapsed = Math.floor((Date.now() - startTime) / 1000);
                    if (elapsed % 5 === 0 && elapsed > 0 && elapsed !== lastState) {
                        lastState = elapsed;
                        console.log(`[ts-iframe] ${elapsed}s | Text: "${frameData.text.slice(0, 50)}"`);
                    }

                    if (frameData.text.includes("Verify") && !hasClicked) {
                        console.log(`[ts] 👀 Klik fisik pada checkbox...`);
                        const iframeElement = await page.$('iframe[src*="challenges.cloudflare.com"]');
                        if (iframeElement) {
                            const box = await iframeElement.boundingBox();
                            if (box) {
                                await page.mouse.click(box.x + 30, box.y + (box.height / 2));
                                hasClicked = true;
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