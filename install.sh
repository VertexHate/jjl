#!/bin/bash

# ─────────────────────────────────────────────
#  RemnaWave XHTTP CDN — автоустановщик
#  HTTP/3 (QUIC) | идемпотентный
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

# ════════════════════════════════════════════════
# [0/6] Удаление таймера авторестарта nginx
# ════════════════════════════════════════════════
echo -e "${GREEN}[0/6] Удаление таймера авторестарта nginx (если есть)...${NC}"

TIMER_NAME="nginx-restart-5min"

if systemctl is-active --quiet "${TIMER_NAME}.timer" 2>/dev/null; then
    systemctl stop "${TIMER_NAME}.timer"
    echo -e "${CYAN}  ✔ Таймер остановлен.${NC}"
fi

if systemctl is-enabled --quiet "${TIMER_NAME}.timer" 2>/dev/null; then
    systemctl disable "${TIMER_NAME}.timer"
    echo -e "${CYAN}  ✔ Таймер отключён из автозапуска.${NC}"
fi

REMOVED=false
for f in \
    "/etc/systemd/system/${TIMER_NAME}.timer" \
    "/etc/systemd/system/${TIMER_NAME}.service"
do
    if [[ -f "$f" ]]; then
        rm -f "$f"
        echo -e "${CYAN}  ✔ Удалён файл: $f${NC}"
        REMOVED=true
    fi
done

if $REMOVED; then
    systemctl daemon-reload
    echo -e "${GREEN}  ✔ Таймер авторестарта полностью удалён.${NC}"
else
    echo -e "${CYAN}  — Таймер не найден, ничего не делаем.${NC}"
fi

# ════════════════════════════════════════════════
# [1/6] Установка Nginx mainline с HTTP/3
# ════════════════════════════════════════════════
echo -e "${GREEN}[1/6] Установка Nginx mainline с поддержкой HTTP/3...${NC}"

apt update -y
apt install -y curl gnupg2 ca-certificates lsb-release

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

# Приоритет mainline-репозитория над системным — именно это
# гарантирует замену старого nginx на версию с nginx.org
echo -e "Package: *\nPin: origin nginx.org\nPin-Priority: 900" \
    > /etc/apt/preferences.d/99nginx

apt update -y
apt install -y nginx   # обновит старый пакет, если он был установлен

NGINX_VERSION=$(nginx -v 2>&1)
echo -e "${CYAN}  Версия: ${NC}${NGINX_VERSION}"

HTTP3_AVAILABLE=true
if nginx -V 2>&1 | grep -q "http_v3"; then
    echo -e "${GREEN}  ✔ HTTP/3 (QUIC) поддерживается.${NC}"
else
    echo -e "${YELLOW}  ⚠ Сборка без --with-http_v3_module. Директивы будут закомментированы.${NC}"
    HTTP3_AVAILABLE=false
fi

# ════════════════════════════════════════════════
# [2/6] Установка certbot
# ════════════════════════════════════════════════
echo -e "${GREEN}[2/6] Установка certbot...${NC}"
apt install -y certbot

# ════════════════════════════════════════════════
# [3/6] Выпуск или обновление сертификата
# ════════════════════════════════════════════════
echo -e "${GREEN}[3/6] Проверка SSL-сертификата для $ORIGIN_DOMAIN...${NC}"

CERT_PATH="/etc/letsencrypt/live/$ORIGIN_DOMAIN/fullchain.pem"

