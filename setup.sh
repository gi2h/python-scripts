#!/bin/bash
sudo apt-get update
sudo apt-get install -y xvfb libnss3 libatk-bridge2.0-0 libgtk-3-0 libgbm-dev
npm install
Xvfb :99 -screen 0 1920x1080x24 &
node app.js
