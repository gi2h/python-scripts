FROM python:3.9-slim

ENV DEBIAN_FRONTEND=noninteractive

# ==========================================================
# System
# ==========================================================

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        curl \
        wget \
        unzip \
        xvfb \
        dumb-init \
        ca-certificates \
        gnupg \
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
        libu2f-udev \
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
        libxshmfence1 && \
    rm -rf /var/lib/apt/lists/*

# ==========================================================
# Google Chrome
# ==========================================================

RUN mkdir -p /etc/apt/keyrings && \
    wget -qO- https://dl.google.com/linux/linux_signing_key.pub | gpg --dearmor > /etc/apt/keyrings/google.gpg && \
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/google.gpg] http://dl.google.com/linux/chrome/deb/ stable main" > /etc/apt/sources.list.d/google.list && \
    apt-get update && \
    apt-get install -y google-chrome-stable && \
    rm -rf /var/lib/apt/lists/*

# ==========================================================
# NodeJS
# ==========================================================

RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt-get install -y nodejs && \
    npm cache clean --force

# ==========================================================
# Environment
# ==========================================================

ENV DISPLAY=:99
ENV PYTHONUNBUFFERED=1
ENV NODE_ENV=production
ENV PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=true
ENV CHROME_BIN=/usr/bin/google-chrome
ENV CHROME_PATH=/usr/bin/google-chrome
ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1

WORKDIR /app

# ==========================================================
# Copy Files
# ==========================================================

COPY requirements.txt .
COPY Api.zip .

# ==========================================================
# Extract Api
# ==========================================================


RUN unzip /app/Api.zip -d /app && \
    rm -f /app/Api.zip

# ==========================================================
# Python
# ==========================================================

RUN pip install --upgrade pip && \
    pip install -r requirements.txt

# ==========================================================
# Node
# ==========================================================

WORKDIR /app/Api

RUN npm install --omit=dev

RUN npm install \
    generic-pool \
    p-queue@7 \
    jimp \
    tesseract.js \
    playwright

WORKDIR /app

# ==========================================================
# Startup Script
# ==========================================================

RUN cat > /start.sh <<'EOF'
#!/bin/bash
set -e

echo "=================================="
echo " Starting API Container"
echo "=================================="

cleanup() {
    echo "Stopping..."
    pkill node || true
    pkill chrome || true
    pkill Xvfb || true
    exit 0
}

trap cleanup SIGINT SIGTERM

echo "Starting Xvfb..."

Xvfb :99 \
-screen 0 1366x768x24 \
-ac \
+extension RANDR &

sleep 2

echo "Starting Api.js..."

cd /app/Api

exec node --no-deprecation Api.js

EOF

RUN chmod +x /start.sh

# ==========================================================
# Health Check
# ==========================================================

HEALTHCHECK \
--interval=30s \
--timeout=10s \
--start-period=30s \
--retries=5 \
CMD curl -fs http://127.0.0.1:7860 || exit 1

EXPOSE 7860

ENTRYPOINT ["dumb-init","--"]

CMD ["/start.sh"]