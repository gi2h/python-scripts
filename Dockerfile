# ═══════════════════════════════════════════════════════════════
# SatoFlow Turnstile Solver — ALL-IN-ONE Dockerfile
# Build → Runtime → Server start, semua dari sini.
# ═══════════════════════════════════════════════════════════════
FROM python:3.11-slim-bookworm

# ── ENV ───────────────────────────────────────────────────────
ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PORT=8080 \
    DISPLAY=:99 \
    CHROME_BIN=/usr/bin/chromium \
    CHROMEDRIVER_PATH=/usr/bin/chromedriver

# ═══════════════════════════════════════════════════════════════
# 1. SYSTEM DEPS (Chromium + fonts + tools)
# ═══════════════════════════════════════════════════════════════
RUN apt-get update && apt-get install -y --no-install-recommends \
    chromium \
    chromium-driver \
    ca-certificates \
    fonts-liberation \
    fonts-noto-color-emoji \
    libasound2 \
    libatk-bridge2.0-0 \
    libatk1.0-0 \
    libatspi2.0-0 \
    libcairo2 \
    libcups2 \
    libdbus-1-3 \
    libdrm2 \
    libexpat1 \
    libgbm1 \
    libglib2.0-0 \
    libgtk-3-0 \
    libnspr4 \
    libnss3 \
    libpango-1.0-0 \
    libx11-6 \
    libxcb1 \
    libxcomposite1 \
    libxdamage1 \
    libxext6 \
    libxfixes3 \
    libxi6 \
    libxkbcommon0 \
    libxrandr2 \
    libxrender1 \
    libxss1 \
    libxtst6 \
    dnsutils \
    iputils-ping \
    netcat-openbsd \
    curl \
    wget \
    tini \
    procps \
    xvfb \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean

RUN chromium --version && chromedriver --version

# ═══════════════════════════════════════════════════════════════
# 2. PYTHON DEPS — Install SEMUA, jangan tergantung requirements.txt
# ═══════════════════════════════════════════════════════════════
RUN pip install --upgrade pip setuptools wheel && \
    pip install \
        fastapi \
        "uvicorn[standard]" \
        gunicorn \
        selenium \
        undetected-chromedriver \
        requests \
        httpx \
        aiohttp \
        pydantic \
        python-dotenv \
        beautifulsoup4 \
        lxml

# Verify critical installs
RUN python -c "import uvicorn; print('✅ uvicorn', uvicorn.__version__)" && \
    python -c "import fastapi; print('✅ fastapi', fastapi.__version__)" && \
    python -c "import selenium; print('✅ selenium', selenium.__version__)"

# ═══════════════════════════════════════════════════════════════
# 3. WORKDIR + COPY repo (main.py, solver code, dll dari git Anda)
# ═══════════════════════════════════════════════════════════════
WORKDIR /app
COPY . .

# ═══════════════════════════════════════════════════════════════
# 4. FALLBACK main.py — hanya dibuat kalau repo Anda TIDAK punya
#    main.py / app.py. Jadi kalau Anda sudah punya solver, tidak
#    akan dioverwrite.
# ═══════════════════════════════════════════════════════════════
RUN if [ ! -f main.py ] && [ ! -f app.py ] && [ ! -f server.py ]; then \
        echo "⚠️  Tidak ada main.py — generate fallback" && \
        printf '%s\n' \
'from fastapi import FastAPI, HTTPException, Request' \
'from pydantic import BaseModel' \
'from typing import Optional, Dict' \
'import uuid, time, logging' \
'' \
'logging.basicConfig(level=logging.INFO)' \
'log = logging.getLogger("solver")' \
'app = FastAPI(title="Turnstile Solver")' \
'' \
'VALID_KEYS = {' \
'    "00000000000000000000#0000000000000000000#000000000000000000#": True,' \
'    "00000000000000000000#0000000000000000000#000000000000000000#0000000000000000000": True,' \
'}' \
'' \
'TASKS: Dict[str, dict] = {}' \
'' \
'class SolveRequest(BaseModel):' \
'    type: Optional[str] = "turnstile"' \
'    domain: Optional[str] = None' \
'    siteKey: Optional[str] = None' \
'    taskId: Optional[str] = None' \
'' \
'@app.get("/")' \
'def root():' \
'    return {"status": "ok", "service": "turnstile-solver", "version": "1.0"}' \
'' \
'@app.get("/health")' \
'def health():' \
'    return {"status": "healthy"}' \
'' \
'@app.post("/solve")' \
'async def solve(req: SolveRequest, request: Request):' \
'    key = request.headers.get("key") or request.headers.get("Key")' \
'    log.info(f"POST /solve type={req.type} taskId={req.taskId} key={key[:20] if key else None}...")' \
'    if key and key not in VALID_KEYS:' \
'        log.warning(f"Invalid key: {key[:30]}...")' \
'        raise HTTPException(status_code=401, detail="invalid key")' \
'    if req.taskId:' \
'        task = TASKS.get(req.taskId)' \
'        if not task:' \
'            return {"status": "error", "message": "task not found"}' \
'        return {"status": task.get("status", "pending"), "token": task.get("token")}' \
'    if not req.siteKey or not req.domain:' \
'        return {"status": "error", "message": "domain + siteKey required"}' \
'    tid = str(uuid.uuid4())' \
'    TASKS[tid] = {"status": "pending", "created": time.time(), "siteKey": req.siteKey, "domain": req.domain}' \
'    log.info(f"Task created: {tid}")' \
'    return {"taskId": tid, "status": "queued"}' \
'' \
'@app.get("/solve")' \
'def solve_info():' \
'    return {"usage": "POST with {\"type\":\"turnstile\",\"domain\":\"...\",\"siteKey\":\"...\"}"}' \
> main.py && \
        echo "✅ Fallback main.py dibuat" ; \
    else \
        echo "✅ main.py/app.py/server.py sudah ada, tidak dioverwrite" ; \
    fi

