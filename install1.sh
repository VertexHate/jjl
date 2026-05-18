#!/bin/bash

# ─────────────────────────────────────────────
#  RemnaWave XHTTP CDN — автоустановщик
#  с поддержкой HTTP/3 (QUIC)
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
echo "║         с поддержкой HTTP/3              ║"
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

# ── Определение дистрибутива ──
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    DISTRO_ID="${ID,,}"
    DISTRO_CODENAME="${VERSION_CODENAME:-}"
else
    echo -e "${RED}Не удалось определить дистрибутив.${NC}"
    exit 1
fi

# ── Шаг 2: установка Nginx mainline с HTTP/3 ──
echo -e "${GREEN}[1/6] Установка Nginx mainline с поддержкой HTTP/3...${NC}"

apt update -y
apt install -y curl gnupg2 ca-certificates lsb-release debian-archive-keyring

# Добавляем ключ и репозиторий mainline nginx
curl -fsSL https://nginx.org/keys/nginx_signing.key \
    | gpg --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg

if [[ "$DISTRO_ID" == "ubuntu" ]]; then
    REPO_URL="https://nginx.org/packages/mainline/ubuntu"
elif [[ "$DISTRO_ID" == "debian" ]]; then
    REPO_URL="https://nginx.org/packages/mainline/debian"
else
    echo -e "${RED}Поддерживаются только Ubuntu и Debian.${NC}"
    exit 1
fi

echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] \
${REPO_URL} ${DISTRO_CODENAME} nginx" \
    > /etc/apt/sources.list.d/nginx.list

# Приоритет mainline-репозитория над системным
echo -e "Package: *\nPin: origin nginx.org\nPin-Priority: 900" \
    > /etc/apt/preferences.d/99nginx

apt update -y
apt install -y nginx

# Проверяем, собран ли nginx с поддержкой http_v3
NGINX_V=$(nginx -V 2>&1)
echo ""
echo -e "${CYAN}Версия Nginx:${NC} $(nginx -v 2>&1)"

if echo "$NGINX_V" | grep -q "http_v3"; then
    echo -e "${GREEN}✔ HTTP/3 (QUIC) поддерживается в этой сборке.${NC}"
else
    echo -e "${YELLOW}⚠ Текущая сборка Nginx из mainline репозитория не включает HTTP/3.${NC}"
    echo -e "${YELLOW}  Пробуем установить из официального mainline-пакета с QUIC...${NC}"

    # Для некоторых дистрибутивов доступен отдельный пакет с quic
    apt install -y nginx-extras 2>/dev/null || true

    NGINX_V2=$(nginx -V 2>&1)
    if echo "$NGINX_V2" | grep -q "http_v3"; then
        echo -e "${GREEN}✔ HTTP/3 успешно включён.${NC}"
    else
        echo -e "${YELLOW}⚠ Конфиг будет создан с HTTP/3-директивами — они активируются${NC}"
        echo -e "${YELLOW}  когда nginx будет собран с флагом --with-http_v3_module.${NC}"
        echo -e "${YELLOW}  Сервис запустится в режиме HTTP/1.1 + HTTP/2.${NC}"
        HTTP3_AVAILABLE=false
    fi
fi

# ── Шаг 3: установка certbot ──
echo -e "${GREEN}[2/6] Установка certbot...${NC}"
apt install -y certbot

# ── Шаг 4: выпуск сертификата ──
echo -e "${GREEN}[3/6] Выпуск SSL-сертификата для $ORIGIN_DOMAIN...${NC}"
systemctl stop nginx
certbot certonly --standalone \
    -d "$ORIGIN_DOMAIN" \
    --non-interactive \
    --agree-tos \
    -m "$EMAIL"
systemctl start nginx

# ── Шаг 5: создание nginx конфига с HTTP/3 ──
echo -e "${GREEN}[4/6] Создание конфига nginx с HTTP/3...${NC}"

