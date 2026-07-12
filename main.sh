#!/bin/bash
set -eo pipefail

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

# ── Проверка root ────────────────────────────────────────────
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "Требуются права root"
        exit 1
    fi
}

check_root

# ── Файл для сохранения пути к конфигу ──────────────────────
CONFIG_PATH_FILE="/opt/mtpr-simple/config_path"

# ── Функция обрезки пробелов ──────────────────────────────
trim() {
    local var="$1"
    var="${var#"${var%%[![:space:]]*}"}"
    var="${var%"${var##*[![:space:]]}"}"
    printf '%s' "$var"
}

# ── Функции для работы с TOML ──────────────
_toml_get_value() {
    local _key="$1" _file="$2"
    [ -f "$_file" ] || return 0
    awk -v k="$_key" '
        /^[[:space:]]*#/ { next }
        $1 == k && $2 == "=" { gsub(/[^0-9]/, "", $3); print $3; exit }
    ' "$_file" 2>/dev/null
}

_toml_has_section() {
    local _section="$1" _file="$2"
    grep -qE "^\\[${_section}\\]" "$_file" 2>/dev/null
}

_toml_has_key() {
    local _key="$1" _file="$2"
    grep -qE "^${_key}[[:space:]]*=" "$_file" 2>/dev/null
}

_is_excluded_path() {
    local _path="$1"
    case "$_path" in
        *telemt-panel*|*telemt_panel*) return 0 ;;
    esac
    return 1
}

_looks_like_telemt_config() {
    local _file="$1"
    [ -f "$_file" ] || return 1
    grep -qE '^\[access\.users\]|^\[censorship\]|^\[general\.modes\]|^tls_domain[[:space:]]*=' "$_file" 2>/dev/null
}

# ── Функция проверки установки Telemt (сначала версия) ──────
is_telemt_installed() {
    command -v telemt >/dev/null 2>&1
}

get_telemt_version() {
    if command -v telemt >/dev/null 2>&1; then
        telemt --version 2>/dev/null | head -1 | awk '{print $2}'
    else
        echo ""
    fi
}

# ── Расширенное обнаружение Telemt (возвращает ВСЕ конфиги) ──
detect_all_telemt_configs() {
    local FOUND_CONFIGS=""
    local SEEN_PATHS=""
    
    # 1. Смотрим запущенные процессы telemt
    if pgrep -x telemt &>/dev/null || timeout 2 systemctl is-active telemt.service &>/dev/null 2>&1; then
        local _args_list
        _args_list=$(timeout 3 ps -eo args 2>/dev/null | grep '[t]elemt' | grep -v 'telemt-panel' | grep -v 'telemt_panel' | grep -oE '/[^ ]+\.toml' | sort -u)
        for _arg in $_args_list; do
            _arg=$(trim "$_arg")
            if [ -n "$_arg" ] && [ -f "$_arg" ] && ! _is_excluded_path "$_arg" && _looks_like_telemt_config "$_arg"; then
                if ! echo "$SEEN_PATHS" | grep -qF "$_arg"; then
                    SEEN_PATHS="${SEEN_PATHS}${_arg}\n"
                    FOUND_CONFIGS="${FOUND_CONFIGS}${_arg}:"
                fi
            fi
        done
    fi
    
    # 2. Поиск конфигов в стандартных местах
    local _cf
    for _cf in /etc/telemt/telemt.toml /etc/telemt/config.toml /etc/telemt.toml /opt/telemt/config.toml /opt/telemt/telemt.toml; do
        _cf=$(trim "$_cf")
        if [ -n "$_cf" ] && [ -f "$_cf" ] && ! _is_excluded_path "$_cf" && _looks_like_telemt_config "$_cf"; then
            if ! echo "$SEEN_PATHS" | grep -qF "$_cf"; then
                SEEN_PATHS="${SEEN_PATHS}${_cf}\n"
                FOUND_CONFIGS="${FOUND_CONFIGS}${_cf}:"
            fi
        fi
    done
    
    # 3. Проверяем сохранённый путь
    if [ -f "$CONFIG_PATH_FILE" ] && [ -s "$CONFIG_PATH_FILE" ]; then
        local _saved_path=$(trim "$(cat "$CONFIG_PATH_FILE")")
        if [ -n "$_saved_path" ] && [ "$_saved_path" != "skip" ] && [ -f "$_saved_path" ] && _looks_like_telemt_config "$_saved_path"; then
            if ! echo "$SEEN_PATHS" | grep -qF "$_saved_path"; then
                SEEN_PATHS="${SEEN_PATHS}${_saved_path}\n"
                FOUND_CONFIGS="${FOUND_CONFIGS}${_saved_path}:"
            fi
        fi
    fi
    
    # Убираем последнее двоеточие и лишние пробелы
    FOUND_CONFIGS=$(trim "${FOUND_CONFIGS%:}")
    
    echo "$FOUND_CONFIGS"
}

# ── Функция получения порта из конфига ──────────────────────
get_port_from_config() {
    local _cfg="$1"
    _cfg=$(trim "$_cfg")
    
    if [ -z "$_cfg" ] || [ ! -f "$_cfg" ]; then
        echo ""
        return 1
    fi
    
    # Способ 1: Прямой grep + sed (самый надёжный)
    local _port=$(grep -E '^[[:space:]]*port[[:space:]]*=' "$_cfg" 2>/dev/null | head -1 | sed -E 's/^[[:space:]]*port[[:space:]]*=[[:space:]]*//; s/[^0-9]//g')
    
    # Способ 2: Если не нашлось — пробуем через _toml_get_value
    if [ -z "$_port" ]; then
        _port=$(_toml_get_value "port" "$_cfg")
    fi
    
    # Способ 3: Если всё ещё нет — пробуем через grep без sed (вдруг там кавычки)
    if [ -z "$_port" ]; then
        _port=$(grep -E '^[[:space:]]*port[[:space:]]*=' "$_cfg" 2>/dev/null | head -1 | awk -F'=' '{print $2}' | tr -d ' "')
    fi
    
    # Проверяем, что порт — это число
    if [[ "$_port" =~ ^[0-9]+$ ]]; then
        echo "$_port"
    else
        echo ""
    fi
    
    return 0
}

