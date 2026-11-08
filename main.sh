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

# wait_key <подсказка> — ждём нажатия клавиши; без доступа к /dev/tty дальше работать нечем
wait_key() {
    echo -e "  ${GRAY}$1${NC}"
    { read -rsn1 </dev/tty; } 2>/dev/null || { echo; log_error "Нет доступа к терминалу для ввода. Выход."; exit 1; }
    IFS= read -r -t 0.05 _ </dev/tty 2>/dev/null || true
}

# ── Режим CLI ────────────────────────────────────────────────
# MEKOPR_CLI=true       — запуск из командной строки (не меню)
# MEKOPR_ASSUME_YES=true — подтверждение запросов без ввода (только CLI, -y)
MEKOPR_CLI=false
MEKOPR_ASSUME_YES=false

# Ранний разбор аргументов: до CLI-диспетчера в файле есть интерактивные
# блоки (например, запрос пути к конфигу Telemt), которые в CLI запускаться не должны.
case "${1:-}" in
    "" | --menu|-m|menu)
        # запуск без аргументов или явный вызов меню — интерактивный режим
        ;;
    *)
        MEKOPR_CLI=true
        ;;
esac

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

# ── Каталог установки (глобально: нужен и CLI-путям удаления) ─
INSTALL_DIR="/opt/mtpr-simple"

# ── Путь к нашему собственному файлу (для самообновления) ────
# Под `bash -s` (скрипт из пайпа) $0 и BASH_SOURCE пусты, поэтому
# при неудаче берём файл из каталога установки; симлинк (mekopr) разыменовываем,
# иначе обновление заменило бы ссылку обычным файлом.
SELF_PATH="${BASH_SOURCE[0]:-}"
if [ -z "$SELF_PATH" ] || [ ! -f "$SELF_PATH" ]; then
    SELF_PATH="$INSTALL_DIR/main.sh"
fi
if [ -L "$SELF_PATH" ] && command -v readlink >/dev/null 2>&1; then
    _self_real="$(readlink -f "$SELF_PATH" 2>/dev/null || true)"
    if [ -n "$_self_real" ] && [ -f "$_self_real" ]; then
        SELF_PATH="$_self_real"
    fi
fi

RULES_SCRIPT="$INSTALL_DIR/data/rules.sh"
RULES_LOADED=0

ensure_rules_loaded() {
    [ "$RULES_LOADED" -eq 1 ] && return 0

    if [ -f "$RULES_SCRIPT" ]; then
        # shellcheck source=/dev/null
        source "$RULES_SCRIPT"
        RULES_LOADED=1
        if [ -f "$INSTALL_DIR/data/zapret2_fix.sh" ]; then
            source "$INSTALL_DIR/data/zapret2_fix.sh"
            if declare -f load_settings >/dev/null 2>&1; then load_settings 2>/dev/null || true; fi
        fi
        return 0
    fi

    log_warning "Файл $RULES_SCRIPT не найден, скачиваю с GitHub..."
    mkdir -p "$INSTALL_DIR/data"
    if curl -fsSL --max-time 5 "https://raw.githubusercontent.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/main/data/rules.sh" -o "$RULES_SCRIPT"; then
        chmod +x "$RULES_SCRIPT"
        # shellcheck source=/dev/null
        source "$RULES_SCRIPT"
        RULES_LOADED=1
        if curl -fsSL --max-time 5 "https://raw.githubusercontent.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/main/data/zapret2_fix.sh" -o "$INSTALL_DIR/data/zapret2_fix.sh"; then
            chmod +x "$INSTALL_DIR/data/zapret2_fix.sh"
            source "$INSTALL_DIR/data/zapret2_fix.sh"
            if declare -f load_settings >/dev/null 2>&1; then load_settings 2>/dev/null || true; fi
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

# ── Загрузка дополнительных меню (data/*.sh) ─────────────────
EXTRA_BASE_URL="https://raw.githubusercontent.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/main"

# ensure_data_script <относительный путь, напр. data/backup_panel.sh>
# Если файла нет (например, при обновлении со старой версии) — скачать.
ensure_data_script() {
    local rel="$1"
    local dest="$INSTALL_DIR/$rel"
    if [ -s "$dest" ]; then
        return 0
    fi
    log_warning "Файл $dest не найден, скачиваю с GitHub..."
    mkdir -p "$(dirname "$dest")"
    if curl -fsSL --max-time 20 "$EXTRA_BASE_URL/$rel" -o "$dest"; then
        if [ -s "$dest" ]; then
            chmod +x "$dest" 2>/dev/null || true
            return 0
        fi
        rm -f "$dest" 2>/dev/null || true
        log_error "Скачанный файл $rel пуст или повреждён"
        return 1
    fi
    rm -f "$dest" 2>/dev/null || true
    log_error "Не удалось скачать $rel"
    return 1
}

# run_menu_script <абсолютный путь> [аргументы…] — запуск отдельного меню в дочернем bash
run_menu_script() {
    local script="$1"; shift
    if [ ! -f "$script" ]; then
        log_error "Файл не найден: $script"
        return 1
    fi
    if { : </dev/tty; } 2>/dev/null; then
        bash "$script" "$@" </dev/tty || true
    else
        log_warning "Нет доступа к /dev/tty — запуск без интерактивного ввода"
        bash "$script" "$@" || true
    fi
    return 0
}

# ── Остальные переменные и функции (правила — в rules.sh) ──
CONFIG_PATH_FILE="$INSTALL_DIR/config_path"
MTG_CONFIG_PATH_FILE="$INSTALL_DIR/mtg_config_path"

# ── Функции для работы с TOML ──────────────────────────────
_toml_get_value() {
    local _key="$1" _file="$2"
    [ -f "$_file" ] || return 0
    awk -v k="$_key" '
        /^[[:space:]]*#/ { next }
        $1 == k && $2 == "=" { gsub(/[^0-9]/, "", $3); print $3; exit }
    ' "$_file" 2>/dev/null
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

get_mtg_config_path() {
    local path
    if [ -f "$MTG_CONFIG_PATH_FILE" ] && [ -s "$MTG_CONFIG_PATH_FILE" ]; then
        path=$(cat "$MTG_CONFIG_PATH_FILE")
        if [ "$path" != "skip" ]; then
            echo "$path"
            return 0
        fi
    fi
    echo "/etc/mtg.toml"
}

is_mtg_installed() {
    command -v mtg >/dev/null 2>&1
}

get_mtg_version() {
    if command -v mtg >/dev/null 2>&1; then
        mtg --version 2>/dev/null | head -1 | awk '{print $1}'
    else
        echo ""
    fi
}

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
}

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
                case "$SEEN_PATHS" in *"$_arg"*) ;; *)
                    SEEN_PATHS="${SEEN_PATHS}${_arg}\n"
                    FOUND_CONFIGS="${FOUND_CONFIGS}${_arg}:"
                ;; esac
            fi
        done
    fi
    
    local _cf
    for _cf in /etc/telemt/telemt.toml /etc/telemt/config.toml /etc/telemt.toml /opt/telemt/config.toml /opt/telemt/telemt.toml; do
        _cf=$(trim "$_cf")
        if [ -n "$_cf" ] && [ -f "$_cf" ] && ! _is_excluded_path "$_cf" && _looks_like_telemt_config "$_cf"; then
            case "$SEEN_PATHS" in *"$_cf"*) ;; *)
                SEEN_PATHS="${SEEN_PATHS}${_cf}\n"
                FOUND_CONFIGS="${FOUND_CONFIGS}${_cf}:"
            ;; esac
        fi
    done
    
    if [ -f "$CONFIG_PATH_FILE" ] && [ -s "$CONFIG_PATH_FILE" ]; then
        local _saved_path
        _saved_path=$(trim "$(cat "$CONFIG_PATH_FILE")") || _saved_path=""
        if [ -n "$_saved_path" ] && [ "$_saved_path" != "skip" ] && [ -f "$_saved_path" ] && _looks_like_telemt_config "$_saved_path"; then
            case "$SEEN_PATHS" in *"$_saved_path"*) ;; *)
                SEEN_PATHS="${SEEN_PATHS}${_saved_path}\n"
                FOUND_CONFIGS="${FOUND_CONFIGS}${_saved_path}:"
            ;; esac
        fi
    fi
    
    FOUND_CONFIGS=$(trim "${FOUND_CONFIGS%:}")
    echo "$FOUND_CONFIGS"
}

