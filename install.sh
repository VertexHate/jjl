#!/bin/bash

# ─────────────────────────────────────────────
#  RemnaWave XHTTP CDN — автоустановщик
# ─────────────────────────────────────────────

set -e

EMAIL="linkhate@icloud.com"
INBOUND_PORT="10085"

# ── Цвета ──
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}"
echo "╔══════════════════════════════════════════╗"
echo "║    RemnaWave XHTTP CDN — Установка       ║"
echo "╚══════════════════════════════════════════╝"
echo -e "${NC}"

# ── Шаг 1: ввод домена ──
echo -e "${YELLOW}Введите ваш домен (например: origin.example.com):${NC}"
read -r ORIGIN_DOMAIN

if [[ -z "$ORIGIN_DOMAIN" ]]; then
    echo -e "${RED}Ошибка: домен не может быть пустым.${NC}"
    exit 1
fi

echo ""
echo -e "${CYAN}▶ Домен:        ${NC}$ORIGIN_DOMAIN"
echo -e "${CYAN}▶ Почта:        ${NC}$EMAIL"
echo -e "${CYAN}▶ Порт inbound: ${NC}$INBOUND_PORT"
echo ""
echo -e "${YELLOW}Начинаем установку... (требуются права root)${NC}"
echo ""

# ── Проверка root ──
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Запустите скрипт от root: sudo bash install.sh${NC}"
    exit 1
fi

# ── Шаг 2: обновление и установка пакетов ──
echo -e "${GREEN}[1/5] Обновление пакетов и установка nginx, certbot...${NC}"
apt update -y
apt install -y nginx certbot

# ── Шаг 3: выпуск сертификата ──
echo -e "${GREEN}[2/5] Выпуск SSL-сертификата для $ORIGIN_DOMAIN...${NC}"
systemctl stop nginx
certbot certonly --standalone \
    -d "$ORIGIN_DOMAIN" \
    --non-interactive \
    --agree-tos \
    -m "$EMAIL"
systemctl start nginx

# ── Шаг 4: создание nginx конфига ──
echo -e "${GREEN}[3/5] Создание конфига nginx...${NC}"
cat > /etc/nginx/conf.d/remnawave-xhttp-cdn.conf <<EOF
server {
    listen 443 ssl http2;
    server_name $ORIGIN_DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$ORIGIN_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$ORIGIN_DOMAIN/privkey.pem;

    client_max_body_size 0;

    location / {
        proxy_pass http://127.0.0.1:$INBOUND_PORT;

        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;

        proxy_buffering off;
        proxy_request_buffering off;
        proxy_cache off;

        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        send_timeout 3600s;

        add_header Cache-Control "no-store" always;
        add_header Pragma "no-cache" always;
        add_header Expires "0" always;
        add_header X-Accel-Expires "0" always;
    }
}
EOF

# ── Шаг 5: проверка и перезапуск nginx ──
echo -e "${GREEN}[4/5] Проверка конфига и перезапуск nginx...${NC}"
nginx -t
systemctl restart nginx

# ── Шаг 6: перезапуск ноды ──
echo -e "${GREEN}[5/5] Перезапуск remnanode...${NC}"
docker restart remnanode

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════╗"
echo -e "║         ✅  Установка завершена!         ║"
echo -e "╚══════════════════════════════════════════╝${NC}"
echo ""
echo -e "${CYAN}Домен:   ${NC}https://$ORIGIN_DOMAIN"
echo -e "${CYAN}Порт:    ${NC}$INBOUND_PORT"
echo -e "${CYAN}Почта:   ${NC}$EMAIL"
echo ""
