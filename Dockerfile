FROM node:20-slim

# Instal dependensi sistem yang dibutuhkan Chromium dan Xvfb
RUN apt-get update && apt-get install -y \
    xvfb \
    libnss3 \
    libatk-bridge2.0-0 \
    libgtk-3-0 \
    libgbm1 \
    libasound2 \
    fonts-liberation \
    libappindicator3-1 \
    lsb-release \
    xdg-utils \
    wget \
    && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /app

# Copy package.json dan install dependensi
COPY package*.json ./
RUN npm install

# Copy seluruh kode proyek
COPY . .

# Railway akan mengabaikan port ini, tapi ini sebagai dokumentasi
EXPOSE 8080

# Jalankan aplikasi
CMD ["node", "app.js"]