if [[ -f "$CERT_PATH" ]]; then
    EXPIRY=$(openssl x509 -enddate -noout -in "$CERT_PATH" | cut -d= -f2)
    EXPIRY_EPOCH=$(date -d "$EXPIRY" +%s 2>/dev/null \
        || date -j -f "%b %d %T %Y %Z" "$EXPIRY" +%s 2>/dev/null)
    NOW_EPOCH=$(date +%s)
    DAYS_LEFT=$(( (EXPIRY_EPOCH - NOW_EPOCH) / 86400 ))

    echo -e "${CYAN}  Сертификат найден. Дней до истечения: ${DAYS_LEFT}${NC}"

    if [[ $DAYS_LEFT -lt 30 ]]; then
        echo -e "${YELLOW}  Обновляем сертификат (осталось менее 30 дней)...${NC}"
        systemctl stop nginx
        certbot certonly --standalone \
            -d "$ORIGIN_DOMAIN" \
            --non-interactive \
            --agree-tos \
            -m "$EMAIL" \
            --force-renewal
        systemctl start nginx
    else
        echo -e "${GREEN}  ✔ Сертификат актуален, пропускаем выпуск.${NC}"
    fi
else
    echo -e "${YELLOW}  Сертификат не найден, выпускаем...${NC}"
    systemctl stop nginx
    certbot certonly --standalone \
        -d "$ORIGIN_DOMAIN" \
        --non-interactive \
        --agree-tos \
        -m "$EMAIL"
    systemctl start nginx
fi

# ════════════════════════════════════════════════
# [4/6] Оптимизация nginx.conf
# ════════════════════════════════════════════════
echo -e "${GREEN}[4/6] Настройка nginx.conf (воркеры, соединения)...${NC}"

CPU_CORES=$(nproc)
MAX_FD=$(ulimit -Hn 2>/dev/null || echo 65535)
[[ -z "$MAX_FD" || "$MAX_FD" == "unlimited" ]] && MAX_FD=65535

WORKER_CONN=$(( MAX_FD / 2 ))
[[ $WORKER_CONN -gt 65535 ]] && WORKER_CONN=65535
[[ $WORKER_CONN -lt 1024  ]] && WORKER_CONN=1024

echo -e "${CYAN}  CPU ядер:             ${NC}${CPU_CORES}"
echo -e "${CYAN}  Лимит файлов (fd):    ${NC}${MAX_FD}"
echo -e "${CYAN}  worker_connections:   ${NC}${WORKER_CONN}"

cat > /etc/nginx/nginx.conf <<NGINXCONF
# ── Глобальные параметры ──────────────────────
user  nginx;
worker_processes  auto;              # по числу CPU (${CPU_CORES} ядер)
worker_rlimit_nofile  ${MAX_FD};     # лимит файловых дескрипторов на воркер

error_log  /var/log/nginx/error.log notice;
pid        /var/run/nginx.pid;

# ── События ───────────────────────────────────
events {
    worker_connections  ${WORKER_CONN}; # макс. соединений на воркер
    use epoll;            # наиболее эффективный метод на Linux
    multi_accept on;      # принимать все входящие соединения за раз
}

