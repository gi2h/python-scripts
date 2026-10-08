# ═══════════════════════════════════════════════════════════════
# Turnstile Solver — Dockerfile + main.py (all-in-one)
# ═══════════════════════════════════════════════════════════════
FROM python:3.11-slim-bookworm

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PORT=8080 \
    DISPLAY=:99 \
    CHROME_BIN=/usr/bin/chromium \
    CHROMEDRIVER_PATH=/usr/bin/chromedriver

# ─────────────────────────────────────────────────────────────
# System deps + Chromium
# ─────────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
    chromium chromium-driver ca-certificates \
    fonts-liberation fonts-noto-color-emoji \
    libasound2 libatk-bridge2.0-0 libatk1.0-0 libatspi2.0-0 \
    libcairo2 libcups2 libdbus-1-3 libdrm2 libexpat1 libgbm1 \
    libglib2.0-0 libgtk-3-0 libnspr4 libnss3 libpango-1.0-0 \
    libx11-6 libxcb1 libxcomposite1 libxdamage1 libxext6 \
    libxfixes3 libxi6 libxkbcommon0 libxrandr2 libxrender1 \
    libxss1 libxtst6 \
    dnsutils curl wget tini procps xvfb \
    && rm -rf /var/lib/apt/lists/*

RUN chromium --version && chromedriver --version

# ─────────────────────────────────────────────────────────────
# Python deps
# ─────────────────────────────────────────────────────────────
RUN pip install --upgrade pip setuptools wheel && \
    pip install \
        fastapi "uvicorn[standard]" \
        selenium requests httpx \
        pydantic python-dotenv

RUN python -c "import uvicorn, fastapi, selenium; print('✅ imports OK')"

# ─────────────────────────────────────────────────────────────
# WORKDIR + COPY
# ─────────────────────────────────────────────────────────────
WORKDIR /app
COPY . .

# ═══════════════════════════════════════════════════════════════
# OVERWRITE main.py dengan solver lengkap
# ═══════════════════════════════════════════════════════════════
RUN cat > /app/main.py << 'PYEOF'
import os, re, time, uuid, tempfile, threading, logging, traceback
from typing import Dict, Optional
from pathlib import Path

from fastapi import FastAPI, HTTPException, Request, BackgroundTasks
from pydantic import BaseModel
from selenium import webdriver
from selenium.webdriver.chrome.options import Options
from selenium.webdriver.chrome.service import Service
from selenium.webdriver.common.by import By
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC

# ── Logging ────────────────────────────────────────────────────
logging.basicConfig(level=logging.INFO,
                    format='%(asctime)s | %(levelname)s | %(message)s',
                    datefmt='%H:%M:%S')
log = logging.getLogger("solver")

# ── Config ─────────────────────────────────────────────────────
VALID_KEYS = {
    "00000000000000000000#0000000000000000000#000000000000000000#",
    "00000000000000000000#0000000000000000000#000000000000000000#0000000000000000000",
}
TASKS: Dict[str, dict] = {}
TASKS_LOCK = threading.Lock()
MAX_SOLVE_TIME = 120

app = FastAPI(title="Turnstile Solver", version="2.0")

# ── Models ─────────────────────────────────────────────────────
class SolveRequest(BaseModel):
    type: Optional[str] = "turnstile"
    domain: Optional[str] = None
    siteKey: Optional[str] = None
    taskId: Optional[str] = None

# ── HTML template untuk host Turnstile ─────────────────────────
def make_host_html(sitekey: str) -> str:
    return f"""<!DOCTYPE html>
<html><head>
<meta charset="utf-8">
<title>loading</title>
<script src="https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit" async defer></script>
</head><body>
<div id="cf" style="margin:50px"></div>
<script>
function initWidget() {{
    if (typeof turnstile === 'undefined') {{ setTimeout(initWidget, 200); return; }}
    turnstile.render('#cf', {{
        sitekey: '{sitekey}',
        callback: function(token) {{
            document.title = 'DONE::' + token;
        }},
        'error-callback': function(e) {{
            document.title = 'ERROR::' + e;
        }},
        'timeout-callback': function() {{
            document.title = 'TIMEOUT';
        }}
    }});
}}
initWidget();
</script>
</body></html>"""

# ── Solver core ────────────────────────────────────────────────
def build_driver():
    """Bikin Selenium driver dengan flag anti-detection."""
    opts = Options()
    # Wajib di container
    opts.add_argument("--headless=new")
    opts.add_argument("--no-sandbox")
    opts.add_argument("--disable-dev-shm-usage")
    opts.add_argument("--disable-gpu")
    opts.add_argument("--window-size=1920,1080")
    opts.add_argument("--single-process")   # hemat memori
    opts.add_argument("--no-zygote")
    # DNS over HTTPS (bypass resolv.conf)
    opts.add_argument("--dns-over-https-mode=secure")
    opts.add_argument("--dns-over-https-templates=https://cloudflare-dns.com/dns-query")
    # Anti-detection
    opts.add_argument("--disable-blink-features=AutomationControlled")
    opts.add_argument("--user-agent=Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                      "AppleWebKit/537.36 (KHTML, like Gecko) "
                      "Chrome/120.0.0.0 Safari/537.36")
    opts.add_argument("--lang=en-US,en")
    opts.add_experimental_option("excludeSwitches", ["enable-automation"])
    opts.add_experimental_option("useAutomationExtension", False)
    opts.binary_location = os.environ.get("CHROME_BIN", "/usr/bin/chromium")

    service = Service(executable_path=os.environ.get(
        "CHROMEDRIVER_PATH", "/usr/bin/chromedriver"))
    driver = webdriver.Chrome(service=service, options=opts)

    # Hide navigator.webdriver
    try:
        driver.execute_cdp_cmd("Page.addScriptToEvaluateOnNewDocument", {
            "source": """
                Object.defineProperty(navigator, 'webdriver', {get: () => undefined});
                Object.defineProperty(navigator, 'plugins', {get: () => [1,2,3,4,5]});
                Object.defineProperty(navigator, 'languages', {get: () => ['en-US','en']});
                window.chrome = { runtime: {} };
                const origQuery = window.navigator.permissions.query;
                window.navigator.permissions.query = (p) => (
                    p.name === 'notifications' ?
                    Promise.resolve({ state: Notification.permission }) :
                    origQuery(p)
                );
            """
        })
    except Exception as e:
        log.warning(f"CDP inject gagal: {e}")

    return driver

def do_solve(task_id: str, sitekey: str, domain: str):
    """Worker: solve turnstile, update TASKS[task_id]."""
    log.info(f"[{task_id[:8]}] START solve sitekey={sitekey} domain={domain}")
    driver = None
    tmp_html = None
    try:
        # Simpan HTML host
        html = make_host_html(sitekey)
        tmp = tempfile.NamedTemporaryFile(mode='w', suffix='.html',
                                          delete=False, encoding='utf-8')
        tmp.write(html)
        tmp.close()
        tmp_html = tmp.name
        file_url = f"file://{tmp_html}"

        driver = build_driver()
        log.info(f"[{task_id[:8]}] driver ready, opening host page...")
        driver.get(file_url)

        # Tunggu title berubah
        deadline = time.time() + MAX_SOLVE_TIME
        token = None
        while time.time() < deadline:
            title = driver.title or ""
            if title.startswith("DONE::"):
                token = title.replace("DONE::", "", 1)
                break
            if title.startswith("ERROR::"):
                err = title.replace("ERROR::", "", 1)
                raise RuntimeError(f"turnstile error: {err}")
            if title == "TIMEOUT":
                raise RuntimeError("turnstile timeout")
            time.sleep(0.5)

        if not token:
            raise RuntimeError("timeout waiting for token")

        log.info(f"[{task_id[:8]}] ✅ TOKEN OK ({len(token)} chars)")
        with TASKS_LOCK:
            TASKS[task_id] = {
                "status": "done",
                "token": token,
                "created": TASKS.get(task_id, {}).get("created", time.time()),
                "solved_at": time.time(),
            }

    except Exception as e:
        log.error(f"[{task_id[:8]}] ❌ FAIL: {type(e).__name__}: {e}")
        log.error(traceback.format_exc())
        with TASKS_LOCK:
            TASKS[task_id] = {
                "status": "error",
                "message": f"{type(e).__name__}: {e}",
                "created": TASKS.get(task_id, {}).get("created", time.time()),
            }
    finally:
        if driver:
            try: driver.quit()
            except Exception: pass
        if tmp_html:
            try: os.unlink(tmp_html)
            except Exception: pass

# ── Routes ─────────────────────────────────────────────────────
@app.get("/")
def root():
    return {"status": "ok", "service": "turnstile-solver", "version": "2.0"}

@app.get("/health")
def health():
    return {"status": "healthy", "tasks": len(TASKS)}

@app.post("/solve")
async def solve(req: SolveRequest, request: Request, bg: BackgroundTasks):
    key = request.headers.get("key") or request.headers.get("Key") or ""

    # Auth
    if VALID_KEYS and key not in VALID_KEYS:
        log.warning(f"Invalid key: {key[:30]}...")
        raise HTTPException(status_code=401, detail="invalid key")

    # Poll existing task
    if req.taskId:
        task = TASKS.get(req.taskId)
        if not task:
            return {"status": "error", "message": "task not found"}
        if task["status"] == "done":
            return {"status": "done", "token": task["token"]}
        if task["status"] == "error":
            return {"status": "error", "message": task.get("message", "unknown")}
        return {"status": "pending"}

    # New task
    if not req.siteKey or not req.domain:
        return {"status": "error", "message": "domain + siteKey required"}

    sitekey = req.siteKey.strip()
    domain = req.domain.strip()

    tid = str(uuid.uuid4())
    with TASKS_LOCK:
        TASKS[tid] = {"status": "pending", "created": time.time(),
                      "sitekey": sitekey, "domain": domain}
    log.info(f"POST /solve new task={tid[:8]} sitekey={sitekey}")

    # Jalankan solver di background thread
    t = threading.Thread(target=do_solve, args=(tid, sitekey, domain), daemon=True)
    t.start()

    return {"taskId": tid, "status": "queued"}

@app.on_event("startup")
async def startup():
    log.info("=" * 55)
    log.info("Turnstile Solver v2 — ready")
    log.info(f"Chromium: {os.environ.get('CHROME_BIN')}")
    log.info(f"ChromeDriver: {os.environ.get('CHROMEDRIVER_PATH')}")
    log.info("=" * 55)
PYEOF

# Verify main.py
RUN python -c "import ast; ast.parse(open('/app/main.py').read()); print('✅ main.py syntax OK')"

# ═══════════════════════════════════════════════════════════════
# ENTRYPOINT
# ═══════════════════════════════════════════════════════════════
RUN printf '%s\n' \
'#!/bin/bash' \
'set -e' \
'echo ""' \
'echo "═══════════════════════════════════════════════"' \
'echo "  TURNSTILE SOLVER — STARTUP"' \
'echo "═══════════════════════════════════════════════"' \
'if [ -w /etc/resolv.conf ]; then' \
'    { echo "nameserver 1.1.1.1"; echo "nameserver 8.8.8.8"; } > /etc/resolv.conf 2>/dev/null || true' \
'fi' \
'cat /etc/resolv.conf 2>/dev/null || true' \
'for host in challenges.cloudflare.com; do' \
'    nslookup "$host" >/dev/null 2>&1 && echo "  ✅ $host OK" || echo "  ⚠️  $host (DoH fallback)"' \
'done' \
'chromium --version 2>/dev/null || echo "  ❌ chromium missing"' \
'chromedriver --version 2>/dev/null || echo "  ❌ chromedriver missing"' \
'python -c "import uvicorn; print(\"  ✅ uvicorn\", uvicorn.__version__)"' \
'echo "═══════════════════════════════════════════════"' \
'exec python -m uvicorn main:app \' \
'    --host 0.0.0.0 \' \
'    --port ${PORT:-8080} \' \
'    --workers 1 \' \
'    --timeout-keep-alive 75 \' \
'    --log-level info' \
> /entrypoint.sh && chmod +x /entrypoint.sh

EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=10s --start-period=90s --retries=3 \
    CMD curl -fsS "http://localhost:${PORT:-8080}/" >/dev/null || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]