get_port_from_config() {
    local _cfg="$1"
    _cfg=$(trim "$_cfg")
    
    if [ -z "$_cfg" ] || [ ! -f "$_cfg" ]; then
        echo ""
        return 1
    fi
    
    local _port
    _port=$(grep -E '^[[:space:]]*port[[:space:]]*=' "$_cfg" 2>/dev/null | head -1 | sed -E 's/^[[:space:]]*port[[:space:]]*=[[:space:]]*//; s/[^0-9]//g') || _port=""
    
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

# Считает IP во всех блоках "active_ips" (формат ответа API менялся).
# Пустой вывод = онлайн неизвестен (API не ответил), это не ноль.
_telemt_online_from_json() {
    local _quotes
    _quotes=$(LC_ALL=C tr '\n' ' ' |
        { grep -o '"active_ips"[[:space:]]*:[[:space:]]*\[[^]]*\]' || true; } |
        sed 's/^"active_ips"[[:space:]]*:[[:space:]]*//' |
        LC_ALL=C tr -cd '"' | LC_ALL=C wc -c)
    echo "$(( _quotes / 2 ))"
}

get_telemt_online_for_config() {
    local _cfg="$1"
    _cfg=$(trim "$_cfg")

    if [ -z "$_cfg" ] || [ ! -f "$_cfg" ]; then
        echo ""
        return 1
    fi

    local _json
    _json=$(curl -s --connect-timeout 1 --max-time 3 \
        "http://127.0.0.1:9091/v1/stats/users/active-ips" 2>/dev/null) || {
        echo ""
        return 1
    }

    case "$_json" in
        *'"ok":true'*) ;;
        *) echo ""; return 1 ;;
    esac

    printf '%s\n' "$_json" | _telemt_online_from_json
}

is_mss_enabled_for_config() {
    local _cfg="$1"
    _cfg=$(trim "$_cfg")
    if [ -z "$_cfg" ] || [ ! -f "$_cfg" ]; then
        return 1
    fi
    if grep -qE '^[[:space:]]*client_mss[[:space:]]*=' "$_cfg"; then
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
    if grep -qE '^[[:space:]]*mss_bulk[[:space:]]*=' "$_cfg"; then
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
    if grep -qE '^[[:space:]]*synlimit[[:space:]]*=' "$_cfg"; then
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
elif [ "$MEKOPR_CLI" = true ]; then
    # CLI: путь к конфигу не спрашиваем (значение подхватится при необходимости)
    CONFIG_TELEMT=""
else
    TELEMT_VERSION=$(get_telemt_version)
    
    echo ""
    echo -e "  ${NC}${BOLD}Укажите путь к конфигу Telemt${NC}"
    echo -e "  ${NC}${BOLD}По умолчанию: ${GREEN}${BOLD}[/etc/telemt/telemt.toml]${NC}"
    
    if [ -n "$TELEMT_VERSION" ]; then
        _detected_configs=$(detect_all_telemt_configs)
        _detected_path=${_detected_configs%%:*}
        
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
    { read -r CONFIG_TELEMT_INPUT </dev/tty; } 2>/dev/null || { echo; log_error "Нет доступа к терминалу для ввода. Выход."; exit 1; }

    if [[ "$CONFIG_TELEMT_INPUT" =~ ^[Nn]$ ]]; then
        mkdir -p "$INSTALL_DIR"
        echo "skip" > "$CONFIG_PATH_FILE"
        CONFIG_TELEMT=""
    else
        if [ -z "$CONFIG_TELEMT_INPUT" ]; then
            _detected_configs=$(detect_all_telemt_configs)
            _detected_path=${_detected_configs%%:*}
            
            if [ -n "$_detected_path" ] && [ -f "$_detected_path" ]; then
                CONFIG_TELEMT_INPUT="$_detected_path"
            else
                if [ -z "$TELEMT_VERSION" ]; then
                    log_info "Telemt не найден, пропускаем настройку конфига"
                    mkdir -p "$INSTALL_DIR"
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
                { read -r confirm_path </dev/tty; } 2>/dev/null || { echo; log_error "Нет доступа к терминалу для ввода. Выход."; exit 1; }
                if [[ ! "$confirm_path" =~ ^[yY]$ ]]; then
                    log_error "Путь к конфигу не подтверждён, выход."
                    exit 1
                fi
            fi

            mkdir -p "$INSTALL_DIR"
            echo "$CONFIG_TELEMT_INPUT" > "$CONFIG_PATH_FILE"
            CONFIG_TELEMT="$CONFIG_TELEMT_INPUT"
        fi
    fi
fi


# ── Пункт 3: Базовая оптимизация (применить / откатить) ─────
#   Перед изменениями сохраняем состояние «как было» в OPT_SNAPSHOT_DIR,
#   чтобы откат возвращал прежние файлы, а не просто удалял наши.
OPT_SNAPSHOT_DIR="$INSTALL_DIR/opt-snapshot"
OPT_SYSCTL_FILE="/etc/sysctl.d/99-custom.conf"
OPT_LIMITS_DIR="/etc/systemd/system/telemt.service.d"
OPT_LIMITS_FILE="$OPT_LIMITS_DIR/limits.conf"
OPT_TELEMT_MAX_CONNECTIONS=16384
OPT_TELEMT_HANDSHAKE_TIMEOUT=15
OPT_NOFILE_LIMIT=65535

# _opt_snapshot_save — сохранить состояние «до». Повторный вызов снапшот не перезатирает.
_opt_snapshot_save() {
    [ -d "$OPT_SNAPSHOT_DIR" ] && return 0
    if ! mkdir -p "$OPT_SNAPSHOT_DIR"; then
        log_warning "Не удалось создать $OPT_SNAPSHOT_DIR — откат будет удалять только наши файлы"
        return 1
    fi

    if [ -f "$OPT_SYSCTL_FILE" ]; then
        cp -a "$OPT_SYSCTL_FILE" "$OPT_SNAPSHOT_DIR/sysctl.conf" 2>/dev/null || true
    else
        : > "$OPT_SNAPSHOT_DIR/sysctl.absent"
    fi

    if [ -f "$OPT_LIMITS_FILE" ]; then
        cp -a "$OPT_LIMITS_FILE" "$OPT_SNAPSHOT_DIR/limits.conf" 2>/dev/null || true
    else
        : > "$OPT_SNAPSHOT_DIR/limits.absent"
    fi

    if [ -n "$CONFIG_TELEMT" ] && [ -f "$CONFIG_TELEMT" ]; then
        cp -a "$CONFIG_TELEMT" "$OPT_SNAPSHOT_DIR/telemt.toml" 2>/dev/null || true
        printf '%s\n' "$CONFIG_TELEMT" > "$OPT_SNAPSHOT_DIR/telemt.path"
    fi

    date '+%Y-%m-%d %H:%M:%S' > "$OPT_SNAPSHOT_DIR/created_at" 2>/dev/null || true
    log_info "Снапшот состояния сохранён: $OPT_SNAPSHOT_DIR"
    return 0
}

# _opt_write_sysctl — записать файл сетевых параметров (без применения)
_opt_write_sysctl() {
    cat >"$OPT_SYSCTL_FILE" <<EOF
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
}

# _opt_pause — пауза меню оптимизации
_opt_pause() {
    echo ""
    echo -e "  ${GRAY}Нажмите любую клавишу для продолжения...${NC}"
    { read -rsn1 </dev/tty; } 2>/dev/null || true
    IFS= read -r -t 0.05 _ </dev/tty 2>/dev/null || true
}

# optimization_status — подробный статус: применена ли и что именно задано
optimization_status() {
    echo ""
    echo -e "  ${BOLD}${CYAN}Базовая оптимизация — статус${NC}"
    echo -e "  ${DIM}══════════════════════════════════════════${NC}"

    if is_optimization_applied; then
        echo -e "    Состояние: ${GREEN}применена${NC}"
    else
        echo -e "    Состояние: ${YELLOW}не применена${NC}"
    fi

    if [ -f "$OPT_SYSCTL_FILE" ]; then
        echo -e "    ${CYAN}$OPT_SYSCTL_FILE:${NC} есть"
    else
        echo -e "    ${CYAN}$OPT_SYSCTL_FILE:${NC} нет"
    fi
    echo -e "    ${CYAN}congestion control:${NC} $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo 'н/д')"
    echo -e "    ${CYAN}default qdisc:${NC} $(sysctl -n net.core.default_qdisc 2>/dev/null || echo 'н/д')"
    echo -e "    ${CYAN}tcp_fastopen:${NC} $(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo 'н/д')"

    if [ -f "$OPT_LIMITS_FILE" ]; then
        echo -e "    ${CYAN}$OPT_LIMITS_FILE:${NC} есть"
    else
        echo -e "    ${CYAN}$OPT_LIMITS_FILE:${NC} нет"
    fi

    if [ -d "$OPT_SNAPSHOT_DIR" ]; then
        echo -e "    ${CYAN}Снапшот для отката:${NC} есть ($(cat "$OPT_SNAPSHOT_DIR/created_at" 2>/dev/null || echo 'дата н/д'))"
    else
        echo -e "    ${CYAN}Снапшот для отката:${NC} ${DIM}нет (откат удалит только наши файлы)${NC}"
    fi
    echo ""
}

apply_basic_optimization() {
    echo ""
    log_info "Выполнение базовой оптимизации системы и Telemt..."

    _opt_snapshot_save || true

    if [ -n "$CONFIG_TELEMT" ] && [ -f "$CONFIG_TELEMT" ]; then
        systemctl stop telemt 2>/dev/null || true

        if grep -q '^max_connections *=.*' "$CONFIG_TELEMT"; then
            if ! grep -q "^max_connections *= *$OPT_TELEMT_MAX_CONNECTIONS" "$CONFIG_TELEMT"; then
                sed -i "s/^max_connections *= *.*/max_connections = $OPT_TELEMT_MAX_CONNECTIONS/" "$CONFIG_TELEMT"
            fi
        elif grep -q '\[server\]' "$CONFIG_TELEMT"; then
            sed -i "/\[server\]/a max_connections = $OPT_TELEMT_MAX_CONNECTIONS" "$CONFIG_TELEMT"
        fi

        if grep -q '^client_handshake *=.*' "$CONFIG_TELEMT"; then
            if ! grep -q "^client_handshake *= *$OPT_TELEMT_HANDSHAKE_TIMEOUT" "$CONFIG_TELEMT"; then
                sed -i "s/^client_handshake *= *.*/client_handshake = $OPT_TELEMT_HANDSHAKE_TIMEOUT/" "$CONFIG_TELEMT"
            fi
        fi

        systemctl restart telemt 2>/dev/null || true
        log_info "Параметры Telemt обновлены (max_connections, client_handshake)"
    else
        log_warning "Файл конфига Telemt не найден или не указан, пропускаем оптимизацию параметров Telemt"
    fi

    if [ ! -f /etc/sysctl.conf ]; then
        touch /etc/sysctl.conf
        chmod 644 /etc/sysctl.conf
        log_info "Создан /etc/sysctl.conf"
    fi

    mkdir -p "$OPT_LIMITS_DIR"
    if ! grep -q "LimitNOFILE=$OPT_NOFILE_LIMIT" "$OPT_LIMITS_FILE" 2>/dev/null; then
        cat >"$OPT_LIMITS_FILE" <<EOF
[Service]
LimitNOFILE=$OPT_NOFILE_LIMIT
EOF
    fi

    systemctl daemon-reload 2>/dev/null || true

    _opt_write_sysctl
    sysctl --system >/dev/null 2>&1 || log_info "sysctl --system выполнен без изменений"

    if [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" != "bbr" ]; then
        log_warning "Ядро не подтвердило tcp_congestion_control=bbr (модуль tcp_bbr может быть недоступен)"
    fi

    log_success "Базовая оптимизация выполнена"
}

# remove_basic_optimization — вернуть состояние «как было» (или удалить наши файлы)
remove_basic_optimization() {
    echo ""
    log_info "Откат базовой оптимизации..."

    local rc=0
    local restored_sysctl=0 restored_limits=0 restored_telemt=0

    if [ -f "$OPT_SNAPSHOT_DIR/sysctl.conf" ]; then
        cp -a "$OPT_SNAPSHOT_DIR/sysctl.conf" "$OPT_SYSCTL_FILE" || rc=1
        restored_sysctl=1
    elif [ -f "$OPT_SYSCTL_FILE" ]; then
        rm -f "$OPT_SYSCTL_FILE" || rc=1
    fi

    if [ -f "$OPT_SNAPSHOT_DIR/limits.conf" ]; then
        mkdir -p "$OPT_LIMITS_DIR"
        cp -a "$OPT_SNAPSHOT_DIR/limits.conf" "$OPT_LIMITS_FILE" || rc=1
        restored_limits=1
    elif [ -f "$OPT_LIMITS_FILE" ]; then
        rm -f "$OPT_LIMITS_FILE" || rc=1
        rmdir "$OPT_LIMITS_DIR" 2>/dev/null || true
    fi

    local _cfg="$CONFIG_TELEMT"
    if [ -f "$OPT_SNAPSHOT_DIR/telemt.path" ]; then
        _cfg="$(cat "$OPT_SNAPSHOT_DIR/telemt.path" 2>/dev/null || true)"
    fi
    if [ -f "$OPT_SNAPSHOT_DIR/telemt.toml" ] && [ -n "$_cfg" ] && [ -f "$_cfg" ]; then
        systemctl stop telemt 2>/dev/null || true
        cp -a "$OPT_SNAPSHOT_DIR/telemt.toml" "$_cfg" || rc=1
        systemctl restart telemt 2>/dev/null || true
        restored_telemt=1
    fi

    systemctl daemon-reload 2>/dev/null || true
    sysctl --system >/dev/null 2>&1 || true

    rm -rf "$OPT_SNAPSHOT_DIR" 2>/dev/null || true

    echo ""
    if [ "$restored_sysctl" -eq 1 ]; then
        log_info "Восстановлен прежний $OPT_SYSCTL_FILE"
    else
        log_info "Удалён $OPT_SYSCTL_FILE (до оптимизации его не было)"
    fi
    if [ "$restored_limits" -eq 1 ]; then
        log_info "Восстановлен прежний $OPT_LIMITS_FILE"
    else
        log_info "Удалён $OPT_LIMITS_FILE (до оптимизации его не было)"
    fi
    if [ "$restored_telemt" -eq 1 ]; then
        log_info "Восстановлены прежние параметры Telemt"
    else
        log_info "Конфиг Telemt не менялся (снапшота нет)"
    fi

    if [ "$rc" -eq 0 ]; then
        log_success "Базовая оптимизация отменена"
        return 0
    fi
    log_warning "Откат выполнен частично — проверьте сообщения выше"
    return 1
}

# optimization_menu — подменю: применить / откатить / статус
optimization_menu() {
    while true; do
        clear 2>/dev/null || true
        echo ""
        echo -e "  ${BOLD}${CYAN}Базовая оптимизация сервера${NC}"
        echo -e "  ${DIM}══════════════════════════════════════════${NC}"
        if is_optimization_applied; then
            echo -e "  Статус: ${GREEN}применена${NC}"
        else
            echo -e "  Статус: ${YELLOW}не применена${NC}"
        fi
        echo ""
        echo -e "  ${CYAN}[1]${NC}  Применить оптимизацию"
        echo -e "  ${CYAN}[2]${NC}  Откатить оптимизацию"
        echo -e "  ${CYAN}[3]${NC}  Подробный статус"
        echo -e "  ${RED}[0]${NC}  ${BOLD}Назад"
        echo ""
        echo -en "  ${BOLD}Выбор:${NC} "
        local _choice
        { read -r _choice </dev/tty; } 2>/dev/null || { echo; return 0; }
        case "$_choice" in
            1) apply_basic_optimization; _opt_pause ;;
            2) remove_basic_optimization || true; _opt_pause ;;
            3) optimization_status; _opt_pause ;;
            0 | "") return 0 ;;
            *) echo -e "  ${RED}[✗]${NC} Неверный выбор"; _opt_pause ;;
        esac
    done
}

