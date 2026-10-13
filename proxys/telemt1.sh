#!/bin/bash
# telemt1.sh

# ── Безопасный запуск внешнего установщика ────────────────────
# Скачивает скрипт во временный файл, проверяет успех curl и
# непустой ответ, и только затем запускает. Возвращает реальный
# код запуска: раньше `curl ... | sh` давал 0 при пустом ответе
# (404/сеть), из-за чего сбой выглядел как успешная установка.
# Использование: fetch_and_run <sh|bash|sudo-bash> <url> [args...]
fetch_and_run() {
    local mode="$1"; shift
    local url="$1"; shift
    local tmp rc=0
    tmp=$(mktemp) || return 1
    if ! curl -fsSL "$url" -o "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    if [ ! -s "$tmp" ]; then
        rm -f "$tmp"
        return 1
    fi
    case "$mode" in
        sh)        sh "$tmp" "$@" || rc=$? ;;
        bash)      bash "$tmp" "$@" || rc=$? ;;
        sudo-bash) sudo bash "$tmp" "$@" || rc=$? ;;
        *)         rc=1 ;;
    esac
    rm -f "$tmp"
    return $rc
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
    if [ -f "$CONFIG_PATH_FILE" ] && [ -s "$CONFIG_PATH_FILE" ]; then
        path=$(cat "$CONFIG_PATH_FILE")
        if [ "$path" != "skip" ]; then
            echo "$path"
            return 0
        fi
    fi
    echo "/etc/telemt/telemt.toml"
    return 0
}

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

