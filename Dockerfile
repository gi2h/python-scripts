# ═══════════════════════════════════════════════════════════════
# SatoFlow Turnstile Solver — Dockerfile (v2)
# Fix: Build-time resolv.conf ditolak → dipindah ke runtime
# ═══════════════════════════════════════════════════════════════
FROM python:3.11-slim-bookworm

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PORT=8080 \
    DISPLAY=:99 \
    CHROME_BIN=/usr/bin/chromium \
    CHROMEDRIVER_PATH=/usr/bin/chromedriver

# ─────────────────────────────────────────────────────────────
# System deps + Chromium
# ─────────────────────────────────────────────────────────────
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

WORKDIR /app

# ─────────────────────────────────────────────────────────────
# Python deps
# ─────────────────────────────────────────────────────────────
COPY requirements.txt* ./

RUN pip install --upgrade pip setuptools wheel && \
    if [ -f requirements.txt ]; then \
        pip install -r requirements.txt; \
    else \
        pip install \
            fastapi \
            uvicorn[standard] \
            selenium \
            undetected-chromedriver \
            requests \
            httpx \
            aiohttp \
            pydantic \
            python-dotenv; \
    fi

RUN python -m playwright install chromium 2>/dev/null || true

# ─────────────────────────────────────────────────────────────
# Copy source
# ─────────────────────────────────────────────────────────────
COPY . .

# ─────────────────────────────────────────────────────────────
# Entrypoint (runtime DNS fix — safe, tidak akan break kalau gagal)
# ─────────────────────────────────────────────────────────────
RUN printf '%s\n' \
'#!/bin/bash' \
'set -e' \
'' \
'echo "═══════════════════════════════════════════════════"' \
'echo "  TURNSTILE SOLVER — STARTUP CHECK"' \
'echo "═══════════════════════════════════════════════════"' \
'' \
'# ── Runtime DNS attempt (bisa gagal karena Railway lock resolv.conf) ──' \
'if [ -w /etc/resolv.conf ]; then' \
'    echo "nameserver 1.1.1.1" > /etc/resolv.conf 2>/dev/null && \' \
'    echo "nameserver 8.8.8.8" >> /etc/resolv.conf 2>/dev/null && \' \
'    echo "  ✅ /etc/resolv.conf di-overwrite (runtime)" || \' \
'    echo "  ⚠️  Gagal overwrite /etc/resolv.conf — pakai DoH saja"' \
'else' \
'    echo "  ⚠️  /etc/resolv.conf read-only — pakai DoH saja"' \
'fi' \
'' \
'echo ""' \
'echo "── Current resolv.conf ──"' \
'cat /etc/resolv.conf 2>/dev/null || echo "  (unreadable)"' \
'' \
'echo ""' \
'echo "── DNS resolution test ──"' \
'for host in challenges.cloudflare.com www.clicks-hits.com google.com; do' \
'    if nslookup "$host" >/dev/null 2>&1; then' \
'        echo "  ✅ $host resolved"' \
'    else' \
'        echo "  ⚠️  $host FAIL — Chromium akan pakai DoH"' \
'    fi' \
'done' \
'' \
'echo ""' \
'echo "── HTTPS to Cloudflare ──"' \
'curl -sS -o /dev/null -w "  challenges.cloudflare.com → HTTP %{http_code} (%{time_total}s)\n" \' \
'    --max-time 10 https://challenges.cloudflare.com/turnstile/v0/api.js \' \
'    || echo "  ❌ HTTPS FAIL"' \
'' \
'echo ""' \
'echo "── Chromium ──"' \
'chromium --version 2>/dev/null || echo "  ❌ chromium missing"' \
'chromedriver --version 2>/dev/null || echo "  ❌ chromedriver missing"' \
'' \
'echo ""' \
'echo "── Environment ──"' \
'echo "  PORT=$PORT  DISPLAY=$DISPLAY"' \
'' \
'echo ""' \
'echo "── Starting server ──"' \
'echo "═══════════════════════════════════════════════════"' \
'exec "$@"' \
> /entrypoint.sh && chmod +x /entrypoint.sh

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -fsS "http://localhost:${PORT:-8080}/" >/dev/null || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]
CMD ["sh", "-c", "uvicorn main:app --host 0.0.0.0 --port ${PORT:-8080} --workers 1 --timeout-keep-alive 75"]
