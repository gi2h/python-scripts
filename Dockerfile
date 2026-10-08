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
    ca-certificates curl wget unzip gnupg dumb-init xvfb \
    dnsmasq netcat-openbsd iproute2 procps \
    fonts-liberation fonts-noto-color-emoji \
    libasound2 libatk-bridge2.0-0 libatk1.0-0 libcups2 libdrm2 \
    libgbm1 libglib2.0-0 libgtk-3-0 libnspr4 libnss3 libvulkan1 \
    libx11-6 libx11-xcb1 libxcb1 libxcomposite1 libxdamage1 \
    libxext6 libxfixes3 libxkbcommon0 libxrandr2 libxrender1 \
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

RUN python -m pip install --upgrade pip setuptools wheel && \
    python -m pip install --no-cache-dir -r /app/requirements.txt

# ==========================================================
# Application
# ==========================================================

COPY Api.zip /app/Api.zip
RUN unzip -q /app/Api.zip -d /app && rm -f /app/Api.zip

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

# Playwright browser
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
    [ -n "${TAIL_PID:-}" ]    && kill "$TAIL_PID" 2>/dev/null || true
    [ -n "${NODE_PID:-}" ]    && kill "$NODE_PID" 2>/dev/null || true
    [ -n "${XVFB_PID:-}" ]    && kill "$XVFB_PID" 2>/dev/null || true
    [ -n "${DNSMASQ_PID:-}" ] && kill "$DNSMASQ_PID" 2>/dev/null || true
}
trap cleanup INT TERM EXIT

# ==========================================================
# DNS — paksa IPv4-only via dnsmasq (filter-AAAA)
# ==========================================================
echo "=================================="
echo " DNS Setup (IPv4-only mode)"
echo "=================================="
echo "Before:"
cat /etc/resolv.conf 2>/dev/null || echo "(empty)"
echo ""

# Kill any existing dnsmasq
pkill dnsmasq 2>/dev/null || true
sleep 1

# Free port 53 if occupied
if command -v ss >/dev/null 2>&1; then
    ss -tulpn 2>/dev/null | grep ':53 ' || true
fi

# Write dnsmasq config
cat > /tmp/dnsmasq.conf <<'DNSMASQ_EOF'
no-resolv
server=1.1.1.1
server=1.0.0.1
server=8.8.8.8
server=8.8.4.4
server=9.9.9.9
filter-AAAA
cache-size=1000
listen-address=127.0.0.1
bind-interfaces
port=53
user=root
log-facility=/tmp/dnsmasq.log
log-queries
DNSMASQ_EOF

echo "Starting dnsmasq (filter-AAAA = drop IPv6)..."
dnsmasq --conf-file=/tmp/dnsmasq.conf >/tmp/dnsmasq.out 2>&1 &
DNSMASQ_PID=$!
sleep 2

if ! kill -0 "$DNSMASQ_PID" 2>/dev/null; then
    echo "ERROR: dnsmasq failed to start"
    cat /tmp/dnsmasq.out || true
    cat /tmp/dnsmasq.log 2>/dev/null || true
    echo "Falling back to direct DNS..."
    printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\noptions timeout:2 attempts:3\n' > /etc/resolv.conf
else
    echo "dnsmasq running (PID $DNSMASQ_PID)"
    # Point resolv.conf to local dnsmasq
    chattr -i /etc/resolv.conf 2>/dev/null || true
    printf 'nameserver 127.0.0.1\noptions timeout:2 attempts:2\n' > /etc/resolv.conf
fi

# Force IPv4 precedence for getaddrinfo (Node, Chrome, curl)
cat > /etc/gai.conf <<'GAI_EOF'
precedence ::ffff:0:0/96  100
GAI_EOF

# Node.js prefer IPv4
export NODE_OPTIONS="--dns-result-order=ipv4first --no-deprecation"

# Disable system IPv6 if kernel allows
sysctl -w net.ipv6.conf.all.disable_ipv6=1 2>/dev/null || true
sysctl -w net.ipv6.conf.default.disable_ipv6=1 2>/dev/null || true

echo ""
echo "After:"
cat /etc/resolv.conf 2>/dev/null || echo "(empty)"
echo ""

# ==========================================================
# DNS verification — expect IPv4 only now
# ==========================================================
echo "DNS verification:"
for host in challenges.cloudflare.com www.clicks-hits.com google.com; do
    ipv4=$(getent ahostsv4 "$host" 2>/dev/null | head -1 | awk '{print $1}')
    ipv6=$(getent ahostsv6 "$host" 2>/dev/null | head -1 | awk '{print $1}')
    if [ -n "$ipv4" ]; then
        echo "  OK   $host -> $ipv4"
    else
        echo "  FAIL $host (no IPv4)"
    fi
    if [ -n "$ipv6" ]; then
        echo "  WARN $host has IPv6: $ipv6 (will be filtered by Chrome if DoH not used)"
    fi
done

# ==========================================================
# Quick connectivity test (IPv4 only)
# ==========================================================
echo ""
echo "IPv4 connectivity test:"
curl -4 -sS -o /dev/null -w "  challenges.cloudflare.com -> HTTP %{http_code} (%{time_total}s)\n" \
    --max-time 10 https://challenges.cloudflare.com/turnstile/v0/api.js \
    || echo "  IPv4 HTTPS to Cloudflare FAILED"

# ==========================================================
# Environment info
# ==========================================================
echo ""
echo "Chrome: $(google-chrome --version 2>/dev/null || echo missing)"
echo "Node:   $(node --version 2>/dev/null || echo missing)"
echo "NPM:    $(npm --version 2>/dev/null || echo missing)"
echo "Python: $(python --version 2>/dev/null || echo missing)"
echo "Playwright browsers:"
ls -la /ms-playwright 2>/dev/null | head -10 || echo "  (not found)"

echo ""
echo "Starting Xvfb..."
Xvfb :99 -screen 0 1366x768x24 -ac +extension RANDR >/tmp/xvfb.log 2>&1 &
XVFB_PID=$!
sleep 2

if ! kill -0 "$XVFB_PID" 2>/dev/null; then
    echo "ERROR: Xvfb failed"
    cat /tmp/xvfb.log || true
    exit 1
fi
echo "Xvfb ready"

cd /app/Api
echo ""
echo "Starting Api.js..."
node Api.js > /tmp/api.log 2>&1 &
NODE_PID=$!

tail -f /tmp/api.log &
TAIL_PID=$!

wait "$NODE_PID"
EOF

RUN chmod +x /start.sh

# ==========================================================
# Healthcheck (pakai nc, bukan curl — hindari restart loop)
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
