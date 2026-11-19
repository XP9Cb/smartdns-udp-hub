#!/bin/bash
set -e

REPO_RAW="https://raw.githubusercontent.com/XP9Cb/smartdns-udp-hub/main"
CFG_FILE="/opt/smartdns/config.json"
BAK_FILE="/tmp/smartdns_config_backup.json"

echo "===================================================="
echo " Обновление SmartDNS & UDP Hub до последней версии"
echo "===================================================="

if [ ! -f "$CFG_FILE" ]; then
    echo "Ошибка: панель ещё не установлена ($CFG_FILE не найден)."
    echo "Для первой установки используйте install_panel.sh"
    exit 1
fi

echo "[1/3] Сохранение резервной копии настроек и пароля..."
cp "$CFG_FILE" "$BAK_FILE"

echo "[2/3] Скачивание и установка свежей версии с GitHub..."
curl -fsSL "${REPO_RAW}/install_panel.sh" | tr -d '\r' > /tmp/install_panel.sh
sed -i '/read -r -p/d' /tmp/install_panel.sh
bash /tmp/install_panel.sh
rm -f /tmp/install_panel.sh

echo "[3/3] Восстановление настроек и перезапуск службы..."
cp "$BAK_FILE" "$CFG_FILE"
rm -f "$BAK_FILE"
systemctl restart smartdns-panel

EXT_IP=$(python3 -c 'import json; print(json.load(open("/opt/smartdns/config.json")).get("ext_ip", ""))')
echo "===================================================="
echo " ОБНОВЛЕНИЕ ЗАВЕРШЕНО! Настройки и пароль сохранены."
echo " Панель управления: http://${EXT_IP}:8080"
echo "===================================================="
