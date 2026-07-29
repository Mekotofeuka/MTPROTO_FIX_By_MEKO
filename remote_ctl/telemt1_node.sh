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

# ── Функция формирования ссылок для подключения ─────────────
generate_proxy_links() {
    local config_path=$(get_config_path)
    if ! ssh_exec "[ -f \"$config_path\" ]"; then
        return 1
    fi
    
    # Получаем данные из конфига через расширенное обнаружение
    local detected_info=$(detect_telemt_advanced)
    local IFS=':'
    local parts=($detected_info)
    unset IFS
    
    local detected_path="${parts[0]}"
    local detected_port="${parts[1]}"
    local detected_ip="${parts[2]}"
    local detected_public_host="${parts[3]}"
    local detected_classic="${parts[4]}"
    local detected_secure="${parts[5]}"
    local detected_tls="${parts[6]}"
    local detected_tls_domain="${parts[7]}"
    local detected_secret="${parts[8]}"
    
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
    
    # Определяем сервер (IP или public_host)
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
    
    # Если нет секрета — выходим
    if [ -z "$detected_secret" ]; then
        return 1
    fi
    
    # Определяем какие режимы включены
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
    
    # Если ни один режим не включен явно, но есть tls_domain — считаем что tls включен
    if [ "$classic_enabled" = false ] && [ "$secure_enabled" = false ] && [ "$tls_enabled" = false ]; then
        if [ -n "$detected_tls_domain" ]; then
            tls_enabled=true
        else
            classic_enabled=true
        fi
    fi
    
    local links=""
    
    # TLS режим (ee + secret + hex(tls_domain))
    if [ "$tls_enabled" = true ]; then
        local hex_domain=""
        if [ -n "$detected_tls_domain" ]; then
            hex_domain=$(ssh_exec "echo -n \"$detected_tls_domain\" | od -An -tx1 | tr -d ' \n' 2>/dev/null")
        fi
        local tls_secret="ee${detected_secret}${hex_domain}"
        links="${links}  TLS:\n"
        links="${links}  tg://proxy?server=${server}&port=${port}&secret=${tls_secret}\n"
    fi
    
    # Secure режим (dd + secret)
    if [ "$secure_enabled" = true ]; then
        local secure_secret="dd${detected_secret}"
        links="${links}  Secure (DD):\n"
        links="${links}  tg://proxy?server=${server}&port=${port}&secret=${secure_secret}\n"
    fi
    
    # Classic режим (просто secret)
    if [ "$classic_enabled" = true ]; then
        links="${links}  Classic:\n"
        links="${links}  tg://proxy?server=${server}&port=${port}&secret=${detected_secret}\n"
    fi
    
    echo -e "$links"
}

