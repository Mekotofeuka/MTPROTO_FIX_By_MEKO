#!/bin/bash
# remote_ctl/rules1_node.sh – удалённое управление SYN FIX (iptables/nftables) через SSH
# Использование: ./rules1_node.sh <IP> <USER> <PORT>

# ── Проверка аргументов ──────────────────────────────────────
if [ $# -lt 3 ]; then
    echo "❌ Использование: $0 <IP> <USER> <PORT>"
    exit 1
fi
REMOTE_IP="$1"
REMOTE_USER="$2"
REMOTE_PORT="$3"

ssh_exec() {
    ssh -p "$REMOTE_PORT" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 "$REMOTE_USER@$REMOTE_IP" "$1" 2>/dev/null
}
ssh_interactive() {
    ssh -t -p "$REMOTE_PORT" -o StrictHostKeyChecking=accept-new "$REMOTE_USER@$REMOTE_IP" "$1"
}

# ── Цвета ─────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

pause_key() {
    { : </dev/tty; } 2>/dev/null || return 0
    echo -e "  ${GRAY}${1:-Нажмите любую клавишу}${NC}"
    read -rsn1 </dev/tty || true
}

# ── Логирование ─────────────────────────────────────────────
log_info() { echo -e "  ${BLUE}[i]${NC} $1"; }
log_success() { echo -e "  ${GREEN}[✓]${NC} $1"; }
log_error() { echo -e "  ${RED}[✗]${NC} $1" >&2; }
log_warning() { echo -e "  ${YELLOW}[!]${NC} $1"; }

# ── Файл для хранения порта (на удалённом сервере) ──────────
PORT_FILE="/opt/mtpr-simple/port"

# ── Название кастомной цепочки iptables ─────────────────────
SYNFIX_CHAIN="MTPR_SYNFIX"

# ── u32-фильтр для v3 (используется для явной проверки применения) ──
U32_FILTER="32 & 0x000FFFFF = 0x0002FFFF && 40 & 0xFF000000 = 0x02000000 && 44 & 0xFFFF0000 = 0x01030000 && 48 & 0xFFFFFF00 = 0x01010800 && 60 & 0xFFFFFFFF = 0x04020000"

get_ssh_port() {
    local port
    port=$(ssh_exec "if command -v sshd >/dev/null 2>&1; then timeout 3 sshd -T 2>/dev/null | grep '^port ' | awk '{print \$2}' | head -1; fi")
    if [[ "$port" =~ ^[0-9]+$ ]]; then
        echo "$port"
        return 0
    fi

    port=$(ssh_exec "grep -E '^Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config | head -1 | awk '{print \$2}'")
    if [[ "$port" =~ ^[0-9]+$ ]]; then
        echo "$port"
        return 0
    fi

    port=$(ssh_exec "for cfg in /etc/ssh/sshd_config.d/*.conf; do [ -f \"\$cfg\" ] && grep -E '^Port[[:space:]]+[0-9]+' \"\$cfg\" | head -1 | awk '{print \$2}'; done")
    if [[ "$port" =~ ^[0-9]+$ ]]; then
        echo "$port"
        return 0
    fi

    echo "22"
}

save_port() {
    ssh_exec "echo \"$1\" > \"$PORT_FILE\""
}

# ── Цепочка MTPR_SYNFIX в iptables ───────────────────────────
is_syn_fix_chain_installed() {
    ssh_exec "iptables -L \"$SYNFIX_CHAIN\" -n >/dev/null 2>&1" && return 0 || return 1
}

is_syn_fix_service_running() {
    ssh_exec "systemctl is-active --quiet mtpr-synfix.service" 2>/dev/null && return 0 || return 1
}

get_synfix_status() {
    if is_syn_fix_chain_installed; then
        if is_syn_fix_service_running; then
            echo "active"
        else
            echo "has_chain_only"
        fi
    else
        echo "inactive"
    fi
}

# ── Таблица mtpr_synfix в nftables ───────────────────────────
is_nft_fix_installed() {
    ssh_exec "nft list table inet mtpr_synfix &>/dev/null 2>&1" && return 0 || return 1
}

is_nft_fix_service_running() {
    ssh_exec "systemctl is-active --quiet mtpr-nft-synfix.service 2>/dev/null" && return 0 || return 1
}

get_nft_fix_status() {
    if is_nft_fix_installed; then
        if is_nft_fix_service_running; then
            echo "active"
        else
            echo "has_table_only"
        fi
    else
        echo "inactive"
    fi
}

# ── Получение статуса Zapret2 с удалённого сервера ───────────
get_zapret2_status_remote() {
    # Проверяем наличие zapret2_fix.sh и загружаем его, если нужно
    local has_zapret2
    has_zapret2=$(ssh_exec "[ -f /opt/mtpr-simple/data/zapret2_fix.sh ] && echo 'yes'")
    if [ "$has_zapret2" != "yes" ]; then
        echo -e "${DIM}не установлен${NC}"
        return
    fi

    # Используем ssh_exec для выполнения функции zapret2_status из zapret2_fix.sh
    local status
    status=$(ssh_exec "bash -c 'source /opt/mtpr-simple/data/zapret2_fix.sh 2>/dev/null && zapret2_status'")
    if [ -n "$status" ]; then
        echo "$status"
    else
        echo -e "${YELLOW}недоступно${NC}"
    fi
}

# ── Генерация скрипта применения правил (удалённо) ──────────
generate_apply_script() {
    local fix_type="${1:-new}"
    shift
    local script_content

    if [ "$fix_type" = "old" ]; then
        script_content=$(cat <<'APPLY_SCRIPT_EOF'
#!/bin/bash
set -e

if [ -f /opt/mtpr-simple/port ]; then
    PORTS=$(cat /opt/mtpr-simple/port)
else
    echo "SYN FIX: Файл с портами не найден" >&2
    exit 1
fi

CHAIN="MTPR_SYNFIX"
SSH_PORT=$(sshd -T 2>/dev/null | grep '^port ' | awk '{print $2}'); [ -n "$SSH_PORT" ] || SSH_PORT=22

if ! iptables -C INPUT -p tcp --dport "$SSH_PORT" -j ACCEPT 2>/dev/null; then
    iptables -I INPUT 1 -p tcp --dport "$SSH_PORT" -j ACCEPT
    echo "SSH-доступ (${SSH_PORT}) разрешён"
fi

iptables -t filter -N "$CHAIN" 2>/dev/null || true
iptables -t filter -F "$CHAIN"

if ! iptables -t filter -C INPUT -j "$CHAIN" 2>/dev/null; then
    iptables -t filter -I INPUT 2 -j "$CHAIN"
    echo "Цепочка $CHAIN подключена к INPUT"
fi

IFS=',' read -ra PORT_ARRAY <<< "$PORTS"
for PORT in "${PORT_ARRAY[@]}"; do
    PORT=$(echo "$PORT" | xargs)
    [ -z "$PORT" ] && continue

    iptables -t filter -A "$CHAIN" -p tcp --dport "$PORT" --syn \
        -m tcp --tcp-flags SYN SYN \
        -m length --length 64 \
        -m ttl --ttl-lt 65 \
        -j ACCEPT

    iptables -t filter -A "$CHAIN" -p tcp --dport "$PORT" --syn \
        -m hashlimit \
        --hashlimit-name mtproto_"$PORT" \
        --hashlimit-mode srcip \
        --hashlimit-upto 54/minute \
        --hashlimit-burst 1 \
        --hashlimit-htable-expire 60000 \
        --hashlimit-htable-size 32768 \
        -j ACCEPT

    iptables -t filter -A "$CHAIN" -p tcp --dport "$PORT" --syn \
        -j REJECT --reject-with tcp-reset
done
APPLY_SCRIPT_EOF
)
    else
        script_content=$(cat <<'APPLY_SCRIPT_EOF'
#!/bin/bash
set -e

if [ -f /opt/mtpr-simple/port ]; then
    PORTS=$(cat /opt/mtpr-simple/port)
else
    echo "SYN FIX: Файл с портами не найден" >&2
    exit 1
fi

CHAIN="MTPR_SYNFIX"
SSH_PORT=$(sshd -T 2>/dev/null | grep '^port ' | awk '{print $2}'); [ -n "$SSH_PORT" ] || SSH_PORT=22

if ! iptables -C INPUT -p tcp --dport "$SSH_PORT" -j ACCEPT 2>/dev/null; then
    iptables -I INPUT 1 -p tcp --dport "$SSH_PORT" -j ACCEPT
    echo "SSH-доступ (${SSH_PORT}) разрешён"
fi

iptables -t filter -N "$CHAIN" 2>/dev/null || true
iptables -t filter -F "$CHAIN"

if ! iptables -t filter -C INPUT -j "$CHAIN" 2>/dev/null; then
    iptables -t filter -I INPUT 2 -j "$CHAIN"
    echo "Цепочка $CHAIN подключена к INPUT"
fi

U32_FILTER="32 & 0x000FFFFF = 0x0002FFFF && 40 & 0xFF000000 = 0x02000000 && 44 & 0xFFFF0000 = 0x01030000 && 48 & 0xFFFFFF00 = 0x01010800 && 60 & 0xFFFFFFFF = 0x04020000"
while iptables -t mangle -C PREROUTING -m u32 --u32 "$U32_FILTER" -j MARK --set-mark 0x400 2>/dev/null; do
    iptables -t mangle -D PREROUTING -m u32 --u32 "$U32_FILTER" -j MARK --set-mark 0x400 2>/dev/null || break
done
iptables -t mangle -C PREROUTING -m u32 --u32 "$U32_FILTER" -j MARK --set-mark 0x400 2>/dev/null \
    || iptables -t mangle -A PREROUTING -m u32 --u32 "$U32_FILTER" -j MARK --set-mark 0x400

IFS=',' read -ra PORT_ARRAY <<< "$PORTS"
for PORT in "${PORT_ARRAY[@]}"; do
    PORT=$(echo "$PORT" | xargs)
    [ -z "$PORT" ] && continue

    iptables -t filter -A "$CHAIN" -p tcp --dport "$PORT" --syn -m mark --mark 0x400 -j ACCEPT

    iptables -t filter -A "$CHAIN" -p tcp --dport "$PORT" --syn \
        -m hashlimit \
        --hashlimit-name mtproto_"$PORT" \
        --hashlimit-mode srcip \
        --hashlimit-upto 54/minute \
        --hashlimit-burst 1 \
        --hashlimit-htable-expire 60000 \
        --hashlimit-htable-size 32768 \
        -j ACCEPT

    iptables -t filter -A "$CHAIN" -p tcp --dport "$PORT" --syn \
        -j REJECT --reject-with tcp-reset
done
APPLY_SCRIPT_EOF
)
    fi

    # Передаём скрипт на удалённый сервер
    ssh_exec "mkdir -p /opt/mtpr-simple && cat > /opt/mtpr-simple/apply-mtpr-synfix.sh << 'EOF'
$script_content
EOF
chmod +x /opt/mtpr-simple/apply-mtpr-synfix.sh"
}

# ── Генерация systemd юнита (удалённо) ──────────────────────
generate_service_unit() {
    local service_content
    service_content=$(cat <<'SERVICE_UNIT_EOF'
[Unit]
Description=MTProto SYN FIX rules for Telemt
After=network-online.target netfilter-persistent.service docker.service ufw.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/opt/mtpr-simple/apply-mtpr-synfix.sh
Restart=on-failure

[Install]
WantedBy=multi-user.target
SERVICE_UNIT_EOF
)
    ssh_exec "cat > /etc/systemd/system/mtpr-synfix.service << 'EOF'
$service_content
EOF
systemctl daemon-reload 2>/dev/null || true"
}

# ── Модуль xt_u32 на удалённом сервере: проверка и установка ──
u32_module_available_remote() {
    ssh_exec "if lsmod 2>/dev/null | grep -q '^xt_u32'; then exit 0; fi; modprobe xt_u32 2>/dev/null; if lsmod 2>/dev/null | grep -q '^xt_u32'; then exit 0; fi; iptables -m u32 -h >/dev/null 2>&1 && exit 0; exit 1"
}

detect_el_major_remote() {
    local v
    v=$(ssh_exec "if [ -f /etc/almalinux-release ]; then grep -oE '[0-9]+' /etc/almalinux-release | head -1; elif [ -f /etc/rocky-release ]; then grep -oE '[0-9]+' /etc/rocky-release | head -1; elif [ -f /etc/centos-release ]; then grep -oE '[0-9]+' /etc/centos-release | head -1; elif [ -f /etc/os-release ]; then grep -E '^VERSION_ID=' /etc/os-release | grep -oE '[0-9]+' | head -1; fi")
    if [ -z "$v" ]; then
        log_warning "Не удалось определить мажорную версию удалённого дистрибутива — предполагаю 9"
        v="9"
    fi
    printf '%s' "$v"
}

install_u32_module_remote() {
    local rel elrepo_url rsudo
    if ! ssh_exec "command -v dnf >/dev/null 2>&1"; then
        log_error "dnf не найден на удалённом сервере — установка kmod-xt_u32 невозможна"
        return 1
    fi
    if [ "$(ssh_exec 'id -u')" = "0" ]; then rsudo=""; else rsudo="sudo"; fi

    rel=$(detect_el_major_remote)
    case "$rel" in
        8)  elrepo_url="https://www.elrepo.org/elrepo-release-8.el8.elrepo.noarch.rpm" ;;
        10) elrepo_url="https://www.elrepo.org/elrepo-release-10.el10.elrepo.noarch.rpm" ;;
        *)  rel="9"; elrepo_url="https://www.elrepo.org/elrepo-release-9.el9.elrepo.noarch.rpm" ;;
    esac

    if ssh_exec "dnf repolist 2>/dev/null | grep -qi elrepo"; then
        log_info "Репозиторий elrepo уже подключён (версия ${rel}.x)"
    else
        log_info "Подключение репозитория elrepo (RHEL/CentOS ${rel}.x)..."
        if ! ssh_exec "$rsudo dnf install -y '$elrepo_url'"; then
            log_error "Не удалось подключить репозиторий elrepo"
            return 1
        fi
    fi

    log_info "Установка пакета kmod-xt_u32..."
    if ! ssh_exec "$rsudo dnf install -y kmod-xt_u32"; then
        log_error "Не удалось установить пакет kmod-xt_u32"
        return 1
    fi

    ssh_exec "$rsudo modprobe xt_u32 2>/dev/null || true"
    if u32_module_available_remote; then
        log_success "Модуль xt_u32 загружен и доступен"
        return 0
    fi
    log_error "Пакет установлен, но модуль xt_u32 не загрузился (modprobe/lsmod пусто)"
    return 1
}