# ── Пункт 4: Удаление компонентов MEKO Manager ───────────────
#   Области (scope): meko | fix | all | fix-only | telemt | meko-telemt | fix-telemt
#   Внутри — три независимых флага: менеджер / фиксы / Telemt.
remove_mekopr() {
    local scope="${1:-fix}"
    local _do_meko=false _do_fix=false _do_telemt=false

    case "$scope" in
        meko)        _do_meko=true ;;
        fix)         _do_meko=true; _do_fix=true ;;
        all)         _do_meko=true; _do_fix=true; _do_telemt=true ;;
        fix-only)    _do_fix=true ;;
        telemt)      _do_telemt=true ;;
        meko-telemt) _do_meko=true; _do_telemt=true ;;
        fix-telemt)  _do_fix=true; _do_telemt=true ;;
        *)
            log_error "Неверная область удаления: $scope"
            echo -e "  ${DIM}Доступно: meko | fix | all | fix-only | telemt | meko-telemt | fix-telemt${NC}"
            return 2
            ;;
    esac

    echo ""
    log_warning "${BOLD}ВНИМАНИЕ:${NC} Будет выполнено удаление!"
    echo ""
    echo -e "  ${BOLD}Что будет удалено:${NC}"
    if [ "$_do_telemt" = true ]; then
        echo -e "  • ${RED}Telemt${NC}: служба/контейнер, конфиг, образы (полное удаление)"
    fi
    if [ "$_do_fix" = true ]; then
        echo -e "  • Все iptables-правила и цепочка ${CYAN}${SYNFIX_CHAIN:-MTPR_SYNFIX}${NC}"
        echo -e "  • Все nftables-правила (mtpr_synfix, mtpr_block, Zapret2)"
        echo -e "  • Правила ${CYAN}GEOIP-обхода${NC} и ежедневная cron-задача геобазы (если ставились)"
        echo -e "  • Службы ${CYAN}Zapret2${NC}, шейпинг и блокировка IP (если ставились)"
    fi
    if [ "$_do_meko" = true ]; then
        echo -e "  • Файлы MEKO Manager в ${CYAN}$INSTALL_DIR${NC} и лаунчеры ${CYAN}mekopr/meko${NC}"
    fi
    if [ "$_do_telemt" = false ]; then
        echo -e "  ${GRAY}  Telemt и его конфиг не затрагиваются${NC}"
    fi
    echo ""
    log_warning "Это действие нельзя отменить!"

    if [ "$MEKOPR_ASSUME_YES" != true ]; then
        echo -en "  ${BOLD}Продолжить удаление? [y/N]:${NC} "
        local confirm
        { read -r confirm </dev/tty; } 2>/dev/null || { echo; log_error "Нет доступа к терминалу для ввода. Выход."; exit 1; }
        if [[ ! "$confirm" =~ ^[yY]$ ]]; then
            log_info "Удаление отменено"
            return 0
        fi
    fi

    log_info "Начинаем удаление (область: $scope)..."

    # ── Telemt ───────────────────────────────────────────────
    if [ "$_do_telemt" = true ]; then
        local _tmenu="$INSTALL_DIR/proxys/telemt1.sh"
        if [ -f "$_tmenu" ]; then
            log_info "Удаляю Telemt (служба/контейнер, конфиг, образы)..."
            bash "$_tmenu" --purge-silent || log_warning "Telemt удалён не полностью — проверьте вручную"
        else
            log_warning "$_tmenu не найден — удалите Telemt вручную (меню прокси)"
        fi
    fi

    # ── Фиксы и правила ──────────────────────────────────────
    if [ "$_do_fix" = true ]; then
        if [ -f "$INSTALL_DIR/data/shaping.sh" ]; then
            log_info "Снимаю ограничение скорости (шейпинг)..."
            bash "$INSTALL_DIR/data/shaping.sh" --remove || log_warning "Не удалось снять шейпинг (продолжаю удаление)"
        fi

        if [ -f "$INSTALL_DIR/data/security.sh" ]; then
            log_info "Снимаю блокировку IP/подсетей (безопасность)..."
            bash "$INSTALL_DIR/data/security.sh" --disable-nft || log_warning "Не удалось снять правила блокировки (продолжаю удаление)"
        fi

        # Zapret2: снять службы (иначе enabled-юниты останутся ссылаться на удалённые файлы)
        log_info "Останавливаю службы Zapret2 (если ставились)..."
        local _z2_unit
        for _z2_unit in mtpr-zapret2-watch.service mtpr-zapret2.service; do
            systemctl stop "$_z2_unit" >/dev/null 2>&1 || true
            systemctl disable "$_z2_unit" >/dev/null 2>&1 || true
            rm -f "/etc/systemd/system/$_z2_unit" || true
        done
        rm -f /usr/local/sbin/mtpr-zapret2-watch.sh || true
        systemctl daemon-reload >/dev/null 2>&1 || true

        if ensure_rules_loaded; then
            if declare -f zapret2_remove_nft >/dev/null 2>&1; then
                zapret2_remove_nft >/dev/null 2>&1 || log_warning "Не удалось удалить nft-таблицу Zapret2"
            fi
            if declare -f remove_geoip_bypass >/dev/null 2>&1; then
                log_info "Удаляю GEOIP-обход SYN-лимита (правило, cron-задача)..."
                remove_geoip_bypass || log_warning "Не удалось полностью удалить GEOIP-обход"
            fi
            remove_syn_fix || log_warning "Не удалось полностью снять SYN-фикс"
        else
            log_warning "rules.sh не загружен, пропускаем удаление правил"
        fi
    fi

    # ── Файлы менеджера и лаунчеры (только когда удаляем сам менеджер) ──
    local _rm_files_ok=false
    if [ "$_do_meko" = true ]; then
        log_info "Удаление файлов конфигурации и лаунчеров..."

        # Лаунчеры: снимаем только свои ссылки, чужие файлы не трогаем
        local _link _target
        for _link in /usr/local/bin/mekopr /usr/local/bin/meko /usr/local/bin/mekomanager; do
            [ -n "$INSTALL_DIR" ] || continue   # защита: пустой INSTALL_DIR иначе даёт шаблон /* 
            [ -L "$_link" ] || continue
            _target="$(readlink -f "$_link" 2>/dev/null || true)"
            case "$_target" in
                "$INSTALL_DIR"/*) rm -f "$_link" && log_info "Удалён лаунчер $_link" ;;
            esac
        done

        if rm -rf "$INSTALL_DIR" 2>/dev/null; then
            log_success "Каталог $INSTALL_DIR удалён"
            _rm_files_ok=true
        else
            log_warning "Не удалось полностью удалить $INSTALL_DIR — проверьте вручную"
        fi
    fi

    # ── Итог ────────────────────────────────────────────────
    if [ "$_do_meko" = true ]; then
        if [ "$_rm_files_ok" = true ]; then
            case "$scope" in
                meko)        log_success "MEKO Manager удалён (правила и Telemt оставлены на месте)!" ;;
                fix)         log_success "MEKO Manager и фиксы удалены с сервера!" ;;
                all)         log_success "MEKO Manager, фиксы и Telemt удалены с сервера!" ;;
                meko-telemt) log_success "MEKO Manager и Telemt удалены (фиксы оставлены на месте)!" ;;
            esac
        else
            log_warning "Удаление завершено частично — проверьте оставшиеся файлы вручную"
        fi
    else
        case "$scope" in
            fix-only)   log_success "Фиксы удалены (MEKO Manager и Telemt оставлены на месте)!" ;;
            telemt)     log_success "Telemt удалён (MEKO Manager и фиксы оставлены на месте)!" ;;
            fix-telemt) log_success "Фиксы и Telemt удалены (MEKO Manager оставлен на месте)!" ;;
        esac
    fi

    # Менеджер удалён — работать дальше нечем, выходим из скрипта.
    if [ "$_do_meko" = true ]; then
        if [ "$MEKOPR_ASSUME_YES" != true ]; then
            echo ""
            log_info "Для завершения работы скрипта нажмите Enter..."
            { read -r </dev/tty; } 2>/dev/null || true
        fi
        log_info "Удаление скрипта $(basename "${SELF_PATH:-$0}")..."
        rm -f "${SELF_PATH:-$0}" 2>/dev/null || true
        exit 0
    fi

    # Менеджер остался на месте — возвращаемся в меню.
    return 0
}

# ── Подменю удаления: выбор области ──────────────────────────
remove_mekopr_menu() {
    while true; do
        clear 2>/dev/null || true
        echo ""
        echo -e "  ${CYAN}${BOLD}══════════ Удаление MEKO Manager ══════════${NC}"
        echo ""
        echo -e "  ${BOLD}Один компонент:${NC}"
        echo -e "  ${CYAN}[1]${NC}  ${BOLD}Только MEKO Manager${NC} ${DIM}(фиксы и Telemt остаются)${NC}"
        echo -e "  ${CYAN}[2]${NC}  ${BOLD}Только фиксы${NC} ${DIM}(SYN-фикс, nftables, GEOIP, Zapret2, шейпинг, блокировка IP)${NC}"
        echo -e "  ${CYAN}[3]${NC}  ${BOLD}Только Telemt${NC} ${DIM}(служба/контейнер, конфиг, образы)${NC}"
        echo ""
        echo -e "  ${BOLD}Комбинации:${NC}"
        echo -e "  ${CYAN}[4]${NC}  ${BOLD}MEKO Manager + фиксы${NC}"
        echo -e "  ${CYAN}[5]${NC}  ${BOLD}MEKO Manager + Telemt${NC}"
        echo -e "  ${CYAN}[6]${NC}  ${BOLD}фиксы + Telemt${NC}"
        echo -e "  ${RED}${BOLD}[7]${NC}  ${RED}${BOLD}Всё: MEKO Manager + фиксы + Telemt${NC} ${DIM}(полная очистка)${NC}"
        echo ""
        echo -e "  ${CYAN}[0]${NC}  ${BOLD}Назад в главное меню${NC}"
        echo ""
        echo -en "  ${BOLD}Выбор:${NC} "
        local choice
        { read -r choice </dev/tty; } 2>/dev/null || { echo; return 1; }
        case "$choice" in
            1) remove_mekopr meko ;;
            2) remove_mekopr fix-only; _opt_pause ;;
            3) remove_mekopr telemt; _opt_pause ;;
            4) remove_mekopr fix ;;
            5) remove_mekopr meko-telemt ;;
            6) remove_mekopr fix-telemt; _opt_pause ;;
            7) remove_mekopr all ;;
            0 | "") return 0 ;;
            *) log_error "Неверный выбор"; sleep 0.2 ;;
        esac
    done
}

# ── Очистка экрана и шапка ──────────────────────────────────
clear_screen() {
    if [ -t 1 ]; then
        clear 2>/dev/null || printf '\033[2J\033[H'
    fi
}

is_mtprotozig_installed() {
    command -v mtbuddy >/dev/null 2>&1
}

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
    echo -e "  ${NC}${BOLD}MEKO ${CYAN}${BOLD}| ${NC}${BOLD}MTProto Manager ${CYAN}${BOLD} v2.0${NC}"
    echo -e "  ${DIM}══════════════════════════════${NC}"
    echo ""

    # ── Информация об ОС ──────────────────────────────────
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
        os_version=$(awk '{print $3}' /etc/almalinux-release)
    elif [ -f /etc/redhat-release ]; then
        os_name="Red Hat"
        os_version=$(grep -oE '[0-9]+\.[0-9]+' /etc/redhat-release | head -1)
    else
        os_name="Unknown OS"
        os_version=""
    fi

    if [ -n "$os_name" ] && [ -n "$os_version" ]; then
        echo -e "  ${BOLD}${os_name}:${NC} ${YELLOW}${BOLD}${os_version}${NC}"
    elif [ -n "$os_name" ]; then
        echo -e "  ${BOLD}${os_name}${NC}"
    fi

    # ── Версия OpenSSL (нужна для SelfSteal SNI) ──────────
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

    # ── IP сервера ────────────────────────────────────────
    local server_ip=""
    if command -v ip >/dev/null 2>&1; then
        server_ip=$(ip route get 1 2>/dev/null | grep -o 'src [0-9.]*' | awk '{print $2}' | head -1 || true)
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

    # ── Порты прокси ──────────────────────────────────────
    local open_ports=""
    if [ -f "$PORT_FILE" ] && [ -s "$PORT_FILE" ]; then
        open_ports=$(cat "$PORT_FILE")
    fi
    if [ -z "$open_ports" ] || [ "$open_ports" = "skip" ]; then
        if [ -n "$CONFIG_TELEMT" ] && [ -f "$CONFIG_TELEMT" ]; then
            local telemt_port
            telemt_port=$(get_port_from_config "$CONFIG_TELEMT") || telemt_port=""
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

    # путь к конфигу: сохранённый → CONFIG_TELEMT → автоопределение (один вызов, не два)
    local current_config_path=""
    local _saved=""
    if [ -f "$CONFIG_PATH_FILE" ] && [ -s "$CONFIG_PATH_FILE" ]; then
        _saved=$(cat "$CONFIG_PATH_FILE")
        [ "$_saved" = "skip" ] && _saved=""
    fi
    current_config_path="${_saved:-$CONFIG_TELEMT}"
    [ "$current_config_path" = "skip" ] && current_config_path=""

    if [ -z "$current_config_path" ] || [ ! -f "$current_config_path" ]; then
        local _detected=""
        _detected=$(detect_all_telemt_configs)
        current_config_path="${_detected%%:*}"
    fi

    if [ -n "$current_config_path" ] && [ -f "$current_config_path" ]; then
        CONFIG_TELEMT="$current_config_path"
        echo "$current_config_path" > "$CONFIG_PATH_FILE"
    else
        CONFIG_TELEMT=""
    fi

    # ── Статус SYN FIX (iptables + nftables) ──────────────
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
        echo -e "  ${BOLD}SYN FIX iptables:${NC} ${GRAY}${BOLD}Не установлен${NC}"
    else
        echo -e "  ${BOLD}SYN FIX iptables:${NC} ${RED}${BOLD}Недоступно${NC}"
    fi

    if [ "$nft_status" = "active" ]; then
        echo -e "  ${BOLD}SYN FIX nftables:${NC} ${GREEN}Установлен${NC}"
    elif [ "$nft_status" = "has_table_only" ]; then
        echo -e "  ${BOLD}SYN FIX nftables:${NC} ${YELLOW}Таблица есть, сервис не запущен${NC}"
    elif [ "$nft_status" = "inactive" ]; then
        echo -e "  ${BOLD}SYN FIX nftables:${NC} ${GRAY}${BOLD}Не установлен${NC}"
    else
        echo -e "  ${BOLD}SYN FIX nftables:${NC} ${RED}${BOLD}Недоступно${NC}"
    fi

    # ── Статус Zapret2 ────────────────────────────────────
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

    # ── Найденные конфиги Telemt ───────────────────────────
    local all_configs
    all_configs=$(detect_all_telemt_configs) || all_configs=""
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
            
            local _port
            _port=$(get_port_from_config "$cfg") || _port=""
            local _version
            _version=$(get_telemt_version) || _version=""
            local _online
            _online=$(get_telemt_online_for_config "$cfg") || _online=""
            local _mss_enabled
            _mss_enabled=$(is_mss_enabled_for_config "$cfg" && echo "включен" || echo "отключен") || _mss_enabled=""
            local _mss_bulk_enabled
            _mss_bulk_enabled=$(is_mss_bulk_enabled_for_config "$cfg" && echo "включен" || echo "отключен") || _mss_bulk_enabled=""
            local _synlimit_enabled
            _synlimit_enabled=$(is_synlimit_enabled_for_config "$cfg" && echo "включен" || echo "отключен") || _synlimit_enabled=""
            
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
            if [[ "$_online" =~ ^[0-9]+$ ]]; then
                echo -e "  ${BOLD}Telemt онлайн:${NC} ${CYAN}${_online}${NC}${BOLD} человек"
            else
                echo -e "  ${BOLD}Telemt онлайн:${NC} ${CYAN}н/д${NC}${BOLD} (API Telemt не ответил)"
            fi
            echo -e "  ${BOLD}Встроенный MSS:${NC} ${mss_color}${_mss_enabled}${NC}  |  ${BOLD}MSS_BULK:${NC} ${mss_bulk_color}${_mss_bulk_enabled}${NC}  |  ${BOLD}Synlimit:${NC} ${synlimit_color}${_synlimit_enabled}${NC}"
        done
    elif [ "$telemt_installed" = true ] && [ ${#configs_array[@]} -eq 0 ]; then
        local _version
        _version=$(get_telemt_version) || _version=""
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

    # ── Mtproto.zig ───────────────────────────────────────
    if [ "$mtprotozig_installed" = true ]; then
        local online_count
        online_count=$(get_mtprotozig_online) || online_count=""
        if [ -n "$online_count" ] && [ "$online_count" -ge 0 ] 2>/dev/null; then
            echo ""
            echo -e "  ${BOLD}Mtproto.zig онлайн:${NC} ${CYAN}$online_count${NC} человек"
        else
            echo ""
            echo -e "  ${BOLD}Mtproto.zig онлайн:${NC} ${CYAN}0${NC} человек"
        fi
    fi

    # ── MTG ───────────────────────────────────────────────
    if [ "$mtg_installed" = true ]; then
        local mtg_version
        mtg_version=$(get_mtg_version) || mtg_version=""
        local mtg_config_path
        mtg_config_path=$(get_mtg_config_path) || mtg_config_path=""
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

    # ── Есть ли хотя бы один прокси ───────────────────────
    if [ "$telemt_installed" = false ] && [ "$mtprotozig_installed" = false ] && [ "$mtg_installed" = false ]; then
        echo -e "  ${NC}${BOLD}Прокси: ${GRAY} не установлены${NC}"
    fi
}

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

open_proxy_menu() {
    local PROXY_MENU_SCRIPT="$INSTALL_DIR/proxys/proxymenu.sh"
    if [ -f "$PROXY_MENU_SCRIPT" ]; then
        # Дочерний запуск, НЕ exec: иначе главное меню заменяется прокси-меню
        # и стек меню растёт на каждый заход (issue #35).
        run_menu_script "$PROXY_MENU_SCRIPT"
    else
        log_error "Файл $PROXY_MENU_SCRIPT не найден"
        wait_key "Нажмите любую клавишу для возврата в меню..."
    fi
}

check_censor() {
    echo ""
    log_info "Проверка ограничений на сервере..."
    echo ""
    local _cc_tmp
    _cc_tmp="$(mktemp /tmp/censorcheck.XXXXXX.sh 2>/dev/null || true)"
    if [ -z "$_cc_tmp" ]; then
        log_error "Не удалось создать временный файл"
    elif ! wget -qO "$_cc_tmp" https://raw.githubusercontent.com/Nokola-Tesla/censorcheck/main/censorcheck.sh; then
        log_error "Не удалось скачать censorcheck.sh"
        rm -f "$_cc_tmp"
    elif [ ! -s "$_cc_tmp" ]; then
        log_error "Скачанный censorcheck.sh пуст"
        rm -f "$_cc_tmp"
    else
        bash "$_cc_tmp" || true
        rm -f "$_cc_tmp"
    fi
    echo ""
    wait_key "Нажмите любую клавишу для возврата в меню..."
}

# ── Главное меню ─────────────────────────────────────────────
main_menu() {
    if [[ "$1" == "-auto_install" ]]; then
        local forced_port="$2"
        echo -e "  ${BLUE}[i]${NC} Запуск в режиме авто-установки SYN FIX..."
        if ensure_rules_loaded; then
            # Порт передаём явно через -port: позиционный аргумент
            # install_syn_fix игнорирует и ставит фикс на 443.
            if [ -n "$forced_port" ]; then
                install_syn_fix -auto_install -port "$forced_port"
            else
                install_syn_fix -auto_install
            fi
        else
            log_error "Невозможно выполнить автоустановку: rules.sh не загружен"
            wait_key "Нажмите любую клавишу..."
        fi
        return 0
    fi

    while true; do
        show_header
        echo ""

        local rules_available=0
        ensure_rules_loaded 2>/dev/null && rules_available=1

        if [ "$rules_available" -eq 1 ]; then
            local iptables_status
            iptables_status=$(get_synfix_status) || iptables_status=""
            local nft_status
            nft_status=$(get_nft_fix_status) || nft_status=""
            if [ "$iptables_status" = "inactive" ] && [ "$nft_status" = "inactive" ]; then
                local item1="${NC}${BOLD}Меню установки ${CYAN}${BOLD}MTProto FIX${NC}"
            else
                local item1="${RED}${BOLD}Удалить Mtproto FIX${NC}"
            fi
        else
            local item1="${YELLOW}${BOLD}Установить/Удалить SYN FIX (недоступно)${NC}"
        fi

        local opt_state="не применена"
        if is_optimization_applied; then
            opt_state="применена"
        fi
        local item2_text="${NC}${BOLD}Базовая оптимизация${NC} ${DIM}(статус: ${opt_state})${NC}"

        echo -e "  ${DIM}══════════════════════════════"
        echo -e "  ${CYAN}${BOLD}[1]${NC}  $item1"
        echo -e "  ${CYAN}[2]${NC}  $item2_text"
        echo -e ""
        echo -e "  ${CYAN}[3]${NC}  ${BOLD}Меню прокси и настройки конфигов${NC}"
        echo -e "  ${CYAN}[4]${NC}  ${BOLD}Меню управления нодами${NC}"
        echo -e "  ${CYAN}[5]${NC}  ${CYAN}${BOLD}Обновить${NC}${BOLD} скрипт${NC}"
        echo -e ""
        echo -e "  ${CYAN}[6]${NC}  ${BOLD}Проверить доступ к популярным сайтам с сервера${NC}"
        echo -e "  ${CYAN}[7]${NC}  ${BOLD}Проверить домен для прокси${YELLOW}${BOLD} (Требуется: OpenSSL 3.5+)  ${NC}"
        echo -e "  ${CYAN}[8]${NC}  ${BOLD}Дополнительно${NC} ${DIM}(GEOIP, шейпинг, Caddy, сервисы, бэкап)${NC}"
        echo -e "  ${RED}${BOLD}[9]${NC}  ${RED}${BOLD}Удалить${NC}${BOLD} MEKO Manager${NC} ${DIM}(все варианты: менеджер / фиксы / Telemt)${NC}"
        echo -e "  ${RED}${BOLD}[0]${NC}${BOLD}  Выход"
        echo ""
        echo -en "  ${BOLD}Выбор:${NC} "
        local choice
        { read -r choice </dev/tty; } 2>/dev/null || { echo; log_error "Нет доступа к терминалу для ввода. Выход."; exit 1; }

        case "$choice" in
        1)
            echo ""
            if ! ensure_rules_loaded; then
                log_error "Невозможно выполнить действие: rules.sh не загружен"
                wait_key "Нажмите любую клавишу для возврата в меню..."
                continue
            fi

            local iptables_status
            iptables_status=$(get_synfix_status) || iptables_status=""
            local nft_status
            nft_status=$(get_nft_fix_status) || nft_status=""
            
            if [ "$iptables_status" != "inactive" ]; then
                log_info "Обнаружен iptables SYN FIX ($SYNFIX_CHAIN). Удалить?"
                echo -en "  ${BOLD}Удалить? [Y/n]:${NC} "
                local confirm
                { read -r confirm </dev/tty; } 2>/dev/null || { echo; log_error "Нет доступа к терминалу для ввода. Выход."; exit 1; }
                if [[ -z "$confirm" || "$confirm" =~ ^[yY]$ ]]; then
                    remove_syn_fix || true
                else
                    log_info "Отмена удаления"
                fi
                echo ""
                wait_key "Нажмите любую клавишу для возврата в меню..."
                continue
            fi
            
            if [ "$nft_status" != "inactive" ]; then
                log_info "Обнаружен nftables SYN FIX (mtpr_synfix). Удалить?"
                echo -en "  ${BOLD}Удалить? [Y/n]:${NC} "
                local confirm
                { read -r confirm </dev/tty; } 2>/dev/null || { echo; log_error "Нет доступа к терминалу для ввода. Выход."; exit 1; }
                if [[ -z "$confirm" || "$confirm" =~ ^[yY]$ ]]; then
                    remove_syn_fix || true
                else
                    log_info "Отмена удаления"
                fi
                echo ""
                wait_key "Нажмите любую клавишу для возврата в меню..."
                continue
            fi
            
            install_syn_fix || true
            ;;
        2)
            optimization_menu
            ;;
        3)
            open_proxy_menu
            ;;
        4)
            echo ""
            install_node_manager
            ;;
        5)
            echo ""
            update_script
            ;;
        6)
            check_censor
            ;;
        7)
            echo ""
            OPENSSL_VERSION=$(openssl version 2>/dev/null | awk '{print $2}')
            REQUIRED_VERSION="3.5"
            
            if [ -z "$OPENSSL_VERSION" ]; then
                log_error "Не удалось определить версию OpenSSL"
                wait_key "Нажмите любую клавишу для возврата в меню..."
                continue
            fi
            
            if [[ "$(printf '%s\n' "$REQUIRED_VERSION" "$OPENSSL_VERSION" | sort -V | head -n1)" != "$REQUIRED_VERSION" ]]; then
                echo ""
                echo -e "  ${RED}${BOLD}❌ Данная функция доступна только на ОС с OpenSSL 3.5 и выше${NC}"
                echo -e "  ${YELLOW}Ваша версия OpenSSL: ${OPENSSL_VERSION}${NC}"
                echo ""
                wait_key "Нажмите любую клавишу для возврата в меню..."
                continue
            fi
            
            CHECKER_SCRIPT="$INSTALL_DIR/proxy_checker.py"
            if [ -f "$CHECKER_SCRIPT" ]; then
                chmod +x "$CHECKER_SCRIPT"
                python3 "$CHECKER_SCRIPT"
            else
                log_error "Файл $CHECKER_SCRIPT не найден"
                wait_key "Нажмите любую клавишу для возврата в меню..."
            fi
            ;;

        8)
            echo ""
            if ensure_data_script "data/extra_menu.sh"; then
                run_menu_script "$INSTALL_DIR/data/extra_menu.sh"
            else
                wait_key "Нажмите любую клавишу для возврата в меню..."
            fi
            ;;
        9)
            remove_mekopr_menu
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
    local url="$BASE_URL/main.sh"
    local temp
    temp="/tmp/$(basename "$SELF_PATH").new.$$" || temp=""

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

    SCRIPT_NAME=$(basename "$SELF_PATH")

    echo -e "  ${BLUE}[i]${NC} Исполняемый файл: ${SCRIPT_NAME}"
    echo ""

    mkdir -p "$INSTALL_DIR"
    mkdir -p "$INSTALL_DIR/proxys"
    mkdir -p "$INSTALL_DIR/data"

    download_file() {
        local file="$1"
        local desc="$2"
        local url="$BASE_URL/$file"
        local dest="$INSTALL_DIR/$file"
        local name
        name=$(basename "$file") || name=""
        
        local size
        size=$(curl -sI "$url" 2>/dev/null | grep -i "Content-Length" | awk '{print $2}' | tr -d '\r') || size=""
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
    echo -e "  ${BOLD}Чтение файлов из репозитория для загрузки и подготовка к установке...${NC}"
    echo ""

    FILES_TO_DOWNLOAD=()
    while IFS='|' read -r file_path description; do
        [[ "$file_path" =~ ^[[:space:]]*#.*$ ]] && continue
        [ -z "$file_path" ] && continue

        file_path="${file_path#"${file_path%%[![:space:]]*}"}"
        file_path="${file_path%"${file_path##*[![:space:]]}"}"
        description="${description#"${description%%[![:space:]]*}"}"
        description="${description%"${description##*[![:space:]]}"}"
        [ -z "$file_path" ] && continue

        FILES_TO_DOWNLOAD+=("$file_path|$description")
        
    done < "$MANIFEST_FILE"

    echo -e "  ${BOLD}Файлы для загрузки (${#FILES_TO_DOWNLOAD[@]} шт.):${NC}"
    for entry in "${FILES_TO_DOWNLOAD[@]}"; do
        IFS='|' read -r file_path desc <<< "$entry"
        echo -e "    ${DIM}• ${file_path}${NC} (${desc})"
    done
    echo ""

    echo -e "  ${BOLD}Загрузка файлов...${NC}"
    echo ""

    for entry in "${FILES_TO_DOWNLOAD[@]}"; do
        IFS='|' read -r file_path description <<< "$entry"
        download_file "$file_path" "$description"
    done

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

    echo -ne "  ${CYAN}[+]${NC} Установка прав выполнения... "
    chmod +x "$INSTALL_DIR/proxys/"*.sh 2>/dev/null || true
    chmod +x "$INSTALL_DIR"/*.py 2>/dev/null || true
    echo -e "${GREEN}✓${NC}"

    rm -f "$MANIFEST_FILE"

    if mv "$temp" "$SELF_PATH"; then
        echo -e "  ${GREEN}[✓]${NC} Обновление успешно!"
        echo ""
        wait_key "Нажмите любую клавишу для возврата в меню..."
        exec bash "$SELF_PATH"
    else
        echo -e "  ${RED}[✗]${NC} Не удалось перезаписать файл"
        rm -f "$temp"
        echo ""
        wait_key "Нажмите любую клавишу для возврата в меню..."
        return 1
    fi
}

# ── Установка/обновление Node Manager ──────────────────────────
install_node_manager() {
    local BASE_URL="https://raw.githubusercontent.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/main"
    local MANIFEST_URL="$BASE_URL/remote_ctl/manifest.txt"
    local MANIFEST_FILE="/tmp/node_manager_manifest.txt"
    local NODE_DIR="$INSTALL_DIR/remote_ctl"
    local MANAGER_SCRIPT="$NODE_DIR/node_manager.sh"

    echo ""
    echo -e "  ${GREEN}[✓]${NC} Скачиваем манифест Node Manager..."
    if ! curl -fsSL "$MANIFEST_URL" -o "$MANIFEST_FILE"; then
        echo -e "  ${RED}[✗]${NC} Не удалось загрузить информацию о необходимых файлах"
        return 1
    fi

    echo -e "  ${BLUE}[i]${NC} Загрузка данных..."
    echo ""

    mkdir -p "$NODE_DIR"

    download_node_file() {
        local file="$1"
        local desc="$2"
        local url="$BASE_URL/remote_ctl/$file"
        local dest="$NODE_DIR/$file"
        local name
        name=$(basename "$file") || name=""
        local dir
        dir=$(dirname "$dest") || dir=""
        mkdir -p "$dir"

        local size
        size=$(curl -sI "$url" 2>/dev/null | grep -i "Content-Length" | awk '{print $2}' | tr -d '\r') || size=""
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

    echo -e "  ${BOLD}Чтение файлов из репозитория для загрузки и подготовка к установке...${NC}"
    echo ""

    FILES_TO_DOWNLOAD=()
    while IFS='|' read -r file_path description; do
        [[ "$file_path" =~ ^[[:space:]]*#.*$ ]] && continue
        [ -z "$file_path" ] && continue

        file_path="${file_path#"${file_path%%[![:space:]]*}"}"
        file_path="${file_path%"${file_path##*[![:space:]]}"}"
        description="${description#"${description%%[![:space:]]*}"}"
        description="${description%"${description##*[![:space:]]}"}"

        FILES_TO_DOWNLOAD+=("$file_path|$description")

    done < "$MANIFEST_FILE"

    echo -e "  ${BOLD}Файлы для загрузки (${#FILES_TO_DOWNLOAD[@]} шт.):${NC}"
    for entry in "${FILES_TO_DOWNLOAD[@]}"; do
        IFS='|' read -r file_path desc <<< "$entry"
        echo -e "    ${DIM}• ${file_path}${NC} (${desc})"
    done
    echo ""

    echo -e "  ${BOLD}Загрузка файлов...${NC}"
    echo ""

    for entry in "${FILES_TO_DOWNLOAD[@]}"; do
        IFS='|' read -r file_path description <<< "$entry"
        download_node_file "$file_path" "$description"
    done

    echo ""
    local failed=0
    for entry in "${FILES_TO_DOWNLOAD[@]}"; do
        IFS='|' read -r file_path description <<< "$entry"
        if [ ! -f "$NODE_DIR/$file_path" ]; then
            echo -e "  ${RED}[✗]${NC} Файл не найден: $file_path"
            failed=1
        fi
    done

    if [ $failed -eq 1 ]; then
        echo -e "  ${RED}[✗]${NC} Установка не удалась: некоторые файлы не загружены"
        echo -e "  ${YELLOW}Проверьте подключение к интернету и доступность репозитория.${NC}"
        echo -e "  ${YELLOW}Попробуйте установить позже.${NC}"
        rm -f "$MANIFEST_FILE"
        return 1
    fi

    echo -ne "  ${CYAN}[+]${NC} Установка прав выполнения... "
    chmod +x "$NODE_DIR/"*.sh 2>/dev/null || true
    chmod +x "$NODE_DIR/"*/*.sh 2>/dev/null || true
    echo -e "${GREEN}✓${NC}"

    # ── Создание команды mekomanager ────────────────────────────
    if [ -f "$MANAGER_SCRIPT" ]; then
        if [ ! -L /usr/local/bin/mekomanager ] || [ "$(readlink /usr/local/bin/mekomanager)" != "$MANAGER_SCRIPT" ]; then
            ln -sf "$MANAGER_SCRIPT" /usr/local/bin/mekomanager
            log_success "Создана команда mekomanager -> $MANAGER_SCRIPT (написав её в консоли вы можете открывать меню Node Manager )"
        else
            log_info "Команда mekomanager уже существует и указывает на правильный файл."
        fi
    else
        log_warning "Файл $MANAGER_SCRIPT не найден, команда mekomanager не создана."
    fi

    rm -f "$MANIFEST_FILE"

    echo -e "  ${GREEN}[✓]${NC} Node Manager успешно установлен в $NODE_DIR"
    echo ""

    if [ -f "$MANAGER_SCRIPT" ]; then
        echo -e "${NC}${BOLD}Для открытия Node Manager не через меню используйте команду: ${GREEN}${BOLD} mekomanager"
        echo -e ""
        wait_key "Нажмите любую клавишу для запуска Node Manager"
        exec bash "$MANAGER_SCRIPT"
    else
        log_error "Не удалось найти $MANAGER_SCRIPT после установки."
        wait_key "Нажмите любую клавишу для возврата в меню..."
    fi
}

