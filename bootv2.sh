#!/usr/bin/env bash
# =============================================================================
# bootstrap-cdn-node-v2.sh
# Установка CDN-ноды: Remnawave + XHTTP (packet-up + uplinkHTTPMethod=GET)
# Поддерживаемые ОС: Debian 11+/12, Ubuntu 22.04+
# =============================================================================
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# Цвета для вывода
# ──────────────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ──────────────────────────────────────────────────────────────────────────────
# Аргументы
# ──────────────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Использование:
  $0 -d <FQDN> -k <SECRET_KEY> -p <NODE_PORT> -P <PANEL_URL>

Параметры:
  -d  FQDN ноды (A-запись должна резолвиться на IP VPS), например node.example.com
  -k  SECRET_KEY из Remnawave-панели (длинная base64)
  -p  NODE_PORT из Remnawave-панели (порт управления, например 2222)
  -P  PANEL_URL — https URL Remnawave-панели, например https://panel.example.com
EOF
    exit 1
}

DOMAIN="" SECRET_KEY="" NODE_PORT="" PANEL_URL=""
while getopts "d:k:p:P:h" opt; do
    case $opt in
        d) DOMAIN="$OPTARG" ;;
        k) SECRET_KEY="$OPTARG" ;;
        p) NODE_PORT="$OPTARG" ;;
        P) PANEL_URL="$OPTARG" ;;
        *) usage ;;
    esac
done
[[ -z "$DOMAIN" || -z "$SECRET_KEY" || -z "$NODE_PORT" || -z "$PANEL_URL" ]] && usage

# ──────────────────────────────────────────────────────────────────────────────
# Проверки среды
# ──────────────────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && die "Запустите скрипт от root."

info "Обнаружение дистрибутива..."
if   [[ -f /etc/debian_version ]]; then PKG_MGR="apt"
elif [[ -f /etc/redhat-release ]];  then PKG_MGR="yum"
else die "Неподдерживаемый дистрибутив. Нужен Debian 11+/12 или Ubuntu 22.04+."
fi
ok "Пакетный менеджер: $PKG_MGR"

# ──────────────────────────────────────────────────────────────────────────────
# 1. Системные пакеты
# ──────────────────────────────────────────────────────────────────────────────
info "Шаг 1/9 — Обновление пакетов и установка зависимостей..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
    ca-certificates curl gnupg lsb-release \
    certbot ufw net-tools iproute2
ok "Пакеты установлены."

# ──────────────────────────────────────────────────────────────────────────────
# 2. Docker
# ──────────────────────────────────────────────────────────────────────────────
info "Шаг 2/9 — Установка Docker..."
if command -v docker &>/dev/null; then
    warn "Docker уже установлен: $(docker --version)"
else
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/$(. /etc/os-release && echo "$ID")/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
      https://download.docker.com/linux/$(. /etc/os-release && echo "$ID") \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
    systemctl enable --now docker
    ok "Docker установлен: $(docker --version)"
fi

# ──────────────────────────────────────────────────────────────────────────────
# 3. Swap
# ──────────────────────────────────────────────────────────────────────────────
info "Шаг 3/9 — Проверка swap..."
if swapon --show | grep -q /; then
    warn "Swap уже существует, пропускаем."
else
    fallocate -l 2G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    ok "Swap 2G создан и активирован."
fi

# ──────────────────────────────────────────────────────────────────────────────
# 4. Sysctl-тюнинг
# ──────────────────────────────────────────────────────────────────────────────
info "Шаг 4/9 — Применение sysctl-тюнинга..."
cat > /etc/sysctl.d/99-xray-cdn.conf <<'SYSCTL'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_max_tw_buckets = 65536
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.netfilter.nf_conntrack_max = 1048576
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
SYSCTL
sysctl --system -q
ok "Sysctl применён (BBR, conntrack 1M, somaxconn 64k)."

# ──────────────────────────────────────────────────────────────────────────────
# 5. Директория ноды + конфиги
# ──────────────────────────────────────────────────────────────────────────────
info "Шаг 5/9 — Создание конфигов в /opt/remnanode..."
WORKDIR=/opt/remnanode
mkdir -p "$WORKDIR/logs/xray"
TS=$(date +%Y%m%d_%H%M%S)

