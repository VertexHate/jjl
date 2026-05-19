#!/bin/bash

# ─────────────────────────────────────────────
#  RemnaWave XHTTP CDN — автоустановщик
#  HTTP/3 (QUIC) | идемпотентный
# ─────────────────────────────────────────────

set -euo pipefail

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

apt-get update -y
apt-get install -y curl gnupg2 ca-certificates lsb-release

# Удаляем старый ключ и репо перед перезаписью
rm -f /usr/share/keyrings/nginx-archive-keyring.gpg

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

cat > /etc/apt/preferences.d/99nginx << 'EOF'
Package: *
Pin: origin nginx.org
Pin-Priority: 900
EOF

apt-get update -y
apt-get install -y nginx

NGINX_VERSION=$(nginx -v 2>&1 | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+')
echo -e "${CYAN}  Версия nginx: ${NC}${NGINX_VERSION}"

# ── Корректная проверка HTTP/3 ──
# Ищем http_v3_module в выводе nginx -V
HTTP3_AVAILABLE=false
NGINX_V_OUTPUT=$(nginx -V 2>&1)

if echo "$NGINX_V_OUTPUT" | grep -q "http_v3_module"; then
    HTTP3_AVAILABLE=true
    echo -e "${GREEN}  ✔ HTTP/3 (QUIC) поддерживается (http_v3_module найден).${NC}"
else
    echo -e "${YELLOW}  ⚠ http_v3_module не найден в этой сборке nginx.${NC}"
    echo -e "${YELLOW}  Попытка установки nginx-module-njs или пересборки...${NC}"
    # Проверяем альтернативное название флага
    if echo "$NGINX_V_OUTPUT" | grep -qiE "with-http_v3|quic"; then
        HTTP3_AVAILABLE=true
        echo -e "${GREEN}  ✔ QUIC/HTTP3 поддержка обнаружена (альтернативный флаг).${NC}"
    else
        echo -e "${YELLOW}  ⚠ HTTP/3 недоступен. Директивы QUIC будут закомментированы.${NC}"
        echo -e "${CYAN}  Для HTTP/3 нужен nginx >= 1.25.0 из mainline репозитория.${NC}"
    fi
fi

# ── Проверка версии nginx для http2 директивы ──
# http2 on; появилась в 1.25.1, до этого: listen 443 ssl http2;
NGINX_MAJOR=$(echo "$NGINX_VERSION" | cut -d. -f1)
NGINX_MINOR=$(echo "$NGINX_VERSION" | cut -d. -f2)
NGINX_PATCH=$(echo "$NGINX_VERSION" | cut -d. -f3)

HTTP2_DIRECTIVE_NEW=false
if [[ "$NGINX_MAJOR" -gt 1 ]]; then
    HTTP2_DIRECTIVE_NEW=true
elif [[ "$NGINX_MAJOR" -eq 1 && "$NGINX_MINOR" -gt 25 ]]; then
    HTTP2_DIRECTIVE_NEW=true
elif [[ "$NGINX_MAJOR" -eq 1 && "$NGINX_MINOR" -eq 25 && "${NGINX_PATCH:-0}" -ge 1 ]]; then
    HTTP2_DIRECTIVE_NEW=true
fi

echo -e "${CYAN}  Синтаксис http2: ${NC}$([ "$HTTP2_DIRECTIVE_NEW" = true ] && echo 'http2 on; (новый)' || echo 'listen ssl http2; (старый)')"

# ════════════════════════════════════════════════
# [2/8] Установка certbot
# ════════════════════════════════════════════════
echo -e "${GREEN}[2/8] Установка certbot...${NC}"
apt-get install -y certbot

# ════════════════════════════════════════════════
# [3/8] Выпуск или обновление сертификата
# ════════════════════════════════════════════════
echo -e "${GREEN}[3/8] Проверка SSL-сертификата для $ORIGIN_DOMAIN...${NC}"

CERT_PATH="/etc/letsencrypt/live/$ORIGIN_DOMAIN/fullchain.pem"

# Используем глобальную переменную вместо return-кода
# чтобы не конфликтовать с set -e
NGINX_WAS_RUNNING=false

nginx_stop_if_running() {
    if systemctl is-active --quiet nginx 2>/dev/null; then
        systemctl stop nginx
        NGINX_WAS_RUNNING=true
        echo -e "${CYAN}  nginx остановлен для certbot.${NC}"
    else
        NGINX_WAS_RUNNING=false
        echo -e "${CYAN}  nginx не запущен, certbot может занять порт 80.${NC}"
    fi
}

nginx_start_if_was_running() {
    if [[ "$NGINX_WAS_RUNNING" == "true" ]]; then
        systemctl start nginx 2>/dev/null || true
        echo -e "${CYAN}  nginx запущен.${NC}"
    fi
}

if [[ -f "$CERT_PATH" ]]; then
    EXPIRY=$(openssl x509 -enddate -noout -in "$CERT_PATH" | cut -d= -f2)
    EXPIRY_EPOCH=$(date -d "$EXPIRY" +%s 2>/dev/null || true)
    NOW_EPOCH=$(date +%s)
    DAYS_LEFT=$(( (EXPIRY_EPOCH - NOW_EPOCH) / 86400 ))

    echo -e "${CYAN}  Сертификат найден. Дней до истечения: ${DAYS_LEFT}${NC}"

    if [[ $DAYS_LEFT -lt 30 ]]; then
        echo -e "${YELLOW}  Обновляем сертификат...${NC}"
        nginx_stop_if_running
        certbot certonly --standalone \
            -d "$ORIGIN_DOMAIN" \
            --non-interactive --agree-tos \
            -m "$EMAIL" --force-renewal
        nginx_start_if_was_running
    else
        echo -e "${GREEN}  ✔ Сертификат актуален.${NC}"
    fi
else
    echo -e "${YELLOW}  Сертификат не найден, выпускаем...${NC}"
    nginx_stop_if_running
    certbot certonly --standalone \
        -d "$ORIGIN_DOMAIN" \
        --non-interactive --agree-tos \
        -m "$EMAIL"
    nginx_start_if_was_running
fi

# Проверяем что сертификат успешно выпущен
if [[ ! -f "$CERT_PATH" ]]; then
    echo -e "${RED}  ✗ Сертификат не был выпущен! Проверьте:${NC}"
    echo -e "${RED}    1. DNS запись A для $ORIGIN_DOMAIN указывает на этот сервер${NC}"
    echo -e "${RED}    2. Порт 80 доступен снаружи${NC}"
    echo -e "${RED}    3. Не заблокирован фаерволом${NC}"
    exit 1
fi

echo -e "${GREEN}  ✔ Сертификат готов.${NC}"

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
# [6/8] sysctl — параметры ядра (TCP + UDP/QUIC)
# ════════════════════════════════════════════════
echo -e "${GREEN}[6/8] Применение sysctl параметров (TCP + UDP/QUIC)...${NC}"

SYSCTL_FILE="/etc/sysctl.d/99-remnawave-nginx.conf"

# Пишем отдельный файл — не засоряем sysctl.conf
# Это правильный способ: sysctl.d подхватывается автоматически при загрузке
cat > "$SYSCTL_FILE" << 'EOF'
# ── TCP оптимизация ────────────────────────────
net.core.somaxconn            = 65535
net.ipv4.tcp_max_syn_backlog  = 65535
net.ipv4.tcp_tw_reuse         = 1
net.ipv4.tcp_fin_timeout      = 15
net.ipv4.tcp_keepalive_time   = 300
net.ipv4.tcp_keepalive_intvl  = 30
net.ipv4.tcp_keepalive_probes = 5
net.core.netdev_max_backlog   = 65535

# ── Буферы TCP ─────────────────────────────────
net.core.rmem_default         = 262144
net.core.wmem_default         = 262144
net.core.rmem_max             = 67108864
net.core.wmem_max             = 67108864
net.ipv4.tcp_rmem             = 4096 87380 67108864
net.ipv4.tcp_wmem             = 4096 65536 67108864
net.ipv4.tcp_mem              = 786432 1048576 26777216

# ── UDP буферы (критично для HTTP/3 QUIC) ──────
# QUIC работает поверх UDP, большие буферы снижают потери пакетов
net.core.rmem_max             = 67108864
net.core.wmem_max             = 67108864

# ── Дополнительные TCP параметры ───────────────
net.ipv4.tcp_fastopen         = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing      = 1

# ── BBR (лучший congestion control для VPN/proxy) ──
net.core.default_qdisc        = fq
net.ipv4.tcp_congestion_control = bbr

# ── Защита от SYN-flood ────────────────────────
net.ipv4.tcp_syncookies       = 1

# ── IPv6 ───────────────────────────────────────
net.ipv6.conf.all.disable_ipv6 = 0
EOF

# Применяем все файлы из sysctl.d + sysctl.conf
sysctl --system > /dev/null 2>&1
echo -e "${GREEN}  ✔ sysctl применён из $SYSCTL_FILE${NC}"

# Проверяем BBR
if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q "bbr"; then
    echo -e "${GREEN}  ✔ BBR congestion control активен.${NC}"
else
    echo -e "${YELLOW}  ⚠ BBR недоступен на этом ядре (нужен Linux >= 4.9).${NC}"
    # Откатываем до cubic чтоб не было ошибки
    sed -i '/tcp_congestion_control.*bbr/d' "$SYSCTL_FILE"
    sed -i '/default_qdisc.*fq/d' "$SYSCTL_FILE"
    sysctl --system > /dev/null 2>&1
fi

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

cat > /etc/nginx/nginx.conf << NGINXCONF
# ── Глобальные параметры ──────────────────────
user  nginx;
worker_processes  auto;
worker_rlimit_nofile  ${MAX_FD};

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

echo -e "${GREEN}  ✔ nginx.conf записан.${NC}"

# ════════════════════════════════════════════════
# [8/8] Конфиг сайта + HTTP/3 + фаервол
# ════════════════════════════════════════════════
echo -e "${GREEN}[8/8] Конфиг сайта, HTTP/3, фаервол...${NC}"

OUR_CONF="remnawave-xhttp-cdn.conf"

# ── Удаляем старые конфиги с портом 443 ──
echo -e "${CYAN}  Удаление старых конфигов с портом 443...${NC}"
DELETED_ANY=false

for conf in /etc/nginx/conf.d/*.conf; do
    [[ -f "$conf" ]] || continue
    [[ "$(basename "$conf")" == "$OUR_CONF" ]] && continue
    if grep -q "listen.*443" "$conf"; then
        rm -f "$conf"
        echo -e "${CYAN}  ✔ Удалён: $conf${NC}"
        DELETED_ANY=true
    fi
done

$DELETED_ANY || echo -e "${CYAN}  — Лишних конфигов не найдено.${NC}"

# ── Формируем блоки в зависимости от версии nginx ──

if [[ "$HTTP3_AVAILABLE" == "true" ]]; then
    # HTTP/3: reuseport нужен только на одном listen,
    # дублировать на IPv4 и IPv6 одновременно нельзя — nginx упадёт с ошибкой
    # Решение: reuseport только на IPv4, IPv6 без него
    QUIC_LISTEN_V4="    listen 443 quic reuseport;"
    QUIC_LISTEN_V6="    listen [::]:443 quic;"
    HTTP3_DIRECTIVE="    http3 on;"
    HTTP3_QUIC_RETRY="    quic_retry on;"
    ALT_SVC_HEADER="    add_header Alt-Svc 'h3=\":443\"; ma=86400' always;"
    QUIC_BUF="    quic_gso on;"
else
    QUIC_LISTEN_V4="    # listen 443 quic reuseport;  # требует nginx >= 1.25.0 с http_v3_module"
    QUIC_LISTEN_V6="    # listen [::]:443 quic;"
    HTTP3_DIRECTIVE="    # http3 on;"
    HTTP3_QUIC_RETRY="    # quic_retry on;"
    ALT_SVC_HEADER="    # add_header Alt-Svc 'h3=\":443\"; ma=86400' always;"
    QUIC_BUF="    # quic_gso on;"
fi

# ── HTTP/2: старый и новый синтаксис ──
if [[ "$HTTP2_DIRECTIVE_NEW" == "true" ]]; then
    # nginx >= 1.25.1: отдельная директива http2 on;
    TCP_LISTEN_V4="    listen 443 ssl;"
    TCP_LISTEN_V6="    listen [::]:443 ssl;"
    HTTP2_BLOCK="    http2 on;"
else
    # nginx < 1.25.1: http2 в директиве listen
    TCP_LISTEN_V4="    listen 443 ssl http2;"
    TCP_LISTEN_V6="    listen [::]:443 ssl http2;"
    HTTP2_BLOCK="    # http2 on; (не поддерживается в nginx < 1.25.1, используется listen ssl http2)"
fi

cat > /etc/nginx/conf.d/${OUR_CONF} << EOF
# ── HTTP → HTTPS редирект ──────────────────────
server {
    listen 80;
    listen [::]:80;
    server_name ${ORIGIN_DOMAIN};
    return 301 https://\$host\$request_uri;
}

# ── HTTPS + HTTP/2 + HTTP/3 ───────────────────
server {
    # TCP: HTTP/1.1 + HTTP/2
${TCP_LISTEN_V4}
${TCP_LISTEN_V6}

    # UDP: HTTP/3 (QUIC)
${QUIC_LISTEN_V4}
${QUIC_LISTEN_V6}

    server_name ${ORIGIN_DOMAIN};

    # HTTP/2
${HTTP2_BLOCK}

    # HTTP/3 (QUIC)
${HTTP3_DIRECTIVE}
${HTTP3_QUIC_RETRY}
${QUIC_BUF}

    # Alt-Svc сообщает браузеру что HTTP/3 доступен
${ALT_SVC_HEADER}

    # ── SSL ──────────────────────────────────
    ssl_certificate     /etc/letsencrypt/live/${ORIGIN_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${ORIGIN_DOMAIN}/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305';
    ssl_prefer_server_ciphers off;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:10m;
    ssl_session_tickets off;

    # HSTS
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
    add_header X-Content-Type-Options "nosniff" always;

    client_max_body_size 0;

    # ── Proxy на XHTTP inbound ────────────────
    location / {
        proxy_pass http://127.0.0.1:${INBOUND_PORT};

        proxy_http_version 1.1;

        # Обязательно для WebSocket / XHTTP upgrade
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;

        # Отключаем буферизацию — критично для стриминг-протоколов
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_cache off;

        # Длинные таймауты для постоянных соединений
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        send_timeout       3600s;
        proxy_connect_timeout 10s;

        add_header Cache-Control "no-store" always;
        add_header Pragma "no-cache" always;
        add_header Expires "0" always;
    }
}
EOF

# ── Нужна map для connection_upgrade (WebSocket / XHTTP) ──
# Добавляем в nginx.conf в секцию http если ещё нет
if ! grep -q "connection_upgrade" /etc/nginx/nginx.conf; then
    # Вставляем map-блок перед include conf.d
    sed -i '/include \/etc\/nginx\/conf\.d/i\
\
    # WebSocket / XHTTP upgrade map\
    map $http_upgrade $connection_upgrade {\
        default upgrade;\
        '"''"'      close;\
    }\
' /etc/nginx/nginx.conf
    echo -e "${GREEN}  ✔ map \$connection_upgrade добавлен в nginx.conf.${NC}"
fi

echo -e "${GREEN}  ✔ Конфиг записан: /etc/nginx/conf.d/${OUR_CONF}${NC}"

# ── Открытие UDP 443 для HTTP/3 ──
echo -e "${CYAN}  Открываем UDP 443 для HTTP/3...${NC}"

if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow 443/tcp comment "HTTPS TCP"  > /dev/null 2>&1 || true
    ufw allow 443/udp comment "HTTPS UDP (HTTP/3 QUIC)" > /dev/null 2>&1 || true
    echo -e "${GREEN}  ✔ UFW: TCP+UDP 443 открыт.${NC}"
elif command -v firewall-cmd &>/dev/null && firewall-cmd --state 2>/dev/null | grep -q "running"; then
    firewall-cmd --permanent --add-port=443/tcp > /dev/null 2>&1 || true
    firewall-cmd --permanent --add-port=443/udp > /dev/null 2>&1 || true
    firewall-cmd --reload > /dev/null 2>&1
    echo -e "${GREEN}  ✔ firewalld: TCP+UDP 443 открыт.${NC}"
elif command -v iptables &>/dev/null; then
    iptables -C INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null \
        || iptables -A INPUT -p tcp --dport 443 -j ACCEPT
    iptables -C INPUT -p udp --dport 443 -j ACCEPT 2>/dev/null \
        || iptables -A INPUT -p udp --dport 443 -j ACCEPT
    # Сохраняем правила если есть iptables-persistent
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save > /dev/null 2>&1 || true
    elif command -v iptables-save &>/dev/null; then
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    fi
    echo -e "${GREEN}  ✔ iptables: TCP+UDP 443 открыт.${NC}"
else
    echo -e "${YELLOW}  ⚠ Фаервол не обнаружен. Откройте вручную: TCP/UDP 443.${NC}"
fi

# ── Проверка конфига и перезапуск nginx ──
echo -e "${CYAN}  Проверка конфига nginx...${NC}"

if nginx -t 2>&1; then
    echo -e "${GREEN}  ✔ Конфиг валиден.${NC}"
    systemctl restart nginx
    echo -e "${GREEN}  ✔ nginx перезапущен.${NC}"
else
    echo -e "${RED}  ✗ Ошибка в конфиге nginx! Показываем детали:${NC}"
    nginx -t
    echo -e "${RED}  Исправьте ошибки и перезапустите nginx вручную.${NC}"
    exit 1
fi

# ── Перезапуск remnanode ──
echo -e "${GREEN}[+] Перезапуск remnanode...${NC}"
if docker ps -q -f name=remnanode | grep -q .; then
    docker restart remnanode
    echo -e "${GREEN}  ✔ remnanode перезапущен.${NC}"
else
    echo -e "${YELLOW}  ⚠ Контейнер remnanode не найден или не запущен.${NC}"
fi

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
echo -e "  rmem_max / wmem_max:    ${GREEN}64 MB (UDP/QUIC буферы)${NC}"
echo -e "  tcp_congestion_control: ${GREEN}BBR${NC}"
echo ""
echo -e "${CYAN}Nginx:${NC}"
echo -e "  Версия:                 ${GREEN}${NGINX_VERSION}${NC}"
echo -e "  worker_processes:       ${GREEN}auto (${CPU_CORES} ядер)${NC}"
echo -e "  worker_rlimit_nofile:   ${GREEN}${MAX_FD}${NC}"
echo -e "  worker_connections:     ${GREEN}${WORKER_CONN}${NC}"
echo -e "  Макс. соединений:       ${GREEN}$(( CPU_CORES * WORKER_CONN ))${NC}"
echo ""
echo -e "${CYAN}Протоколы:${NC}"
echo -e "  ${GREEN}✔${NC} HTTP/1.1 (TCP 443)"
echo -e "  ${GREEN}✔${NC} HTTP/2   (TCP 443)"
if [[ "$HTTP3_AVAILABLE" == "true" ]]; then
    echo -e "  ${GREEN}✔${NC} HTTP/3   (UDP 443) — активен"
else
    echo -e "  ${YELLOW}⚠${NC} HTTP/3   (UDP 443) — не поддерживается данной сборкой nginx"
    echo -e "  ${YELLOW}  Для активации установите nginx >= 1.25.0 из nginx.org/packages/mainline${NC}"
fi
echo ""
echo -e "${YELLOW}Проверка HTTP/3: https://http3check.net/?host=$ORIGIN_DOMAIN${NC}"
echo -e "${YELLOW}Проверка заголовков: curl -sI --http3 https://$ORIGIN_DOMAIN${NC}"
echo ""
