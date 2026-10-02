FROM python:3.11-slim

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    NODE_ENV=production \
    DISPLAY=:99 \
    CHROME_BIN=/usr/bin/google-chrome \
    CHROME_PATH=/usr/bin/google-chrome \
    PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=true

# ==========================================================
# System dependencies
# ==========================================================

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    wget \
    unzip \
    gnupg \
    dumb-init \
    xvfb \
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

# ==========================================================
# Google Chrome
# ==========================================================

RUN mkdir -p /etc/apt/keyrings && \
    wget -qO- https://dl.google.com/linux/linux_signing_key.pub \
        | gpg --dearmor -o /etc/apt/keyrings/google.gpg && \
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/google.gpg] \
        https://dl.google.com/linux/chrome/deb/ stable main" \
        > /etc/apt/sources.list.d/google-chrome.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends google-chrome-stable && \
    rm -rf /var/lib/apt/lists/*

# ==========================================================
# Node.js 20
# ==========================================================

RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt-get update && \
    apt-get install -y --no-install-recommends nodejs && \
    npm cache clean --force && \
    rm -rf /var/lib/apt/lists/*

# ==========================================================
# Python dependencies
# ==========================================================

WORKDIR /app

COPY requirements.txt /app/requirements.txt

RUN python -m pip install --upgrade \
        pip \
        setuptools \
        wheel && \
    python -m pip install \
        --no-cache-dir \
        -r /app/requirements.txt

# ==========================================================
# Application
# ==========================================================

COPY Api.zip /app/Api.zip

RUN unzip -q /app/Api.zip -d /app && \
    rm -f /app/Api.zip

# ==========================================================
# Node dependencies
# ==========================================================

WORKDIR /app/Api

# package.json/package-lock.json sebaiknya berada di Api.zip
RUN if [ -f package-lock.json ]; then \
        npm ci --omit=dev; \
    else \
        npm install --omit=dev; \
    fi

# Dependency tambahan aplikasi
RUN npm install --omit=dev \
        generic-pool \
        p-queue@7 \
        jimp \
        tesseract.js \
        playwright

# ==========================================================
# Runtime
# ==========================================================

WORKDIR /app

RUN cat > /start.sh <<'EOF'
#!/bin/sh
set -eu

echo "=================================="
echo " Starting API Container"
echo "=================================="

cleanup() {
    echo "Stopping..."

    if [ -n "${XVFB_PID:-}" ]; then
        kill "$XVFB_PID" 2>/dev/null || true
    fi

    if [ -n "${NODE_PID:-}" ]; then
        kill "$NODE_PID" 2>/dev/null || true
    fi
}

trap cleanup INT TERM EXIT

echo "Chrome:"
google-chrome --version || true

echo "Node:"
node --version || true

echo "NPM:"
npm --version || true

echo "Python:"
python --version || true

echo "Starting Xvfb..."

Xvfb :99 \
    -screen 0 1366x768x24 \
    -ac \
    +extension RANDR \
    >/tmp/xvfb.log 2>&1 &

XVFB_PID=$!

sleep 2

if ! kill -0 "$XVFB_PID" 2>/dev/null; then
    echo "ERROR: Xvfb failed"
    cat /tmp/xvfb.log || true
    exit 1
fi

echo "Xvfb ready"

cd /app/Api

echo "Starting Api.js..."

node --no-deprecation Api.js &
NODE_PID=$!

wait "$NODE_PID"
EOF

RUN chmod +x /start.sh

# ==========================================================
# Health check
# ==========================================================

HEALTHCHECK \
    --interval=30s \
    --timeout=10s \
    --start-period=60s \
    --retries=5 \
    CMD curl -fsS http://127.0.0.1:8080/ || exit 1

EXPOSE 8080

ENTRYPOINT ["dumb-init", "--"]

CMD ["/start.sh"]