# ── Функция получения онлайна для конкретного конфига ────────
get_telemt_online_for_config() {
    local _cfg="$1"
    _cfg=$(trim "$_cfg")
    
    if [ -z "$_cfg" ] || [ ! -f "$_cfg" ]; then
        echo "0"
        return 1
    fi
    
    local _port=$(get_port_from_config "$_cfg")
    if [ -z "$_port" ]; then
        echo "0"
        return 1
    fi
    
    # Пробуем через API
    local _online=$(curl -s --max-time 2 --connect-timeout 1 "http://127.0.0.1:9091/v1/stats/users/active-ips" 2>/dev/null | grep -o '"active_ips":\[[^]]*\]' | grep -o '[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}' | wc -l | tr -d ' ')
    if [ -z "$_online" ] || [ "$_online" -lt 0 ] 2>/dev/null; then
        echo "0"
    else
        echo "$_online"
    fi
}

# ── Проверка MSS в конкретном конфиге ──────────────────────
is_mss_enabled_for_config() {
    local _cfg="$1"
    _cfg=$(trim "$_cfg")
    if [ -z "$_cfg" ] || [ ! -f "$_cfg" ]; then
        return 1
    fi
    if grep -E '^[[:space:]]*client_mss[[:space:]]*=' "$_cfg" | grep -v '^#' | grep -q .; then
        return 0
    fi
    return 1
}

is_mss_bulk_enabled_for_config() {
    local _cfg="$1"
    _cfg=$(trim "$_cfg")
    if [ -z "$_cfg" ] || [ ! -f "$_cfg" ]; then
        return 1
    fi
    if grep -E '^[[:space:]]*mss_bulk[[:space:]]*=' "$_cfg" | grep -v '^#' | grep -q .; then
        return 0
    fi
    return 1
}

is_synlimit_enabled_for_config() {
    local _cfg="$1"
    _cfg=$(trim "$_cfg")
    if [ -z "$_cfg" ] || [ ! -f "$_cfg" ]; then
        return 1
    fi
    if grep -E '^[[:space:]]*synlimit[[:space:]]*=' "$_cfg" | grep -v '^#' | grep -q .; then
        return 0
    fi
    return 1
}

# ── Проверяем, сохранён ли путь к конфигу ──────────────────
if [ -f "$CONFIG_PATH_FILE" ] && [ -s "$CONFIG_PATH_FILE" ]; then
    CONFIG_TELEMT=$(cat "$CONFIG_PATH_FILE")
    if [ "$CONFIG_TELEMT" = "skip" ]; then
        CONFIG_TELEMT=""
    fi
else
    # Определяем, установлен ли Telemt
    TELEMT_VERSION=$(get_telemt_version)
    
    echo ""
    echo -e "  ${NC}${BOLD}Укажите путь к конфигу Telemt${NC}"
    echo -e "  ${NC}${BOLD}По умолчанию: ${GREEN}${BOLD}[/etc/telemt/telemt.toml]${NC}"
    
    if [ -n "$TELEMT_VERSION" ]; then
        # Telemt найден — ищем конфиги
        _detected_configs=$(detect_all_telemt_configs)
        _detected_path=$(echo "$_detected_configs" | cut -d':' -f1)
        
        if [ -n "$_detected_path" ] && [ -f "$_detected_path" ]; then
            echo -e "  ${NC}${BOLD}Телемт найден по пути: ${GREEN}${BOLD}${_detected_path}${NC}"
            echo -e "  ${NC}${BOLD}Если путь определён верно — нажмите ${GREEN}${BOLD}Enter${NC}"
        else
            echo -e "  ${NC}${BOLD}Телемт найден (версия ${TELEMT_VERSION}), но конфиг не обнаружен.${NC}"
            echo -e "  ${NC}${BOLD}Если путь определён верно — нажмите ${GREEN}${BOLD}Enter${NC}"
        fi
    else
        echo -e "  ${NC}${BOLD}Телемт не найден.${NC}"
        echo -e "  ${NC}${BOLD}Если Telemt не установлен - нажмите ${GREEN}${BOLD}Enter${NC}"
    fi
    
    echo ""
    echo -en "  ${BOLD}Ввод:${NC} "
    read -r CONFIG_TELEMT_INPUT

    if [[ "$CONFIG_TELEMT_INPUT" =~ ^[Nn]$ ]]; then
        mkdir -p /opt/mtpr-simple
        echo "skip" > "$CONFIG_PATH_FILE"
        CONFIG_TELEMT=""
    else
        if [ -z "$CONFIG_TELEMT_INPUT" ]; then
            # Если Enter — пробуем определить автоматически
            _detected_configs=$(detect_all_telemt_configs)
            _detected_path=$(echo "$_detected_configs" | cut -d':' -f1)
            
            if [ -n "$_detected_path" ] && [ -f "$_detected_path" ]; then
                CONFIG_TELEMT_INPUT="$_detected_path"
            else
                # Если Telemt не найден и Enter — делаем skip
                if [ -z "$TELEMT_VERSION" ]; then
                    log_info "Telemt не найден, пропускаем настройку конфига"
                    mkdir -p /opt/mtpr-simple
                    echo "skip" > "$CONFIG_PATH_FILE"
                    CONFIG_TELEMT=""
                else
                    CONFIG_TELEMT_INPUT="/etc/telemt/telemt.toml"
                fi
            fi
        fi

        # Если CONFIG_TELEMT_INPUT не пустой, пробуем сохранить
        if [ -n "$CONFIG_TELEMT_INPUT" ]; then
            if [ ! -f "$CONFIG_TELEMT_INPUT" ]; then
                log_warning "Файл $CONFIG_TELEMT_INPUT не найден."
                echo -en "  ${BOLD}Сохранить этот путь всё равно? [y/N]:${NC} "
                confirm_path=""
                read -r confirm_path
                if [[ ! "$confirm_path" =~ ^[yY]$ ]]; then
                    log_error "Путь к конфигу не подтверждён, выход."
                    exit 1
                fi
            fi

            mkdir -p /opt/mtpr-simple
            echo "$CONFIG_TELEMT_INPUT" > "$CONFIG_PATH_FILE"
            CONFIG_TELEMT="$CONFIG_TELEMT_INPUT"
        fi
    fi
