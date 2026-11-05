FROM node:20-slim

# Instal Chromium dan semua dependensi sistem untuk Headful browser
RUN apt-get update && apt-get install -y \
    chromium \
    xvfb \
    libnss3 \
    libatk-bridge2.0-0 \
    libgtk-3-0 \
    libgbm1 \
    libasound2 \
    fonts-liberation \
    lsb-release \
    xdg-utils \
    wget \
    && rm -rf /var/lib/apt/lists/*

# 🛠️ KUNCI PERBAIKAN: Arahkan library ke binary Chromium yang baru diinstal
ENV CHROME_PATH=/usr/bin/chromium
ENV PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium
ENV PUPPETEER_SKIP_DOWNLOAD=true

WORKDIR /app

COPY package*.json ./
RUN npm install

COPY . .

EXPOSE 8080
CMD ["node", "app.js"]
