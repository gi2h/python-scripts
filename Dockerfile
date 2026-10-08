# ═══════════════════════════════════════════════════════════════
# SatoFlow Turnstile Solver — Dockerfile
# Fix: DNS resolver + Chromium dependenncies + anti-bot bypass
# ═══════════════════════════════════════════════════════════════
FROM python:3.11-slim-bookworm

# ─────────────────────────────────────────────────────────────
# ENV
# ─────────────────────────────────────────────────────────────
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
# 1. DNS FIX — WAJIB PALING AWAL
# Railway default resolv.conf sering rusak. Ganti dengan DNS publik.
# ─────────────────────────────────────────────────────────────
USER root

RUN printf 'nameserver 1.1.1.1\nnameserver 1.0.0.1\nnameserver 8.8.8.8\nnameserver 8.8.4.4\noptions timeout:2 attempts:3 rotate\n' > /etc/resolv.conf

# Cegah Railway overwrite /etc/resolv.conf (kalau diizinkan)
RUN chattr +i /etc/resolv.conf 2>/dev/null || true

# ─────────────────────────────────────────────────────────────
# 2. System dependencies untuk Chromium
# ─────────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Chromium & driver
    chromium \
    chromium-driver \
    # Chromium runtime libs
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
    # Debug & network tools
    dnsutils \
    iputils-ping \
    netcat-openbsd \
    curl \
    wget \
    # Utilities
    tini \
    procps \
    supervisor \
    xvfb \
    x11vnc \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean

# ─────────────────────────────────────────────────────────────
# 3. Chromium sanity check (build-time)
# ─────────────────────────────────────────────────────────────
RUN chromium --version && chromedriver --version

# ─────────────────────────────────────────────────────────────
# 4. Working directory
# ─────────────────────────────────────────────────────────────
WORKDIR /app

# ─────────────────────────────────────────────────────────────
# 5. Python dependencies
# ─────────────────────────────────────────────────────────────
# Copy requirements dulu (layer caching)
COPY requirements.txt* ./

RUN pip install --upgrade pip setuptools wheel && \
    if [ -f requirements.txt ]; then \
        pip install -r requirements.txt; \
    else \
        pip install \
            fastapi \
            uvicorn[standard] \
            gunicorn \
            selenium \
            undetected-chromedriver \
            requests \
            httpx \
            aiohttp \
            playwright \
            pydantic \
            python-dotenv; \
    fi

# Install Playwright Chromium (kalau dipakai) — abaikan error kalau tidak ada
RUN python -m playwright install chromium 2>/dev/null || true

# ─────────────────────────────────────────────────────────────
# 6. Copy source code
# ─────────────────────────────────────────────────────────────
COPY . .

# ─────────────────────────────────────────────────────────────
# 7. Entrypoint script — test DNS sebelum start
# ─────────────────────────────────────────────────────────────
RUN printf '#!/bin/bash\n\
set -e\n\
echo "═══════════════════════════════════════════════════"\n\
echo "  TURNSTILE SOLVER — STARTUP CHECK"\n\
echo "═══════════════════════════════════════════════════"\n\
echo ""\n\
echo "── /etc/resolv.conf ──"\n\
cat /etc/resolv.conf\n\
echo ""\n\
echo "── DNS resolution test ──"\n\
for host in challenges.cloudflare.com www.clicks-hits.com google.com; do\n\
    if nslookup "$host" >/dev/null 2>&1; then\n\
        ip=$(nslookup "$host" 2>/dev/null | grep -A1 "Name:" | tail -1 | awk "{print \\$2}" | head -1)\n\
        echo "  ✅ $host → ${ip:-resolved}"\n\
    else\n\
        echo "  ⚠️  $host → FAIL"\n\
    fi\n\
done\n\
echo ""\n\
echo "── HTTPS to Cloudflare ──"\n\
if curl -sS -o /dev/null -w "  ✅ challenges.cloudflare.com → HTTP %{http_code} (%{time_total}s)\\n" --max-time 10 https://challenges.cloudflare.com/turnstile/v0/api.js; then\n\
    :\n\
else\n\
    echo "  ❌ HTTPS FAIL"\n\
fi\n\
echo ""\n\
echo "── Chromium version ──"\n\
chromium --version 2>/dev/null || echo "  ❌ chromium not found"\n\
chromedriver --version 2>/dev/null || echo "  ❌ chromedriver not found"\n\
echo ""\n\
echo "── Starting server ──"\n\
echo "═══════════════════════════════════════════════════"\n\
echo ""\n\
exec "$@"\n' > /entrypoint.sh && chmod +x /entrypoint.sh

# ─────────────────────────────────────────────────────────────
# 8. Non-root user (Railway kadang butuh, tapi Chromium butuh root
#    untuk beberapa flag. Kalau error, set kembali ke root.)
# ─────────────────────────────────────────────────────────────
# Tetap root agar --no-sandbox berfungsi penuh di Railway

# ─────────────────────────────────────────────────────────────
# 9. Expose port (Railway auto-detect dari $PORT)
# ─────────────────────────────────────────────────────────────
EXPOSE 8080

# ─────────────────────────────────────────────────────────────
# 10. Healthcheck
# ─────────────────────────────────────────────────────────────
HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
    CMD curl -fsS "http://localhost:${PORT}/" >/dev/null || exit 1

# ─────────────────────────────────────────────────────────────
# 11. Entrypoint & CMD
# ─────────────────────────────────────────────────────────────
ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]

# Auto-detect: ganti ini sesuai framework Anda
# FastAPI/Uvicorn:
CMD ["sh", "-c", "uvicorn main:app --host 0.0.0.0 --port ${PORT:-8080} --workers 1 --timeout-keep-alive 75"]

# Kalau pakai Flask/Gunicorn, comment CMD di atas dan pakai ini:
# CMD ["sh", "-c", "gunicorn -w 1 -k uvicorn.workers.UvicornWorker --bind 0.0.0.0:${PORT:-8080} --timeout 300 main:app"]

# Kalau pakai Sanic:
# CMD ["sh", "-c", "sanic main:app --host 0.0.0.0 --port ${PORT:-8080} --workers 1"]
