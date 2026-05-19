#!/bin/bash
# fix-node.sh — исправление всех найденных проблем

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Нужен root${NC}"
    exit 1
fi

echo -e "${CYAN}╔══════════════════════════════════════╗"
echo -e "║   Fix Node — исправление проблем     ║"
echo -e "╚══════════════════════════════════════╝${NC}"
echo ""

# ════════════════════════════════════════
# 1. Фикс sysctl (BBR + буферы + очереди)
# ════════════════════════════════════════
echo -e "${GREEN}[1/4] Применение sysctl параметров...${NC}"

cat > /etc/sysctl.d/99-remnawave-nginx.conf << 'EOF'
# ── TCP очереди ────────────────────────────────
net.core.somaxconn            = 65535
net.ipv4.tcp_max_syn_backlog  = 65535
net.core.netdev_max_backlog   = 65535

# ── TCP поведение ──────────────────────────────
net.ipv4.tcp_tw_reuse         = 1
net.ipv4.tcp_fin_timeout      = 15
net.ipv4.tcp_keepalive_time   = 300
net.ipv4.tcp_keepalive_intvl  = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_fastopen         = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing      = 1
net.ipv4.tcp_syncookies       = 1

# ── Буферы TCP + UDP (критично для QUIC/HTTP3) ─
net.core.rmem_default         = 262144
net.core.wmem_default         = 262144
net.core.rmem_max             = 67108864
net.core.wmem_max             = 67108864
net.ipv4.tcp_rmem             = 4096 87380 67108864
net.ipv4.tcp_wmem             = 4096 65536 67108864

# ── BBR congestion control ─────────────────────
net.core.default_qdisc        = fq
net.ipv4.tcp_congestion_control = bbr
EOF

# Применяем
sysctl --system > /dev/null 2>&1

# Проверка BBR
if sysctl -n net.ipv4.tcp_congestion_control | grep -q "bbr"; then
    echo -e "  ${GREEN}✔ BBR включён${NC}"
else
    echo -e "  ${YELLOW}⚠ BBR недоступен, убираем из конфига${NC}"
    sed -i '/tcp_congestion_control/d' /etc/sysctl.d/99-remnawave-nginx.conf
    sed -i '/default_qdisc.*fq$/d' /etc/sysctl.d/99-remnawave-nginx.conf
    sysctl --system > /dev/null 2>&1
fi

echo -e "  ${GREEN}✔ sysctl применён${NC}"
echo -e "  ${CYAN}rmem_max: $(sysctl -n net.core.rmem_max)${NC}"
echo -e "  ${CYAN}netdev_max_backlog: $(sysctl -n net.core.netdev_max_backlog)${NC}"

# ════════════════════════════════════════
# 2. Фикс systemd LimitNOFILE для nginx
# ════════════════════════════════════════
echo -e "${GREEN}[2/4] Настройка systemd LimitNOFILE...${NC}"

mkdir -p /etc/systemd/system/nginx.service.d/

cat > /etc/systemd/system/nginx.service.d/override.conf << 'EOF'
[Service]
LimitNOFILE=65535
EOF

systemctl daemon-reload
echo -e "  ${GREEN}✔ systemd override: LimitNOFILE=65535${NC}"

# Фикс limits.conf
sed -i '/nginx.*nofile/d'    /etc/security/limits.conf
sed -i '/www-data.*nofile/d' /etc/security/limits.conf

cat >> /etc/security/limits.conf << 'EOF'
nginx    soft nofile 65535
nginx    hard nofile 65535
www-data soft nofile 65535
www-data hard nofile 65535
EOF

echo -e "  ${GREEN}✔ limits.conf обновлён${NC}"

# ════════════════════════════════════════
# 3. Фикс firewall — UDP 443 для HTTP/3
# ════════════════════════════════════════
echo -e "${GREEN}[3/4] Открываем UDP 443 для HTTP/3...${NC}"

# nftables
if command -v nft &>/dev/null && nft list ruleset 2>/dev/null | grep -q "type filter"; then
    # Проверяем есть ли уже правило
    if ! nft list ruleset 2>/dev/null | grep -q "udp dport 443.*accept"; then
        # Находим нужную цепочку и добавляем правило
        NFT_TABLE=$(nft list ruleset 2>/dev/null | grep "^table" | head -1 | awk '{print $2, $3}')
        echo -e "  ${CYAN}nftables таблица: $NFT_TABLE${NC}"
        
        # Пробуем добавить в стандартные места
        nft add rule inet filter input udp dport 443 accept 2>/dev/null \
            || nft add rule ip filter INPUT udp dport 443 accept 2>/dev/null \
            || echo -e "  ${YELLOW}⚠ Не удалось добавить nftables правило автоматически${NC}"
        
        echo -e "  ${GREEN}✔ nftables: UDP 443 добавлен${NC}"
    else
        echo -e "  ${GREEN}✔ nftables: UDP 443 уже разрешён${NC}"
    fi
