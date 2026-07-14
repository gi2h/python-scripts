#!/usr/bin/env python3
"""
PEPE FAUCET BOT - MINIMALIS + COOLDOWN CHECK + HF SPACE READY
- Satu coin: freepepecoin.com
- Cek cooldown SEBELUM claim (hemat kredit solver)
- Simpan cookies & total claim ke file
- Auto claim dengan cooldown dari halaman
- Support Hugging Face Space dengan healthcheck endpoint
- LOGGING LENGKAP + ALERT HTML DI KONSOL
"""

import sys
import os
import json
import time
import re
import requests
import traceback
from datetime import datetime
from threading import Thread
from http.server import HTTPServer, BaseHTTPRequestHandler

# ============= UNBUFFERED OUTPUT =============
try:
    sys.stdout.reconfigure(line_buffering=True)
except AttributeError:
    import functools
    print = functools.partial(print, flush=True)

# ============= KONFIGURASI =============
EMAIL = "Casminivana@gmail.com"               # Ganti dengan email FaucetPay Anda
SOLVER_URL = "https://qonita2545-pepe.hf.space" # URL solver reCAPTCHA
SOLVER_KEY = "00000000000000000000#0000000000000000000#000000000000000000#"  # API key solver
COOKIES_FILE = "cookies_pepe.json"
STATS_FILE   = "stats_pepe.json"
LOG_FILE     = "bot.log"                # File log
# ========================================

# ============= FUNGSI LOGGING =============
def log(level, message, alert_html=None):
    """Cetak log dengan timestamp + simpan ke file."""
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    log_line = f"[{timestamp}] [{level}] {message}"
    print(log_line)
    if alert_html:
        print(alert_html)  # Tampilkan alert HTML di konsol
    # Simpan ke file log
    try:
        with open(LOG_FILE, 'a', encoding='utf-8') as f:
            f.write(log_line + "\n")
            if alert_html:
                f.write(alert_html + "\n")
    except:
        pass

def log_info(msg):
    log("INFO", msg)

def log_success(msg):
    alert = f'<div class="alert alert-success">{msg}</div>'
    log("SUCCESS", msg, alert)

def log_warning(msg):
    alert = f'<div class="alert alert-warning">{msg}</div>'
    log("WARNING", msg, alert)

def log_error(msg):
    alert = f'<div class="alert alert-danger">{msg}</div>'
    log("ERROR", msg, alert)

# ============= HEALTHCHECK SERVER UNTUK HUGGING FACE =============
class HealthHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"Bot is running")
    def log_message(self, format, *args):
        pass  # Jangan banjiri log

def start_health_server():
    try:
        server = HTTPServer(('0.0.0.0', 7860), HealthHandler)
        log_info("✅ Healthcheck server running on port 7860 (untuk Hugging Face)")
        server.serve_forever()
    except Exception as e:
        log_error(f"Healthcheck server error: {e}")

Thread(target=start_health_server, daemon=True).start()
# =================================================================

session = requests.Session()
session.headers.update({
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/144.0.0.0 Safari/537.36',
    'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8',
    'Accept-Language': 'id-ID,id;q=0.9,en-US;q=0.8,en;q=0.7',
})

# ============= TEST KONEKSI SOLVER =============
def test_solver():
    log_info("🔍 Menguji koneksi ke solver...")
    try:
        r = requests.get(SOLVER_URL, timeout=5)
        log_info(f"✓ Solver OK (HTTP {r.status_code})")
        return True
    except Exception as e:
        log_error(f"✗ Solver GAGAL: {e}")
        return False

test_solver()
log_info("="*50)

# ============= FUNGSI COOKIES & STATS =============
def save_cookies():
    try:
        cookies_dict = requests.utils.dict_from_cookiejar(session.cookies)
        with open(COOKIES_FILE, 'w') as f:
            json.dump({
                'cookies': cookies_dict,
                'saved_at': datetime.now().isoformat(),
                'email': EMAIL
            }, f)
        log_info("✓ Cookies disimpan")
        return True
    except Exception as e:
        log_warning(f"⚠️ Gagal simpan cookies: {e}")
        return False

