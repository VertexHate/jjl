#!/bin/bash
# ============================================================
#  nginx-xhttp-optimize.sh
#  Оптимизация nginx для xhttp VPN (xray/remnanode)
#  Использование: bash nginx.sh
#  Домен и порт определяются автоматически
# ============================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[!!]${NC} $1"; }
info() { echo -e "${CYAN}[..]${NC} $1"; }
err()  { echo -e "${RED}[ERR]${NC} $1"; exit 1; }

[ "$EUID" -ne 0 ] && err "Запускай от root: sudo bash nginx.sh"

# ------------------------------------------------------------
# 1. Автоопределение домена
# ------------------------------------------------------------
info "Ищем домен в конфигах nginx..."

DOMAIN=""

# Ищем server_name во всех конфигах (исключаем _ и localhost)
for conf in /etc/nginx/conf.d/*.conf /etc/nginx/sites-enabled/*; do
    [ -f "$conf" ] || continue
    candidate=$(grep -E '^\s*server_name\s+' "$conf" 2>/dev/null \
        | grep -v '_\|localhost' \
        | awk '{print $2}' \
        | tr -d ';' \
        | head -1)
    if [ -n "$candidate" ]; then
        DOMAIN="$candidate"
        info "Нашли домен в $conf: $DOMAIN"
        break
    fi
done

# Если не нашли — ищем в letsencrypt
if [ -z "$DOMAIN" ]; then
    info "Ищем домен в /etc/letsencrypt/live/..."
    DOMAIN=$(ls /etc/letsencrypt/live/ 2>/dev/null \
        | grep -v 'README' \
        | head -1)
    [ -n "$DOMAIN" ] && info "Нашли домен в letsencrypt: $DOMAIN"
fi

[ -z "$DOMAIN" ] && err "Не удалось определить домен. Запусти: bash nginx.sh <домен> <порт>"

# ------------------------------------------------------------
# 2. Автоопределение порта xray
# ------------------------------------------------------------
info "Ищем порт xray..."

XRAY_PORT=""

# Ищем proxy_pass в конфигах nginx
for conf in /etc/nginx/conf.d/*.conf /etc/nginx/sites-enabled/*; do
    [ -f "$conf" ] || continue
    candidate=$(grep -E 'proxy_pass\s+http://127\.0\.0\.1:' "$conf" 2>/dev/null \
        | grep -oE ':[0-9]+' \
        | tr -d ':' \
        | head -1)
    if [ -n "$candidate" ]; then
        XRAY_PORT="$candidate"
        info "Нашли порт в $conf: $XRAY_PORT"
        break
    fi
done

# Ищем в конфиге xray напрямую
if [ -z "$XRAY_PORT" ]; then
    for config_path in \
        /usr/local/etc/xray/config.json \
        /etc/xray/config.json \
        /opt/remnanode/config.json; do
        if [ -f "$config_path" ]; then
            candidate=$(grep -oE '"port"\s*:\s*[0-9]+' "$config_path" \
                | grep -oE '[0-9]+' \
                | head -1)
            [ -n "$candidate" ] && XRAY_PORT="$candidate" && break
        fi
    done
fi

# Ищем в docker контейнере remnanode
if [ -z "$XRAY_PORT" ] && command -v docker &>/dev/null; then
    info "Ищем порт в docker контейнере remnanode..."
    candidate=$(docker exec remnanode \
        sh -c "find / -name '*.json' 2>/dev/null | xargs grep -l 'xhttp' 2>/dev/null | head -1 | xargs grep -oE '\"port\"\s*:\s*[0-9]+' 2>/dev/null | grep -oE '[0-9]+' | head -1" 2>/dev/null || true)
    [ -n "$candidate" ] && XRAY_PORT="$candidate"
fi

# Ищем что слушает на 127.0.0.1 кроме стандартных портов
if [ -z "$XRAY_PORT" ]; then
    info "Сканируем ss для поиска порта xray..."
    XRAY_PORT=$(ss -tlnp 2>/dev/null \
        | grep '127.0.0.1' \
        | grep -vE ':80\s|:443\s|:22\s|:3306\s|:5432\s' \
        | awk '{print $4}' \
        | grep -oE '[0-9]+$' \
        | head -1)
fi

# Fallback
if [ -z "$XRAY_PORT" ]; then
    XRAY_PORT="10085"
    warn "Порт не найден автоматически, используем дефолт: 10085"
fi

# ------------------------------------------------------------
# 3. Показываем что нашли
# ------------------------------------------------------------
echo ""
echo "============================================================"
echo "  nginx xhttp optimizer"
echo "  Домен      : $DOMAIN"
echo "  Xray порт  : $XRAY_PORT"
echo "  SSL cert   : /etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
echo "============================================================"
echo ""

SSL_CERT="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
SSL_KEY="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
[ ! -f "$SSL_CERT" ] && err "SSL сертификат не найден: $SSL_CERT"

# ------------------------------------------------------------
# 4. nginx.conf
# ------------------------------------------------------------
log "Патчим /etc/nginx/nginx.conf..."

NGINX_CONF="/etc/nginx/nginx.conf"
cp "$NGINX_CONF" "${NGINX_CONF}.bak.$(date +%s)"

cat > "$NGINX_CONF" << 'NGINXEOF'
user www-data;
worker_processes auto;
pid /run/nginx.pid;
error_log /var/log/nginx/error.log;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 65535;
    multi_accept on;
    use epoll;
}

http {
    sendfile on;
    tcp_nopush on;
    types_hash_max_size 2048;

    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;

    access_log /var/log/nginx/access.log;

    gzip off;

    keepalive_timeout 3600s;
    keepalive_requests 10000;
    proxy_connect_timeout 10s;

    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
NGINXEOF

log "nginx.conf обновлён"

# ------------------------------------------------------------
# 5. Удаляем старые конфиги чтобы не было дублей
# ------------------------------------------------------------
info "Удаляем старые конфиги xhttp vpn..."

for old in \
    /etc/nginx/conf.d/xhttp-vpn.conf \
    /etc/nginx/conf.d/remnawave-xhttp-cdn.conf \
    /etc/nginx/conf.d/remnanode.conf; do
    if [ -f "$old" ]; then
        rm -f "$old"
        warn "Удалён старый конфиг: $old"
    fi
done

# Удаляем из sites-enabled если там был конфиг с нашим доменом
for conf in /etc/nginx/sites-enabled/*; do
    [ -f "$conf" ] || continue
    if grep -q "$DOMAIN" "$conf" 2>/dev/null; then
        rm -f "$conf"
        warn "Удалён старый конфиг из sites-enabled: $conf"
    fi
done

# ------------------------------------------------------------
# 6. Новый конфиг сайта
# ------------------------------------------------------------
SITE_CONF="/etc/nginx/conf.d/xhttp-vpn.conf"
log "Создаём $SITE_CONF..."

cat > "$SITE_CONF" << EOF
upstream xray_backend {
    server 127.0.0.1:${XRAY_PORT};
    keepalive 64;
    keepalive_requests 100;
    keepalive_timeout 60s;
}

limit_conn_zone \$binary_remote_addr zone=vpn_limit:10m;

server {
    listen 443 ssl http2;
    server_name ${DOMAIN};

    ssl_certificate     ${SSL_CERT};
    ssl_certificate_key ${SSL_KEY};

    client_max_body_size 0;

    location / {
        limit_conn vpn_limit 100;

        proxy_pass http://xray_backend;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
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

log "Конфиг сайта создан"

# ------------------------------------------------------------
# 7. systemd override
# ------------------------------------------------------------
log "Настраиваем лимит файлов для nginx (systemd)..."

mkdir -p /etc/systemd/system/nginx.service.d/
cat > /etc/systemd/system/nginx.service.d/override.conf << 'EOF'
[Service]
LimitNOFILE=65535
EOF

systemctl daemon-reload
log "systemd override применён"

# ------------------------------------------------------------
# 8. limits.conf
# ------------------------------------------------------------
log "Настраиваем /etc/security/limits.conf..."

sed -i '/www-data.*nofile/d' /etc/security/limits.conf
cat >> /etc/security/limits.conf << 'EOF'
www-data soft nofile 65535
www-data hard nofile 65535
EOF

log "limits.conf обновлён"

# ------------------------------------------------------------
# 9. sysctl
# ------------------------------------------------------------
log "Применяем sysctl параметры..."

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

sysctl -p > /dev/null 2>&1
log "sysctl применён"

# ------------------------------------------------------------
# 10. Проверка и перезапуск nginx
# ------------------------------------------------------------
log "Проверяем конфиг nginx..."
nginx -t || err "Ошибка в конфиге nginx!"

log "Перезапускаем nginx..."
systemctl restart nginx
log "nginx перезапущен"

# ------------------------------------------------------------
# 11. Итог
# ------------------------------------------------------------
echo ""
echo "============================================================"
echo "  Результат"
echo "============================================================"

WORKER_PID=$(pgrep -f "nginx: worker" | head -1)
if [ -n "$WORKER_PID" ]; then
    NOFILE=$(grep "open files" /proc/${WORKER_PID}/limits 2>/dev/null | awk '{print $4}')
else
    NOFILE="н/д"
fi

echo "  Домен                     : $DOMAIN"
echo "  Xray порт                 : $XRAY_PORT"
echo "  Лимит файлов nginx worker : ${NOFILE}"
echo "  worker_connections        : 65535"
echo "  tcp_tw_reuse              : $(sysctl -n net.ipv4.tcp_tw_reuse)"
echo "  tcp_fin_timeout           : $(sysctl -n net.ipv4.tcp_fin_timeout)"
echo "  somaxconn                 : $(sysctl -n net.core.somaxconn)"
echo ""
echo -e "${GREEN}  Готово! Нода оптимизирована.${NC}"
echo "============================================================"
echo ""
warn "Не забудь в xray inbound добавить: \"maxUploadConnections\": 4"
echo ""