# Читает FakeTLS-домены из файла конфига и печатает по одному на строку.
get_tls_domains() {
    local _cfg="$1"
    [ -n "$_cfg" ] && [ -f "$_cfg" ] || return 0
    local _raw
    _raw=$(awk '
        /^[[:space:]]*tls_domain[[:space:]]*=/ { print; next }
        /^[[:space:]]*tls_domains[[:space:]]*=/ {
            grab=1; print
            if (index($0, "]") > 0) grab=0
            next
        }
        grab { print; if (index($0, "]") > 0) grab=0 }
    ' "$_cfg" 2>/dev/null)
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
    if pgrep -x telemt &>/dev/null || systemctl is-active telemt.service &>/dev/null 2>&1; then
        local _args
        _args=$(ps -eo args 2>/dev/null | grep '[t]elemt' | grep -v 'telemt-panel' | grep -v 'telemt_panel' | head -1 | grep -oE '/[^ ]+\.toml' | head -1)
        if [ -n "$_args" ] && [ -f "$_args" ] && ! _is_excluded_path "$_args" && _looks_like_telemt_config "$_args"; then
            DETECTED_CONFIG_PATH="$_args"
        fi
    fi
    
    # 2. Поиск конфига в стандартных местах
    if [ -z "$DETECTED_CONFIG_PATH" ]; then
        local _cf
        for _cf in /etc/telemt/telemt.toml /etc/telemt/config.toml /etc/telemt.toml /opt/telemt/config.toml /opt/telemt/telemt.toml; do
            if [ -f "$_cf" ] && ! _is_excluded_path "$_cf" && _looks_like_telemt_config "$_cf"; then
                DETECTED_CONFIG_PATH="$_cf"
                break
            fi
        done
    fi
    
    # 3. Проверяем сохранённый путь
    if [ -z "$DETECTED_CONFIG_PATH" ] && [ -f "$CONFIG_PATH_FILE" ] && [ -s "$CONFIG_PATH_FILE" ]; then
        local _saved_path=$(cat "$CONFIG_PATH_FILE")
        if [ "$_saved_path" != "skip" ] && [ -f "$_saved_path" ] && _looks_like_telemt_config "$_saved_path"; then
            DETECTED_CONFIG_PATH="$_saved_path"
        fi
    fi
    
    # 4. Получаем параметры из конфига
    if [ -n "$DETECTED_CONFIG_PATH" ] && [ -f "$DETECTED_CONFIG_PATH" ]; then
        DETECTED_PORT=$(_toml_get_value "port" "$DETECTED_CONFIG_PATH")
        DETECTED_IP=$(grep -E '^ip[[:space:]]*=' "$DETECTED_CONFIG_PATH" 2>/dev/null | head -1 | awk -F'=' '{print $2}' | tr -d ' "')
        DETECTED_PUBLIC_HOST=$(grep -E '^public_host[[:space:]]*=' "$DETECTED_CONFIG_PATH" 2>/dev/null | head -1 | awk -F'=' '{print $2}' | tr -d ' "')
        DETECTED_TLS_DOMAIN=$(grep -E '^tls_domain[[:space:]]*=' "$DETECTED_CONFIG_PATH" 2>/dev/null | head -1 | awk -F'=' '{print $2}' | tr -d ' "')
        
        # Ищем секрет - сначала в секции [access.users], потом во всем файле
        DETECTED_SECRET=$(sed -n '/^\[access\.users\]/,/^\[/p' "$DETECTED_CONFIG_PATH" 2>/dev/null | grep -E '=' | head -1 | awk -F'=' '{print $2}' | tr -d ' "')
        if [ -z "$DETECTED_SECRET" ]; then
            DETECTED_SECRET=$(grep -E '^[[:space:]]*[^#]*[[:space:]]*=' "$DETECTED_CONFIG_PATH" 2>/dev/null | grep -v '^#' | head -1 | awk -F'=' '{print $2}' | tr -d ' "')
        fi
        
        # Проверяем режимы
        DETECTED_CLASSIC=$(grep -E '^classic[[:space:]]*=' "$DETECTED_CONFIG_PATH" 2>/dev/null | grep -v '^#' | head -1 | awk -F'=' '{print $2}' | tr -d ' "')
        DETECTED_SECURE=$(grep -E '^secure[[:space:]]*=' "$DETECTED_CONFIG_PATH" 2>/dev/null | grep -v '^#' | head -1 | awk -F'=' '{print $2}' | tr -d ' "')
        DETECTED_TLS=$(grep -E '^tls[[:space:]]*=' "$DETECTED_CONFIG_PATH" 2>/dev/null | grep -v '^#' | head -1 | awk -F'=' '{print $2}' | tr -d ' "')
    fi
    
    echo "$DETECTED_CONFIG_PATH:$DETECTED_PORT:$DETECTED_IP:$DETECTED_PUBLIC_HOST:$DETECTED_CLASSIC:$DETECTED_SECURE:$DETECTED_TLS:$DETECTED_TLS_DOMAIN:$DETECTED_SECRET"
}

# ── Функция получения публичного IP ──────────────────────────
get_public_ip() {
    local _ip=""
    _ip=$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null) ||
    _ip=$(curl -4 -fsS --max-time 5 https://ifconfig.me 2>/dev/null) ||
    _ip=$(curl -4 -fsS --max-time 5 https://icanhazip.com 2>/dev/null) ||
    _ip=""
    echo "$_ip"
}

# ── Функция получения списка пользователей из конфига ──────
get_users_list() {
    local config_path=$(get_config_path)
    if [ ! -f "$config_path" ]; then
        return 1
    fi
    
    # Получаем все строки из секции [access.users]
    sed -n '/^\[access\.users\]/,/^\[/p' "$config_path" 2>/dev/null | grep -E '=' | grep -v '^#' | while IFS='=' read -r name secret; do
        name=$(echo "$name" | tr -d ' "')
        secret=$(echo "$secret" | tr -d ' "')
        if [ -n "$name" ] && [ -n "$secret" ]; then
            echo "$name:$secret"
        fi
    done
}

# ── Функция поиска пользователя и вывода ссылки ─────────────
# ── Печать ссылок пользователя (TLS/Secure/Classic) ─────────
# Переиспользуется в find_user_link и при добавлении пользователей.
print_user_links() {
    local user_name="$1"
    local user_secret="$2"

    local config_path=""
    config_path=$(get_config_path)

    # Получаем параметры для ссылки
    local detected_info=$(detect_telemt_advanced)
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
        port=$(grep -E '^port[[:space:]]*=' "$config_path" 2>/dev/null | head -1 | awk -F'=' '{print $2}' | tr -d ' "')
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
        server=$(curl -4 -fsS --max-time 3 https://api.ipify.org 2>/dev/null)
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
        echo -e "  ${GRAY}Нажмите любую клавишу для возврата...${NC}"
        { read -rsn1 </dev/tty; } 2>/dev/null || true
        return 1
    fi
    
    # Получаем список пользователей
    local users=$(get_users_list)
    if [ -z "$users" ]; then
        echo ""
        echo -e "  ${YELLOW}[!]${NC} В конфиге нет пользователей в секции [access.users]"
        echo ""
        echo -e "  ${GRAY}Нажмите любую клавишу для возврата...${NC}"
        { read -rsn1 </dev/tty; } 2>/dev/null || true
        return 1
    fi
    
    # Ищем совпадения (регистронезависимо)
    local matches=$(echo "$users" | grep -i "$search_query")
    
    if [ -z "$matches" ]; then
        echo ""
        echo -e "  ${YELLOW}[!]${NC} Пользователь с именем \"$search_query\" не найден"
        echo ""
        echo -e "  ${GRAY}Нажмите любую клавишу для возврата...${NC}"
        { read -rsn1 </dev/tty; } 2>/dev/null || true
        return 1
    fi
    
    # Проверяем сколько совпадений
    local match_count=$(echo "$matches" | wc -l)
    
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
        echo -e "  ${GRAY}Нажмите любую клавишу для возврата...${NC}"
        { read -rsn1 </dev/tty; } 2>/dev/null || true
        return 1
    fi
    
    # Одно совпадение — показываем ссылку
    local user_name=$(echo "$matches" | cut -d':' -f1)
    local user_secret=$(echo "$matches" | cut -d':' -f2)
    
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
    echo -e "  ${GRAY}Нажмите любую клавишу для возврата...${NC}"
    { read -rsn1 </dev/tty; } 2>/dev/null || true
}

# ── Функция проверки, установлен ли Telemt ──────────────────
is_telemt_installed() {
    if command -v telemt >/dev/null 2>&1; then
        return 0
    fi
    if systemctl is-active --quiet telemt 2>/dev/null; then
        return 0
    fi
    if pgrep -x telemt >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

# ── Функция получения версии Telemt ─────────────────────────
get_telemt_version() {
    if command -v telemt >/dev/null 2>&1; then
        telemt --version 2>/dev/null | head -1 | awk '{print $2}'
    else
        echo ""
    fi
}

# ── Функция получения порта(ов) из конфига ──────────────────
get_telemt_ports() {
    local config_path=$(get_config_path)
    if [ ! -f "$config_path" ]; then
        echo ""
        return 1
    fi
    grep -E '^port[[:space:]]*=' "$config_path" 2>/dev/null | awk -F'=' '{print $2}' | tr -d ' "'
}

# ── Функция получения онлайна Telemt ────────────────────────
get_telemt_online() {
    if is_telemt_installed; then
        curl -s http://127.0.0.1:9091/v1/stats/users/active-ips 2>/dev/null | grep -o '"active_ips":\[[^]]*\]' | grep -o '[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}' | wc -l | tr -d ' '
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

    if [ ! -f "$CONFIG_TELEMT_INPUT" ]; then
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

    mkdir -p /opt/mtpr-simple
    echo "$CONFIG_TELEMT_INPUT" > "$CONFIG_PATH_FILE"
    echo -e "  ${GREEN}[✓]${NC} Путь сохранён: $CONFIG_TELEMT_INPUT"
    echo ""
    echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
    { read -rsn1 </dev/tty; } 2>/dev/null || true
    return 0
}

# ── Функция просмотра логов ──────────────────────────────────
view_logs() {
    echo ""
    echo -e "  ${BLUE}[i]${NC} Просмотр логов Telemt (Ctrl+C для выхода)..."
    echo ""
    echo -e "  ${GRAY}Нажмите любую клавишу для продолжения...${NC}"
    { read -rsn1 </dev/tty; } 2>/dev/null || true
    journalctl -u telemt -f
    echo ""
    echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
    { read -rsn1 </dev/tty; } 2>/dev/null || true
}

# ── Занят ли TCP-порт ЧУЖИМ процессом ───────────────────────
# 0 — занят посторонним, 1 — свободен или занят самим telemt
_telemt_port_busy_by_other() {
    local p="$1" line
    [ -z "$p" ] && return 1
    line=$(ss -ltnp 2>/dev/null | awk -v p=":$p" 'index($4, p) == length($4) - length(p) + 1 { print }')
    [ -z "$line" ] && return 1
    case "$line" in *telemt*) return 1 ;; esac
    return 0
}

# ── Спросить порт (только интерактивный путь) ───────────────
# Результат — в TELEMT_PORT_CHOSEN. rc=1 — отмена пользователем.
ask_telemt_port() {
    local default_port="443" reply
    while true; do
        echo ""
        echo -e "  ${NC}${BOLD}Укажите порт для прокси${NC} ${GRAY}(по умолчанию: ${default_port})${NC}"
        echo -e "  ${GRAY}Enter — оставить по умолчанию, N/n — отмена${NC}"
        echo -en "  ${NC}${BOLD}Порт:${NC} "
        { read -r reply </dev/tty; } 2>/dev/null || { echo; return 1; }

        if [[ "$reply" =~ ^[Nn]$ ]]; then
            echo ""
            echo -e "  ${GRAY}Установка отменена${NC}"
            return 1
        fi
        [ -z "$reply" ] && reply="$default_port"

        if ! [[ "$reply" =~ ^[0-9]+$ ]] || [ "$reply" -lt 1 ] || [ "$reply" -gt 65535 ]; then
            echo -e "  ${YELLOW}[!]${NC} Неверный порт: ${reply} (нужно 1-65535)."
            continue
        fi
        if _telemt_port_busy_by_other "$reply"; then
            echo -e "  ${RED}[✗]${NC} Порт уже занят другим процессом: ${reply}"
            echo -e "  ${GRAY}Освободите порт или укажите другой.${NC}"
            continue
        fi

        TELEMT_PORT_CHOSEN="$reply"
        return 0
    done
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
        echo -e "  ${GRAY}${BOLD}Нажмите любую клавишу для возврата в меню...${NC}"
        { read -rsn1 </dev/tty; } 2>/dev/null || true
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
            echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
            { read -rsn1 </dev/tty; } 2>/dev/null || true
            return 1
        fi
    fi

    echo ""
    echo -e "  ${BLUE}[i]${NC} Установка Telemt версии ${display_version}..."

    # ── ПОРТ: спрашиваем у пользователя ──────────────────────
    # Если 443 (или любой другой порт) занят, upstream падает с
    # «Порт уже занят другим процессом» — поэтому порт выбираем здесь.
    if ! ask_telemt_port; then
        echo ""
        echo -e "  ${GRAY}${BOLD}Нажмите любую клавишу для возврата в меню...${NC}"
        { read -rsn1 </dev/tty; } 2>/dev/null || true
        return 1
    fi
    local _port="$TELEMT_PORT_CHOSEN"
    echo ""

    # ── ПЕРЕХОДИМ В /tmp И УБИРАЕМ INSTALL_DIR ──
    cd /tmp
    unset INSTALL_DIR

    # ── Флаги для upstream-установщика ────────────────────────
    # -l 2 обязателен: интерфейс русский, иначе upstream задаёт
    # лишний вопрос про язык. Порт — выбранный выше (сохраняем в
    # /opt/mtpr-simple/port), домен — из tls_domain конфига.
    local _domain="" _cfg="" _info=""
    _info=$(detect_telemt_advanced)
    _cfg=$(echo "$_info" | cut -d: -f1)
    if [ -n "$_cfg" ] && [ -f "$_cfg" ]; then
        _domain=$(grep -E '^tls_domain[[:space:]]*=' "$_cfg" 2>/dev/null | head -1 | awk -F'=' '{print $2}' | tr -d ' "')
    fi
    mkdir -p /opt/mtpr-simple 2>/dev/null || true
    printf '%s\n' "$_port" > /opt/mtpr-simple/port 2>/dev/null || true

    local -a telemt_flags=(-l 2 -p "$_port")
    [ -n "$_domain" ] && telemt_flags+=(-d "$_domain")

    if [ "$install_version" = "latest" ]; then
        if fetch_and_run sh "https://raw.githubusercontent.com/telemt/telemt/main/install.sh" "${telemt_flags[@]}"; then
            echo ""
            echo -e "  ${GREEN}[✓]${NC} Telemt успешно установлен (последняя версия)"
        else
            echo ""
            echo -e "  ${RED}[✗]${NC} Ошибка установки Telemt"
        fi
    else
        if fetch_and_run sh "https://raw.githubusercontent.com/telemt/telemt/main/install.sh" "$install_version" "${telemt_flags[@]}"; then
            echo ""
            echo -e "  ${GREEN}[✓]${NC} Telemt версии ${install_version} успешно установлен"
        else
            echo ""
            echo -e "  ${RED}[✗]${NC} Ошибка установки Telemt версии ${install_version}"
        fi
    fi
    
    echo ""
    echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
    { read -rsn1 </dev/tty; } 2>/dev/null || true
}

# ── Прогон upstream-установщика без tty-шума ─────────────────
# Upstream проверяет `-c /dev/tty` (устройство существует всегда),
# затем читает из него и без управляющего терминала печатает
# безобидное "/dev/tty: No such device or address". Отфильтровываем
# ровно это сообщение, весь прочий stderr сохраняем.
_silent_run_installer() {
    local rc=0 errf
    errf=$(mktemp 2>/dev/null) || { fetch_and_run "$@"; return $?; }
    fetch_and_run "$@" 2>"$errf" || rc=$?
    if [ -s "$errf" ]; then
        grep -v -- '/dev/tty: No such device' "$errf" >&2 || true
    fi
    rm -f "$errf"
    return $rc
}

# ── Неинтерактивная установка Telemt (--install-silent <вер>) ─
# Ставит конкретную версию (X.Y.Z) или latest БЕЗ промптов, меню и
# ожидания клавиши. Ни разу не обращается к /dev/tty, поэтому
# работает без терминала. Честный rc: 0 — успех, 1 — ошибка или
# неверный формат версии.
install_telemt_silent() {
    local version_input="${1:-}"
    local port_input="${2:-}"
    local install_version="latest" display_version="последнюю"

    if [ -n "$port_input" ]; then
        if ! [[ "$port_input" =~ ^[0-9]+$ ]] || [ "$port_input" -lt 1 ] || [ "$port_input" -gt 65535 ]; then
            echo -e "  ${RED}[✗]${NC} Неверный порт: '${port_input}' (нужно 1-65535)" >&2
            return 1
        fi
    fi

    if [ -z "$version_input" ] || [ "$version_input" = "latest" ]; then
        install_version="latest"
        display_version="последнюю"
    elif [[ "$version_input" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        install_version="$version_input"
        display_version="$version_input"
    else
        echo -e "  ${YELLOW}[!]${NC} Некорректный формат версии: '${version_input}'. Используйте X.Y.Z или latest" >&2
        return 1
    fi

    echo -e "  ${BLUE}[i]${NC} Установка Telemt версии ${display_version}..."

    # ── ПЕРЕХОДИМ В /tmp И УБИРАЕМ INSTALL_DIR ──
    cd /tmp
    unset INSTALL_DIR

    # ── Флаги для upstream-установщика ────────────────────────
    # Порт: аргумент (2-й) имеет приоритет, иначе /opt/mtpr-simple/port,
    # иначе автоопределение, иначе 443.
    local _port="" _domain="" _cfg="" _info=""
    if [ -n "$port_input" ]; then
        _port="$port_input"
    elif [ -f /opt/mtpr-simple/port ] && [ -s /opt/mtpr-simple/port ]; then
        _port=$(head -1 /opt/mtpr-simple/port | tr -d '[:space:]')
    fi
    _info=$(detect_telemt_advanced)
    _cfg=$(echo "$_info" | cut -d: -f1)
    [ -z "$_port" ] && _port=$(echo "$_info" | cut -d: -f2)
    if [ -n "$_cfg" ] && [ -f "$_cfg" ]; then
        _domain=$(grep -E '^tls_domain[[:space:]]*=' "$_cfg" 2>/dev/null | head -1 | awk -F'=' '{print $2}' | tr -d ' "')
    fi
    [ -z "$_port" ] && _port="443"
    mkdir -p /opt/mtpr-simple 2>/dev/null || true
    printf '%s\n' "$_port" > /opt/mtpr-simple/port 2>/dev/null || true

    local -a telemt_flags=(-l 2 -p "$_port")
    [ -n "$_domain" ] && telemt_flags+=(-d "$_domain")

    local rc=1
    if [ "$install_version" = "latest" ]; then
        if _silent_run_installer sh "https://raw.githubusercontent.com/telemt/telemt/main/install.sh" "${telemt_flags[@]}"; then
            echo -e "  ${GREEN}[✓]${NC} Telemt успешно установлен (последняя версия)"
            rc=0
        else
            echo -e "  ${RED}[✗]${NC} Ошибка установки Telemt"
        fi
    else
        if _silent_run_installer sh "https://raw.githubusercontent.com/telemt/telemt/main/install.sh" "$install_version" "${telemt_flags[@]}"; then
            echo -e "  ${GREEN}[✓]${NC} Telemt версии ${install_version} успешно установлен"
            rc=0
        else
            echo -e "  ${RED}[✗]${NC} Ошибка установки Telemt версии ${install_version}"
        fi
    fi
    return $rc
}

# ── Функция установки Telemt в Docker ───────────────────────
install_telemt_docker() {
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    DOCKER_SCRIPT="$SCRIPT_DIR/telemt_in_docker1.sh"
    
    if [ -f "$DOCKER_SCRIPT" ]; then
        chmod +x "$DOCKER_SCRIPT"
        source "$DOCKER_SCRIPT"
    else
        echo ""
        echo -e "  ${RED}[✗]${NC} Файл $DOCKER_SCRIPT не найден"
        echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
        { read -rsn1 </dev/tty; } 2>/dev/null || true
    fi
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
        echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
        { read -rsn1 </dev/tty; } 2>/dev/null || true
        return 1
    fi

    echo ""
    echo -e "  ${BLUE}[i]${NC} Удаление Telemt..."
    echo ""
    if fetch_and_run sh "https://raw.githubusercontent.com/telemt/telemt/main/install.sh" purge -l 2; then
        echo ""
        echo -e "  ${GREEN}[✓]${NC} Telemt успешно удалён"
    else
        echo ""
        echo -e "  ${RED}[✗]${NC} Ошибка удаления Telemt"
    fi
    echo ""
    echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
    { read -rsn1 </dev/tty; } 2>/dev/null || true
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
    if [ -d "$TELEMT_PATH" ]; then
        echo -e "  ${DIM}Обнаружена папка: ${TELEMT_PATH}${NC}"
    else
        echo -e "  ${YELLOW}[!]${NC} Папка $TELEMT_PATH не найдена"
        echo -en "  ${BOLD}Удалять всё равно? [y/N]:${NC} "
        { read -r force_remove </dev/tty; } 2>/dev/null || true
        if [[ ! "$force_remove" =~ ^[yY]$ ]]; then
            echo -e "  ${GRAY}Удаление отменено${NC}"
            echo ""
            echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
            { read -rsn1 </dev/tty; } 2>/dev/null || true
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
        echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
        { read -rsn1 </dev/tty; } 2>/dev/null || true
        return 1
    fi

    echo ""
    echo -e "  ${BLUE}[i]${NC} Удаление Telemt из Docker..."
    echo ""
    
    # 1. Останавливаем и удаляем контейнеры
    if [ -f "$TELEMT_PATH/docker-compose.yml" ]; then
        echo -e "  ${BLUE}[i]${NC} Остановка и удаление контейнеров..."
        cd "$TELEMT_PATH" && docker compose down -v 2>/dev/null || echo -e "  ${YELLOW}[!]${NC} Контейнеры не найдены или уже удалены"
    else
        echo -e "  ${YELLOW}[!]${NC} docker-compose.yml не найден, пропускаем остановку контейнеров"
    fi
    
    # 2. Удаляем папку с проектом
    echo -e "  ${BLUE}[i]${NC} Удаление папки $TELEMT_PATH..."
    if [ -d "$TELEMT_PATH" ]; then
        cd /root && rm -rf "$TELEMT_PATH"
        echo -e "  ${GREEN}[✓]${NC} Папка удалена"
    else
        echo -e "  ${YELLOW}[!]${NC} Папка не найдена"
    fi
    
    # 3. Удаляем образы
    echo -e "  ${BLUE}[i]${NC} Удаление образов..."
    docker rmi ghcr.io/telemt/telemt:* 2>/dev/null || echo -e "  ${YELLOW}[!]${NC} Образ Telemt не найден"
    docker rm -f watchtower 2>/dev/null || true
    docker rmi containrrr/watchtower 2>/dev/null || echo -e "  ${YELLOW}[!]${NC} Образ Watchtower не найден"
    
    # 4. Чистим неиспользуемые образы, контейнеры, сети
    echo -e "  ${BLUE}[i]${NC} Очистка неиспользуемых ресурсов Docker..."
    echo -e "  ${DIM}Будут удалены все неиспользуемые образы, контейнеры и сети${NC}"
    echo -en "  ${BOLD}Выполнить очистку? [y/N]:${NC} "
    { read -r prune_confirm </dev/tty; } 2>/dev/null || prune_confirm="n"
    if [[ "$prune_confirm" =~ ^[yY]$ ]]; then
        docker system prune -af
        echo -e "  ${GREEN}[✓]${NC} Очистка выполнена"
    else
        echo -e "  ${GRAY}Очистка пропущена${NC}"
    fi
    
    # 5. Проверяем что ничего не осталось
    echo ""
    echo -e "  ${BLUE}[i]${NC} Проверка остатков..."
    echo -e "  ${BOLD}Контейнеры:${NC}"
    docker ps -a | grep telemt || echo -e "  ${GRAY}Контейнеров Telemt не найдено${NC}"
    echo ""
    echo -e "  ${BOLD}Образы:${NC}"
    docker images | grep telemt || echo -e "  ${GRAY}Образов Telemt не найдено${NC}"
    
    echo ""
    echo -e "  ${GREEN}[✓]${NC} Telemt из Docker успешно удалён!"
    echo ""
    echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
    { read -rsn1 </dev/tty; } 2>/dev/null || true
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
    
    if [ ! -f "$config_path" ]; then
        echo ""
        echo -e "  ${YELLOW}[!]${NC} Файл конфига не найден по пути: $config_path"
        echo -e "  ${GRAY}Используйте пункт 4 для обновления пути к конфигу${NC}"
        echo ""
        echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
        { read -rsn1 </dev/tty; } 2>/dev/null || true
        return 1
    fi
    
    echo ""
    echo -e "  ${BLUE}[i]${NC} Открытие конфига: $config_path"
    
    if command -v nano >/dev/null 2>&1; then
        echo -e "  ${GRAY}После редактирования сохраните файл (Ctrl+O) и закройте (Ctrl+X)${NC}"
        echo ""
        echo -e "  ${GRAY}Нажмите любую клавишу для продолжения...${NC}"
        { read -rsn1 </dev/tty; } 2>/dev/null || true
        nano "$config_path"
    elif command -v vim >/dev/null 2>&1; then
        echo -e "  ${YELLOW}[!]${NC} nano не установлен. Используем vim для открытия файла."
        echo -e "  ${GRAY}Для сохранения: нажмите ESC, затем введите :wq и Enter${NC}"
        echo -e "  ${GRAY}Для выхода без сохранения: ESC, затем :q! и Enter${NC}"
        echo ""
        echo -e "  ${GRAY}Нажмите любую клавишу для продолжения...${NC}"
        { read -rsn1 </dev/tty; } 2>/dev/null || true
        vim "$config_path"
    elif command -v vi >/dev/null 2>&1; then
        echo -e "  ${YELLOW}[!]${NC} Использую vi."
        echo -e "  ${GRAY}Для сохранения: нажмите ESC, затем введите :wq и Enter${NC}"
        echo ""
        echo -e "  ${GRAY}Нажмите любую клавишу для продолжения...${NC}"
        { read -rsn1 </dev/tty; } 2>/dev/null || true
        vi "$config_path"
    else
        echo -e "  ${RED}[✗]${NC} Ни один редактор не найден (nano, vim, vi)"
        echo -e "  ${GRAY}Установите один из редакторов: apt install nano или vim${NC}"
        echo ""
        echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
        { read -rsn1 </dev/tty; } 2>/dev/null || true
        return 1
    fi
    
    echo ""
    echo -e "  ${GREEN}[✓]${NC} Редактирование завершено"
    echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
    { read -rsn1 </dev/tty; } 2>/dev/null || true
}

# ── Функция перезапуска Telemt ──────────────────────────────
restart_telemt() {
    echo ""
    echo -e "  ${BLUE}[i]${NC} Перезапуск Telemt..."
    echo ""
    if systemctl restart telemt 2>/dev/null; then
        echo -e "  ${GREEN}[✓]${NC} Telemt успешно перезапущен"
    else
        echo -e "  ${YELLOW}[!]${NC} Не удалось перезапустить Telemt (возможно, он не установлен как служба)"
        echo -e "  ${GRAY}Попробуйте сначала установить Telemt (пункт 1)${NC}"
    fi
    echo ""
    echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
    { read -rsn1 </dev/tty; } 2>/dev/null || true
}

# ── ФУНКЦИИ УПРАВЛЕНИЯ MSS (скопированы из main.sh) ────────

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
    local config_path=$(get_config_path)
    if [ -z "$config_path" ] || [ ! -f "$config_path" ]; then
        echo ""
        echo -e "  ${RED}[✗]${NC} Файл конфига не найден или не указан"
        echo ""
        echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
        { read -rsn1 </dev/tty; } 2>/dev/null || true
        return 1
    fi

    local changed=0
    local mss_value="92"
    local mss_bulk_value="1200"

    # Проверяем наличие строк (даже закомментированных)
    local has_mss=$(grep -E '^[[:space:]]*#?[[:space:]]*client_mss[[:space:]]*=' "$config_path" | head -1)
    local has_mss_bulk=$(grep -E '^[[:space:]]*#?[[:space:]]*mss_bulk[[:space:]]*=' "$config_path" | head -1)

    # Раскомментируем и обновляем client_mss
    if [ -n "$has_mss" ]; then
        sed -i 's/^[[:space:]]*#[[:space:]]*client_mss[[:space:]]*=.*/client_mss = '"$mss_value"'/' "$config_path"
        changed=1
    else
        # Добавляем в секцию server
        if grep -q '^\[server\]' "$config_path"; then
            sed -i '/^\[server\]/a client_mss = '"$mss_value"'' "$config_path"
            changed=1
        else
            echo "" >> "$config_path"
            echo "[server]" >> "$config_path"
            echo "client_mss = $mss_value" >> "$config_path"
            changed=1
        fi
    fi

    # Раскомментируем и обновляем mss_bulk
    if [ -n "$has_mss_bulk" ]; then
        sed -i 's/^[[:space:]]*#[[:space:]]*mss_bulk[[:space:]]*=.*/mss_bulk = '"$mss_bulk_value"'/' "$config_path"
        changed=1
    else
        # Добавляем в секцию server
        if grep -q '^\[server\]' "$config_path"; then
            sed -i '/^\[server\]/a mss_bulk = '"$mss_bulk_value"'' "$config_path"
            changed=1
        else
            if ! grep -q '^\[server\]' "$config_path"; then
                echo "" >> "$config_path"
                echo "[server]" >> "$config_path"
            fi
            echo "mss_bulk = $mss_bulk_value" >> "$config_path"
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
            if systemctl restart telemt 2>/dev/null; then
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
    echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
    { read -rsn1 </dev/tty; } 2>/dev/null || true
}

# ── ОТКЛЮЧЕНИЕ MSS, MSS_BULK И SYN_LIMIT ───────────────────
disable_bad_options() {
    local config_path=$(get_config_path)
    if [ -z "$config_path" ] || [ ! -f "$config_path" ]; then
        echo ""
        echo -e "  ${RED}[✗]${NC} Файл конфига не найден или не указан"
        echo ""
        echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
        { read -rsn1 </dev/tty; } 2>/dev/null || true
        return 1
    fi

    local changed=0

    if grep -E '^[[:space:]]*client_mss[[:space:]]*=' "$config_path" | grep -v '^#' | grep -q .; then
        sed -i 's/^[[:space:]]*client_mss[[:space:]]*=.*/#client_mss = 0/' "$config_path"
        changed=1
    fi

    if grep -E '^[[:space:]]*mss_bulk[[:space:]]*=' "$config_path" | grep -v '^#' | grep -q .; then
        sed -i 's/^[[:space:]]*mss_bulk[[:space:]]*=.*/#mss_bulk = 0/' "$config_path"
        changed=1
    fi

    if grep -E '^[[:space:]]*synlimit[[:space:]]*=' "$config_path" | grep -v '^#' | grep -q .; then
        sed -i 's/^[[:space:]]*synlimit[[:space:]]*=.*/#synlimit = 0/' "$config_path"
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
    echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
    { read -rsn1 </dev/tty; } 2>/dev/null || true
}

# ── УПРАВЛЕНИЕ MSS В КОНФИГЕ ──────────────────────────────
manage_mss() {
    local config_path=$(get_config_path)
    if [ -z "$config_path" ] || [ ! -f "$config_path" ]; then
        echo ""
        echo -e "  ${RED}[✗]${NC} Файл конфига не найден или не указан"
        echo ""
        echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
        { read -rsn1 </dev/tty; } 2>/dev/null || true
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
            echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
            { read -rsn1 </dev/tty; } 2>/dev/null || true
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
            echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
            { read -rsn1 </dev/tty; } 2>/dev/null || true
        fi
    fi
}

# ── Генерация секрета пользователя ───────────────────────────
_gen_secret() {
    local sec=""
    if command -v openssl >/dev/null 2>&1; then
        sec=$(openssl rand -hex 16 2>/dev/null)
    fi
    if [ -z "$sec" ] && command -v od >/dev/null 2>&1; then
        sec=$(head -c 16 /dev/urandom 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n')
    fi
    if [ -z "$sec" ] && command -v sha256sum >/dev/null 2>&1; then
        sec=$((date +%s%N 2>/dev/null; printf '%s' "$RANDOM$RANDOM$RANDOM") | sha256sum 2>/dev/null | cut -c1-32)
    fi
    printf '%s' "$sec"
}

# ── Проверка TOML-конфига: 0=ok, 1=ошибка, 2=проверка недоступна ──
_verify_toml() {
    local cfg="$1"
    if command -v telemt >/dev/null 2>&1 && telemt --help 2>&1 | grep -qiE '(^|[[:space:]])verify([[:space:]]|$)'; then
        if telemt --config "$cfg" verify >/dev/null 2>&1; then
            return 0
        fi
        return 1
    fi
    if command -v python3 >/dev/null 2>&1 && python3 -c 'import tomllib' >/dev/null 2>&1; then
        if python3 -c 'import tomllib,sys; tomllib.load(open(sys.argv[1],"rb"))' "$cfg" >/dev/null 2>&1; then
            return 0
        fi
        return 1
    fi
    return 2
}

# ── Разбор спецификаций пользователей из одной строки ────────
# Форматы: user | u1 u2 u3 | u1,u2,u3 | u1:secret | u2=secret | u3 <32hex>
# Печатает записи "OK<TAB>имя<TAB>секрет" либо "ERR<TAB>сообщение".
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

# ── Добавление пользователей в [access.users] ────────────────
add_users_to_config() {
    local raw="$1"
    local cfg=""
    cfg=$(get_config_path)
    if [ -z "$cfg" ] || [ ! -f "$cfg" ]; then
        echo -e "  ${RED}[x]${NC} Конфиг telemt не найден"
        return 1
    fi

    if grep -qE '^[[:space:]]*\[\[access\.users\]\]' "$cfg"; then
        echo -e "  ${RED}[x]${NC} Обнаружен нестандартный формат [[access.users]] — правьте вручную"
        return 1
    fi

    local -a names=() secrets=()
    local seen=" " _line _rest _name _secret
    while IFS= read -r _line; do
        case "$_line" in
            ERR*) echo -e "  ${RED}[x]${NC} ${_line#ERR$'\t'}"; continue ;;
            OK*) : ;;
            *) continue ;;
        esac
        _rest="${_line#OK$'\t'}"
        _name="${_rest%%$'\t'*}"
        _secret="${_rest#*$'\t'}"
        if ! [[ "$_name" =~ ^[A-Za-z0-9_.-]{1,32}$ ]]; then
            echo -e "  ${RED}[x]${NC} Недопустимое имя: '$_name' (латиница/цифры/._-, 1..32)"
            continue
        fi
        if [ -z "$_secret" ]; then
            echo -e "  ${RED}[x]${NC} Пустой секрет для '$_name'"
            continue
        fi
        if ! [[ "$_secret" =~ ^[0-9a-fA-F]{32}$ || "$_secret" =~ ^[0-9a-fA-F]{64}$ ]]; then
            echo -e "  ${RED}[x]${NC} Недопустимый секрет для '$_name': нужен 32- или 64-символьный hex"
            continue
        fi
        case "$seen" in
            *" $_name "*) echo -e "  ${YELLOW}[!]${NC} '$_name' повторяется во вводе — пропуск"; continue ;;
        esac
        seen="${seen}${_name} "
        names+=("$_name")
        secrets+=("$_secret")
    done < <(_parse_user_specs "$raw")

    if [ "${#names[@]}" -eq 0 ]; then
        echo -e "  ${YELLOW}[!]${NC} Нет корректных пользователей для добавления"
        return 1
    fi

    local -a add_names=() add_secrets=()
    local _i
    for _i in "${!names[@]}"; do
        if grep -qE "^[[:space:]]*${names[$_i]}[[:space:]]*=" "$cfg"; then
            echo -e "  ${YELLOW}[!]${NC} Пользователь '${names[$_i]}' уже есть — секрет не изменён"
            continue
        fi
        add_names+=("${names[$_i]}")
        add_secrets+=("${secrets[$_i]}")
    done

    if [ "${#add_names[@]}" -eq 0 ]; then
        echo -e "  ${GREEN}[✓]${NC} Все пользователи уже присутствуют — изменений нет"
        return 0
    fi

    local backup="${cfg}.bak.$(date +%Y%m%d-%H%M%S)"
    if ! cp -a "$cfg" "$backup" 2>/dev/null; then
        echo -e "  ${RED}[x]${NC} Не удалось создать бэкап $backup"
        return 1
    fi
    echo -e "  ${DIM}Бэкап конфига: ${backup}${NC}"

    local add_block=""
    for _i in "${!add_names[@]}"; do
        add_block="${add_block}${add_names[$_i]} = \"${add_secrets[$_i]}\""$'\n'
    done

    local tmp_cfg="${cfg}.tmp.$$"
    if grep -qE '^[[:space:]]*\[access\.users\][[:space:]]*$' "$cfg"; then
        if ! awk -v block="$add_block" '
            { print }
            /^[[:space:]]*\[access\.users\][[:space:]]*$/ { printf "%s", block }
        ' "$cfg" > "$tmp_cfg" 2>/dev/null; then
            rm -f "$tmp_cfg"
            echo -e "  ${RED}[x]${NC} Не удалось записать конфиг"
            return 1
        fi
    else
        if ! { printf '\n[access.users]\n'; printf '%s' "$add_block"; } > "$tmp_cfg" 2>/dev/null; then
            rm -f "$tmp_cfg"
            echo -e "  ${RED}[x]${NC} Не удалось подготовить секцию [access.users]"
            return 1
        fi
        if ! cat "$tmp_cfg" >> "$cfg" 2>/dev/null; then
            rm -f "$tmp_cfg"
            echo -e "  ${RED}[x]${NC} Не удалось обновить конфиг"
            return 1
        fi
        rm -f "$tmp_cfg"
        tmp_cfg=""
    fi

    if [ -n "$tmp_cfg" ]; then
        if ! cat "$tmp_cfg" > "$cfg" 2>/dev/null; then
            rm -f "$tmp_cfg"
            echo -e "  ${RED}[x]${NC} Не удалось записать конфиг"
            return 1
        fi
        rm -f "$tmp_cfg"
    fi

    local vrc=0
    _verify_toml "$cfg" || vrc=$?
    if [ "$vrc" -eq 1 ]; then
        echo -e "  ${RED}[x]${NC} Проверка TOML не пройдена — восстанавливаю бэкап"
        cp -a "$backup" "$cfg" 2>/dev/null || true
        return 1
    elif [ "$vrc" -eq 2 ]; then
        echo -e "  ${YELLOW}[!]${NC} Проверка TOML недоступна — пропущена"
    fi

    echo -e "  ${GREEN}[✓]${NC} Добавлено пользователей: ${#add_names[@]}"
    if systemctl restart telemt >/dev/null 2>&1 && systemctl is-active --quiet telemt 2>/dev/null; then
        echo -e "  ${GREEN}[✓]${NC} telemt перезапущен и активен"
    else
        echo -e "  ${YELLOW}[!]${NC} Не удалось подтвердить активность telemt — проверьте: systemctl status telemt"
    fi

    for _i in "${!add_names[@]}"; do
        print_user_links "${add_names[$_i]}" "${add_secrets[$_i]}"
    done
    return 0
}

# ── Меню: добавить пользователя(ей) ──────────────────────────
add_users_menu() {
    echo ""
    echo -e "  ${BOLD}Добавление пользователей Telemt${NC}"
    echo -e "  ${DIM}Форматы: user | u1 u2 u3 | u1,u2,u3 | u1:секрет | u2=секрет | u3 <32hex>${NC}"
    echo -e "  ${DIM}Пустая строка или q — выход${NC}"
    echo ""
    while true; do
        echo -en "  ${BOLD}Имена:${NC} "
        local raw=""
        if ! { read -r raw </dev/tty; } 2>/dev/null; then
            echo ""
            echo -e "  ${GRAY}Отмена${NC}"
            return 1
        fi
        case "$raw" in
            ""|q|Q)
                echo -e "  ${GRAY}Выход${NC}"
                return 0
                ;;
        esac
        add_users_to_config "$raw" || true
        echo ""
    done
}