# ── Функция получения списка пользователей из конфига ──────
get_users_list() {
    local config_path=$(get_config_path)
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
find_user_link() {
    echo ""
    echo -e "  ${BOLD}Поиск пользователя для генерации ссылки${NC}"
    echo -e "  ${DIM}Введите имя пользователя (или его часть)${NC}"
    echo -e "  ${DIM}Например: hello, hel, user1, test и т.д.${NC}"
    echo ""
    echo -en "  ${BOLD}Ввод:${NC} "
    read -r search_query
    
    if [ -z "$search_query" ]; then
        echo ""
        echo -e "  ${YELLOW}[!]${NC} Введите имя пользователя"
        echo ""
        echo -e "  ${GRAY}Нажмите любую клавишу для возврата...${NC}"
        read -rsn1
        return 1
    fi
    
    # Получаем список пользователей
    local users=$(get_users_list)
    if [ -z "$users" ]; then
        echo ""
        echo -e "  ${YELLOW}[!]${NC} В конфиге нет пользователей в секции [access.users]"
        echo ""
        echo -e "  ${GRAY}Нажмите любую клавишу для возврата...${NC}"
        read -rsn1
        return 1
    fi
    
    # Ищем совпадения (регистронезависимо)
    local matches=$(echo "$users" | grep -i "$search_query")
    
    if [ -z "$matches" ]; then
        echo ""
        echo -e "  ${YELLOW}[!]${NC} Пользователь с именем \"$search_query\" не найден"
        echo ""
        echo -e "  ${GRAY}Нажмите любую клавишу для возврата...${NC}"
        read -rsn1
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
        read -rsn1
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
    read -r confirm
    
    if [[ -n "$confirm" && "$confirm" =~ ^[nN]$ ]]; then
        echo ""
        echo -e "  ${GRAY}Возврат...${NC}"
        sleep 0.5
        return 0
    fi
    
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
    
    # TLS режим
    if [ "$tls_enabled" = true ]; then
        local hex_domain=""
        if [ -n "$detected_tls_domain" ]; then
            hex_domain=$(ssh_exec "echo -n \"$detected_tls_domain\" | od -An -tx1 | tr -d ' \n' 2>/dev/null")
        fi
        local tls_secret="ee${user_secret}${hex_domain}"
        echo -e "  ${BOLD}TLS:${NC}"
        echo -e "  ${CYAN}tg://proxy?server=${server}&port=${port}&secret=${tls_secret}${NC}"
        echo ""
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
    
    echo -e "  ${GRAY}Нажмите любую клавишу для возврата...${NC}"
    read -rsn1
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
    local config_path=$(get_config_path)
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
    read -r CONFIG_TELEMT_INPUT

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
        read -r confirm_path
        if [[ ! "$confirm_path" =~ ^[yY]$ ]]; then
            echo -e "  ${GRAY}Возврат в меню...${NC}"
            sleep 0.1
            return 1
        fi
    fi

    ssh_exec "mkdir -p /opt/mtpr-simple && echo \"$CONFIG_TELEMT_INPUT\" > \"$CONFIG_PATH_FILE\""
    echo -e "  ${GREEN}[✓]${NC} Путь сохранён: $CONFIG_TELEMT_INPUT"
    echo ""
    echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
    read -rsn1
    return 0
}

# ── Функция просмотра логов ──────────────────────────────────
view_logs() {
    echo ""
    echo -e "  ${BLUE}[i]${NC} Просмотр логов Telemt (Ctrl+C для выхода)..."
    echo ""
    echo -e "  ${GRAY}Нажмите любую клавишу для продолжения...${NC}"
    read -rsn1
    ssh_interactive "journalctl -u telemt -f"
    echo ""
    echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
    read -rsn1
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
    read -r version_input

    if [[ "$version_input" =~ ^[Nn]$ ]]; then
        echo ""
        echo -e "  ${GRAY}Установка отменена${NC}"
        echo ""
        echo -e "  ${GRAY}${BOLD}Нажмите любую клавишу для возврата в меню...${NC}"
        read -rsn1
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
            read -rsn1
            return 1
        fi
    fi

    echo ""
    echo -e "  ${BLUE}[i]${NC} Установка Telemt версии ${display_version}..."
    echo ""

    if [ "$install_version" = "latest" ]; then
        ssh_interactive "curl -fsSL https://raw.githubusercontent.com/telemt/telemt/main/install.sh | sh"
    else
        ssh_interactive "curl -fsSL https://raw.githubusercontent.com/telemt/telemt/main/install.sh | sh -s -- $install_version"
    fi
    
    echo ""
    echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
    read -rsn1
}

# ── Функция установки Telemt в Docker ───────────────────────
install_telemt_docker() {
    echo ""
    echo -e "  ${RED}[✗]${NC} Установка Telemt в Docker на удалённой ноде пока не поддерживается"
    echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
    read -rsn1
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
    read -r confirm

    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        echo -e "  ${GRAY}Удаление отменено${NC}"
        echo ""
        echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
        read -rsn1
        return 1
    fi

    echo ""
    echo -e "  ${BLUE}[i]${NC} Удаление Telemt..."
    echo ""
    ssh_interactive "curl -fsSL https://raw.githubusercontent.com/telemt/telemt/main/install.sh | sh -s -- purge"
    echo ""
    echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
    read -rsn1
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
        read -r force_remove
        if [[ ! "$force_remove" =~ ^[yY]$ ]]; then
            echo -e "  ${GRAY}Удаление отменено${NC}"
            echo ""
            echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
            read -rsn1
            return 1
        fi
    fi
    
    echo ""
    echo -en "  ${BOLD}Продолжить удаление? [y/N]:${NC} "
    local confirm
    read -r confirm

    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        echo -e "  ${GRAY}Удаление отменено${NC}"
        echo ""
        echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
        read -rsn1
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
    ssh_exec "docker rmi containrrr/watchtower 2>/dev/null || true"
    
    # 4. Чистим неиспользуемые образы, контейнеры, сети
    echo -e "  ${BLUE}[i]${NC} Очистка неиспользуемых ресурсов Docker..."
    echo -e "  ${DIM}Будут удалены все неиспользуемые образы, контейнеры и сети${NC}"
    echo -en "  ${BOLD}Выполнить очистку? [y/N]:${NC} "
    read -r prune_confirm
    if [[ -z "$prune_confirm" || "$prune_confirm" =~ ^[yY]$ ]]; then
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
    echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
    read -rsn1
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
    read -r purge_choice
    
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
        echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
        read -rsn1
        return 1
    fi
    
    echo ""
    echo -e "  ${BLUE}[i]${NC} Открытие конфига: $config_path на удалённом сервере"
    ssh_interactive "nano \"$config_path\""
    
    echo ""
    echo -e "  ${GREEN}[✓]${NC} Редактирование завершено"
    echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
    read -rsn1
}

# ── Функция перезапуска Telemt ──────────────────────────────
restart_telemt() {
    echo ""
    echo -e "  ${BLUE}[i]${NC} Перезапуск Telemt..."
    echo ""
    ssh_exec "systemctl restart telemt 2>/dev/null || true"
    if [ $? -eq 0 ]; then
        echo -e "  ${GREEN}[✓]${NC} Telemt успешно перезапущен"
    else
        echo -e "  ${YELLOW}[!]${NC} Не удалось перезапустить Telemt (возможно, он не установлен как служба)"
        echo -e "  ${GRAY}Попробуйте сначала установить Telemt (пункт 1)${NC}"
    fi
    echo ""
    echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
    read -rsn1
}

# ── ФУНКЦИИ УПРАВЛЕНИЯ MSS (скопированы из main.sh) ────────

# ── Проверка MSS в конкретном конфиге ──────────────────────
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
    local config_path=$(get_config_path)
    if [ -z "$config_path" ] || ! ssh_exec "[ -f \"$config_path\" ]"; then
        echo ""
        echo -e "  ${RED}[✗]${NC} Файл конфига не найден или не указан"
        echo ""
        echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
        read -rsn1
        return 1
    fi

    local changed=0
    local mss_value="92"
    local mss_bulk_value="1200"

    # Проверяем наличие строк (даже закомментированных)
    local has_mss=$(ssh_exec "grep -E '^[[:space:]]*#?[[:space:]]*client_mss[[:space:]]*=' \"$config_path\" | head -1")
    local has_mss_bulk=$(ssh_exec "grep -E '^[[:space:]]*#?[[:space:]]*mss_bulk[[:space:]]*=' \"$config_path\" | head -1")

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
        read -r restart_confirm
        
        if [[ -z "$restart_confirm" || "$restart_confirm" =~ ^[yY]$ ]]; then
            ssh_exec "systemctl restart telemt 2>/dev/null || true"
            if [ $? -eq 0 ]; then
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
    read -rsn1
}