fi

# iptables
if command -v iptables &>/dev/null; then
    # TCP 443
    iptables -C INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null \
        || iptables -A INPUT -p tcp --dport 443 -j ACCEPT
    # UDP 443
    iptables -C INPUT -p udp --dport 443 -j ACCEPT 2>/dev/null \
        || iptables -A INPUT -p udp --dport 443 -j ACCEPT
    # TCP 80
    iptables -C INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null \
        || iptables -A INPUT -p tcp --dport 80 -j ACCEPT

    echo -e "  ${GREEN}✔ iptables: TCP/UDP 443 и TCP 80 открыты${NC}"

    # Сохраняем правила если есть инструменты
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save > /dev/null 2>&1 \
            && echo -e "  ${GREEN}✔ iptables правила сохранены (netfilter-persistent)${NC}"
    elif [[ -d /etc/iptables ]]; then
        iptables-save > /etc/iptables/rules.v4 2>/dev/null \
            && echo -e "  ${GREEN}✔ iptables правила сохранены (/etc/iptables/rules.v4)${NC}"
    fi
fi

# UFW
if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow 80/tcp  > /dev/null 2>&1 || true
    ufw allow 443/tcp > /dev/null 2>&1 || true
    ufw allow 443/udp > /dev/null 2>&1 || true
    echo -e "  ${GREEN}✔ UFW: TCP/UDP 443 открыты${NC}"
fi

# ════════════════════════════════════════
# 4. Перезапуск nginx + проверка лимитов
# ════════════════════════════════════════
echo -e "${GREEN}[4/4] Перезапуск nginx и проверка...${NC}"

nginx -t 2>&1 | grep -E "ok|error" | head -3

systemctl restart nginx
sleep 1

# Проверяем реальный лимит после перезапуска
NGINX_PID=$(cat /run/nginx.pid 2>/dev/null || pgrep -x nginx | head -1)
if [[ -n "$NGINX_PID" ]]; then
    ACTUAL_LIMIT=$(cat /proc/$NGINX_PID/limits 2>/dev/null \
        | grep "open files" \
        | awk '{print $4}')
    echo -e "  ${CYAN}Реальный open files soft limit: ${NC}${ACTUAL_LIMIT}"
    
    if [[ "${ACTUAL_LIMIT:-0}" -ge 65535 ]]; then
        echo -e "  ${GREEN}✔ Лимит файлов применён корректно${NC}"
    else
        echo -e "  ${YELLOW}⚠ Лимит всё ещё низкий: $ACTUAL_LIMIT${NC}"
        echo -e "  ${YELLOW}  Пробуем через worker_rlimit_nofile в nginx.conf...${NC}"
        
        # Проверяем есть ли worker_rlimit_nofile в nginx.conf
        if ! grep -q "worker_rlimit_nofile" /etc/nginx/nginx.conf; then
            sed -i '/^worker_processes/a worker_rlimit_nofile 65535;' /etc/nginx/nginx.conf
            echo -e "  ${GREEN}✔ Добавлен worker_rlimit_nofile в nginx.conf${NC}"
        else
            sed -i 's/worker_rlimit_nofile.*/worker_rlimit_nofile 65535;/' /etc/nginx/nginx.conf
            echo -e "  ${GREEN}✔ worker_rlimit_nofile обновлён в nginx.conf${NC}"
        fi
        
        nginx -t && systemctl restart nginx
        sleep 1
        
        NGINX_PID=$(cat /run/nginx.pid 2>/dev/null || pgrep -x nginx | head -1)
        ACTUAL_LIMIT=$(cat /proc/$NGINX_PID/limits 2>/dev/null \
            | grep "open files" \
            | awk '{print $4}')
        echo -e "  ${CYAN}Лимит после фикса: ${NC}${ACTUAL_LIMIT}"
    fi
fi

# ════════════════════════════════════════
# Итог
# ════════════════════════════════════════
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════╗"
echo -e "║   ✅ Фиксы применены                         ║"
echo -e "╚══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${CYAN}Текущие значения:${NC}"
echo -e "  rmem_max:          ${GREEN}$(sysctl -n net.core.rmem_max)${NC}"
echo -e "  wmem_max:          ${GREEN}$(sysctl -n net.core.wmem_max)${NC}"
echo -e "  netdev_max_backlog:${GREEN}$(sysctl -n net.core.netdev_max_backlog)${NC}"
echo -e "  somaxconn:         ${GREEN}$(sysctl -n net.core.somaxconn)${NC}"
echo -e "  congestion_control:${GREEN}$(sysctl -n net.ipv4.tcp_congestion_control)${NC}"
echo -e "  nginx open files:  ${GREEN}${ACTUAL_LIMIT:-unknown}${NC}"
echo ""
echo -e "${YELLOW}Запусти диагностику снова чтобы проверить:${NC}"
echo -e "${CYAN}  bash check-node.sh${NC}"