fi

# ── Файл для хранения порта ─────────────────────────────────
PORT_FILE="/opt/mtpr-simple/port"

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

get_saved_port() {
    if [ -f "$PORT_FILE" ]; then
        cat "$PORT_FILE"
    else
        echo ""
    fi
}

save_port() {
    echo "$1" >"$PORT_FILE"
}

# ── Функция получения порта Telemt ──────────────────────────
get_telemt_port() {
    local config_path="$1"
    if [ -z "$config_path" ] || [ ! -f "$config_path" ]; then
        echo ""
        return 1
    fi
    _toml_get_value "port" "$config_path"
}

# ── Название кастомной цепочки iptables ─────────────────────
SYNFIX_CHAIN="MTPR_SYNFIX"

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

is_our_syn_fix_installed() {
    is_syn_fix_chain_installed
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
        echo -en "  ${BOLD}Введите порты для SYN FIX (через запятую, например: 443,8443,8080):${NC} "
        read -r ports_input
        if [ -z "$ports_input" ]; then
            ports_input="443"
        fi

        echo ""
        echo -e "  ${BOLD}Выберите тип SYN FIX:${NC}"
        echo -e "  ${GREEN}[1]${NC}  ${BOLD}Новый вариант(iptables)${NC} (Разделение устройств с помощью u32 по байтам из пакета) — ${GREEN}рекомендуется${NC}"
        echo -e "${NC}  Если совпало -> это ios и принимаем пакеты без лимита"
        echo -e "${NC}  Если не совпало -> это другое ус-во и ставим SYN 1/s"
        echo -e "  ${CYAN}[2]${NC}  ${BOLD}Старый вариант(iptables)${NC} (Разделение устройств определяя их TTL+Length)"
        echo -e "${NC}  Если TTL <65 и length 64 -> это ios и принимаем пакеты без лимита"
        echo -e "${NC}  Иначе -> это другое ус-во и ставим SYN 1/s"
        echo ""
        echo -e "  ${YELLOW}[3]${NC}  ${BOLD}Новый вариант(nftables)${NC}${BOLD} - рекомендуется для nftables${NC}"
        echo -e "${NC}  Если совпало -> это ios и принимаем пакеты без лимита"
        echo -e "${NC}  Если не совпало -> это другое ус-во и ставим SYN 1/s"
        echo -e "  ${YELLOW}[4]${NC}  ${BOLD}Старый вариант(nftables)${NC}${BOLD}"
        echo -e "${NC}  Если TTL <65 и length 64 -> это ios и принимаем пакеты без лимита"
        echo -e "${NC}  Иначе -> это другое ус-во и ставим SYN 1/s"
        echo ""
        echo -en "  ${NC}${BOLD}Ввод (Новый - ${GREEN}${BOLD}1 или enter${NC}${BOLD}, старый - ${RED}${BOLD}2${NC}${BOLD}, nftables Новый - ${YELLOW}${BOLD}3${NC}${BOLD}, nftables старый - ${RED}${BOLD}4${NC}${BOLD}):${NC} "
        read -r fix_choice

        if [ -z "$fix_choice" ] || [ "$fix_choice" = "1" ]; then
            FIX_TYPE="new"
            log_info "Выбран новый вариант фикса"
        elif [ "$fix_choice" = "2" ]; then
            FIX_TYPE="old"
            log_info "Выбран старый вариант фикса"
        elif [ "$fix_choice" = "3" ]; then
            FIX_TYPE="docker_smart"
            log_info "Выбран nftables Smart By-MEKO"
        elif [ "$fix_choice" = "4" ]; then
            FIX_TYPE="docker_classic"
            log_info "Выбран nftables Classic"
        else
            log_warning "Неверный выбор, используем новый вариант"
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
        echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
        read -rsn1
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
                echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
                read -rsn1
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
            echo -en "  ${BOLD}Продолжить установку? [y/N]:${NC} "
            local confirm
            read -r confirm
            if [[ ! "$confirm" =~ ^[yY]$ ]]; then
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
            echo ""
            echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
            read -rsn1
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
        echo ""
        echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
        read -rsn1
        return 0
    fi

    # ── Старые iptables режимы (1 и 2) ──────────────────────
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
        echo -en "  ${BOLD}Продолжить установку? [y/N]:${NC} "
        local confirm
        read -r confirm
        if [[ ! "$confirm" =~ ^[yY]$ ]]; then
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
        echo -en "  ${BOLD}Ввод:${NC} "
        read -r install_u32

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
                echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
                read -rsn1
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
                echo ""
                echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
                read -rsn1
            else
                echo -e "  ${RED}[✗]${NC} Не удалось установить модуль kmod-xt_u32"
                echo -e "  ${YELLOW}[!]${NC} Попробуйте выбрать старый вариант фикса (TTL+Length)"
                echo ""
                echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
                read -rsn1
                return 1
            fi
        else
            log_info "Установка отменена"
            echo ""
            echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
            read -rsn1
            return 1
        fi
    elif [ $apply_exit_code -ne 0 ]; then
        echo ""
        log_error "Ошибка применения правил iptables:"
        echo "$apply_output"
        echo ""
        echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
        read -rsn1
        return 1
    else
        systemctl enable mtpr-synfix.service
        systemctl restart mtpr-synfix.service
        echo ""
        log_success "SYN FIX успешно установлен на порты: $ports_str"
        echo ""
        echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
        read -rsn1
    fi
}

