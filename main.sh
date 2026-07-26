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

# ── Функция обрезки пробелов ──────────────────────────────
trim() {
    local var="$1"
    var="${var#"${var%%[![:space:]]*}"}"
    var="${var%"${var##*[![:space:]]}"}"
    printf '%s' "$var"
}

# ── Проверка root ────────────────────────────────────────────
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "Требуются права root"
        exit 1
    fi
}
check_root

# ── Функция проверки и загрузки rules.sh ────────────────────
RULES_SCRIPT="/opt/mtpr-simple/data/rules.sh"
RULES_LOADED=0

ensure_rules_loaded() {
    # Если уже загружен — просто возвращаем успех
    [ "$RULES_LOADED" -eq 1 ] && return 0

    # Проверяем наличие файла
    if [ -f "$RULES_SCRIPT" ]; then
        source "$RULES_SCRIPT"
        RULES_LOADED=1
        # Загружаем Zapret2, если файл существует
        if [ -f /opt/mtpr-simple/data/zapret2_fix.sh ]; then
            source /opt/mtpr-simple/data/zapret2_fix.sh
            zapret2_load_settings 2>/dev/null || true
        fi
        return 0
    fi

    # Файла нет — пробуем скачать с таймаутом 5 сек
    log_warning "Файл $RULES_SCRIPT не найден, скачиваю с GitHub..."
    mkdir -p /opt/mtpr-simple/data
    if curl -fsSL --max-time 5 "https://raw.githubusercontent.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/main/data/rules.sh" -o "$RULES_SCRIPT"; then
        chmod +x "$RULES_SCRIPT"
        source "$RULES_SCRIPT"
        RULES_LOADED=1
        # Скачиваем zapret2_fix.sh, если есть
        if curl -fsSL --max-time 5 "https://raw.githubusercontent.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/main/data/zapret2_fix.sh" -o /opt/mtpr-simple/data/zapret2_fix.sh; then
            chmod +x /opt/mtpr-simple/data/zapret2_fix.sh
            source /opt/mtpr-simple/data/zapret2_fix.sh
            zapret2_load_settings 2>/dev/null || true
        fi
        log_success "rules.sh успешно загружен"
        return 0
    else
        log_error "Не удалось скачать rules.sh (проверьте подключение к GitHub)"
        echo -e "  ${YELLOW}Вы можете вручную поместить файл rules.sh по пути:${NC}"
        echo -e "  ${BOLD}${RULES_SCRIPT}${NC}"
        echo -e "  ${YELLOW}После этого повторите попытку.${NC}"
        return 1
    fi
}

# ── ОСТАЛЬНЫЕ ПЕРЕМЕННЫЕ И ФУНКЦИИ (НЕ ИЗ RULES.SH) ──────────
CONFIG_PATH_FILE="/opt/mtpr-simple/config_path"
MTG_CONFIG_PATH_FILE="/opt/mtpr-simple/mtg_config_path"

# ── Функции для работы с TOML ──────────────────────────────
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

# ── Функции для MTG ──────────────────────────────────────────

# Путь к конфигу MTG
get_mtg_config_path() {
    if [ -f "$MTG_CONFIG_PATH_FILE" ] && [ -s "$MTG_CONFIG_PATH_FILE" ]; then
        path=$(cat "$MTG_CONFIG_PATH_FILE")
        if [ "$path" != "skip" ]; then
            echo "$path"
            return 0
        fi
    fi
    echo "/etc/mtg.toml"
    return 0
}

# Проверка установки MTG
is_mtg_installed() {
    command -v mtg >/dev/null 2>&1
}

# Получение версии MTG
get_mtg_version() {
    if command -v mtg >/dev/null 2>&1; then
        mtg --version 2>/dev/null | head -1 | awk '{print $1}'
    else
        echo ""
    fi
}