# ═══════════════════════════════════════════════════════════════
# 5. ENTRYPOINT — startup check + auto-detect app file
# ═══════════════════════════════════════════════════════════════
RUN printf '%s\n' \
'#!/bin/bash' \
'set -e' \
'' \
'echo ""' \
'echo "═══════════════════════════════════════════════════"' \
'echo "  TURNSTILE SOLVER — STARTUP CHECK"' \
'echo "═══════════════════════════════════════════════════"' \
'' \
'# Coba tulis resolv.conf (bisa gagal karena Railway read-only — aman)' \
'if [ -w /etc/resolv.conf ]; then' \
'    { echo "nameserver 1.1.1.1"; echo "nameserver 8.8.8.8"; } > /etc/resolv.conf 2>/dev/null || true' \
'fi' \
'' \
'echo ""' \
'echo "── /etc/resolv.conf ──"' \
'cat /etc/resolv.conf 2>/dev/null || echo "(unreadable)"' \
'' \
'echo ""' \
'echo "── DNS test ──"' \
'for host in challenges.cloudflare.com www.clicks-hits.com google.com; do' \
'    if nslookup "$host" >/dev/null 2>&1; then' \
'        echo "  ✅ $host resolved"' \
'    else' \
'        echo "  ⚠️  $host FAIL (fallback: Chromium DoH)"' \
'    fi' \
'done' \
'' \
'echo ""' \
'echo "── HTTPS to Cloudflare ──"' \
'curl -sS -o /dev/null -w "  cloudflare → HTTP %{http_code} (%{time_total}s)\\n" --max-time 10 https://challenges.cloudflare.com/turnstile/v0/api.js || echo "  ❌ HTTPS FAIL"' \
'' \
'echo ""' \
'echo "── Chromium ──"' \
'chromium --version 2>/dev/null || echo "  ❌ chromium missing"' \
'chromedriver --version 2>/dev/null || echo "  ❌ chromedriver missing"' \
'' \
'echo ""' \
'echo "── Python check ──"' \
'python -c "import uvicorn; print(\"  ✅ uvicorn\", uvicorn.__version__)" 2>/dev/null || echo "  ❌ uvicorn missing"' \
'python -c "import fastapi; print(\"  ✅ fastapi\", fastapi.__version__)" 2>/dev/null || echo "  ❌ fastapi missing"' \
'' \
'echo ""' \
'echo "── App file detection ──"' \
'APP_FILE="main"' \
'if [ -f main.py ]; then APP_FILE="main"; echo "  ✅ Using main.py"' \
'elif [ -f app.py ]; then APP_FILE="app"; echo "  ✅ Using app.py"' \
'elif [ -f server.py ]; then APP_FILE="server"; echo "  ✅ Using server.py"' \
'else echo "  ❌ No app file found"; exit 1; fi' \
'' \
'echo ""' \
'echo "── Files in /app ──"' \
'ls -la /app 2>/dev/null | head -20' \
'' \
'echo ""' \
'echo "── Environment ──"' \
'echo "  PORT=$PORT  DISPLAY=$DISPLAY  APP_FILE=$APP_FILE"' \
'' \
'echo ""' \
'echo "── Starting: python -m uvicorn ${APP_FILE}:app on port ${PORT} ──"' \
'echo "═══════════════════════════════════════════════════"' \
'echo ""' \
'' \
'exec python -m uvicorn ${APP_FILE}:app \' \
'    --host 0.0.0.0 \' \
'    --port ${PORT:-8080} \' \
'    --workers 1 \' \
'    --timeout-keep-alive 75 \' \
'    --log-level info' \
> /entrypoint.sh && chmod +x /entrypoint.sh

# ═══════════════════════════════════════════════════════════════
# 6. EXPOSE + HEALTHCHECK
# ═══════════════════════════════════════════════════════════════
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -fsS "http://localhost:${PORT:-8080}/" >/dev/null || exit 1

# ═══════════════════════════════════════════════════════════════
# 7. ENTRYPOINT (CMD sudah di entrypoint.sh)
# ═══════════════════════════════════════════════════════════════
ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]