# ── Удаление правил из файла iptables ──────────────────────
remove_iptables_rules() {
    local rules_file="/etc/iptables/rules.v4"
    
    if [ ! -f "$rules_file" ]; then
        log_warning "Файл $rules_file не найден"
        return 1
    fi
    
    log_info "Проверка наличия наших правил в $rules_file..."
    
    if ! grep -q "MTPR_SYNFIX" "$rules_file"; then
        log_warning "Наши правила (MTPR_SYNFIX) не найдены в файле"
        return 1
    fi
    
    echo ""
    echo -e "  ${BOLD}Обнаружены наши правила SYN FIX в файле${NC}"
    echo -e "  ${DIM}Что будет сделано:${NC}"
    echo -e "  • Будут удалены только строки с цепочкой $SYNFIX_CHAIN"
    echo ""
    log_warning "Это изменит конфигурацию iptables-persistent!"
    echo ""
    echo -en "  ${BOLD}Подтвердить удаление? [y/N]:${NC} "
    local confirm
    read -r confirm
    
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        log_info "Удаление отменено"
        return 0
    fi
    
    echo ""
    
    local temp_file=$(mktemp)
    grep -v "MTPR_SYNFIX" "$rules_file" > "$temp_file"
    mv "$temp_file" "$rules_file"
    chmod 644 "$rules_file"
    
    log_success "Правила $SYNFIX_CHAIN удалены из $rules_file"
}

# ── Удаление SYN FIX (iptables + nftables) ────────────────
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