# ── docker-compose.yml ────────────────────────────────────────────────────────
[[ -f "$WORKDIR/docker-compose.yml" ]] && cp "$WORKDIR/docker-compose.yml" "$WORKDIR/docker-compose.yml.bak.$TS"
cat > "$WORKDIR/docker-compose.yml" <<EOF
services:
  remnanode:
    image: remnawave/node:latest
    container_name: remnanode
    network_mode: host
    restart: always
    cap_add:
      - NET_ADMIN
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
      memlock:
        soft: -1
        hard: -1
    environment:
      - NODE_PORT=${NODE_PORT}
      - SECRET_KEY=${SECRET_KEY}
      - PANEL_URL=${PANEL_URL}
      - GOMEMLIMIT=3072MiB
      - GOGC=75
      - XRAY_VMESS_AEAD_FORCED=false
    volumes:
      - ./logs/xray:/var/log/xray
      - /dev/shm:/dev/shm

  nginx:
    image: nginx:latest
    container_name: nginx
    network_mode: host
    restart: always
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
      - /etc/letsencrypt:/etc/letsencrypt:ro
      - /var/www/letsencrypt:/var/www/letsencrypt:ro
EOF

# ── nginx.conf ────────────────────────────────────────────────────────────────
[[ -f "$WORKDIR/nginx.conf" ]] && cp "$WORKDIR/nginx.conf" "$WORKDIR/nginx.conf.bak.$TS"

# Определяем синтаксис http2 (старый nginx не поддерживает `http2 on;`)
NGINX_IMG_VERSION=$(docker run --rm nginx:latest nginx -v 2>&1 | grep -oP '[\d.]+' | head -1 || echo "1.25")
NGINX_MAJOR=$(echo "$NGINX_IMG_VERSION" | cut -d. -f1)
NGINX_MINOR=$(echo "$NGINX_IMG_VERSION" | cut -d. -f2)
if [[ "$NGINX_MAJOR" -gt 1 ]] || [[ "$NGINX_MAJOR" -eq 1 && "$NGINX_MINOR" -ge 25 ]]; then
    LISTEN_SSL="listen 443 ssl reuseport;"
    HTTP2_DIRECTIVE="        http2 on;"
else
    LISTEN_SSL="listen 443 ssl http2 reuseport;"
    HTTP2_DIRECTIVE=""
fi

cat > "$WORKDIR/nginx.conf" <<EOF
worker_processes auto;
pid /var/run/nginx.pid;
error_log /var/log/nginx/error.log warn;

