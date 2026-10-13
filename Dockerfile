FROM python:3.11-slim-bookworm

# ============================================================
# ENV
# ============================================================
ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    NODE_ENV=production \
    DISPLAY=:99 \
    PORT=8080 \
    CHROME_BIN=/usr/bin/google-chrome \
    CHROME_PATH=/usr/bin/google-chrome \
    PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=true \
    PUPPETEER_SKIP_DOWNLOAD=true \
    PUPPETEER_EXECUTABLE_PATH=/usr/bin/google-chrome \
    PLAYWRIGHT_BROWSERS_PATH=/ms-playwright \
    NODE_OPTIONS=--dns-result-order=ipv4first

# ============================================================
# 1. SYSTEM DEPENDENCIES
# ============================================================
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        wget \
        gnupg \
        unzip \
        dumb-init \
        xvfb \
        netcat-openbsd \
        procps \
        iproute2 \
        fonts-liberation \
        fonts-noto-color-emoji \
        libasound2 \
        libatk-bridge2.0-0 \
        libatk1.0-0 \
        libcups2 \
        libdrm2 \
        libgbm1 \
        libglib2.0-0 \
        libgtk-3-0 \
        libnspr4 \
        libnss3 \
        libvulkan1 \
        libx11-6 \
        libx11-xcb1 \
        libxcb1 \
        libxcomposite1 \
        libxdamage1 \
        libxext6 \
        libxfixes3 \
        libxkbcommon0 \
        libxrandr2 \
        libxrender1 \
        libxshmfence1 \
    && rm -rf /var/lib/apt/lists/*

# ============================================================
# 2. GOOGLE CHROME
# ============================================================
RUN mkdir -p /etc/apt/keyrings && \
    wget -qO- https://dl.google.com/linux/linux_signing_key.pub \
        | gpg --dearmor -o /etc/apt/keyrings/google.gpg && \
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/google.gpg] https://dl.google.com/linux/chrome/deb/ stable main" \
        > /etc/apt/sources.list.d/google-chrome.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends google-chrome-stable && \
    rm -rf /var/lib/apt/lists/* && \
    google-chrome --version

# ============================================================
# 3. NODE.JS 20
# ============================================================
RUN curl -fsSL https://deb.nodesource.com/setup_20.x -o /tmp/nodesource.sh && \
    bash /tmp/nodesource.sh && \
    apt-get update && \
    apt-get install -y --no-install-recommends nodejs && \
    npm cache clean --force && \
    rm -rf /tmp/nodesource.sh /var/lib/apt/lists/* && \
    node --version && npm --version

# ============================================================
# 4. PYTHON DEPENDENCIES
#    requirements.txt harus ada di sebelah Dockerfile
# ============================================================
WORKDIR /app
COPY requirements.txt /app/requirements.txt

RUN python -m pip install --upgrade pip setuptools wheel && \
    python -m pip install --no-cache-dir -r /app/requirements.txt

# ============================================================
# 5. APPLICATION ZIP
#    Api.zip harus ada di sebelah Dockerfile
# ============================================================
COPY Api.zip /tmp/Api.zip

RUN mkdir -p /app/Api && \
    unzip -q /tmp/Api.zip -d /app && \
    rm -f /tmp/Api.zip && \
    if [ ! -f /app/Api/Api.js ] && [ -f /app/Api/Api/Api.js ]; then \
        cp -a /app/Api/Api/. /app/Api/ && \
        rm -rf /app/Api/Api; \
    fi && \
    test -f /app/Api/Api.js || \
    (echo "ERROR: Api.js not found at /app/Api/Api.js"; \
     find /app -maxdepth 4 -type f -name 'Api.js'; exit 1)

# ============================================================
# 6. NODE DEPENDENCIES
# ============================================================
WORKDIR /app/Api

RUN if [ -f package-lock.json ]; then \
        npm ci --omit=dev; \
    elif [ -f package.json ]; then \
        npm install --omit=dev; \
    else \
        echo "ERROR: package.json not found in /app/Api"; \
        exit 1; \
    fi

# Paket runtime tambahan
RUN npm install --omit=dev \
        generic-pool \
        p-queue@7 \
        jimp \
        tesseract.js \
        playwright

# ============================================================
# 7. PLAYWRIGHT CHROMIUM
# ============================================================
RUN mkdir -p /ms-playwright && \
    npx playwright install chromium && \
    npx playwright install-deps chromium

# ============================================================
# 8. START SCRIPT
# ============================================================
WORKDIR /app

RUN printf '%s\n' \
'#!/bin/sh' \
'set -eu' \
'' \
'echo "======================================"' \
'echo " Starting API Container"' \
'echo "======================================"' \
'' \
'cleanup() {' \
'  if [ -n "${XVFB_PID:-}" ]; then' \
'    kill "$XVFB_PID" 2>/dev/null || true' \
'  fi' \
'}' \
'trap cleanup EXIT INT TERM' \
'' \
'echo ""' \
'echo "=== Runtime information ==="' \
'echo "Python:  $(python --version 2>&1)"' \
'echo "Node:    $(node --version 2>&1)"' \
'echo "NPM:     $(npm --version 2>&1)"' \
'echo "Chrome:  $(google-chrome --version 2>&1)"' \
'echo "Port:    ${PORT:-8080}"' \
'echo "Display: ${DISPLAY:-:99}"' \
'' \
'echo ""' \
'echo "=== DNS configuration ==="' \
'cat /etc/resolv.conf || true' \
'' \
'echo ""' \
'echo "=== DNS verification ==="' \
'for host in google.com challenges.cloudflare.com; do' \
'  if getent ahostsv4 "$host" >/dev/null 2>&1; then' \
'    echo "OK: IPv4 resolution for $host"' \
'  else' \
'    echo "WARN: IPv4 resolution failed for $host"' \
'  fi' \
'done' \
'' \
'echo ""' \
'echo "=== HTTPS verification ==="' \
'if curl -4 -fsSI --max-time 10 https://challenges.cloudflare.com/turnstile/v0/api.js >/dev/null 2>&1; then' \
'  echo "OK: HTTPS connection established"' \
'else' \
'  echo "WARN: HTTPS check failed; inspect network and TLS"' \
'fi' \
'' \
'echo ""' \
'echo "=== Playwright browser ==="' \
'if [ -d "${PLAYWRIGHT_BROWSERS_PATH:-/ms-playwright}" ]; then' \
'  ls -la "${PLAYWRIGHT_BROWSERS_PATH:-/ms-playwright}"' \
'else' \
'  echo "ERROR: Playwright browser directory missing"' \
'  exit 1' \
'fi' \
'' \
'echo ""' \
'echo "=== Starting Xvfb ==="' \
'Xvfb "${DISPLAY:-:99}" -screen 0 1366x768x24 -ac +extension RANDR >/tmp/xvfb.log 2>&1 &' \
'XVFB_PID=$!' \
'sleep 2' \
'' \
'if ! kill -0 "$XVFB_PID" 2>/dev/null; then' \
'  echo "ERROR: Xvfb failed to start"' \
'  cat /tmp/xvfb.log || true' \
'  exit 1' \
'fi' \
'echo "OK: Xvfb started"' \
'' \
'echo ""' \
'echo "=== Starting API ==="' \
'cd /app/Api' \
'' \
'if [ ! -f Api.js ]; then' \
'  echo "ERROR: /app/Api/Api.js not found"' \
'  exit 1' \
'fi' \
'' \
'node Api.js' \
> /start.sh && \
chmod +x /start.sh

# ============================================================
# 9. HEALTHCHECK
# ============================================================
HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=5 \
    CMD-SHELL nc -z 127.0.0.1 "${PORT:-8080}" || exit 1

EXPOSE 8080

ENTRYPOINT ["dumb-init", "--"]
CMD ["/start.sh"]
