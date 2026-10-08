FROM python:3.11-slim

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    NODE_ENV=production \
    DISPLAY=:99 \
    CHROME_BIN=/usr/bin/google-chrome \
    CHROME_PATH=/usr/bin/google-chrome \
    PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=true \
    PUPPETEER_SKIP_DOWNLOAD=true \
    PUPPETEER_EXECUTABLE_PATH=/usr/bin/google-chrome \
    PLAYWRIGHT_BROWSERS_PATH=/ms-playwright

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
    dnsmasq \
    netcat-openbsd \
    iproute2 \
    procps \
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

RUN if [ -f package-lock.json ]; then \
        npm ci --omit=dev; \
    else \
        npm install --omit=dev; \
    fi

RUN npm install --omit=dev \
        generic-pool \
        p-queue@7 \
        jimp \
        tesseract.js \
        playwright

# Playwright browser (kalau turnstile.js pakai playwright)
RUN npx playwright install chromium 2>/dev/null || echo "playwright chromium skip"
RUN npx playwright install-deps chromium 2>/dev/null || true

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

    if [ -n "${TAIL_PID:-}" ]; then
        kill "$TAIL_PID" 2>/dev/null || true
    fi
    if [ -n "${NODE_PID:-}" ]; then
        kill "$NODE_PID" 2>/dev/null || true
    fi
    if [ -n "${XVFB_PID:-}" ]; then
        kill "$XVFB_PID" 2>/dev/null || true
    fi
    if [ -n "${DNSMASQ_PID:-}" ]; then
        kill "$DNSMASQ_PID" 2>/dev/null || true
    fi
}

trap cleanup INT TERM EXIT

# ==========================================================
# DNS — 6-layer fallback
# ==========================================================
echo "=================================="
echo " DNS Setup"
echo "=================================="
echo "Before:"
cat /etc/resolv.conf 2>/dev/null || echo "(empty)"
echo ""

DNS_CONTENT="nameserver 1.1.1.1
nameserver 1.0.0.1
nameserver 8.8.8.8
nameserver 8.8.4.4
options timeout:2 attempts:3 rotate"

DNS_OK=0

# -- Layer 1: direct write
if [ -w /etc/resolv.conf ]; then
    printf '%s\n' "$DNS_CONTENT" > /etc/resolv.conf 2>/dev/null && \
        DNS_OK=1 && echo "  [L1] direct write: OK"
fi

# -- Layer 2: strip immutable flag then write
if [ "$DNS_OK" = "0" ]; then
    chattr -i /etc/resolv.conf 2>/dev/null || true
    if [ -w /etc/resolv.conf ]; then
        printf '%s\n' "$DNS_CONTENT" > /etc/resolv.conf 2>/dev/null && \
            DNS_OK=1 && echo "  [L2] chattr -i + write: OK"
    fi
fi

# -- Layer 3: remount /etc rw
if [ "$DNS_OK" = "0" ]; then
    mount -o remount,rw /etc 2>/dev/null || true
    if [ -w /etc/resolv.conf ]; then
        printf '%s\n' "$DNS_CONTENT" > /etc/resolv.conf 2>/dev/null && \
            DNS_OK=1 && echo "  [L3] remount /etc rw: OK"
    fi
fi

# -- Layer 4: dnsmasq on 127.0.0.1
if [ "$DNS_OK" = "0" ]; then
    echo "  [L4] starting dnsmasq on 127.0.0.1:53..."
    dnsmasq --no-resolv \
            --server=1.1.1.1 \
            --server=1.0.0.1 \
            --server=8.8.8.8 \
            --server=8.8.4.4 \
            --listen-address=127.0.0.1 \
            --bind-interfaces \
            --port=53 \
            --user=root \
            --log-facility=/tmp/dnsmasq.log \
            >/tmp/dnsmasq.log 2>&1 &
    DNSMASQ_PID=$!
    sleep 1
    if kill -0 "$DNSMASQ_PID" 2>/dev/null; then
        echo "  [L4] dnsmasq running (PID $DNSMASQ_PID)"
        # Coba arahkan resolv.conf ke dnsmasq lokal
        if [ -w /etc/resolv.conf ]; then
            echo "nameserver 127.0.0.1" > /etc/resolv.conf 2>/dev/null && \
                DNS_OK=1 && echo "  [L4] resolv.conf → 127.0.0.1"
        fi
    else
        echo "  [L4] dnsmasq FAILED"
    fi
fi

# -- Layer 5: /etc/hosts patch (last resort)
if [ "$DNS_OK" = "0" ]; then
    echo "  [L5] patching /etc/hosts..."
    if [ -w /etc/hosts ]; then
        cat >> /etc/hosts <<'HOSTS_EOF'

# DNS fallback entries
104.16.132.229 challenges.cloudflare.com
104.16.133.229 challenges.cloudflare.com
104.16.134.229 challenges.cloudflare.com
1.1.1.1 one.one.one.one
8.8.8.8 dns.google
HOSTS_EOF
        echo "  [L5] /etc/hosts patched"
    else
        echo "  [L5] /etc/hosts read-only, skipped"
    fi
fi

# -- Layer 6: force Chrome/Node DoH via env (Node + Puppeteer-ish)
export NODE_OPTIONS="--dns-result-order=ipv4first --no-deprecation"

echo ""
echo "After:"
cat /etc/resolv.conf 2>/dev/null || echo "(empty)"

# ==========================================================
# DNS verification
# ==========================================================
echo ""
echo "DNS verification:"
for host in challenges.cloudflare.com www.clicks-hits.com google.com; do
    if getent hosts "$host" >/dev/null 2>&1; then
        ip=$(getent hosts "$host" 2>/dev/null | head -1 | awk '{print $1}')
        echo "  OK   $host -> ${ip:-resolved}"
    else
        echo "  FAIL $host"
    fi
done

# ==========================================================
# Environment info
# ==========================================================

echo ""
echo "Chrome:"
google-chrome --version || true

echo "Node:"
node --version || true

echo "NPM:"
npm --version || true

echo "Python:"
python --version || true

echo "Playwright browsers:"
ls -la /ms-playwright 2>/dev/null || echo "  (not found)"

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

# Jalankan Node — log ke stdout (Railway) + file (backup)
node Api.js > /tmp/api.log 2>&1 &
NODE_PID=$!

# Tail log ke stdout supaya terlihat di Railway
tail -f /tmp/api.log &
TAIL_PID=$!

wait "$NODE_PID"
EOF

RUN chmod +x /start.sh

# ==========================================================
# Health check
# ==========================================================

HEALTHCHECK \
    --interval=30s \
    --timeout=10s \
    --start-period=90s \
    --retries=5 \
    CMD nc -z 127.0.0.1 8080 || exit 1

EXPOSE 8080

ENTRYPOINT ["dumb-init", "--"]

CMD ["/start.sh"]