# ── Получение шаблона WEB-конфига ────────────────────────────
# ── WEB: путь внутри домена и отчёты bridge ───────────────────
# Минимальная версия telemt, поддерживающая base_path у vhost.
WEB_PATH_MIN_VERSION="3.5.8"

# _ver_ge <have> <need> → 0, если have >= need (покомпонентно, 3 поля)
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

# _web_is_valid_path <path> → 0/1. Сегменты [A-Za-z0-9][A-Za-z0-9_-]* через '/'.
_web_is_valid_path() {
    local p="$1"
    [ -n "$p" ] || return 0
    [ "${#p}" -le 128 ] || return 1
    [[ "$p" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*(/[A-Za-z0-9][A-Za-z0-9_-]*)*$ ]]
}

# Печатает изменённый TOML в stdout. hdr — точный заголовок блока после
# trim (напр. '[[web.vhosts]]' или '[web.debug]'); val — готовое значение
# (для строк — вместе с кавычками). Пустое val удаляет ключ. app=1 создаёт
# блок в конце файла, если его нет. Возврат 3 — блока нет и app != 1.
_toml_set_in_table() {
    local cfg="$1" hdr="$2" key="$3" val="$4" app="${5:-0}"
    awk -v hdr="$hdr" -v key="$key" -v val="$val" -v app="$app" '
    function trim(s){ gsub(/^[[:space:]]+|[[:space:]]+$/,"",s); return s }
    function emit(){ if (val != "") print key " = " val }
    BEGIN { inblk=0; found=0; kdone=0 }
    {
        t=trim($0)
        if (!inblk && t == hdr) { inblk=1; found=1; print; next }
        if (inblk && t ~ /^\[/) {
            if (!kdone) { emit(); kdone=1 }
            inblk=0; print; next
        }
        if (inblk && trim($0) ~ ("^" key "[[:space:]]*=")) {
            emit(); kdone=1; next
        }
        print
    }
    END {
        if (inblk && !kdone) { emit() }
        if (!found) {
            if (app == "1" && val != "") { print ""; print hdr; print key " = " val }
            else if (val != "") { exit 3 }
        }
    }
    ' "$cfg"
}

# Бэкап + запись нового содержимого + verify + откат при невалидном TOML,
# затем рестарт telemt и проверка активности.
_web_apply_edit() {
    local cfg="$1" newfile="$2"
    local backup="${cfg}.bak.$(date +%Y%m%d-%H%M%S)"
    if ! cp -a "$cfg" "$backup" 2>/dev/null; then
        echo -e "  ${RED}[x]${NC} Не удалось создать бэкап $backup"
        return 1
    fi
    cat "$newfile" > "$cfg"
    local vrc=0
    _verify_toml "$cfg" || vrc=$?
    if [ "$vrc" -eq 1 ]; then
        cp -a "$backup" "$cfg" 2>/dev/null || true
        echo -e "  ${RED}[x]${NC} TOML невалиден — бэкап восстановлен"
        return 1
    fi
    [ "$vrc" -eq 2 ] && echo -e "  ${YELLOW}[!]${NC} Проверка TOML недоступна — пропущена"
    echo -e "  ${DIM}Бэкап: ${backup}${NC}"
    if systemctl restart telemt >/dev/null 2>&1 && systemctl is-active --quiet telemt 2>/dev/null; then
        echo -e "  ${GREEN}[✓]${NC} telemt перезапущен и активен"
    else
        echo -e "  ${YELLOW}[!]${NC} Не удалось подтвердить активность telemt"
    fi
    return 0
}

# Записать base_path в первый [[web.vhosts]], пустой путь — в корень.
_web_set_base_path() {
    local cfg="$1" path="$2"
    local tmp="${cfg}.tmp.$$" val=""
    [ -n "$path" ] && val="\"$path\""
    if ! _toml_set_in_table "$cfg" "[[web.vhosts]]" "base_path" "$val" "0" > "$tmp"; then
        rm -f "$tmp"; return 3
    fi
    if ! _web_apply_edit "$cfg" "$tmp"; then rm -f "$tmp"; return 1; fi
    rm -f "$tmp"; return 0
}

# Включить/выключить отчёты bridge: sideband (и enabled) в [web.debug].
_web_set_sideband() {
    local cfg="$1" mode="$2"
    local t1="${cfg}.t1.$$" t2="${cfg}.t2.$$"
    if [ "$mode" = "off" ]; then
        grep -qE '^[[:space:]]*\[web\.debug\][[:space:]]*$' "$cfg" || return 2
        _toml_set_in_table "$cfg" "[web.debug]" "sideband" "false" "1" > "$t1" || { rm -f "$t1"; return 1; }
    else
        _toml_set_in_table "$cfg" "[web.debug]" "enabled" "true" "1" > "$t1" || { rm -f "$t1"; return 1; }
        _toml_set_in_table "$t1" "[web.debug]" "sideband" "true" "1" > "$t2" || { rm -f "$t1" "$t2"; return 1; }
        rm -f "$t1"; t1="$t2"
    fi
    if ! _web_apply_edit "$cfg" "$t1"; then rm -f "$t1" "$t2"; return 1; fi
    rm -f "$t1" "$t2"; return 0
}

# _web_make_link <host> <path> <secret_hex> <dd>
# Корень: secret=dd<hex>/<hex>. Под путём: server=host%2Fpath%2F и
# secret=base64url( 0x70 [0xdd] + сырые байты секрета ).
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

# Печатает host<TAB>path<TAB>user<TAB>secret_mode<TAB>secret<TAB>sideband
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

_web_path_menu() {
    local cfg="$1" host path user mode secret sideband cur ver
    IFS='|' read -r host path user mode secret sideband < <(_web_parse_cfg "$cfg")
    cur="$path"
    echo ""
    echo -e "  ${BOLD}Путь WEB внутри домена${NC}"
    echo -e "  ${DIM}Пусто — корень домена (ссылка без пути). Пример: app/sync${NC}"
    echo -en "  ${BOLD}Путь [${cur:-корень}]:${NC} "
    local newp=""
    { read -r newp </dev/tty; } 2>/dev/null || { echo; return 1; }
    newp="$(printf '%s' "$newp" | tr -d '[:space:]')"
    newp="${newp#/}"; newp="${newp%/}"
    if [ -n "$newp" ] && ! _web_is_valid_path "$newp"; then
        echo -e "  ${RED}[x]${NC} Некорректный путь: '${newp}'"
        return 1
    fi
    if [ -n "$newp" ]; then
        ver=$(get_telemt_version 2>/dev/null)
        if ! _ver_ge "$ver" "$WEB_PATH_MIN_VERSION"; then
            echo -e "  ${RED}[x]${NC} Движок telemt не поддерживает путь внутри домена."
            echo -e "  ${YELLOW}Нужен telemt ${WEB_PATH_MIN_VERSION}+, установлен ${ver:-неизвестно}. Путь НЕ записан.${NC}"
            return 1
        fi
    fi
    if ! grep -qE '^[[:space:]]*\[\[web\.vhosts\]\][[:space:]]*$' "$cfg"; then
        echo -e "  ${RED}[x]${NC} В конфиге нет [[web.vhosts]] — сначала установите WEB-прокси [1]"
        return 1
    fi
    if ! _web_set_base_path "$cfg" "$newp"; then
        return 1
    fi
    echo -e "  ${GREEN}[✓]${NC} Путь WEB: ${newp:-корень}"
    return 0
}

_web_reports_menu() {
    local cfg="$1" host path user mode secret sideband
    IFS='|' read -r host path user mode secret sideband < <(_web_parse_cfg "$cfg")
    echo ""
    local ans=""
    if [ "$sideband" = "true" ]; then
        echo -e "  ${BOLD}Отчёты bridge:${NC} ${GREEN}включены${NC}"
        echo -en "  ${BOLD}Выключить? [y/N]:${NC} "
        { read -r ans </dev/tty; } 2>/dev/null || { echo; return 1; }
        case "$ans" in y|Y|yes|YES) : ;; *) echo -e "  ${GRAY}Отменено${NC}"; return 0 ;; esac
        local rc=0
        _web_set_sideband "$cfg" off || rc=$?
        if [ "$rc" -eq 2 ]; then echo -e "  ${DIM}Уже выключено${NC}"; return 0; fi
        [ "$rc" -eq 0 ] || return 1
        echo -e "  ${GREEN}[✓]${NC} Отчёты bridge выключены"
    else
        echo -e "  ${BOLD}Отчёты bridge:${NC} ${DIM}выключены${NC}"
        echo -e "  ${DIM}Ключи: enabled + sideband в [web.debug]${NC}"
        echo -en "  ${BOLD}Включить? [y/N]:${NC} "
        { read -r ans </dev/tty; } 2>/dev/null || { echo; return 1; }
        case "$ans" in y|Y|yes|YES) : ;; *) echo -e "  ${GRAY}Отменено${NC}"; return 0 ;; esac
        _web_set_sideband "$cfg" on || return 1
        echo -e "  ${GREEN}[✓]${NC} Отчёты bridge включены"
    fi
    return 0
}