# ── HTTP ──────────────────────────────────────
http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    log_format  main  '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                      '\$status \$body_bytes_sent "\$http_referer" '
                      '"\$http_user_agent" "\$http_x_forwarded_for"';
    access_log  /var/log/nginx/access.log  main;

    # Производительность
    sendfile            on;
    tcp_nopush          on;
    tcp_nodelay         on;
    keepalive_timeout   65;
    keepalive_requests  10000;

    # Буферы
    client_body_buffer_size     128k;
    client_header_buffer_size   1k;
    large_client_header_buffers 4 16k;
    output_buffers              1 32k;
    postpone_output             1460;

    # Таймауты
    client_header_timeout     30s;
    client_body_timeout       60s;
    send_timeout              60s;
    reset_timedout_connection on;

    # Gzip
    gzip             on;
    gzip_comp_level  5;
    gzip_min_length  256;
    gzip_proxied     any;
    gzip_vary        on;
    gzip_types
        application/javascript
        application/json
        application/xml
        text/css
        text/javascript
        text/plain
        text/xml;

    # Open file cache
    open_file_cache           max=10000 inactive=30s;
    open_file_cache_valid     60s;
    open_file_cache_min_uses  2;
    open_file_cache_errors    on;

    server_tokens off;

    include /etc/nginx/conf.d/*.conf;
}
NGINXCONF

# ════════════════════════════════════════════════
# [5/6] Конфиг виртуального хоста с HTTP/3
# ════════════════════════════════════════════════
echo -e "${GREEN}[5/6] Создание конфига сайта с HTTP/3...${NC}"

if [[ "${HTTP3_AVAILABLE}" == "false" ]]; then
    HTTP3_LISTEN_V4="# listen 443 quic reuseport;  # раскомментировать после включения http_v3"
    HTTP3_LISTEN_V6="# listen [::]:443 quic reuseport;"
    HTTP3_ON="# http3 on;"
    ALT_SVC="# add_header Alt-Svc 'h3=\":443\"; ma=86400';  # раскомментировать после включения http_v3"
else
    HTTP3_LISTEN_V4="listen 443 quic reuseport;"
    HTTP3_LISTEN_V6="listen [::]:443 quic reuseport;"
    HTTP3_ON="http3 on;"
    ALT_SVC="add_header Alt-Svc 'h3=\":443\"; ma=86400' always;"
fi

cat > /etc/nginx/conf.d/remnawave-xhttp-cdn.conf <<EOF
# HTTP → HTTPS редирект
server {
    listen 80;
    listen [::]:80;
    server_name $ORIGIN_DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    # ── TCP: HTTP/1.1 + HTTP/2 ──
    listen 443 ssl;
    listen [::]:443 ssl;

    # ── UDP: HTTP/3 (QUIC) ──
    ${HTTP3_LISTEN_V4}
    ${HTTP3_LISTEN_V6}

    server_name $ORIGIN_DOMAIN;

    # ── Протоколы ──
    http2 on;
    ${HTTP3_ON}

    ${ALT_SVC}

    # ── SSL ──
    ssl_certificate     /etc/letsencrypt/live/$ORIGIN_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$ORIGIN_DOMAIN/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305';
    ssl_prefer_server_ciphers off;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:10m;
    ssl_session_tickets off;

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

# ════════════════════════════════════════════════
# [6/6] Открытие UDP 443 для QUIC
# ════════════════════════════════════════════════
echo -e "${GREEN}[6/6] Открытие UDP-порта 443 для HTTP/3...${NC}"

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
    echo -e "${YELLOW}  ⚠ Фаервол не обнаружен. Откройте UDP 443 вручную.${NC}"
fi

# ── Проверка и перезапуск nginx ──
echo -e "${GREEN}[+] Проверка конфига и перезапуск nginx...${NC}"
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
echo -e "${CYAN}Nginx:${NC}"
echo -e "  worker_processes:    ${GREEN}auto (${CPU_CORES} ядер)${NC}"
echo -e "  worker_connections:  ${GREEN}${WORKER_CONN}${NC}"
echo -e "  worker_rlimit_nofile:${GREEN}${MAX_FD}${NC}"
echo -e "  Макс. соединений:    ${GREEN}$(( CPU_CORES * WORKER_CONN ))${NC} (ядра × connections)"
echo ""
echo -e "${CYAN}Протоколы:${NC}"
echo -e "  ${GREEN}✔${NC} HTTP/1.1 (TCP 443)"
echo -e "  ${GREEN}✔${NC} HTTP/2   (TCP 443)"
if [[ "${HTTP3_AVAILABLE}" != "false" ]]; then
    echo -e "  ${GREEN}✔${NC} HTTP/3   (UDP 443) — активен"
else
    echo -e "  ${YELLOW}⚠${NC} HTTP/3   (UDP 443) — требует nginx с --with-http_v3_module"
fi
echo ""
echo -e "${YELLOW}Проверка HTTP/3: https://http3check.net/?host=$ORIGIN_DOMAIN${NC}"
echo ""