events {
    worker_connections 65535;
    multi_accept on;
    use epoll;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    sendfile on;
    tcp_nopush on;
    ssl_protocols TLSv1.2 TLSv1.3;
    gzip off;
    keepalive_timeout 3600s;
    keepalive_requests 10000;
    access_log off;

    # Большие GET URL под XHTTP packet-up payload
    large_client_header_buffers 8 128k;
    client_header_buffer_size 64k;
    client_body_buffer_size 64k;

    upstream xray_backend {
        server 127.0.0.1:10085;
        keepalive 512;
        keepalive_requests 100000;
        keepalive_timeout 60s;
    }

    # HTTP — redirect + ACME challenge
    server {
        listen 80;
        listen [::]:80;
        server_name ${DOMAIN};
        location /.well-known/acme-challenge/ {
            root /var/www/letsencrypt;
        }
        location / { return 301 https://\$host\$request_uri; }
    }

    server {
        ${LISTEN_SSL}
        listen [::]:443 ssl;
${HTTP2_DIRECTIVE}
        server_name ${DOMAIN};
        ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
        client_max_body_size 0;

        location / {
            proxy_pass http://xray_backend;
            proxy_http_version 1.1;
            proxy_set_header Connection "";
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto https;
            proxy_buffering off;
            proxy_buffer_size 64k;
            proxy_buffers 16 64k;
            proxy_busy_buffers_size 128k;
            proxy_request_buffering off;
            proxy_cache off;
            proxy_read_timeout 3600s;
            proxy_send_timeout 3600s;
            send_timeout 3600s;
            add_header Cache-Control "no-store" always;
            add_header X-Accel-Expires "0" always;
        }
    }
}
EOF
ok "Конфиги docker-compose.yml и nginx.conf записаны."

# ──────────────────────────────────────────────────────────────────────────────
# 6. Firewall
# ──────────────────────────────────────────────────────────────────────────────
info "Шаг 6/9 — Настройка firewall (ufw)..."
ufw allow 22/tcp  comment "SSH"     2>/dev/null || true
ufw allow 80/tcp  comment "HTTP"    2>/dev/null || true
ufw allow 443/tcp comment "HTTPS"   2>/dev/null || true
ufw allow "${NODE_PORT}/tcp" comment "Remnawave NODE_PORT" 2>/dev/null || true
ufw --force enable 2>/dev/null || true
ok "ufw настроен: 22, 80, 443, ${NODE_PORT} открыты."

# ──────────────────────────────────────────────────────────────────────────────
# 7. Let's Encrypt — получение сертификата (standalone)
# ──────────────────────────────────────────────────────────────────────────────
info "Шаг 7/9 — Получение Let's Encrypt сертификата (standalone)..."
mkdir -p /var/www/letsencrypt

# Убеждаемся, что 80 порт свободен
if ss -tlnp 'sport = :80' | grep -q LISTEN; then
    warn "Порт 80 занят, пытаемся освободить..."
    docker stop nginx 2>/dev/null || true
fi

certbot certonly \
    --standalone \
    --non-interactive \
    --agree-tos \
    --register-unsafely-without-email \
    -d "$DOMAIN"
ok "Сертификат получен для $DOMAIN."

# ── Настройка автообновления через webroot ────────────────────────────────────
RENEWAL_CONF="/etc/letsencrypt/renewal/${DOMAIN}.conf"
if [[ -f "$RENEWAL_CONF" ]]; then
    # Переключаем с standalone на webroot
    sed -i 's/^authenticator = standalone/authenticator = webroot/' "$RENEWAL_CONF"
    # Добавляем webroot_path если нет
    grep -q 'webroot_path' "$RENEWAL_CONF" || \
        echo "webroot_path = /var/www/letsencrypt," >> "$RENEWAL_CONF"
    grep -q '\[\[webroot_map\]\]' "$RENEWAL_CONF" || \
        printf '[[webroot_map]]\n%s = /var/www/letsencrypt\n' "$DOMAIN" >> "$RENEWAL_CONF"
fi

# ── Deploy-hook для reload nginx в docker ─────────────────────────────────────
HOOK_DIR="/etc/letsencrypt/renewal-hooks/deploy"
mkdir -p "$HOOK_DIR"
cat > "$HOOK_DIR/reload-docker-nginx.sh" <<'HOOK'
#!/bin/sh
docker exec nginx nginx -s reload >/dev/null 2>&1 || true
HOOK
chmod +x "$HOOK_DIR/reload-docker-nginx.sh"
ok "Auto-renew webroot и deploy-hook настроены."

# ──────────────────────────────────────────────────────────────────────────────
# 8. Запуск контейнеров
# ──────────────────────────────────────────────────────────────────────────────
info "Шаг 8/9 — Запуск docker compose..."
cd "$WORKDIR"
docker compose pull -q
docker compose up -d
ok "Контейнеры запущены."

# ──────────────────────────────────────────────────────────────────────────────
# 9. Smoke-test + dry-run renew
# ──────────────────────────────────────────────────────────────────────────────
info "Шаг 9/9 — Smoke-test..."
sleep 5

HTTP_CODE=$(curl -kso /dev/null -m 10 -w '%{http_code}' "https://${DOMAIN}/" || echo "000")
SERVER_HDR=$(curl -kso /dev/null -m 10 -w '%header{server}' "https://${DOMAIN}/" || echo "unknown")

if [[ "$HTTP_CODE" == "400" ]]; then
    ok "Smoke-test: HTTP=${HTTP_CODE} server=${SERVER_HDR} — XHTTP inbound отвечает корректно."
else
    warn "Smoke-test: HTTP=${HTTP_CODE} server=${SERVER_HDR} — ожидалось 400. Проверьте логи ниже."
    docker logs nginx --tail 20
    docker logs remnanode --tail 20
fi

info "Dry-run проверка certbot..."
certbot renew --dry-run --cert-name "$DOMAIN" -q && \
    ok "certbot dry-run: успешно." || \
    warn "certbot dry-run завершился с ошибкой — проверьте вручную."

# ──────────────────────────────────────────────────────────────────────────────
# Итог
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Установка завершена!${NC}"
echo -e "${GREEN}══════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  Домен ноды  : ${CYAN}https://${DOMAIN}/${NC}"
echo -e "  NODE_PORT   : ${CYAN}${NODE_PORT}${NC}"
echo -e "  PANEL_URL   : ${CYAN}${PANEL_URL}${NC}"
echo -e "  Конфиги     : ${CYAN}/opt/remnanode/${NC}"
echo ""
echo -e "  Следующие шаги:"
echo -e "  1. В Timeweb CDN создайте PullZone с origin = ${DOMAIN}:443 (HTTPS)"
echo -e "     Выключите: HTTP/3, кэширование, gzip, оптимизацию больших файлов"
echo -e "  2. В Remnawave-панели настройте inbound XHTTP:"
echo -e "     mode=packet-up, uplinkHTTPMethod=GET"
echo -e "  3. В host-block Remnawave укажите CDN-домен (xxxxx.cdn.twcstorage.ru)"
echo ""
echo -e "  Полезные команды:"
echo -e "  ${YELLOW}docker logs remnanode --tail 50${NC}   — логи ноды"
echo -e "  ${YELLOW}docker logs nginx --tail 50${NC}       — логи nginx"
echo -e "  ${YELLOW}cd /opt/remnanode && docker compose restart${NC}"
echo ""