def load_cookies():
    try:
        if os.path.exists(COOKIES_FILE):
            with open(COOKIES_FILE, 'r') as f:
                data = json.load(f)
                cookies_dict = data.get('cookies', {})
                session.cookies = requests.utils.cookiejar_from_dict(cookies_dict)
                log_info("✓ Cookies dimuat")
                return True
    except Exception as e:
        log_warning(f"⚠️ Gagal muat cookies: {e}")
    return False

def load_total_claims():
    try:
        if os.path.exists(STATS_FILE):
            with open(STATS_FILE, 'r') as f:
                data = json.load(f)
                return data.get('total_claims', 0)
    except:
        pass
    return 0

def save_total_claims(total):
    try:
        with open(STATS_FILE, 'w') as f:
            json.dump({'total_claims': total, 'updated': datetime.now().isoformat()}, f)
    except Exception as e:
        log_warning(f"⚠️ Gagal simpan statistik: {e}")

# ============= FUNGSI CEK COOLDOWN =============
def check_cooldown():
    try:
        resp = session.get("https://freepepecoin.com/", timeout=15)
        if resp.status_code != 200:
            return 0, "Gagal memuat halaman"
        match = re.search(r'Please wait (\d+)s', resp.text)
        if match:
            cd = int(match.group(1))
            return cd, f"Cooldown {cd} detik"
        if 'Claim Pepe' in resp.text and 'Please wait' not in resp.text:
            return 0, "Siap claim"
        return 0, "Tidak ada info cooldown"
    except Exception as e:
        return 0, f"Error: {e}"

# ============= FUNGSI RECAPTCHA =============
def solve_recaptcha():
    log_info("  [reCAPTCHA] Meminta token...")
    headers = {"Content-Type": "application/json", "key": SOLVER_KEY}
    data = {
        "type": "recaptcha3",
        "domain": "https://freepepecoin.com",
        "siteKey": "6LcbMB0sAAAAAAxsy76NqLNBhHfzZO8E4jLJ8XNl"
    }
    try:
        resp = requests.post(f"{SOLVER_URL}/solve", headers=headers, json=data, timeout=30)
        result = resp.json()
        if "taskId" not in result:
            log_error("  ❌ Gagal dapat Task ID")
            return None
        task_id = result["taskId"]
        
        for _ in range(30):
            time.sleep(2)
            poll = requests.post(f"{SOLVER_URL}/solve", headers=headers, json={"taskId": task_id}, timeout=30)
            poll_res = poll.json()
            if poll_res.get("status") == "done":
                token = poll_res.get("token") or poll_res.get("solution", {}).get("token")
                if token:
                    log_success("  ✓ reCAPTCHA solved!")
                    return token
            elif poll_res.get("status") == "error":
                log_error("  ❌ Error solver")
                return None
        log_error("  ❌ Timeout solver")
        return None
    except Exception as e:
        log_error(f"  ❌ Error reCAPTCHA: {e}")
        return None

# ============= FUNGSI CSRF TOKEN =============
def get_csrf_token():
    log_info("  [CSRF] Mengambil token...")
    try:
        resp = session.get("https://freepepecoin.com/", timeout=30)
        if resp.status_code != 200:
            log_error(f"  ❌ Gagal akses halaman: {resp.status_code}")
            return None
        match = re.search(r'name="csrf_token" value="([a-f0-9]{64})"', resp.text)
        if match:
            token = match.group(1)
            log_info(f"  ✓ CSRF token: {token[:16]}...")
            return token
        else:
            log_error("  ❌ CSRF token tidak ditemukan")
            return None
    except Exception as e:
        log_error(f"  ❌ Error ambil CSRF: {e}")
        return None

