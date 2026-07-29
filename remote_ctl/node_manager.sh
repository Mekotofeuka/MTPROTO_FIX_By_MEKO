#!/bin/bash
# remote_ctl/node_manager.sh – управление удалёнными нодами

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
        log_error "Требуются права root для управления SSH-ключами"
        exit 1
    fi
}
check_root

# ── Конфигурация ─────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
    local servers=()
    if [[ -d "$SERVERS_DIR" ]]; then
        for f in "$SERVERS_DIR"/*.conf; do
            [[ -f "$f" ]] && servers+=("$(basename "$f" .conf)")
        done
    fi
    echo "${servers[@]}"
}

get_server_count() {
    local servers=($(get_servers))
    echo ${#servers[@]}
}

# ── Загрузка конфига сервера ──────────────────────────────
load_server_config() {
    local ip="$1"
    local conf_file="$SERVERS_DIR/$ip.conf"
    [[ ! -f "$conf_file" ]] && return 1
    source "$conf_file"
    echo "$USER" "$PORT"
}

# ── Сохранение конфига ──────────────────────────────────────
save_server_config() {
    local ip="$1"
    local user="$2"
    local port="$3"
    cat > "$SERVERS_DIR/$ip.conf" <<EOF
USER="$user"
PORT="$port"
EOF
}

# ── Проверка доступа по ключу ──────────────────────────────
check_ssh_key() {
    local user="$1"
    local ip="$2"
    local port="${3:-22}"
    ssh -o BatchMode=yes -o ConnectTimeout=5 -o Port="$port" "$user@$ip" "exit" &>/dev/null
    return $?
}

# ── Парсинг ввода (user@ip, ssh user@ip, ip) ──────────────
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

    if [[ ! "$ip" =~ ^[a-zA-Z0-9.-]+$ ]]; then
        echo "❌ Некорректный адрес: $ip" >&2
        return 1
    fi

    echo "$user" "$ip"
    return 0
}

# ── Добавление сервера ──────────────────────────────────────
add_server() {
    clear
    echo ""
    echo -e "  ${BOLD}Добавление нового сервера${NC}"
    echo -e "  ${DIM}═════════════════════════════════════${NC}"
    echo ""
    echo -en "  ${BOLD}Введите IP или строку типа ${CYAN}'root@1.2.3.4'${NC} (или ${CYAN}'ssh root@1.2.3.4'${NC}): "
    local input
    read -r input

    local parsed
    parsed=($(parse_input "$input")) || { read -p "Нажмите Enter для возврата..." ; return 1; }
    local user="${parsed[0]}"
    local ip="${parsed[1]}"

    if [[ -f "$SERVERS_DIR/$ip.conf" ]]; then
        echo ""
        echo -en "  ${BOLD}Сервер $ip уже добавлен. Перезаписать? [y/N]:${NC} "
        local overwrite
        read -r overwrite
        if [[ ! "$overwrite" =~ ^[yY]$ ]]; then
            log_info "Отмена"
            read -p "Нажмите Enter для продолжения..." 
            return 0
        fi
    fi

    echo -en "  ${BOLD}Порт SSH (по умолчанию ${GREEN}22${NC}${BOLD}):${NC} "
    local port
    read -r port
    port=${port:-22}

    ensure_ssh_key

    if check_ssh_key "$user" "$ip" "$port"; then
        log_success "Доступ по ключу уже настроен."
    else
        echo ""
        log_info "Доступ по ключу отсутствует. Будет выполнена команда:"
        echo -e "  ${CYAN}ssh-copy-id -p $port $user@$ip${NC}"
        echo -e "  ${BOLD}Введите пароль пользователя ${GREEN}$user${NC}${BOLD}, если потребуется.${NC}"
        ssh-copy-id -p "$port" "$user@$ip"
        if [[ $? -eq 0 ]]; then
            log_success "Ключ успешно скопирован."
        else
            log_error "Не удалось скопировать ключ. Проверьте пароль и доступность."
            read -p "Нажмите Enter для продолжения..."
            return 1
        fi
    fi

    save_server_config "$ip" "$user" "$port"
    log_success "Сервер $ip сохранён."
    read -p "Нажмите Enter для продолжения..."
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
    read -r confirm
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        log_info "Отмена"
        return 0
    fi

    log_info "Удаление конфига сервера..."
    rm -f "$SERVERS_DIR/$ip.conf"
    log_success "Конфиг удалён."

    log_info "Отзыв SSH-ключа на сервере..."
    local pub_key=$(cat ~/.ssh/id_rsa.pub)
    local escaped_key=$(echo "$pub_key" | sed 's/[\/&]/\\&/g')
    ssh -p "$port" "$user@$ip" "sed -i '/$escaped_key/d' ~/.ssh/authorized_keys" 2>/dev/null || true
    if [[ $? -eq 0 ]]; then
        log_success "Ключ удалён из ~/.ssh/authorized_keys на сервере."
    else
        log_warning "Не удалось удалить ключ (возможно, его там нет или доступ уже потерян)."
    fi

    log_success "Сервер $ip полностью удалён."
    read -p "Нажмите Enter для продолжения..."
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
    read -r confirm
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        log_info "Отмена"
        return 0
    fi

    log_info "Начинаем очистку сервера $ip..."

    # 1. Удаление Telemt (стандартный)
    log_info "Удаление Telemt (стандартный)..."
    ssh -p "$port" "$user@$ip" "curl -fsSL https://raw.githubusercontent.com/telemt/telemt/main/install.sh | sh -s -- purge" 2>/dev/null || true

    # 2. Удаление Telemt Docker
    log_info "Удаление Telemt (Docker)..."
    ssh -p "$port" "$user@$ip" "bash -c 'cd /root/telemt 2>/dev/null && docker compose down -v 2>/dev/null; cd /root && rm -rf /root/telemt 2>/dev/null; docker rmi ghcr.io/telemt/telemt:* 2>/dev/null || true'" 2>/dev/null || true

    # 3. Удаление MTProtoZig
    log_info "Удаление MTProtoZig..."
    ssh -p "$port" "$user@$ip" "sudo mtbuddy uninstall --yes" 2>/dev/null || true
    ssh -p "$port" "$user@$ip" "systemctl stop mtproto-proxy 2>/dev/null; systemctl disable mtproto-proxy 2>/dev/null; rm -f /etc/systemd/system/mtproto-proxy.service; pkill -f mtbuddy 2>/dev/null || true" 2>/dev/null || true

    # 4. Удаление MTG
    log_info "Удаление MTG..."
    ssh -p "$port" "$user@$ip" "systemctl stop mtg.service 2>/dev/null; systemctl disable mtg.service 2>/dev/null; rm -f /etc/systemd/system/mtg.service 2>/dev/null; rm -f /usr/local/bin/mtg 2>/dev/null; rm -f /etc/mtg.toml 2>/dev/null; rm -f /opt/mtpr-simple/mtg_config_path 2>/dev/null" 2>/dev/null || true

    # 5. Удаление MEKO FIX (SYN FIX)
    log_info "Удаление MEKO FIX (SYN FIX)..."
    ssh -p "$port" "$user@$ip" "bash -c '
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
    '" 2>/dev/null || true

    # 6. Удаление 3xUI
    log_info "Удаление 3xUI..."
    ssh -p "$port" "$user@$ip" "bash -c 'echo y | x-ui uninstall 2>/dev/null; systemctl stop x-ui 2>/dev/null; systemctl disable x-ui 2>/dev/null; rm -rf /etc/3x-ui /usr/local/x-ui 2>/dev/null'" 2>/dev/null || true

    # 7. Очистка остатков MEKO
    log_info "Удаление каталогов MEKO..."
    ssh -p "$port" "$user@$ip" "rm -rf /opt/mtpr-simple /opt/telemt /etc/telemt /etc/telemt.toml /opt/mtproto-proxy 2>/dev/null || true" 2>/dev/null || true

    log_success "Очистка сервера $ip завершена."
    read -p "Нажмите Enter для продолжения..."
}

# ── Список серверов ─────────────────────────────────────────
list_servers() {
    clear
    local servers=($(get_servers))
    if [[ ${#servers[@]} -eq 0 ]]; then
        echo ""
        log_warning "Нет сохранённых серверов."
        read -p "Нажмите Enter для продолжения..."
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
    read -r choice

    if [[ "$choice" -eq 0 ]]; then
        return 0
    fi
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 1 ]] || [[ "$choice" -gt ${#servers[@]} ]]; then
        log_error "Неверный номер."
        read -p "Нажмите Enter для продолжения..."
        return 1
    fi
    local selected_ip="${servers[$((choice-1))]}"
    server_submenu "$selected_ip"
}

# ── Подменю для сервера ──────────────────────────────────────
server_submenu() {
    local ip="$1"
    local config
    config=($(load_server_config "$ip"))
    local user="${config[0]}"
    local port="${config[1]}"

    if [[ -z "$user" ]]; then
        log_error "Не удалось загрузить конфиг для $ip."
        read -p "Нажмите Enter для продолжения..."
        return 1
    fi

    while true; do
        clear
        echo ""
        echo -e "  ${BOLD}Управление сервером: ${CYAN}${user}@${ip}${NC}${BOLD} (порт $port)${NC}"
        echo -e ""
        echo -e "  ${DIM}════════════════════════════════════════════════════${NC}"
        echo -e "  ${CYAN}[1]${NC} Проверить статус (онлайн/оффлайн)"
        echo -e "  ${CYAN}[2]${NC} Меню работы с прокси"
        echo -e "  ${CYAN}[3]${NC} Удалить прокси (заглушка)"
        echo -e "  ${CYAN}[4]${NC} Выполнить произвольную команду"
        echo -e "  ${CYAN}[5]${RED}${BOLD} Удалить сервер ${NC}(отозвать ключ и конфиг)${NC}"
        echo -e "  ${CYAN}[6]${YELLOW}${BOLD} Очистить всё на сервере ${NC}(прокси + фиксы)${NC}"
        echo -e "  ${CYAN}[7]${NC} ${BOLD}Меню фиксов (SYN FIX/Zapret2)${NC}"
        echo -e "  ${CYAN}[0]${NC} Назад"
        echo ""
        echo -en "  ${BOLD}Выберите действие:${NC} "
        local act
        read -r act

        case "$act" in
            1)
                echo ""
                log_info "Проверка доступа..."
                if check_ssh_key "$user" "$ip" "$port"; then
                    log_success "Сервер доступен (SSH-ключ работает)."
                    ssh -p "$port" "$user@$ip" "uptime" 2>/dev/null || log_warning "Не удалось выполнить команду."
                else
                    log_error "Сервер недоступен или ключ не работает."
                fi
                read -p "Нажмите Enter для продолжения..."
                ;;
            2)
                echo ""
                local NODE_TELEMT_SCRIPT="$SCRIPT_DIR/telemt1_node.sh"
                if [ -f "$NODE_TELEMT_SCRIPT" ]; then
                    exec "$NODE_TELEMT_SCRIPT" "$ip" "$user" "$port"
                else
                    log_error "Скрипт $NODE_TELEMT_SCRIPT не найден."
                    read -p "Нажмите Enter для продолжения..."
                fi
                ;;
            3)
                echo ""
                log_info "🗑 Удаление прокси (заглушка) — позже будет реализована."
                read -p "Нажмите Enter для продолжения..."
                ;;
            4)
                echo ""
                echo -en "  ${BOLD}Введите команду для выполнения на сервере:${NC} "
                local cmd
                read -r cmd
                if [[ -n "$cmd" ]]; then
                    echo ""
                    ssh -p "$port" "$user@$ip" "$cmd"
                else
                    log_warning "Команда не введена."
                fi
                read -p "Нажмите Enter для продолжения..."
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
                    exec "$NODE_RULES_SCRIPT" "$ip" "$user" "$port"
                else
                    log_error "Скрипт $NODE_RULES_SCRIPT не найден."
                    read -p "Нажмите Enter для продолжения..."
                fi
                ;;
            0)
                break
                ;;
            *)
                log_error "Неверный выбор."
                read -p "Нажмите Enter для продолжения..."
                ;;
        esac
    done
}

# ── Главное меню ─────────────────────────────────────────────
main_menu() {
    while true; do
        clear
        local server_count=$(get_server_count)
        echo ""
        echo -e "  ${BOLD}MEKO ${CYAN}| ${NC}${BOLD}NODE MANAGER v0.1 ${NC}"
        echo -e "  ${DIM}══════════════════════════════════════════════${NC}"
        echo -e "  ${BOLD}Подключено серверов:${NC} ${CYAN}${server_count}${NC}"
        echo ""
        echo -e "  ${CYAN}[1]${NC} Добавить сервер"
        echo -e "  ${CYAN}[2]${NC} Список серверов"
        echo -e "  ${CYAN}[0]${NC} Выход"
        echo ""
        echo -en "  ${BOLD}Выберите действие:${NC} "
        local choice
        read -r choice

        case "$choice" in
            1) add_server ;;
            2) list_servers ;;
            0) echo "" ; log_info "Выход." ; exit 0 ;;
            *) log_error "Неверный выбор." ; read -p "Нажмите Enter для продолжения..." ;;
        esac
    done
}

# ── Запуск ────────────────────────────────────────────────────
main_menu