_web_show_link() {
    local cfg="$1" host path user mode secret sideband dd=0
    IFS='|' read -r host path user mode secret sideband < <(_web_parse_cfg "$cfg")
    if [ -z "$user" ] || [ -z "$secret" ]; then
        echo -e "  ${RED}[x]${NC} Не удалось определить пользователя/секрет WEB в конфиге"
        return 1
    fi
    [ "$mode" = "dd" ] && dd=1
    # Гейт версии движка: путь внутри домена действует только на telemt >= WEB_PATH_MIN_VERSION.
    # Иначе игнорируем path из конфига и строим КОРНЕВУЮ ссылку (иначе пользователь
    # получает нерабочую ссылку с путём на старом движке / после отката).
    if [ -n "$path" ]; then
        local ver=""
        ver=$(get_telemt_version 2>/dev/null)
        if ! _ver_ge "$ver" "$WEB_PATH_MIN_VERSION"; then
            path=""
            echo -e "  ${YELLOW}Движок ${ver:-неизвестной версии} не поддерживает путь внутри домена — ссылка без пути (нужен telemt ${WEB_PATH_MIN_VERSION}+).${NC}"
        fi
    fi
    echo ""
    echo -e "  ${BOLD}WEB-ссылка:${NC}"
    echo -e "  ${CYAN}$(_web_make_link "$host" "$path" "$secret" "$dd")${NC}"
    echo ""
    echo -e "  ${DIM}server=${host}${path:+, path=/${path}}, secret=$( [ "$dd" = 1 ] && printf 'base64url(0x70 0xdd + secret)' || printf 'base64url(0x70 + secret)' )${NC}"
    return 0
}

