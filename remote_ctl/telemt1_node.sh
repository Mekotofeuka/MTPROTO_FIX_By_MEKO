#!/bin/bash
# telemt1_node.sh – удалённое управление Telemt через SSH
# Использование: ./telemt1_node.sh <IP> <USER> <PORT>

# ── Проверка аргументов ──────────────────────────────────────
if [ $# -lt 3 ]; then
    echo "❌ Использование: $0 <IP> <USER> <PORT>"
    exit 1
fi
REMOTE_IP="$1"
REMOTE_USER="$2"
REMOTE_PORT="$3"

# ── Функция выполнения команд через SSH ─────────────────────
ssh_exec() {
    ssh -p "$REMOTE_PORT" -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$REMOTE_USER@$REMOTE_IP" "$1" 2>/dev/null
}
ssh_interactive() {
    ssh -t -p "$REMOTE_PORT" -o StrictHostKeyChecking=no "$REMOTE_USER@$REMOTE_IP" "$1"
}

# ── Безопасный запуск внешнего установщика на удалённой ноде ──
# Собирает shell-команду для удалённого хоста: скачать скрипт во
# временный файл, проверить успех curl и непустой ответ, затем
# запустить. Раньше `curl ... | sh` на ноде давал 0 при 404.
# Использование: remote_installer_cmd <url> [args...]
remote_installer_cmd() {
    local url="$1"; shift
    local args=""
    if [ "$#" -gt 0 ]; then
        args="$*"
    fi
    printf 'tmp=$(mktemp) || exit 1; if ! curl -fsSL %s -o "$tmp"; then rm -f "$tmp"; exit 1; fi; if [ ! -s "$tmp" ]; then rm -f "$tmp"; exit 1; fi; sh "$tmp" %s; rc=$?; rm -f "$tmp"; exit $rc' "$url" "$args"
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

# ── Логирование ───────────────────────────────────────────────
# В этом файле хелперов log_* не было, из-за чего пункт [0]
# ("Назад в управление нодой") падал с "log_info: command not found".
log_info() { echo -e "  ${BLUE}[i]${NC} $1"; }
log_success() { echo -e "  ${GREEN}[✓]${NC} $1"; }
log_error() { echo -e "  ${RED}[✗]${NC} $1" >&2; }
log_warning() { echo -e "  ${YELLOW}[!]${NC} $1"; }

# pause_key [подсказка] — ждём клавишу, только если есть терминал
pause_key() {
    { : </dev/tty; } 2>/dev/null || return 0
    echo -e "  ${GRAY}${1:-Нажмите любую клавишу}${NC}"
    read -rsn1 </dev/tty || true
}

# ── Файл для сохранения пути к конфигу (используем общий с main.sh) ──
CONFIG_PATH_FILE="/opt/mtpr-simple/config_path"

# ── Функция обрезки пробелов  ──────
trim() {
    local var="$1"
    var="${var#"${var%%[![:space:]]*}"}"
    var="${var%"${var##*[![:space:]]}"}"
    printf '%s' "$var"
}

# ── Функция получения текущего пути к конфигу ──────────────
get_config_path() {
    local path
    path=$(ssh_exec "if [ -f \"$CONFIG_PATH_FILE\" ] && [ -s \"$CONFIG_PATH_FILE\" ]; then cat \"$CONFIG_PATH_FILE\"; fi")
    if [ -n "$path" ] && [ "$path" != "skip" ]; then
        echo "$path"
        return 0
    fi
    echo "/etc/telemt/telemt.toml"
    return 0
}

# ── Функции для работы с TOML ──────────────────────────────
_toml_get_value() {
    local _key="$1" _file="$2"
    ssh_exec "[ -f \"$_file\" ] && awk -v k=\"$_key\" '/^[[:space:]]*#/ { next } \$1 == k && \$2 == \"=\" { gsub(/[^0-9]/, \"\", \$3); print \$3; exit }' \"$_file\""
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
    ssh_exec "[ -f \"$_file\" ] && grep -qE '^\[access\.users\]|^\[censorship\]|^\[general\.modes\]|^tls_domain[[:space:]]*=' \"$_file\""
}

# ── Разбор FakeTLS-доменов ─────────────────
# Принимает «сырые» строки конфига (tls_domain и tls_domains) и печатает
# эффективный упорядоченный список доменов: первичный tls_domain первым,
# затем элементы tls_domains, дубликаты убраны (как в самом telemt).
_parse_tls_domains() {
    local _raw="$1"
    local _primary="" _extra="" _body="" _seen=" " _d=""
    _primary=$(printf '%s\n' "$_raw" | grep -E '^[[:space:]]*tls_domain[[:space:]]*=' | head -1 \
        | sed -E 's/^[^=]*=//; s/#.*$//' | tr -d '"' | tr -d '[:space:]')
    # Дополнительные домены берём ТОЛЬКО из тела массива tls_domains,
    # иначе в выборку попадают кавычки значения tls_domain.
    _body=$(printf '%s\n' "$_raw" | awk '
        /^[[:space:]]*tls_domains[[:space:]]*=/ {
            if (index($0, "]") > 0) { s=$0; sub(/^[^[]*\[/, "", s); sub(/\].*$/, "", s); print s; exit }
            grab=1; s=$0; sub(/^[^[]*\[/, "", s); buf=s; next
        }
        grab {
            if (index($0, "]") > 0) { s=$0; sub(/\].*$/, "", s); print buf "\n" s; exit }
            buf=buf "\n" $0
        }
    ')
    if [ -n "$_body" ]; then
        _extra=$(printf '%s\n' "$_body" | grep -oE '"[^"]*"' | tr -d '"')
    fi
    for _d in $_primary $_extra; do
        [ -n "$_d" ] || continue
        _d="${_d%%:*}"   # срезаем порт (example.com:443 -> example.com) после снятия кавычек/пробелов
        [ -n "$_d" ] || continue
        case " $_seen " in
            *" $_d "*) continue ;;
        esac
        _seen="${_seen}${_d} "
        printf '%s\n' "$_d"
    done
}

# hex-кодирование домена для SNI: печатает hex или пусто при сбое od
_domain_hex() {
    printf '%s' "$1" | od -An -tx1 2>/dev/null | tr -d ' \n'
}

# Читает FakeTLS-домены из конфига на удалённой ноде (по одному на строку).
get_tls_domains() {
    local _cfg="$1"
    [ -n "$_cfg" ] || return 0
    local _raw
    _raw=$(ssh_exec "awk '/^[[:space:]]*tls_domain[[:space:]]*=/{print; next} /^[[:space:]]*tls_domains[[:space:]]*=/{grab=1; print; if(index(\$0,\"]\")>0) grab=0; next} grab{print; if(index(\$0,\"]\")>0) grab=0}' \"$_cfg\" 2>/dev/null")
    _parse_tls_domains "$_raw"
}

# ── Расширенное обнаружение Telemt ──────────
detect_telemt_advanced() {
    local DETECTED_CONFIG_PATH=""
    local DETECTED_PORT=""
    local DETECTED_IP=""
    local DETECTED_PUBLIC_HOST=""
    local DETECTED_CLASSIC=""
    local DETECTED_SECURE=""
    local DETECTED_TLS=""
    local DETECTED_TLS_DOMAIN=""
    local DETECTED_SECRET=""
    
    # 1. Локальный процесс telemt
    if ssh_exec "pgrep -x telemt >/dev/null 2>&1 || systemctl is-active telemt.service >/dev/null 2>&1"; then
        local _args
        _args=$(ssh_exec "ps -eo args 2>/dev/null | grep '[t]elemt' | grep -v 'telemt-panel' | grep -v 'telemt_panel' | head -1 | grep -oE '/[^ ]+\.toml' | head -1")
        if [ -n "$_args" ] && ssh_exec "[ -f \"$_args\" ]" && ! _is_excluded_path "$_args" && _looks_like_telemt_config "$_args"; then
            DETECTED_CONFIG_PATH="$_args"
        fi
    fi
    
    # 2. Поиск конфига в стандартных местах
    if [ -z "$DETECTED_CONFIG_PATH" ]; then
        for _cf in /etc/telemt/telemt.toml /etc/telemt/config.toml /etc/telemt.toml /opt/telemt/config.toml /opt/telemt/telemt.toml; do
            if ssh_exec "[ -f \"$_cf\" ]" && ! _is_excluded_path "$_cf" && _looks_like_telemt_config "$_cf"; then
                DETECTED_CONFIG_PATH="$_cf"
                break
            fi
        done
    fi
    
    # 3. Проверяем сохранённый путь
    if [ -z "$DETECTED_CONFIG_PATH" ] && [ -f "$CONFIG_PATH_FILE" ] && [ -s "$CONFIG_PATH_FILE" ]; then
        local _saved_path
        _saved_path=$(ssh_exec "cat \"$CONFIG_PATH_FILE\"")
        if [ "$_saved_path" != "skip" ] && ssh_exec "[ -f \"$_saved_path\" ]" && _looks_like_telemt_config "$_saved_path"; then
            DETECTED_CONFIG_PATH="$_saved_path"
        fi
    fi
    
    # 4. Получаем параметры из конфига
    if [ -n "$DETECTED_CONFIG_PATH" ] && ssh_exec "[ -f \"$DETECTED_CONFIG_PATH\" ]"; then
        DETECTED_PORT=$(_toml_get_value "port" "$DETECTED_CONFIG_PATH")
        DETECTED_IP=$(ssh_exec "grep -E '^ip[[:space:]]*=' \"$DETECTED_CONFIG_PATH\" 2>/dev/null | head -1 | awk -F'=' '{print \$2}' | tr -d ' \"'")
        DETECTED_PUBLIC_HOST=$(ssh_exec "grep -E '^public_host[[:space:]]*=' \"$DETECTED_CONFIG_PATH\" 2>/dev/null | head -1 | awk -F'=' '{print \$2}' | tr -d ' \"'")
        DETECTED_TLS_DOMAIN=$(ssh_exec "grep -E '^tls_domain[[:space:]]*=' \"$DETECTED_CONFIG_PATH\" 2>/dev/null | head -1 | awk -F'=' '{print \$2}' | tr -d ' \"'")
        
        # Ищем секрет - сначала в секции [access.users], потом во всем файле
        DETECTED_SECRET=$(ssh_exec "sed -n '/^\[access\.users\]/,/^\[/p' \"$DETECTED_CONFIG_PATH\" 2>/dev/null | grep -E '=' | head -1 | awk -F'=' '{print \$2}' | tr -d ' \"'")
        if [ -z "$DETECTED_SECRET" ]; then
            DETECTED_SECRET=$(ssh_exec "grep -E '^[[:space:]]*[^#]*[[:space:]]*=' \"$DETECTED_CONFIG_PATH\" 2>/dev/null | grep -v '^#' | head -1 | awk -F'=' '{print \$2}' | tr -d ' \"'")
        fi
        
        # Проверяем режимы
        DETECTED_CLASSIC=$(ssh_exec "grep -E '^classic[[:space:]]*=' \"$DETECTED_CONFIG_PATH\" 2>/dev/null | grep -v '^#' | head -1 | awk -F'=' '{print \$2}' | tr -d ' \"'")
        DETECTED_SECURE=$(ssh_exec "grep -E '^secure[[:space:]]*=' \"$DETECTED_CONFIG_PATH\" 2>/dev/null | grep -v '^#' | head -1 | awk -F'=' '{print \$2}' | tr -d ' \"'")
        DETECTED_TLS=$(ssh_exec "grep -E '^tls[[:space:]]*=' \"$DETECTED_CONFIG_PATH\" 2>/dev/null | grep -v '^#' | head -1 | awk -F'=' '{print \$2}' | tr -d ' \"'")
    fi
    
    echo "$DETECTED_CONFIG_PATH:$DETECTED_PORT:$DETECTED_IP:$DETECTED_PUBLIC_HOST:$DETECTED_CLASSIC:$DETECTED_SECURE:$DETECTED_TLS:$DETECTED_TLS_DOMAIN:$DETECTED_SECRET"
}

# ── Функция получения публичного IP ──────────────────────────
get_public_ip() {
    local _ip
    _ip=$(ssh_exec "curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || curl -4 -fsS --max-time 5 https://ifconfig.me 2>/dev/null || curl -4 -fsS --max-time 5 https://icanhazip.com 2>/dev/null")
    echo "$_ip"
}

# ── Функция получения списка пользователей из конфига ──────
get_users_list() {
    local config_path
    config_path=$(get_config_path)
    if ! ssh_exec "[ -f \"$config_path\" ]"; then
        return 1
    fi
    
    ssh_exec "sed -n '/^\[access\.users\]/,/^\[/p' \"$config_path\" 2>/dev/null | grep -E '=' | grep -v '^#' | while IFS='=' read -r name secret; do
        name=\$(echo \"\$name\" | tr -d ' \"')
        secret=\$(echo \"\$secret\" | tr -d ' \"')
        if [ -n \"\$name\" ] && [ -n \"\$secret\" ]; then
            echo \"\$name:\$secret\"
        fi
    done"
}

# ── Функция поиска пользователя и вывода ссылки ─────────────
print_user_links() {
    local user_name="$1"
    local user_secret="$2"
    local config_path="$(get_config_path)"
    local detected_info
    detected_info=$(detect_telemt_advanced)
    local IFS=':'
    local parts=($detected_info)
    unset IFS
    
    local detected_port="${parts[1]}"
    local detected_ip="${parts[2]}"
    local detected_public_host="${parts[3]}"
    local detected_classic="${parts[4]}"
    local detected_secure="${parts[5]}"
    local detected_tls="${parts[6]}"
    local detected_tls_domain="${parts[7]}"
    
    # Определяем порт
    local port=""
    if [ -n "$detected_port" ]; then
        port="$detected_port"
    else
        port=$(ssh_exec "grep -E '^port[[:space:]]*=' \"$config_path\" 2>/dev/null | head -1 | awk -F'=' '{print \$2}' | tr -d ' \"'")
    fi
    if [ -z "$port" ]; then
        port="443"
    fi
    
    # Определяем сервер
    local server=""
    if [ -n "$detected_public_host" ]; then
        server="$detected_public_host"
    elif [ -n "$detected_ip" ]; then
        server="$detected_ip"
    else
        server=$(get_public_ip)
    fi
    if [ -z "$server" ]; then
        server=$(ssh_exec "curl -4 -fsS --max-time 3 https://api.ipify.org 2>/dev/null")
    fi
    if [ -z "$server" ]; then
        server="SERVER_IP"
    fi
    
    # Определяем режимы
    local classic_enabled=false
    local secure_enabled=false
    local tls_enabled=false
    
    if [ "$detected_classic" = "true" ]; then
        classic_enabled=true
    fi
    if [ "$detected_secure" = "true" ]; then
        secure_enabled=true
    fi
    if [ "$detected_tls" = "true" ]; then
        tls_enabled=true
    fi
    
    if [ "$classic_enabled" = false ] && [ "$secure_enabled" = false ] && [ "$tls_enabled" = false ]; then
        if [ -n "$detected_tls_domain" ]; then
            tls_enabled=true
        else
            classic_enabled=true
        fi
    fi
    
    echo ""
    echo -e "  ${BOLD}Ссылка для пользователя ${GREEN}${user_name}${NC}${BOLD}:${NC}"
    echo ""
    
    # TLS режим. При нескольких FakeTLS-доменах печатаем ссылку на каждый.
    if [ "$tls_enabled" = true ]; then
        local _domains_cfg="$(get_config_path)"
        if [ -n "${parts[0]}" ]; then
            _domains_cfg="${parts[0]}"
        fi
        local tls_domains=""
        tls_domains=$(get_tls_domains "$_domains_cfg")
        local domain_count=0
        if [ -n "$tls_domains" ]; then
            domain_count=$(printf '%s\n' "$tls_domains" | grep -c .)
        fi
        local _tls_out="" _tls_ok=true
        if [ "$domain_count" -gt 0 ]; then
            while IFS= read -r _d; do
                [ -n "$_d" ] || continue
                local hex_domain=""
                hex_domain=$(_domain_hex "$_d")
                if [ -z "$hex_domain" ]; then
                    _tls_ok=false
                    break
                fi
                if [ "$domain_count" -eq 1 ]; then
                    _tls_out="${_tls_out}  ${BOLD}TLS:${NC}\n"
                else
                    _tls_out="${_tls_out}  ${BOLD}TLS (${_d}):${NC}\n"
                fi
                _tls_out="${_tls_out}  ${CYAN}tg://proxy?server=${server}&port=${port}&secret=ee${user_secret}${hex_domain}${NC}\n\n"
            done <<< "$tls_domains"
        fi
        if [ "$domain_count" -eq 0 ] || [ "$_tls_ok" = false ]; then
            # Домен не задан или hex не собрался — одна ссылка без hex
            echo -e "  ${BOLD}TLS:${NC}"
            echo -e "  ${CYAN}tg://proxy?server=${server}&port=${port}&secret=ee${user_secret}${NC}"
            echo ""
        else
            echo -e "$_tls_out"
        fi
    fi
    
    # Secure режим
    if [ "$secure_enabled" = true ]; then
        local secure_secret="dd${user_secret}"
        echo -e "  ${BOLD}Secure (DD):${NC}"
        echo -e "  ${CYAN}tg://proxy?server=${server}&port=${port}&secret=${secure_secret}${NC}"
        echo ""
    fi
    
    # Classic режим
    if [ "$classic_enabled" = true ]; then
        echo -e "  ${BOLD}Classic:${NC}"
        echo -e "  ${CYAN}tg://proxy?server=${server}&port=${port}&secret=${user_secret}${NC}"
        echo ""
    fi
    
}

find_user_link() {
    echo ""
    echo -e "  ${BOLD}Поиск пользователя для генерации ссылки${NC}"
    echo -e "  ${DIM}Введите имя пользователя (или его часть)${NC}"
    echo -e "  ${DIM}Например: hello, hel, user1, test и т.д.${NC}"
    echo ""
    echo -en "  ${BOLD}Ввод:${NC} "
    { read -r search_query </dev/tty; } 2>/dev/null || { echo; return 1; }
    
    if [ -z "$search_query" ]; then
        echo ""
        echo -e "  ${YELLOW}[!]${NC} Введите имя пользователя"
        echo ""
        pause_key "Нажмите любую клавишу для возврата..."
        return 1
    fi
    
    # Получаем список пользователей
    local users
    users=$(get_users_list)
    if [ -z "$users" ]; then
        echo ""
        echo -e "  ${YELLOW}[!]${NC} В конфиге нет пользователей в секции [access.users]"
        echo ""
        pause_key "Нажмите любую клавишу для возврата..."
        return 1
    fi
    
    # Ищем совпадения (регистронезависимо)
    local matches
    matches=$(grep -i "$search_query" <<<"$users")
    if [ -z "$matches" ]; then
        echo ""
        echo -e "  ${YELLOW}[!]${NC} Пользователь с именем \"$search_query\" не найден"
        echo ""
        pause_key "Нажмите любую клавишу для возврата..."
        return 1
    fi
    
    # Проверяем сколько совпадений
    local match_count
    match_count=$(wc -l <<<"$matches")
    if [ "$match_count" -gt 1 ]; then
        echo ""
        echo -e "  ${YELLOW}[!]${NC} Найдено несколько совпадений:"
        echo ""
        echo "$matches" | while IFS=':' read -r name secret; do
            echo -e "    ${CYAN}${name}${NC}"
        done
        echo ""
        echo -e "  ${BOLD}Уточните запрос для выбора конкретного пользователя${NC}"
        echo ""
        pause_key "Нажмите любую клавишу для возврата..."
        return 1
    fi
    
    # Одно совпадение — показываем ссылку
    local user_name
    user_name=$(cut -d: -f1 <<<"$matches")
    local user_secret
    user_secret=$(cut -d: -f2 <<<"$matches")
    echo ""
    echo -e "  ${GREEN}✓${NC} Найден пользователь: ${BOLD}${user_name}${NC}"
    echo ""
    echo -en "  ${NC}${BOLD}Вывести ссылку для этого пользователя?${GREEN}${BOLD} Enter${NC}${BOLD} -${GREEN}${BOLD} да${NC}${BOLD}, ${RED}${BOLD}n${NC}${BOLD} - ${RED}${BOLD}назад${NC}${BOLD}:${NC} "
    local confirm
    { read -r confirm </dev/tty; } 2>/dev/null || confirm="n"
    
    if [[ -n "$confirm" && "$confirm" =~ ^[nN]$ ]]; then
        echo ""
        echo -e "  ${GRAY}Возврат...${NC}"
        sleep 0.5
        return 0
    fi
    
    print_user_links "$user_name" "$user_secret"
    pause_key "Нажмите любую клавишу для возврата..."
}

# ── Функция проверки, установлен ли Telemt ──────────────────
is_telemt_installed() {
    ssh_exec "command -v telemt >/dev/null 2>&1 || systemctl is-active --quiet telemt 2>/dev/null || pgrep -x telemt >/dev/null 2>&1" && return 0 || return 1
}

# ── Функция получения версии Telemt ─────────────────────────
get_telemt_version() {
    ssh_exec "telemt --version 2>/dev/null | head -1 | awk '{print \$2}'"
}

# ── Функция получения порта(ов) из конфига ──────────────────
get_telemt_ports() {
    local config_path
    config_path=$(get_config_path)
    if ! ssh_exec "[ -f \"$config_path\" ]"; then
        echo ""
        return 1
    fi
    ssh_exec "grep -E '^port[[:space:]]*=' \"$config_path\" 2>/dev/null | awk -F'=' '{print \$2}' | tr -d ' \"'"
}

# ── Функция получения онлайна Telemt ────────────────────────
get_telemt_online() {
    if is_telemt_installed; then
        local online
        online=$(ssh_exec "curl -s http://127.0.0.1:9091/v1/stats/users/active-ips 2>/dev/null | grep -o '\"active_ips\":\[[^]]*\]' | grep -o '[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}' | wc -l | tr -d ' '")
        echo "${online:-0}"
    else
        echo ""
    fi
}

# ── Функция обновления пути к конфигу ──────────────────────
update_config_path() {
    echo ""
    default_path="/etc/telemt/telemt.toml"
    echo -en "Укажите путь к конфигу Telemt (По умолчанию: [${default_path}] если не меняли - нажмите Enter, или [N/n] для возврата в меню): "
    { read -r CONFIG_TELEMT_INPUT </dev/tty; } 2>/dev/null || { echo; return 1; }

    if [[ "$CONFIG_TELEMT_INPUT" =~ ^[Nn]$ ]]; then
        echo ""
        echo -e "  ${GRAY}Возврат в меню...${NC}"
        sleep 0.1
        return 1
    fi

    if [ -z "$CONFIG_TELEMT_INPUT" ]; then
        CONFIG_TELEMT_INPUT="$default_path"
    fi

    if ! ssh_exec "[ -f \"$CONFIG_TELEMT_INPUT\" ]"; then
        echo -e "  ${YELLOW}[!]${NC} Файл $CONFIG_TELEMT_INPUT не найден."
        echo -en "  ${BOLD}Сохранить этот путь всё равно? [y/N]:${NC} "
        confirm_path=""
        { read -r confirm_path </dev/tty; } 2>/dev/null || true
        if [[ ! "$confirm_path" =~ ^[yY]$ ]]; then
            echo -e "  ${GRAY}Возврат в меню...${NC}"
            sleep 0.1
            return 1
        fi
    fi

    ssh_exec "mkdir -p /opt/mtpr-simple && echo \"$CONFIG_TELEMT_INPUT\" > \"$CONFIG_PATH_FILE\""
    echo -e "  ${GREEN}[✓]${NC} Путь сохранён: $CONFIG_TELEMT_INPUT"
    echo ""
    pause_key "Нажмите любую клавишу для возврата в меню..."
    return 0
}

# ── Функция просмотра логов ──────────────────────────────────
view_logs() {
    echo ""
    echo -e "  ${BLUE}[i]${NC} Просмотр логов Telemt (Ctrl+C для выхода)..."
    echo ""
    pause_key "Нажмите любую клавишу для продолжения..."
    ssh_interactive "journalctl -u telemt -f"
    echo ""
    pause_key "Нажмите любую клавишу для возврата в меню..."
}

# ── Функция установки Telemt ────────────────────────────────
install_telemt() {
    echo ""
    echo -e "  ${BLUE}[i]${NC} Установка Telemt"
    echo ""
    echo -e "  ${NC}${BOLD}Выберите какую версию TELEMT вы хотите установить:${NC}"
    echo -e "  ${GREEN}[Enter]${NC}${BOLD} — установить самую последнюю версию"
    echo -e "  ${NC}${BOLD}Либо введите любую версию в формате: ${GREEN}3.4.18"
    echo -e "  ${RED}[N/n]${NC}${BOLD} — назад"
    echo ""
    echo -en "  ${NC}${BOLD}Ввод:${NC} "
    { read -r version_input </dev/tty; } 2>/dev/null || { echo; return 1; }

    if [[ "$version_input" =~ ^[Nn]$ ]]; then
        echo ""
        echo -e "  ${GRAY}Установка отменена${NC}"
        echo ""
        pause_key "Нажмите любую клавишу для возврата в меню..."
        return 0
    fi

    local install_version="latest"
    local display_version="последнюю"
    
    if [ -n "$version_input" ]; then
        if [[ "$version_input" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            install_version="$version_input"
            display_version="$version_input"
        else
            echo ""
            echo -e "  ${YELLOW}[!]${NC} Некорректный формат версии. Используйте формат X.Y.Z"
            pause_key "Нажмите любую клавишу для возврата в меню..."
            return 1
        fi
    fi

    echo ""
    echo -e "  ${BLUE}[i]${NC} Установка Telemt версии ${display_version}..."
    echo ""

    # ── Флаги для upstream-установщика на ноде ────────────────
    # -l 2 обязателен: интерфейс русский; без -p/-d upstream
    # спрашивает порт/домен и может зависнуть. Порт — из конфига
    # ноды или /opt/mtpr-simple/port (fallback 443), домен — из
    # tls_domain конфига ноды.
    local _info="" _port="" _domain=""
    _info=$(detect_telemt_advanced)
    _port=$(cut -d: -f2 <<<"$_info")
    _domain=$(cut -d: -f8 <<<"$_info")
    if [ -z "$_port" ]; then
        _port=$(ssh_exec "if [ -s /opt/mtpr-simple/port ]; then head -1 /opt/mtpr-simple/port; fi" | tr -d '[:space:]')
    fi
    [ -z "$_port" ] && _port="443"

    local -a telemt_flags=(-l 2 -p "$_port")
    [ -n "$_domain" ] && telemt_flags+=(-d "$_domain")

    if [ "$install_version" = "latest" ]; then
        if ssh_interactive "$(remote_installer_cmd "https://raw.githubusercontent.com/telemt/telemt/main/install.sh" "${telemt_flags[@]}")"; then
            echo -e "  ${GREEN}[✓]${NC} Telemt успешно установлен (последняя версия)"
        else
            echo -e "  ${RED}[✗]${NC} Ошибка установки Telemt"
        fi
    else
        if ssh_interactive "$(remote_installer_cmd "https://raw.githubusercontent.com/telemt/telemt/main/install.sh" "$install_version" "${telemt_flags[@]}")"; then
            echo -e "  ${GREEN}[✓]${NC} Telemt версии ${install_version} успешно установлен"
        else
            echo -e "  ${RED}[✗]${NC} Ошибка установки Telemt версии ${install_version}"
        fi
    fi
    
    echo ""
    pause_key "Нажмите любую клавишу для возврата в меню..."
}

# ── Неинтерактивная установка Telemt на ноде (--install-silent) ─
# Ставит конкретную версию (X.Y.Z) или latest БЕЗ промптов, меню и
# ожидания клавиши. Не читает /dev/tty. Честный rc: 0 — успех,
# 1 — ошибка или неверный формат версии.
install_telemt_silent() {
    local version_input="${1:-}"
    local install_version="latest" display_version="последнюю"

    if [ -z "$version_input" ] || [ "$version_input" = "latest" ]; then
        install_version="latest"
        display_version="последнюю"
    elif [[ "$version_input" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        install_version="$version_input"
        display_version="$version_input"
    else
        log_error "Некорректный формат версии: '${version_input}'. Используйте X.Y.Z или latest"
        return 1
    fi

    log_info "Установка Telemt версии ${display_version} на ноде ${REMOTE_USER}@${REMOTE_IP}..."

    # ── Флаги для upstream-установщика на ноде ────────────────
    local _info="" _port="" _domain=""
    _info=$(detect_telemt_advanced)
    _port=$(cut -d: -f2 <<<"$_info")
    _domain=$(cut -d: -f8 <<<"$_info")
    if [ -z "$_port" ]; then
        _port=$(ssh_exec "if [ -s /opt/mtpr-simple/port ]; then head -1 /opt/mtpr-simple/port; fi" | tr -d '[:space:]')
    fi
    [ -z "$_port" ] && _port="443"

    local -a telemt_flags=(-l 2 -p "$_port")
    [ -n "$_domain" ] && telemt_flags+=(-d "$_domain")

    if [ "$install_version" = "latest" ]; then
        if ssh_exec "$(remote_installer_cmd "https://raw.githubusercontent.com/telemt/telemt/main/install.sh" "${telemt_flags[@]}")"; then
            log_success "Telemt успешно установлен (последняя версия)"
            return 0
        fi
        log_error "Ошибка установки Telemt"
        return 1
    fi
    if ssh_exec "$(remote_installer_cmd "https://raw.githubusercontent.com/telemt/telemt/main/install.sh" "$install_version" "${telemt_flags[@]}")"; then
        log_success "Telemt версии ${install_version} установлен"
        return 0
    fi
    log_error "Ошибка установки Telemt версии ${install_version}"
    return 1
}

# ── Функция установки Telemt в Docker ───────────────────────
install_telemt_docker() {
    echo ""
    echo -e "  ${RED}[✗]${NC} Установка Telemt в Docker на удалённой ноде пока не поддерживается"
    pause_key "Нажмите любую клавишу для возврата в меню..."
}

# ── Функция удаления Telemt (стандартный) ────────────────────
purge_telemt() {
    echo ""
    echo -e "  ${RED}${BOLD}ВНИМАНИЕ:${NC} Будет выполнено полное удаление стандартного Telemt!"
    echo ""
    echo -e "  ${BOLD}Будут удалены:${NC}"
    echo -e "  • Все файлы Telemt"
    echo -e "  • Конфигурационные файлы"
    echo -e "  • Systemd служба"
    echo ""
    echo -e "  ${YELLOW}[!]${NC} Это действие нельзя отменить!"
    echo -en "  ${BOLD}Продолжить удаление? [y/N]:${NC} "
    local confirm
    { read -r confirm </dev/tty; } 2>/dev/null || true

    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        echo -e "  ${GRAY}Удаление отменено${NC}"
        echo ""
        pause_key "Нажмите любую клавишу для возврата в меню..."
        return 1
    fi

    echo ""
    echo -e "  ${BLUE}[i]${NC} Удаление Telemt..."
    echo ""
    if ssh_interactive "$(remote_installer_cmd "https://raw.githubusercontent.com/telemt/telemt/main/install.sh" purge -l 2)"; then
        echo -e "  ${GREEN}[✓]${NC} Telemt успешно удалён"
    else
        echo -e "  ${RED}[✗]${NC} Ошибка удаления Telemt"
    fi
    echo ""
    pause_key "Нажмите любую клавишу для возврата в меню..."
}

# ── Функция удаления Telemt из Docker ────────────────────────
purge_telemt_docker() {
    echo ""
    echo -e "  ${RED}${BOLD}ВНИМАНИЕ:${NC} Будет выполнено полное удаление Telemt из Docker!"
    echo ""
    echo -e "  ${BOLD}Будут удалены:${NC}"
    echo -e "  • Контейнеры Telemt и Watchtower"
    echo -e "  • Папка проекта (по умолчанию: /root/telemt)"
    echo -e "  • Образы Telemt и Watchtower"
    echo -e "  • Все неиспользуемые образы, контейнеры и сети"
    echo ""
    echo -e "  ${YELLOW}[!]${NC} Это действие нельзя отменить!"
    
    # Определяем путь к папке telemt
    local TELEMT_PATH="/root/telemt"
    if ssh_exec "[ -d \"$TELEMT_PATH\" ]"; then
        echo -e "  ${DIM}Обнаружена папка: ${TELEMT_PATH}${NC}"
    else
        echo -e "  ${YELLOW}[!]${NC} Папка $TELEMT_PATH не найдена"
        echo -en "  ${BOLD}Удалять всё равно? [y/N]:${NC} "
        { read -r force_remove </dev/tty; } 2>/dev/null || true
        if [[ ! "$force_remove" =~ ^[yY]$ ]]; then
            echo -e "  ${GRAY}Удаление отменено${NC}"
            echo ""
            pause_key "Нажмите любую клавишу для возврата в меню..."
            return 1
        fi
    fi
    
    echo ""
    echo -en "  ${BOLD}Продолжить удаление? [y/N]:${NC} "
    local confirm
    { read -r confirm </dev/tty; } 2>/dev/null || true

    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        echo -e "  ${GRAY}Удаление отменено${NC}"
        echo ""
        pause_key "Нажмите любую клавишу для возврата в меню..."
        return 1
    fi

    echo ""
    echo -e "  ${BLUE}[i]${NC} Удаление Telemt из Docker..."
    echo ""
    
    # 1. Останавливаем и удаляем контейнеры
    if ssh_exec "[ -f \"$TELEMT_PATH/docker-compose.yml\" ]"; then
        echo -e "  ${BLUE}[i]${NC} Остановка и удаление контейнеров..."
        ssh_interactive "cd \"$TELEMT_PATH\" && docker compose down -v 2>/dev/null || true"
    else
        echo -e "  ${YELLOW}[!]${NC} docker-compose.yml не найден, пропускаем остановку контейнеров"
    fi
    
    # 2. Удаляем папку с проектом
    echo -e "  ${BLUE}[i]${NC} Удаление папки $TELEMT_PATH..."
    ssh_exec "cd /root && rm -rf \"$TELEMT_PATH\""
    echo -e "  ${GREEN}[✓]${NC} Папка удалена"
    
    # 3. Удаляем образы
    echo -e "  ${BLUE}[i]${NC} Удаление образов..."
    ssh_exec "docker rmi ghcr.io/telemt/telemt:* 2>/dev/null || true"
    ssh_exec "docker rm -f watchtower 2>/dev/null || true"
    ssh_exec "docker rmi containrrr/watchtower 2>/dev/null || true"
    
    # 4. Чистим неиспользуемые образы, контейнеры, сети
    echo -e "  ${BLUE}[i]${NC} Очистка неиспользуемых ресурсов Docker..."
    echo -e "  ${DIM}Будут удалены все неиспользуемые образы, контейнеры и сети${NC}"
    echo -en "  ${BOLD}Выполнить очистку? [y/N]:${NC} "
    { read -r prune_confirm </dev/tty; } 2>/dev/null || prune_confirm="n"
    if [[ "$prune_confirm" =~ ^[yY]$ ]]; then
        ssh_interactive "docker system prune -af"
        echo -e "  ${GREEN}[✓]${NC} Очистка выполнена"
    else
        echo -e "  ${GRAY}Очистка пропущена${NC}"
    fi
    
    # 5. Проверяем что ничего не осталось
    echo ""
    echo -e "  ${BLUE}[i]${NC} Проверка остатков..."
    echo -e "  ${BOLD}Контейнеры:${NC}"
    ssh_exec "docker ps -a | grep telemt || echo 'Контейнеров Telemt не найдено'"
    echo ""
    echo -e "  ${BOLD}Образы:${NC}"
    ssh_exec "docker images | grep telemt || echo 'Образов Telemt не найдено'"
    
    echo ""
    echo -e "  ${GREEN}[✓]${NC} Telemt из Docker успешно удалён!"
    echo ""
    pause_key "Нажмите любую клавишу для возврата в меню..."
}

# ── Функция выбора удаления ──────────────────────────────────
purge_telemt_menu() {
    echo ""
    echo -e "  ${BOLD}УДАЛЕНИЕ TELEMT${NC}"
    echo -e "  ${DIM}===========================${NC}"
    echo ""
    echo -e "  ${CYAN}[1]${NC}  ${BOLD}Удалить стандартный Telemt${NC}"
    echo -e "  ${CYAN}[2]${NC}  ${BOLD}Удалить Telemt из Docker${NC}"
    echo -e "  ${CYAN}[0]${NC}  ${BOLD}Назад${NC}"
    echo ""
    echo -en "  ${BOLD}Выбор:${NC} "
    { read -r purge_choice </dev/tty; } 2>/dev/null || { echo; return 1; }
    
    case "$purge_choice" in
        1)
            purge_telemt
            ;;
        2)
            purge_telemt_docker
            ;;
        0)
            return 0
            ;;
        *)
            echo "  Неверный выбор"
            sleep 0.5
            ;;
    esac
}

# ── Функция открытия конфига ────────────────────────────────
edit_config() {
    config_path=$(get_config_path)
    
    if ! ssh_exec "[ -f \"$config_path\" ]"; then
        echo ""
        echo -e "  ${YELLOW}[!]${NC} Файл конфига не найден по пути: $config_path"
        echo -e "  ${GRAY}Используйте пункт 4 для обновления пути к конфигу${NC}"
        echo ""
        pause_key "Нажмите любую клавишу для возврата в меню..."
        return 1
    fi
    
    echo ""
    echo -e "  ${BLUE}[i]${NC} Открытие конфига: $config_path на удалённом сервере"
    ssh_interactive "nano \"$config_path\""
    
    echo ""
    echo -e "  ${GREEN}[✓]${NC} Редактирование завершено"
    pause_key "Нажмите любую клавишу для возврата в меню..."
}

# ── Функция перезапуска Telemt ──────────────────────────────
restart_telemt() {
    echo ""
    echo -e "  ${BLUE}[i]${NC} Перезапуск Telemt..."
    echo ""
    if ssh_exec "systemctl restart telemt 2>/dev/null"; then
        echo -e "  ${GREEN}[✓]${NC} Telemt успешно перезапущен"
    else
        echo -e "  ${YELLOW}[!]${NC} Не удалось перезапустить Telemt (возможно, он не установлен как служба)"
        echo -e "  ${GRAY}Попробуйте сначала установить Telemt (пункт 1)${NC}"
    fi
    echo ""
    pause_key "Нажмите любую клавишу для возврата в меню..."
}

# ── ФУНКЦИИ УПРАВЛЕНИЯ MSS (скопированы из main.sh) ────────

is_mss_enabled_for_config() {
    local _cfg="$1"
    _cfg=$(trim "$_cfg")
    if [ -z "$_cfg" ] || ! ssh_exec "[ -f \"$_cfg\" ]"; then
        return 1
    fi
    ssh_exec "grep -E '^[[:space:]]*client_mss[[:space:]]*=' \"$_cfg\" | grep -v '^#' | grep -q ." && return 0 || return 1
}

is_mss_bulk_enabled_for_config() {
    local _cfg="$1"
    _cfg=$(trim "$_cfg")
    if [ -z "$_cfg" ] || ! ssh_exec "[ -f \"$_cfg\" ]"; then
        return 1
    fi
    ssh_exec "grep -E '^[[:space:]]*mss_bulk[[:space:]]*=' \"$_cfg\" | grep -v '^#' | grep -q ." && return 0 || return 1
}

is_synlimit_enabled_for_config() {
    local _cfg="$1"
    _cfg=$(trim "$_cfg")
    if [ -z "$_cfg" ] || ! ssh_exec "[ -f \"$_cfg\" ]"; then
        return 1
    fi
    ssh_exec "grep -E '^[[:space:]]*synlimit[[:space:]]*=' \"$_cfg\" | grep -v '^#' | grep -q ." && return 0 || return 1
}

are_bad_options_enabled_for_config() {
    local _cfg="$1"
    if is_mss_enabled_for_config "$_cfg" || is_mss_bulk_enabled_for_config "$_cfg" || is_synlimit_enabled_for_config "$_cfg"; then
        return 0
    else
        return 1
    fi
}

# ── ВКЛЮЧЕНИЕ MSS И MSS_BULK ───────────────────────────────
enable_mss_options() {
    local config_path
    config_path=$(get_config_path)
    if [ -z "$config_path" ] || ! ssh_exec "[ -f \"$config_path\" ]"; then
        echo ""
        echo -e "  ${RED}[✗]${NC} Файл конфига не найден или не указан"
        echo ""
        pause_key "Нажмите любую клавишу для возврата в меню..."
        return 1
    fi

    local changed=0
    local mss_value="92"
    local mss_bulk_value="1200"

    # Проверяем наличие строк (даже закомментированных)
    local has_mss
    has_mss=$(ssh_exec "grep -E '^[[:space:]]*#?[[:space:]]*client_mss[[:space:]]*=' \"$config_path\" | head -1")
    local has_mss_bulk
    has_mss_bulk=$(ssh_exec "grep -E '^[[:space:]]*#?[[:space:]]*mss_bulk[[:space:]]*=' \"$config_path\" | head -1")
    if [ -n "$has_mss" ]; then
        ssh_exec "sed -i 's/^[[:space:]]*#[[:space:]]*client_mss[[:space:]]*=.*/client_mss = $mss_value/' \"$config_path\""
        changed=1
    else
        # Добавляем в секцию server
        if ssh_exec "grep -q '^\[server\]' \"$config_path\""; then
            ssh_exec "sed -i '/^\[server\]/a client_mss = $mss_value' \"$config_path\""
            changed=1
        else
            ssh_exec "echo '' >> \"$config_path\" && echo '[server]' >> \"$config_path\" && echo 'client_mss = $mss_value' >> \"$config_path\""
            changed=1
        fi
    fi

    if [ -n "$has_mss_bulk" ]; then
        ssh_exec "sed -i 's/^[[:space:]]*#[[:space:]]*mss_bulk[[:space:]]*=.*/mss_bulk = $mss_bulk_value/' \"$config_path\""
        changed=1
    else
        if ssh_exec "grep -q '^\[server\]' \"$config_path\""; then
            ssh_exec "sed -i '/^\[server\]/a mss_bulk = $mss_bulk_value' \"$config_path\""
            changed=1
        else
            if ! ssh_exec "grep -q '^\[server\]' \"$config_path\""; then
                ssh_exec "echo '' >> \"$config_path\" && echo '[server]' >> \"$config_path\""
            fi
            ssh_exec "echo 'mss_bulk = $mss_bulk_value' >> \"$config_path\""
            changed=1
        fi
    fi

    if [ "$changed" -eq 1 ]; then
        echo ""
        echo -e "  ${GREEN}[✓]${NC} MSS (client_mss = $mss_value) и mss_bulk = $mss_bulk_value добавлены в конфиг"
        
        # Спрашиваем о перезапуске
        echo ""
        echo -en "  ${BOLD}${NC}Перезапустить telemt для применения изменений?${NC} ${GREEN}${BOLD}[Enter/Y - да, N - нет]:${NC} "
        local restart_confirm
        { read -r restart_confirm </dev/tty; } 2>/dev/null || restart_confirm="n"
        
        if [[ -z "$restart_confirm" || "$restart_confirm" =~ ^[yY]$ ]]; then
            if ssh_exec "systemctl restart telemt 2>/dev/null"; then
                echo -e "  ${GREEN}[✓]${NC} Telemt успешно перезапущен"
            else
                echo -e "  ${YELLOW}[!]${NC} Не удалось перезапустить telemt (возможно, он не установлен как служба)"
            fi
        else
            echo -e "  ${BLUE}[i]${NC} Перезапуск отменён. Изменения применятся после перезапуска telemt"
        fi
    else
        echo -e "  ${BLUE}[i]${NC} Не удалось добавить параметры client_mss и mss_bulk"
    fi
    echo ""
    pause_key "Нажмите любую клавишу для возврата в меню..."
}

# ── ОТКЛЮЧЕНИЕ MSS, MSS_BULK И SYN_LIMIT ───────────────────
disable_bad_options() {
    local config_path
    config_path=$(get_config_path)
    if [ -z "$config_path" ] || ! ssh_exec "[ -f \"$config_path\" ]"; then
        echo ""
        echo -e "  ${RED}[✗]${NC} Файл конфига не найден или не указан"
        echo ""
        pause_key "Нажмите любую клавишу для возврата в меню..."
        return 1
    fi

    local changed=0

    if ssh_exec "grep -E '^[[:space:]]*client_mss[[:space:]]*=' \"$config_path\" | grep -v '^#' | grep -q ."; then
        ssh_exec "sed -i 's/^[[:space:]]*client_mss[[:space:]]*=.*/#client_mss = 0/' \"$config_path\""
        changed=1
    fi

    if ssh_exec "grep -E '^[[:space:]]*mss_bulk[[:space:]]*=' \"$config_path\" | grep -v '^#' | grep -q ."; then
        ssh_exec "sed -i 's/^[[:space:]]*mss_bulk[[:space:]]*=.*/#mss_bulk = 0/' \"$config_path\""
        changed=1
    fi

    if ssh_exec "grep -E '^[[:space:]]*synlimit[[:space:]]*=' \"$config_path\" | grep -v '^#' | grep -q ."; then
        ssh_exec "sed -i 's/^[[:space:]]*synlimit[[:space:]]*=.*/#synlimit = 0/' \"$config_path\""
        changed=1
    fi

    if [ "$changed" -eq 1 ]; then
        echo ""
        echo -e "  ${GREEN}[✓]${NC} MSS, mss_bulk и synlimit отключены (строки закомментированы)"
    else
        echo ""
        echo -e "  ${BLUE}[i]${NC} Активные строки client_mss, mss_bulk или synlimit не найдены"
    fi
    echo ""
    pause_key "Нажмите любую клавишу для возврата в меню..."
}

# ── УПРАВЛЕНИЕ MSS В КОНФИГЕ ──────────────────────────────
manage_mss() {
    local config_path
    config_path=$(get_config_path)
    if [ -z "$config_path" ] || ! ssh_exec "[ -f \"$config_path\" ]"; then
        echo ""
        echo -e "  ${RED}[✗]${NC} Файл конфига не найден или не указан"
        echo ""
        pause_key "Нажмите любую клавишу для возврата в меню..."
        return 1
    fi

    if are_bad_options_enabled_for_config "$config_path"; then
        echo ""
        echo -e "  ${BLUE}[i]${NC} Обнаружены активные строки с client_mss, mss_bulk или synlimit в $config_path"
        echo -en "  ${BOLD}${NC}Отключить mss, mss_bulk и synlimit в cfg telemt? [Y/n]:${NC} "
        local confirm
        { read -r confirm </dev/tty; } 2>/dev/null || confirm="n"
        if [[ -z "$confirm" || "$confirm" =~ ^[yY]$ ]]; then
            disable_bad_options
        else
            echo -e "  ${BLUE}[i]${NC} Отмена"
            echo ""
            pause_key "Нажмите любую клавишу для возврата в меню..."
        fi
    else
        echo ""
        echo -e "  ${BLUE}[i]${NC} client_mss, mss_bulk и synlimit уже отключены или отсутствуют в конфиге"
        echo -en "  ${BOLD}Включить mss и mss_bulk в конфиге telemt? [Y/n]:${NC} "
        local confirm
        { read -r confirm </dev/tty; } 2>/dev/null || confirm="n"
        if [[ -z "$confirm" || "$confirm" =~ ^[yY]$ ]]; then
            enable_mss_options
        else
            echo -e "  ${BLUE}[i]${NC} Отмена"
            echo ""
            pause_key "Нажмите любую клавишу для возврата в меню..."
        fi
    fi
}

# ── Генерация секрета (как в install.sh) ───────────────────
_gen_secret() {
    local sec=""
    if command -v openssl >/dev/null 2>&1; then
        sec=$(openssl rand -hex 16 2>/dev/null)
    fi
    if [ -z "$sec" ] && command -v od >/dev/null 2>&1; then
        sec=$(head -c 16 /dev/urandom 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n')
    fi
    if [ -z "$sec" ] && command -v sha256sum >/dev/null 2>&1; then
        sec=$( { date +%s%N 2>/dev/null; printf '%s' "$RANDOM$RANDOM$RANDOM"; } | sha256sum 2>/dev/null | cut -c1-32 )
    fi
    printf '%s' "$sec"
}

# ── Разбор строки пользователей ─────────────────────────────
# Принимает: "u1", "u1 u2 u3", "u1,u2,u3", "u1 u2, u3",
#            "u1:secret", "u2=secret", "u3 secret" (secret — 32 hex).
# Печатает: OK<TAB>имя<TAB>секрет  |  ERR<TAB>сообщение
_parse_user_specs() {
    local raw="$1"
    raw="${raw//$'\t'/ }"
    raw="${raw//,/ }"
    local -a _toks=()
    # shellcheck disable=SC2206
    _toks=($raw)
    if [ "${#_toks[@]}" -eq 0 ]; then
        printf 'ERR\tПустая строка\n'
        return 0
    fi
    local _tok="" _pending=""
    for _tok in "${_toks[@]}"; do
        # имя:секрет или имя=секрет
        if [[ "$_tok" == *:* || "$_tok" == *=* ]]; then
            local _nm="${_tok%%[=:]*}"
            local _sc="${_tok#*[=:]}"
            if [ -n "$_pending" ]; then
                printf 'OK\t%s\t%s\n' "$_pending" "$(_gen_secret)"
                _pending=""
            fi
            printf 'OK\t%s\t%s\n' "$_nm" "$_sc"
            continue
        fi
        # отдельный 32-hex токен — секрет для предыдущего имени
        if [[ "$_tok" =~ ^[0-9a-fA-F]{32}$ ]]; then
            if [ -n "$_pending" ]; then
                printf 'OK\t%s\t%s\n' "$_pending" "$_tok"
                _pending=""
            else
                printf 'ERR\tСекрет без имени: %s\n' "$_tok"
            fi
            continue
        fi
        # новый кандидат в имена
        if [ -n "$_pending" ]; then
            printf 'OK\t%s\t%s\n' "$_pending" "$(_gen_secret)"
        fi
        _pending="$_tok"
    done
    if [ -n "$_pending" ]; then
        printf 'OK\t%s\t%s\n' "$_pending" "$(_gen_secret)"
    fi
}

# ── Добавление пользователей в конфиг на ноде ───────────────
add_users_to_config() {
    local raw="$1"
    local cfg=""
    cfg=$(get_config_path)
    if [ -z "$cfg" ] || ! ssh_exec "[ -f \"$cfg\" ]"; then
        log_error "Конфиг telemt на ноде не найден"
        return 1
    fi
    if ssh_exec "grep -qE '^[[:space:]]*\[\[access\.users\]\]' \"$cfg\""; then
        log_error "Нестандартный формат [[access.users]] — правьте конфиг вручную на ноде"
        return 1
    fi

    local -a names=() secrets=()
    local seen=" " _line _rest _name _secret
    while IFS= read -r _line; do
        case "$_line" in
            ERR*) printf '  %s[x]%s %s\n' "$RED" "$NC" "${_line#ERR$'\t'}"; continue ;;
            OK*) : ;;
            *) continue ;;
        esac
        _rest="${_line#OK$'\t'}"
        _name="${_rest%%$'\t'*}"
        _secret="${_rest#*$'\t'}"
        if ! [[ "$_name" =~ ^[A-Za-z0-9_.-]{1,32}$ ]]; then
            printf '  %s[x]%s Недопустимое имя: %s\n' "$RED" "$NC" "$_name"; continue
        fi
        if [ -z "$_secret" ]; then
            printf '  %s[x]%s Пустой секрет для %s\n' "$RED" "$NC" "$_name"; continue
        fi
        if ! [[ "$_secret" =~ ^[0-9a-fA-F]{32}$ || "$_secret" =~ ^[0-9a-fA-F]{64}$ ]]; then
            printf '  %s[x]%s Недопустимый секрет для %s: нужен 32- или 64-символьный hex\n' "$RED" "$NC" "$_name"; continue
        fi
        case "$seen" in *" $_name "*) printf '  %s[!]%s %s повторяется — пропуск\n' "$YELLOW" "$NC" "$_name"; continue ;; esac
        seen="${seen}${_name} "
        names+=("$_name"); secrets+=("$_secret")
    done < <(_parse_user_specs "$raw")

    if [ "${#names[@]}" -eq 0 ]; then
        log_warning "Нет корректных пользователей для добавления"
        return 1
    fi

    local -a add_names=() add_secrets=()
    local _i
    for _i in "${!names[@]}"; do
        if ssh_exec "grep -qE '^[[:space:]]*${names[$_i]}[[:space:]]*=' \"$cfg\""; then
            log_warning "Пользователь '${names[$_i]}' уже есть — секрет не изменён"
            continue
        fi
        add_names+=("${names[$_i]}")
        add_secrets+=("${secrets[$_i]}")
    done

    if [ "${#add_names[@]}" -eq 0 ]; then
        log_success "Все указанные пользователи уже присутствуют"
        return 0
    fi

    local backup="${cfg}.bak.$(date +%Y%m%d-%H%M%S)"
    if ! ssh_exec "cp -a \"$cfg\" \"$backup\""; then
        log_error "Не удалось создать бэкап конфига на ноде"
        return 1
    fi
    log_info "Бэкап конфига на ноде: ${backup}"

    local payload=""
    for _i in "${!add_names[@]}"; do
        payload="${payload}${add_names[$_i]} = \"${add_secrets[$_i]}\""$'\n'
    done
    local ub64=""
    ub64=$(printf '%s' "$payload" | base64 -w0 2>/dev/null)
    [ -n "$ub64" ] || ub64=$(printf '%s' "$payload" | base64 | tr -d '\n')

    local rscript=""
    rscript=$(cat <<RSH
cfg="$cfg"
ub64="$ub64"
tmp=\$(mktemp) || exit 9
printf '%s' "\$ub64" | base64 -d > "\$tmp" 2>/dev/null || printf '%s' "\$ub64" | base64 --decode > "\$tmp" 2>/dev/null || { rm -f "\$tmp"; exit 9; }
if grep -qE '^[[:space:]]*\[access\.users\][[:space:]]*\$' "\$cfg"; then
    awk -v blk="\$(cat "\$tmp")" '{print} /^[[:space:]]*\[access\.users\][[:space:]]*\$/{printf "%s\n", blk}' "\$cfg" > "\$cfg.tmp.\$\$" || { rm -f "\$tmp"; exit 8; }
    cat "\$cfg.tmp.\$\$" > "\$cfg" && rm -f "\$cfg.tmp.\$\$"
else
    { printf '\n[access.users]\n'; cat "\$tmp"; } >> "\$cfg"
fi
rm -f "\$tmp"
if command -v telemt >/dev/null 2>&1 && telemt --help 2>&1 | grep -qE '(^|[[:space:]])verify([[:space:]]|\$)'; then
    telemt --config "\$cfg" verify >/dev/null 2>&1 || exit 1
elif command -v python3 >/dev/null 2>&1 && python3 -c 'import tomllib' >/dev/null 2>&1; then
    python3 -c 'import tomllib,sys; tomllib.load(open(sys.argv[1],"rb"))' "\$cfg" >/dev/null 2>&1 || exit 1
else
    exit 2
fi
exit 0
RSH
)
    local s64=""
    s64=$(printf '%s' "$rscript" | base64 -w0 2>/dev/null)
    [ -n "$s64" ] || s64=$(printf '%s' "$rscript" | base64 | tr -d '\n')

    local vrc=1
    # base64 передаётся на ноду через stdin, а не аргументом ssh —
    # иначе содержимое (в т.ч. секреты) видно в `ps` на ноде.
    ssh_exec 'rt=$(mktemp) || exit 9; if base64 -d > "$rt" 2>/dev/null || base64 --decode > "$rt" 2>/dev/null; then bash "$rt"; rc=$?; else rc=9; fi; rm -f "$rt"; exit $rc' <<< "$s64"
    vrc=$?
    if [ "$vrc" -eq 1 ]; then
        log_error "Проверка TOML не пройдена — восстанавливаю бэкап на ноде"
        ssh_exec "cp -a \"$backup\" \"$cfg\""
        return 1
    elif [ "$vrc" -ne 0 ] && [ "$vrc" -ne 2 ]; then
        log_error "Не удалось обновить конфиг на ноде (код $vrc)"
        ssh_exec "cp -a \"$backup\" \"$cfg\""
        return 1
    fi
    if [ "$vrc" -eq 2 ]; then
        log_warning "Проверка TOML недоступна — пропущена"
    fi

    log_success "Добавлено пользователей: ${#add_names[@]}"
    if ssh_exec "systemctl restart telemt >/dev/null 2>&1 && systemctl is-active --quiet telemt 2>/dev/null"; then
        log_success "Telemt на ноде перезапущен и активен"
    else
        log_warning "Не удалось подтвердить активность telemt на ноде"
    fi

    for _i in "${!add_names[@]}"; do
        print_user_links "${add_names[$_i]}" "${add_secrets[$_i]}"
    done
    return 0
}

add_users_menu() {
    clear 2>/dev/null || true
    echo ""
    echo -e "  ${BOLD}Добавление пользователей Telemt (удалённо)${NC}"
    echo -e "  ${DIM}Введите имена (можно несколько через пробел или запятую).${NC}"
    echo -e "  ${DIM}Можно указать секрет: имя:секрет, имя=секрет или имя секрет (32 hex).${NC}"
    echo -e "  ${DIM}Пустая строка или q — выход.${NC}"
    echo ""
    while true; do
        echo -en "  ${BOLD}Пользователи:${NC} "
        local raw=""
        { read -r raw </dev/tty; } 2>/dev/null || break
        case "$raw" in
            ""|q|Q) break ;;
        esac
        add_users_to_config "$raw" || true
        echo ""
    done
    pause_key "Нажмите любую клавишу для возврата..."
    return 0
}

# ── WEB на ноде: тот же формат ссылки и статуса, что в telemt1.sh ──
WEB_PATH_MIN_VERSION="3.5.8"

_ver_ge() {
    local have="$1" need="$2" i x y
    [ -n "$have" ] || return 1
    local a b
    IFS='.' read -r -a a <<< "$have"
    IFS='.' read -r -a b <<< "$need"
    for i in 0 1 2; do
        x="${a[$i]:-0}"; y="${b[$i]:-0}"
        x="$(printf '%s' "$x" | tr -cd '0-9')"; x="${x:-0}"
        y="$(printf '%s' "$y" | tr -cd '0-9')"; y="${y:-0}"
        if [ "$x" -gt "$y" ] 2>/dev/null; then return 0; fi
        if [ "$x" -lt "$y" ] 2>/dev/null; then return 1; fi
    done
    return 0
}

_web_make_link() {
    local host="$1" path="$2" secret_hex="$3" dd="${4:-0}" b64="" esc="" hex="70"
    if [ -z "$path" ]; then
        if [ "$dd" = "1" ]; then
            printf 'tg://webproxy?server=%s&secret=dd%s' "$host" "$secret_hex"
        else
            printf 'tg://webproxy?server=%s&secret=%s' "$host" "$secret_hex"
        fi
        return 0
    fi
    [ "$dd" = "1" ] && hex="70dd"
    esc=$(printf '%s' "${hex}${secret_hex}" | sed 's/\(..\)/\\x\1/g')
    b64=$(printf '%b' "$esc" | base64 -w0 2>/dev/null)
    [ -n "$b64" ] || b64=$(printf '%b' "$esc" | base64 2>/dev/null | tr -d '\n')
    b64=$(printf '%s' "$b64" | tr '+/' '-_' | tr -d '=')
    printf 'tg://webproxy?server=%s%%2F%s%%2F&secret=%s' "$host" "${path//\//%2F}" "$b64"
}

_web_parse_cfg() {
    local f="$1"
    local host path user mode secret sideband
    host=$(awk '
        /^[[:space:]]*\[\[web\.vhosts\]\][[:space:]]*$/ { inv=1; next }
        inv && /^[[:space:]]*\[/ { exit }
        inv && /^[[:space:]]*host[[:space:]]*=/ { sub(/#.*/,""); sub(/^[^=]*=/,""); gsub(/[[:space:]"]/,""); print; exit }
    ' "$f" 2>/dev/null)
    path=$(awk '
        /^[[:space:]]*\[\[web\.vhosts\]\][[:space:]]*$/ { inv=1; next }
        inv && /^[[:space:]]*\[/ { exit }
        inv && /^[[:space:]]*base_path[[:space:]]*=/ { sub(/#.*/,""); sub(/^[^=]*=/,""); gsub(/[[:space:]"]/,""); print; exit }
    ' "$f" 2>/dev/null)
    user=$(awk '
        /^[[:space:]]*\[\[web\.vhosts\.profiles\]\][[:space:]]*$/ { inp=1; next }
        inp && /^[[:space:]]*\[/ { exit }
        inp && /^[[:space:]]*user[[:space:]]*=/ { sub(/#.*/,""); sub(/^[^=]*=/,""); gsub(/[[:space:]"]/,""); print; exit }
    ' "$f" 2>/dev/null)
    mode=$(awk '
        /^[[:space:]]*\[\[web\.vhosts\.profiles\]\][[:space:]]*$/ { inp=1; next }
        inp && /^[[:space:]]*\[/ { exit }
        inp && /^[[:space:]]*secret_mode[[:space:]]*=/ { sub(/#.*/,""); sub(/^[^=]*=/,""); gsub(/[[:space:]"]/,""); print; exit }
    ' "$f" 2>/dev/null)
    sideband=$(awk '
        /^[[:space:]]*\[web\.debug\][[:space:]]*$/ { ind=1; next }
        ind && /^[[:space:]]*\[/ { exit }
        ind && /^[[:space:]]*sideband[[:space:]]*=/ { sub(/#.*/,""); sub(/^[^=]*=/,""); gsub(/[[:space:]"]/,""); print; exit }
    ' "$f" 2>/dev/null)
    secret=""
    if [ -n "$user" ]; then
        secret=$(awk -v u="$user" '
            /^[[:space:]]*\[access\.users\]/ { inu=1; next }
            inu && /^[[:space:]]*\[/ { exit }
            inu {
                line=$0; sub(/#.*/,"",line)
                n=index(line,"="); if (n>0) {
                    nm=substr(line,1,n-1); gsub(/[[:space:]]/,"",nm)
                    if (nm==u) { v=substr(line,n+1); gsub(/[[:space:]"]/,"",v); print v; exit }
                }
            }
        ' "$f" 2>/dev/null)
    fi
    printf '%s|%s|%s|%s|%s|%s\n' "$host" "$path" "$user" "$mode" "$secret" "$sideband"
}

_web_print_status() {
    local cfg="$1" host path user mode secret sideband ver
    IFS='|' read -r host path user mode secret sideband < <(_web_parse_cfg "$cfg")
    ver=$(get_telemt_version 2>/dev/null)
    if [ -n "$path" ]; then
        if _ver_ge "$ver" "$WEB_PATH_MIN_VERSION"; then
            echo -e "  ${BOLD}Путь WEB:${NC} ${CYAN}/${path}${NC} ${GREEN}(действует)${NC}"
        else
            echo -e "  ${BOLD}Путь WEB:${NC} ${CYAN}/${path}${NC} ${YELLOW}(не действует — нужен telemt ${WEB_PATH_MIN_VERSION}+, установлен ${ver:-?})${NC}"
        fi
    else
        echo -e "  ${BOLD}Путь WEB:${NC} ${DIM}корень домена${NC}"
    fi
    if [ "$sideband" = "true" ]; then
        echo -e "  ${BOLD}Отчёты bridge:${NC} ${GREEN}включены${NC}"
    else
        echo -e "  ${BOLD}Отчёты bridge:${NC} ${DIM}выключены${NC}"
    fi
}

web_proxy_menu() {
    local cfg=""
    cfg=$(get_config_path)
    if [ -n "$cfg" ]; then
        local tmp=""
        tmp=$(mktemp 2>/dev/null) || tmp=""
        if [ -n "$tmp" ]; then
            ssh_exec "cat \"$cfg\"" > "$tmp" 2>/dev/null || true
            if [ -s "$tmp" ] && grep -qE '^[[:space:]]*\[\[web\.vhosts\]\][[:space:]]*$' "$tmp"; then
                local host path user mode secret sideband dbg
                IFS='|' read -r host path user mode secret sideband < <(_web_parse_cfg "$tmp")
                clear 2>/dev/null || true
                echo ""
                echo -e "  ${BOLD}WEB-прокси на ноде ${REMOTE_USER}@${REMOTE_IP}${NC}"
                echo -e "  ${DIM}===========================${NC}"
                _web_print_status "$tmp"
                if [ -n "$user" ] && [ -n "$secret" ]; then
                    local dd=0
                    [ "$mode" = "dd" ] && dd=1
                    if [ -n "$path" ]; then
                        local nver=""
                        nver=$(get_telemt_version 2>/dev/null)
                        if ! _ver_ge "$nver" "$WEB_PATH_MIN_VERSION"; then
                            path=""
                            echo ""
                            echo -e "  ${YELLOW}Движок ${nver:-неизвестной версии} не поддерживает путь внутри домена — ссылка без пути (нужен telemt ${WEB_PATH_MIN_VERSION}+).${NC}"
                        fi
                    fi
                    echo ""
                    echo -e "  ${BOLD}WEB-ссылка:${NC}"
                    echo -e "  ${CYAN}$(_web_make_link "$host" "$path" "$secret" "$dd")${NC}"
                fi
                echo ""
                echo -e "  ${YELLOW}[!]${NC} Управление WEB (установка/путь/отчёты) выполняется на самой ноде."
                pause_key "Нажмите любую клавишу для возврата..."
                rm -f "$tmp"
                return 0
            fi
            rm -f "$tmp"
        fi
    fi
    clear 2>/dev/null || true
    echo ""
    echo -e "  ${BOLD}WEB-прокси Telemt (удалённо)${NC}"
    echo ""
    echo -e "  ${YELLOW}[!]${NC} Автоматическая установка WEB-прокси на ноде не поддерживается."
    echo -e "  ${DIM}WEB-режим требует домен с A-записью на ноду, полную замену${NC}"
    echo -e "  ${DIM}конфига telemt и nginx + сертификат Let's Encrypt.${NC}"
    echo -e "  ${DIM}Выполните установку на самой ноде или через CLI.${NC}"
    echo ""
    pause_key "Нажмите любую клавишу для возврата..."
    return 1
}

# ── Бэкап и восстановление Telemt на ноде ─────────────────────
# Панель бэкапа запускается НА САМОЙ НОДЕ через ssh -t, чтобы
# бэкапился Telemt-конфиг ноды, а не управляющей машины.
# Догрузка панели на ноду (зеркало _ensure_backup_panel из
# proxys/telemt1.sh): сначала пробуем скачать НА САМОЙ ноде, если
# curl нет/не сработал — качаем на управляющем хосте и заливаем
# на ноду base64-полезной нагрузкой через ssh_exec.
_node_has_panel() {
    ssh_exec "[ -s /opt/mtpr-simple/data/backup_panel.sh ]"
}

_ensure_backup_panel_node() {
    local dest="/opt/mtpr-simple/data/backup_panel.sh"
    local base="${EXTRA_BASE_URL:-https://raw.githubusercontent.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/main}"
    if _node_has_panel; then
        return 0
    fi
    log_info "Файл $dest на ноде не найден, скачиваю..."
    ssh_exec "mkdir -p /opt/mtpr-simple/data"

    # (a) скачать напрямую на ноде
    ssh_exec "curl -fsSL --max-time 20 '$base/data/backup_panel.sh' -o '$dest'"

    # (b) fallback: скачать на управляющем хосте и залить на ноду
    if ! ssh_exec "[ -s '$dest' ]"; then
        local tmp b64
        tmp=$(mktemp 2>/dev/null) || tmp="/tmp/backup_panel.$$"
        if curl -fsSL --max-time 20 "$base/data/backup_panel.sh" -o "$tmp" && [ -s "$tmp" ]; then
            b64=$(base64 -w0 < "$tmp" 2>/dev/null) || b64=$(base64 < "$tmp" 2>/dev/null | tr -d '\n')
            if [ -n "$b64" ]; then
                ssh_exec "printf '%s' '$b64' | base64 -d > '$dest.tmp' 2>/dev/null || printf '%s' '$b64' | base64 --decode > '$dest.tmp' 2>/dev/null; mv -f '$dest.tmp' '$dest' 2>/dev/null"
            fi
        fi
        rm -f "$tmp" 2>/dev/null || true
    fi

    # Панель принята, только если непустая И поддерживает --scope
    if _node_has_panel && ssh_exec "grep -q -- '--scope' '$dest'"; then
        ssh_exec "chmod +x '$dest'" 2>/dev/null || true
        log_success "Панель бэкапа загружена на ноду: $dest"
        return 0
    fi
    ssh_exec "rm -f '$dest' '$dest.tmp'" 2>/dev/null || true
    log_error "Не удалось получить backup_panel.sh на ноде"
    return 1
}

telemt_backup_menu() {
    echo ""
    log_info "Бэкап/восстановление Telemt на ноде ${REMOTE_USER}@${REMOTE_IP}"
    if ! _ensure_backup_panel_node; then
        log_warning "На ноде нет /opt/mtpr-simple/data/backup_panel.sh — обновите ноду, пропускаю"
        pause_key "Нажмите любую клавишу для возврата"
        return 1
    fi
    if ssh_exec "grep -q -- '--scope' /opt/mtpr-simple/data/backup_panel.sh"; then
        ssh_interactive "bash /opt/mtpr-simple/data/backup_panel.sh --scope telemt"
    else
        log_warning "backup_panel.sh на ноде без поддержки --scope — открываю полное меню"
        ssh_interactive "bash /opt/mtpr-simple/data/backup_panel.sh"
    fi
    return 0
}

# ── Движок Telemt на ноде: кастомная сборка из архива (удалённо) ──
# Управляющий хост качает/проверяет архив, заливает его на ноду base64
# через stdin и запускает там установку. Состояние — /opt/mtpr-simple/engine.json.
ENGINE_STATE="/opt/mtpr-simple/engine.json"
ENGINE_BACKUP_DIR="/opt/mtpr-simple/engine-backup"

_eng_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" 2>/dev/null | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
    else return 1; fi
}

# Есть ли контрольная сумма рядом с архивом (на управляющем хосте)
_eng_checksum_for() {
    local u="$1" tmp="$2" h=""
    case "$u" in
        http://*|https://*)
            if curl -fsSL --max-time 20 -o "$tmp/chk" "$u.sha256" 2>/dev/null && [ -s "$tmp/chk" ]; then
                h=$(grep -oE '[0-9a-fA-F]{64}' "$tmp/chk" | head -1); [ -n "$h" ] && { printf '%s\n' "$h"; return 0; }
            fi
            if curl -fsSL --max-time 20 -o "$tmp/chk" "${u%/*}/checksums.txt" 2>/dev/null && [ -s "$tmp/chk" ]; then
                h=$(grep -oE '[0-9a-fA-F]{64}' "$tmp/chk" | head -1); [ -n "$h" ] && { printf '%s\n' "$h"; return 0; }
            fi ;;
        *)
            if [ -f "$u.sha256" ]; then h=$(grep -oE '[0-9a-fA-F]{64}' "$u.sha256" | head -1); [ -n "$h" ] && { printf '%s\n' "$h"; return 0; }; fi
            if [ -f "$(dirname "$u")/checksums.txt" ]; then h=$(grep -oE '[0-9a-fA-F]{64}' "$(dirname "$u")/checksums.txt" | head -1); [ -n "$h" ] && { printf '%s\n' "$h"; return 0; }; fi ;;
    esac
    return 1
}

# Сведения о ноде → "arch|abi|v3"
_eng_node_info() {
    ssh_exec 'bash -s' <<'ENG_INFO'
A=$(uname -m)
case "$A" in x86_64|amd64) A=x86_64;; aarch64|arm64) A=aarch64;; esac
AB=musl
G=$(getconf GNU_LIBC_VERSION 2>/dev/null | awk '{print $2}')
if [ -n "$G" ]; then
    M=${G%%.*}; N=${G#*.}; N=${N%%.*}
    if [ "${M:-0}" -gt 2 ] 2>/dev/null || { [ "${M:-0}" -eq 2 ] && [ "${N:-0}" -ge 34 ]; }; then AB=gnu; fi
fi
V3=""
if [ "$A" = "x86_64" ]; then
    V3="-v3"
    for f in avx avx2 bmi1 bmi2 fma movbe f16c abm; do
        grep -qw "$f" /proc/cpuinfo 2>/dev/null || { V3=""; break; }
    done
fi
echo "$A|$AB|$V3"
ENG_INFO
}

_eng_remote_install() {
    local arc="$1" want="$2" label="$3" body
    body=$(cat <<'ENG_EOS'
A="$1"; WANT="$2"; LABEL="$3"
STATE=/opt/mtpr-simple/engine.json
BK=/opt/mtpr-simple/engine-backup
o(){ printf '%s\n' "$*"; }
die(){ o "ENGINE_ERR $*"; exit 1; }
[ -s "$A" ] || die "архив не залит на ноду"
T=$(command -v telemt 2>/dev/null)
if [ -z "$T" ]; then
    for uf in /etc/systemd/system/telemt.service /usr/lib/systemd/system/telemt.service /lib/systemd/system/telemt.service; do
        [ -f "$uf" ] || continue
        T=$(sed -nE 's/^[[:space:]]*ExecStart[[:space:]]*=[[:space:]]*([^[:space:];]+).*/\1/p' "$uf" | head -1)
        [ -n "$T" ] && break
    done
fi
[ -n "$T" ] || T=/usr/bin/telemt
ARCH=$(uname -m); case "$ARCH" in x86_64|amd64) ARCH=x86_64;; aarch64|arm64) ARCH=aarch64;; esac
W=$(mktemp -d) || die "mktemp не удалось"
case "$A" in
    *.tar.gz|*.tgz) tar -xzf "$A" -C "$W" ;;
    *.tar.xz|*.txz) tar -xJf "$A" -C "$W" ;;
    *.tar)          tar -xf  "$A" -C "$W" ;;
    *) die "неизвестный формат архива" ;;
esac || die "не удалось распаковать архив"
B=""
if [ -f "$W/telemt" ]; then
    B="$W/telemt"
else
    n=0
    for f in "$W"/*; do
        [ -f "$f" ] && [ -x "$f" ] || continue
        n=$((n+1)); B="$f"
    done
    [ "$n" = 1 ] || die "в архиве не один бинарь"
fi
[ -n "$B" ] && [ -f "$B" ] || die "бинарь telemt не найден"
[ "$(head -c4 "$B" | od -An -tx1 | tr -d ' \n')" = "7f454c46" ] || die "файл не ELF"
if command -v file >/dev/null 2>&1; then
    fo=$(file -b "$B")
    case "$ARCH" in
        x86_64)  printf '%s' "$fo" | grep -qE 'x86-64'  || die "чужая архитектура" ;;
        aarch64) printf '%s' "$fo" | grep -qE 'aarch64' || die "чужая архитектура" ;;
    esac
fi
V=$(timeout 8 "$B" --version 2>&1); rc=$?
[ "$rc" -eq 0 ] || { V=$(timeout 8 "$B" -V 2>&1); rc=$?; }
if [ "$rc" -ne 0 ]; then rm -rf "$W"; o "ENGINE_RC $rc"; exit "$rc"; fi
printf '%s' "$V" | grep -qE '^telemt [0-9]' || { rm -rf "$W"; die "это не telemt"; }
V=$(printf '%s\n' "$V" | head -1)
SA=$(sha256sum "$A" | awk '{print $1}')
if [ -n "$WANT" ] && [ "$SA" != "$WANT" ]; then rm -rf "$W"; die "sha256 архива не совпал"; fi
S=$(sha256sum "$B" | awk '{print $1}')
mkdir -p "$BK" 2>/dev/null
CURV=""; BKFILE=""
if [ -f "$T" ]; then
    CURV=$(timeout 8 "$T" --version 2>/dev/null | head -1)
    BKBASE="$BK/telemt-$(printf '%s' "${CURV:-unknown}" | tr ' /' '__')-$(date +%Y%m%d%H%M%S)"
    BKFILE="$BKBASE"; bn=0
    while [ -e "$BKFILE" ]; do bn=$((bn+1)); BKFILE="${BKBASE}-${bn}"; done
    cp -f "$T" "$BKFILE" || die "не удалось создать бэкап"
fi
D=$(dirname "$T"); mkdir -p "$D" 2>/dev/null
install -m 0755 "$B" "$D/.telemt.new" || die "install не удался"
mv -f "$D/.telemt.new" "$T" || die "не удалось заменить движок"
{
    printf '{\n'
    printf '  "source": "%s",\n' "$LABEL"
    printf '  "sha256": "%s",\n' "$S"
    printf '  "arch": "%s",\n' "$ARCH"
    printf '  "version": "%s",\n' "$V"
    printf '  "installed_at": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '  "target": "%s",\n' "$T"
    printf '  "backup": "%s"\n' "$BKFILE"
    printf '}\n'
} > "$STATE.tmp" && mv -f "$STATE.tmp" "$STATE"
ok=1
if command -v systemctl >/dev/null 2>&1 && systemctl cat telemt >/dev/null 2>&1; then
    systemctl restart telemt || ok=0
    sleep 1
    systemctl is-active --quiet telemt || ok=0
elif command -v docker >/dev/null 2>&1 && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx telemt; then
    docker restart telemt >/dev/null 2>&1 || ok=0
fi
if [ "$ok" != 1 ]; then
    if [ -n "$BKFILE" ] && [ -f "$BKFILE" ]; then
        install -m 0755 "$BKFILE" "$D/.telemt.new" && mv -f "$D/.telemt.new" "$T"
        command -v systemctl >/dev/null 2>&1 && systemctl restart telemt >/dev/null 2>&1
    fi
    rm -rf "$W"
    die "движок не запустился — выполнен откат"
fi
rm -rf "$W"
o "ENGINE_OK $V"
o "ENGINE_SHA $S"
o "ENGINE_TARGET $T"
exit 0
ENG_EOS
)
    ssh_exec "bash -s -- '$arc' '$want' '$label'" <<< "$body"
    return $?
}

engine_install() {
    local src="$1" want_sha="${2:-}"
    [ -n "$src" ] || { log_error "Источник не задан"; return 1; }
    local info arch abi v3 asset
    info=$(_eng_node_info)
    IFS='|' read -r arch abi v3 <<< "$info"
    [ -n "$arch" ] || { log_error "Не удалось определить архитектуру ноды"; return 1; }
    asset="telemt-${arch}${v3}-linux-${abi}.tar.gz"

    local -a urls=() uniq=(); local u x seen
    case "$src" in
        *.tar.gz|*.tgz|*.tar.xz|*.txz|*.tar|/*|./*|../*)
            urls+=("$src") ;;
        http://*|https://*)
            urls+=("${src%/}/$asset")
            urls+=("${src%/}/telemt-${arch}-linux-${abi}.tar.gz")
            if [ "$abi" = "gnu" ]; then urls+=("${src%/}/telemt-${arch}${v3}-linux-musl.tar.gz"); fi
            urls+=("${src%/}/telemt-${arch}-linux-musl.tar.gz") ;;
        *) urls+=("$src") ;;
    esac
    for u in "${urls[@]}"; do
        seen=0; for x in "${uniq[@]:-}"; do [ "$x" = "$u" ] && { seen=1; break; }; done
        [ "$seen" -eq 0 ] && uniq+=("$u")
    done
    urls=("${uniq[@]}")

    local u archive="" exp="$want_sha" got="" tmpd
    tmpd=$(mktemp -d 2>/dev/null) || tmpd="/tmp/eng.$$"
    for u in "${urls[@]}"; do
        archive="$tmpd/engine.tar.gz"
        rm -f "$archive"
        case "$u" in
            http://*|https://*) curl -fL --max-time 120 --retry 2 -o "$archive" "$u" 2>/dev/null || { archive=""; continue; } ;;
            *) { [ -f "$u" ] && cp -f "$u" "$archive"; } 2>/dev/null || { archive=""; continue; } ;;
        esac
        [ -n "$archive" ] && [ -s "$archive" ] && break
        archive=""
    done
    if [ -z "$archive" ]; then
        log_error "Не удалось получить архив ни из одного источника"
        rm -rf "$tmpd"; return 1
    fi
    got=$(_eng_sha256 "$archive")
    if [ -z "$exp" ]; then exp=$(_eng_checksum_for "$u" "$tmpd" || true); fi
    if [ -n "$exp" ]; then
        if [ "$(printf '%s' "$exp" | tr 'A-F' 'a-f')" != "$(printf '%s' "$got" | tr 'A-F' 'a-f')" ]; then
            log_error "sha256 архива не совпал (ожидалось ${exp:0:16}…, получено ${got:0:16}…)"
            rm -rf "$tmpd"; return 1
        fi
        log_info "sha256 совпал: $got"
    else
        log_warning "Контрольной суммы нет. Реальный sha256: $got"
        echo -en "  ${BOLD}Продолжить установку? [y/N]:${NC} "
        local ok=""
        { read -r ok </dev/tty; } 2>/dev/null || { echo; rm -rf "$tmpd"; return 1; }
        case "$ok" in y|Y|yes|YES) : ;; *) echo -e "  ${GRAY}Отменено${NC}"; rm -rf "$tmpd"; return 1 ;; esac
    fi

    local b64 rdest
    b64=$(base64 -w0 < "$archive" 2>/dev/null) || b64=$(base64 < "$archive" 2>/dev/null | tr -d '\n')
    archive=""
    rm -rf "$tmpd"
    [ -n "$b64" ] || { log_error "Не удалось закодировать архив"; return 1; }
    rdest="/tmp/telemt-engine-$$.tar.gz"
    printf '%s' "$b64" | ssh_exec "base64 -d > '$rdest' 2>/dev/null || base64 --decode > '$rdest' 2>/dev/null"
    b64=""
    if ! ssh_exec "[ -s '$rdest' ]"; then
        log_error "Архив не залился на ноду"
        ssh_exec "rm -f '$rdest'"; return 1
    fi
    log_info "Архив залит на ноду, устанавливаю..."
    local out rc
    out=$(_eng_remote_install "$rdest" "$got" "$src")
    rc=$?
    ssh_exec "rm -f '$rdest'"
    printf '%s\n' "$out"
    local ver=""
    ver=$(printf '%s\n' "$out" | sed -n 's/^ENGINE_OK //p' | head -1)
    if [ "$rc" -eq 0 ] && [ -n "$ver" ]; then
        log_success "Движок на ноде обновлён: $ver"
        log_warning "WEB base_path (путь внутри домена) требует движок ${WEB_PATH_MIN_VERSION}+"
        return 0
    fi
    log_error "Не удалось установить движок на ноде"
    return 1
}

engine_status() {
    echo ""
    echo -e "  ${BOLD}Движок Telemt на ноде ${REMOTE_USER}@${REMOTE_IP}${NC}"
    echo -e "  ${DIM}===========================${NC}"
    ssh_exec 'bash -s' <<'ENG_STATUS'
STATE=/opt/mtpr-simple/engine.json
T=$(command -v telemt 2>/dev/null)
if [ -z "$T" ]; then
    for uf in /etc/systemd/system/telemt.service /usr/lib/systemd/system/telemt.service /lib/systemd/system/telemt.service; do
        [ -f "$uf" ] || continue
        T=$(sed -nE 's/^[[:space:]]*ExecStart[[:space:]]*=[[:space:]]*([^[:space:];]+).*/\1/p' "$uf" | head -1)
        [ -n "$T" ] && break
    done
fi
[ -n "$T" ] || T=/usr/bin/telemt
if [ -f "$T" ]; then
    echo "Путь: $T"
    V=$(timeout 8 "$T" --version 2>/dev/null | head -1)
    echo "Версия: ${V:-не удалось определить}"
    S=$(sha256sum "$T" 2>/dev/null | awk '{print $1}')
    echo "sha256: ${S:-недоступно}"
else
    echo "Бинарь не найден: $T"
fi
if [ -f "$STATE" ]; then
    g(){ sed -nE "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*/\1/p" "$STATE" | head -1; }
    echo "Установлен из: $(g source)"
    echo "Время: $(g installed_at)"
    B=$(g backup)
    if [ -n "$B" ] && [ -f "$B" ]; then echo "Бэкап: $B"; else echo "Бэкап: нет"; fi
else
    echo "Состояние ($STATE) отсутствует"
fi
if command -v systemctl >/dev/null 2>&1 && systemctl cat telemt >/dev/null 2>&1; then
    echo "Сервис: $(systemctl is-active telemt 2>/dev/null)"
fi
ENG_STATUS
    echo ""
    return 0
}

engine_rollback() {
    local target backup ver dir rc
    target=$(ssh_exec "command -v telemt 2>/dev/null || echo /usr/bin/telemt")
    backup=""
    if ssh_exec "[ -f '$ENGINE_STATE' ]"; then
        backup=$(ssh_exec "sed -nE 's/.*\"backup\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*/\1/p' '$ENGINE_STATE' | head -1")
    fi
    if [ -z "$backup" ]; then
        log_error "Бэкап движка на ноде не найден — откат невозможен"; return 1
    fi
    if ! ssh_exec "[ -f '$backup' ]"; then
        log_error "Файл бэкапа на ноде отсутствует: $backup"; return 1
    fi
    ssh_exec 'bash -s' <<ENG_RB
set -u
T="$target"; B="$backup"; STATE="$ENGINE_STATE"
[ "\$(head -c4 "\$B" | od -An -tx1 | tr -d ' \n')" = "7f454c46" ] || { echo "ENGINE_ERR бэкап не ELF"; exit 1; }
D=\$(dirname "\$T"); mkdir -p "\$D"
install -m 0755 "\$B" "\$D/.telemt.new" && mv -f "\$D/.telemt.new" "\$T" || { echo "ENGINE_ERR не удалось восстановить"; exit 1; }
ok=1
if command -v systemctl >/dev/null 2>&1 && systemctl cat telemt >/dev/null 2>&1; then
    systemctl restart telemt || ok=0
    sleep 1
    systemctl is-active --quiet telemt || ok=0
fi
[ "\$ok" = 1 ] || { echo "ENGINE_ERR сервис не поднялся после отката"; exit 1; }
V=\$(timeout 8 "\$T" --version 2>/dev/null | head -1)
echo "ENGINE_OK \${V:-unknown}"
ENG_RB
    rc=$?
    if [ "$rc" -eq 0 ]; then
        log_success "Откат на ноде выполнен"
        return 0
    fi
    log_error "Откат на ноде не удался"
    return 1
}

engine_menu() {
    local c src
    while true; do
        clear 2>/dev/null || true
        echo ""
        echo -e "  ${BOLD}Движок Telemt на ноде (кастомная сборка из архива)${NC}"
        echo -e "  ${DIM}===========================${NC}"
        c=$(ssh_exec "command -v telemt >/dev/null 2>&1 && timeout 8 telemt --version 2>/dev/null | head -1")
        echo -e "  ${DIM}Текущий движок: ${c:-не определён}${NC}"
        echo ""
        echo -e "  ${CYAN}[1]${NC}  ${BOLD}Установить/обновить движок из архива${NC}"
        echo -e "  ${CYAN}[2]${NC}  ${BOLD}Статус движка${NC}"
        echo -e "  ${CYAN}[3]${NC}  ${BOLD}Откатить на предыдущий движок${NC}"
        echo ""
        echo -e "  ${RED}[0]${NC}  ${BOLD}Назад${NC}"
        echo ""
        echo -en "  ${BOLD}Выбор:${NC} "
        c=""
        { read -r c </dev/tty; } 2>/dev/null || { echo; break; }
        case "$c" in
            1)
                echo ""
                echo -en "  ${BOLD}URL архива или путь (на управляющем хосте):${NC} "
                src=""
                { read -r src </dev/tty; } 2>/dev/null || { echo; break; }
                src=$(printf '%s' "$src" | tr -d '[:space:]')
                if [ -z "$src" ]; then echo -e "  ${GRAY}Отмена${NC}"; sleep 1; continue; fi
                engine_install "$src" || true
                echo -en "  ${DIM}Enter для продолжения...${NC}"
                { read -r c </dev/tty; } 2>/dev/null || true
                ;;
            2) engine_status || true; echo -en "  ${DIM}Enter...${NC}"; { read -r c </dev/tty; } 2>/dev/null || true ;;
            3) engine_rollback || true; echo -en "  ${DIM}Enter...${NC}"; { read -r c </dev/tty; } 2>/dev/null || true ;;
            0) break ;;
            *) echo "  Неверный выбор"; sleep 0.1 ;;
        esac
    done
    return 0
}

# ── Неинтерактивный режим (CLI) ──────────────────────────────
# ./telemt1_node.sh <IP> <USER> <PORT> --install-silent <версия>
# Без 4-го аргумента — обычный интерактивный режим (главное меню).
case "${4:-}" in
    "")
        : # интерактивный режим — ниже главное меню
        ;;
    --install-silent)
        if [ -n "${5:-}" ]; then
            install_telemt_silent "$5"
            exit $?
        else
            echo "Использование: $0 <IP> <USER> <PORT> --install-silent <версия>" >&2
            exit 2
        fi
        ;;
    *)
        echo "Использование: $0 <IP> <USER> <PORT> [--install-silent <версия>]" >&2
        exit 2
        ;;
esac

# ── Главное меню ─────────────────────────────────────────────
while true; do
    clear 2>/dev/null || true
    echo ""
    echo -e "  ${BOLD}Telemt меню (удалённо: ${CYAN}${REMOTE_USER}@${REMOTE_IP}${NC}${BOLD}) v0.78${NC}"
    echo -e "  ${DIM}===========================${NC}"
    
    # Показываем информацию о Telemt, если установлен
    if is_telemt_installed; then
        echo ""
        echo -e "  ${NC}${BOLD}Telemt:${NC}${GREEN} установлен${NC}"
        
        # Версия
        version=$(get_telemt_version)
        if [ -n "$version" ]; then
            echo -e "  ${NC}${BOLD}Версия:${NC} ${GREEN}${version}${NC}"
        fi
        
        # Порт(ы)
        ports=$(get_telemt_ports)
        if [ -n "$ports" ]; then
            port_count=$(wc -l <<<"$ports")
            if [ "$port_count" -eq 1 ]; then
                echo -e "  ${BOLD}Порт:${NC} ${CYAN}${ports}${NC}"
            else
                echo -e "  ${BOLD}Порты:${NC} ${CYAN}${ports//$'\n'/, }${NC}"
            fi
        fi
        
        # Онлайн
        online=$(get_telemt_online)
        if [ -n "$online" ] && [ "$online" -ge 0 ] 2>/dev/null; then
            echo -e "  ${NC}${BOLD}Подключено к прокси:${NC} ${CYAN}${BOLD}${online}${NC}${BOLD} человек"
        else
            echo -e "  ${NC}${BOLD}Подключено к прокси:${NC} ${CYAN}${BOLD}0${NC}${BOLD} человек"
        fi
        
        # ── СТАТУС MSS (как в main.sh) ──────────────────────
        config_path=$(get_config_path)
        if ssh_exec "[ -f \"$config_path\" ]"; then
            _mss_enabled=$(is_mss_enabled_for_config "$config_path" && echo "включен" || echo "отключен")
            _mss_bulk_enabled=$(is_mss_bulk_enabled_for_config "$config_path" && echo "включен" || echo "отключен")
            _synlimit_enabled=$(is_synlimit_enabled_for_config "$config_path" && echo "включен" || echo "отключен")
            
            mss_color="${GREEN}"
            mss_bulk_color="${GREEN}"
            synlimit_color="${GREEN}"
            
            [ "$_mss_enabled" = "включен" ] && mss_color="${RED}"
            [ "$_mss_bulk_enabled" = "включен" ] && mss_bulk_color="${RED}"
            [ "$_synlimit_enabled" = "включен" ] && synlimit_color="${RED}"
            
            echo -e "  ${BOLD}Встроенный MSS:${NC} ${mss_color}${_mss_enabled}${NC}  |  ${BOLD}MSS_BULK:${NC} ${mss_bulk_color}${_mss_bulk_enabled}${NC}  |  ${BOLD}Synlimit:${NC} ${synlimit_color}${_synlimit_enabled}${NC}"
        fi
        
        echo ""
    fi
    
    echo -e "  ${CYAN}[1]${NC}  ${BOLD}Установить/обновить/откатить Telemt${NC}"
    echo -e "  ${CYAN}[2]${NC}  ${BOLD}Установить Telemt в Docker${NC}"
    echo -e "  ${CYAN}[3]${NC}  ${BOLD}Открыть конфиг Telemt${NC}"
    echo -e "  ${CYAN}[4]${NC}  ${BOLD}Перезапустить Telemt${NC}"
    echo -e "  ${CYAN}[5]${NC}  ${BOLD}Обновить путь к конфигу Telemt${NC}"
    echo -e "  ${CYAN}[6]${NC}  ${BOLD}Посмотреть логи Telemt${NC}"
    echo -e "  ${CYAN}[7]${NC}  ${BOLD}Вывести ссылку на подключение для пользователя${NC}"
    
    # ── Динамическое отображение статуса MSS в меню ──────
    config_path=$(get_config_path)
    if ssh_exec "[ -f \"$config_path\" ]"; then
        if are_bad_options_enabled_for_config "$config_path"; then
            echo -e "  ${CYAN}[8]${NC}  ${GREEN}${BOLD}Отключить mss, mss_bulk и synlimit в конфиге telemt${NC}"
        else
            echo -e "  ${CYAN}[8]${NC}  ${BOLD}Включить mss и mss_bulk в конфиге telemt${RED} (не рекомендуется)${NC}"
        fi
    else
        echo -e "  ${CYAN}[8]${NC}  ${BOLD}Управление MSS в конфиге${NC} ${DIM}(client_mss, mss_bulk, synlimit)${NC}"
    fi
    
    echo -e "  ${RED}[9]${NC}  ${BOLD}Удалить Telemt обычный/Telemt в докере${NC}"
    echo ""
    echo -e "  ${CYAN}[a]${NC}  ${BOLD}Открыть меню панели Telemt${NC} ${DIM}(не поддерживается удалённо)${NC}"
    echo ""
    echo -e "  ${CYAN}[u]${NC}  ${BOLD}Добавить пользователя(ей)${NC}"
    echo -e "  ${CYAN}[w]${NC}  ${BOLD}Установить WEB-прокси (telemt + nginx)${NC}"
    echo -e "  ${CYAN}[b]${NC}  ${BOLD}Бэкап и восстановление Telemt${NC}"
    echo -e "  ${CYAN}[e]${NC}  ${BOLD}Движок Telemt (кастомная сборка из архива)${NC}"
    echo ""
    echo -e "  ${RED}${BOLD}[0]${NC}  ${BOLD}Назад в управление нодой${NC}"
    echo ""
    
    if ! is_telemt_installed; then
        echo -e "  ${YELLOW}Telemt не установлен${NC}"
        echo ""
    else
        current_path=$(get_config_path)
        echo -e "  ${DIM}Текущий путь к конфигу: ${current_path}${NC}"
        echo ""
    fi
    
    echo -en "  ${BOLD}Выбор:${NC} "
    { read -r choice </dev/tty; } 2>/dev/null || { echo; break; }

    case "$choice" in
        1)
            install_telemt
            ;;
        2)
            install_telemt_docker
            ;;
        3)
            edit_config
            ;;
        4)
            restart_telemt
            ;;
        5)
            update_config_path
            ;;
        6)
            view_logs
            ;;
        7)
            find_user_link
            ;;
        8)
            manage_mss
            ;;
        9)
            purge_telemt_menu
            ;;
        a|A)
            echo ""
            echo "  [✗] Меню панели Telemt не поддерживается в удалённом режиме"
            pause_key "Нажмите любую клавишу для возврата"
            ;;
        u|U)
            add_users_menu || true
            ;;
        w|W)
            web_proxy_menu || true
            ;;
        b|B)
            telemt_backup_menu || true
            ;;
        e|E)
            engine_menu || true
            ;;
        0)
            echo ""
            log_info "Возврат в управление нодой..."
            exit 0
            ;;
        *)
            echo "  Неверный выбор"
            sleep 0.1
            ;;
    esac
done