# Если HTTP/3 недоступен — добавляем закомментированные директивы
if [[ "${HTTP3_AVAILABLE}" == "false" ]]; then
    HTTP3_LISTEN="# listen 443 quic reuseport;  # раскомментировать после включения http_v3"
    HTTP3_DIRECTIVES="# http3 on;  # раскомментировать после включения http_v3"
    ALT_SVC_HEADER="# add_header Alt-Svc 'h3=\":443\"; ma=86400';  # раскомментировать после включения http_v3"
else
    HTTP3_LISTEN="listen 443 quic reuseport;"
    HTTP3_DIRECTIVES="http3 on;"
    ALT_SVC_HEADER="add_header Alt-Svc 'h3=\":443\"; ma=86400' always;"
fi

cat > /etc/nginx/conf.d/remnawave-xhttp-cdn.conf <<EOF
server {
    # HTTP → HTTPS редирект
    listen 80;
    server_name $ORIGIN_DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    # HTTP/1.1 + HTTP/2 (TCP)
    listen 443 ssl;
    listen [::]:443 ssl;

    # HTTP/3 (QUIC / UDP)
    ${HTTP3_LISTEN}
    listen [::]:443 quic reuseport;

    server_name $ORIGIN_DOMAIN;

    # ── SSL ──
    ssl_certificate     /etc/letsencrypt/live/$ORIGIN_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$ORIGIN_DOMAIN/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:'
                'ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:'
                'ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305';
    ssl_prefer_server_ciphers off;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:10m;
    ssl_session_tickets off;

    # ── HTTP/2 и HTTP/3 ──
    http2 on;
    ${HTTP3_DIRECTIVES}

    # Сообщаем браузеру о поддержке HTTP/3
    ${ALT_SVC_HEADER}

    # ── Общие заголовки ──
    add_header Strict-Transport-Security "max-age=63072000" always;
    add_header X-Content-Type-Options "nosniff" always;

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

# ── Шаг 6: открываем UDP 443 для QUIC ──
echo -e "${GREEN}[5/6] Открытие UDP-порта 443 для HTTP/3 (QUIC)...${NC}"

if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
    ufw allow 443/udp
    echo -e "${GREEN}  ✔ UFW: UDP 443 открыт.${NC}"
elif command -v firewall-cmd &>/dev/null; then
    firewall-cmd --permanent --add-port=443/udp
    firewall-cmd --reload
    echo -e "${GREEN}  ✔ firewalld: UDP 443 открыт.${NC}"
elif command -v iptables &>/dev/null; then
    iptables -C INPUT -p udp --dport 443 -j ACCEPT 2>/dev/null \
        || iptables -A INPUT -p udp --dport 443 -j ACCEPT
    echo -e "${GREEN}  ✔ iptables: UDP 443 открыт.${NC}"
else
    echo -e "${YELLOW}  ⚠ Фаервол не обнаружен. Убедитесь, что UDP 443 открыт вручную.${NC}"
fi

# ── Проверка и перезапуск nginx ──
echo -e "${GREEN}[6/6] Проверка конфига и перезапуск nginx...${NC}"
nginx -t
systemctl restart nginx

# ── Перезапуск ноды ──
echo -e "${GREEN}[+] Перезапуск remnanode...${NC}"
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
echo -e "${CYAN}Протоколы:${NC}"
echo -e "  ${GREEN}✔${NC} HTTP/1.1 (TCP 443)"
echo -e "  ${GREEN}✔${NC} HTTP/2   (TCP 443)"

if [[ "${HTTP3_AVAILABLE}" != "false" ]]; then
    echo -e "  ${GREEN}✔${NC} HTTP/3   (UDP 443) — активен"
else
    echo -e "  ${YELLOW}⚠${NC} HTTP/3   (UDP 443) — требует пересборки nginx с --with-http_v3_module"
fi

echo ""
echo -e "${YELLOW}Проверка HTTP/3: https://http3check.net/?host=$ORIGIN_DOMAIN${NC}"
echo ""
