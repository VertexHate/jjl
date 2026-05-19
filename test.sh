#!/bin/bash

# ═══════════════════════════════════════════════════════════
#  RemnaWave XHTTP + HTTP/3 — Диагностический скрипт
# ═══════════════════════════════════════════════════════════

DOMAIN="${1:-auto}"
INBOUND_PORT="10085"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${CYAN}"
echo "╔════════════════════════════════════════════════════════╗"
echo "║   RemnaWave XHTTP CDN — Диагностика                    ║"
echo "╚════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# ── Автоопределение домена ──
if [[ "$DOMAIN" == "auto" ]]; then
    if [[ -d /etc/nginx/conf.d ]]; then
        for conf in /etc/nginx/conf.d/*.conf; do
            [[ -f "$conf" ]] || continue
            if ! grep -q "listen.*443" "$conf"; then continue; fi
            domain=$(grep -E "^\s*server_name\s+" "$conf" \
                | grep -v "server_name\s*_" \
                | grep -v "server_name\s*localhost" \
                | awk '{print $2}' | tr -d ';' | head -1)
            if [[ -n "$domain" ]]; then
                DOMAIN="$domain"
                break
            fi
        done
    fi

    if [[ "$DOMAIN" == "auto" ]]; then
        echo -e "${YELLOW}Не удалось автоопределить домен из /etc/nginx/conf.d/*.conf${NC}"
        echo -e "${YELLOW}Запустите скрипт с указанием домена:${NC}"
        echo -e "${CYAN}  bash check-node.sh your-domain.com${NC}"
        echo ""
        DOMAIN="NOT_DETECTED"
    else
        echo -e "${GREEN}Автоопределён домен: ${CYAN}$DOMAIN${NC}"
        echo ""
    fi
fi

# ═══════════════════════════════════════════════════════════
# Функция: красивый раздел
# ═══════════════════════════════════════════════════════════
section() {
    echo ""
    echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${CYAN}  $1${NC}"
    echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

subsection() {
    echo ""
    echo -e "${BOLD}${YELLOW}▶ $1${NC}"
}

ok() {
    echo -e "  ${GREEN}✔${NC} $1"
}

warn() {
    echo -e "  ${YELLOW}⚠${NC} $1"
}

err() {
    echo -e "  ${RED}✗${NC} $1"
}

info() {
    echo -e "  ${CYAN}→${NC} $1"
}

# ═══════════════════════════════════════════════════════════
# 1. Информация о системе
# ═══════════════════════════════════════════════════════════
section "1. СИСТЕМА"

subsection "Hostname & OS"
hostnamectl 2>/dev/null || uname -a

subsection "Kernel"
uname -r

subsection "Uptime"
uptime

subsection "CPU"
lscpu | grep -E "^Model name|^CPU\(s\):|^Thread" || nproc

subsection "RAM"
free -h | grep -E "Mem:|Swap:"

subsection "Disk"
df -h / | tail -1

subsection "/etc/os-release"
cat /etc/os-release 2>/dev/null || echo "N/A"

# ═══════════════════════════════════════════════════════════
# 2. Nginx
# ═══════════════════════════════════════════════════════════
section "2. NGINX"

subsection "Версия nginx"
if command -v nginx &>/dev/null; then
    NGINX_VERSION=$(nginx -v 2>&1 | grep -oP '\d+\.\d+\.\d+' || echo "unknown")
    nginx -v 2>&1
    ok "Версия: $NGINX_VERSION"
else
    err "nginx не установлен"
    NGINX_VERSION="NOT_INSTALLED"
fi

subsection "Сборка nginx"
if command -v nginx &>/dev/null; then
    NGINX_BUILD=$(nginx -V 2>&1)
    echo "$NGINX_BUILD"

    # Проверка HTTP/3
    if echo "$NGINX_BUILD" | grep -q "http_v3_module"; then
        ok "HTTP/3 поддерживается (http_v3_module найден)"
        HTTP3_SUPPORT=true
    elif echo "$NGINX_BUILD" | grep -qiE "with-http_v3|quic"; then
        ok "HTTP/3 поддерживается (QUIC флаг найден)"
        HTTP3_SUPPORT=true
    else
        err "HTTP/3 НЕ поддерживается (http_v3_module не найден)"
        HTTP3_SUPPORT=false
    fi

    # Проверка HTTP/2
    if echo "$NGINX_BUILD" | grep -q "http_v2_module"; then
        ok "HTTP/2 поддерживается"
    else
        warn "HTTP/2 может не поддерживаться"
    fi

    # Проверка SSL
    if echo "$NGINX_BUILD" | grep -q "http_ssl_module"; then
        ok "SSL поддерживается"
    else
        err "SSL НЕ поддерживается"
    fi
else
    warn "nginx не установлен, проверка сборки невозможна"
    HTTP3_SUPPORT=false
fi

subsection "Статус nginx"
if systemctl is-active --quiet nginx 2>/dev/null; then
    ok "nginx запущен"
    NGINX_RUNNING=true
else
    err "nginx НЕ запущен"
    NGINX_RUNNING=false
fi

if systemctl is-enabled --quiet nginx 2>/dev/null; then
    ok "nginx в автозапуске"
else
    warn "nginx НЕ в автозапуске"
fi

subsection "Проверка конфига nginx"
if command -v nginx &>/dev/null; then
    if nginx -t 2>&1; then
        ok "Конфиг валиден"
    else
        err "Конфиг содержит ошибки!"
    fi
else
    warn "nginx не установлен"
fi

subsection "PID и лимиты nginx"
if [[ -f /run/nginx.pid ]]; then
    NGINX_PID=$(cat /run/nginx.pid)
    info "PID: $NGINX_PID"
    
    OPEN_FILES=$(cat /proc/$NGINX_PID/limits 2>/dev/null | grep "open files" | awk '{print $4 " (soft) / " $5 " (hard)"}')
    info "Open files limit: $OPEN_FILES"
else
    warn "nginx PID файл не найден (возможно, nginx не запущен)"
fi

subsection "systemd LimitNOFILE"
if systemctl show nginx -p LimitNOFILE 2>/dev/null | grep -q "LimitNOFILE"; then
    LIMIT_NOFILE=$(systemctl show nginx -p LimitNOFILE 2>/dev/null)
    info "$LIMIT_NOFILE"
else
    warn "systemd LimitNOFILE не задан"
fi

# ═══════════════════════════════════════════════════════════
# 3. Конфигурация nginx
# ═══════════════════════════════════════════════════════════
section "3. КОНФИГУРАЦИЯ NGINX"

subsection "Основной конфиг nginx.conf"
if [[ -f /etc/nginx/nginx.conf ]]; then
    grep -E "worker_processes|worker_rlimit_nofile|worker_connections|use epoll|multi_accept" /etc/nginx/nginx.conf | grep -v "^#"
else
    warn "/etc/nginx/nginx.conf не найден"
fi

subsection "Server блоки на порту 443"
if [[ -d /etc/nginx/conf.d ]]; then
    FOUND_443=false
    for conf in /etc/nginx/conf.d/*.conf; do
        [[ -f "$conf" ]] || continue
        if grep -q "listen.*443" "$conf"; then
            FOUND_443=true
            info "Файл: $conf"
            grep -nE "listen .*443|server_name|http2|http3|quic|Alt-Svc|proxy_pass|ssl_certificate" "$conf" | head -20
        fi
    done
    
    if ! $FOUND_443; then
        warn "Не найдено конфигов с портом 443"
    fi
else
    warn "/etc/nginx/conf.d не существует"
fi

subsection "Критические директивы для XHTTP + HTTP/3"
if [[ -d /etc/nginx ]]; then
    echo ""
    info "Проверка listen 443 quic:"
    grep -rn "listen.*443.*quic" /etc/nginx 2>/dev/null | head -5 || warn "  Не найдено 'listen 443 quic'"
    
    echo ""
    info "Проверка http3 on:"
    grep -rn "http3.*on" /etc/nginx 2>/dev/null | head -5 || warn "  Не найдено 'http3 on'"
    
    echo ""
    info "Проверка Alt-Svc:"
    grep -rn "Alt-Svc" /etc/nginx 2>/dev/null | head -5 || warn "  Не найдено 'Alt-Svc'"
    
    echo ""
    info "Проверка proxy_pass к inbound:"
    grep -rn "proxy_pass.*127.0.0.1:$INBOUND_PORT" /etc/nginx 2>/dev/null | head -5 || warn "  Не найдено 'proxy_pass http://127.0.0.1:$INBOUND_PORT'"
    
    echo ""
    info "Проверка WebSocket/XHTTP upgrade:"
    grep -rn "Upgrade.*http_upgrade" /etc/nginx 2>/dev/null | head -5 || warn "  Не найдено 'Upgrade \$http_upgrade'"
    grep -rn "Connection.*connection_upgrade" /etc/nginx 2>/dev/null | head -5 || warn "  Не найдено 'Connection \$connection_upgrade'"
    
    echo ""
    info "Проверка map \$connection_upgrade:"
    grep -rn "map.*http_upgrade.*connection_upgrade" /etc/nginx 2>/dev/null | head -5 || warn "  Не найдено 'map \$http_upgrade \$connection_upgrade'"
else
    warn "/etc/nginx не существует"
fi

# ═══════════════════════════════════════════════════════════
# 4. Сетевые порты
# ═══════════════════════════════════════════════════════════
section "4. СЕТЕВЫЕ ПОРТЫ"

subsection "Все слушающие порты (TCP + UDP)"
ss -lntup 2>/dev/null | grep -E "LISTEN|UDP" | head -30 || netstat -lntup | head -30

subsection "Критичные порты для работы"
echo ""
info "Порт 80 (HTTP):"
if ss -lntp 2>/dev/null | grep -q ":80 "; then
    ok "Порт 80 слушает"
    ss -lntp | grep ":80 "
else
    warn "Порт 80 НЕ слушает"
fi

echo ""
info "Порт 443 TCP (HTTPS / HTTP/2):"
if ss -lntp 2>/dev/null | grep -q ":443 "; then
    ok "Порт 443 TCP слушает"
    ss -lntp | grep ":443 "
else
    err "Порт 443 TCP НЕ слушает — HTTPS не работает!"
fi

echo ""
info "Порт 443 UDP (HTTP/3 / QUIC):"
if ss -lunp 2>/dev/null | grep -q ":443 "; then
    ok "Порт 443 UDP слушает — HTTP/3 возможен"
    ss -lunp | grep ":443 "
    UDP_443_LISTEN=true
else
    err "Порт 443 UDP НЕ слушает — HTTP/3 НЕ работает!"
    UDP_443_LISTEN=false
fi

echo ""
info "Порт $INBOUND_PORT (backend / remnanode):"
if ss -lntp 2>/dev/null | grep -q ":$INBOUND_PORT "; then
    ok "Порт $INBOUND_PORT слушает"
    ss -lntp | grep ":$INBOUND_PORT "
    BACKEND_LISTEN=true
else
    err "Порт $INBOUND_PORT НЕ слушает — backend не работает!"
    BACKEND_LISTEN=false
fi

# ═══════════════════════════════════════════════════════════
# 5. SSL сертификаты
# ═══════════════════════════════════════════════════════════
section "5. SSL СЕРТИФИКАТЫ"

if [[ "$DOMAIN" != "NOT_DETECTED" ]]; then
    CERT_PATH="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
    
    subsection "Сертификат для домена: $DOMAIN"
    if [[ -f "$CERT_PATH" ]]; then
        ok "Сертификат найден: $CERT_PATH"
        
        EXPIRY=$(openssl x509 -enddate -noout -in "$CERT_PATH" | cut -d= -f2)
        info "Срок действия до: $EXPIRY"
        
        EXPIRY_EPOCH=$(date -d "$EXPIRY" +%s 2>/dev/null || echo "0")
        NOW_EPOCH=$(date +%s)
        DAYS_LEFT=$(( (EXPIRY_EPOCH - NOW_EPOCH) / 86400 ))
        
        if [[ $DAYS_LEFT -gt 30 ]]; then
            ok "Сертификат актуален ($DAYS_LEFT дней до истечения)"
        elif [[ $DAYS_LEFT -gt 0 ]]; then
            warn "Сертификат истекает через $DAYS_LEFT дней — нужно обновить!"
        else
            err "Сертификат ИСТЁК!"
        fi
        
        info "Детали сертификата:"
        openssl x509 -in "$CERT_PATH" -noout -subject -issuer -dates
    else
        err "Сертификат НЕ найден для домена $DOMAIN"
    fi
else
    warn "Домен не определён, проверка сертификата пропущена"
fi

subsection "Список всех доменов с сертификатами Let's Encrypt"
if [[ -d /etc/letsencrypt/live ]]; then
    ls -1 /etc/letsencrypt/live/ 2>/dev/null || warn "Нет сертификатов"
else
    warn "/etc/letsencrypt/live не существует"
fi

# ═══════════════════════════════════════════════════════════
# 6. Backend (remnanode / docker)
# ═══════════════════════════════════════════════════════════
section "6. BACKEND (REMNANODE / DOCKER)"

subsection "Статус Docker"
if systemctl is-active --quiet docker 2>/dev/null; then
    ok "Docker запущен"
else
    err "Docker НЕ запущен"
fi

subsection "Контейнеры Docker"
if command -v docker &>/dev/null; then
    docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null || warn "Ошибка получения списка контейнеров"
else
    warn "Docker не установлен"
fi

subsection "Контейнер remnanode"
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "remnanode"; then
    ok "remnanode запущен"
    REMNA_STATUS=$(docker ps --filter "name=remnanode" --format 'table {{.Status}}\t{{.Ports}}')
    echo "$REMNA_STATUS"
    REMNANODE_RUNNING=true
else
    err "remnanode НЕ запущен"
    REMNANODE_RUNNING=false
fi

subsection "Логи remnanode (последние 30 строк)"
if [[ "$REMNANODE_RUNNING" == "true" ]]; then
    docker logs --tail 30 remnanode 2>&1
else
    warn "remnanode не запущен, логи недоступны"
fi

subsection "Проверка доступности backend напрямую"
if [[ "$BACKEND_LISTEN" == "true" ]]; then
    info "Тест: curl http://127.0.0.1:$INBOUND_PORT/"
    BACKEND_RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 http://127.0.0.1:$INBOUND_PORT/ 2>/dev/null || echo "FAIL")
    
    if [[ "$BACKEND_RESPONSE" =~ ^[0-9]+$ ]]; then
        ok "Backend отвечает (HTTP код: $BACKEND_RESPONSE)"
    else
        err "Backend НЕ отвечает (timeout или connection refused)"
    fi
else
    warn "Backend не слушает порт $INBOUND_PORT, тест пропущен"
fi

# ═══════════════════════════════════════════════════════════
# 7. Sysctl параметры
# ═══════════════════════════════════════════════════════════
section "7. SYSCTL (KERNEL PARAMETERS)"

subsection "TCP Congestion Control"
sysctl net.ipv4.tcp_congestion_control 2>/dev/null || warn "Не удалось получить tcp_congestion_control"

if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q "bbr"; then
    ok "BBR включён"
else
    warn "BBR НЕ включён (используется $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo 'unknown'))"
fi

subsection "Queue discipline"
sysctl net.core.default_qdisc 2>/dev/null || warn "Не удалось получить default_qdisc"

subsection "Сетевые буферы (критично для HTTP/3 / QUIC)"
sysctl \
    net.core.rmem_max \
    net.core.wmem_max \
    net.core.rmem_default \
    net.core.wmem_default 2>/dev/null || warn "Не удалось получить параметры буферов"

RMEM_MAX=$(sysctl -n net.core.rmem_max 2>/dev/null || echo "0")
WMEM_MAX=$(sysctl -n net.core.wmem_max 2>/dev/null || echo "0")

if [[ "$RMEM_MAX" -ge 67108864 && "$WMEM_MAX" -ge 67108864 ]]; then
    ok "Буферы >= 64MB (хорошо для QUIC)"
elif [[ "$RMEM_MAX" -ge 16777216 && "$WMEM_MAX" -ge 16777216 ]]; then
    warn "Буферы >= 16MB (приемлемо, но лучше 64MB для QUIC)"
else
    err "Буферы < 16MB (плохо для QUIC, увеличьте rmem_max / wmem_max)"
fi

subsection "TCP параметры"
sysctl \
    net.core.somaxconn \
    net.ipv4.tcp_max_syn_backlog \
    net.core.netdev_max_backlog \
    net.ipv4.tcp_fastopen \
    net.ipv4.tcp_tw_reuse \
    net.ipv4.tcp_fin_timeout \
    net.ipv4.tcp_keepalive_time \
    net.ipv4.tcp_keepalive_intvl \
    net.ipv4.tcp_keepalive_probes \
    net.ipv4.tcp_mtu_probing 2>/dev/null || warn "Не удалось получить TCP параметры"

subsection "Все параметры из /etc/sysctl.d/"
if [[ -d /etc/sysctl.d ]]; then
    for f in /etc/sysctl.d/*.conf; do
        [[ -f "$f" ]] || continue
        info "Файл: $f"
        cat "$f" | grep -v "^#" | grep -v "^$"
    done
else
    warn "/etc/sysctl.d не существует"
fi

# ═══════════════════════════════════════════════════════════
# 8. Firewall
# ═══════════════════════════════════════════════════════════
section "8. FIREWALL"

subsection "UFW"
if command -v ufw &>/dev/null; then
    if ufw status 2>/dev/null | grep -q "Status: active"; then
        ok "UFW активен"
        ufw status verbose
        
        if ufw status | grep -q "443/tcp"; then
            ok "TCP 443 открыт в UFW"
        else
            err "TCP 443 НЕ открыт в UFW"
        fi
        
        if ufw status | grep -q "443/udp"; then
            ok "UDP 443 открыт в UFW (HTTP/3 разрешён)"
        else
            err "UDP 443 НЕ открыт в UFW (HTTP/3 заблокирован!)"
        fi
    else
        info "UFW не активен"
    fi
else
    info "UFW не установлен"
fi

subsection "iptables"
if command -v iptables &>/dev/null; then
    info "Правила iptables INPUT:"
    iptables -S INPUT 2>/dev/null | grep -E "443|80|$INBOUND_PORT" || info "Нет правил для портов 80/443/$INBOUND_PORT"
else
    warn "iptables не установлен"
fi

subsection "nftables"
if command -v nft &>/dev/null; then
    info "Правила nftables:"
    nft list ruleset 2>/dev/null | grep -E "443|80" | head -20 || info "Нет правил nftables"
else
    info "nftables не установлен"
fi

subsection "firewalld"
if command -v firewall-cmd &>/dev/null; then
    if firewall-cmd --state 2>/dev/null | grep -q "running"; then
        ok "firewalld активен"
        firewall-cmd --list-all
        
        if firewall-cmd --list-ports 2>/dev/null | grep -q "443/tcp"; then
            ok "TCP 443 открыт в firewalld"
        else
            err "TCP 443 НЕ открыт в firewalld"
        fi
        
        if firewall-cmd --list-ports 2>/dev/null | grep -q "443/udp"; then
            ok "UDP 443 открыт в firewalld"
        else
            err "UDP 443 НЕ открыт в firewalld"
        fi
    else
        info "firewalld не активен"
    fi
else
    info "firewalld не установлен"
fi

# ═══════════════════════════════════════════════════════════
# 9. Тесты HTTP/2 и HTTP/3
# ═══════════════════════════════════════════════════════════
section "9. ТЕСТЫ HTTP/2 И HTTP/3"

if [[ "$DOMAIN" == "NOT_DETECTED" ]]; then
    warn "Домен не определён, пропускаем тесты HTTP"
else
    subsection "Проверка curl версии и поддержки HTTP/3"
    if command -v curl &>/dev/null; then
        curl -V | head -3
        
        if curl -V | grep -qi "http3"; then
            ok "Локальный curl поддерживает HTTP/3"
            CURL_HTTP3=true
        else
            warn "Локальный curl НЕ поддерживает HTTP/3 (нужна специальная сборка)"
            CURL_HTTP3=false
        fi
    else
        warn "curl не установлен"
        CURL_HTTP3=false
    fi

    subsection "Тест HTTP/2 (локально через 127.0.0.1)"
    if [[ "$NGINX_RUNNING" == "true" ]]; then
        info "curl -kI --http2 --resolve $DOMAIN:443:127.0.0.1 https://$DOMAIN/"
        HTTP2_TEST=$(curl -kI --http2 --max-time 5 --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/" 2>&1)
        echo "$HTTP2_TEST"
        
        if echo "$HTTP2_TEST" | grep -qi "HTTP/2"; then
            ok "HTTP/2 работает локально"
        else
            err "HTTP/2 НЕ работает локально"
        fi
    else
        warn "nginx не запущен, тест пропущен"
    fi

    subsection "Тест HTTP/3 (локально через 127.0.0.1)"
    if [[ "$HTTP3_SUPPORT" == "true" && "$UDP_443_LISTEN" == "true" && "$NGINX_RUNNING" == "true" ]]; then
        if [[ "$CURL_HTTP3" == "true" ]]; then
            info "curl -kI --http3-only --resolve $DOMAIN:443:127.0.0.1 https://$DOMAIN/"
            HTTP3_TEST=$(curl -kI --http3-only --max-time 5 --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/" 2>&1)
            echo "$HTTP3_TEST"
            
            if echo "$HTTP3_TEST" | grep -qi "HTTP/3"; then
                ok "HTTP/3 работает локально!"
            else
                err "HTTP/3 НЕ работает локально (но настроен)"
            fi
        else
            warn "Локальный curl без HTTP/3, используем docker образ с поддержкой HTTP/3"
            
            if command -v docker &>/dev/null; then
                info "docker run ghcr.io/curl/curl:latest --http3-only -kI https://$DOMAIN/"
                HTTP3_DOCKER=$(docker run --rm ghcr.io/curl/curl:latest --http3-only -kI --max-time 5 "https://$DOMAIN/" 2>&1)
                echo "$HTTP3_DOCKER"
                
                if echo "$HTTP3_DOCKER" | grep -qi "HTTP/3"; then
                    ok "HTTP/3 работает (проверено через docker curl)!"
                else
                    err "HTTP/3 НЕ работает"
                fi
            else
                warn "Docker не установлен, HTTP/3 тест пропущен"
            fi
        fi
    else
        warn "HTTP/3 не может работать (причины выше), тест пропущен"
    fi

    subsection "Проверка заголовка Alt-Svc (нужен для HTTP/3)"
    if [[ "$NGINX_RUNNING" == "true" ]]; then
        info "curl -skI https://$DOMAIN/ | grep -i alt-svc"
        ALT_SVC=$(curl -skI --max-time 5 --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/" 2>/dev/null | grep -i "alt-svc")
        
        if [[ -n "$ALT_SVC" ]]; then
            ok "Заголовок Alt-Svc найден:"
            echo "$ALT_SVC"
        else
            err "Заголовок Alt-Svc НЕ найден — браузеры не узнают что есть HTTP/3"
        fi
    else
        warn "nginx не запущен, тест пропущен"
    fi
fi

# ═══════════════════════════════════════════════════════════
# 10. MTU и сетевые интерфейсы
# ═══════════════════════════════════════════════════════════
section "10. СЕТЬ (MTU, МАРШРУТЫ, ИНТЕРФЕЙСЫ)"

subsection "Сетевые интерфейсы"
ip -br link show

subsection "MTU интерфейсов"
ip link show | grep -E "^[0-9]+:|mtu"

subsection "Маршруты"
ip route show

subsection "Тест MTU (ping с Don't Fragment)"
info "ping -M do -s 1472 -c 2 1.1.1.1 (проверка MTU 1500)"
if ping -M do -s 1472 -c 2 1.1.1.1 &>/dev/null; then
    ok "MTU 1500 проходит без фрагментации"
else
    warn "MTU 1500 НЕ проходит — возможна проблема с Path MTU Discovery для QUIC"
    
    info "ping -M do -s 1400 -c 2 1.1.1.1 (проверка MTU 1428)"
    if ping -M do -s 1400 -c 2 1.1.1.1 &>/dev/null; then
        warn "MTU 1428 проходит — используется урезанный MTU"
    else
        err "Даже MTU 1428 не проходит — серьёзные проблемы с сетью"
    fi
fi

# ═══════════════════════════════════════════════════════════
# 11. Итоговая сводка
# ═══════════════════════════════════════════════════════════
section "11. ИТОГОВАЯ СВОДКА"

echo ""
echo -e "${BOLD}${CYAN}════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}Компонент                    Статус${NC}"
echo -e "${BOLD}${CYAN}════════════════════════════════════════════════════════${NC}"

# Nginx
if [[ "$NGINX_RUNNING" == "true" ]]; then
    echo -e "Nginx                        ${GREEN}✔ Запущен${NC}"
else
    echo -e "Nginx                        ${RED}✗ НЕ запущен${NC}"
fi

# HTTP/3 support
if [[ "$HTTP3_SUPPORT" == "true" ]]; then
    echo -e "HTTP/3 модуль                ${GREEN}✔ Доступен${NC}"
else
    echo -e "HTTP/3 модуль                ${RED}✗ Недоступен${NC}"
fi

# TCP 443
if ss -lntp 2>/dev/null | grep -q ":443 "; then
    echo -e "TCP 443 (HTTPS/HTTP2)        ${GREEN}✔ Слушает${NC}"
else
    echo -e "TCP 443 (HTTPS/HTTP2)        ${RED}✗ НЕ слушает${NC}"
fi

# UDP 443
if [[ "$UDP_443_LISTEN" == "true" ]]; then
    echo -e "UDP 443 (HTTP/3)             ${GREEN}✔ Слушает${NC}"
else
    echo -e "UDP 443 (HTTP/3)             ${RED}✗ НЕ слушает${NC}"
fi

# Backend
if [[ "$BACKEND_LISTEN" == "true" ]]; then
    echo -e "Backend (port $INBOUND_PORT)        ${GREEN}✔ Слушает${NC}"
else
    echo -e "Backend (port $INBOUND_PORT)        ${RED}✗ НЕ слушает${NC}"
fi

# remnanode
if [[ "$REMNANODE_RUNNING" == "true" ]]; then
    echo -e "remnanode контейнер          ${GREEN}✔ Запущен${NC}"
else
    echo -e "remnanode контейнер          ${RED}✗ НЕ запущен${NC}"
fi

# BBR
if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q "bbr"; then
    echo -e "BBR congestion control       ${GREEN}✔ Включён${NC}"
else
    echo -e "BBR congestion control       ${YELLOW}⚠ Выключен${NC}"
fi

# Buffers
if [[ "$RMEM_MAX" -ge 67108864 && "$WMEM_MAX" -ge 67108864 ]]; then
    echo -e "UDP/TCP буферы               ${GREEN}✔ >= 64MB${NC}"
elif [[ "$RMEM_MAX" -ge 16777216 && "$WMEM_MAX" -ge 16777216 ]]; then
    echo -e "UDP/TCP буферы               ${YELLOW}⚠ >= 16MB${NC}"
else
    echo -e "UDP/TCP буферы               ${RED}✗ < 16MB${NC}"
fi

echo -e "${BOLD}${CYAN}════════════════════════════════════════════════════════${NC}"
echo ""

# Финальная рекомендация
echo -e "${BOLD}${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${YELLOW}  РЕКОМЕНДАЦИИ${NC}"
echo -e "${BOLD}${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
echo ""

if [[ "$HTTP3_SUPPORT" == "false" ]]; then
    err "Установите nginx с http_v3_module (версия >= 1.25.0 из nginx.org/packages/mainline)"
fi

if [[ "$UDP_443_LISTEN" == "false" ]]; then
    err "UDP 443 не слушает — проверьте конфиг nginx (listen 443 quic)"
fi

if [[ "$BACKEND_LISTEN" == "false" ]]; then
    err "Backend не слушает порт $INBOUND_PORT — проверьте remnanode"
fi

if [[ "$NGINX_RUNNING" == "false" ]]; then
    err "Запустите nginx: systemctl start nginx"
fi

if ! sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q "bbr"; then
    warn "Включите BBR для лучшей производительности"
fi

if [[ "$RMEM_MAX" -lt 67108864 ]]; then
    warn "Увеличьте net.core.rmem_max до 67108864 (64MB) для QUIC"
fi

echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════════════╗"
echo -e "║   Диагностика завершена!                               ║"
echo -e "╚════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${CYAN}Сохраните этот вывод и отправьте для сравнения с другой нодой.${NC}"
echo -e "${CYAN}Команда для сохранения:${NC}"
echo -e "${YELLOW}  bash check-node.sh $DOMAIN > /root/node-diag-\$(hostname).txt${NC}"
echo ""