# ============= FUNGSI CLAIM =============
total_claims = load_total_claims()

def claim():
    global total_claims
    log_info("\n" + "="*50)
    log_info("🪙  CLAIM PEPE")
    log_info("="*50)

    # 1. Cek cooldown dulu!
    cd, msg = check_cooldown()
    if cd > 0:
        log_warning(f"⏳ {msg} – tunggu dulu.")
        return "cooldown", cd
    
    log_success(f"✅ {msg} – langsung claim.")

    # 2. Ambil CSRF token
    csrf = get_csrf_token()
    if not csrf:
        return "error", None

    # 3. Dapatkan token reCAPTCHA
    captcha = solve_recaptcha()
    if not captcha:
        return "error", None

    # 4. Kirim POST claim
    log_info("  [POST] Mengirim claim...")
    headers = {
        'Content-Type': 'application/x-www-form-urlencoded',
        'Origin': 'https://freepepecoin.com',
        'Referer': 'https://freepepecoin.com/',
    }
    data = {
        'csrf_token': csrf,
        'g-recaptcha-response': captcha,
        'email': EMAIL,
        'claim': ''
    }
    try:
        resp = session.post("https://freepepecoin.com/", headers=headers, data=data, timeout=30, allow_redirects=True)
        log_info(f"  Response: {resp.status_code}")

        # Cek captcha failed
        if 'Captcha verification failed.' in resp.text:
            log_error("  ⚠️  Captcha verification failed – akan coba lagi dengan token baru.")
            log_error('<div class="alert alert-danger">Captcha verification failed.</div>')  # Alert HTML
            return "captcha_failed", None

        # Cek sukses
        success_keywords = ['successfully', 'claimed', 'reward', 'thank you', 'you received', 'congratulation']
        if any(kw in resp.text.lower() for kw in success_keywords):
            total_claims += 1
            success_msg = f"✅ CLAIM BERHASIL! Total claim sukses: {total_claims}"
            log_success(success_msg)
            
            # Ambil reward
            reward_match = re.search(r'(\d+\.?\d*)\s*PEPE', resp.text)
            if reward_match:
                reward = float(reward_match.group(1))
                log_success(f"  💰 Reward: {reward} PEPE")
            
            # Simpan cookies dan statistik
            save_cookies()
            save_total_claims(total_claims)
            
            # Cek cooldown baru dari halaman (biasanya langsung muncul)
            cd_new, _ = check_cooldown()
            if cd_new > 0:
                return "success", cd_new
            else:
                return "success", 240  # fallback
        else:
            log_error("  ❌ Claim gagal (tidak terdeteksi sukses)")
            return "error", None

    except Exception as e:
        log_error(f"  ❌ Error claim: {e}")
        return "error", None

# ============= MAIN LOOP =============
def main():
    log_info("\n🚀 PEPE FAUCET BOT MINIMALIS + COOLDOWN CHECK + HF SPACE READY")
    log_info(f"📧 Email: {EMAIL}")
    log_info(f"📊 Total claim sebelumnya: {total_claims}")
    log_info("="*50)

    # Muat cookies
    load_cookies()

    while True:
        status, value = claim()
        
        if status == "cooldown":
            log_info(f"😴 Tidur {value} detik (cooldown)...")
            time.sleep(value)
        
        elif status == "captcha_failed":
            log_info("🔄 Coba claim ulang dalam 5 detik dengan token baru...")
            time.sleep(5)
        
        elif status == "success":
            cooldown = value if value else 240
            log_info(f"😴 Tidur {cooldown} detik hingga claim berikutnya...")
            time.sleep(cooldown)
        
        else:  # error
            log_info("⏳ Coba lagi dalam 30 detik...")
            time.sleep(30)

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        log_info("\n👋 Bot dihentikan user")
    except Exception:
        log_error("\n💥 UNHANDLED EXCEPTION:")
        traceback.print_exc()
        sys.exit(1)