#!/bin/bash
# remote_ctl/node_manager.sh – управление удалёнными нодами

# ── Цвета ─────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
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
        log_error "Требуются права root для управления SSH-ключами"
        exit 1
    fi
}
check_root

# ── Конфигурация ─────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
SERVERS_DIR="$SCRIPT_DIR/servers"
mkdir -p "$SERVERS_DIR"

# ── Генерация SSH-ключа, если нет ──────────────────────────
ensure_ssh_key() {
    if [[ ! -f ~/.ssh/id_rsa.pub ]]; then
        log_info "Генерирую SSH-ключ (без пароля)..."
        mkdir -p ~/.ssh
        ssh-keygen -t rsa -b 4096 -N "" -f ~/.ssh/id_rsa
        log_success "Ключ создан: ~/.ssh/id_rsa.pub"
    fi
}

# ── Получение списка серверов ──────────────────────────────
get_servers() {
    local f
    for f in "$SERVERS_DIR"/*.conf; do
        [ -f "$f" ] && basename "$f" .conf
    done
}

get_server_count() {
    local n=0 f
    for f in "$SERVERS_DIR"/*.conf; do
        [ -f "$f" ] && n=$((n + 1))
    done
    echo "$n"
}

# ── Загрузка конфига сервера ──────────────────────────────
load_server_config() {
    local ip="$1"
    local conf_file="$SERVERS_DIR/$ip.conf"
    [[ ! -f "$conf_file" ]] && return 1
    # source в подоболочке: файл не должен менять переменные самого
    # скрипта (раньше он затирал глобальный $USER/$PORT).
    (
        . "$conf_file"
        echo "${NODE_USER:-${USER:-root}}" "${NODE_PORT:-${PORT:-22}}"
    )
}

# ── Сохранение конфига ──────────────────────────────────────
save_server_config() {
    local ip="$1"
    local user="$2"
    local port="$3"
    cat > "$SERVERS_DIR/$ip.conf" <<EOF
# MEKO Node Manager — конфиг ноды
NODE_USER="$user"
NODE_PORT="$port"
# старые ключи (обратная совместимость)
USER="$user"
PORT="$port"
EOF
}

# ── Проверка доступа по ключу ──────────────────────────────
# Возвращает 0 только если SSH реально пускает БЕЗ пароля
# (BatchMode=yes запрещает интерактив), т.е. ключ уже установлен.
check_ssh_key() {
    local user="$1"
    local ip="$2"
    local port="${3:-22}"
    ssh -o BatchMode=yes -o ConnectTimeout=5 -o ConnectionAttempts=2 -o Port="$port" "$user@$ip" "exit" &>/dev/null
    return $?
}

# ── Проверка доступности TCP-порта (без аутентификации) ─────
# Нужна отдельно от check_ssh_key: до добавления сервера ключа ещё
# нет, и раньше любой живой хост получал ложное "не отвечает по SSH".
check_tcp() {
    local ip="$1"
    local port="$2"
    local timeout="${3:-5}"
    timeout "$timeout" bash -c "exec 3<>/dev/tcp/$ip/$port" 2>/dev/null
    return $?
}

# ── Парсинг ввода (user@ip, ssh user@ip, ip) с валидацией ──
parse_input() {
    local raw="$1"
    raw=$(trim "$raw")
    if [[ -z "$raw" ]]; then
        echo "❌ Пустой ввод." >&2
        return 1
    fi

    local user="root"
    local ip=""
    if [[ "$raw" == *"@"* ]]; then
        local user_part="${raw%%@*}"
        user_part=$(trim "${user_part#ssh }")
        ip="${raw##*@}"
        ip=$(echo "$ip" | awk '{print $1}')
        user="$user_part"
    else
        ip="$raw"
    fi

    if [[ -z "$ip" ]]; then
        echo "❌ Не удалось извлечь IP-адрес." >&2
        return 1
    fi

    # ── Валидация IP или домена ──────────────────────────────
    # Проверка на IPv4 (4 октета)
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        # Дополнительная проверка октетов
        IFS='.' read -r o1 o2 o3 o4 <<< "$ip"
        if [[ $o1 -le 255 && $o2 -le 255 && $o3 -le 255 && $o4 -le 255 ]]; then
            # Валидный IP
            echo "$user" "$ip"
            return 0
        else
            echo "❌ Некорректный IP-адрес (октеты > 255): $ip" >&2
            return 1
        fi
    # Проверка на домен (содержит точку и хотя бы одну букву после точки)
    elif [[ "$ip" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        echo "$user" "$ip"
        return 0
    else
        echo "❌ Некорректный IP или домен: $ip (допустимы только IPv4 или домены вида example.com)" >&2
        return 1
    fi
}

# ── Добавление сервера ──────────────────────────────────────
add_server() {
    clear 2>/dev/null || true
    echo ""
    echo -e "  ${BOLD}Добавление нового сервера${NC}"
    echo -e "  ${DIM}═════════════════════════════════════${NC}"
    echo ""
    echo -en "  ${BOLD}Введите IP-адрес или строку типа ${CYAN}'root@1.2.3.4'${NC} или ${CYAN}'ssh root@127.0.0.1'${NC}: "
    local input
    { read -r input </dev/tty; } 2>/dev/null || input=""

    local parsed
    if ! parsed=$(parse_input "$input"); then
        echo -n "Нажмите Enter для возврата..."; { read -r _ </dev/tty; } 2>/dev/null || true; return 1
    fi
    local user ip
    read -r user ip <<< "$parsed"

    # Сначала порт, потом TCP-проверка доступности.
    # Раньше проверка шла ДО ввода порта и через check_ssh_key: у ещё
    # не добавленного сервера ключа нет, поэтому живой хост получал
    # ложное «Хост ... не отвечает по SSH (таймаут 5 сек)».
    echo -en "  ${BOLD}Введите порт для SSH подключения (по умолчанию ${GREEN}Enter - 22${NC}${BOLD}):${NC} "
    local port
    { read -r port </dev/tty; } 2>/dev/null || port=""
    port=${port:-22}

    log_info "Проверка доступности $ip (порт $port)..."
    if ! check_tcp "$ip" "$port" 5; then
        log_warning "Порт $port на $ip недоступен (таймаут 5 сек)."
        echo -en "  ${BOLD}Добавить сервер всё равно? [y/N]:${NC} "
        local force
        { read -r force </dev/tty; } 2>/dev/null || force=""
        if [[ ! "$force" =~ ^[yY]$ ]]; then
            log_info "Отмена"
            echo -n "Нажмите Enter для продолжения..."; { read -r _ </dev/tty; } 2>/dev/null || true
            return 0
        fi
    fi

    if [[ -f "$SERVERS_DIR/$ip.conf" ]]; then
        echo ""
        echo -en "  ${BOLD}Сервер $ip уже добавлен. Перезаписать? [y/N]:${NC} "
        local overwrite
        { read -r overwrite </dev/tty; } 2>/dev/null || overwrite=""
        if [[ ! "$overwrite" =~ ^[yY]$ ]]; then
            log_info "Отмена"
            echo -n "Нажмите Enter для продолжения..."; { read -r _ </dev/tty; } 2>/dev/null || true
            return 0
        fi
    fi

    ensure_ssh_key

    if check_ssh_key "$user" "$ip" "$port"; then
        log_success "Доступ по ключу уже настроен."
    else
        echo ""
        log_info "Доступ по ключу отсутствует. Будет выполнена команда:"
        echo -e "  ${CYAN}ssh-copy-id -p $port $user@$ip${NC}"
        echo -e "  ${BOLD}Введите пароль пользователя ${GREEN}$user${NC}${BOLD}, если потребуется.${NC}"
        if ssh-copy-id -p "$port" "$user@$ip"; then
            log_success "Ключ успешно скопирован."
        else
            log_error "Не удалось скопировать ключ. Проверьте пароль и доступность."
            echo -n "Нажмите Enter для продолжения..."; { read -r _ </dev/tty; } 2>/dev/null || true
            return 1
        fi
    fi

    save_server_config "$ip" "$user" "$port"
    log_success "Сервер $ip сохранён."
    echo -n "Нажмите Enter для продолжения..."; { read -r _ </dev/tty; } 2>/dev/null || true
}

# ── Удаление сервера (конфиг + отзыв ключа) ────────────────
remove_server() {
    local ip="$1"
    local user="$2"
    local port="$3"

    echo ""
    echo -e "  ${RED}${BOLD}ВНИМАНИЕ:${NC} Будет удалён сервер ${CYAN}$ip${NC} и отозван SSH-ключ!"
    echo -e "  ${DIM}══════════════════════════════════════════════════${NC}"
    echo ""
    echo -en "  ${BOLD}Продолжить? [y/N]:${NC} "
    local confirm
    { read -r confirm </dev/tty; } 2>/dev/null || { echo; log_info "Нет доступа к терминалу — отмена"; return 0; }
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        log_info "Отмена"
        return 0
    fi

    log_info "Удаление конфига сервера..."
    rm -f "$SERVERS_DIR/$ip.conf"
    log_success "Конфиг удалён."

    log_info "Отзыв SSH-ключа на сервере..."
    # Guard: без непустого публичного ключа escaped_key пуст, и тогда
    # sed -i '//d' вычистил бы ВЕСЬ authorized_keys, отрезав SSH к серверу.
    if [[ ! -s ~/.ssh/id_rsa.pub ]]; then
        log_warning "Публичный ключ ~/.ssh/id_rsa.pub отсутствует или пуст — отзыв ключа пропущен, authorized_keys не тронут."
    else
        local pub_key
        pub_key=$(cat ~/.ssh/id_rsa.pub)
        local escaped_key
        escaped_key=$(echo "$pub_key" | sed 's/[\/&]/\\&/g')
        # Сохраняем реальный код возврата SSH (без маскировки через "|| true").
        ssh -o ConnectTimeout=5 -o ConnectionAttempts=2 -p "$port" "$user@$ip" "sed -i '/$escaped_key/d' ~/.ssh/authorized_keys" 2>/dev/null
        local rc=$?
        if [[ $rc -eq 0 ]]; then
            log_success "Ключ удалён из ~/.ssh/authorized_keys на сервере."
        else
            log_warning "Не удалось удалить ключ (возможно, его там нет или доступ уже потерян)."
        fi
    fi

    log_success "Сервер $ip полностью удалён."
    echo -n "Нажмите Enter для продолжения..."; { read -r _ </dev/tty; } 2>/dev/null || true
}

# ── Очистка всех прокси и фиксов на сервере ────────────────
clean_all_on_server() {
    local ip="$1"
    local user="$2"
    local port="$3"

    echo ""
    echo -e "  ${RED}${BOLD}ВНИМАНИЕ:${NC} Будет выполнена полная очистка на сервере ${CYAN}$ip${NC}"
    echo -e "  ${DIM}══════════════════════════════════════════════════${NC}"
    echo -e "  Будут удалены все прокси и фиксы:"
    echo -e "    • Telemt (стандартный и Docker)"
    echo -e "    • MTProtoZig"
    echo -e "    • MTG"
    echo -e "    • MEKO FIX (SYN FIX)"
    echo -e "    • 3xUI (если установлен)"
    echo ""
    echo -en "  ${BOLD}Продолжить? [y/N]:${NC} "
    local confirm
    { read -r confirm </dev/tty; } 2>/dev/null || { echo; log_info "Нет доступа к терминалу — отмена"; return 0; }
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        log_info "Отмена"
        return 0
    fi

    log_info "Начинаем очистку сервера $ip..."

    # Все SSH-команды с таймаутом. Код возврата каждой проверяем:
    # раньше стояло глушение "|| true", поэтому полный провал был невидим,
    # а в конце всегда печатался ложный успех.
    local SSH_OPTS="-o ConnectTimeout=5 -o ConnectionAttempts=2 -p $port"
    local had_error=0
    local rc=0

    # 1. Удаление Telemt (стандартный)
    log_info "Удаление Telemt (стандартный)..."
    # -l 2 обязателен: без него upstream уходит в интерактивный вопрос выбора языка
    ssh $SSH_OPTS "$user@$ip" "curl -fsSL https://raw.githubusercontent.com/telemt/telemt/main/install.sh | sh -s -- purge -l 2" 2>/dev/null
    rc=$?
    [[ $rc -ne 0 ]] && { had_error=1; log_warning "Шаг 1 (Telemt) завершился с кодом $rc."; }

    # 2. Удаление Telemt Docker
    log_info "Удаление Telemt (Docker)..."
    ssh $SSH_OPTS "$user@$ip" "bash -c 'cd /root/telemt 2>/dev/null && docker compose down -v 2>/dev/null; cd /root && rm -rf /root/telemt 2>/dev/null; docker rmi ghcr.io/telemt/telemt:* 2>/dev/null || true'" 2>/dev/null
    rc=$?
    [[ $rc -ne 0 ]] && { had_error=1; log_warning "Шаг 2 (Telemt Docker) завершился с кодом $rc."; }

    # 3. Удаление MTProtoZig
    log_info "Удаление MTProtoZig..."
    ssh $SSH_OPTS "$user@$ip" "sudo mtbuddy uninstall --yes" 2>/dev/null
    rc=$?
    [[ $rc -ne 0 ]] && { had_error=1; log_warning "Шаг 3a (mtbuddy uninstall) завершился с кодом $rc."; }
    ssh $SSH_OPTS "$user@$ip" "systemctl stop mtproto-proxy 2>/dev/null; systemctl disable mtproto-proxy 2>/dev/null; rm -f /etc/systemd/system/mtproto-proxy.service; pkill -f mtbuddy 2>/dev/null || true" 2>/dev/null
    rc=$?
    [[ $rc -ne 0 ]] && { had_error=1; log_warning "Шаг 3b (mtproto-proxy) завершился с кодом $rc."; }

    # 4. Удаление MTG
    log_info "Удаление MTG..."
    ssh $SSH_OPTS "$user@$ip" "systemctl stop mtg.service 2>/dev/null; systemctl disable mtg.service 2>/dev/null; rm -f /etc/systemd/system/mtg.service 2>/dev/null; rm -f /usr/local/bin/mtg 2>/dev/null; rm -f /etc/mtg.toml 2>/dev/null; rm -f /opt/mtpr-simple/mtg_config_path 2>/dev/null" 2>/dev/null
    rc=$?
    [[ $rc -ne 0 ]] && { had_error=1; log_warning "Шаг 4 (MTG) завершился с кодом $rc."; }

    # 5. Удаление MEKO FIX (SYN FIX)
    log_info "Удаление MEKO FIX (SYN FIX)..."
    ssh $SSH_OPTS "$user@$ip" "bash -c '
        iptables -D INPUT -j MTPR_SYNFIX 2>/dev/null
        iptables -F MTPR_SYNFIX 2>/dev/null
        iptables -X MTPR_SYNFIX 2>/dev/null
        nft delete table inet mtpr_synfix 2>/dev/null
        nft delete table ip MTProto 2>/dev/null
        systemctl stop mtpr-synfix.service mtpr-nft-synfix.service mtpr-zapret2.service 2>/dev/null
        systemctl disable mtpr-synfix.service mtpr-nft-synfix.service mtpr-zapret2.service 2>/dev/null
        rm -f /etc/systemd/system/mtpr-*.service 2>/dev/null
        rm -rf /opt/zapret2 2>/dev/null
        rm -rf /etc/zapret2 2>/dev/null
        rm -f /opt/mtpr-simple/apply-mtpr-synfix.sh 2>/dev/null
        rm -f /opt/mtpr-simple/mtpr-synfix-nft.sh 2>/dev/null
        rm -f /opt/mtpr-simple/port 2>/dev/null
    '" 2>/dev/null
    rc=$?
    [[ $rc -ne 0 ]] && { had_error=1; log_warning "Шаг 5 (MEKO FIX) завершился с кодом $rc."; }

    # 6. Удаление 3xUI
    log_info "Удаление 3xUI..."
    ssh $SSH_OPTS "$user@$ip" "bash -c 'echo y | x-ui uninstall 2>/dev/null; systemctl stop x-ui 2>/dev/null; systemctl disable x-ui 2>/dev/null; rm -rf /etc/3x-ui /usr/local/x-ui 2>/dev/null'" 2>/dev/null
    rc=$?
    [[ $rc -ne 0 ]] && { had_error=1; log_warning "Шаг 6 (3xUI) завершился с кодом $rc."; }

    # 7. Очистка остатков MEKO
    log_info "Удаление каталогов MEKO..."
    ssh $SSH_OPTS "$user@$ip" "rm -rf /opt/mtpr-simple /opt/telemt /etc/telemt /etc/telemt.toml /opt/mtproto-proxy 2>/dev/null" 2>/dev/null
    rc=$?
    [[ $rc -ne 0 ]] && { had_error=1; log_warning "Шаг 7 (каталоги MEKO) завершился с кодом $rc."; }

    if [[ $had_error -eq 0 ]]; then
        log_success "Очистка сервера $ip завершена."
    else
        log_warning "Очистка сервера $ip завершена с ошибками (см. предупреждения выше)."
    fi
    echo -n "Нажмите Enter для продолжения..."; { read -r _ </dev/tty; } 2>/dev/null || true
}

# ── Путь к локальному конфигу Telemt ───────────────────────
# Приоритет: путь из /opt/mtpr-simple/config_path, иначе /etc/telemt/telemt.toml.
get_local_config_path() {
    local cfgfile="/opt/mtpr-simple/config_path"
    if [ -s "$cfgfile" ]; then
        local p
        p=$(head -1 "$cfgfile" 2>/dev/null)
        if [ -n "$p" ] && [ "$p" != "skip" ] && [ -f "$p" ]; then
            echo "$p"
            return 0
        fi
    fi
    echo "/etc/telemt/telemt.toml"
}

# ── Парсинг клиентов из секции [access.users] ──────────────
# Формат Telemt: [access.users], записи "имя = \"секрет\"".
# Вывод: строки вида "имя:секрет" (по одной на клиента).
parse_clients_from_file() {
    local file="$1"
    [ -f "$file" ] || return 1
    sed -n '/^\[access\.users\]/,/^\[/p' "$file" 2>/dev/null \
        | grep -E '=' | grep -v '^[[:space:]]*#' \
        | while IFS='=' read -r _name _secret; do
            _name=$(echo "$_name" | tr -d ' "' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
            _secret=$(echo "$_secret" | tr -d ' "' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
            if [ -n "$_name" ] && [ -n "$_secret" ]; then
                echo "$_name:$_secret"
            fi
        done
}

# ── Синхронизация клиентов: локальная нода → удалённая ─────
# Добавляет на ноду только ОТСУТСТВУЮЩИХ клиентов (ничего не удаляет),
# перед правкой делает бэкап, затем restart telemt с проверкой is-active.
sync_clients_from_local() {
    local ip="$1"
    local user="$2"
    local port="$3"
    local SSH_OPTS="-o ConnectTimeout=5 -o ConnectionAttempts=2 -p $port"

    clear 2>/dev/null || true
    echo ""
    echo -e "  ${BOLD}Синхронизация клиентов: локальная нода → ${CYAN}$ip${NC}"
    echo -e "  ${DIM}══════════════════════════════════════════════════${NC}"

    # 1. Локальный конфиг
    local local_cfg
    local_cfg=$(get_local_config_path)
    if [ ! -f "$local_cfg" ]; then
        echo ""
        log_error "Локальный конфиг Telemt не найден: $local_cfg"
        log_info "Проверьте путь в /opt/mtpr-simple/config_path или /etc/telemt/telemt.toml."
        echo -n "Нажмите Enter для продолжения..."; { read -r _ </dev/tty; } 2>/dev/null || true
        return 1
    fi
    local local_clients
    local_clients=$(parse_clients_from_file "$local_cfg")
    echo ""
    log_info "Локальный конфиг: $local_cfg"
    if [ -z "$local_clients" ]; then
        log_warning "В локальном конфиге нет клиентов в секции [access.users]."
        echo -n "Нажмите Enter для продолжения..."; { read -r _ </dev/tty; } 2>/dev/null || true
        return 1
    fi

    # 2. Удалённый конфиг (путь + содержимое по SSH)
    local remote_cfg
    remote_cfg=$(ssh $SSH_OPTS "$user@$ip" 'p=""; if [ -s /opt/mtpr-simple/config_path ]; then p=$(head -1 /opt/mtpr-simple/config_path); fi; if [ -z "$p" ] || [ "$p" = "skip" ]; then p=/etc/telemt/telemt.toml; fi; echo "$p"' 2>/dev/null | tail -1)
    remote_cfg=$(trim "$remote_cfg")
    if [[ ! "$remote_cfg" =~ ^/[A-Za-z0-9_./-]+$ ]]; then
        echo ""
        log_error "Не удалось определить конфиг Telemt на ноде ($ip)."
        echo -n "Нажмите Enter для продолжения..."; { read -r _ </dev/tty; } 2>/dev/null || true
        return 1
    fi
    local remote_content
    remote_content=$(ssh $SSH_OPTS "$user@$ip" "cat '$remote_cfg'" 2>/dev/null)
    if [ -z "$remote_content" ]; then
        echo ""
        log_error "Не удалось прочитать конфиг на ноде: $remote_cfg"
        echo -n "Нажмите Enter для продолжения..."; { read -r _ </dev/tty; } 2>/dev/null || true
        return 1
    fi
    local tmp_remote
    tmp_remote=$(mktemp)
    printf '%s\n' "$remote_content" > "$tmp_remote"
    local remote_clients
    remote_clients=$(parse_clients_from_file "$tmp_remote")
    rm -f "$tmp_remote"

    log_info "Удалённый конфиг: $remote_cfg"

    # 3. Таблица сравнения
    echo ""
    printf "  %-24s %-10s %-10s %s\n" "Клиент" "Локально" "На ноде" "Действие"
    printf "  %-24s %-10s %-10s %s\n" "────────────────────────" "──────────" "──────────" "────────────────────────"
    local add_lines=""
    local add_count=0
    local skipped=0
    local name secret rsecret action
    while IFS=: read -r name secret; do
        [ -z "$name" ] && continue
        if [[ ! "$name" =~ ^[A-Za-z0-9_.-]+$ ]] || [[ ! "$secret" =~ ^[A-Za-z0-9+/=_-]+$ ]]; then
            printf "  %-24s %-10s %-10s %s\n" "$name" "да" "?" "пропущен (недопустимые символы)"
            skipped=$((skipped + 1))
            continue
        fi
        if printf '%s\n' "$remote_clients" | cut -d: -f1 | grep -qxF "$name"; then
            rsecret=$(printf '%s\n' "$remote_clients" | awk -F: -v n="$name" '$1==n{print substr($0, index($0,":")+1); exit}')
            if [ "$rsecret" = "$secret" ]; then
                action="уже есть"
            else
                action="уже есть (секрет отличается!)"
            fi
            printf "  %-24s %-10s %-10s %s\n" "$name" "да" "да" "$action"
        else
            printf "  %-24s %-10s %-10s %s\n" "$name" "да" "нет" "добавить"
            add_lines="${add_lines}${name}"$'\t'"${secret}"$'\n'
            add_count=$((add_count + 1))
        fi
    done <<< "$local_clients"

    # Клиенты, которых нет локально: НЕ удаляем, только предупреждаем.
    local extra_count=0
    local rname
    while IFS=: read -r rname _; do
        [ -z "$rname" ] && continue
        if ! printf '%s\n' "$local_clients" | cut -d: -f1 | grep -qxF "$rname"; then
            printf "  %-24s %-10s %-10s %s\n" "$rname" "нет" "да" "лишний (не удаляю)"
            extra_count=$((extra_count + 1))
        fi
    done <<< "$remote_clients"

    echo ""
    if [ "$add_count" -eq 0 ]; then
        log_success "Все локальные клиенты уже есть на ноде. Добавлять нечего."
        [ "$extra_count" -gt 0 ] && log_warning "На ноде $extra_count клиент(ов), которых нет локально — они не тронуты."
        echo -n "  Нажмите Enter для продолжения..."
        { read -r _ </dev/tty; } 2>/dev/null || { echo; return 0; }
        return 0
    fi
    log_info "К добавлению на ноду: $add_count клиент(ов)."
    [ "$extra_count" -gt 0 ] && log_warning "На ноде $extra_count лишних клиент(ов) — они не будут удалены."
    [ "$skipped" -gt 0 ] && log_warning "Пропущено некорректных записей: $skipped."
    echo ""
    echo -en "  ${BOLD}Продолжить? [y/N]:${NC} "
    local confirm
    { read -r confirm </dev/tty; } 2>/dev/null || { echo; log_info "Нет доступа к терминалу — отмена"; return 0; }
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        log_info "Отмена"
        return 0
    fi

    # 4. Применение на ноде: бэкап → правка → verify (если есть) → restart
    local ts
    ts=$(date +%Y%m%d-%H%M%S)
    local b64
    b64=$(printf '%s' "$add_lines" | base64 | tr -d '\n')
    echo ""
    log_info "Применяю на ноде (бэкап: ${remote_cfg}.bak.${ts})..."

    # #1: base64-пayload содержит секреты клиентов — НЕ передаём его
    # аргументом SSH-команды (argv виден в `ps` и ограничен ARG_MAX).
    # Payload подставляется в тело скрипта, а тело уходит на ноду по stdin.
    local apply_out _remote_script
    _remote_script=$(cat <<'REMOTE_SYNC'
set -u
CFG="$1"
TS="$2"
B64='__B64PAYLOAD__'

[ -f "$CFG" ] || { echo "ERR_NO_CFG"; exit 11; }

BAK="${CFG}.bak.${TS}"
cp -a "$CFG" "$BAK" || { echo "ERR_BACKUP"; exit 12; }
echo "BACKUP=$BAK"

PAYLOAD=$(printf '%s' "$B64" | base64 -d 2>/dev/null) || { echo "ERR_B64"; exit 13; }
[ -n "$PAYLOAD" ] || { echo "ERR_EMPTY_PAYLOAD"; exit 14; }

BLOCK=$(printf '%s\n' "$PAYLOAD" | while IFS="$(printf '\t')" read -r _n _s; do
    [ -n "$_n" ] && printf '%s = "%s"\n' "$_n" "$_s"
done)
[ -n "$BLOCK" ] || { echo "ERR_EMPTY_BLOCK"; exit 15; }

# #8: временный файл кладём в ТОТ ЖЕ каталог, что и конфиг, и записываем через
# mv — запись атомарна. Прежний код (cat > CFG) при обрыве/ENOSPC оставлял
# конфиг усечённым и не восстанавливал бэкап в ветке ERR_WRITE.
_cfg_dir=$(dirname "$CFG")
TMP=$(mktemp "${_cfg_dir}/.telemt-sync.XXXXXX") || { echo "ERR_TMP"; exit 16; }
START=$(grep -n '^\[access\.users\]' "$CFG" | head -1 | cut -d: -f1)

if [ -z "$START" ]; then
    # #10: точная секция [access.users] не найдена. Если есть альтернативная
    # форма ([access], [[access.users]], inline) — угадывать нельзя: дописали бы
    # ВТОРУЮ секцию. Отказываем явно.
    if grep -qE '^\[\[?access\.users\]\]?|^\[access\]|^[[:space:]]*access[[:space:]]*=[[:space:]]*\{' "$CFG"; then
        echo "ERR_FORMAT"
        rm -f "$TMP"
        exit 23
    fi
    cat "$CFG" > "$TMP" || { echo "ERR_COPY"; rm -f "$TMP"; exit 17; }
    printf '\n[access.users]\n%s\n' "$BLOCK" >> "$TMP"
else
    awk -v s="$START" -v ins="$BLOCK" 'NR==s { print; printf "%s\n", ins; next } { print }' "$CFG" > "$TMP" || { echo "ERR_AWK"; rm -f "$TMP"; exit 18; }
fi

# mv сохраняет права/владельца временного файла, поэтому переносим их с оригинала.
_perm=$(stat -c '%a' "$CFG" 2>/dev/null || echo 640)
_owner=$(stat -c '%u:%g' "$CFG" 2>/dev/null || echo 0:0)
chmod "$_perm" "$TMP" 2>/dev/null || true
chown "$_owner" "$TMP" 2>/dev/null || true

if ! mv -f "$TMP" "$CFG"; then
    echo "ERR_WRITE"
    cp -a "$BAK" "$CFG" 2>/dev/null || true
    echo "ROLLBACK=write"
    rm -f "$TMP" 2>/dev/null || true
    exit 19
fi
echo "APPLIED"

if command -v telemt >/dev/null 2>&1 && telemt --help 2>&1 | grep -q 'verify'; then
    if telemt --config "$CFG" verify >/dev/null 2>&1; then
        echo "VERIFY=ok"
    else
        echo "VERIFY=fail"
        cp -a "$BAK" "$CFG" 2>/dev/null || true
        echo "ROLLBACK=verify"
        exit 20
    fi
else
    echo "VERIFY=skip"
    # #9: tomllib есть только в Python 3.11+. На Ubuntu 22.04 / Debian 11 /
    # RHEL 8-9 его нет, и ImportError НЕ означает невалидный конфиг — пропускаем
    # проверку (TOML=skip), не откатываем рабочую синхронизацию.
    if command -v python3 >/dev/null 2>&1 && python3 -c 'import tomllib' >/dev/null 2>&1; then
        if python3 -c 'import sys,tomllib; tomllib.load(open(sys.argv[1],"rb"))' "$CFG" >/dev/null 2>&1; then
            echo "TOML=ok"
        else
            echo "TOML=fail"
            cp -a "$BAK" "$CFG" 2>/dev/null || true
            echo "ROLLBACK=toml"
            exit 22
        fi
    else
        echo "TOML=skip"
    fi
fi

if command -v systemctl >/dev/null 2>&1; then
    systemctl restart telemt >/dev/null 2>&1
    _rc=$?
    sleep 1
    if [ "$_rc" -eq 0 ] && systemctl is-active --quiet telemt; then
        echo "RESTART=ok"
    else
        echo "RESTART=fail"
        cp -a "$BAK" "$CFG" 2>/dev/null || true
        systemctl restart telemt >/dev/null 2>&1 || true
        echo "ROLLBACK=restart"
        exit 21
    fi
else
    echo "RESTART=skip"
fi

echo "SYNC_OK"
exit 0
REMOTE_SYNC
)
    apply_out=$(printf '%s' "${_remote_script/__B64PAYLOAD__/$b64}" | ssh $SSH_OPTS "$user@$ip" "bash -s -- '$remote_cfg' '$ts'" 2>/dev/null)
    local apply_rc=$?

    # 5. Честный итог
    echo ""
    echo "$apply_out" | while IFS= read -r _line; do
        case "$_line" in
            BACKUP=*)    log_info "Бэкап конфига ноды: ${_line#BACKUP=}" ;;
            APPLIED)     log_success "Клиенты добавлены в конфиг ноды." ;;
            VERIFY=ok)   log_success "Проверка конфига (telemt verify): ok." ;;
            VERIFY=skip) log_info "telemt verify недоступен — проверка пропущена." ;;
            TOML=ok)     log_success "Конфиг ноды валиден (tomllib)." ;;
            TOML=skip)   log_warning "python3 недоступен — TOML-проверка пропущена." ;;
            TOML=fail)   log_error "Конфиг ноды невалиден (tomllib) — выполнен откат из бэкапа." ;;
            RESTART=ok)  log_success "Telemt на ноде перезапущен, is-active: ok." ;;
            RESTART=skip) log_warning "systemctl недоступен — сервис не перезапущен." ;;
            VERIFY=fail) log_error "Проверка конфига не прошла — выполнен откат из бэкапа." ;;
            RESTART=fail) log_error "Telemt не поднялся — конфиг откачен из бэкапа." ;;
            ERR_FORMAT)  log_error "Формат секции [access.users] на ноде не распознан — синхронизация отменена." ;;
            ERR_*)       log_error "Ошибка на ноде: $_line" ;;
            ROLLBACK=*)  log_warning "Выполнен откат (${_line#ROLLBACK=})." ;;
        esac
    done

    if [ "$apply_rc" -eq 0 ] && echo "$apply_out" | grep -q '^SYNC_OK$'; then
        log_success "Синхронизация завершена: добавлено клиентов — $add_count."
    else
        log_warning "Синхронизация НЕ завершена успешно (код $apply_rc). Конфиг ноды не изменён или откачен."
    fi
    echo -n "  Нажмите Enter для продолжения..."
    { read -r _ </dev/tty; } 2>/dev/null || { echo; return 1; }
}

# ── Список серверов ─────────────────────────────────────────
list_servers() {
    clear 2>/dev/null || true
    local servers=()
    mapfile -t servers < <(get_servers)
    if [[ ${#servers[@]} -eq 0 ]]; then
        echo ""
        log_warning "Нет сохранённых серверов. Добавьте их с помощью пункта [1]"
        echo -n "  Нажмите Enter чтобы вернуться в меню"; { read -r _ </dev/tty; } 2>/dev/null || true
        return 0
    fi

    echo ""
    echo -e "  ${BOLD}Список серверов${NC}"
    echo -e "  ${DIM}═════════════════════════════════════${NC}"
    local i=1
    for srv in "${servers[@]}"; do
        echo -e "  ${CYAN}[$i]${NC} $srv"
        ((i++))
    done
    echo -e "  ${CYAN}[0]${NC} Назад"
    echo ""
    echo -en "  ${BOLD}Выберите номер сервера (или 0):${NC} "
    local choice
    { read -r choice </dev/tty; } 2>/dev/null || { echo; return 0; }

    if [[ ! "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -gt ${#servers[@]} ]]; then
        log_error "Неверный номер."
        echo -n "Нажмите Enter для продолжения..."; { read -r _ </dev/tty; } 2>/dev/null || true
        return 1
    fi
    [[ "$choice" -eq 0 ]] && return 0
    local selected_ip="${servers[$((choice-1))]}"
    server_submenu "$selected_ip"
}

# ── Подменю для сервера ──────────────────────────────────────
server_submenu() {
    local ip="$1"
    local config
    config=$(load_server_config "$ip") || return 1
    local user="${config%% *}"
    local port="${config##* }"

    if [[ -z "$user" ]]; then
        log_error "Не удалось загрузить конфиг для $ip."
        echo -n "Нажмите Enter для продолжения..."; { read -r _ </dev/tty; } 2>/dev/null || true
        return 1
    fi

    while true; do
        clear 2>/dev/null || true
        echo ""
        echo -e "  ${BOLD}Меню сервера: ${CYAN}${user}@${ip}${NC}${BOLD}:$port${NC}"
        echo -e "  ${DIM}════════════════════════════════════════════════════${NC}"
        echo -e ""
        echo -e "  ${CYAN}[1]${NC}${BOLD} Проверить статус ноды (онлайн/оффлайн)"
        echo -e ""
        echo -e "  ${CYAN}[2]${NC}${BOLD} Меню работы с прокси"
        echo -e "  ${CYAN}[3]${NC}${BOLD} Синхронизировать клиентов с локальной нодой"
        echo -e "  ${CYAN}[4]${NC}${BOLD} Выполнить произвольную команду"
        echo -e "  ${CYAN}[5]${RED}${BOLD} Удалить сервер ${NC}(отозвать ключ и конфиг)${NC}"
        echo -e "  ${CYAN}[6]${YELLOW}${BOLD} Очистить всё на сервере ${NC}(прокси + фиксы)${NC}"
        echo -e "  ${CYAN}[7]${NC} ${BOLD}Меню фиксов (SYN FIX/Zapret2)${NC}"
        echo -e ""
        echo -e "  ${CYAN}[0]${NC}${BOLD} Назад"
        echo ""
        echo -en "  ${BOLD}Ввод:${NC} "
        local act
        { read -r act </dev/tty; } 2>/dev/null || { echo; return 0; }

        case "$act" in
            1)
                echo ""
                log_info "Проверка доступа..."
                if check_ssh_key "$user" "$ip" "$port"; then
                    log_success "Сервер доступен (SSH-ключ работает)."
                    ssh -o ConnectTimeout=5 -p "$port" "$user@$ip" "uptime" 2>/dev/null || log_warning "Не удалось выполнить команду."
                else
                    log_error "Сервер недоступен или ключ не работает."
                fi
                echo -n "Нажмите Enter для продолжения..."; { read -r _ </dev/tty; } 2>/dev/null || true
                ;;
            2)
                echo ""
                local NODE_TELEMT_SCRIPT="$SCRIPT_DIR/telemt1_node.sh"
                if [ -f "$NODE_TELEMT_SCRIPT" ]; then
                    # НЕ exec: exec подменял процесс, и выход из подменю
                    # выбрасывал пользователя в шелл. Дочерний запуск
                    # возвращает управление в это меню.
                    bash "$NODE_TELEMT_SCRIPT" "$ip" "$user" "$port" || true
                    continue
                else
                    log_error "Скрипт $NODE_TELEMT_SCRIPT не найден."
                    echo -n "Нажмите Enter для продолжения..."; { read -r _ </dev/tty; } 2>/dev/null || true
                fi
                ;;
            3)
                sync_clients_from_local "$ip" "$user" "$port"
                ;;
            4)
                echo ""
                echo -en "  ${BOLD}Введите команду для выполнения на сервере:${NC} "
                local cmd
                { read -r cmd </dev/tty; } 2>/dev/null || { echo; return 0; }
                if [[ -n "$cmd" ]]; then
                    echo ""
                    ssh -o ConnectTimeout=5 -p "$port" "$user@$ip" "$cmd"
                else
                    log_warning "Команда не введена."
                fi
                echo -n "Нажмите Enter для продолжения..."; { read -r _ </dev/tty; } 2>/dev/null || true
                ;;
            5)
                remove_server "$ip" "$user" "$port"
                return 0  # выходим из подменю, возвращаемся в список
                ;;
            6)
                clean_all_on_server "$ip" "$user" "$port"
                ;;
            7)
                echo ""
                local NODE_RULES_SCRIPT="$SCRIPT_DIR/rules1_node.sh"
                if [ -f "$NODE_RULES_SCRIPT" ]; then
                    # НЕ exec (см. комментарий у пункта [2]).
                    bash "$NODE_RULES_SCRIPT" "$ip" "$user" "$port" || true
                    continue
                else
                    log_error "Скрипт $NODE_RULES_SCRIPT не найден."
                    echo -n "Нажмите Enter для продолжения..."; { read -r _ </dev/tty; } 2>/dev/null || true
                fi
                ;;
            0)
                break
                ;;
            *)
                log_error "Неверный выбор."
                echo -n "Нажмите Enter для продолжения..."; { read -r _ </dev/tty; } 2>/dev/null || true
                ;;
        esac
    done
}

# ── Главное меню ─────────────────────────────────────────────
main_menu() {
    while true; do
        clear 2>/dev/null || true
        local server_count
        server_count=$(get_server_count)
        echo ""
        echo -e "  ${BOLD}MEKO ${CYAN}| ${NC}${BOLD}NODE MANAGER v0.1 ${NC}"
        echo -e "  ${DIM}══════════════════════════════════════════════${NC}"
        echo -e "  ${BOLD}Подключено серверов:${NC} ${CYAN}${server_count}${NC}"
        echo ""
        echo -e "  ${CYAN}[1]${NC}${BOLD} Добавить сервер"
        echo -e "  ${CYAN}[2]${NC}${BOLD} Список серверов"
        echo -e ""
        echo -e "  ${RED}${BOLD}[0]${NC}${BOLD} Выход"
        echo ""
        echo -en "  ${BOLD}Ввод:${NC} "
        local choice
        { read -r choice </dev/tty; } 2>/dev/null || { echo; break; }

        case "$choice" in
            1) add_server ;;
            2) list_servers ;;
            0) echo "" ; log_info "Выход." ; exit 0 ;;
            *) log_error "Неверный выбор." ; { read -r _ </dev/tty; } 2>/dev/null || true ;;
        esac
    done
}

# ── Запуск ────────────────────────────────────────────────────
main_menu