restart_syn_fix_service() {
    log_info "Перезапуск сервиса mtpr-synfix.service..."
    systemctl restart mtpr-synfix.service
    log_success "Сервис успешно перезапущен"
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

# обратно в INPUT
iptables -t filter -A "$CHAIN" -j RETURN

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

# обратно в INPUT
iptables -t filter -A "$CHAIN" -j RETURN

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


# ── Пункт 3: Базовая оптимизация ───────────────────────────
apply_basic_optimization() {
    echo ""
    log_info "Выполнение базовой оптимизации системы и Telemt..."

    if [ -n "$CONFIG_TELEMT" ] && [ -f "$CONFIG_TELEMT" ]; then
        systemctl stop telemt 2>/dev/null || true

        if grep -q '^max_connections *=.*' "$CONFIG_TELEMT"; then
            if ! grep -q '^max_connections *= *16384' "$CONFIG_TELEMT"; then
                sed -i 's/^max_connections *= *.*/max_connections = 16384/' "$CONFIG_TELEMT"
            fi
        else
            grep -q '\[server\]' "$CONFIG_TELEMT" && sed -i '/\[server\]/a max_connections = 16384' "$CONFIG_TELEMT"
        fi

        if grep -q '^client_handshake *=.*' "$CONFIG_TELEMT"; then
            if ! grep -q '^client_handshake *= *15' "$CONFIG_TELEMT"; then
                sed -i 's/^client_handshake *= *.*/client_handshake = 15/' "$CONFIG_TELEMT"
            fi
        fi

        systemctl restart telemt 2>/dev/null || true
    else
        log_warning "Файл конфига Telemt не найден или не указан, пропускаем оптимизацию параметров Telemt"
    fi

    if [ ! -f /etc/sysctl.conf ]; then
        touch /etc/sysctl.conf
        chmod 644 /etc/sysctl.conf
        log_info "Создан /etc/sysctl.conf"
    fi

    mkdir -p /etc/systemd/system/telemt.service.d

    if ! grep -q "LimitNOFILE=65535" /etc/systemd/system/telemt.service.d/limits.conf 2>/dev/null; then
        cat >/etc/systemd/system/telemt.service.d/limits.conf <<EOF
[Service]
LimitNOFILE=65535
EOF
    fi

    systemctl daemon-reload

    apply_sysctl() {
        cat >/etc/sysctl.d/99-custom.conf <<EOF
net.ipv4.tcp_fastopen=3
net.core.somaxconn=65535
net.ipv4.tcp_max_syn_backlog=65535
net.core.netdev_max_backlog=65535
fs.file-max=2097152
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_keepalive_time=45
net.ipv4.tcp_keepalive_intvl=15
net.ipv4.tcp_keepalive_probes=3
EOF

        sysctl --system 2>/dev/null || log_info "sysctl --system выполнен без изменений"
    }

    apply_sysctl

    log_success "Базовая оптимизация выполнена"
}

# ── Пункт 4: Полное удаление MEKOpr ─────────────────────────
remove_mekopr() {
    echo ""
    log_warning "${BOLD}ВНИМАНИЕ:${NC} Будет выполнено полное удаление MEKOpr со всеми его конфигами и правилами!"
    echo ""
    echo -e "  ${BOLD}Что будет удалено:${NC}"
    echo -e "  • Все iptables правила и цепочка ${CYAN}$SYNFIX_CHAIN${NC}"
    echo -e "  • Все nftables правила (mtpr_synfix)${NC}"
    echo -e "  • Все файлы конфигурации в ${CYAN}/opt/mtpr-simple${NC}"
    echo -e "  • Сам скрипт ${CYAN}$0${NC}"
    echo ""
    log_warning "Это действие нельзя отменить!"
    echo -en "  ${BOLD}Продолжить удаление? [y/N]:${NC} "
    local confirm
    read -r confirm

    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        log_info "Удаление отменено"
        return
    fi

    log_info "Начинаем полное удаление MEKOpr..."

    remove_syn_fix

    log_info "Удаление файлов конфигурации..."
    rm -rf /opt/mtpr-simple

    log_info "Удаление скрипта..."
    rm -f "$0"

    log_success "MEKOpr полностью удалён с сервера!"
    echo ""
    log_info "Для завершения работы скрипта нажмите Enter..."
    read -r
    exit 0
}

# ── Очистка экрана и шапка ──────────────────────────────────
clear_screen() {
    clear 2>/dev/null || printf '\033[2J\033[H'
}

is_mtprotozig_installed() {
    command -v mtbuddy >/dev/null 2>&1
}

# ── Функция получения онлайна Mtprotozig для конфига ────────────
get_mtprotozig_online() {
    if is_mtprotozig_installed; then
        sudo journalctl -u mtproto-proxy -n 50 2>/dev/null | grep -o 'users_total=[0-9]*' | tail -1 | cut -d'=' -f2
    else
        echo ""
    fi
}

get_online_count() {
    local port="443"
    if [ -n "$CONFIG_TELEMT" ] && [ -f "$CONFIG_TELEMT" ]; then
        local config_port=$(grep -E '^port[[:space:]]*=' "$CONFIG_TELEMT" | head -1 | awk -F'=' '{print $2}' | tr -d ' "')
        if [[ "$config_port" =~ ^[0-9]+$ ]]; then
            port="$config_port"
        fi
    fi
    ss -tnp 2>/dev/null | grep ":${port}" | grep -v '0.0.0.0' | awk '{print $5}' | cut -d: -f1 | sort -u | wc -l | tr -d ' '
}

show_header() {
    clear_screen
    echo ""
    echo -e "  ${NC}${BOLD}MEKO ${CYAN}${BOLD}| ${NC}${BOLD}MTProto Launcher  v1.7${NC}"
    echo -e "  ${DIM}===========================${NC}"
    echo ""

    # ── ПОЛУЧАЕМ ИНФОРМАЦИЮ ОБ ОС ──────────────────────────
    local os_name=""
    local os_version=""
    
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        os_name="$NAME"
        os_version="$VERSION_ID"
    elif [ -f /etc/lsb-release ]; then
        . /etc/lsb-release
        os_name="$DISTRIB_DESCRIPTION"
        os_version="$DISTRIB_RELEASE"
    elif [ -f /etc/debian_version ]; then
        os_name="Debian"
        os_version=$(cat /etc/debian_version)
    elif [ -f /etc/almalinux-release ]; then
        os_name="AlmaLinux"
        os_version=$(cat /etc/almalinux-release | awk '{print $3}')
    elif [ -f /etc/redhat-release ]; then
        os_name="Red Hat"
        os_version=$(cat /etc/redhat-release | grep -oE '[0-9]+\.[0-9]+' | head -1)
    else
        os_name="Unknown OS"
        os_version=""
    fi

    if [ -n "$os_name" ] && [ -n "$os_version" ]; then
        echo -e "  ${BOLD}${os_name}:${NC} ${YELLOW}${BOLD}${os_version}${NC}"
    elif [ -n "$os_name" ]; then
        echo -e "  ${BOLD}${os_name}${NC}"
    fi

    # ── ПОЛУЧАЕМ IP-АДРЕС СЕРВЕРА ──────────────────────────
    local server_ip=""
    if command -v ip >/dev/null 2>&1; then
        server_ip=$(ip route get 1 2>/dev/null | grep -o 'src [0-9.]*' | awk '{print $2}' | head -1)
    fi
    if [ -z "$server_ip" ]; then
        server_ip=$(curl -4 -fsS --max-time 3 https://api.ipify.org 2>/dev/null)
    fi
    if [ -z "$server_ip" ]; then
        server_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    if [ -z "$server_ip" ]; then
        server_ip="не определено"
    fi

    # ── ПОЛУЧАЕМ ОТКРЫТЫЕ ПОРТЫ ─────────────────────────────
    local open_ports=""
    if [ -f "$PORT_FILE" ] && [ -s "$PORT_FILE" ]; then
        open_ports=$(cat "$PORT_FILE")
    fi
    if [ -z "$open_ports" ] || [ "$open_ports" = "skip" ]; then
        if [ -n "$CONFIG_TELEMT" ] && [ -f "$CONFIG_TELEMT" ]; then
            local telemt_port=$(get_port_from_config "$CONFIG_TELEMT")
            if [ -n "$telemt_port" ]; then
                open_ports="$telemt_port"
            fi
        fi
    fi
    if [ -z "$open_ports" ]; then
        open_ports="не определено"
    fi

    echo -e "  ${BOLD}IP:${NC} ${CYAN}${server_ip}${NC}"
    echo -e "  ${BOLD}Порты для прокси:${NC} ${CYAN}${open_ports}${NC}"

    # ── ПОЛУЧАЕМ ВЕРСИЮ OPENSSL ─────────────────────────────
    local openssl_version=""
    local openssl_display=""
    local openssl_color=""
    
    if command -v openssl &>/dev/null; then
        openssl_version=$(openssl version 2>/dev/null | awk '{print $2}' | cut -d'-' -f1 | cut -d'+' -f1)
        
        if [ -n "$openssl_version" ]; then
            if [[ "$(printf '%s\n' "3.5" "$openssl_version" | sort -V | head -n1)" = "3.5" ]]; then
                openssl_color="${GREEN}${BOLD}"
                openssl_display="${openssl_version}"
            else
                openssl_color="${RED}${BOLD}"
                openssl_display="${openssl_version} ${YELLOW}${BOLD}(не подходит для SelfSteal SNI)${NC}"
            fi
            echo -e "  ${BOLD}OpenSSL:${NC} ${openssl_color}${openssl_display}${NC}"
        fi
    fi

    # ── ПЕРЕЧИТЫВАЕМ ПУТЬ К КОНФИГУ ──────────────────────────
    local current_config_path=""
    if [ -f "$CONFIG_PATH_FILE" ] && [ -s "$CONFIG_PATH_FILE" ]; then
        local _saved=$(cat "$CONFIG_PATH_FILE")
        if [ "$_saved" != "skip" ] && [ -n "$_saved" ]; then
            current_config_path="$_saved"
        fi
    fi
    if [ -z "$current_config_path" ] && [ -n "$CONFIG_TELEMT" ] && [ "$CONFIG_TELEMT" != "skip" ]; then
        current_config_path="$CONFIG_TELEMT"
    fi
    if [ -n "$current_config_path" ] && [ ! -f "$current_config_path" ]; then
        local _detected=$(detect_all_telemt_configs)
        local _first=$(echo "$_detected" | cut -d':' -f1)
        if [ -n "$_first" ] && [ -f "$_first" ]; then
            current_config_path="$_first"
            echo "$_first" > "$CONFIG_PATH_FILE"
        fi
    fi

    if [ -n "$current_config_path" ] && [ -f "$current_config_path" ]; then
        CONFIG_TELEMT="$current_config_path"
    elif [ -z "$current_config_path" ] || [ ! -f "$current_config_path" ]; then
        local _detected=$(detect_all_telemt_configs)
        local _first=$(echo "$_detected" | cut -d':' -f1)
        if [ -n "$_first" ] && [ -f "$_first" ]; then
            CONFIG_TELEMT="$_first"
            echo "$_first" > "$CONFIG_PATH_FILE"
        else
            CONFIG_TELEMT=""
        fi
    fi

    # ── СТАТУС SYN FIX (iptables + nftables) ──────────────
    local iptables_status=$(get_synfix_status)
    local nft_status=$(get_nft_fix_status)
    
    if [ "$iptables_status" = "active" ]; then
        echo -e "  ${BOLD}SYN FIX (iptables):${NC} ${GREEN}Установлен${NC}"
    elif [ "$iptables_status" = "has_chain_only" ]; then
        echo -e "  ${BOLD}SYN FIX (iptables):${NC} ${YELLOW}Цепочка есть, сервис не запущен${NC}"
    else
        echo -e "  ${BOLD}SYN FIX (iptables):${NC} ${RED}Не установлен${NC}"
    fi

    if [ "$nft_status" = "active" ]; then
        echo -e "  ${BOLD}SYN FIX (nftables (работает с Docker)):${NC} ${GREEN}Установлен${NC}"
    elif [ "$nft_status" = "has_table_only" ]; then
        echo -e "  ${BOLD}SYN FIX (nftables (работает с Docker)):${NC} ${YELLOW}Таблица есть, сервис не запущен${NC}"
    else
        echo -e "  ${BOLD}SYN FIX (nftables (работает с Docker)):${NC} ${RED}Не установлен${NC}"
    fi

    local telemt_installed=false
    local mtprotozig_installed=false
    
    if is_telemt_installed; then
        telemt_installed=true
    fi
    if is_mtprotozig_installed; then
        mtprotozig_installed=true
    fi

    # ── ВЫВОДИМ ВСЕ НАЙДЕННЫЕ КОНФИГИ TELEMT ──────────────────
    local all_configs=$(detect_all_telemt_configs)
    local configs_array=()
    if [ -n "$all_configs" ]; then
        IFS=':' read -ra configs_array <<< "$all_configs"
    fi

    local first_config=true
    
    if [ ${#configs_array[@]} -gt 0 ]; then
        for cfg in "${configs_array[@]}"; do
            if [ -z "$cfg" ] || [ ! -f "$cfg" ]; then
                continue
            fi
            
            local _port=$(get_port_from_config "$cfg")
            local _version=$(get_telemt_version)
            local _online=$(get_telemt_online_for_config "$cfg")
            local _mss_enabled=$(is_mss_enabled_for_config "$cfg" && echo "включен" || echo "отключен")
            local _mss_bulk_enabled=$(is_mss_bulk_enabled_for_config "$cfg" && echo "включен" || echo "отключен")
            local _synlimit_enabled=$(is_synlimit_enabled_for_config "$cfg" && echo "включен" || echo "отключен")
            
            local version_color=""
            if [ "$_version" = "3.4.18" ]; then
                version_color="${GREEN}"
            elif [[ "$(printf '%s\n' "3.4.18" "$_version" | sort -V | head -n1)" != "3.4.18" ]]; then
                version_color="${RED}"
            else
                version_color="${YELLOW}"
            fi
            
            if [ "$first_config" = true ]; then
                first_config=false
            fi
            
            local port_display=""
            if [ -n "$_port" ] && [[ "$_port" =~ ^[0-9]+$ ]]; then
                port_display=" Port: ${_port}"
            else
                port_display=" (порт не определён)"
            fi
            
            local mss_color="${GREEN}"
            local mss_bulk_color="${GREEN}"
            local synlimit_color="${GREEN}"
            
            [ "$_mss_enabled" = "включен" ] && mss_color="${RED}"
            [ "$_mss_bulk_enabled" = "включен" ] && mss_bulk_color="${RED}"
            [ "$_synlimit_enabled" = "включен" ] && synlimit_color="${RED}"
            
            echo -e "  ${BOLD}Telemt V:${NC} ${version_color}${_version}${NC}${port_display}"
            echo -e "  ${BOLD}Подключено к прокси Telemt:${NC} ${CYAN}${_online}${NC}${BOLD} человек"
            echo -e "  ${BOLD}Встроенный MSS:${NC} ${mss_color}${_mss_enabled}${NC}  |  ${BOLD}MSS_BULK:${NC} ${mss_bulk_color}${_mss_bulk_enabled}${NC}  |  ${BOLD}Synlimit:${NC} ${synlimit_color}${_synlimit_enabled}${NC}"
        done
    elif [ "$telemt_installed" = true ] && [ ${#configs_array[@]} -eq 0 ]; then
        local _version=$(get_telemt_version)
        local version_color=""
        if [ "$_version" = "3.4.18" ]; then
            version_color="${GREEN}"
        elif [[ "$(printf '%s\n' "3.4.18" "$_version" | sort -V | head -n1)" != "3.4.18" ]]; then
            version_color="${RED}"
        else
            version_color="${YELLOW}"
        fi
        echo -e "  ${BOLD}Telemt V:${NC} ${version_color}${_version}${NC} ${YELLOW}(конфиг не найден)${NC}"
    fi

    # ── ИНФОРМАЦИЯ О MTPROTOZIG ─────────────────────────────
    if [ "$mtprotozig_installed" = true ]; then
        local online_count=$(get_mtprotozig_online)
        if [ -n "$online_count" ] && [ "$online_count" -ge 0 ] 2>/dev/null; then
            echo -e "  ${BOLD}Подключено к прокси Mtproto.zig:${NC} ${CYAN}$online_count${NC} человек"
        else
            echo -e "  ${BOLD}Подключено к прокси Mtproto.zig:${NC} ${CYAN}0${NC} человек"
        fi
    fi

    if [ "$telemt_installed" = false ] && [ "$mtprotozig_installed" = false ]; then
        echo -e "  ${RED}${BOLD}Прокси не установлены${NC}"
    fi

    echo ""
}

# ── Функция проверки статуса базовой оптимизации ──────────
is_optimization_applied() {
    local check_count=0

    if [ ! -f /etc/sysctl.d/99-custom.conf ]; then
        return 1
    fi

    [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = "bbr" ] \
        && check_count=$((check_count + 1))

    [ "$(sysctl -n net.core.default_qdisc 2>/dev/null)" = "fq" ] \
        && check_count=$((check_count + 1))

    [ "$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null)" = "3" ] \
        && check_count=$((check_count + 1))

    [ "$check_count" -ge 2 ]
}

# ── Функция открытия меню прокси ──────────────────────────
open_proxy_menu() {
    local PROXY_MENU_SCRIPT="/opt/mtpr-simple/proxys/proxymenu.sh"
    if [ -f "$PROXY_MENU_SCRIPT" ]; then
        exec "$PROXY_MENU_SCRIPT"
    else
        log_error "Файл $PROXY_MENU_SCRIPT не найден"
        echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
        read -rsn1
    fi
}

# ── Функция проверки ограничений сервера ──────────────────
check_censor() {
    echo ""
    log_info "Проверка ограничений на сервере..."
    echo ""
    wget -qO- censorcheck.tlab.pw | bash
    echo ""
    echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
    read -rsn1
}

# ── Главное меню ─────────────────────────────────────────────
main_menu() {
    local auto_install=false
    if [[ "$1" == "-auto_install" ]]; then
        auto_install=true
        local forced_port="$2"
        echo -e "  ${BLUE}[i]${NC} Запуск в режиме авто-установки SYN FIX..."
        install_syn_fix -auto_install "$forced_port"
        echo ""
        # Для авто-установки оставляем один read, он уже есть внутри install_syn_fix
        return 0
    fi

    while true; do
        local show_iptables_rules=false
        if [ -f /etc/iptables/rules.v4 ]; then
            if grep -q "MTPR_SYNFIX" /etc/iptables/rules.v4 2>/dev/null; then
                show_iptables_rules=true
            fi
        fi
        
        show_header
        echo ""

        local iptables_status=$(get_synfix_status)
        local nft_status=$(get_nft_fix_status)
        
        if [ "$iptables_status" = "inactive" ] && [ "$nft_status" = "inactive" ]; then
            local item1="${GREEN}${BOLD}Установить SYN FIX${NC}"
        else
            local item1="${RED}${BOLD}Удалить SYN FIX${NC}"
        fi

        if is_optimization_applied; then
            local item2_text="${GRAY}${BOLD}Выполнить базовую оптимизацию (уже применена)${NC}"
        else
            local item2_text="${GREEN}${BOLD}Выполнить базовую оптимизацию${NC}"
        fi

        echo -e "  ${CYAN}[1]${NC}  $item1"
        echo -e "  ${CYAN}[2]${NC}  $item2_text"
        echo -e "  ${CYAN}[3]${NC}  ${NC}${BOLD}Меню прокси и конфигов${NC}"
        echo -e "  ${CYAN}[4]${NC}  ${NC}${BOLD}Обновить скрипт${NC}"
        echo -e "  ${CYAN}[5]${NC}  ${NC}${BOLD}Проверить доступ к сайтам с сервера(тг,ютуб,инст, и тд.)${NC}"
        echo -e "  ${CYAN}[6]${NC}  ${NC}${BOLD}Проверить домен/прокси на ios-валидность${YELLOW}${BOLD}(Необходим: OpenSSL 3.5+)  ${NC}"
        echo -e "  ${CYAN}[7]${NC}  ${RED}${BOLD}Удалить полностью MEKOpr${NC}"
        
        if [ "$show_iptables_rules" = true ]; then
            echo -e "  ${RED}[8]${NC}  Удалить правила iptables-persistent"
        fi
        
        echo -e "  ${CYAN}[0]${NC}  Выход"
        echo ""
        echo -en "  ${BOLD}Выбор:${NC} "
        local choice
        read -r choice

        case "$choice" in
        1)
            echo ""
            local iptables_status=$(get_synfix_status)
            local nft_status=$(get_nft_fix_status)
            
            # Если установлен iptables
            if [ "$iptables_status" != "inactive" ]; then
                log_info "Обнаружен iptables SYN FIX ($SYNFIX_CHAIN). Удалить?"
                echo -en "  ${BOLD}Удалить? [Y/n]:${NC} "
                local confirm
                read -r confirm
                if [[ -z "$confirm" || "$confirm" =~ ^[yY]$ ]]; then
                    remove_syn_fix
                else
                    log_info "Отмена удаления"
                fi
                # Пауза здесь
                echo ""
                echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
                read -rsn1
                continue
            fi
            
            # Если установлен nftables
            if [ "$nft_status" != "inactive" ]; then
                log_info "Обнаружен nftables SYN FIX (mtpr_synfix). Удалить?"
                echo -en "  ${BOLD}Удалить? [Y/n]:${NC} "
                local confirm
                read -r confirm
                if [[ -z "$confirm" || "$confirm" =~ ^[yY]$ ]]; then
                    remove_syn_fix
                else
                    log_info "Отмена удаления"
                fi
                # Пауза здесь
                echo ""
                echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
                read -rsn1
                continue
            fi
            
            # Если ничего не установлено — запускаем установку
            # install_syn_fix уже содержит свой read, поэтому после него НЕ добавляем ещё один
            install_syn_fix
            # install_syn_fix сам выводит "Нажмите любую клавишу" и делает read
            # Поэтому НЕ добавляем ещё один read
            ;;
        2)
            echo ""
            apply_basic_optimization
            echo ""
            echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
            read -rsn1
            ;;
        3)
            open_proxy_menu
            # open_proxy_menu вызывает exec, управление не возвращается
            ;;
        4)
            echo ""
            update_script
            # update_script перезапускает скрипт через exec, управление не возвращается
            ;;
        5)
            check_censor
            # check_censor уже содержит свой read и сообщение
            ;;
        6)
            echo ""
            # Проверяем версию OpenSSL
            OPENSSL_VERSION=$(openssl version 2>/dev/null | awk '{print $2}')
            REQUIRED_VERSION="3.5"
            
            if [ -z "$OPENSSL_VERSION" ]; then
                log_error "Не удалось определить версию OpenSSL"
                echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
                read -rsn1
                continue
            fi
            
            if [[ "$(printf '%s\n' "$REQUIRED_VERSION" "$OPENSSL_VERSION" | sort -V | head -n1)" != "$REQUIRED_VERSION" ]]; then
                echo ""
                echo -e "  ${RED}${BOLD}❌ Данная функция доступна только на ОС с OpenSSL 3.5 и выше${NC}"
                echo -e "  ${YELLOW}Ваша версия OpenSSL: ${OPENSSL_VERSION}${NC}"
                echo ""
                echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
                read -rsn1
                continue
            fi
            
            CHECKER_SCRIPT="/opt/mtpr-simple/proxy_checker.py"
            if [ -f "$CHECKER_SCRIPT" ]; then
                chmod +x "$CHECKER_SCRIPT"
                python3 "$CHECKER_SCRIPT"
                # proxy_checker.py сам управляет паузами, не добавляем свой read
            else
                log_error "Файл $CHECKER_SCRIPT не найден"
                echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
                read -rsn1
            fi
            ;;
        7)
            remove_mekopr
            # remove_mekopr завершает скрипт через exit
            ;;
        8)
            echo ""
            remove_iptables_rules
            echo ""
            echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
            read -rsn1
            ;;
        0 | q | Q)
            echo ""
            log_info "Выход"
            exit 0
            ;;
        *)
            log_error "Неверный выбор"
            sleep 0.2
            ;;
        esac
    done
}