# ── CLI: онлайн (Telemt / Mtproto.zig / MTG) ──────────────────
cli_online() {
    MEKOPR_CLI=true
    local found=0

    echo ""
    echo -e "  ${BOLD}${CYAN}Текущий онлайн${NC}"
    echo -e "  ${DIM}══════════════════════════════════════════${NC}"

    if is_telemt_installed; then
        local configs
        configs="$(detect_all_telemt_configs 2>/dev/null || true)"
        if [ -n "$configs" ]; then
            local _cfg
            while IFS= read -r _cfg; do
                [ -n "$_cfg" ] || continue
                local _port _online
                _port="$(get_port_from_config "$_cfg" 2>/dev/null || true)"
                _online="$(get_telemt_online_for_config "$_cfg" 2>/dev/null || true)"
                [[ "$_online" =~ ^[0-9]+$ ]] || _online="н/д"
                if [ -n "$_port" ]; then
                    echo -e "    ${BOLD}Telemt${NC} ${DIM}($_cfg, порт $_port)${NC}: ${CYAN}${_online}${NC} человек"
                else
                    echo -e "    ${BOLD}Telemt${NC} ${DIM}($_cfg)${NC}: ${CYAN}${_online}${NC} человек"
                fi
                found=1
            done <<< "$(printf '%s\n' "$configs" | tr ':' '\n')"
        fi
        if [ "$found" -eq 0 ]; then
            echo -e "    ${BOLD}Telemt${NC}: ${YELLOW}установлен, но конфиг не найден${NC}"
            found=1
        fi
    fi

    if is_mtprotozig_installed; then
        local _zig_online
        _zig_online="$(get_mtprotozig_online 2>/dev/null || echo 0)"
        [ -n "$_zig_online" ] || _zig_online=0
        echo -e "    ${BOLD}Mtproto.zig${NC}: ${CYAN}${_zig_online}${NC} человек"
        found=1
    fi

    if is_mtg_installed; then
        echo -e "    ${BOLD}MTG${NC}: ${DIM}установлен (счётчик онлайна движок не отдаёт)${NC}"
        found=1
    fi

    if [ "$found" -eq 0 ]; then
        echo -e "    ${YELLOW}Ни Telemt, ни Mtproto.zig, ни MTG не установлены${NC}"
    fi
    echo ""
    return 0
}

