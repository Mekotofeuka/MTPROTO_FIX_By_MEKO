#!/bin/bash
# telemt1_node.sh – управление Telemt на удалённой ноде (через SSH)
# Использование: ./telemt1_node.sh <IP> <USER> <PORT>

# ── Проверка аргументов ──────────────────────────────────────
if [ $# -lt 3 ]; then
    echo "❌ Использование: $0 <IP> <USER> <PORT>"
    exit 1
fi
REMOTE_IP="$1"
REMOTE_USER="$2"
REMOTE_PORT="$3"

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

# ── Конфигурация локального кеша ─────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVERS_DIR="$SCRIPT_DIR/servers"
SERVER_CACHE_DIR="$SERVERS_DIR/$REMOTE_IP"
mkdir -p "$SERVER_CACHE_DIR"

# Путь к локальному кешу конфига Telemt
LOCAL_CONFIG_FILE="$SERVER_CACHE_DIR/telemt.toml"
REMOTE_CONFIG_DEFAULT="/etc/telemt/telemt.toml"

# ── Функция выполнения команды через SSH ─────────────────────
ssh_exec() {
    local cmd="$1"
    ssh -p "$REMOTE_PORT" -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$REMOTE_USER@$REMOTE_IP" "$cmd" 2>/dev/null
}

# ── Проверка, установлен ли Telemt на удалённом сервере ──────
is_telemt_installed() {
    local status
    status=$(ssh_exec "command -v telemt >/dev/null 2>&1 && echo 'ok'")
    [ "$status" = "ok" ]
}

# ── Получение версии Telemt с удалённого сервера ────────────
get_telemt_version() {
    ssh_exec "telemt --version 2>/dev/null | head -1 | awk '{print \$2}'" 2>/dev/null
}

# ── Получение порта(ов) из конфига (локального кеша) ────────
get_telemt_ports() {
    if [ -f "$LOCAL_CONFIG_FILE" ]; then
        grep -E '^port[[:space:]]*=' "$LOCAL_CONFIG_FILE" 2>/dev/null | awk -F'=' '{print $2}' | tr -d ' "'
    else
        echo ""
    fi
}

# ── Получение онлайна Telemt с удалённого сервера ────────────
get_telemt_online() {
    if is_telemt_installed; then
        local online
        online=$(ssh_exec "curl -s --max-time 2 http://127.0.0.1:9091/v1/stats/users/active-ips 2>/dev/null | grep -o '\"active_ips\":\[[^]]*\]' | grep -o '[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}' | wc -l | tr -d ' '")
        echo "${online:-0}"
    else
        echo ""
    fi
}

# ── Обновить локальный кеш конфига (скачать с сервера) ──────
refresh_config_cache() {
    local remote_path="$REMOTE_CONFIG_DEFAULT"
    # Попробуем определить реальный путь конфига (если Telemt запущен)
    local detected_path
    detected_path=$(ssh_exec "ps -eo args 2>/dev/null | grep '[t]elemt' | grep -v 'telemt-panel' | grep -oE '/[^ ]+\.toml' | head -1")
    if [ -n "$detected_path" ]; then
        remote_path="$detected_path"
    else
        # Проверим стандартные места
        for p in "/etc/telemt/telemt.toml" "/etc/telemt/config.toml" "/opt/telemt/config.toml"; do
            if ssh_exec "test -f $p" >/dev/null 2>&1; then
                remote_path="$p"
                break
            fi
        done
    fi
    log_info "Загрузка конфига с $REMOTE_IP:$remote_path..."
    ssh_exec "cat $remote_path" > "$LOCAL_CONFIG_FILE" 2>/dev/null
    if [ $? -eq 0 ] && [ -s "$LOCAL_CONFIG_FILE" ]; then
        log_success "Конфиг сохранён локально: $LOCAL_CONFIG_FILE"
    else
        log_warning "Не удалось загрузить конфиг (возможно, Telemt не установлен или конфиг отсутствует)."
        # Создаём пустой файл, чтобы не было ошибок при чтении
        touch "$LOCAL_CONFIG_FILE"
    fi
}

# ── Проверка MSS (из локального конфига) ─────────────────────
is_mss_enabled() {
    if [ -f "$LOCAL_CONFIG_FILE" ]; then
        grep -E '^[[:space:]]*client_mss[[:space:]]*=' "$LOCAL_CONFIG_FILE" | grep -v '^#' | grep -q .
        return $?
    fi
    return 1
}

is_mss_bulk_enabled() {
    if [ -f "$LOCAL_CONFIG_FILE" ]; then
        grep -E '^[[:space:]]*mss_bulk[[:space:]]*=' "$LOCAL_CONFIG_FILE" | grep -v '^#' | grep -q .
        return $?
    fi
    return 1
}

is_synlimit_enabled() {
    if [ -f "$LOCAL_CONFIG_FILE" ]; then
        grep -E '^[[:space:]]*synlimit[[:space:]]*=' "$LOCAL_CONFIG_FILE" | grep -v '^#' | grep -q .
        return $?
    fi
    return 1
}

are_bad_options_enabled() {
    is_mss_enabled || is_mss_bulk_enabled || is_synlimit_enabled
}

# ── Включение MSS и MSS_BULK (редактируем локальный кеш, затем применяем) ──
enable_mss_options() {
    if [ ! -f "$LOCAL_CONFIG_FILE" ]; then
        log_error "Локальный конфиг не найден. Сначала загрузите конфиг (пункт 5)."
        return 1
    fi

    local changed=0
    local mss_value="92"
    local mss_bulk_value="1200"

    local has_mss=$(grep -E '^[[:space:]]*#?[[:space:]]*client_mss[[:space:]]*=' "$LOCAL_CONFIG_FILE" | head -1)
    local has_mss_bulk=$(grep -E '^[[:space:]]*#?[[:space:]]*mss_bulk[[:space:]]*=' "$LOCAL_CONFIG_FILE" | head -1)

    if [ -n "$has_mss" ]; then
        sed -i 's/^[[:space:]]*#[[:space:]]*client_mss[[:space:]]*=.*/client_mss = '"$mss_value"'/' "$LOCAL_CONFIG_FILE"
        changed=1
    else
        if grep -q '^\[server\]' "$LOCAL_CONFIG_FILE"; then
            sed -i '/^\[server\]/a client_mss = '"$mss_value"'' "$LOCAL_CONFIG_FILE"
            changed=1
        else
            echo "" >> "$LOCAL_CONFIG_FILE"
            echo "[server]" >> "$LOCAL_CONFIG_FILE"
            echo "client_mss = $mss_value" >> "$LOCAL_CONFIG_FILE"
            changed=1
        fi
    fi

    if [ -n "$has_mss_bulk" ]; then
        sed -i 's/^[[:space:]]*#[[:space:]]*mss_bulk[[:space:]]*=.*/mss_bulk = '"$mss_bulk_value"'/' "$LOCAL_CONFIG_FILE"
        changed=1
    else
        if grep -q '^\[server\]' "$LOCAL_CONFIG_FILE"; then
            sed -i '/^\[server\]/a mss_bulk = '"$mss_bulk_value"'' "$LOCAL_CONFIG_FILE"
            changed=1
        else
            if ! grep -q '^\[server\]' "$LOCAL_CONFIG_FILE"; then
                echo "" >> "$LOCAL_CONFIG_FILE"
                echo "[server]" >> "$LOCAL_CONFIG_FILE"
            fi
            echo "mss_bulk = $mss_bulk_value" >> "$LOCAL_CONFIG_FILE"
            changed=1
        fi
    fi

    if [ $changed -eq 1 ]; then
        log_success "MSS параметры добавлены в локальный конфиг."
        # Копируем конфиг на сервер
        apply_local_config
        # Перезапускаем Telemt
        restart_telemt
    else
        log_warning "Не удалось изменить конфиг."
    fi
}

# ── Отключение MSS, MSS_BULK, SYN_LIMIT (локально) ──────────
disable_bad_options() {
    if [ ! -f "$LOCAL_CONFIG_FILE" ]; then
        log_error "Локальный конфиг не найден."
        return 1
    fi
    local changed=0
    if grep -E '^[[:space:]]*client_mss[[:space:]]*=' "$LOCAL_CONFIG_FILE" | grep -v '^#' | grep -q .; then
        sed -i 's/^[[:space:]]*client_mss[[:space:]]*=.*/#client_mss = 0/' "$LOCAL_CONFIG_FILE"
        changed=1
    fi
    if grep -E '^[[:space:]]*mss_bulk[[:space:]]*=' "$LOCAL_CONFIG_FILE" | grep -v '^#' | grep -q .; then
        sed -i 's/^[[:space:]]*mss_bulk[[:space:]]*=.*/#mss_bulk = 0/' "$LOCAL_CONFIG_FILE"
        changed=1
    fi
    if grep -E '^[[:space:]]*synlimit[[:space:]]*=' "$LOCAL_CONFIG_FILE" | grep -v '^#' | grep -q .; then
        sed -i 's/^[[:space:]]*synlimit[[:space:]]*=.*/#synlimit = 0/' "$LOCAL_CONFIG_FILE"
        changed=1
    fi
    if [ $changed -eq 1 ]; then
        log_success "MSS/mss_bulk/synlimit отключены в локальном конфиге."
        apply_local_config
        restart_telemt
    else
        log_warning "Активные строки не найдены."
    fi
}

# ── Применить локальный конфиг на удалённом сервере ────────
apply_local_config() {
    if [ ! -f "$LOCAL_CONFIG_FILE" ]; then
        log_error "Локальный конфиг не найден."
        return 1
    fi
    # Определим удалённый путь конфига (используем стандартный или из процесса)
    local remote_path="$REMOTE_CONFIG_DEFAULT"
    local detected_path
    detected_path=$(ssh_exec "ps -eo args 2>/dev/null | grep '[t]elemt' | grep -v 'telemt-panel' | grep -oE '/[^ ]+\.toml' | head -1")
    if [ -n "$detected_path" ]; then
        remote_path="$detected_path"
    fi
    log_info "Копирование локального конфига на $REMOTE_IP:$remote_path..."
    scp -P "$REMOTE_PORT" -o StrictHostKeyChecking=no "$LOCAL_CONFIG_FILE" "$REMOTE_USER@$REMOTE_IP:$remote_path" >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        log_success "Конфиг применён на сервере."
    else
        log_error "Не удалось скопировать конфиг на сервер."
        return 1
    fi
}

# ── Перезапустить Telemt на удалённом сервере ──────────────
restart_telemt() {
    log_info "Перезапуск Telemt на $REMOTE_IP..."
    ssh_exec "systemctl restart telemt 2>/dev/null || true"
    if [ $? -eq 0 ]; then
        log_success "Telemt перезапущен."
    else
        log_warning "Не удалось перезапустить (возможно, не установлен как служба)."
    fi
}

# ── Установка Telemt на удалённом сервере ───────────────────
install_telemt_remote() {
    echo ""
    echo -e "  ${BLUE}[i]${NC} Установка Telemt на $REMOTE_IP"
    echo ""
    echo -e "  ${NC}${BOLD}Выберите версию TELEMT:${NC}"
    echo -e "  ${GREEN}[Enter]${NC}${BOLD} — последняя версия"
    echo -e "  ${NC}${BOLD}Либо введите версию (например, ${GREEN}3.4.18${NC}${BOLD})"
    echo -e "  ${RED}[N/n]${NC}${BOLD} — назад"
    echo ""
    echo -en "  ${NC}${BOLD}Ввод:${NC} "
    read -r version_input

    if [[ "$version_input" =~ ^[Nn]$ ]]; then
        echo ""
        echo -e "  ${GRAY}Установка отменена${NC}"
        return 0
    fi

    local install_version="latest"
    if [ -n "$version_input" ] && [[ "$version_input" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        install_version="$version_input"
    fi

    log_info "Установка Telemt версии ${install_version} на $REMOTE_IP..."
    if [ "$install_version" = "latest" ]; then
        ssh_exec "curl -fsSL https://raw.githubusercontent.com/telemt/telemt/main/install.sh | sh" >/dev/null 2>&1
    else
        ssh_exec "curl -fsSL https://raw.githubusercontent.com/telemt/telemt/main/install.sh | sh -s -- $install_version" >/dev/null 2>&1
    fi
    if [ $? -eq 0 ]; then
        log_success "Telemt установлен (или обновлён)."
        # После установки загружаем конфиг
        refresh_config_cache
        # Спрашиваем, перезапустить ли
        echo ""
        echo -en "  ${BOLD}Перезапустить Telemt сейчас? [Y/n]:${NC} "
        local restart_choice
        read -r restart_choice
        if [[ -z "$restart_choice" || "$restart_choice" =~ ^[yY]$ ]]; then
            restart_telemt
        fi
    else
        log_error "Ошибка установки Telemt."
    fi
    echo ""
    echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
    read -rsn1
}

# ── Получение списка пользователей из локального конфига ────
get_users_list() {
    if [ ! -f "$LOCAL_CONFIG_FILE" ]; then
        return 1
    fi
    sed -n '/^\[access\.users\]/,/^\[/p' "$LOCAL_CONFIG_FILE" 2>/dev/null | grep -E '=' | grep -v '^#' | while IFS='=' read -r name secret; do
        name=$(echo "$name" | tr -d ' "')
        secret=$(echo "$secret" | tr -d ' "')
        if [ -n "$name" ] && [ -n "$secret" ]; then
            echo "$name:$secret"
        fi
    done
}

# ── Поиск пользователя и генерация ссылки (использует локальный конфиг и удалённый IP) ──
find_user_link() {
    echo ""
    echo -e "  ${BOLD}Поиск пользователя для генерации ссылки (на $REMOTE_IP)${NC}"
    echo -e "  ${DIM}Введите имя пользователя (или его часть)${NC}"
    echo ""
    echo -en "  ${BOLD}Ввод:${NC} "
    read -r search_query

    if [ -z "$search_query" ]; then
        echo -e "  ${YELLOW}[!]${NC} Введите имя пользователя"
        return 1
    fi

    local users=$(get_users_list)
    if [ -z "$users" ]; then
        echo -e "  ${YELLOW}[!]${NC} В конфиге нет пользователей в секции [access.users]"
        return 1
    fi

    local matches=$(echo "$users" | grep -i "$search_query")
    if [ -z "$matches" ]; then
        echo -e "  ${YELLOW}[!]${NC} Пользователь не найден."
        return 1
    fi

    local match_count=$(echo "$matches" | wc -l)
    if [ "$match_count" -gt 1 ]; then
        echo -e "  ${YELLOW}[!]${NC} Найдено несколько совпадений:"
        echo "$matches" | while IFS=':' read -r name secret; do
            echo -e "    ${CYAN}${name}${NC}"
        done
        echo -e "  ${BOLD}Уточните запрос.${NC}"
        return 1
    fi

    local user_name=$(echo "$matches" | cut -d':' -f1)
    local user_secret=$(echo "$matches" | cut -d':' -f2)
    echo -e "  ${GREEN}✓${NC} Найден пользователь: ${BOLD}${user_name}${NC}"
    echo ""
    echo -en "  ${BOLD}Вывести ссылку? [Y/n]:${NC} "
    local confirm
    read -r confirm
    if [[ "$confirm" =~ ^[nN]$ ]]; then
        return 0
    fi

    # Определяем порт из конфига
    local port=$(grep -E '^port[[:space:]]*=' "$LOCAL_CONFIG_FILE" 2>/dev/null | head -1 | awk -F'=' '{print $2}' | tr -d ' "')
    [ -z "$port" ] && port="443"

    # Определяем сервер: используем public_host если есть, иначе REMOTE_IP
    local server="$REMOTE_IP"
    local public_host=$(grep -E '^public_host[[:space:]]*=' "$LOCAL_CONFIG_FILE" 2>/dev/null | head -1 | awk -F'=' '{print $2}' | tr -d ' "')
    [ -n "$public_host" ] && server="$public_host"

    # Определяем режимы
    local tls_enabled=false
    local secure_enabled=false
    local classic_enabled=false
    local tls_domain=$(grep -E '^tls_domain[[:space:]]*=' "$LOCAL_CONFIG_FILE" 2>/dev/null | head -1 | awk -F'=' '{print $2}' | tr -d ' "')
    [ -n "$tls_domain" ] && tls_enabled=true
    # Также проверяем явные режимы
    grep -qE '^classic[[:space:]]*=[[:space:]]*true' "$LOCAL_CONFIG_FILE" 2>/dev/null && classic_enabled=true
    grep -qE '^secure[[:space:]]*=[[:space:]]*true' "$LOCAL_CONFIG_FILE" 2>/dev/null && secure_enabled=true
    grep -qE '^tls[[:space:]]*=[[:space:]]*true' "$LOCAL_CONFIG_FILE" 2>/dev/null && tls_enabled=true
    if [ "$classic_enabled" = false ] && [ "$secure_enabled" = false ] && [ "$tls_enabled" = false ]; then
        # Если ничего не указано, считаем classic
        classic_enabled=true
    fi

    echo ""
    echo -e "  ${BOLD}Ссылка для пользователя ${GREEN}${user_name}${NC}${BOLD}:${NC}"
    echo ""

    if [ "$tls_enabled" = true ]; then
        local hex_domain=""
        if [ -n "$tls_domain" ]; then
            hex_domain=$(echo -n "$tls_domain" | od -An -tx1 | tr -d ' \n' 2>/dev/null)
        fi
        local tls_secret="ee${user_secret}${hex_domain}"
        echo -e "  ${BOLD}TLS:${NC}"
        echo -e "  ${CYAN}tg://proxy?server=${server}&port=${port}&secret=${tls_secret}${NC}"
        echo ""
    fi

    if [ "$secure_enabled" = true ]; then
        local secure_secret="dd${user_secret}"
        echo -e "  ${BOLD}Secure (DD):${NC}"
        echo -e "  ${CYAN}tg://proxy?server=${server}&port=${port}&secret=${secure_secret}${NC}"
        echo ""
    fi

    if [ "$classic_enabled" = true ]; then
        echo -e "  ${BOLD}Classic:${NC}"
        echo -e "  ${CYAN}tg://proxy?server=${server}&port=${port}&secret=${user_secret}${NC}"
        echo ""
    fi
}

# ── Просмотр логов на удалённом сервере ─────────────────────
view_logs() {
    echo ""
    echo -e "  ${BLUE}[i]${NC} Просмотр логов Telemt на $REMOTE_IP (Ctrl+C для выхода)..."
    echo ""
    echo -e "  ${GRAY}Нажмите любую клавишу для продолжения...${NC}"
    read -rsn1
    ssh -t -p "$REMOTE_PORT" "$REMOTE_USER@$REMOTE_IP" "journalctl -u telemt -f"
}

# ── Обновить путь к конфигу (для локального кеша) ──────────
update_config_path() {
    echo ""
    echo -e "  ${BLUE}[i]${NC} Обновление пути к конфигу (локальный кеш)"
    echo -e "  ${DIM}Эта функция позволяет изменить путь, откуда берётся конфиг на сервере.${NC}"
    echo -e "  ${DIM}По умолчанию используется /etc/telemt/telemt.toml${NC}"
    echo ""
    echo -en "  ${BOLD}Введите новый путь (или Enter для отмены):${NC} "
    read -r new_path
    if [ -z "$new_path" ]; then
        return 0
    fi
    # Сохраняем новый путь в специальный файл для этого сервера
    echo "$new_path" > "$SERVER_CACHE_DIR/remote_config_path"
    log_success "Путь сохранён: $new_path"
    # Перезагружаем конфиг
    refresh_config_cache
}

# ── Функция для удаления Telemt (стандартный и Docker) ──────
purge_telemt_remote() {
    echo ""
    echo -e "  ${RED}${BOLD}ВНИМАНИЕ:${NC} Будет выполнено полное удаление Telemt на $REMOTE_IP!"
    echo -e "  ${BOLD}Будут удалены все файлы Telemt.${NC}"
    echo ""
    echo -en "  ${BOLD}Продолжить? [y/N]:${NC} "
    local confirm
    read -r confirm
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        log_info "Отмена"
        return 0
    fi

    log_info "Удаление Telemt на $REMOTE_IP..."
    # Стандартный Telemt
    ssh_exec "curl -fsSL https://raw.githubusercontent.com/telemt/telemt/main/install.sh | sh -s -- purge" >/dev/null 2>&1
    # Docker Telemt
    ssh_exec "cd /root/telemt 2>/dev/null && docker compose down -v 2>/dev/null; cd /root && rm -rf /root/telemt 2>/dev/null; docker rmi ghcr.io/telemt/telemt:* 2>/dev/null || true" >/dev/null 2>&1
    # Удаляем локальный кеш
    rm -f "$LOCAL_CONFIG_FILE"
    rm -f "$SERVER_CACHE_DIR/remote_config_path"
    log_success "Telemt удалён с $REMOTE_IP, локальный кеш очищен."
}

# ── Главное меню ─────────────────────────────────────────────
main_menu() {
    while true; do
        clear
        # Проверяем, установлен ли Telemt на удалённом сервере
        local installed=false
        if is_telemt_installed; then
            installed=true
        fi

        echo ""
        echo -e "  ${BOLD}Telemt меню (удалённо: ${CYAN}${REMOTE_USER}@${REMOTE_IP}${NC}${BOLD}) v0.78${NC}"
        echo -e "  ${DIM}═══════════════════════════════════════════════════════════${NC}"

        if [ "$installed" = true ]; then
            # Подгружаем конфиг, если ещё нет
            if [ ! -f "$LOCAL_CONFIG_FILE" ] || [ ! -s "$LOCAL_CONFIG_FILE" ]; then
                refresh_config_cache
            fi

            echo ""
            echo -e "  ${NC}${BOLD}Telemt:${NC}${GREEN} установлен${NC}"
            version=$(get_telemt_version)
            if [ -n "$version" ]; then
                echo -e "  ${NC}${BOLD}Версия:${NC} ${GREEN}${version}${NC}"
            fi
            ports=$(get_telemt_ports)
            if [ -n "$ports" ]; then
                echo -e "  ${BOLD}Порт(ы):${NC} ${CYAN}${ports}${NC}"
            fi
            online=$(get_telemt_online)
            if [ -n "$online" ] && [ "$online" -ge 0 ] 2>/dev/null; then
                echo -e "  ${NC}${BOLD}Подключено к прокси:${NC} ${CYAN}${BOLD}${online}${NC}${BOLD} человек"
            else
                echo -e "  ${NC}${BOLD}Подключено к прокси:${NC} ${CYAN}${BOLD}0${NC}${BOLD} человек"
            fi
            # MSS статус
            if [ -f "$LOCAL_CONFIG_FILE" ]; then
                _mss_enabled=$(is_mss_enabled && echo "включен" || echo "отключен")
                _mss_bulk_enabled=$(is_mss_bulk_enabled && echo "включен" || echo "отключен")
                _synlimit_enabled=$(is_synlimit_enabled && echo "включен" || echo "отключен")
                mss_color="${GREEN}"
                mss_bulk_color="${GREEN}"
                synlimit_color="${GREEN}"
                [ "$_mss_enabled" = "включен" ] && mss_color="${RED}"
                [ "$_mss_bulk_enabled" = "включен" ] && mss_bulk_color="${RED}"
                [ "$_synlimit_enabled" = "включен" ] && synlimit_color="${RED}"
                echo -e "  ${BOLD}Встроенный MSS:${NC} ${mss_color}${_mss_enabled}${NC}  |  ${BOLD}MSS_BULK:${NC} ${mss_bulk_color}${_mss_bulk_enabled}${NC}  |  ${BOLD}Synlimit:${NC} ${synlimit_color}${_synlimit_enabled}${NC}"
            fi
            echo ""
        else
            echo ""
            echo -e "  ${YELLOW}Telemt не установлен на $REMOTE_IP${NC}"
            echo ""
        fi

        echo -e "  ${CYAN}[1]${NC}  ${BOLD}Установить/обновить/откатить Telemt${NC}"
        echo -e "  ${CYAN}[2]${NC}  ${BOLD}Установить Telemt в Docker${NC}  ${DIM}(заглушка)${NC}"
        echo -e "  ${CYAN}[3]${NC}  ${BOLD}Открыть конфиг (локальный кеш)${NC}"
        echo -e "  ${CYAN}[4]${NC}  ${BOLD}Перезапустить Telemt${NC}"
        echo -e "  ${CYAN}[5]${NC}  ${BOLD}Обновить конфиг с сервера${NC}"
        echo -e "  ${CYAN}[6]${NC}  ${BOLD}Посмотреть логи Telemt${NC}"
        echo -e "  ${CYAN}[7]${NC}  ${BOLD}Вывести ссылку для пользователя${NC}"
        echo -e "  ${CYAN}[8]${NC}  ${BOLD}Управление MSS в конфиге${NC}"
        echo -e "  ${RED}[9]${NC}  ${BOLD}Удалить Telemt${NC}"
        echo ""
        echo -e "  ${RED}${BOLD}[0]${NC}  ${BOLD}Назад в меню управления нодами${NC}"
        echo ""
        if [ "$installed" = true ] && [ -f "$LOCAL_CONFIG_FILE" ]; then
            echo -e "  ${DIM}Локальный кеш конфига: ${LOCAL_CONFIG_FILE}${NC}"
        fi
        echo ""
        echo -en "  ${BOLD}Выбор:${NC} "
        read -r choice

        case "$choice" in
            1) install_telemt_remote ;;
            2)
                echo ""
                log_info "Установка Telemt в Docker на $REMOTE_IP (заглушка)."
                read -p "Нажмите Enter для продолжения..."
                ;;
            3)
                if [ ! -f "$LOCAL_CONFIG_FILE" ]; then
                    log_warning "Локальный конфиг не найден. Загрузите его через пункт 5."
                else
                    if command -v nano >/dev/null 2>&1; then
                        nano "$LOCAL_CONFIG_FILE"
                        # После редактирования предлагаем применить
                        echo ""
                        echo -en "  ${BOLD}Применить изменения на сервере и перезапустить Telemt? [Y/n]:${NC} "
                        local apply_choice
                        read -r apply_choice
                        if [[ -z "$apply_choice" || "$apply_choice" =~ ^[yY]$ ]]; then
                            apply_local_config
                            restart_telemt
                        fi
                    else
                        log_error "nano не найден. Установите или используйте другой редактор."
                    fi
                fi
                read -p "Нажмите Enter для продолжения..."
                ;;
            4) restart_telemt ; read -p "Нажмите Enter для продолжения..." ;;
            5) refresh_config_cache ; read -p "Нажмите Enter для продолжения..." ;;
            6) view_logs ;;
            7) find_user_link ; read -p "Нажмите Enter для продолжения..." ;;
            8)
                if [ -f "$LOCAL_CONFIG_FILE" ]; then
                    if are_bad_options_enabled; then
                        echo ""
                        echo -e "  ${BLUE}[i]${NC} Обнаружены активные MSS/mss_bulk/synlimit."
                        echo -en "  ${BOLD}Отключить их? [Y/n]:${NC} "
                        local confirm
                        read -r confirm
                        if [[ -z "$confirm" || "$confirm" =~ ^[yY]$ ]]; then
                            disable_bad_options
                        fi
                    else
                        echo ""
                        echo -e "  ${BLUE}[i]${NC} MSS/mss_bulk/synlimit уже отключены или отсутствуют."
                        echo -en "  ${BOLD}Включить mss и mss_bulk? [Y/n]:${NC} "
                        local confirm
                        read -r confirm
                        if [[ -z "$confirm" || "$confirm" =~ ^[yY]$ ]]; then
                            enable_mss_options
                        fi
                    fi
                else
                    log_error "Конфиг не найден. Загрузите через пункт 5."
                fi
                read -p "Нажмите Enter для продолжения..."
                ;;
            9) purge_telemt_remote ; read -p "Нажмите Enter для продолжения..." ;;
            0) echo "" ; log_info "Возврат..." ; exit 0 ;;
            *)
                log_error "Неверный выбор"
                sleep 0.5
                ;;
        esac
    done
}

# ── Запуск ────────────────────────────────────────────────────
main_menu