# ── Обновление скрипта ──────────────────────────────────────────
update_script() {
    local url="https://raw.githubusercontent.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/main/main.sh"
    local temp="/tmp/$(basename "$0").new.$$"

    echo ""
    echo -e "  ${GREEN}[✓]${NC} Скачиваем новую версию main.sh..."
    if curl -fsSL "$url" -o "$temp"; then
        chmod +x "$temp"

        echo -e "  ${GREEN}[✓]${NC} Скачиваем все необходимые файлы..."
        
        # Все файлы которые нужно скачать (как в install.sh)
        local all_files=(
            "proxys/proxymenu.sh"
            "proxys/telemt1.sh"
            "proxys/mtprotozig1.sh"
            "proxys/telemt_in_docker1.sh"
            "proxys/mtgv2_1.sh"
            "proxy_checker.py"
        )
        
        mkdir -p /opt/mtpr-simple/proxys
        
        local all_ok=true
        for pfile in "${all_files[@]}"; do
            if curl -fsSL "https://raw.githubusercontent.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/main/$pfile" -o "/opt/mtpr-simple/$pfile"; then
                echo -e "    ${GREEN}✓${NC} $(basename "$pfile")"
            else
                echo -e "    ${RED}✗${NC} $(basename "$pfile") — ошибка"
                all_ok=false
            fi
        done
        
        if [ "$all_ok" = true ]; then
            chmod +x /opt/mtpr-simple/proxys/*.sh 2>/dev/null || true
            chmod +x /opt/mtpr-simple/proxy_checker.py 2>/dev/null || true
        fi

        if mv "$temp" "$0"; then
            echo -e "  ${GREEN}[✓]${NC} Обновление успешно!"
            echo ""
            echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
            read -rsn1
            # Перезапускаем скрипт без авто-установки
            exec "$0"
        else
            echo -e "  ${RED}[✗]${NC} Не удалось перезаписать файл"
            rm -f "$temp"
            echo ""
            echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
            read -rsn1
            return 1
        fi
    else
        echo -e "  ${RED}[✗]${NC} Ошибка скачивания main.sh"
        rm -f "$temp"
        echo ""
        echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
        read -rsn1
        return 1
    fi
}

# ── Запуск ────────────────────────────────────────────────────
main_menu "$@"
