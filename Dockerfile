# ============================================
# DOCKERFILE FAUCET BOT - WITH API ZIP EXTRACT
# ============================================
FROM python:3.9-slim

# -------------------------------
# 1. Install system dependencies + Xvfb + unzip
# -------------------------------
RUN apt-get update && apt-get install -y \
    curl \
    wget \
    gnupg \
    ca-certificates \
    xz-utils \
    xvfb \
    unzip \
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
    && rm -rf /var/lib/apt/lists/*

# -------------------------------
# 2. Install Google Chrome
# -------------------------------
RUN mkdir -p /etc/apt/keyrings \
    && wget -q -O - https://dl.google.com/linux/linux_signing_key.pub > /tmp/google.pub \
    && gpg --dearmor < /tmp/google.pub > /etc/apt/keyrings/google-chrome.gpg \
    && echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main" > /etc/apt/sources.list.d/google-chrome.list \
    && apt-get update \
    && apt-get install -y google-chrome-stable \
    && rm -rf /var/lib/apt/lists/* \
    && rm /tmp/google.pub

WORKDIR /app

# -------------------------------
# 3. Install Python dependencies
# -------------------------------
COPY requirements.txt .
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir -r requirements.txt

# -------------------------------
# 4. Install Node.js 20
# -------------------------------
RUN mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" > /etc/apt/sources.list.d/nodesource.list \
    && apt-get update \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# -------------------------------
# 5. Copy & Extract API ZIP
# -------------------------------
COPY Api.zip /app/Api.zip
RUN unzip /app/Api.zip -d /app && \
    mv /app/Api* /app/Api || true && \
    rm /app/Api.zip

WORKDIR /app/Api
RUN npm install --omit=dev

WORKDIR /app

# -------------------------------
# 6. Copy Python bot
# -------------------------------
COPY app.py .

# -------------------------------
# 7. Startup Script
# -------------------------------
RUN echo '#!/bin/bash\n\
echo "🤖 STARTING FAUCET BOT"\n\
echo "======================"\n\
\n\
echo "Starting Node.js API..."\n\
cd /app/Api\n\
node Api.js &\n\
\n\
echo "Waiting for API to start..."\n\
sleep 5\n\
\n\
echo "Starting Python Bot..."\n\
cd /app\n\
xvfb-run -a python3 app.py\n\
' > /start.sh && chmod +x /start.sh

# -------------------------------
# 8. Healthcheck
# -------------------------------
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD curl -f http://localhost:3000/ || exit 1

EXPOSE 3000
CMD ["/start.sh"]
