FROM node:20-bookworm

ENV DEBIAN_FRONTEND=noninteractive
ENV NODE_ENV=production
ENV DISPLAY=:99

RUN apt-get update && apt-get install -y --no-install-recommends \
    wget \
    curl \
    gnupg \
    ca-certificates \
    unzip \
    xvfb \
    xauth \
    fonts-liberation \
    libnss3 \
    libatk-bridge2.0-0 \
    libx11-xcb1 \
    libxcb-dri3-0 \
    libxcomposite1 \
    libxdamage1 \
    libxrandr2 \
    libgbm1 \
    libasound2 \
    libatk1.0-0 \
    libgtk-3-0 \
    libxshmfence1 \
    procps \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /etc/apt/keyrings \
    && wget -q -O /tmp/google.pub \
       https://dl.google.com/linux/linux_signing_key.pub \
    && gpg --dearmor \
       < /tmp/google.pub \
       > /etc/apt/keyrings/google-chrome.gpg \
    && echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main" \
       > /etc/apt/sources.list.d/google-chrome.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends google-chrome-stable \
    && rm -rf /var/lib/apt/lists/* /tmp/google.pub

WORKDIR /app

COPY Api.zip /tmp/Api.zip

RUN mkdir -p /tmp/api \
    && unzip -q /tmp/Api.zip -d /tmp/api \
    && API_JS="$(find /tmp/api -type f -name 'Api.js' -print -quit)" \
    && test -n "$API_JS" \
    && API_DIR="$(dirname "$API_JS")" \
    && cp -a "$API_DIR"/. /app/ \
    && rm -rf /tmp/api /tmp/Api.zip \
    && test -f /app/Api.js

RUN if [ -f package-lock.json ]; then \
        npm ci --omit=dev; \
    elif [ -f package.json ]; then \
        npm install --omit=dev; \
    fi

RUN cat > /start.sh <<'EOF'
#!/bin/bash
set -e

export DISPLAY=:99
export PORT="${PORT:-8080}"

rm -f /tmp/.X99-lock

Xvfb :99 \
    -screen 0 1920x1080x24 \
    -ac \
    +extension GLX \
    +render \
    -noreset \
    >/tmp/xvfb.log 2>&1 &

XVFB_PID=$!

sleep 2

if ! kill -0 "$XVFB_PID" 2>/dev/null; then
    cat /tmp/xvfb.log
    exit 1
fi

echo "Xvfb ready"
echo "Starting Node API on PORT=$PORT"

exec node /app/Api.js
EOF

RUN chmod +x /start.sh

EXPOSE 8080

CMD ["/start.sh"]