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

# ── Проверка root ──
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Запустите скрипт от root: sudo bash install.sh${NC}"
    exit 1
fi

# ════════════════════════════════════════════════
# Автоопределение домена из conf.d
# ════════════════════════════════════════════════
DETECTED_DOMAIN=""

if [[ -d /etc/nginx/conf.d ]]; then
    for conf in /etc/nginx/conf.d/*.conf; do
        [[ -f "$conf" ]] || continue
        if ! grep -q "listen.*443" "$conf"; then
            continue
        fi
        domain=$(grep -E "^\s*server_name\s+" "$conf" \
            | grep -v "server_name\s*_" \
            | grep -v "server_name\s*localhost" \
            | awk '{print $2}' \
            | tr -d ';' \
            | head -1)
        if [[ -n "$domain" ]]; then
            DETECTED_DOMAIN="$domain"
            echo -e "${GREEN}Найден существующий конфиг: ${CYAN}$conf${NC}"
            echo -e "${GREEN}Обнаружен домен: ${CYAN}$domain${NC}"
            echo ""
            break
        fi
    done
fi

# ── Ввод домена ──
if [[ -n "$DETECTED_DOMAIN" ]]; then
    echo -e "${YELLOW}Использовать найденный домен ${CYAN}${DETECTED_DOMAIN}${YELLOW}? [Y/n]:${NC} "
    read -r CONFIRM
    CONFIRM="${CONFIRM:-Y}"
    if [[ "${CONFIRM,,}" == "y" || "${CONFIRM,,}" == "yes" ]]; then
        ORIGIN_DOMAIN="$DETECTED_DOMAIN"
        echo -e "${GREEN}  ✔ Используем домен: $ORIGIN_DOMAIN${NC}"
    else
        echo -e "${YELLOW}Введите ваш домен (например: origin.example.com):${NC}"
        read -r ORIGIN_DOMAIN
    fi
else
    echo -e "${CYAN}Существующих конфигов с портом 443 не найдено.${NC}"
    echo -e "${YELLOW}Введите ваш домен (например: origin.example.com):${NC}"
    read -r ORIGIN_DOMAIN
fi

if [[ -z "$ORIGIN_DOMAIN" ]]; then
    echo -e "${RED}Ошибка: домен не может быть пустым.${NC}"
    exit 1
fi

echo ""
echo -e "${CYAN}▶ Домен:        ${NC}$ORIGIN_DOMAIN"
echo -e "${CYAN}▶ Почта:        ${NC}$EMAIL"
echo -e "${CYAN}▶ Порт inbound: ${NC}$INBOUND_PORT"
echo ""
echo -e "${YELLOW}Начинаем установку...${NC}"
echo ""

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
# [0/8] Удаление таймера авторестарта nginx
# ════════════════════════════════════════════════
echo -e "${GREEN}[0/8] Удаление таймера авторестарта nginx (если есть)...${NC}"

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
        echo -e "${CYAN}  ✔ Удалён: $f${NC}"
        REMOVED=true
    fi
done

if $REMOVED; then
    systemctl daemon-reload
    echo -e "${GREEN}  ✔ Таймер авторестарта полностью удалён.${NC}"
else
    echo -e "${CYAN}  — Таймер не найден, пропускаем.${NC}"
fi

# ════════════════════════════════════════════════
# [1/8] Установка Nginx mainline с HTTP/3
# ════════════════════════════════════════════════
echo -e "${GREEN}[1/8] Установка Nginx mainline с поддержкой HTTP/3...${NC}"

apt update -y
apt install -y curl gnupg2 ca-certificates lsb-release

rm -rf /usr/share/keyrings/nginx-archive-keyring.gpg
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

echo -e "Package: *\nPin: origin nginx.org\nPin-Priority: 900" \
    > /etc/apt/preferences.d/99nginx

apt update -y
apt install -y nginx

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
# [2/8] Установка certbot
# ════════════════════════════════════════════════
echo -e "${GREEN}[2/8] Установка certbot...${NC}"
apt install -y certbot

# ════════════════════════════════════════════════
# [3/8] Выпуск или обновление сертификата
# ════════════════════════════════════════════════
echo -e "${GREEN}[3/8] Проверка SSL-сертификата для $ORIGIN_DOMAIN...${NC}"

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
# [4/8] systemd override — лимит файлов для nginx
# ════════════════════════════════════════════════
echo -e "${GREEN}[4/8] Настройка systemd override для nginx (LimitNOFILE)...${NC}"

mkdir -p /etc/systemd/system/nginx.service.d/
cat > /etc/systemd/system/nginx.service.d/override.conf << 'EOF'
[Service]
LimitNOFILE=65535
EOF

systemctl daemon-reload
echo -e "${GREEN}  ✔ systemd override применён (LimitNOFILE=65535).${NC}"

# ════════════════════════════════════════════════
# [5/8] limits.conf
# ════════════════════════════════════════════════
echo -e "${GREEN}[5/8] Настройка /etc/security/limits.conf...${NC}"

sed -i '/nginx.*nofile/d'    /etc/security/limits.conf
sed -i '/www-data.*nofile/d' /etc/security/limits.conf

cat >> /etc/security/limits.conf << 'EOF'
nginx    soft nofile 65535
nginx    hard nofile 65535
www-data soft nofile 65535
www-data hard nofile 65535
EOF

echo -e "${GREEN}  ✔ limits.conf обновлён.${NC}"

# ════════════════════════════════════════════════
# [6/8] sysctl — параметры ядра
# ════════════════════════════════════════════════
echo -e "${GREEN}[6/8] Применение sysctl параметров...${NC}"

apply_sysctl() {
    local key="$1" val="$2"
    if grep -q "^${key}" /etc/sysctl.conf; then
        sed -i "s|^${key}.*|${key} = ${val}|" /etc/sysctl.conf
    else
        echo "${key} = ${val}" >> /etc/sysctl.conf
    fi
}

apply_sysctl "net.core.somaxconn"            65535
apply_sysctl "net.ipv4.tcp_max_syn_backlog"  65535
apply_sysctl "net.ipv4.tcp_tw_reuse"         1
apply_sysctl "net.ipv4.tcp_fin_timeout"      15
apply_sysctl "net.ipv4.tcp_keepalive_time"   300
apply_sysctl "net.ipv4.tcp_keepalive_intvl"  30
apply_sysctl "net.ipv4.tcp_keepalive_probes" 5
apply_sysctl "net.core.rmem_max"             16777216
apply_sysctl "net.core.wmem_max"             16777216
apply_sysctl "net.core.netdev_max_backlog"   65535

sysctl -p > /dev/null 2>&1
echo -e "${GREEN}  ✔ sysctl применён.${NC}"

# ════════════════════════════════════════════════
# [7/8] nginx.conf — воркеры и производительность
# ════════════════════════════════════════════════
echo -e "${GREEN}[7/8] Настройка nginx.conf (воркеры, соединения)...${NC}"

CPU_CORES=$(nproc)
MAX_FD=65535

WORKER_CONN=$(( MAX_FD / 2 ))
[[ $WORKER_CONN -gt 65535 ]] && WORKER_CONN=65535
[[ $WORKER_CONN -lt 1024  ]] && WORKER_CONN=1024

echo -e "${CYAN}  CPU ядер:             ${NC}${CPU_CORES}"
echo -e "${CYAN}  worker_rlimit_nofile: ${NC}${MAX_FD}"
echo -e "${CYAN}  worker_connections:   ${NC}${WORKER_CONN}"

cat > /etc/nginx/nginx.conf <<NGINXCONF
# ── Глобальные параметры ──────────────────────
user  nginx;
worker_processes  auto;              # по числу CPU (${CPU_CORES} ядер)
worker_rlimit_nofile  ${MAX_FD};     # совпадает с LimitNOFILE в systemd

error_log  /var/log/nginx/error.log notice;
pid        /var/run/nginx.pid;

# ── События ───────────────────────────────────
events {
    worker_connections  ${WORKER_CONN};
    use epoll;
    multi_accept on;
}

# ── HTTP ──────────────────────────────────────
http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    log_format  main  '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                      '\$status \$body_bytes_sent "\$http_referer" '
                      '"\$http_user_agent" "\$http_x_forwarded_for"';
    access_log  /var/log/nginx/access.log  main;

    sendfile            on;
    tcp_nopush          on;
    tcp_nodelay         on;
    keepalive_timeout   65;
    keepalive_requests  10000;

    client_body_buffer_size     128k;
    client_header_buffer_size   1k;
    large_client_header_buffers 4 16k;
    output_buffers              1 32k;
    postpone_output             1460;

    client_header_timeout     30s;
    client_body_timeout       60s;
    send_timeout              60s;
    reset_timedout_connection on;

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

    open_file_cache           max=10000 inactive=30s;
    open_file_cache_valid     60s;
    open_file_cache_min_uses  2;
    open_file_cache_errors    on;

    server_tokens off;

    include /etc/nginx/conf.d/*.conf;
}
NGINXCONF

# ════════════════════════════════════════════════
# [8/8] Очистка старых конфигов + новый конфиг + HTTP/3 + фаервол
# ════════════════════════════════════════════════
echo -e "${GREEN}[8/8] Конфиг сайта, HTTP/3, фаервол...${NC}"

# ── Удаляем все старые конфиги в conf.d которые слушают 443 ──
echo -e "${CYAN}  Удаление старых конфигов с портом 443...${NC}"
OUR_CONF="remnawave-xhttp-cdn.conf"
DELETED_ANY=false

for conf in /etc/nginx/conf.d/*.conf; do
    [[ -f "$conf" ]] || continue
    # Пропускаем наш собственный файл (он будет перезаписан ниже)
    [[ "$(basename "$conf")" == "$OUR_CONF" ]] && continue

    if grep -q "listen.*443" "$conf"; then
        rm -f "$conf"
        echo -e "${CYAN}  ✔ Удалён конфиг: $conf${NC}"
        DELETED_ANY=true
    fi
done

if ! $DELETED_ANY; then
    echo -e "${CYAN}  — Лишних конфигов не найдено.${NC}"
fi

# ── Пишем новый конфиг ──
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
    listen 443 ssl;
    listen [::]:443 ssl;

    ${HTTP3_LISTEN_V4}
    ${HTTP3_LISTEN_V6}

    server_name $ORIGIN_DOMAIN;

    http2 on;
    ${HTTP3_ON}
    

    ssl_certificate     /etc/letsencrypt/live/$ORIGIN_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$ORIGIN_DOMAIN/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305';
    ssl_prefer_server_ciphers off;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:10m;
    ssl_session_tickets off;

    client_max_body_size 0;
    large_client_header_buffers 32 128k;
    client_header_buffer_size 128k;
    underscores_in_headers on;

    proxy_buffering off;
    proxy_request_buffering off;
    proxy_ignore_client_abort on;

    location /api/user {
        proxy_pass http://127.0.0.1:${INBOUND_PORT};

        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Connection "";

        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        send_timeout 3600s;

        add_header Alt-Svc 'h3=":443"; ma=86400' always;
        add_header Strict-Transport-Security "max-age=63072000" always;
    }
}
EOF

echo -e "${GREEN}  ✔ Конфиг записан: /etc/nginx/conf.d/${OUR_CONF}${NC}"

# ── Открытие UDP 443 ──
echo -e "${CYAN}  Открываем UDP 443 для HTTP/3...${NC}"
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
echo -e "${CYAN}  Проверка конфига nginx...${NC}"
nginx -t
systemctl restart nginx
echo -e "${GREEN}  ✔ nginx перезапущен.${NC}"

# ── Перезапуск ноды ──
echo -e "${GREEN}[+] Перезапуск remnanode...${NC}"
docker restart remnanode

# ════════════════════════════════════════════════
# Итог
# ════════════════════════════════════════════════
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════╗"
echo -e "║         ✅  Установка завершена!         ║"
echo -e "╚══════════════════════════════════════════╝${NC}"
echo ""
echo -e "${CYAN}Домен:   ${NC}https://$ORIGIN_DOMAIN"
echo -e "${CYAN}Порт:    ${NC}$INBOUND_PORT"
echo -e "${CYAN}Почта:   ${NC}$EMAIL"
echo ""
echo -e "${CYAN}Оптимизация системы:${NC}"
echo -e "  LimitNOFILE (systemd):  ${GREEN}65535${NC}"
echo -e "  nofile (limits.conf):   ${GREEN}65535${NC}"
echo -e "  somaxconn:              ${GREEN}65535${NC}"
echo -e "  tcp_max_syn_backlog:    ${GREEN}65535${NC}"
echo -e "  netdev_max_backlog:     ${GREEN}65535${NC}"
echo ""
echo -e "${CYAN}Nginx:${NC}"
echo -e "  worker_processes:       ${GREEN}auto (${CPU_CORES} ядер)${NC}"
echo -e "  worker_rlimit_nofile:   ${GREEN}${MAX_FD}${NC}"
echo -e "  worker_connections:     ${GREEN}${WORKER_CONN}${NC}"
echo -e "  Макс. соединений:       ${GREEN}$(( CPU_CORES * WORKER_CONN ))${NC} (ядра × connections)"
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
