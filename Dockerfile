FROM node:20-slim

RUN apt-get update && apt-get install -y \
    wget gnupg ca-certificates xvfb \
    fonts-liberation libappindicator3-1 libasound2 libatk-bridge2.0-0 \
    libatk1.0-0 libxss1 libnss3 libxcomposite1 libxdamage1 libxrandr2 libgbm1 \
    && wget https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb \
    && apt-get install -y ./google-chrome-stable_current_amd64.deb \
    && rm google-chrome-stable_current_amd64.deb \
    && rm -rf /var/lib/apt/lists/*

# ── [v4.8] FIX DNS: HARDCODE HOSTS UNTUK CLOUDFLARE ──
# Memastikan container selalu resolve ke IP Cloudflare yang valid
RUN echo "nameserver 1.1.1.1" > /etc/resolv.conf && \
    echo "104.16.132.229 challenges.cloudflare.com" >> /etc/hosts && \
    echo "104.16.132.229 brunhid.challenges.cloudflare.com" >> /etc/hosts

WORKDIR /A

COPY package*.json ./

RUN npm ci --omit=dev

COPY . .

EXPOSE 7860

CMD ["sh", "-c", "rm -f /tmp/.X99-lock && Xvfb :99 -screen 0 1024x768x24 & export DISPLAY=:99 && exec npm start"]