_get_web_template() {
    local dest="$1"
    local script_dir=""
    script_dir=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
    local local_tpl=""
    if [ -n "$script_dir" ] && [ -s "$script_dir/../data/webconfig.txt" ]; then
        local_tpl="$script_dir/../data/webconfig.txt"
    elif [ -s /opt/mtpr-simple/data/webconfig.txt ]; then
        local_tpl="/opt/mtpr-simple/data/webconfig.txt"
    fi
    if [ -n "$local_tpl" ] && [ -s "$local_tpl" ]; then
        if cp -f "$local_tpl" "$dest" 2>/dev/null && [ -s "$dest" ]; then
            return 0
        fi
    fi
    local -a urls=()
    local base="${EXTRA_BASE_URL:-${BASE_URL:-}}"
    if [ -n "$base" ]; then
        urls+=("${base%/}/data/webconfig.txt")
    fi
    urls+=("https://raw.githubusercontent.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/main/data/webconfig.txt")
    local u=""
    for u in "${urls[@]}"; do
        if curl -fsSL --max-time 20 "$u" -o "$dest" 2>/dev/null && [ -s "$dest" ]; then
            return 0
        fi
    done
    return 1
}

# ── Установка/настройка nginx для WEB-режима (с откатом) ─────
_web_install_nginx() {
    local web_host="$1"

    if ! command -v nginx >/dev/null 2>&1 || ! command -v certbot >/dev/null 2>&1; then
        echo -e "  ${DIM}Установка nginx и certbot...${NC}"
        if command -v apt-get >/dev/null 2>&1; then
            DEBIAN_FRONTEND=noninteractive apt-get update -qq || true
            if ! DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nginx certbot python3-certbot-nginx; then
                echo -e "  ${RED}[x]${NC} Не удалось установить nginx/certbot"
                return 1
            fi
        elif command -v dnf >/dev/null 2>&1; then
            if ! dnf install -y -q nginx certbot python3-certbot-nginx; then
                echo -e "  ${RED}[x]${NC} Не удалось установить nginx/certbot"
                return 1
            fi
        elif command -v yum >/dev/null 2>&1; then
            if ! yum install -y -q nginx certbot python3-certbot-nginx; then
                echo -e "  ${RED}[x]${NC} Не удалось установить nginx/certbot"
                return 1
            fi
        else
            echo -e "  ${RED}[x]${NC} Не удалось определить пакетный менеджер"
            return 1
        fi
    fi

    local nginx_conf="/etc/nginx/sites-available/default"
    local nginx_bak=""
    if [ -f "$nginx_conf" ]; then
        nginx_bak="${nginx_conf}.bak.$(date +%Y%m%d-%H%M%S)"
        cp -a "$nginx_conf" "$nginx_bak" 2>/dev/null || nginx_bak=""
    fi

    local nginx_was_active=false
    if systemctl is-active --quiet nginx 2>/dev/null; then
        nginx_was_active=true
    fi

    mkdir -p /var/lib/telemt/public 2>/dev/null || true
    echo "OK" > /var/lib/telemt/public/index.html 2>/dev/null || true

    echo -e "  ${DIM}Получение SSL-сертификата для ${web_host}...${NC}"
    sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1 || true
    sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1 || true
    local cert_ok=false
    if certbot --nginx -d "$web_host" --non-interactive --agree-tos --email "admin@$web_host" >/dev/null 2>&1; then
        cert_ok=true
    else
        systemctl stop nginx >/dev/null 2>&1 || true
        if certbot certonly --standalone -d "$web_host" --non-interactive --agree-tos --email "admin@$web_host" >/dev/null 2>&1; then
            cert_ok=true
        fi
    fi
    sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1 || true
    sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1 || true

    if [ "$cert_ok" != true ]; then
        echo -e "  ${RED}[x]${NC} Не удалось получить SSL-сертификат для $web_host"
        if [ -n "$nginx_bak" ] && [ -f "$nginx_bak" ]; then
            cp -a "$nginx_bak" "$nginx_conf" 2>/dev/null || true
        fi
        if [ "$nginx_was_active" = true ]; then
            systemctl start nginx >/dev/null 2>&1 || true
        fi
        return 1
    fi
    echo -e "  ${GREEN}[✓]${NC} SSL-сертификат получен"

    cat > "$nginx_conf" <<EOF
map \$http_upgrade \$telemt_connection_upgrade {
    default upgrade;
    ''      '';
}

upstream telemt_web {
    server 127.0.0.1:18080;
    keepalive 64;
}

server {
    listen 443 ssl http2;
    server_name $web_host;

    ssl_certificate     /etc/letsencrypt/live/$web_host/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$web_host/privkey.pem;

    client_max_body_size 2m;
    access_log off;

    location / {
        proxy_pass http://telemt_web;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$telemt_connection_upgrade;

        proxy_connect_timeout 5s;
        proxy_send_timeout 65s;
        proxy_read_timeout 65s;
        proxy_request_buffering off;
        proxy_buffering off;
        proxy_next_upstream off;
    }
}
EOF

    if ! nginx -t >/dev/null 2>&1; then
        echo -e "  ${RED}[x]${NC} Конфигурация nginx невалидна — откат"
        if [ -n "$nginx_bak" ] && [ -f "$nginx_bak" ]; then
            cp -a "$nginx_bak" "$nginx_conf" 2>/dev/null || true
        fi
        systemctl restart nginx >/dev/null 2>&1 || true
        return 1
    fi
    if ! systemctl restart nginx >/dev/null 2>&1; then
        echo -e "  ${RED}[x]${NC} Не удалось перезапустить nginx"
        return 1
    fi
    echo -e "  ${GREEN}[✓]${NC} nginx настроен для $web_host"
    return 0
}

# ── Меню: установка WEB-прокси ───────────────────────────────
# ── WEB-прокси: меню (установка, путь, отчёты, ссылка) ────────
web_proxy_menu() {
    local cfg=""
    while true; do
        cfg=$(get_config_path)
        clear 2>/dev/null || true
        echo ""
        echo -e "  ${BOLD}WEB-прокси Telemt${NC}"
        echo -e "  ${DIM}===========================${NC}"
        if [ -z "$cfg" ] || [ ! -f "$cfg" ]; then
            echo -e "  ${RED}[x]${NC} Конфиг telemt не найден — сначала установите Telemt"
            echo -e "  ${GRAY}Нажмите любую клавишу для возврата${NC}"
            { read -rsn1 </dev/tty; } 2>/dev/null || true
            return 1
        fi
        _web_print_status "$cfg"
        echo ""
        echo -e "  ${CYAN}[1]${NC}  ${BOLD}Установить/переустановить WEB-прокси (nginx + конфиг)${NC}"
        echo -e "  ${CYAN}[p]${NC}  ${BOLD}Путь WEB внутри домена${NC}"
        echo -e "  ${CYAN}[r]${NC}  ${BOLD}Отчёты bridge-страницы: вкл/выкл${NC}"
        echo -e "  ${CYAN}[s]${NC}  ${BOLD}Показать WEB-ссылку${NC}"
        echo ""
        echo -e "  ${RED}[0]${NC}  ${BOLD}Назад${NC}"
        echo ""
        echo -en "  ${BOLD}Выбор:${NC} "
        local wchoice=""
        { read -r wchoice </dev/tty; } 2>/dev/null || { echo; return 1; }
        case "$wchoice" in
            1) _web_proxy_install || true ;;
            p|P) _web_path_menu "$cfg" || true ;;
            r|R) _web_reports_menu "$cfg" || true ;;
            s|S) _web_show_link "$cfg" || true ;;
            0 | "") return 0 ;;
            *) echo "  Неверный выбор"; sleep 0.1 ;;
        esac
    done
}