# ── CLI: открыть конкретное меню ─────────────────────────────
# _cli_open <раздел> [аргументы…] — запускает меню из каталога установки
_cli_open() {
    MEKOPR_CLI=true
    local target="${1:-}"
    [ -n "$target" ] && shift

    local rel=""
    case "$target" in
        telemt)          rel="proxys/telemt1.sh" ;;
        proxy|proxies)   rel="proxys/proxymenu.sh" ;;
        zig|mtprotozig)  rel="proxys/mtprotozig1.sh" ;;
        mtg)             rel="proxys/mtgv2_1.sh" ;;
        docker)          rel="proxys/telemt_in_docker1.sh" ;;
        panel)           rel="proxys/telemt_panel_amirotin.sh" ;;
        fix|rules)       rel="data/rules.sh" ;;
        geoip)           rel="data/rules.sh"; set -- -geoip "$@" ;;
        shaping)         rel="data/shaping.sh" ;;
        security|sec)    rel="data/security.sh" ;;
        backup)          rel="data/backup_panel.sh"; set -- --scope all "$@" ;;
        services)        rel="data/services_menu.sh" ;;
        extra)           rel="data/extra_menu.sh" ;;
        caddy)           rel="proxys/caddy_pq.sh" ;;
        nodes|node|manager) rel="remote_ctl/node_manager.sh" ;;
        *) log_error "Неизвестный раздел: $target"; _cli_usage; return 2 ;;
    esac

    local script="$INSTALL_DIR/$rel"
    ensure_data_script "$rel" || return 1
    run_menu_script "$script" "$@"
    return $?
}

