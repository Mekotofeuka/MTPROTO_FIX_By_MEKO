#!/bin/bash
# data/rules.sh – все функции и наборы для работы с SYN FIX (iptables/nftables)

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

# ── Логирование ─────────────────────────────────────────────
log_info() { echo -e "  ${BLUE}[i]${NC} $1"; }
log_success() { echo -e "  ${GREEN}[✓]${NC} $1"; }
log_error() { echo -e "  ${RED}[✗]${NC} $1" >&2; }
log_warning() { echo -e "  ${YELLOW}[!]${NC} $1"; }

# ── Файл для хранения порта ─────────────────────────────────
PORT_FILE="/opt/mtpr-simple/port"

# ── Название кастомной цепочки iptables ─────────────────────
SYNFIX_CHAIN="MTPR_SYNFIX"

# ── Функция обрезки пробелов ──────────────────────────────
trim() {
    local var="$1"
    var="${var#"${var%%[![:space:]]*}"}"
    var="${var%"${var##*[![:space:]]}"}"
    printf '%s' "$var"
}

# ── Функция определения порта SSH ────────────────────────────
get_ssh_port() {
    local port
    if command -v sshd >/dev/null 2>&1; then
        port=$(timeout 3 sshd -T 2>/dev/null | grep '^port ' | awk '{print $2}' | head -1)
        if [[ "$port" =~ ^[0-9]+$ ]]; then
            echo "$port"
            return 0
        fi
    fi

    if [ -f /etc/ssh/sshd_config ]; then
        port=$(grep -E '^Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config | head -1 | awk '{print $2}')
        if [[ "$port" =~ ^[0-9]+$ ]]; then
            echo "$port"
            return 0
        fi
    fi

    if [ -d /etc/ssh/sshd_config.d ]; then
        for cfg in /etc/ssh/sshd_config.d/*.conf; do
            if [ -f "$cfg" ]; then
                port=$(grep -E '^Port[[:space:]]+[0-9]+' "$cfg" | head -1 | awk '{print $2}')
                if [[ "$port" =~ ^[0-9]+$ ]]; then
                    echo "$port"
                    return 0
                fi
            fi
        done
    fi

    echo "22"
    return 0
}

save_port() {
    echo "$1" >"$PORT_FILE"
}

# ── ПРОВЕРКА НАЛИЧИЯ ЦЕПОЧКИ IPTABLES SYN FIX ────────────────
is_syn_fix_chain_installed() {
    iptables -L "$SYNFIX_CHAIN" -n >/dev/null 2>&1
}

is_syn_fix_service_running() {
    systemctl is-active --quiet mtpr-synfix.service
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

# ── ПРОВЕРКА НАЛИЧИЯ NFTABLES SYN FIX ────────────────────────
is_nft_fix_installed() {
    nft list table inet mtpr_synfix &>/dev/null 2>&1
}

is_nft_fix_service_running() {
    systemctl is-active --quiet mtpr-nft-synfix.service 2>/dev/null
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

# ── Генерация скрипта применения правил ──────────────────────────
generate_apply_script() {
    local fix_type="${1:-new}"
    shift
    local ports=("$@")

    if [ "$fix_type" = "old" ]; then
        cat >/opt/mtpr-simple/apply-mtpr-synfix.sh <<'APPLY_SCRIPT_EOF'
#!/bin/bash
set -e

# ── Парсим порты из файла ──────────────────────────────────
if [ -f /opt/mtpr-simple/port ]; then
    PORTS=$(cat /opt/mtpr-simple/port)
else
    echo "SYN FIX: Файл с портами не найден" >&2
    exit 1
fi

CHAIN="MTPR_SYNFIX"
SSH_PORT=$(sshd -T 2>/dev/null | grep '^port ' | awk '{print $2}' || echo 22)

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

# ── Проходим по каждому порту ──────────────────────────────
IFS=',' read -ra PORT_ARRAY <<< "$PORTS"
for PORT in "${PORT_ARRAY[@]}"; do
    PORT=$(echo "$PORT" | xargs)
    [ -z "$PORT" ] && continue

    # ── iOS — проверка TTL+Length, ACCEPT БЕЗ ЛИМИТА ────────
    iptables -t filter -A "$CHAIN" -p tcp --dport "$PORT" --syn \
        -m tcp --tcp-flags SYN SYN \
        -m length --length 64 \
        -m ttl --ttl-lt 65 \
        -j ACCEPT

    # ── ВТОРОЙ СЛОЙ — все остальные → hashlimit 54/мин ──────
    iptables -t filter -A "$CHAIN" -p tcp --dport "$PORT" --syn \
        -m hashlimit \
        --hashlimit-name mtproto_"$PORT" \
        --hashlimit-mode srcip \
        --hashlimit-upto 54/minute \
        --hashlimit-burst 1 \
        --hashlimit-htable-expire 60000 \
        --hashlimit-htable-size 32768 \
        -j ACCEPT

    # ── REJECT для всех остальных ────────────────────────────
    iptables -t filter -A "$CHAIN" -p tcp --dport "$PORT" --syn \
        -j REJECT --reject-with tcp-reset
done

APPLY_SCRIPT_EOF
    else
        # Новый вариант (u32 + ACCEPT без лимита)
        cat >/opt/mtpr-simple/apply-mtpr-synfix.sh <<'APPLY_SCRIPT_EOF'
#!/bin/bash
set -e

# ── Парсим порты из файла ──────────────────────────────────
if [ -f /opt/mtpr-simple/port ]; then
    PORTS=$(cat /opt/mtpr-simple/port)
else
    echo "SYN FIX: Файл с портами не найден" >&2
    exit 1
fi

CHAIN="MTPR_SYNFIX"
SSH_PORT=$(sshd -T 2>/dev/null | grep '^port ' | awk '{print $2}' || echo 22)

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

# ── 1. Маркировка iOS в mangle ──────────────────────────────
iptables -t mangle -A PREROUTING -m u32 --u32 "32 & 0x000FFFFF = 0x0002FFFF && 40 & 0xFF000000 = 0x02000000 && 44 & 0xFFFF0000 = 0x01030000 && 48 & 0xFFFFFF00 = 0x01010800 && 60 & 0xFFFFFFFF = 0x04020000" -j MARK --set-mark 0x400

# ── Проходим по каждому порту ──────────────────────────────
IFS=',' read -ra PORT_ARRAY <<< "$PORTS"
for PORT in "${PORT_ARRAY[@]}"; do
    PORT=$(echo "$PORT" | xargs)
    [ -z "$PORT" ] && continue

    # ── ACCEPT для маркированных iOS (БЕЗ ЛИМИТА) ─────────────
    iptables -t filter -A "$CHAIN" -p tcp --dport "$PORT" --syn -m mark --mark 0x400 -j ACCEPT

    # ── ВТОРОЙ СЛОЙ — все остальные → hashlimit 54/мин ──────
    iptables -t filter -A "$CHAIN" -p tcp --dport "$PORT" --syn \
        -m hashlimit \
        --hashlimit-name mtproto_"$PORT" \
        --hashlimit-mode srcip \
        --hashlimit-upto 54/minute \
        --hashlimit-burst 1 \
        --hashlimit-htable-expire 60000 \
        --hashlimit-htable-size 32768 \
        -j ACCEPT

    # ── REJECT для всех остальных ────────────────────────────
    iptables -t filter -A "$CHAIN" -p tcp --dport "$PORT" --syn \
        -j REJECT --reject-with tcp-reset
done

APPLY_SCRIPT_EOF
    fi

    chmod +x /opt/mtpr-simple/apply-mtpr-synfix.sh
}

# ── Генерация systemd юнита ────────────────────────────────────
generate_service_unit() {
    cat >/etc/systemd/system/mtpr-synfix.service <<'SERVICE_UNIT_EOF'
[Unit]
Description=MTProto SYN FIX rules for Telemt
After=docker.service ufw.service network.target
Wants=docker.service ufw.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/opt/mtpr-simple/apply-mtpr-synfix.sh
Restart=on-failure

[Install]
WantedBy=multi-user.target
SERVICE_UNIT_EOF
    if systemctl daemon-reload 2>/dev/null; then
        log_info "Системный менеджер служб перезапущен"
    fi
}

# ── УСТАНОВКА SYN FIX ──────────────────────────────────────
install_syn_fix() {
    local ports_input
    local fix_choice
    local auto_install=false
    local forced_ports=""
    local FIX_TYPE="new"

    if [[ "$1" == "-auto_install" ]]; then
        auto_install=true
        forced_ports="$2"
        FIX_TYPE="new"
    fi

    ssh_port=$(get_ssh_port)

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
        # Используем /dev/tty для ввода
        if [ -r /dev/tty ]; then
		    clear
		    echo -e ""
		    echo -e ""
            echo -e "  ${BOLD}Меню SYN FIX V1.15 | Выберите порт(тот же что и у proxy) ниже"
		    echo -e "  ${DIM}═══════════════════════════════════════════════════════════════"
		    echo -e ""
            echo -e "  ${NC}${BOLD}Введите порт для SYN FIX ${DIM}(Например: 443)"
            echo -e "  ${NC}${BOLD}Либо введите порты через запятую ${DIM}(Например: 443,8443) "
			echo -e ""
			echo -en "  ${NC}${BOLD}Ввод ${GREEN}${BOLD}(По умолчанию Enter - 443)${NC}${BOLD}:${NC}"
            read -r ports_input </dev/tty
        else
            echo -e "  ${NC}${BOLD}Введите порт для SYN FIX (например: 443 (Enter - 443) "
            echo -e "  ${NC}${BOLD}Либо введите порты через запятую (например: 443,8443) "
			echo -e ""
			echo -en "  ${NC}${BOLD}Ввод ${GREEN}${BOLD}(По умолчанию Enter - 443)${NC}${BOLD}:${NC}"
            read -r ports_input
        fi
        if [ -z "$ports_input" ]; then
            ports_input="443"
        fi

        echo ""
        echo -e "  ${BOLD}Выберите вариант правил ниже"
		echo -e "  ${DIM}══════════════════════════════════════════════"
		echo -e ""
        echo -e "  ${GREEN}[1]${NC}  ${BOLD}Новый вариант(iptables)${NC} (Разделение устройств с помощью u32 по байтам из пакета) — ${GREEN}${BOLD}рекомендуется${NC}"
        echo -e "${DIM}  Если совпало -> это ios и принимаем пакеты без лимита"
        echo -e "${DIM}  Если не совпало -> это другое ус-во и ставим SYN 1 пакет в 1.1 сек."
        echo -e "  ${CYAN}[2]${NC}  ${BOLD}Старый вариант(iptables)${NC} (Разделение устройств определяя их TTL+Length)"
        echo -e "${DIM}  Если TTL <65 и length 64 -> это ios и принимаем пакеты без лимита"
        echo -e "${DIM}  Иначе -> это другое ус-во и ставим SYN 1 пакет в 1.1 сек."
        echo ""
        echo -e "  ${YELLOW}[3]${NC}  ${BOLD}Новый вариант(nftables)${GREEN}${BOLD} - рекомендуется (Совместим с Docker)${NC}"
        echo -e "${DIM}  Если совпало -> это ios и принимаем пакеты без лимита"
        echo -e "${DIM}  Если не совпало -> это другое ус-во и ставим SYN 1 пакет в 1.1 сек."
        echo -e "  ${YELLOW}[4]${NC}  ${BOLD}Старый вариант(nftables)${NC}${BOLD}${NC}${BOLD} (Совместим с Docker)"
        echo -e "${DIM}  Если TTL <65 и length 64 -> это ios и принимаем пакеты без лимита"
        echo -e "${DIM}  Иначе -> это другое ус-во и ставим SYN 1 пакет в 1.1 сек."
        echo ""
        if [ -r /dev/tty ]; then
            echo -en "  ${NC}${BOLD}Ввод (По умолчанию - ${GREEN}${BOLD}1 или enter${NC}${BOLD}):${NC} "
            read -r fix_choice </dev/tty
        else
            echo -en "  ${NC}${BOLD}Ввод (${GREEN}${BOLD}По умолчанию - 1(Enter)${NC}${BOLD}):${NC} "
            read -r fix_choice
        fi

        if [ -z "$fix_choice" ] || [ "$fix_choice" = "1" ]; then
            FIX_TYPE="new"
            log_info "Выбран новый iptables"
        elif [ "$fix_choice" = "2" ]; then
            FIX_TYPE="old"
            log_info "Выбран старый iptables"
        elif [ "$fix_choice" = "3" ]; then
            FIX_TYPE="docker_smart"
            log_info "Выбран nftables новый"
        elif [ "$fix_choice" = "4" ]; then
            FIX_TYPE="docker_classic"
            log_info "Выбран nftables старый"
        else
            log_warning "Неверный выбор, используем новый вариант(1)"
            FIX_TYPE="new"
        fi
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
        if [ -r /dev/tty ]; then
            echo -e "  ${GRAY}Нажмите любую клавишу...${NC}"
            read -rsn1 </dev/tty
        else
            echo -e "  ${GRAY}Нажмите любую клавишу...${NC}"
            read -rsn1
        fi
        return 1
    fi

    local ports_str=$(IFS=,; echo "${valid_ports[*]}")
    log_info "Установка SYN FIX на порты: $ports_str"
    save_port "$ports_str"

    # ── nftables режимы ──────────────────────────────────────
    if [ "$FIX_TYPE" = "docker_smart" ] || [ "$FIX_TYPE" = "docker_classic" ]; then

        # Проверяем nftables
        if ! command -v nft &>/dev/null; then
            log_warning "nftables не установлен, устанавливаю..."
            if command -v apt-get &>/dev/null; then
                apt-get update -qq && apt-get install -y -qq nftables
            elif command -v yum &>/dev/null; then
                yum install -y -q nftables
            elif command -v dnf &>/dev/null; then
                dnf install -y -q nftables
            else
                echo ""
                log_error "Не удалось установить nftables автоматически"
                if [ -r /dev/tty ]; then
                    echo -e "  ${GRAY}Нажмите любую клавишу${NC}"
                    read -rsn1 </dev/tty
                else
                    echo -e "  ${GRAY}Нажмите любую клавишу${NC}"
                    read -rsn1
                fi
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
            if [ -r /dev/tty ]; then
                echo -en "  ${BOLD}Продолжить установку? Y/n:${NC} "
                read -r confirm </dev/tty
            else
                echo -en "  ${BOLD}Продолжить установку? Y/n:${NC} "
                read -r confirm
            fi
            if [[ -z "$confirm" || "$confirm" =~ ^[yY]$ ]]; then
                : # продолжить
            else
                log_info "Установка отменена"
                sleep 0.5
                return 1
            fi
        fi

        log_info "Установка nftables режима..."

        # ── Генерируем скрипт как в реаниматоре ──────────────
        local NFT_SCRIPT="/opt/mtpr-simple/mtpr-synfix-nft.sh"
        local NFT_TABLE="mtpr_synfix"

        # Создаём shell-обёртку (как в реаниматоре)
        cat > "$NFT_SCRIPT" << 'NFT_WRAPPER_EOF'
#!/bin/sh
set -eu

TABLE="mtpr_synfix"
CHAIN="input"

# Удаляем таблицу если существует
nft delete table inet "$TABLE" 2>/dev/null || true

# Создаём таблицу и цепочку
nft add table inet "$TABLE"
nft "add chain inet $TABLE $CHAIN { type filter hook input priority 0; policy accept; }"

NFT_WRAPPER_EOF

        if [ "$FIX_TYPE" = "docker_smart" ]; then
            cat >> "$NFT_SCRIPT" << 'SMART_RULES_EOF'
# 1. iOS по TCP fingerprint → ACCEPT без лимита
nft "add rule inet mtpr_synfix input tcp dport PORT_HERE tcp flags & (syn|ack) == syn @th,108,20 0x2ffff @th,160,16 0x204 @th,192,16 0x103 @th,224,24 0x10108 @th,320,32 0x4020000 counter accept comment \"ios_accept\""

# 2. Все остальные → лимит 54/minute
nft "add rule inet mtpr_synfix input tcp dport PORT_HERE tcp flags & (syn|ack) == syn meter mtpr_other { ip saddr timeout 60s limit rate 54/minute burst 1 packets } counter accept comment \"other_accept\""

# 3. Превысившие лимит → reject с icmp-host-unreachable
nft "add rule inet mtpr_synfix input tcp dport PORT_HERE tcp flags & (syn|ack) == syn counter reject with icmp type host-unreachable comment \"other_reject\""
SMART_RULES_EOF
        else
            cat >> "$NFT_SCRIPT" << 'CLASSIC_RULES_EOF'
# Classic: 1/second burst 1 для всех
nft "add rule inet mtpr_synfix input tcp dport PORT_HERE tcp flags & (syn|ack) == syn meter mtpr_classic { ip saddr timeout 60s limit rate 1/second burst 1 packets } counter drop comment \"classic_drop\""
CLASSIC_RULES_EOF
        fi

        # Подставляем порты
        for port in "${valid_ports[@]}"; do
            sed -i "s/PORT_HERE/${port}/g" "$NFT_SCRIPT"
        done

        chmod +x "$NFT_SCRIPT"

        # Применяем скрипт (как в реаниматоре)
        if /bin/sh "$NFT_SCRIPT"; then
            echo ""
            log_success "NFT правила применены успешно"
        else
            echo ""
            log_error "Ошибка применения NFT правил"
            if [ -r /dev/tty ]; then
                echo -e "  ${GRAY}Нажмите любую клавишу${NC}"
                read -rsn1 </dev/tty
            else
                echo -e "  ${GRAY}Нажмите любую клавишу${NC}"
                read -rsn1
            fi
            return 1
        fi

        # Создаём systemd сервис (как в реаниматоре)
        cat > /etc/systemd/system/mtpr-nft-synfix.service << 'SERVICE_NFT_EOF'
[Unit]
Description=MTProto SYN FIX (nftables) for Telemt/Docker
After=docker.service network.target
Wants=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh /opt/mtpr-simple/mtpr-synfix-nft.sh
ExecStop=/bin/sh -c '/usr/sbin/nft delete table inet mtpr_synfix 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
SERVICE_NFT_EOF

        systemctl daemon-reload
        systemctl enable mtpr-nft-synfix.service 2>/dev/null
        systemctl restart mtpr-nft-synfix.service 2>/dev/null

        echo ""
        log_success "SYN FIX (nftables) успешно установлен на порты: $ports_str"
        if [ -r /dev/tty ]; then
            echo -e "  ${GRAY}Нажмите любую клавишу${NC}"
            read -rsn1 </dev/tty
        else
            echo -e "  ${GRAY}Нажмите любую клавишу${NC}"
            read -rsn1
        fi
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
        if [ -r /dev/tty ]; then
            echo -en "  ${BOLD}Продолжить установку? [Y/n]:${NC} "
            read -r confirm </dev/tty
        else
            echo -en "  ${BOLD}Продолжить установку? [Y/n]:${NC} "
            read -r confirm
        fi
        if [[ -z "$confirm" || "$confirm" =~ ^[yY]$ ]]; then
            : # продолжить
        else
            log_info "Установка отменена"
            sleep 0.5
            return 1
        fi
    fi

    generate_apply_script "$FIX_TYPE" "${valid_ports[@]}"
    generate_service_unit
    systemctl daemon-reload

    # ── Пытаемся применить правила с перехватом ошибки u32 ──
    local apply_output
    local apply_exit_code
    apply_output=$(PORT="$ports_str" /opt/mtpr-simple/apply-mtpr-synfix.sh 2>&1)
    apply_exit_code=$?

    # Проверяем, была ли ошибка с u32 (только для нового варианта)
    if [ "$FIX_TYPE" = "new" ] && [ $apply_exit_code -ne 0 ] && echo "$apply_output" | grep -q "u32"; then
        echo ""
        echo -e "  ${YELLOW}[!]${NC} Обнаружена ошибка: модуль u32 отсутствует"
        echo -e "  ${YELLOW}[!]${NC} Для работы нового варианта SYN FIX требуется установить модуль xt_u32"
        echo ""
        echo -e "  ${BOLD}Установить необходимый модуль xt_u32?${NC}"
        echo -e "  ${GREEN}Enter/Y${NC} — установить и продолжить"
        echo -e "  ${RED}N/n${NC} — отменить установку и вернуться в меню"
        echo ""
        if [ -r /dev/tty ]; then
            echo -en "  ${BOLD}Ввод:${NC} "
            read -r install_u32 </dev/tty
        else
            echo -en "  ${BOLD}Ввод:${NC} "
            read -r install_u32
        fi

        if [[ -z "$install_u32" || "$install_u32" =~ ^[yY]$ ]]; then
            echo ""
            log_info "Установка модуля xt_u32 для AlmaLinux..."
            echo ""
            
            # Определяем версию AlmaLinux
            local ALMA_VERSION=""
            if [ -f /etc/almalinux-release ]; then
                ALMA_VERSION=$(grep -oE '[0-9]+' /etc/almalinux-release | head -1)
            elif [ -f /etc/os-release ]; then
                ALMA_VERSION=$(grep -E '^VERSION_ID=' /etc/os-release | cut -d'"' -f2 | cut -d'.' -f1)
            fi
            
            if [ -z "$ALMA_VERSION" ]; then
                ALMA_VERSION="9"
                echo -e "  ${YELLOW}[!]${NC} Не удалось определить версию AlmaLinux, используем 9"
            fi
            
            echo -e "  ${BLUE}[i]${NC} Обнаружена версия AlmaLinux: ${ALMA_VERSION}"
            echo ""
            
            local ELREPO_URL=""
            if [ "$ALMA_VERSION" = "10" ]; then
                ELREPO_URL="https://www.elrepo.org/elrepo-release-10.el10.elrepo.noarch.rpm"
            else
                ELREPO_URL="https://www.elrepo.org/elrepo-release-9.el9.elrepo.noarch.rpm"
            fi
            
            echo -e "  ${BLUE}[i]${NC} Добавление репозитория elrepo (версия ${ALMA_VERSION})..."
            if sudo dnf install -y "$ELREPO_URL" 2>&1; then
                echo -e "  ${GREEN}[✓]${NC} Репозиторий elrepo добавлен"
            else
                echo -e "  ${RED}[✗]${NC} Не удалось добавить репозиторий elrepo"
                if [ -r /dev/tty ]; then
                    echo -e "  ${GRAY}Нажмите любую клавишу${NC}"
                    read -rsn1 </dev/tty
                else
                    echo -e "  ${GRAY}Нажмите любую клавишу${NC}"
                    read -rsn1
                fi
                return 1
            fi
            
            echo ""
            echo -e "  ${BLUE}[i]${NC} Установка модуля kmod-xt_u32..."
            if sudo dnf install -y kmod-xt_u32 2>&1; then
                echo -e "  ${GREEN}[✓]${NC} Модуль kmod-xt_u32 успешно установлен"
                echo ""
                log_info "Повторная попытка применения правил..."
                echo ""
                
                PORT="$ports_str" /opt/mtpr-simple/apply-mtpr-synfix.sh
                systemctl enable mtpr-synfix.service
                systemctl restart mtpr-synfix.service
                
                echo ""
                log_success "SYN FIX успешно установлен на порты: $ports_str"
                if [ -r /dev/tty ]; then
                    echo -e "  ${GRAY}Нажмите любую клавишу${NC}"
                    read -rsn1 </dev/tty
                else
                    echo -e "  ${GRAY}Нажмите любую клавишу${NC}"
                    read -rsn1
                fi
            else
                echo -e "  ${RED}[✗]${NC} Не удалось установить модуль kmod-xt_u32"
                echo -e "  ${YELLOW}[!]${NC} Попробуйте выбрать старый вариант фикса (TTL+Length)"
                if [ -r /dev/tty ]; then
                    echo -e "  ${GRAY}Нажмите любую клавишу${NC}"
                    read -rsn1 </dev/tty
                else
                    echo -e "  ${GRAY}Нажмите любую клавишу${NC}"
                    read -rsn1
                fi
                return 1
            fi
        else
            log_info "Установка отменена"
            if [ -r /dev/tty ]; then
                echo -e "  ${GRAY}Нажмите любую клавишу...${NC}"
                read -rsn1 </dev/tty
            else
                echo -e "  ${GRAY}Нажмите любую клавишу...${NC}"
                read -rsn1
            fi
            return 1
        fi
    elif [ $apply_exit_code -ne 0 ]; then
        echo ""
        log_error "Ошибка применения правил iptables:"
        echo "$apply_output"
        if [ -r /dev/tty ]; then
            echo -e "  ${GRAY}Нажмите любую клавишу...${NC}"
            read -rsn1 </dev/tty
        else
            echo -e "  ${GRAY}Нажмите любую клавишу...${NC}"
            read -rsn1
        fi
        return 1
    else
        systemctl enable mtpr-synfix.service
        systemctl restart mtpr-synfix.service
        echo ""
        log_success "SYN FIX успешно установлен на порты: $ports_str"
        if [ -r /dev/tty ]; then
            echo -e "  ${GRAY}Нажмите любую клавишу...${NC}"
            read -rsn1 </dev/tty
        else
            echo -e "  ${GRAY}Нажмите любую клавишу...${NC}"
            read -rsn1
        fi
    fi
}

# ── УДАЛЕНИЕ SYN FIX ─────────────────────────────────────────
remove_syn_fix() {
    log_info "Удаление SYN FIX..."

    # Удаляем iptables
    systemctl stop mtpr-synfix.service 2>/dev/null || true
    systemctl disable mtpr-synfix.service 2>/dev/null || true

    if iptables -C INPUT -j "$SYNFIX_CHAIN" 2>/dev/null; then
        iptables -D INPUT -j "$SYNFIX_CHAIN"
        log_info "Цепочка $SYNFIX_CHAIN отключена от INPUT"
    fi

    if iptables -L "$SYNFIX_CHAIN" -n >/dev/null 2>&1; then
        iptables -F "$SYNFIX_CHAIN"
        iptables -X "$SYNFIX_CHAIN"
        log_info "Цепочка $SYNFIX_CHAIN удалена"
    fi

    # ── Удаляем правило маркировки iOS из mangle (новый вариант) ──
    local u32_rule="32 & 0x000FFFFF = 0x0002FFFF && 40 & 0xFF000000 = 0x02000000 && 44 & 0xFFFF0000 = 0x01030000 && 48 & 0xFFFFFF00 = 0x01010800 && 60 & 0xFFFFFFFF = 0x04020000"
    
    # 1. Пытаемся удалить через iptables
    if iptables -t mangle -C PREROUTING -m u32 --u32 "$u32_rule" -j MARK --set-mark 0x400 2>/dev/null; then
        iptables -t mangle -D PREROUTING -m u32 --u32 "$u32_rule" -j MARK --set-mark 0x400
        log_info "Правило маркировки iOS (mangle) удалено через iptables"
    fi

    # 2. Дополнительно удаляем через nftables (на случай, если правило осталось)
    if command -v nft >/dev/null 2>&1; then
        # Проверяем наличие правила в nftables
        if nft list table ip mangle 2>/dev/null | grep -q 'xt match "u32".*meta mark set 0x400'; then
            # Пытаемся удалить по точному совпадению (разные варианты счётчиков)
            nft delete rule ip mangle PREROUTING 'xt match "u32" counter meta mark set 0x400' 2>/dev/null || true
            nft delete rule ip mangle PREROUTING 'xt match "u32" meta mark set 0x400' 2>/dev/null || true
            
            # Если не удалось, ищем по handle и удаляем
            nft -a list chain ip mangle PREROUTING 2>/dev/null | grep 'meta mark set 0x400' | while read -r line; do
                handle=$(echo "$line" | grep -o 'handle [0-9]*' | awk '{print $2}')
                if [ -n "$handle" ]; then
                    nft delete rule ip mangle PREROUTING handle "$handle" 2>/dev/null || true
                    log_info "Правило маркировки iOS удалено через nftables (handle $handle)"
                fi
            done
        fi
    fi

    rm -f "$PORT_FILE"
    rm -f /etc/systemd/system/mtpr-synfix.service

    # Удаляем nftables
    systemctl stop mtpr-nft-synfix.service 2>/dev/null || true
    systemctl disable mtpr-nft-synfix.service 2>/dev/null || true
    rm -f /etc/systemd/system/mtpr-nft-synfix.service
    nft delete table inet mtpr_synfix 2>/dev/null || true
    rm -f /opt/mtpr-simple/mtpr-synfix-nft.sh

    systemctl daemon-reload

    log_success "SYN FIX (iptables + nftables) удалён"
}
 