# ── WEB-прокси: установка (мастер) ────────────────────────────
_web_proxy_install() {
    local cfg=""
    cfg=$(get_config_path)
    if [ -z "$cfg" ] || [ ! -f "$cfg" ]; then
        echo -e "  ${RED}[x]${NC} Конфиг telemt не найден — сначала установите Telemt"
        return 1
    fi

    echo ""
    echo -e "  ${BOLD}Установка WEB-прокси Telemt${NC}"
    echo ""

    echo -en "  ${BOLD}Домен (A-запись должна указывать на этот сервер):${NC} "
    local web_host=""
    { read -r web_host </dev/tty; } 2>/dev/null || { echo ""; return 1; }
    web_host="$(printf '%s' "$web_host" | tr -d '[:space:]')"
    if ! [[ "$web_host" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then
        echo -e "  ${RED}[x]${NC} Некорректный домен: '$web_host'"
        return 1
    fi

    echo -en "  ${BOLD}Имя пользователя${NC} ${DIM}[webuser]${NC}${BOLD}:${NC} "
    local web_user=""
    { read -r web_user </dev/tty; } 2>/dev/null || true
    web_user="$(printf '%s' "$web_user" | tr -d '[:space:]')"
    [ -n "$web_user" ] || web_user="webuser"
    if ! [[ "$web_user" =~ ^[A-Za-z0-9_.-]{1,32}$ ]]; then
        echo -e "  ${RED}[x]${NC} Некорректное имя пользователя"
        return 1
    fi

    echo -en "  ${BOLD}Секрет${NC} ${DIM}[Enter — сгенерировать]${NC}${BOLD}:${NC} "
    local web_secret=""
    { read -r web_secret </dev/tty; } 2>/dev/null || true
    web_secret="$(printf '%s' "$web_secret" | tr -d '[:space:]')"
    if [ -z "$web_secret" ]; then
        web_secret="$(_gen_secret)"
        echo -e "  ${DIM}Сгенерирован секрет: ${web_secret}${NC}"
    fi

    echo -en "  ${BOLD}Ставить nginx + SSL (certbot)? [y/N]:${NC} "
    local use_nginx=""
    { read -r use_nginx </dev/tty; } 2>/dev/null || true
    local do_nginx=false
    case "$use_nginx" in y|Y|yes|YES) do_nginx=true ;; esac

    if ss -tlnH 2>/dev/null | grep -q ':443 ' || netstat -tlnH 2>/dev/null | grep -q ':443 '; then
        echo -e "  ${YELLOW}[!]${NC} Порт 443 уже занят. В WEB-режиме его занимает nginx —"
        echo -e "  ${YELLOW}[!]${NC} обычный telemt-прокси на 443 работать не будет (конфликт)."
    fi

    echo ""
    echo -e "  ${RED}${BOLD}ВНИМАНИЕ:${NC} WEB-конфиг ЗАМЕНЯЕТ ${cfg} ЦЕЛИКОМ."
    echo -e "  ${RED}Существующие пользователи и настройки будут потеряны.${NC}"
    echo -en "  ${BOLD}Продолжить? [y/N]:${NC} "
    local confirm=""
    { read -r confirm </dev/tty; } 2>/dev/null || true
    case "$confirm" in y|Y|yes|YES) : ;; *) echo -e "  ${GRAY}Отменено${NC}"; return 0 ;; esac

    local backup="${cfg}.bak.$(date +%Y%m%d-%H%M%S)"
    if ! cp -a "$cfg" "$backup" 2>/dev/null; then
        echo -e "  ${RED}[x]${NC} Не удалось создать бэкап $backup"
        return 1
    fi
    echo -e "  ${DIM}Бэкап: ${backup}${NC}"

    local tpl="/tmp/webconfig.$$"
    if ! _get_web_template "$tpl"; then
        echo -e "  ${RED}[x]${NC} Не удалось получить data/webconfig.txt"
        rm -f "$tpl"
        return 1
    fi

    local web_ip=""
    web_ip=$(get_public_ip)
    [ -n "$web_ip" ] || web_ip=$(curl -4 -fsS --max-time 4 https://api.ipify.org 2>/dev/null)
    if [ -z "$web_ip" ]; then
        echo -e "  ${RED}[x]${NC} Не удалось определить внешний IP"
        rm -f "$tpl"
        return 1
    fi

    if [ "$do_nginx" = true ]; then
        if ! _web_install_nginx "$web_host"; then
            echo -e "  ${RED}[x]${NC} Настройка nginx не удалась — конфиг telemt не изменён"
            rm -f "$tpl"
            return 1
        fi
    fi

    local content=""
    content=$(cat "$tpl")
    content="${content//\"zdez.tvoi.domen.com\"/\"$web_host\"}"
    content="${content//\"12.34.56.789:443\"/\"$web_ip:443\"}"
    content="${content//hello = \"e5544cb710bae52b8bcbc05375921c16\"/hello = \"$web_secret\"}"
    if [ "$web_user" != "hello" ]; then
        content="${content//hello = /$web_user = }"
        content="${content//links_show = \[\"hello\"\]/links_show = [\"$web_user\"]}"
        content="${content//user = \"hello\"/user = \"$web_user\"}"
    fi
    printf '%s\n' "$content" > "$cfg"
    rm -f "$tpl"

    local vrc=0
    _verify_toml "$cfg" || vrc=$?
    if [ "$vrc" -eq 1 ]; then
        echo -e "  ${RED}[x]${NC} TOML невалиден — восстанавливаю бэкап"
        cp -a "$backup" "$cfg" 2>/dev/null || true
        return 1
    fi

    if systemctl restart telemt >/dev/null 2>&1 && systemctl is-active --quiet telemt 2>/dev/null; then
        echo -e "  ${GREEN}[✓]${NC} telemt перезапущен и активен"
    else
        echo -e "  ${YELLOW}[!]${NC} Не удалось подтвердить активность telemt"
    fi

    local _dd=0 _wpath="" _wh="" _wu="" _wm="" _ws="" _wsb=""
    IFS='|' read -r _wh _wpath _wu _wm _ws _wsb < <(_web_parse_cfg "$cfg")
    [ "$_wm" = "dd" ] && _dd=1
    echo ""
    echo -e "  ${BOLD}WEB-ссылка:${NC}"
    echo -e "  ${CYAN}$(_web_make_link "$web_host" "$_wpath" "$web_secret" "$_dd")${NC}"
    echo ""
    echo -e "  ${DIM}Откройте https://${web_host} в браузере.${NC}"
    return 0
}

# ── Бэкап и восстановление Telemt ─────────────────────────────
# Догрузка панели бэкапа (как ensure_data_script в main.sh), затем
# запуск с --scope telemt. Если установленная версия --scope не
# поддерживает — деградируем в обычный запуск без аргументов.
_ensure_backup_panel() {
    local dest="/opt/mtpr-simple/data/backup_panel.sh"
    if [ -s "$dest" ]; then
        return 0
    fi
    local base="${EXTRA_BASE_URL:-https://raw.githubusercontent.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/main}"
    echo -e "  ${YELLOW}Файл $dest не найден, скачиваю...${NC}"
    mkdir -p "$(dirname "$dest")"
    if curl -fsSL --max-time 20 "$base/data/backup_panel.sh" -o "$dest" && [ -s "$dest" ]; then
        chmod +x "$dest" 2>/dev/null || true
        return 0
    fi
    rm -f "$dest" 2>/dev/null || true
    echo -e "  ${RED}Не удалось получить backup_panel.sh${NC}"
    return 1
}

telemt_backup_menu() {
    if ! _ensure_backup_panel; then
        echo -e "  ${GRAY}Нажмите любую клавишу для возврата${NC}"
        { read -rsn1 </dev/tty; } 2>/dev/null || true
        return 1
    fi
    local panel="/opt/mtpr-simple/data/backup_panel.sh"
    if grep -q -- "--scope" "$panel" 2>/dev/null; then
        bash "$panel" --scope telemt </dev/tty || true
    else
        echo -e "  ${YELLOW}backup_panel.sh без поддержки --scope — открываю полное меню${NC}"
        bash "$panel" </dev/tty || true
    fi
    return 0
}

# ── Неинтерактивное удаление Telemt (--purge-silent) ─────────
# Полное удаление системного и/или docker-варианта Telemt БЕЗ
# единого промпта и без чтения /dev/tty (вызывается из CLI).
# Честный код возврата: 0 — только если Telemt действительно нет.
purge_telemt_silent() {
    echo -e "  ${BLUE}[i]${NC} Неинтерактивное удаление Telemt..."

    local sys_present=0 docker_present=0

    # Автодетект системного Telemt
    if [ -f /etc/systemd/system/telemt.service ] || \
       [ -f /usr/lib/systemd/system/telemt.service ] || \
       [ -f /lib/systemd/system/telemt.service ] || \
       [ -f /usr/bin/telemt ] || \
       [ -f /etc/telemt/telemt.toml ]; then
        sys_present=1
    elif command -v systemctl >/dev/null 2>&1 && systemctl cat telemt >/dev/null 2>&1; then
        sys_present=1
    fi

    # Автодетект docker-варианта (только свои контейнеры/образы)
    if [ -f /root/telemt/docker-compose.yml ]; then
        docker_present=1
    elif command -v docker >/dev/null 2>&1; then
        if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx 'telemt' || \
           docker images --format '{{.Repository}}' 2>/dev/null | grep -q 'telemt'; then
            docker_present=1
        fi
    fi

    if [ "$sys_present" -eq 0 ] && [ "$docker_present" -eq 0 ]; then
        echo -e "  ${DIM}Telemt не обнаружен — нечего удалять${NC}"
        return 0
    fi

    # ── Системный Telemt ──
    if [ "$sys_present" -eq 1 ]; then
        echo -e "  ${BLUE}[i]${NC} Обнаружен системный Telemt — удаляю"
        if command -v systemctl >/dev/null 2>&1; then
            systemctl stop telemt >/dev/null 2>&1 || true
            systemctl disable telemt >/dev/null 2>&1 || true
        fi
        rm -f /etc/systemd/system/telemt.service 2>/dev/null || true
        rm -f /usr/lib/systemd/system/telemt.service 2>/dev/null || true
        rm -f /lib/systemd/system/telemt.service 2>/dev/null || true
        rm -f /usr/bin/telemt 2>/dev/null || true
        rm -rf /etc/telemt 2>/dev/null || true
        if command -v systemctl >/dev/null 2>&1; then
            systemctl daemon-reload >/dev/null 2>&1 || true
        fi
        echo -e "  ${GREEN}[✓]${NC} Системный Telemt удалён"
    fi

    # ── Docker-Telemt ──
    if [ "$docker_present" -eq 1 ] && command -v docker >/dev/null 2>&1; then
        echo -e "  ${BLUE}[i]${NC} Обнаружен Docker-Telemt — удаляю"
        if [ -f /root/telemt/docker-compose.yml ]; then
            ( cd /root/telemt && docker compose down -v ) >/dev/null 2>&1 || true
        fi
        docker rm -f telemt >/dev/null 2>&1 || true
        docker rm -f watchtower >/dev/null 2>&1 || true
        local _ids
        _ids=$(docker images --format '{{.ID}} {{.Repository}}' 2>/dev/null | awk '$2 ~ /telemt/ {print $1}')
        [ -n "$_ids" ] && docker rmi -f $_ids >/dev/null 2>&1 || true
        _ids=$(docker images --format '{{.ID}} {{.Repository}}' 2>/dev/null | awk '$2 ~ /watchtower/ {print $1}')
        [ -n "$_ids" ] && docker rmi -f $_ids >/dev/null 2>&1 || true
        rm -rf /root/telemt 2>/dev/null || true
        echo -e "  ${GREEN}[✓]${NC} Docker-Telemt удалён"
    fi

    # ── Проверка результата (без docker system prune) ──
    local problems=""
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active telemt >/dev/null 2>&1; then
        problems="${problems} служба telemt активна;"
    fi
    [ -f /etc/telemt/telemt.toml ] && problems="${problems} /etc/telemt/telemt.toml на месте;"
    [ -f /usr/bin/telemt ] && problems="${problems} /usr/bin/telemt на месте;"
    if command -v docker >/dev/null 2>&1; then
        if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx 'telemt'; then
            problems="${problems} контейнер telemt существует;"
        fi
        if docker images --format '{{.Repository}}' 2>/dev/null | grep -q 'telemt'; then
            problems="${problems} образ telemt существует;"
        fi
    fi

    if [ -n "$problems" ]; then
        echo -e "  ${RED}[✗]${NC} Telemt удалён не полностью:${problems}"
        return 1
    fi
    echo -e "  ${GREEN}[✓]${NC} Telemt полностью удалён"
    return 0
}