# ── ОТКЛЮЧЕНИЕ MSS, MSS_BULK И SYN_LIMIT ───────────────────
disable_bad_options() {
    local config_path=$(get_config_path)
    if [ -z "$config_path" ] || ! ssh_exec "[ -f \"$config_path\" ]"; then
        echo ""
        echo -e "  ${RED}[✗]${NC} Файл конфига не найден или не указан"
        echo ""
        echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
        read -rsn1
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
    echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
    read -rsn1
}

# ── УПРАВЛЕНИЕ MSS В КОНФИГЕ ──────────────────────────────
manage_mss() {
    local config_path=$(get_config_path)
    if [ -z "$config_path" ] || ! ssh_exec "[ -f \"$config_path\" ]"; then
        echo ""
        echo -e "  ${RED}[✗]${NC} Файл конфига не найден или не указан"
        echo ""
        echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
        read -rsn1
        return 1
    fi

    if are_bad_options_enabled_for_config "$config_path"; then
        echo ""
        echo -e "  ${BLUE}[i]${NC} Обнаружены активные строки с client_mss, mss_bulk или synlimit в $config_path"
        echo -en "  ${BOLD}${NC}Отключить mss, mss_bulk и synlimit в cfg telemt? [Y/n]:${NC} "
        local confirm
        read -r confirm
        if [[ -z "$confirm" || "$confirm" =~ ^[yY]$ ]]; then
            disable_bad_options
        else
            echo -e "  ${BLUE}[i]${NC} Отмена"
            echo ""
            echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
            read -rsn1
        fi
    else
        echo ""
        echo -e "  ${BLUE}[i]${NC} client_mss, mss_bulk и synlimit уже отключены или отсутствуют в конфиге"
        echo -en "  ${BOLD}Включить mss и mss_bulk в конфиге telemt? [Y/n]:${NC} "
        local confirm
        read -r confirm
        if [[ -z "$confirm" || "$confirm" =~ ^[yY]$ ]]; then
            enable_mss_options
        else
            echo -e "  ${BLUE}[i]${NC} Отмена"
            echo ""
            echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
            read -rsn1
        fi
    fi
}

# ── Главное меню ─────────────────────────────────────────────
while true; do
    clear
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
    read -r choice

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
            echo -e "  ${GRAY}Нажмите любую клавишу для возврата${NC}"
            read -rsn1
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