# Получение порта из конфига MTG
get_mtg_port() {
    local _cfg="$1"
    _cfg=$(trim "$_cfg")
    if [ -z "$_cfg" ] || [ ! -f "$_cfg" ]; then
        echo ""
        return 1
    fi
    local _port
    _port=$(grep -E '^bind-to[[:space:]]*=' "$_cfg" 2>/dev/null | head -1 | sed -E 's/^[[:space:]]*bind-to[[:space:]]*=[[:space:]]*"//; s/".*$//' | awk -F: '{print $2}')
    if [ -z "$_port" ]; then
        _port=$(_toml_get_value "port" "$_cfg")
    fi
    if [[ "$_port" =~ ^[0-9]+$ ]]; then
        echo "$_port"
    else
        echo ""
    fi
    return 0
}

# ── Функция проверки установки Telemt ──────────────────────
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

# ── Расширенное обнаружение Telemt ──────────────────────────
detect_all_telemt_configs() {
    local FOUND_CONFIGS=""
    local SEEN_PATHS=""
    
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
    
    if [ -f "$CONFIG_PATH_FILE" ] && [ -s "$CONFIG_PATH_FILE" ]; then
        local _saved_path=$(trim "$(cat "$CONFIG_PATH_FILE")")
        if [ -n "$_saved_path" ] && [ "$_saved_path" != "skip" ] && [ -f "$_saved_path" ] && _looks_like_telemt_config "$_saved_path"; then
            if ! echo "$SEEN_PATHS" | grep -qF "$_saved_path"; then
                SEEN_PATHS="${SEEN_PATHS}${_saved_path}\n"
                FOUND_CONFIGS="${FOUND_CONFIGS}${_saved_path}:"
            fi
        fi
    fi
    
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
    
    local _port=$(grep -E '^[[:space:]]*port[[:space:]]*=' "$_cfg" 2>/dev/null | head -1 | sed -E 's/^[[:space:]]*port[[:space:]]*=[[:space:]]*//; s/[^0-9]//g')
    
    if [ -z "$_port" ]; then
        _port=$(_toml_get_value "port" "$_cfg")
    fi
    
    if [ -z "$_port" ]; then
        _port=$(grep -E '^[[:space:]]*port[[:space:]]*=' "$_cfg" 2>/dev/null | head -1 | awk -F'=' '{print $2}' | tr -d ' "')
    fi
    
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
    TELEMT_VERSION=$(get_telemt_version)
    
    echo ""
    echo -e "  ${NC}${BOLD}Укажите путь к конфигу Telemt${NC}"
    echo -e "  ${NC}${BOLD}По умолчанию: ${GREEN}${BOLD}[/etc/telemt/telemt.toml]${NC}"
    
    if [ -n "$TELEMT_VERSION" ]; then
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
            _detected_configs=$(detect_all_telemt_configs)
            _detected_path=$(echo "$_detected_configs" | cut -d':' -f1)
            
            if [ -n "$_detected_path" ] && [ -f "$_detected_path" ]; then
                CONFIG_TELEMT_INPUT="$_detected_path"
            else
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

    # Удаление правил (если удаётся загрузить rules.sh)
    if ensure_rules_loaded; then
        remove_syn_fix
    else
        log_warning "rules.sh не загружен, пропускаем удаление правил"
    fi

    log_info "Удаление файлов конфигурации..."
    rm -rf /opt/mtpr-simple

    log_success "MEKOpr полностью удалён с сервера!"
    echo ""
    log_info "Для завершения работы скрипта нажмите Enter..."
    read -r

    log_info "Удаление скрипта..."
    rm -f "$0"
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

show_header() {
    clear_screen
    ensure_rules_loaded 2>/dev/null

    echo ""
    echo -e "  ${NC}${BOLD}MEKO ${CYAN}${BOLD}| ${NC}${BOLD}MTProto Manager ${CYAN}${BOLD} v1.91${NC}"
    echo -e "  ${DIM}══════════════════════════════${NC}"
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

    # ── ПОЛУЧАЕМ ВЕРСИЮ OPENSSL (теперь сразу после ОС) ───
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
    local iptables_status="недоступно"
    local nft_status="недоступно"
    if ensure_rules_loaded 2>/dev/null; then
        iptables_status=$(get_synfix_status)
        nft_status=$(get_nft_fix_status)
    else
        log_warning "СТАТУС SYN FIX: rules.sh не загружен" >&2
    fi

    echo ""
    if [ "$iptables_status" = "active" ]; then
        echo -e "  ${BOLD}SYN FIX iptables:${NC} ${GREEN}Установлен${NC}"
    elif [ "$iptables_status" = "has_chain_only" ]; then
        echo -e "  ${BOLD}SYN FIX iptables:${NC} ${YELLOW}Цепочка есть, сервис не запущен${NC}"
    elif [ "$iptables_status" = "inactive" ]; then
        echo -e "  ${BOLD}SYN FIX iptables:${NC} ${RED}${BOLD}Не установлен${NC}"
    else
        echo -e "  ${BOLD}SYN FIX iptables:${NC} ${RED}${BOLD}Недоступно${NC}"
    fi

    if [ "$nft_status" = "active" ]; then
        echo -e "  ${BOLD}SYN FIX nftables:${NC} ${GREEN}Установлен${NC}"
    elif [ "$nft_status" = "has_table_only" ]; then
        echo -e "  ${BOLD}SYN FIX nftables:${NC} ${YELLOW}Таблица есть, сервис не запущен${NC}"
    elif [ "$nft_status" = "inactive" ]; then
        echo -e "  ${BOLD}SYN FIX nftables:${NC} ${RED}${BOLD}Не установлен${NC}"
    else
        echo -e "  ${BOLD}SYN FIX nftables:${NC} ${RED}${BOLD}Недоступно${NC}"
    fi

    # ── СТАТУС ZAPRET2 ──────────────────────────────────────
    if declare -f zapret2_status &>/dev/null; then
        echo -e "  ${BOLD}Zapret2 fix:${NC} $(zapret2_status)"
    else
        echo -e "  ${BOLD}Zapret2 fix:${NC} ${DIM}недоступно${NC}"
    fi

    local telemt_installed=false
    local mtprotozig_installed=false
    local mtg_installed=false

    if is_telemt_installed; then
        telemt_installed=true
    fi
    if is_mtprotozig_installed; then
        mtprotozig_installed=true
    fi
    if is_mtg_installed; then
        mtg_installed=true
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
                version_color="${GREEN}"
            else
                version_color="${GREEN}"
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
            
            echo ""
            echo -e "  ${BOLD}Telemt V:${NC} ${version_color}${_version}${NC}${port_display}"
            echo -e "  ${BOLD}Telemt онлайн:${NC} ${CYAN}${_online}${NC}${BOLD} человек"
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
        echo ""
        echo -e "  ${BOLD}Telemt V:${NC} ${version_color}${_version}${NC} ${YELLOW}(конфиг не найден)${NC}"
    fi

    # ── ИНФОРМАЦИЯ О MTPROTOZIG ─────────────────────────────
    if [ "$mtprotozig_installed" = true ]; then
        local online_count=$(get_mtprotozig_online)
        if [ -n "$online_count" ] && [ "$online_count" -ge 0 ] 2>/dev/null; then
            echo ""
            echo -e "  ${BOLD}Mtproto.zig онлайн:${NC} ${CYAN}$online_count${NC} человек"
        else
            echo ""
            echo -e "  ${BOLD}Mtproto.zig онлайн:${NC} ${CYAN}0${NC} человек"
        fi
    fi

    # ── ИНФОРМАЦИЯ О MTG ──────────────────────────────────────
    if [ "$mtg_installed" = true ]; then
        local mtg_version=$(get_mtg_version)
        local mtg_config_path=$(get_mtg_config_path)
        local mtg_port=""
        if [ -f "$mtg_config_path" ]; then
            mtg_port=$(get_mtg_port "$mtg_config_path")
        fi
        local version_color="${GREEN}"
        echo ""
        if [ -n "$mtg_version" ]; then
            echo -e "  ${BOLD}MTG V:${NC} ${version_color}${mtg_version}${NC}${BOLD}  Port: ${CYAN}${mtg_port:-не определён}${NC}"
        else
            echo -e "  ${BOLD}MTG:${NC} ${GREEN}установлен${NC}${BOLD}  Port: ${CYAN}${mtg_port:-не определён}${NC}"
        fi
    fi

    # ── ПРОВЕРКА: ЕСТЬ ЛИ ХОТЯ БЫ ОДИН ПРОКСИ ──────────────
    if [ "$telemt_installed" = false ] && [ "$mtprotozig_installed" = false ] && [ "$mtg_installed" = false ]; then
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
    wget -qO- https://raw.githubusercontent.com/Nokola-Tesla/censorcheck/main/censorcheck.sh | bash
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
        if ensure_rules_loaded; then
            install_syn_fix -auto_install "$forced_port"
        else
            log_error "Невозможно выполнить автоустановку: rules.sh не загружен"
            echo -e "  ${GRAY}Нажмите любую клавишу...${NC}"
            read -rsn1
        fi
        return 0
    fi

    while true; do
        show_header
        echo ""

        local rules_available=0
        ensure_rules_loaded 2>/dev/null && rules_available=1

        if [ "$rules_available" -eq 1 ]; then
            local iptables_status=$(get_synfix_status)
            local nft_status=$(get_nft_fix_status)
            if [ "$iptables_status" = "inactive" ] && [ "$nft_status" = "inactive" ]; then
                local item1="${GREEN}${BOLD}Меню установки SYN FIX${NC}"
            else
                local item1="${RED}${BOLD}Удалить SYN FIX${NC}"
            fi
        else
            local item1="${YELLOW}${BOLD}Установить/Удалить SYN FIX (недоступно)${NC}"
        fi

        if is_optimization_applied; then
            local item2_text="${GRAY}${BOLD}Выполнить базовую оптимизацию (уже применена)${NC}"
        else
            local item2_text="${GREEN}${BOLD}Выполнить базовую оптимизацию${NC}"
        fi

        echo -e "  ${DIM}══════════════════════════════"
        echo -e "  ${CYAN}[1]${NC}  $item1"
        echo -e "  ${CYAN}[2]${NC}  $item2_text"
        echo -e "  ${CYAN}[3]${NC}  ${NC}${BOLD}Меню прокси и конфигов${NC}"
        echo -e "  ${CYAN}[4]${NC}  ${NC}${BOLD}Обновить скрипт${NC}"
        echo -e "  ${CYAN}[5]${NC}  ${NC}${BOLD}Проверить доступ к сайтам с сервера(тг,ютуб,инст, и тд.)${NC}"
        echo -e "  ${CYAN}[6]${NC}  ${NC}${BOLD}Проверить работоспособность домена/прокси на ios${YELLOW}${BOLD} (Необходим: OpenSSL 3.5+)  ${NC}"
        echo -e "  ${CYAN}[7]${NC}  ${RED}${BOLD}Удалить MEKO Manager(вместе с правилами)${NC}"
        echo -e "  ${CYAN}[8]${NC}  ${NC}${BOLD}Меню Zapret2 MTProto fix by CHKRON (тестируется)${NC}"
        echo -e "  ${CYAN}[0]${NC}  Выход"
        echo ""
        echo -en "  ${BOLD}Выбор:${NC} "
        local choice
        read -r choice

        case "$choice" in
        1)
            echo ""
            if ! ensure_rules_loaded; then
                log_error "Невозможно выполнить действие: rules.sh не загружен"
                echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
                read -rsn1
                continue
            fi

            local iptables_status=$(get_synfix_status)
            local nft_status=$(get_nft_fix_status)
            
            if [ "$iptables_status" != "inactive" ]; then
                log_info "Обнаружен iptables SYN FIX ($SYNFIX_CHAIN). Удалить?"
                echo -en "  ${BOLD}Удалить? [Y/n]:${NC} "
                local confirm
                read -r confirm
                if [[ -z "$confirm" || "$confirm" =~ ^[yY]$ ]]; then
                    remove_syn_fix || true
                else
                    log_info "Отмена удаления"
                fi
                echo ""
                echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
                read -rsn1
                continue
            fi
            
            if [ "$nft_status" != "inactive" ]; then
                log_info "Обнаружен nftables SYN FIX (mtpr_synfix). Удалить?"
                echo -en "  ${BOLD}Удалить? [Y/n]:${NC} "
                local confirm
                read -r confirm
                if [[ -z "$confirm" || "$confirm" =~ ^[yY]$ ]]; then
                    remove_syn_fix || true
                else
                    log_info "Отмена удаления"
                fi
                echo ""
                echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
                read -rsn1
                continue
            fi
            
            install_syn_fix
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
            ;;
        4)
            echo ""
            update_script
            ;;
        5)
            check_censor
            ;;
        6)
            echo ""
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
            else
                log_error "Файл $CHECKER_SCRIPT не найден"
                echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
                read -rsn1
            fi
            ;;
        7)
            remove_mekopr
            ;;
        8)
            echo ""
            if declare -f show_zapret2_menu &>/dev/null; then
                show_zapret2_menu
            else
                log_error "Функция show_zapret2_menu не найдена. Проверьте наличие /opt/mtpr-simple/data/zapret2_fix.sh"
                echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
                read -rsn1
            fi
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
    local BASE_URL="https://raw.githubusercontent.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/main"
    local MANIFEST_URL="$BASE_URL/data/manifest.txt"
    local MANIFEST_FILE="/tmp/manifest_update.txt"
    local INSTALL_DIR="/opt/mtpr-simple"
    local url="$BASE_URL/main.sh"
    local temp="/tmp/$(basename "$0").new.$$"

    echo ""
    echo -e "  ${GREEN}[✓]${NC} Скачиваем новую версию main.sh..."
    if curl -fsSL "$url" -o "$temp"; then
        chmod +x "$temp"
    else
        echo -e "  ${RED}[✗]${NC} Ошибка скачивания main.sh"
        rm -f "$temp"
        return 1
    fi

    echo -e "  ${BLUE}[i]${NC} Загрузка данных..."
    if ! curl -fsSL "$MANIFEST_URL" -o "$MANIFEST_FILE"; then
        echo -e "  ${RED}[✗]${NC} Не удалось загрузить информацию о необходимых файлах"
        rm -f "$MANIFEST_FILE"
        rm -f "$temp"
        return 1
    fi

    SCRIPT_NAME=$(basename "$0")

    echo -e "  ${BLUE}[i]${NC} Исполняемый файл: ${SCRIPT_NAME}"
    echo ""

    # ── СОЗДАНИЕ ВСЕХ НЕОБХОДИМЫХ ПАПОК ЗАРАНЕЕ ────────────────
    mkdir -p "$INSTALL_DIR"
    mkdir -p "$INSTALL_DIR/proxys"
    mkdir -p "$INSTALL_DIR/data"

    # ── Функция скачивания файла ─────────────────────────────────
    download_file() {
        local file="$1"
        local desc="$2"
        local url="$BASE_URL/$file"
        local dest="$INSTALL_DIR/$file"
        local name=$(basename "$file")
        
        local size=$(curl -sI "$url" 2>/dev/null | grep -i "Content-Length" | awk '{print $2}' | tr -d '\r')
        local size_str="?"
        if [ -n "$size" ] && [ "$size" -gt 0 ] 2>/dev/null; then
            if [ "$size" -gt 1048576 ]; then
                local mb=$((size / 1048576))
                local remainder=$(((size % 1048576) / 104857))
                if [ "$remainder" -gt 0 ]; then
                    size_str="${mb}.${remainder} MB"
                else
                    size_str="${mb} MB"
                fi
            elif [ "$size" -gt 1024 ]; then
                size_str="$((size / 1024)) KB"
            else
                size_str="$size B"
            fi
        fi
        
        echo -e "  ${CYAN}⏳${NC}${BOLD} Загрузка ${GREEN}${BOLD}${name}${NC}${BOLD} (${desc})"
        
        if curl -fsSL "$url" -o "$dest" 2>/dev/null; then
            echo -e "  ${GREEN}${BOLD}✓${NC}${BOLD} Скачан успешно:${NC} ${GREEN}${BOLD}${name}${NC} (${size_str})"
            chmod +x "$dest" 2>/dev/null || true
            return 0
        else
            echo -e "  ${RED}✗${NC} ${RED}${name}${NC} — ошибка загрузки"
            return 1
        fi
    }
    export -f download_file
    export BASE_URL INSTALL_DIR

    # ── Чтение манифеста и исключение себя ──────────────────────
    echo -e "  ${BOLD}Чтение файлов из репозитория для загрузки и подготовка к установке...${NC}"
    echo ""

    FILES_TO_DOWNLOAD=()
    while IFS='|' read -r file_path description; do
        [[ "$file_path" =~ ^[[:space:]]*#.*$ ]] && continue
        [ -z "$file_path" ] && continue

        file_path=$(echo "$file_path" | xargs)
        description=$(echo "$description" | xargs)
        
        # ── УДАЛЁН БЛОК ПРОПУСКА САМОГО СЕБЯ ──
        # Теперь ВСЕ файлы добавляются, включая main.sh

        FILES_TO_DOWNLOAD+=("$file_path|$description")
        
    done < "$MANIFEST_FILE"

    # ── Вывод списка файлов для загрузки ────────────────────────
    echo -e "  ${BOLD}Файлы для загрузки (${#FILES_TO_DOWNLOAD[@]} шт.):${NC}"
    for entry in "${FILES_TO_DOWNLOAD[@]}"; do
        file_path=$(echo "$entry" | cut -d'|' -f1)
        desc=$(echo "$entry" | cut -d'|' -f2)
        echo -e "    ${DIM}• ${file_path}${NC} (${desc})"
    done
    echo ""

    # ── Загрузка файлов (параллельно, 6 потоков) ───────────────
    echo -e "  ${BOLD}Загрузка файлов...${NC}"
    echo ""

    printf "%s\n" "${FILES_TO_DOWNLOAD[@]}" | xargs -P 6 -I {} bash -c '
        IFS="|" read -r file_path description <<< "$1"
        download_file "$file_path" "$description"
    ' _ {}

    # ── Проверка, что все файлы скачались ───────────────────────
    echo ""
    local failed=0
    for entry in "${FILES_TO_DOWNLOAD[@]}"; do
        IFS='|' read -r file_path description <<< "$entry"
        if [ ! -f "$INSTALL_DIR/$file_path" ]; then
            echo -e "  ${RED}[✗]${NC} Файл не найден: $file_path"
            failed=1
        fi
    done

    if [ $failed -eq 1 ]; then
        echo -e "  ${RED}[✗]${NC} Обновление не удалось: некоторые файлы не загружены"
        echo -e "  ${YELLOW}Проверьте подключение к интернету и доступность репозитория.${NC}"
        echo -e "  ${YELLOW}Попробуйте обновить позже.${NC}"
        rm -f "$MANIFEST_FILE"
        rm -f "$temp"
        return 1
    fi

    # ── Установка прав ──────────────────────────────────────────
    echo -ne "  ${CYAN}[+]${NC} Установка прав выполнения... "
    chmod +x "$INSTALL_DIR/proxys/"*.sh 2>/dev/null || true
    chmod +x "$INSTALL_DIR"/*.py 2>/dev/null || true
    echo -e "${GREEN}✓${NC}"

    rm -f "$MANIFEST_FILE"

    if mv "$temp" "$0"; then
        echo -e "  ${GREEN}[✓]${NC} Обновление успешно!"
        echo ""
        echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
        read -rsn1
        exec "$0"
    else
        echo -e "  ${RED}[✗]${NC} Не удалось перезаписать файл"
        rm -f "$temp"
        echo ""
        echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
        read -rsn1
        return 1
    fi
}

# ── Запуск ────────────────────────────────────────────────────
main_menu "$@"