# ══════════════════════════════════════════════════════════════
#  Движок Telemt: кастомная сборка из архива
#  Установка / статус / откат. Состояние — /opt/mtpr-simple/engine.json
# ══════════════════════════════════════════════════════════════
ENGINE_STATE="/opt/mtpr-simple/engine.json"
ENGINE_BACKUP_DIR="/opt/mtpr-simple/engine-backup"

_eng_info(){ echo -e "  ${BLUE}[i]${NC} $1"; }
_eng_ok(){ echo -e "  ${GREEN}[✓]${NC} $1"; }
_eng_err(){ echo -e "  ${RED}[x]${NC} $1"; }
_eng_warn(){ echo -e "  ${YELLOW}[!]${NC} $1"; }

# Путь к текущему бинарю движка: PATH → systemd ExecStart → /usr/bin/telemt
_eng_target() {
    local t="" uf
    t=$(command -v telemt 2>/dev/null)
    if [ -z "$t" ]; then
        for uf in /etc/systemd/system/telemt.service /usr/lib/systemd/system/telemt.service /lib/systemd/system/telemt.service; do
            [ -f "$uf" ] || continue
            t=$(sed -nE 's/^[[:space:]]*ExecStart[[:space:]]*=[[:space:]]*([^[:space:];]+).*/\1/p' "$uf" | head -1)
            [ -n "$t" ] && break
        done
    fi
    [ -n "$t" ] || t="/usr/bin/telemt"
    printf '%s\n' "$t"
}

_eng_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  printf 'x86_64\n' ;;
        aarch64|arm64) printf 'aarch64\n' ;;
        *)             printf '%s\n' "$(uname -m)" ;;
    esac
}

# gnu при glibc >= 2.34, иначе musl (static-pie — безопасный фолбэк)
_eng_abi() {
    local v=""
    v=$(getconf GNU_LIBC_VERSION 2>/dev/null | awk '{print $2}')
    if [ -n "$v" ] && _ver_ge "$v" "2.34"; then printf 'gnu\n'; else printf 'musl\n'; fi
}

# x86-64-v3 только для x86_64 и только при наличии ВСЕХ флагов
_eng_is_v3() {
    [ "$(_eng_arch)" = "x86_64" ] || return 1
    local f
    for f in avx avx2 bmi1 bmi2 fma movbe f16c abm; do
        grep -qw "$f" /proc/cpuinfo 2>/dev/null || return 1
    done
    return 0
}

_eng_asset_name() {
    local arch abi v3=""
    arch=$(_eng_arch); abi=$(_eng_abi)
    if [ "$arch" = "x86_64" ] && _eng_is_v3; then v3="-v3"; fi
    printf 'telemt-%s%s-linux-%s.tar.gz\n' "$arch" "$v3" "$abi"
}

_eng_is_elf() {
    [ -f "$1" ] || return 1
    [ "$(head -c4 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "7f454c46" ]
}

# Проверка ELF-машины (мягкая: без `file` доверяем запуску --version)
_eng_match_arch() {
    local f="$1" arch="$2" out=""
    command -v file >/dev/null 2>&1 || return 0
    out=$(file -b "$f" 2>/dev/null)
    case "$out" in *ELF*) : ;; *) return 1 ;; esac
    case "$arch" in
        x86_64)  printf '%s' "$out" | grep -qE 'x86-64'  || return 1 ;;
        aarch64) printf '%s' "$out" | grep -qE 'aarch64' || return 1 ;;
    esac
    return 0
}

# Запуск бинаря: печатает версию (^telemt <цифра>), rc = rc запуска (132=SIGILL)
_eng_run_version() {
    local out rc
    out=$(timeout 8 "$1" --version 2>&1); rc=$?
    if [ "$rc" -ne 0 ]; then out=$(timeout 8 "$1" -V 2>&1); rc=$?; fi
    [ "$rc" -eq 0 ] || return "$rc"
    printf '%s' "$out" | grep -qE '^telemt [0-9]' || return 1
    printf '%s\n' "$out" | head -1
    return 0
}

_eng_unpack() {
    case "$1" in
        *.tar.gz|*.tgz) tar -xzf "$1" -C "$2" ;;
        *.tar.xz|*.txz) tar -xJf "$1" -C "$2" ;;
        *.tar)          tar -xf  "$1" -C "$2" ;;
        *) return 1 ;;
    esac
}

# Ровно один бинарь: сначала файл `telemt`, иначе единственный executable
_eng_pick_bin() {
    local d="$1" f n=0 cand=""
    if [ -f "$d/telemt" ]; then printf '%s\n' "$d/telemt"; return 0; fi
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        n=$((n+1)); cand="$f"
    done < <(find "$d" -maxdepth 1 -type f -perm -u+x 2>/dev/null)
    [ "$n" -eq 1 ] && [ -n "$cand" ] || return 1
    printf '%s\n' "$cand"
}

_eng_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" 2>/dev/null | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
    else return 1; fi
}

# Контрольная сумма рядом с архивом (<url>.sha256 или checksums.txt)
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

_eng_restart() {
    if command -v systemctl >/dev/null 2>&1 && systemctl cat telemt >/dev/null 2>&1; then
        systemctl restart telemt || return 1
        sleep 1
        systemctl is-active --quiet telemt || return 1
        return 0
    fi
    if command -v docker >/dev/null 2>&1 && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx 'telemt'; then
        docker restart telemt >/dev/null 2>&1 || return 1
        sleep 1
        [ "$(docker inspect -f '{{.State.Running}}' telemt 2>/dev/null)" = "true" ] || return 1
        return 0
    fi
    return 2
}

_eng_state_get() {
    [ -f "$ENGINE_STATE" ] || return 1
    sed -nE "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*/\1/p" "$ENGINE_STATE" | head -1
}

# Запись состояния через tmp+mv (никаких cat > файл)
_eng_write_state() {
    local tmp; tmp=$(mktemp 2>/dev/null) || return 1
    {
        printf '{\n'
        printf '  "source": "%s",\n' "$1"
        printf '  "sha256": "%s",\n' "$2"
        printf '  "arch": "%s",\n' "$3"
        printf '  "version": "%s",\n' "$4"
        printf '  "installed_at": "%s",\n' "$5"
        printf '  "target": "%s",\n' "$6"
        printf '  "backup": "%s"\n' "$7"
        printf '}\n'
    } > "$tmp" || { rm -f "$tmp"; return 1; }
    mkdir -p "$(dirname "$ENGINE_STATE")" 2>/dev/null || true
    mv -f "$tmp" "$ENGINE_STATE"
}

# Распаковать+проверить архив, положить бинарь в $2 → печатает "sha|version"
_eng_prepare() {
    local archive="$1" staged="$2" work bin ver sha r
    work=$(mktemp -d 2>/dev/null) || { _eng_err "mktemp не удалось"; return 1; }
    if ! _eng_unpack "$archive" "$work"; then _eng_err "Не удалось распаковать архив"; rm -rf "$work"; return 1; fi
    if ! bin=$(_eng_pick_bin "$work"); then _eng_err "В архиве нет одного бинаря telemt"; rm -rf "$work"; return 1; fi
    if ! _eng_is_elf "$bin"; then _eng_err "Файл в архиве не ELF"; rm -rf "$work"; return 1; fi
    if ! _eng_match_arch "$bin" "$(_eng_arch)"; then _eng_err "Архитектура бинаря не $(_eng_arch)"; rm -rf "$work"; return 1; fi
    ver=$(_eng_run_version "$bin"); r=$?
    if [ "$r" -ne 0 ]; then rm -rf "$work"; return "$r"; fi
    if ! cp -f "$bin" "$staged" || ! chmod 0755 "$staged" 2>/dev/null; then
        _eng_err "Не удалось подготовить бинарь"; rm -rf "$work"; return 1
    fi
    sha=$(_eng_sha256 "$staged")
    rm -rf "$work"
    printf '%s|%s\n' "$sha" "$ver"
    return 0
}