# ── Установка SYN FIX ────────────────────────────────────────
install_syn_fix() {
    local ports_input
    local fix_choice
    local auto_install=false
    local forced_ports=""
    local FIX_TYPE="new"

    if [[ "${1:-}" == "-auto_install" ]]; then
        auto_install=true
        forced_ports="${2:-}"
        FIX_TYPE="new"
    fi


    if [ "$auto_install" = true ]; then
        if [[ -n "$forced_ports" ]]; then
            ports_input="$forced_ports"
            log_info "Используем порты, переданные аргументом: $ports_input"
        else
            log_info "Порты не переданы, используем 443"
            ports_input="443"
        fi
    else
        echo ""
        clear 2>/dev/null || true
        echo -e ""
        echo -e "  ${BOLD}Меню установки MTPRoto FIX V1.2 (удалённо: ${CYAN}${REMOTE_USER}@${REMOTE_IP}${NC}${BOLD})${NC}"
        echo -e "  ${DIM}═══════════════════════════════════════════════════════════════"
        echo -e "  ${DIM}Для работы прокси на ios необходим корректно работающий домен"
        echo -e "  ${DIM}Подробнее в data/dictionary.md в репозитории. (обязательно к прочтению)"
        echo -e ""
        echo -e "  ${NC}${BOLD}Введите порт для SYN FIX ${DIM}(Например: 443)"
        echo -e "  ${NC}${BOLD}Либо введите порты через запятую ${DIM}(Например: 443,8443) "
        echo -e ""
        echo -en "  ${NC}${BOLD}Ввод ${GREEN}${BOLD}(По умолчанию Enter - 443)${NC}${BOLD}:${NC}"
        { read -r ports_input </dev/tty; } 2>/dev/null || ports_input=""
        if [ -z "$ports_input" ]; then
            ports_input="443"
        fi

        echo ""
        echo -e "  ${BOLD}Выберите вариант правил ниже"
        echo -e "  ${DIM}══════════════════════════════════════════════"
        echo ""
        echo -e "  ${GREEN}[1]${NC}  ${BOLD}V3 фикс iptables${NC} (Разделение устройств с помощью u32 по байтам из пакета) — ${GREEN}${BOLD}рекомендуется${NC}"
        echo -e "${DIM}  Если совпало -> это ios и принимаем пакеты без лимита"
        echo -e "${DIM}  Если не совпало -> это другое ус-во и ставим SYN 1 пакет в 1.1 сек."
        echo -e ""
        echo -e "  ${CYAN}[2]${NC}  ${BOLD}V4 фикс zapret2 ${NC} — быстрый (на этапе тестирования)${NC}"
        echo -e "${DIM}  Работает с помощью zapret2 на уровне TCP-пакетов: ${NC}"
        echo -e "${DIM}  disorder + badsum + window control"
        echo ""
        echo -e "  ${YELLOW}[3]${NC}  ${BOLD}v2 фикс iptables${NC} (Разделение устройств определяя их TTL+Length)"
        echo -e "${DIM}  Если TTL <65 и length 64 -> это ios и принимаем пакеты без лимита"
        echo -e "${DIM}  Иначе -> это другое ус-во и ставим SYN 1 пакет в 1.1 сек."
        echo ""
        echo -e "  ${GREEN}[4]${NC}  ${BOLD}v3 фикс nftables${GREEN}${BOLD} - рекомендуется (Совместим с Docker)${NC}"
        echo -e "${DIM}  Если совпало -> это ios и принимаем пакеты без лимита"
        echo -e "${DIM}  Если не совпало -> это другое ус-во и ставим SYN 1 пакет в 1.1 сек."
        echo -e "  ${YELLOW}[5]${NC}  ${BOLD}v2 фикс nftables${NC}${BOLD}${NC}${BOLD} (Совместим с Docker)"
        echo -e "${DIM}  Если TTL <65 и length 64 -> это ios и принимаем пакеты без лимита"
        echo -e "${DIM}  Иначе -> это другое ус-во и ставим SYN 1 пакет в 1.1 сек."
        echo ""
        echo -en "  ${NC}${BOLD}Ввод (По умолчанию - ${GREEN}${BOLD}1 или enter${NC}${BOLD}):${NC} "
        { read -r fix_choice </dev/tty; } 2>/dev/null || fix_choice=""

        if [ -z "$fix_choice" ] || [ "$fix_choice" = "1" ]; then
            FIX_TYPE="new"
            log_info "Выбран v3 iptables"
        elif [ "$fix_choice" = "2" ]; then
            FIX_TYPE="zapret2"
            log_info "Выбран Zapret2 fix"
        elif [ "$fix_choice" = "3" ]; then
            FIX_TYPE="old"
            log_info "Выбран v2 iptables"
        elif [ "$fix_choice" = "4" ]; then
            FIX_TYPE="docker_smart"
            log_info "Выбран v3 nftables"
        elif [ "$fix_choice" = "5" ]; then
            FIX_TYPE="docker_classic"
            log_info "Выбран v3 nftables"
        else
            log_warning "Неверный выбор, используем первый вариант"
            FIX_TYPE="new"
        fi
    fi

    # ── Если выбран Zapret2 fix ────────────────────────────────
    if [ "$FIX_TYPE" = "zapret2" ]; then
        # Проверяем наличие zapret2_fix.sh на удалённом сервере и запускаем его меню
        if ssh_exec "[ -f /opt/mtpr-simple/data/zapret2_fix.sh ]"; then
            log_info "Запуск меню Zapret2 на удалённом сервере..."
            ssh_interactive "bash /opt/mtpr-simple/data/zapret2_fix.sh"
        else
            log_error "zapret2_fix.sh не найден на удалённом сервере, скачиваю..."
            ssh_exec "mkdir -p /opt/mtpr-simple/data && curl -fsSL https://raw.githubusercontent.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/main/data/zapret2_fix.sh -o /opt/mtpr-simple/data/zapret2_fix.sh && chmod +x /opt/mtpr-simple/data/zapret2_fix.sh"
            log_success "zapret2_fix.sh скачан, запускаю..."
            ssh_interactive "bash /opt/mtpr-simple/data/zapret2_fix.sh"
        fi
        return 0
    fi

    # Парсим порты
    IFS=',' read -ra PORTS_ARRAY <<< "$ports_input"
    local valid_ports=()
    for p in "${PORTS_ARRAY[@]}"; do
        p=$(echo "$p" | xargs)
        if [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ]; then
            valid_ports+=("$p")
        else
            log_warning "Некорректный порт '$p' пропущен"
        fi
    done

    if [ ${#valid_ports[@]} -eq 0 ]; then
        log_error "Нет корректных портов для установки"
        echo ""
        pause_key "Нажмите любую клавишу..."
        return 1
    fi

    local ports_str
    ports_str=$(IFS=,; echo "${valid_ports[*]}")
    log_info "Установка SYN FIX на порты: $ports_str"
    save_port "$ports_str"

    # ── nftables режимы ──────────────────────────────────────
    if [ "$FIX_TYPE" = "docker_smart" ] || [ "$FIX_TYPE" = "docker_classic" ]; then

        # Проверяем nftables на удалённом сервере
        if ! ssh_exec "command -v nft >/dev/null 2>&1"; then
            log_warning "nftables не установлен на удалённом сервере, устанавливаю..."
            if ! ssh_exec "if command -v apt-get >/dev/null 2>&1; then apt-get update -qq && apt-get install -y -qq nftables; elif command -v yum >/dev/null 2>&1; then yum install -y -q nftables; elif command -v dnf >/dev/null 2>&1; then dnf install -y -q nftables; else echo 'Не удалось установить nftables'; exit 1; fi"; then
                log_error "Не удалось установить nftables на удалённом сервере"
                pause_key "Нажмите любую клавишу..."
                return 1
            fi
        fi

        if [ "$auto_install" = false ]; then
            echo ""
            log_warning "Будет выполнена установка SYN FIX (nftables) на порты: $ports_str"
            echo ""
            echo -e "  ${BOLD}Что будет сделано:${NC}"
            echo -e "  • Будет создана таблица nftables ${CYAN}mtpr_synfix${NC}"
            echo -e "  • Добавлены правила SYN-фильтрации для портов: ${CYAN}$ports_str${NC}"
            echo -e "  • Будет создан systemd сервис ${CYAN}mtpr-nft-synfix.service${NC}"
            echo ""
            log_warning "${BOLD}ВНИМАНИЕ:${NC} Данная настройка изменит файрвол системы."
            echo ""
            echo -en "  ${BOLD}Продолжить установку? Y/n:${NC} "
            { read -r confirm </dev/tty; } 2>/dev/null || confirm=""
            if [[ ! "$confirm" =~ ^[yY]$ ]] && [ -n "$confirm" ]; then
                log_info "Установка отменена"
                sleep 0.5
                return 1
            fi
        fi

        log_info "Установка nftables режима..."

        # Генерируем скрипт nftables на удалённом сервере
        local NFT_SCRIPT="/opt/mtpr-simple/mtpr-synfix-nft.sh"
        local nft_script_content
        nft_script_content=$(cat <<'NFT_WRAPPER_EOF'
#!/bin/sh
set -eu

TABLE="mtpr_synfix"
CHAIN="input"

nft delete table inet "$TABLE" 2>/dev/null || true
nft add table inet "$TABLE"
nft "add chain inet $TABLE $CHAIN { type filter hook input priority -10; policy accept; }"
NFT_WRAPPER_EOF
)

        if [ "$FIX_TYPE" = "docker_smart" ]; then
            nft_script_content+=$'\n'"# 1. iOS по TCP fingerprint → ACCEPT без лимита"
            for port in "${valid_ports[@]}"; do
                nft_script_content+=$'\n'"nft \"add rule inet mtpr_synfix input tcp dport $port tcp flags & (syn | ack) == syn @th,108,20 0x2ffff @th,160,16 0x204 @th,192,16 0x103 @th,224,24 0x10108 @th,320,32 0x4020000 counter accept comment \\\"ios_accept\\\"\""
                nft_script_content+=$'\n'"nft \"add rule inet mtpr_synfix input tcp dport $port tcp flags & (syn | ack) == syn meter mtpr_other { ip saddr timeout 60s limit rate 54/minute burst 1 packets } counter accept comment \\\"other_accept\\\"\""
                nft_script_content+=$'\n'"nft \"add rule inet mtpr_synfix input tcp dport $port tcp flags & (syn | ack) == syn meter mtpr_other6 { ip6 saddr timeout 60s limit rate 54/minute burst 1 packets } counter accept comment \\\"other_accept6\\\"\""
                nft_script_content+=$'\n'"nft \"add rule inet mtpr_synfix input tcp dport $port tcp flags & (syn | ack) == syn counter reject with tcp reset comment \\\"other_reject\\\"\""
            done
        else
            for port in "${valid_ports[@]}"; do
                nft_script_content+=$'\n'"nft \"add rule inet mtpr_synfix input tcp dport $port tcp flags & (syn | ack) == syn meter mtpr_classic { ip saddr timeout 60s limit rate 1/second burst 1 packets } counter drop comment \\\"classic_drop\\\"\""
                nft_script_content+=$'\n'"nft \"add rule inet mtpr_synfix input tcp dport $port tcp flags & (syn | ack) == syn meter mtpr_classic6 { ip6 saddr timeout 60s limit rate 1/second burst 1 packets } counter drop comment \\\"classic_drop6\\\"\""
            done
        fi

        ssh_exec "cat > $NFT_SCRIPT << 'EOF'
$nft_script_content
EOF
chmod +x $NFT_SCRIPT"

        # Применяем скрипт
        if ssh_interactive "bash $NFT_SCRIPT"; then
            echo ""
            log_success "NFT правила применены успешно"
        else
            echo ""
            log_error "Ошибка применения NFT правил"
            pause_key "Нажмите любую клавишу..."
            return 1
        fi

        # Создаём systemd сервис
        local service_nft_content
        service_nft_content=$(cat <<'SERVICE_NFT_EOF'
[Unit]
Description=MTProto SYN FIX (nftables) for Telemt/Docker
After=network-online.target netfilter-persistent.service docker.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh /opt/mtpr-simple/mtpr-synfix-nft.sh
ExecStop=/bin/sh -c '/usr/sbin/nft delete table inet mtpr_synfix 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
SERVICE_NFT_EOF
)
        ssh_exec "cat > /etc/systemd/system/mtpr-nft-synfix.service << 'EOF'
$service_nft_content
EOF
systemctl daemon-reload 2>/dev/null || echo 'daemon-reload failed' >&2
systemctl enable mtpr-nft-synfix.service 2>/dev/null || true
systemctl restart mtpr-nft-synfix.service 2>/dev/null || true"

        echo ""
        log_info "Автозапуск mtpr-nft-synfix.service: $(ssh_exec "systemctl is-enabled mtpr-nft-synfix.service 2>/dev/null || echo неизвестно")"
        log_success "SYN FIX (nftables) успешно установлен на порты: $ports_str"
        pause_key "Нажмите любую клавишу..."
        return 0
    fi

    # ── iptables режимы (1 и 2) ──────────────────────
    if [ "$auto_install" = false ]; then
        echo ""
        log_warning "Будет выполнена установка SYN FIX на порты: $ports_str"
        echo ""
        echo -e "  ${BOLD}Что будет сделано:${NC}"
        echo -e "  • Создана отдельная цепочка iptables ${CYAN}$SYNFIX_CHAIN${NC}"
        echo -e "  • Добавлены правила SYN-фильтрации для портов: ${CYAN}$ports_str${NC}"
        echo -e "  • Вы сможете удалить данную настройку через меню скрипта."
        echo ""
        log_warning "${BOLD}ВНИМАНИЕ:${NC} Данная настройка изменит файрвол системы."
        echo ""
        echo -en "  ${BOLD}Продолжить установку? [Y/n]:${NC} "
        { read -r confirm </dev/tty; } 2>/dev/null || confirm=""
        if [[ ! "$confirm" =~ ^[yY]$ ]] && [ -n "$confirm" ]; then
            log_info "Установка отменена"
            sleep 0.5
            return 1
        fi
    fi

    # ── Для v3 (u32) заранее убеждаемся, что модуль xt_u32 есть на удалённом сервере ──
    if [ "$FIX_TYPE" = "new" ] && ! u32_module_available_remote; then
        echo ""
        echo -e "  ${YELLOW}[!]${NC} Модуль xt_u32 не найден на удалённом сервере"
        echo -e "  ${YELLOW}[!]${NC} Он необходим для варианта V3 (iptables + u32)"
        echo ""
        if [ "$auto_install" = true ]; then
            log_info "Автоматическая установка kmod-xt_u32 через elrepo (удалённо)..."
            if ! install_u32_module_remote; then
                log_error "Модуль u32 недоступен. Автоматическая установка не удалась."
                return 1
            fi
        else
            echo -e "  ${BOLD}Установить необходимый модуль xt_u32?${NC}"
            echo -e "  ${GREEN}Enter/Y${NC} — установить и продолжить"
            echo -e "  ${RED}N/n${NC} — отменить установку и вернуться в меню"
            echo ""
            echo -en "  ${BOLD}Ввод:${NC} "
            { read -r install_u32 </dev/tty; } 2>/dev/null || install_u32=""
            if [[ -z "$install_u32" || "$install_u32" =~ ^[yY]$ ]]; then
                if ! install_u32_module_remote; then
                    pause_key "Нажмите любую клавишу..."
                    return 1
                fi
            else
                log_info "Установка отменена"
                pause_key "Нажмите любую клавишу..."
                return 0
            fi
        fi
    fi

    generate_apply_script "$FIX_TYPE" "${valid_ports[@]}"
    generate_service_unit

    local apply_output
    local apply_exit_code
    if apply_output=$(ssh_exec "PORT='$ports_str' /opt/mtpr-simple/apply-mtpr-synfix.sh 2>&1"); then
        apply_exit_code=0
    else
        apply_exit_code=$?
    fi

    # ── Явная проверка результата для v3: правило u32 в mangle удалённого сервера ──
    if [ "$FIX_TYPE" = "new" ]; then
        if ! ssh_exec "iptables -t mangle -C PREROUTING -m u32 --u32 '$U32_FILTER' -j MARK --set-mark 0x400"; then
            log_error "SYN FIX (v3/u32) НЕ применён: правило u32 в mangle отсутствует"
            echo -e "  ${DIM}apply_output:${NC} ${apply_output:-<пусто>}"
            pause_key "Нажмите любую клавишу..."
            return 1
        fi
    fi

    if [ "$apply_exit_code" -ne 0 ]; then
        echo ""
        log_error "Ошибка применения правил iptables:"
        echo "$apply_output"
        pause_key "Нажмите любую клавишу..."
        return 1
    fi

    if ! ssh_exec "systemctl enable mtpr-synfix.service && systemctl restart mtpr-synfix.service"; then
        log_error "Не удалось включить/перезапустить mtpr-synfix.service"
        pause_key "Нажмите любую клавишу..."
        return 1
    fi
    echo ""
    log_info "Автозапуск mtpr-synfix.service: $(ssh_exec "systemctl is-enabled mtpr-synfix.service 2>/dev/null || echo неизвестно")"
    log_success "SYN FIX успешно установлен на порты: $ports_str"
    pause_key "Нажмите любую клавишу..."
}

# ── Удаление SYN FIX ─────────────────────────────────────────
remove_syn_fix() {
    log_info "Удаление SYN FIX..."

    # Удаляем iptables
    ssh_exec "systemctl stop mtpr-synfix.service 2>/dev/null || true"
    ssh_exec "systemctl disable mtpr-synfix.service 2>/dev/null || true"

    if ssh_exec "iptables -C INPUT -j \"$SYNFIX_CHAIN\" 2>/dev/null"; then
        ssh_exec "iptables -D INPUT -j \"$SYNFIX_CHAIN\""
        log_info "Цепочка $SYNFIX_CHAIN отключена от INPUT"
    fi

    if ssh_exec "iptables -L \"$SYNFIX_CHAIN\" -n >/dev/null 2>&1"; then
        ssh_exec "iptables -F \"$SYNFIX_CHAIN\""
        ssh_exec "iptables -X \"$SYNFIX_CHAIN\""
        log_info "Цепочка $SYNFIX_CHAIN удалена"
    fi

    # Удаляем правила u32 из mangle
    local u32_filter="32 & 0x000FFFFF = 0x0002FFFF && 40 & 0xFF000000 = 0x02000000 && 44 & 0xFFFF0000 = 0x01030000 && 48 & 0xFFFFFF00 = 0x01010800 && 60 & 0xFFFFFFFF = 0x04020000"
    if ssh_exec "iptables -t mangle -L PREROUTING -n 2>/dev/null | grep -q \"$u32_filter\""; then
        log_info "Обнаружены правила u32 в mangle (iptables), удаляем..."
        ssh_exec "iptables -t mangle -L PREROUTING --line-numbers 2>/dev/null | grep \"$u32_filter\" | awk '{print \$1}' | tac | while read -r num; do [ -n \"\$num\" ] && iptables -t mangle -D PREROUTING \"\$num\" 2>/dev/null; done"
    else
        log_info "Правил с нашим u32-фильтром в iptables/mangle не найдено"
    fi

    # Удаляем nftables
    if ssh_exec "command -v nft >/dev/null 2>&1"; then
        if ssh_exec "nft list table inet mtpr_synfix &>/dev/null 2>&1"; then
            log_info "Обнаружена таблица inet mtpr_synfix (nftables), удаляем..."
            ssh_exec "nft delete table inet mtpr_synfix 2>/dev/null"
        else
            log_info "Таблицы inet mtpr_synfix не найдено"
        fi

        handles=$(ssh_exec "nft -a list chain ip mangle PREROUTING 2>/dev/null | grep 'xt match \"u32\".*meta mark set 0x400' | grep -o 'handle [0-9]*' | awk '{print \$2}'" 2>/dev/null)
        if [ -n "$handles" ]; then
            log_info "Найдены правила u32 в nftables (ip mangle), удаляем..."
            for h in $handles; do
                ssh_exec "nft delete rule ip mangle PREROUTING handle $h 2>/dev/null"
            done
        fi

        ssh_exec "nft delete table inet mtpr_synfix 2>/dev/null || true"
    fi

    ssh_exec "rm -f \"$PORT_FILE\""
    ssh_exec "rm -f /etc/systemd/system/mtpr-synfix.service"

    # Удаляем nftables-сервис
    ssh_exec "systemctl stop mtpr-nft-synfix.service 2>/dev/null || true"
    ssh_exec "systemctl disable mtpr-nft-synfix.service 2>/dev/null || true"
    ssh_exec "rm -f /etc/systemd/system/mtpr-nft-synfix.service"
    ssh_exec "rm -f /opt/mtpr-simple/mtpr-synfix-nft.sh"

    ssh_exec "systemctl daemon-reload"

    log_success "SYN FIX (iptables + nftables) удалён"
}

# ── Главное меню ─────────────────────────────────────────────

main_menu() {
    while true; do
        clear 2>/dev/null || true
        echo ""
        echo -e "  ${BOLD}Меню фиксов (SYN FIX/Zapret2) для ${CYAN}${REMOTE_USER}@${REMOTE_IP}${NC}${BOLD} (порт $REMOTE_PORT)${NC}"
        echo -e "  ${DIM}═══════════════════════════════════════════════════════════${NC}"
        echo ""
        echo -e "  ${BOLD}Статус iptables:${NC} $(get_synfix_status)"
        echo -e "  ${BOLD}Статус nftables:${NC} $(get_nft_fix_status)"
        echo -e "  ${BOLD}Zapret2 fix:${NC} $(get_zapret2_status_remote)"
        echo ""

        echo -e "  ${CYAN}[1]${NC}  ${BOLD}Установить SYN FIX${NC}"
        echo -e "  ${CYAN}[2]${NC}  ${BOLD}Удалить SYN FIX${NC}"
        echo -e "  ${CYAN}[3]${NC}  ${BOLD}Проверить статус${NC}"
        echo -e "  ${CYAN}[4]${NC}  ${BOLD}Меню Zapret2${NC}  ${DIM}(запуск zapret2_fix.sh)${NC}"
        echo -e "  ${CYAN}[0]${NC}  ${BOLD}Назад в управление нодой${NC}"
        echo ""
        echo -en "  ${BOLD}Выбор:${NC} "
        { read -r choice </dev/tty; } 2>/dev/null || return 1

        case "$choice" in
            1)
                install_syn_fix
                ;;
            2)
                echo ""
                remove_syn_fix
                pause_key "Нажмите любую клавишу..."
                ;;
            3)
                echo ""
                echo -e "  Статус iptables: $(get_synfix_status)"
                echo -e "  Статус nftables: $(get_nft_fix_status)"
                echo -e "  Zapret2 fix: $(get_zapret2_status_remote)"
                pause_key "Нажмите любую клавишу..."
                ;;
            4)
                echo ""
                if ssh_exec "[ -f /opt/mtpr-simple/data/zapret2_fix.sh ]"; then
                    log_info "Запуск меню Zapret2 на удалённом сервере..."
                    ssh_interactive "bash /opt/mtpr-simple/data/zapret2_fix.sh"
                else
                    log_error "zapret2_fix.sh не найден на удалённом сервере, скачиваю..."
                    ssh_exec "mkdir -p /opt/mtpr-simple/data && curl -fsSL https://raw.githubusercontent.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/main/data/zapret2_fix.sh -o /opt/mtpr-simple/data/zapret2_fix.sh && chmod +x /opt/mtpr-simple/data/zapret2_fix.sh"
                    log_success "zapret2_fix.sh скачан, запускаю..."
                    ssh_interactive "bash /opt/mtpr-simple/data/zapret2_fix.sh"
                fi
                ;;
            0)
                echo ""
                log_info "Возврат в управление нодой..."
                return 0   # вместо exit 0, чтобы вернуть управление вызывающему скрипту
                ;;
            *)
                echo "  Неверный выбор"
                sleep 0.1
                ;;
        esac
    done
}

# ── Запуск ────────────────────────────────────────────────────
main_menu
