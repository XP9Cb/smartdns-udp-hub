#!/bin/bash
set -e

PANEL_PORT="8080"

echo "===================================================="
echo " Установка SmartDNS & UDP Hub (Multi-User Edition)"
echo "===================================================="
read -r -p "Введите новый пароль для веб-панели (Enter = dns2026): " INPUT_PASS </dev/tty || true
export ADMIN_PASS="${INPUT_PASS:-dns2026}"

echo "[1/7] Определение сетевых параметров..."
export EXT_IP=$(curl -s https://api.ipify.org || curl -s https://ifconfig.me)
export INT_IP=$(hostname -I | awk '{print $1}')
export SSH_IP=$(echo "${SSH_CLIENT:-}" | awk '{print $1}')
grep -q "$(hostname)" /etc/hosts || echo "127.0.1.1 $(hostname)" >> /etc/hosts

echo "Внешний IP: $EXT_IP | Внутренний IP: $INT_IP | Текущий IP клиента: ${SSH_IP:-не определен}"

echo "[2/7] Настройка Swap (1 ГБ) для стабильной работы на e2-micro..."
if [ ! -f /swapfile ] && [ "$(swapon --show | wc -l)" -eq 0 ]; then
    fallocate -l 1G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=1024 status=none
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile
    grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    echo "Swap 1 ГБ успешно создан и активирован."
else
    echo "Swap уже активен, пропускаем."
fi

echo "[3/7] Отключение systemd-resolved и установка пакетов..."
systemctl stop systemd-resolved 2>/dev/null || true
systemctl disable systemd-resolved 2>/dev/null || true
rm -f /etc/resolv.conf
echo "nameserver 8.8.8.8" > /etc/resolv.conf

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y dnsmasq sniproxy python3 python3-flask iptables curl dnsutils

echo "[4/7] Настройка ядра Linux и снятие ограничений соединений..."
cat << EOF > /etc/sysctl.d/99-smartdns.conf
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
fs.file-max=2097152
EOF
sysctl --system >/dev/null

mkdir -p /etc/systemd/system/dnsmasq.service.d
cat << 'EOF' > /etc/systemd/system/dnsmasq.service.d/override.conf
[Service]
LimitNOFILE=65535
ExecStart=
ExecStart=/usr/sbin/dnsmasq -x /run/dnsmasq/dnsmasq.pid -u dnsmasq -r /run/dnsmasq/resolv.conf -7 /etc/dnsmasq.d,.dpkg-dist,.dpkg-old,.dpkg-new
EOF
systemctl daemon-reload

echo "[5/7] Настройка SNI Proxy (IPv4 + LimitNOFILE=65535)..."
systemctl stop sniproxy 2>/dev/null || true
pkill -x sniproxy 2>/dev/null || true
[ -f /etc/default/sniproxy ] && sed -i 's/ENABLED=0/ENABLED=1/' /etc/default/sniproxy

cat << 'EOF' > /etc/sniproxy.conf
user daemon
pidfile /var/run/sniproxy.pid

resolver {
    nameserver 8.8.8.8
    nameserver 1.1.1.1
    mode ipv4_only
}

listen 0.0.0.0:80 {
    proto http
    table http_hosts
}

listen 0.0.0.0:443 {
    proto tls
    table https_hosts
}

table http_hosts {
    .* *
}

table https_hosts {
    .* *
}
EOF

cat << 'EOF' > /etc/systemd/system/sniproxy.service
[Unit]
Description=SNI Proxy
After=network.target

[Service]
Type=simple
LimitNOFILE=65535
ExecStart=/usr/sbin/sniproxy -c /etc/sniproxy.conf -f
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable sniproxy
systemctl restart sniproxy

echo "[6/7] Создание конфигурации и веб-панели SmartDNS & UDP Hub..."
mkdir -p /opt/smartdns

python3 -c '
import json, os, secrets
ips = []
ssh_ip = os.environ.get("SSH_IP", "").strip()
if ssh_ip:
    ips.append(f"{ssh_ip} # Admin")

cfg_path = "/opt/smartdns/config.json"
if os.path.exists(cfg_path):
    with open(cfg_path, "r", encoding="utf-8") as f:
        cfg = json.load(f)
    cfg["password"] = os.environ["ADMIN_PASS"]
    cfg["ext_ip"] = os.environ["EXT_IP"]
    cfg["int_ip"] = os.environ["INT_IP"]
    if "ddns_tokens" not in cfg:
        cfg["ddns_tokens"] = {}
        if cfg.get("ddns_token"):
            cfg["ddns_tokens"][cfg.pop("ddns_token")] = "Router"
        else:
            cfg["ddns_tokens"][secrets.token_hex(12)] = "Router"
else:
    cfg = {
      "password": os.environ["ADMIN_PASS"],
      "ddns_tokens": {
        secrets.token_hex(12): "Router"
      },
      "ext_ip": os.environ["EXT_IP"],
      "int_ip": os.environ["INT_IP"],
      "wildcard_mode": False,
      "block_ipv6": True,
      "log_queries": True,
      "allowed_ips": ips,
      "domains": [
        "account.live.com", "account.microsoft.com", "accounts.xboxlive.com",
        "cp.microsoft.com", "device.auth.xboxlive.com", "gamepass.com",
        "gfx.ms", "login.live.com", "mgt.xboxlive.com", "microsoftonline.com",
        "mp.microsoft.com", "msftauth.net", "pmservices.cp.microsoft.com",
        "rta.xboxlive.com", "title.auth.xboxlive.com", "titlestorage.xboxlive.com",
        "user.auth.xboxlive.com", "xbox.com", "xboxab.com", "teal.xboxservices.com",
        "silver.xboxservices.com", "xsts.auth.xboxlive.com", "settings.xboxlive.com",
        "directory.xboxlive.com", "activity.windows.com", "edge.microsoft.com",
        "displaycatalog.mp.microsoft.com", "licensing.mp.microsoft.com",
        "purchase.mp.microsoft.com", "bing.com", "rewards.microsoft.com", "addr.tools"
      ],
      "udp_rules": []
    }

with open(cfg_path, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
'

cat << 'EOF' > /opt/smartdns/app.py
import os, json, subprocess, shutil, threading, secrets
from functools import wraps
from flask import Flask, request, render_template_string, redirect, url_for, session, flash, Response

app = Flask(__name__)
app.secret_key = os.urandom(24)
CONFIG_FILE = "/opt/smartdns/config.json"
LOCK = threading.Lock()

PRESETS = {
    "xbox": [
        "account.live.com", "account.microsoft.com", "accounts.xboxlive.com",
        "cp.microsoft.com", "device.auth.xboxlive.com", "gamepass.com",
        "gfx.ms", "login.live.com", "mgt.xboxlive.com", "microsoftonline.com",
        "mp.microsoft.com", "msftauth.net", "pmservices.cp.microsoft.com",
        "rta.xboxlive.com", "title.auth.xboxlive.com", "titlestorage.xboxlive.com",
        "user.auth.xboxlive.com", "xbox.com", "xboxab.com", "teal.xboxservices.com",
        "silver.xboxservices.com", "xsts.auth.xboxlive.com", "settings.xboxlive.com",
        "directory.xboxlive.com", "activity.windows.com", "edge.microsoft.com",
        "displaycatalog.mp.microsoft.com", "licensing.mp.microsoft.com",
        "purchase.mp.microsoft.com", "bing.com", "rewards.microsoft.com", "addr.tools"
    ],
    "gemini": [
        "gemini.google.com", "aistudio.google.com", "makersuite.google.com",
        "generativelanguage.googleapis.com", "alkalimakersuite-pa.clients6.google.com",
        "proactivebackend-pa.googleapis.com", "bard.google.com", "labs.google",
        "aitestkitchen.withgoogle.com", "notebooklm.google.com", "notebooklm.google"
    ],
    "openai": [
        "openai.com", "chatgpt.com", "oaistatic.com", "oaiusercontent.com", "auth0.com", "sora.com"
    ],
    "claude": [
        "claude.ai", "anthropic.com", "claudeusercontent.com"
    ],
    "meta_x": [
        "instagram.com", "cdninstagram.com", "threads.net", "threads.com",
        "facebook.com", "fbcdn.net", "fbsbx.com", "x.com", "twitter.com", "twimg.com", "t.co"
    ],
    "discord": [
        "discord.com", "discordapp.com", "discordapp.net", "discord.gg", "discord.media", "discordcdn.com"
    ],
    "spotify": [
        "spotify.com", "scdn.co", "spotifycdn.com", "spotifycharts.com"
    ],
    "work": [
        "canva.com", "notion.so", "notion.site", "notion-static.com", "linkedin.com", "licdn.com"
    ]
}

def load_config():
    with open(CONFIG_FILE, "r", encoding="utf-8") as f:
        cfg = json.load(f)
    if "ddns_tokens" not in cfg:
        cfg["ddns_tokens"] = {}
        if cfg.get("ddns_token"):
            cfg["ddns_tokens"][cfg.pop("ddns_token")] = "Router"
        save_config(cfg)
    return cfg

def save_config(cfg):
    with open(CONFIG_FILE, "w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)

def extract_ips(raw_list):
    clean = []
    for item in raw_list:
        ip = item.split("#")[0].strip()
        if ip:
            clean.append(ip)
    return list(dict.fromkeys(clean))

def resolve_real_ip(domain):
    try:
        out = subprocess.check_output(["dig", "+short", "@8.8.8.8", domain], text=True, timeout=3).strip().splitlines()
        for line in out:
            if all(c.isdigit() or c == '.' for c in line) and line.count('.') == 3:
                return line
    except Exception:
        pass
    return domain

def apply_system_changes():
    cfg = load_config()
    ext_ip = cfg["ext_ip"]
    int_ip = cfg["int_ip"]

    lines = [
        "port=53",
        f"listen-address=127.0.0.1,{int_ip}",
        "server=8.8.8.8",
        "server=1.1.1.1",
        "cache-size=4096"
    ]
    if cfg.get("block_ipv6", True):
        lines.append("filter-AAAA")
    if cfg.get("log_queries", True):
        lines.append("log-queries")

    if cfg.get("wildcard_mode", False):
        lines.append(f"address=/#/{ext_ip}")
    else:
        for d in sorted(set(cfg.get("domains", []))):
            d = d.strip().lstrip("*.")
            if d:
                lines.append(f"address=/{d}/{ext_ip}")

    with open("/etc/dnsmasq.conf", "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")

    subprocess.run(["systemctl", "restart", "dnsmasq"], check=False)

    if shutil.which("ufw"):
        subprocess.run(["ufw", "disable"], check=False)

    subprocess.run(["iptables", "-t", "raw", "-F"], check=False)
    subprocess.run(["iptables", "-t", "raw", "-A", "PREROUTING", "-p", "udp", "--dport", "53", "-j", "NOTRACK"], check=False)

    subprocess.run(["iptables", "-D", "INPUT", "-j", "SMARTDNS_ACL"], check=False)
    subprocess.run(["iptables", "-F", "SMARTDNS_ACL"], check=False)
    subprocess.run(["iptables", "-X", "SMARTDNS_ACL"], check=False)
    subprocess.run(["iptables", "-N", "SMARTDNS_ACL"], check=False)
    subprocess.run(["iptables", "-I", "INPUT", "1", "-j", "SMARTDNS_ACL"], check=False)

    subprocess.run(["iptables", "-A", "SMARTDNS_ACL", "-i", "lo", "-j", "ACCEPT"], check=False)
    subprocess.run(["iptables", "-A", "SMARTDNS_ACL", "-m", "conntrack", "--ctstate", "ESTABLISHED,RELATED", "-j", "ACCEPT"], check=False)
    subprocess.run(["iptables", "-A", "SMARTDNS_ACL", "-p", "tcp", "--dport", "22", "-j", "ACCEPT"], check=False)
    subprocess.run(["iptables", "-A", "SMARTDNS_ACL", "-p", "tcp", "--dport", "8080", "-j", "ACCEPT"], check=False)

    clean_ips = extract_ips(cfg.get("allowed_ips", []))
    for ip in clean_ips:
        subprocess.run(["iptables", "-A", "SMARTDNS_ACL", "-s", ip, "-j", "ACCEPT"], check=False)

    subprocess.run(["iptables", "-A", "SMARTDNS_ACL", "-p", "udp", "--dport", "53", "-j", "DROP"], check=False)
    subprocess.run(["iptables", "-A", "SMARTDNS_ACL", "-p", "tcp", "-m", "multiport", "--dports", "53,80,443", "-j", "DROP"], check=False)

    subprocess.run(["iptables", "-t", "nat", "-F"], check=False)
    for rule in cfg.get("udp_rules", []):
        port = str(rule.get("port", "")).strip()
        target = str(rule.get("target", "")).strip()
        if port and target:
            real_ip = resolve_real_ip(target)
            for ip in clean_ips:
                subprocess.run([
                    "iptables", "-t", "nat", "-A", "PREROUTING",
                    "-s", ip, "-p", "udp", "--dport", port,
                    "-j", "DNAT", "--to-destination", f"{real_ip}:{port.replace(':', '-')}"
                ], check=False)
            subprocess.run(["iptables", "-t", "nat", "-A", "POSTROUTING", "-p", "udp", "-d", real_ip, "-j", "MASQUERADE"], check=False)

def _bg_apply():
    with LOCK:
        apply_system_changes()

def apply_async():
    threading.Thread(target=_bg_apply, daemon=True).start()

def login_required(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        if not session.get("logged_in"):
            return redirect(url_for("login"))
        return f(*args, **kwargs)
    return decorated

HTML_TEMPLATE = """
<!DOCTYPE html>
<html lang="ru" data-bs-theme="dark">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>SmartDNS & UDP Control Panel</title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.2/dist/css/bootstrap.min.css" rel="stylesheet">
</head>
<body class="bg-dark text-light">
<nav class="navbar navbar-expand-lg navbar-dark bg-black border-bottom border-secondary mb-4">
  <div class="container">
    <span class="navbar-brand fw-bold text-info">⚡ SmartDNS & UDP Hub ({{ cfg.ext_ip }})</span>
    <div class="d-flex align-items-center gap-2 flex-wrap">
      <form method="post" action="{{ url_for('restart_service', svc='dnsmasq') }}" class="m-0 d-inline">
        <button type="submit" class="btn btn-sm {{ 'btn-success' if dns_ok else 'btn-danger' }}" title="Нажмите для перезапуска Dnsmasq">
          Dnsmasq: {{ 'Активен' if dns_ok else 'Ошибка' }} ↻
        </button>
      </form>
      <form method="post" action="{{ url_for('restart_service', svc='sniproxy') }}" class="m-0 d-inline">
        <button type="submit" class="btn btn-sm {{ 'btn-success' if sni_ok else 'btn-danger' }}" title="Нажмите для перезапуска SNIProxy">
          SNIProxy: {{ 'Активен' if sni_ok else 'Ошибка' }} ↻
        </button>
      </form>
      <a href="{{ url_for('logout') }}" class="btn btn-sm btn-outline-secondary ms-2">Выйти</a>
    </div>
  </div>
</nav>

<div class="container pb-5">
  {% with messages = get_flashed_messages() %}
    {% if messages %}
      {% for m in messages %}
        <div class="alert alert-info py-2 fw-semibold">{{ m }}</div>
      {% endfor %}
    {% endif %}
  {% endwith %}

  <div class="row g-4">
    <!-- Левая колонка -->
    <div class="col-md-5">
      <div class="card bg-black border-secondary mb-4">
        <div class="card-header border-secondary d-flex justify-content-between align-items-center">
          <h6 class="mb-0">Белый список IP ({{ cfg.allowed_ips|length }})</h6>
          <form method="post" action="{{ url_for('add_my_ip') }}" class="m-0">
            <button class="btn btn-sm btn-info fw-bold">+ Мой IP ({{ client_ip }})</button>
          </form>
        </div>
        <div class="card-body">
          <form method="post" action="{{ url_for('update_ips') }}">
            <textarea name="ips" class="form-control font-monospace mb-2" rows="4" placeholder="85.249.19.97 # Дом">{{ '\\n'.join(cfg.allowed_ips) }}</textarea>
            <button class="btn btn-primary btn-sm w-100">Сохранить список IP</button>
          </form>
        </div>
      </div>

      <div class="card bg-black border-secondary mb-4">
        <div class="card-header border-secondary d-flex justify-content-between align-items-center">
          <h6 class="mb-0">Персональные DDNS-токены ({{ cfg.ddns_tokens|length }})</h6>
        </div>
        <div class="card-body">
          <form method="post" action="{{ url_for('add_token') }}" class="row g-2 mb-3">
            <div class="col-8">
              <input type="text" name="token_name" class="form-control form-control-sm" placeholder="Имя (напр. Роутер, Иван, Xbox)" required>
            </div>
            <div class="col-4">
              <button class="btn btn-sm btn-success w-100">+ Токен</button>
            </div>
          </form>

          {% if cfg.ddns_tokens %}
            <ul class="list-group list-group-flush mb-2">
              {% for tok, name in cfg.ddns_tokens.items() %}
                {% set full_url = 'http://' + cfg.ext_ip + ':8080/ddns/' + tok %}
                <li class="list-group-item bg-dark border-secondary py-2 px-2">
                  <div class="d-flex justify-content-between align-items-center mb-1">
                    <span class="fw-bold text-info small">{{ name }}</span>
                    <div class="d-flex gap-1">
                      <button type="button" class="btn btn-sm btn-outline-info py-0 px-2" onclick="copyText('{{ full_url }}', this)">Копировать ссылку</button>
                      <a href="{{ url_for('del_token', token=tok) }}" class="btn btn-sm btn-outline-danger py-0 px-1" title="Удалить токен и отключить его IP">✕</a>
                    </div>
                  </div>
                  <div class="text-secondary font-monospace text-truncate" style="font-size: 0.72rem;">{{ full_url }}</div>
                </li>
              {% endfor %}
            </ul>
          {% else %}
            <small class="text-secondary d-block mb-2">Нет активных токенов. Создайте первый выше.</small>
          {% endif %}
          <small class="text-secondary d-block">
            При переходе по ссылке с устройства сервер сам добавит или обновит его IP под указанным именем. Удаление токена отзывает доступ.
          </small>
        </div>
      </div>

      <div class="card bg-black border-secondary mb-4">
        <div class="card-header border-secondary"><h6 class="mb-0">Режим работы DNS</h6></div>
        <div class="card-body">
          <form method="post" action="{{ url_for('update_settings') }}">
            <div class="form-check form-switch mb-2">
              <input class="form-check-input" type="checkbox" name="wildcard_mode" id="wc" {% if cfg.wildcard_mode %}checked{% endif %}>
              <label class="form-check-label text-warning fw-bold" for="wc">Проксировать ВЕСЬ веб-трафик (Wildcard /#/)</label>
            </div>
            <div class="form-check form-switch mb-2">
              <input class="form-check-input" type="checkbox" name="block_ipv6" id="v6" {% if cfg.block_ipv6 %}checked{% endif %}>
              <label class="form-check-label" for="v6">Отключить IPv6 (filter-AAAA)</label>
            </div>
            <div class="form-check form-switch mb-3">
              <input class="form-check-input" type="checkbox" name="log_queries" id="lq" {% if cfg.log_queries %}checked{% endif %}>
              <label class="form-check-label" for="lq">Вести живой лог DNS-запросов</label>
            </div>
            <button class="btn btn-primary btn-sm w-100">Применить параметры</button>
          </form>
        </div>
      </div>

      <div class="card bg-black border-secondary mb-4">
        <div class="card-header border-secondary"><h6 class="mb-0">UDP NAT-Проброс (Для игр и голосовых чатов)</h6></div>
        <div class="card-body">
          <form method="post" action="{{ url_for('add_udp') }}" class="row g-2 mb-3">
            <div class="col-4">
              <input type="text" name="port" class="form-control form-control-sm" placeholder="Порт (3074)" required>
            </div>
            <div class="col-5">
              <input type="text" name="target" class="form-control form-control-sm" placeholder="IP или домен" required>
            </div>
            <div class="col-3">
              <button class="btn btn-sm btn-success w-100">Добавить</button>
            </div>
          </form>
          {% if cfg.udp_rules %}
            <ul class="list-group list-group-flush">
              {% for r in cfg.udp_rules %}
                <li class="list-group-item bg-dark d-flex justify-content-between align-items-center py-1 px-2 border-secondary">
                  <small class="font-monospace">UDP {{ r.port }} ➔ {{ r.target }}</small>
                  <a href="{{ url_for('del_udp', idx=loop.index0) }}" class="btn btn-sm btn-outline-danger py-0 px-1">✕</a>
                </li>
              {% endfor %}
            </ul>
          {% else %}
            <small class="text-secondary">Нет активных правил UDP. Стандартный мультиплеер Xbox работает напрямую.</small>
          {% endif %}
        </div>
      </div>

      <div class="card bg-black border-secondary">
        <div class="card-header border-secondary"><h6 class="mb-0">Резервная копия и безопасность</h6></div>
        <div class="card-body">
          <div class="d-flex gap-2 mb-3">
            <a href="{{ url_for('export_config') }}" class="btn btn-sm btn-outline-info w-50">⬇ Скачать бэкап</a>
            <form method="post" action="{{ url_for('import_config') }}" enctype="multipart/form-data" class="w-50 m-0">
              <label class="btn btn-sm btn-outline-warning w-100 mb-0">
                ⬆ Загрузить JSON <input type="file" name="backup_file" accept=".json" hidden onchange="this.form.submit()">
              </label>
            </form>
          </div>
          <form method="post" action="{{ url_for('change_password') }}" class="row g-2">
            <div class="col-8">
              <input type="password" name="new_password" class="form-control form-control-sm" placeholder="Новый пароль панели" required>
            </div>
            <div class="col-4">
              <button class="btn btn-sm btn-outline-light w-100">Сменить</button>
            </div>
          </form>
        </div>
      </div>
    </div>

    <!-- Правая колонка -->
    <div class="col-md-7">
      <div class="card bg-black border-secondary mb-4">
        <div class="card-header border-secondary">
          <div class="d-flex justify-content-between align-items-center mb-2">
            <h6 class="mb-0">Перенаправляемые домены ({{ cfg.domains|length }})</h6>
            <small class="text-secondary">Добавить пресет:</small>
          </div>
          <div class="d-flex flex-wrap gap-1">
            <a href="{{ url_for('add_preset', name='xbox') }}" class="btn btn-sm btn-outline-success py-0">+ Xbox & Rewards</a>
            <a href="{{ url_for('add_preset', name='gemini') }}" class="btn btn-sm btn-outline-primary py-0">+ Gemini</a>
            <a href="{{ url_for('add_preset', name='openai') }}" class="btn btn-sm btn-outline-info py-0">+ ChatGPT</a>
            <a href="{{ url_for('add_preset', name='claude') }}" class="btn btn-sm btn-outline-warning py-0">+ Claude</a>
            <a href="{{ url_for('add_preset', name='meta_x') }}" class="btn btn-sm btn-outline-danger py-0">+ Instagram / X</a>
            <a href="{{ url_for('add_preset', name='discord') }}" class="btn btn-sm btn-outline-light py-0">+ Discord</a>
            <a href="{{ url_for('add_preset', name='spotify') }}" class="btn btn-sm btn-outline-success py-0">+ Spotify</a>
            <a href="{{ url_for('add_preset', name='work') }}" class="btn btn-sm btn-outline-secondary py-0">+ Canva & Notion</a>
          </div>
        </div>
        <div class="card-body">
          <form method="post" action="{{ url_for('update_domains') }}">
            <textarea name="domains" class="form-control font-monospace mb-2" rows="13" {% if cfg.wildcard_mode %}disabled{% endif %}>{{ '\\n'.join(cfg.domains) }}</textarea>
            {% if cfg.wildcard_mode %}
              <div class="text-warning small mb-2">Включен режим «Весь трафик». Список доменов временно игнорируется.</div>
            {% endif %}
            <button class="btn btn-primary btn-sm w-100" {% if cfg.wildcard_mode %}disabled{% endif %}>Сохранить домены и перезапустить DNS</button>
          </form>

          <hr class="border-secondary my-3">
          <form method="post" action="{{ url_for('test_domain') }}" class="row g-2">
            <div class="col-9">
              <input type="text" name="test_domain" class="form-control form-control-sm font-monospace" placeholder="Проверка домена (например: gemini.google.com)" required>
            </div>
            <div class="col-3">
              <button class="btn btn-sm btn-outline-info w-100">Проверить</button>
            </div>
          </form>
        </div>
      </div>

      <div class="card bg-black border-secondary">
        <div class="card-header border-secondary d-flex justify-content-between align-items-center gap-2">
          <h6 class="mb-0">DNS-запросы (Live Log)</h6>
          <div class="d-flex gap-2">
            <input type="text" id="logFilter" class="form-control form-control-sm" style="width: 170px;" placeholder="Фильтр (напр. gemini)" onkeyup="filterLogs()">
            <a href="{{ url_for('index') }}" class="btn btn-sm btn-outline-light">Обновить</a>
          </div>
        </div>
        <div class="card-body p-2">
          <pre id="logBox" class="bg-dark text-success p-2 mb-0 font-monospace small" style="max-height: 290px; overflow-y: auto;">{{ logs }}</pre>
        </div>
      </div>
    </div>
  </div>
</div>

<script>
const rawLogs = document.getElementById('logBox').innerText;
function filterLogs() {
  const q = document.getElementById('logFilter').value.toLowerCase();
  if (!q) {
    document.getElementById('logBox').innerText = rawLogs;
    return;
  }
  const filtered = rawLogs.split('\\n').filter(line => line.toLowerCase().includes(q)).join('\\n');
  document.getElementById('logBox').innerText = filtered || 'Совпадений не найдено.';
}
function copyText(text, btn) {
  const done = () => {
    const old = btn.innerText;
    btn.innerText = 'Скопировано!';
    setTimeout(() => btn.innerText = old, 1500);
  };
  if (navigator.clipboard && window.isSecureContext) {
    navigator.clipboard.writeText(text).then(done);
  } else {
    const ta = document.createElement('textarea');
    ta.value = text;
    document.body.appendChild(ta);
    ta.select();
    document.execCommand('copy');
    document.body.removeChild(ta);
    done();
  }
}
</script>
</body>
</html>
"""

LOGIN_HTML = """
<!DOCTYPE html>
<html lang="ru" data-bs-theme="dark">
<head>
    <meta charset="UTF-8">
    <title>Вход — SmartDNS</title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.2/dist/css/bootstrap.min.css" rel="stylesheet">
</head>
<body class="bg-dark d-flex align-items-center justify-content-center" style="height: 100vh;">
  <form method="post" class="card bg-black border-secondary p-4" style="width: 340px;">
    <h5 class="mb-3 text-info text-center">⚡ SmartDNS Панель</h5>
    <input type="password" name="password" class="form-control mb-3" placeholder="Пароль администратора" required autofocus>
    <button class="btn btn-info w-100 fw-bold">Войти</button>
  </form>
</body>
</html>
"""

@app.route("/login", methods=["GET", "POST"])
def login():
    if request.method == "POST":
        cfg = load_config()
        if request.form.get("password") == cfg.get("password"):
            session["logged_in"] = True
            return redirect(url_for("index"))
    return render_template_string(LOGIN_HTML)

@app.route("/logout")
def logout():
    session.clear()
    return redirect(url_for("login"))

@app.route("/ddns/<token>", methods=["GET", "POST"])
def ddns_webhook(token):
    cfg = load_config()
    tokens = cfg.get("ddns_tokens", {})
    if token not in tokens:
        return "Forbidden: invalid or revoked token\n", 403

    ip = request.args.get("ip", "").strip() or request.remote_addr
    tag = tokens[token]
    marker = f"# {tag}"

    updated = False
    found = False
    new_list = []

    for entry in cfg.get("allowed_ips", []):
        if entry.strip().endswith(marker):
            found = True
            old_ip = entry.split("#")[0].strip()
            if old_ip == ip:
                return f"UNCHANGED: {ip} ({tag})\n", 200
            new_list.append(f"{ip} {marker}")
            updated = True
        else:
            new_list.append(entry)

    if not found:
        new_list.append(f"{ip} {marker}")
        updated = True

    if updated:
        cfg["allowed_ips"] = new_list
        save_config(cfg)
        apply_async()
        return f"OK: {ip} ({tag})\n", 200

    return f"UNCHANGED: {ip} ({tag})\n", 200

@app.route("/")
@login_required
def index():
    cfg = load_config()
    client_ip = request.remote_addr
    dns_ok = subprocess.run(["systemctl", "is-active", "--quiet", "dnsmasq"]).returncode == 0
    sni_ok = subprocess.run(["systemctl", "is-active", "--quiet", "sniproxy"]).returncode == 0
    try:
        logs = subprocess.check_output(["journalctl", "-u", "dnsmasq", "-n", "60", "--no-pager"], text=True)
    except Exception:
        logs = "Логи недоступны."
    return render_template_string(
        HTML_TEMPLATE, cfg=cfg, client_ip=client_ip,
        dns_ok=dns_ok, sni_ok=sni_ok, logs=logs
    )

@app.route("/add_token", methods=["POST"])
@login_required
def add_token():
    cfg = load_config()
    name = request.form.get("token_name", "").strip().replace("#", "")[:24] or "Device"
    tok = secrets.token_hex(12)
    cfg.setdefault("ddns_tokens", {})[tok] = name
    save_config(cfg)
    flash(f"Персональный токен для «{name}» создан.")
    return redirect(url_for("index"))

@app.route("/del_token/<token>")
@login_required
def del_token(token):
    cfg = load_config()
    tokens = cfg.get("ddns_tokens", {})
    if token in tokens:
        name = tokens.pop(token)
        marker = f"# {name}"
        cfg["allowed_ips"] = [x for x in cfg.get("allowed_ips", []) if not x.strip().endswith(marker)]
        save_config(cfg)
        apply_async()
        flash(f"Токен «{name}» удален, связанный IP исключен из белого списка.")
    return redirect(url_for("index"))

@app.route("/restart_service/<svc>", methods=["POST"])
@login_required
def restart_service(svc):
    if svc in ("dnsmasq", "sniproxy"):
        subprocess.run(["systemctl", "restart", svc], check=False)
        flash(f"Служба {svc} перезапущена.")
    return redirect(url_for("index"))

@app.route("/test_domain", methods=["POST"])
@login_required
def test_domain():
    cfg = load_config()
    raw = request.form.get("test_domain", "").strip().lower()
    domain = raw.replace("https://", "").replace("http://", "").split("/")[0].strip()
    if not domain:
        return redirect(url_for("index"))
    try:
        dns_res = subprocess.check_output(["dig", "+short", "@127.0.0.1", domain], text=True, timeout=3).strip().splitlines()
        resolved = dns_res[0] if dns_res else "нет ответа"
    except Exception as e:
        resolved = f"ошибка DNS ({e})"
    is_proxied = (resolved == cfg["ext_ip"])
    try:
        curl_out = subprocess.check_output(
            ["curl", "-sI", "-m", "4", "--resolve", f"{domain}:443:127.0.0.1", f"https://{domain}"],
            text=True, stderr=subprocess.STDOUT
        ).splitlines()
        http_status = curl_out[0] if curl_out else "пустой ответ"
    except subprocess.CalledProcessError as e:
        http_status = f"код ошибки {e.returncode}"
    except Exception as e:
        http_status = str(e)
    mode_txt = "ЧЕРЕЗ ПРОКСИ (Финляндия)" if is_proxied else "НАПРЯМУЮ (мимо прокси)"
    flash(f"Тест {domain}: DNS ➔ {resolved} [{mode_txt}] | HTTPS через SNIProxy ➔ {http_status}")
    return redirect(url_for("index"))

@app.route("/add_my_ip", methods=["POST"])
@login_required
def add_my_ip():
    cfg = load_config()
    ip = request.remote_addr
    if ip not in extract_ips(cfg["allowed_ips"]):
        cfg["allowed_ips"].append(f"{ip} # Браузер")
        save_config(cfg)
        apply_async()
        flash(f"Ваш IP {ip} добавлен в белый список!")
    return redirect(url_for("index"))

@app.route("/update_ips", methods=["POST"])
@login_required
def update_ips():
    cfg = load_config()
    raw = request.form.get("ips", "").splitlines()
    cfg["allowed_ips"] = [x.strip() for x in raw if x.strip()]
    save_config(cfg)
    apply_async()
    flash("Белый список IP обновлен.")
    return redirect(url_for("index"))

@app.route("/update_settings", methods=["POST"])
@login_required
def update_settings():
    cfg = load_config()
    cfg["wildcard_mode"] = "wildcard_mode" in request.form
    cfg["block_ipv6"] = "block_ipv6" in request.form
    cfg["log_queries"] = "log_queries" in request.form
    save_config(cfg)
    apply_async()
    flash("Настройки режима работы применены.")
    return redirect(url_for("index"))

@app.route("/update_domains", methods=["POST"])
@login_required
def update_domains():
    cfg = load_config()
    raw = request.form.get("domains", "").splitlines()
    clean = []
    for line in raw:
        d = line.strip().replace("address=/", "").split("/")[0].strip()
        if d and not d.startswith("#"):
            clean.append(d)
    cfg["domains"] = sorted(list(set(clean)))
    save_config(cfg)
    apply_async()
    flash("Список доменов сохранен и применяется в фоне.")
    return redirect(url_for("index"))

@app.route("/add_preset/<name>")
@login_required
def add_preset(name):
    cfg = load_config()
    if name in PRESETS:
        merged = set(cfg.get("domains", [])) | set(PRESETS[name])
        cfg["domains"] = sorted(list(merged))
        save_config(cfg)
        apply_async()
        flash(f"Пресет «{name}» добавлен.")
    return redirect(url_for("index"))

@app.route("/add_udp", methods=["POST"])
@login_required
def add_udp():
    cfg = load_config()
    port = request.form.get("port", "").strip()
    target = request.form.get("target", "").strip()
    if port and target:
        cfg["udp_rules"].append({"port": port, "target": target})
        save_config(cfg)
        apply_async()
        flash(f"UDP проброс порта {port} добавлен.")
    return redirect(url_for("index"))

@app.route("/del_udp/<int:idx>")
@login_required
def del_udp(idx):
    cfg = load_config()
    if 0 <= idx < len(cfg["udp_rules"]):
        cfg["udp_rules"].pop(idx)
        save_config(cfg)
        apply_async()
        flash("Правило UDP удалено.")
    return redirect(url_for("index"))

@app.route("/export_config")
@login_required
def export_config():
    cfg = load_config()
    return Response(
        json.dumps(cfg, indent=2, ensure_ascii=False),
        mimetype="application/json",
        headers={"Content-Disposition": "attachment;filename=smartdns_backup.json"}
    )

@app.route("/import_config", methods=["POST"])
@login_required
def import_config():
    file = request.files.get("backup_file")
    if file:
        try:
            data = json.loads(file.read().decode("utf-8"))
            cfg = load_config()
            for key in ("allowed_ips", "ddns_tokens", "domains", "udp_rules", "wildcard_mode", "block_ipv6", "log_queries"):
                if key in data:
                    cfg[key] = data[key]
            save_config(cfg)
            apply_async()
            flash("Конфигурация восстановлена из бэкапа!")
        except Exception as e:
            flash(f"Ошибка файла бэкапа: {e}")
    return redirect(url_for("index"))

@app.route("/change_password", methods=["POST"])
@login_required
def change_password():
    new_pass = request.form.get("new_password", "").strip()
    if new_pass:
        cfg = load_config()
        cfg["password"] = new_pass
        save_config(cfg)
        flash("Пароль администратора успешно изменен.")
    return redirect(url_for("index"))

if __name__ == "__main__":
    apply_system_changes()
    app.run(host="0.0.0.0", port=8080)
EOF

echo "[7/7] Создание системной службы автозапуска..."
cat << 'EOF' > /etc/systemd/system/smartdns-panel.service
[Unit]
Description=SmartDNS & UDP Web Control Panel
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/smartdns
ExecStart=/usr/bin/python3 /opt/smartdns/app.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable smartdns-panel
systemctl restart smartdns-panel

echo "===================================================="
echo " УСТАНОВКА ЗАВЕРШЕНА УСПЕШНО!"
echo " Панель управления: http://${EXT_IP}:${PANEL_PORT}"
echo " Установленный пароль: ${ADMIN_PASS}"
echo "===================================================="