# engine_install <url|path> [ожидаемый sha256]
engine_install() {
    local src="$1" want_sha="${2:-}"
    [ -n "$src" ] || { _eng_err "Источник не задан"; return 1; }
    local target arch tmp staged archive
    target=$(_eng_target); arch=$(_eng_arch)
    tmp=$(mktemp -d 2>/dev/null) || { _eng_err "mktemp не удалось"; return 1; }
    staged="$tmp/telemt.new"; archive="$tmp/engine.tar.gz"

    local -a urls=() uniq=() ; local u x seen
    case "$src" in
        *.tar.gz|*.tgz|*.tar.xz|*.txz|*.tar|/*|./*|../*)
            urls+=("$src") ;;
        http://*|https://*)
            local primary; primary=$(_eng_asset_name)
            urls+=("${src%/}/$primary")
            case "$primary" in
                *-v3-linux-gnu.tar.gz)  urls+=("${src%/}/telemt-${arch}-linux-gnu.tar.gz");  urls+=("${src%/}/telemt-${arch}-linux-musl.tar.gz") ;;
                *-v3-linux-musl.tar.gz) urls+=("${src%/}/telemt-${arch}-linux-musl.tar.gz") ;;
                *-linux-gnu.tar.gz)     urls+=("${src%/}/telemt-${arch}-linux-musl.tar.gz") ;;
            esac ;;
        *) urls+=("$src") ;;
    esac
    for u in "${urls[@]}"; do
        seen=0
        for x in "${uniq[@]:-}"; do [ "$x" = "$u" ] && { seen=1; break; }; done
        [ "$seen" -eq 0 ] && uniq+=("$u")
    done
    urls=("${uniq[@]}")

    local prepared=0 rc=0 new_sha="" new_ver=""
    for u in "${urls[@]}"; do
        _eng_info "Источник: $u"
        rm -f "$archive" "$staged"
        case "$u" in
            http://*|https://*) curl -fL --max-time 120 --retry 2 -o "$archive" "$u" || { _eng_warn "Не удалось скачать: $u"; continue; } ;;
            *) { [ -f "$u" ] && cp -f "$u" "$archive"; } || { _eng_warn "Файл не найден: $u"; continue; } ;;
        esac
        [ -s "$archive" ] || { _eng_warn "Пустой архив: $u"; continue; }

        local exp="${want_sha:-}" got=""
        if [ -z "$exp" ]; then exp=$(_eng_checksum_for "$u" "$tmp" || true); fi
        got=$(_eng_sha256 "$archive")
        if [ -n "$exp" ]; then
            if [ "$(printf '%s' "$exp" | tr 'A-F' 'a-f')" != "$(printf '%s' "$got" | tr 'A-F' 'a-f')" ]; then
                _eng_err "sha256 архива не совпал (ожидалось ${exp:0:16}…, получено ${got:0:16}…)"
                rm -rf "$tmp"; return 1
            fi
            _eng_info "sha256 совпал: $got"
        else
            _eng_warn "Контрольной суммы нет. Реальный sha256: $got"
            echo -en "  ${BOLD}Продолжить установку? [y/N]:${NC} "
            local ok=""
            { read -r ok </dev/tty; } 2>/dev/null || { echo; rm -rf "$tmp"; return 1; }
            case "$ok" in y|Y|yes|YES) : ;; *) echo -e "  ${GRAY}Отменено${NC}"; rm -rf "$tmp"; return 1 ;; esac
        fi

        local res="" pf prep
        pf=$(mktemp 2>/dev/null) || pf="$tmp/_prepare.log"
        _eng_prepare "$archive" "$staged" >"$pf" 2>&1; rc=$?
        prep=$(cat "$pf" 2>/dev/null); rm -f "$pf"
        res=$(printf '%s\n' "$prep" | grep -E '^[0-9a-f]{64}\|' | head -1)
        if [ -z "$res" ] && [ -n "$prep" ]; then printf '%s\n' "$prep"; fi
        if [ "$rc" -eq 132 ]; then _eng_warn "SIGILL (нет x86-64-v3) — пробую другой ассет"; continue; fi
        if [ "$rc" -eq 126 ] || [ "$rc" -eq 127 ]; then _eng_warn "Бинарь не запускается (rc=$rc) — пробую другой ассет"; continue; fi
        if [ "$rc" -ne 0 ]; then continue; fi
        prepared=1; new_sha="${res%%|*}"; new_ver="${res#*|}"
        break
    done
    if [ "$prepared" -ne 1 ]; then
        _eng_err "Не удалось подготовить движок ни из одного источника"
        rm -rf "$tmp"; return 1
    fi

    # Бэкап текущего движка
    local cur_ver="" backup=""
    if [ -f "$target" ]; then
        cur_ver=$(_eng_run_version "$target" 2>/dev/null || true)
        mkdir -p "$ENGINE_BACKUP_DIR" 2>/dev/null || true
        local bbase bn
        if [ -n "$cur_ver" ]; then
            bbase="$ENGINE_BACKUP_DIR/telemt-$(printf '%s' "$cur_ver" | tr ' /' '__')-$(date +%Y%m%d%H%M%S)"
        else
            bbase="$ENGINE_BACKUP_DIR/telemt-unknown-$(date +%Y%m%d%H%M%S)"
        fi
        bn=0; backup="$bbase"
        while [ -e "$backup" ]; do bn=$((bn+1)); backup="${bbase}-${bn}"; done
        if ! cp -f "$target" "$backup"; then
            _eng_err "Не удалось сохранить бэкап текущего движка"; rm -rf "$tmp"; return 1
        fi
        _eng_info "Бэкап текущего движка: $backup"
    fi

    # Атомарная установка
    local dir; dir=$(dirname "$target")
    mkdir -p "$dir" 2>/dev/null || true
    if ! install -m 0755 "$staged" "$dir/.telemt.new"; then
        _eng_err "Не удалось записать новый движок"; rm -rf "$tmp"; return 1
    fi
    if ! mv -f "$dir/.telemt.new" "$target"; then
        rm -f "$dir/.telemt.new"; _eng_err "Не удалось заменить движок"; rm -rf "$tmp"; return 1
    fi
    _eng_write_state "$src" "$new_sha" "$arch" "$new_ver" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$target" "$backup" || true

    # Перезапуск + автооткат
    _eng_restart; rc=$?
    if [ "$rc" -eq 2 ]; then
        _eng_warn "Юнит/контейнер telemt не найден — перезапуск не требуется"
    elif [ "$rc" -ne 0 ]; then
        _eng_err "Движок не запустился (rc=$rc) — откатываю на бэкап"
        if [ -n "$backup" ] && [ -f "$backup" ]; then
            if install -m 0755 "$backup" "$dir/.telemt.new" && mv -f "$dir/.telemt.new" "$target"; then
                _eng_restart >/dev/null 2>&1 || _eng_warn "Сервис не поднялся и после отката"
                _eng_warn "Возвращён движок ${cur_ver:-неизвестной версии}"
            else
                _eng_err "Откат не удался"
            fi
        else
            _eng_warn "Бэкапа нет — откат невозможен"
        fi
        rm -rf "$tmp"; return 1
    fi

    _eng_ok "Движок обновлён: $new_ver"
    echo -e "  ${DIM}Путь:   $target${NC}"
    echo -e "  ${DIM}sha256: $new_sha${NC}"
    _eng_warn "WEB base_path (путь внутри домена) требует движок ${WEB_PATH_MIN_VERSION}+"
    rm -rf "$tmp"
    return 0
}

engine_status() {
    local target ver sha
    target=$(_eng_target)
    echo ""
    echo -e "  ${BOLD}Движок Telemt${NC}"
    echo -e "  ${DIM}===========================${NC}"
    if [ -f "$target" ]; then
        ver=$(_eng_run_version "$target" 2>/dev/null || true)
        sha=$(_eng_sha256 "$target" 2>/dev/null || true)
        echo -e "  ${BOLD}Путь:${NC} $target"
        echo -e "  ${BOLD}Версия:${NC} ${ver:-не удалось определить}"
        echo -e "  ${BOLD}sha256:${NC} ${sha:-недоступно}"
    else
        echo -e "  ${YELLOW}Бинарь не найден: $target${NC}"
    fi
    if [ -f "$ENGINE_STATE" ]; then
        local src at backup bv
        src=$(_eng_state_get source || true); at=$(_eng_state_get installed_at || true); backup=$(_eng_state_get backup || true)
        echo -e "  ${BOLD}Установлен из:${NC} ${src:-?}"
        echo -e "  ${BOLD}Время:${NC} ${at:-?}"
        if [ -n "$backup" ] && [ -f "$backup" ]; then
            bv=$(_eng_run_version "$backup" 2>/dev/null || echo '?')
            echo -e "  ${BOLD}Бэкап:${NC} $backup (${bv})"
        else
            echo -e "  ${BOLD}Бэкап:${NC} ${DIM}нет${NC}"
        fi
    else
        echo -e "  ${DIM}Состояние ($ENGINE_STATE) отсутствует${NC}"
    fi
    if command -v systemctl >/dev/null 2>&1 && systemctl cat telemt >/dev/null 2>&1; then
        echo -e "  ${BOLD}Сервис:${NC} $(systemctl is-active telemt 2>/dev/null)"
    fi
    echo ""
    return 0
}

engine_rollback() {
    local target backup ver dir
    target=$(_eng_target)
    backup=""
    [ -f "$ENGINE_STATE" ] && backup=$(_eng_state_get backup || true)
    if [ -z "$backup" ] || [ ! -f "$backup" ]; then
        _eng_err "Бэкап движка не найден — откат невозможен"; return 1
    fi
    if ! _eng_is_elf "$backup"; then
        _eng_err "Бэкап повреждён (не ELF): $backup"; return 1
    fi
    ver=$(_eng_run_version "$backup" 2>/dev/null || true)
    dir=$(dirname "$target")
    if ! install -m 0755 "$backup" "$dir/.telemt.new" || ! mv -f "$dir/.telemt.new" "$target"; then
        _eng_err "Не удалось восстановить бэкап"; return 1
    fi
    _eng_restart; local rc=$?
    if [ "$rc" -eq 2 ]; then
        _eng_warn "Юнит/контейнер telemt не найден — перезапуск не требуется"
    elif [ "$rc" -ne 0 ]; then
        _eng_err "Сервис не поднялся после отката (rc=$rc)"; return 1
    fi
    if [ -f "$ENGINE_STATE" ]; then
        local src; src=$(_eng_state_get source || true)
        _eng_write_state "$src" "$(_eng_sha256 "$target")" "$(_eng_arch)" "${ver:-unknown}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$target" "" || true
    fi
    _eng_ok "Откат выполнен: ${ver:-неизвестная версия}"
    return 0
}

engine_menu() {
    local ver c src ans
    while true; do
        clear 2>/dev/null || true
        echo ""
        echo -e "  ${BOLD}Движок Telemt (кастомная сборка из архива)${NC}"
        echo -e "  ${DIM}===========================${NC}"
        ver=$(_eng_run_version "$(_eng_target)" 2>/dev/null || true)
        echo -e "  ${DIM}Текущий движок: ${ver:-не определён}${NC}"
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
                echo -en "  ${BOLD}URL архива или путь:${NC} "
                src=""
                { read -r src </dev/tty; } 2>/dev/null || { echo; break; }
                src=$(printf '%s' "$src" | tr -d '[:space:]')
                if [ -z "$src" ]; then echo -e "  ${GRAY}Отмена${NC}"; sleep 1; continue; fi
                engine_install "$src" || true
                echo -en "  ${DIM}Enter для продолжения...${NC}"
                { read -r ans </dev/tty; } 2>/dev/null || true
                ;;
            2) engine_status || true; echo -en "  ${DIM}Enter...${NC}"; { read -r ans </dev/tty; } 2>/dev/null || true ;;
            3) engine_rollback || true; echo -en "  ${DIM}Enter...${NC}"; { read -r ans </dev/tty; } 2>/dev/null || true ;;
            0) break ;;
            *) echo "  Неверный выбор"; sleep 0.1 ;;
        esac
    done
    return 0
}

# ── Главное меню ─────────────────────────────────────────────
if [ "${BASH_SOURCE[0]}" = "$0" ] && [ $# -eq 0 ]; then
while true; do
    clear 2>/dev/null || true
    echo ""
    echo -e "  ${BOLD}Telemt меню v0.80${NC}"
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
            port_count=$(echo "$ports" | wc -l)
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
        if [ -f "$config_path" ]; then
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
    if [ -f "$config_path" ]; then
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
    echo -e "  ${CYAN}[a]${NC}  ${BOLD}Открыть меню панели Telemt${NC}"
    echo -e "  ${CYAN}[u]${NC}  ${BOLD}Добавить пользователя(ей)${NC}"
    echo -e "  ${CYAN}[w]${NC}  ${BOLD}Установить WEB-прокси (telemt + nginx)${NC}"
    echo -e "  ${CYAN}[b]${NC}  ${BOLD}Бэкап и восстановление Telemt${NC}"
    echo -e "  ${CYAN}[e]${NC}  ${BOLD}Движок Telemt (кастомная сборка из архива)${NC}"
    echo ""
    echo -e "  ${RED}${BOLD}[0]${NC}  ${BOLD}Назад в прокси меню${NC}"
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
            if [ -f "/opt/mtpr-simple/proxys/telemt_panel_amirotin.sh" ]; then
                exec bash /opt/mtpr-simple/proxys/telemt_panel_amirotin.sh
            else
                echo ""
                echo "  [✗] Файл /opt/mtpr-simple/proxys/telemt_panel_amirotin.sh не найден"
                echo -e "  ${GRAY}Нажмите любую клавишу для возврата${NC}"
                { read -rsn1 </dev/tty; } 2>/dev/null || true
            fi
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
            if [ -f "/opt/mtpr-simple/proxys/proxymenu.sh" ]; then
                exec bash /opt/mtpr-simple/proxys/proxymenu.sh
            else
                echo ""
                echo "  [✗] Файл /opt/mtpr-simple/proxys/proxymenu.sh не найден"
                echo -e "  ${GRAY}Нажмите любую клавишу для возврата${NC}"
                { read -rsn1 </dev/tty; } 2>/dev/null || true
            fi
            ;;
        *)
            echo "  Неверный выбор"
            sleep 0.1
            ;;
    esac
done
fi

# ── Диспетчер аргументов ─────────────────────────────────────
# Запускается только при прямом вызове скрипта; при source — нет.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    case "${1:-}" in
        --purge-silent)
            purge_telemt_silent
            exit $?
            ;;
        --install-silent)
            if [ -n "${2:-}" ]; then
                install_telemt_silent "$2" "${3:-}"
                exit $?
            else
                echo "Использование: $0 --install-silent <версия> [порт]" >&2
                exit 2
            fi
            ;;
        --engine-install)
            if [ -n "${2:-}" ]; then
                engine_install "$2" "${3:-}"
                exit $?
            else
                echo "Использование: $0 --engine-install <url|путь> [sha256]" >&2
                exit 2
            fi
            ;;
        --engine-status)
            engine_status
            exit $?
            ;;
        --engine-rollback)
            engine_rollback
            exit $?
            ;;
        "")
            : # меню уже отработало выше
            ;;
        *)
            echo "Использование: $0 [--purge-silent|--install-silent <версия> [порт]|--engine-install <url|путь> [sha256]|--engine-status|--engine-rollback]" >&2
            exit 2
            ;;
    esac
fi