# ── CLI: справка ──────────────────────────────────────────────
_cli_usage() {
    echo ""
    echo -e "  ${BOLD}MEKO Manager — командная строка${NC}"
    echo ""
    echo -e "  ${CYAN}mekopr${NC}                             открыть главное меню"
    echo -e "  ${CYAN}mekopr online${NC}                      текущий онлайн (Telemt / Mtproto.zig / MTG)"
    echo -e "  ${CYAN}mekopr status${NC}                      краткий статус системы"
    echo ""
    echo -e "  ${BOLD}Открыть раздел напрямую:${NC}"
    echo -e "  ${CYAN}mekopr telemt${NC}                      меню Telemt"
    echo -e "  ${CYAN}mekopr proxy${NC}                       меню прокси и конфигов"
    echo -e "  ${CYAN}mekopr zig | mtg | docker | panel${NC}  меню Mtproto.zig / MTG / Telemt в Docker / панель"
    echo -e "  ${CYAN}mekopr fix${NC}                         меню установки/удаления MTProto FIX"
    echo -e "  ${CYAN}mekopr geoip${NC}                       меню GEOIP-обхода SYN-лимита"
    echo -e "  ${CYAN}mekopr nodes${NC}                       меню управления нодами"
    echo -e "  ${CYAN}mekopr security${NC}                    меню безопасности (TLS-отпечатки, блокировка)"
    echo -e "  ${CYAN}mekopr shaping${NC}                     меню ограничения скорости"
    echo -e "  ${CYAN}mekopr backup${NC}                      меню бэкапа и восстановления"
    echo -e "  ${CYAN}mekopr services${NC}                    Cloudflare WARP / AdGuard Home"
    echo -e "  ${CYAN}mekopr caddy${NC}                       Caddy как PQ-заглушка"
    echo -e "  ${CYAN}mekopr extra${NC}                       меню «Дополнительно»"
    echo ""
    echo -e "  ${BOLD}Установка и удаление:${NC}"
    echo -e "  ${CYAN}mekopr install${NC} [флаги install.sh]  полная установка/обновление MEKO Manager"
    echo -e "  ${CYAN}mekopr remove [область] -y${NC}         удаление без вопросов (по умолчанию: fix)"
    echo -e "  ${CYAN}mekopr update${NC}                      обновить скрипт с GitHub"
    echo -e "  ${CYAN}mekopr help${NC}                        эта справка"
    echo ""
    echo -e "  ${DIM}Области удаления (любая комбинация компонентов):${NC}"
    echo -e "    ${BOLD}meko${NC}        — только файлы менеджера и сам скрипт"
    echo -e "    ${BOLD}fix-only${NC}    — только фиксы (SYN-фикс, nftables, GEOIP, Zapret2, шейпинг)"
    echo -e "    ${BOLD}telemt${NC}      — только Telemt (служба/контейнер, конфиг, образы)"
    echo -e "    ${BOLD}fix${NC}         — менеджер + фиксы"
    echo -e "    ${BOLD}meko-telemt${NC}  — менеджер + Telemt"
    echo -e "    ${BOLD}fix-telemt${NC}   — фиксы + Telemt"
    echo -e "    ${BOLD}all${NC}         — всё: менеджер + фиксы + Telemt"
    echo ""
    echo -e "  ${DIM}Примеры:${NC}"
    echo -e "    mekopr online"
    echo -e "    mekopr telemt"
    echo -e "    mekopr install -fix -fix-type v3 -port 8443"
    echo -e "    mekopr install -telemt -domain my.domain -port 443"
    echo -e "    mekopr remove all -y"
    echo ""
}

# ── CLI: полная установка/обновление ─────────────────────────
cli_install() {
    MEKOPR_CLI=true
    local tmp rc
    tmp="$(mktemp /tmp/mekopr-install.XXXXXX.sh 2>/dev/null)" || { log_error "Не удалось создать временный файл"; return 1; }
    log_info "Скачиваю установщик MEKO Manager..."
    if ! curl -fsSL --max-time 90 "$EXTRA_BASE_URL/install.sh" -o "$tmp" || [ ! -s "$tmp" ]; then
        rm -f "$tmp" 2>/dev/null || true
        log_error "Не удалось скачать $EXTRA_BASE_URL/install.sh"
        return 1
    fi
    log_info "Запускаю установку MEKO Manager..."
    echo ""
    rc=0
    bash "$tmp" "$@" || rc=$?
    rm -f "$tmp" 2>/dev/null || true
    if [ "$rc" -eq 0 ]; then
        echo ""
        log_success "Установка MEKO Manager завершена."
    else
        echo ""
        log_error "Установка MEKO Manager завершилась с кодом $rc"
    fi
    return "$rc"
}

# ── CLI: удаление ─────────────────────────────────────────────
cli_remove() {
    MEKOPR_CLI=true
    local scope="" assume_yes=false
    while [ $# -gt 0 ]; do
        case "$1" in
            meko|fix|all|fix-only|telemt|meko-telemt|fix-telemt) scope="$1" ;;
            -y|--yes) assume_yes=true ;;
            -h|--help) _cli_usage; return 0 ;;
            *) log_error "Неизвестный аргумент: $1"; _cli_usage; return 2 ;;
        esac
        shift
    done
    [ -n "$scope" ] || scope="fix"
    if [ "$assume_yes" != true ]; then
        log_error "Для удаления из командной строки требуется подтверждение -y (--yes)"
        echo -e "  Например: ${BOLD}mekopr --remove $scope -y${NC}"
        return 2
    fi
    MEKOPR_ASSUME_YES=true
    remove_mekopr "$scope"
}

# ── CLI: краткий статус ───────────────────────────────────────
cli_status() {
    MEKOPR_CLI=true
    show_header
    return 0
}

# ── Запуск ────────────────────────────────────────────────────
if [ $# -gt 0 ]; then
    case "$1" in
        --install|-i|install)
            shift
            cli_install "$@"
            exit $?
            ;;
        --remove|--uninstall|-r|remove|uninstall)
            shift
            cli_remove "$@"
            exit $?
            ;;
        --update|-u|update)
            update_script
            exit $?
            ;;
        online|--online)
            cli_online
            exit $?
            ;;
        --status|-s|status)
            cli_status
            exit $?
            ;;
        --help|-h|help)
            _cli_usage
            exit 0
            ;;
        --menu|-m|menu)
            shift
            main_menu "$@"
            exit $?
            ;;
        telemt|proxy|proxies|zig|mtprotozig|mtg|docker|panel|fix|rules|geoip|shaping|security|sec|backup|services|extra|caddy|nodes|node|manager)
            _cli_open "$@"
            exit $?
            ;;
        *)
            log_error "Неизвестная команда: $1"
            _cli_usage
            exit 2
            ;;
    esac
else
    main_menu "$@"
fi
