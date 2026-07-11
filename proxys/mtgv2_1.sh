#!/bin/bash
# mtgv2_1.sh – управление MTG (MTProto Go proxy)

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

# ── Файл для сохранения пути к конфигу (как в telemt1.sh) ──
CONFIG_PATH_FILE="/opt/mtpr-simple/mtg_config_path"

# ── Функция обрезки пробелов ──────────────────────────────
trim() {
    local var="$1"
    var="${var#"${var%%[![:space:]]*}"}"
    var="${var%"${var##*[![:space:]]}"}"
    printf '%s' "$var"
}

# ── Функция получения текущего пути к конфигу MTG ──────────
get_config_path() {
    if [ -f "$CONFIG_PATH_FILE" ] && [ -s "$CONFIG_PATH_FILE" ]; then
        path=$(cat "$CONFIG_PATH_FILE")
        if [ "$path" != "skip" ]; then
            echo "$path"
            return 0
        fi
    fi
    echo "/etc/mtg.toml"
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

# ── Проверка установки MTG ──────────────────────────────────
is_mtg_installed() {
    command -v mtg >/dev/null 2>&1
}

get_mtg_version() {
    if command -v mtg >/dev/null 2>&1; then
        mtg --version 2>/dev/null | head -1 | awk '{print $2}'
    else
        echo ""
    fi
}

# ── Получение порта из конфига MTG ──────────────────────────
get_mtg_port() {
    local _cfg="$1"
    _cfg=$(trim "$_cfg")
    if [ -z "$_cfg" ] || [ ! -f "$_cfg" ]; then
        echo ""
        return 1
    fi
    # Сначала ищем bind-to, потом port (если есть)
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

# ── Получение секрета из конфига ────────────────────────────
get_mtg_secret() {
    local _cfg="$1"
    _cfg=$(trim "$_cfg")
    if [ -z "$_cfg" ] || [ ! -f "$_cfg" ]; then
        echo ""
        return 1
    fi
    grep -E '^secret[[:space:]]*=' "$_cfg" 2>/dev/null | head -1 | sed -E 's/^[[:space:]]*secret[[:space:]]*=[[:space:]]*"//; s/".*$//'
}

# ── Получение публичного IP ──────────────────────────────────
get_public_ip() {
    local _ip=""
    _ip=$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null) ||
    _ip=$(curl -4 -fsS --max-time 5 https://ifconfig.me 2>/dev/null) ||
    _ip=$(curl -4 -fsS --max-time 5 https://icanhazip.com 2>/dev/null) ||
    _ip=""
    echo "$_ip"
}

# ── Генерация ссылок через mtg access ──────────────────────
generate_proxy_links() {
    local config_path=$(get_config_path)
    if [ ! -f "$config_path" ]; then
        return 1
    fi

    # Проверяем, есть ли jq для парсинга JSON
    if ! command -v jq &>/dev/null; then
        echo -e "  ${YELLOW}[!] jq не установлен, устанавливаю...${NC}"
        if command -v apt-get &>/dev/null; then
            apt-get update -qq && apt-get install -y -qq jq
        elif command -v yum &>/dev/null; then
            yum install -y -q jq
        elif command -v dnf &>/dev/null; then
            dnf install -y -q jq
        elif command -v apk &>/dev/null; then
            apk add --no-cache jq
        else
            echo -e "  ${RED}[✗] Не удалось установить jq. Установите вручную.${NC}"
            return 1
        fi
    fi

    local output
    output=$(mtg access "$config_path" 2>/dev/null)
    if [ $? -ne 0 ] || [ -z "$output" ]; then
        echo -e "  ${RED}[✗] Не удалось получить ссылки. Проверьте, что MTG запущен.${NC}"
        return 1
    fi

    # Парсим JSON
    local tg_url
    tg_url=$(echo "$output" | jq -r '.ipv4.tg_url // empty' 2>/dev/null)
    if [ -n "$tg_url" ]; then
        echo -e "  ${BOLD}Ссылка для подключения (IPv4):${NC}"
        echo -e "  ${CYAN}${tg_url}${NC}"
        echo ""
    fi

    local tme_url
    tme_url=$(echo "$output" | jq -r '.ipv4.tme_url // empty' 2>/dev/null)
    if [ -n "$tme_url" ]; then
        echo -e "  ${BOLD}Альтернативная ссылка (t.me):${NC}"
        echo -e "  ${CYAN}${tme_url}${NC}"
        echo ""
    fi

    local secret_hex
    secret_hex=$(echo "$output" | jq -r '.secret.hex // empty' 2>/dev/null)
    if [ -n "$secret_hex" ]; then
        echo -e "  ${BOLD}Секрет (hex):${NC} ${DIM}${secret_hex}${NC}"
    fi

    return 0
}

# ── Функция установки MTG ────────────────────────────────────
install_mtg() {
    echo ""
    echo -e "  ${BLUE}[i]${NC} Установка MTG"

    # Проверяем, установлен ли уже
    if is_mtg_installed; then
        echo -e "  ${YELLOW}[!] MTG уже установлен. Версия: $(get_mtg_version)${NC}"
        echo -en "  ${BOLD}Переустановить? [y/N]:${NC} "
        local reinstall
        read -r reinstall
        if [[ ! "$reinstall" =~ ^[yY]$ ]]; then
            echo -e "  ${GRAY}Установка отменена${NC}"
            echo ""
            echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
            read -rsn1
            return 0
        fi
    fi

    # Запрос порта
    local default_port="443"
    echo ""
    echo -en "  ${BOLD}Введите порт для MTG [${default_port}]:${NC} "
    read -r port_input
    if [ -z "$port_input" ]; then
        port_input="$default_port"
    fi
    if ! [[ "$port_input" =~ ^[0-9]+$ ]] || [ "$port_input" -lt 1 ] || [ "$port_input" -gt 65535 ]; then
        echo -e "  ${RED}[✗] Некорректный порт. Использую 443.${NC}"
        port_input="443"
    fi
    local port="$port_input"

    # Запрос домена для TLS (используется в секрете)
    echo ""
    echo -e "  ${DIM}Домен будет использован для Fake TLS (маскировка).${NC}"
    echo -en "  ${BOLD}Введите домен [rutube.ru]:${NC} "
    read -r domain_input
    if [ -z "$domain_input" ]; then
        domain_input="rutube.ru"
    fi
    local domain="$domain_input"

    # Генерация секрета
    echo ""
    echo -e "  ${BLUE}[i]${NC} Генерация секрета для домена ${domain}..."
    local secret
    secret=$(mtg generate-secret --hex "$domain" 2>/dev/null)
    if [ -z "$secret" ]; then
        echo -e "  ${RED}[✗] Не удалось сгенерировать секрет. Убедитесь, что mtg установлен.${NC}"
        echo ""
        echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
        read -rsn1
        return 1
    fi
    echo -e "  ${GREEN}✓${NC} Секрет: ${DIM}${secret}${NC}"

    # Создание конфига
    echo ""
    echo -e "  ${BLUE}[i]${NC} Создание конфига /etc/mtg.toml..."
    cat > /etc/mtg.toml << EOF
secret = "${secret}"
bind-to = "0.0.0.0:${port}"
EOF

    # Добавление опций keep-alive (по желанию)
    echo ""
    echo -e "  ${BOLD}Добавить настройки TCP keep-alive для мобильных клиентов?${NC}"
    echo -e "  ${DIM}Это улучшает стабильность на iOS/Android.${NC}"
    echo -en "  ${BOLD}Добавить? [Y/n]:${NC} "
    read -r add_keepalive
    if [[ ! "$add_keepalive" =~ ^[nN]$ ]]; then
        cat >> /etc/mtg.toml << 'EOF'

[network.keep-alive]
disabled = false
idle = "15s"
interval = "15s"
count = 9
EOF
        echo -e "  ${GREEN}✓${NC} Настройки keep-alive добавлены."
    fi

    # Сохраняем путь к конфигу
    mkdir -p /opt/mtpr-simple
    echo "/etc/mtg.toml" > "$CONFIG_PATH_FILE"

    # Запуск через systemd (если доступен)
    echo ""
    echo -e "  ${BOLD}Установить автозапуск через systemd?${NC}"
    echo -en "  ${BOLD}Установить? [Y/n]:${NC} "
    read -r add_systemd
    if [[ ! "$add_systemd" =~ ^[nN]$ ]]; then
        cat > /etc/systemd/system/mtg.service << 'EOF'
[Unit]
Description=MTG - MTProto proxy
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/mtg run /etc/mtg.toml
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable mtg.service
        systemctl start mtg.service
        echo -e "  ${GREEN}✓${NC} Служба mtg.service установлена и запущена."
    else
        echo -e "  ${YELLOW}[!] systemd не установлен. Для запуска используйте: mtg run /etc/mtg.toml${NC}"
    fi

    echo ""
    echo -e "  ${GREEN}✓${NC} Установка MTG завершена!"
    echo ""
    echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
    read -rsn1
}

# ── Функция открытия конфига ─────────────────────────────────
edit_config() {
    config_path=$(get_config_path)
    if [ ! -f "$config_path" ]; then
        echo ""
        echo -e "  ${YELLOW}[!] Файл конфига не найден по пути: $config_path"
        echo -e "  ${GRAY}Используйте пункт 4 для обновления пути к конфигу${NC}"
        echo ""
        echo -e "  ${GRAY}Нажмите любую клавишу для возврата...${NC}"
        read -rsn1
        return 1
    fi
    echo ""
    echo -e "  ${BLUE}[i]${NC} Открытие конфига: $config_path"
    if command -v nano >/dev/null 2>&1; then
        echo -e "  ${GRAY}После редактирования сохраните файл (Ctrl+O) и закройте (Ctrl+X)${NC}"
        echo ""
        echo -e "  ${GRAY}Нажмите любую клавишу для продолжения...${NC}"
        read -rsn1
        nano "$config_path"
    elif command -v vim >/dev/null 2>&1; then
        echo -e "  ${YELLOW}[!] nano не установлен. Использую vim.${NC}"
        echo -e "  ${GRAY}Для сохранения: ESC → :wq, для выхода без сохранения: ESC → :q!${NC}"
        echo ""
        echo -e "  ${GRAY}Нажмите любую клавишу для продолжения...${NC}"
        read -rsn1
        vim "$config_path"
    elif command -v vi >/dev/null 2>&1; then
        echo -e "  ${YELLOW}[!] Использую vi.${NC}"
        echo -e "  ${GRAY}Для сохранения: ESC → :wq, для выхода без сохранения: ESC → :q!${NC}"
        echo ""
        echo -e "  ${GRAY}Нажмите любую клавишу для продолжения...${NC}"
        read -rsn1
        vi "$config_path"
    else
        echo -e "  ${RED}[✗] Ни один редактор не найден (nano, vim, vi)${NC}"
        echo -e "  ${GRAY}Нажмите любую клавишу для возврата...${NC}"
        read -rsn1
        return 1
    fi
    echo ""
    echo -e "  ${GREEN}[✓] Редактирование завершено"
    echo -e "  ${GRAY}Нажмите любую клавишу для возврата...${NC}"
    read -rsn1
}

# ── Функция перезапуска MTG ──────────────────────────────────
restart_mtg() {
    echo ""
    echo -e "  ${BLUE}[i]${NC} Перезапуск MTG..."
    if systemctl restart mtg.service 2>/dev/null; then
        echo -e "  ${GREEN}[✓] MTG успешно перезапущен"
    else
        echo -e "  ${YELLOW}[!] Не удалось перезапустить через systemd. Попробуйте вручную:${NC}"
        echo -e "  ${CYAN}mtg run /etc/mtg.toml${NC}"
    fi
    echo ""
    echo -e "  ${GRAY}Нажмите любую клавишу для возврата...${NC}"
    read -rsn1
}

# ── Функция просмотра логов ──────────────────────────────────
view_logs() {
    echo ""
    echo -e "  ${BLUE}[i]${NC} Просмотр логов MTG (Ctrl+C для выхода)..."
    echo ""
    echo -e "  ${GRAY}Нажмите любую клавишу для продолжения...${NC}"
    read -rsn1
    journalctl -u mtg.service -f
    echo ""
    echo -e "  ${GRAY}Нажмите любую клавишу для возврата...${NC}"
    read -rsn1
}

# ── Функция удаления MTG ─────────────────────────────────────
purge_mtg() {
    echo ""
    echo -e "  ${RED}${BOLD}ВНИМАНИЕ:${NC} Будет выполнено полное удаление MTG!"
    echo ""
    echo -e "  ${BOLD}Будут удалены:${NC}"
    echo -e "  • Бинарник /usr/local/bin/mtg"
    echo -e "  • Конфигурационный файл /etc/mtg.toml"
    echo -e "  • Systemd служба (если есть)"
    echo ""
    echo -e "  ${YELLOW}[!] Это действие нельзя отменить!"
    echo -en "  ${BOLD}Продолжить удаление? [y/N]:${NC} "
    local confirm
    read -r confirm
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        echo -e "  ${GRAY}Удаление отменено${NC}"
        echo ""
        echo -e "  ${GRAY}Нажмите любую клавишу для возврата...${NC}"
        read -rsn1
        return 1
    fi

    echo ""
    echo -e "  ${BLUE}[i]${NC} Удаление MTG..."
    systemctl stop mtg.service 2>/dev/null || true
    systemctl disable mtg.service 2>/dev/null || true
    rm -f /etc/systemd/system/mtg.service
    rm -f /usr/local/bin/mtg
    rm -f /etc/mtg.toml
    rm -f "$CONFIG_PATH_FILE"
    systemctl daemon-reload 2>/dev/null || true

    echo -e "  ${GREEN}[✓] MTG успешно удалён"
    echo ""
    echo -e "  ${GRAY}Нажмите любую клавишу для возврата...${NC}"
    read -rsn1
}

# ── Функция обновления пути к конфигу ──────────────────────
update_config_path() {
    echo ""
    default_path="/etc/mtg.toml"
    echo -en "Укажите путь к конфигу MTG (Enter для ${default_path}, N/n для отмены): "
    read -r input
    if [[ "$input" =~ ^[Nn]$ ]]; then
        echo -e "  ${GRAY}Возврат...${NC}"
        sleep 0.5
        return 0
    fi
    if [ -z "$input" ]; then
        input="$default_path"
    fi
    if [ ! -f "$input" ]; then
        echo -e "  ${YELLOW}[!] Файл $input не найден. Сохранить путь всё равно? [y/N]${NC}"
        read -r confirm
        if [[ ! "$confirm" =~ ^[yY]$ ]]; then
            echo -e "  ${GRAY}Отменено${NC}"
            return 1
        fi
    fi
    mkdir -p /opt/mtpr-simple
    echo "$input" > "$CONFIG_PATH_FILE"
    echo -e "  ${GREEN}[✓] Путь сохранён: $input"
    echo ""
    echo -e "  ${GRAY}Нажмите любую клавишу для возврата...${NC}"
    read -rsn1
}

# ── Главное меню ─────────────────────────────────────────────
while true; do
    clear
    echo ""
    echo -e "  ${BOLD}MTG меню v0.1${NC}"
    echo -e "  ${DIM}===========================${NC}"
    echo ""

    if is_mtg_installed; then
        echo -e "  ${NC}${BOLD}MTG:${NC}${GREEN} установлен${NC}"
        version=$(get_mtg_version)
        if [ -n "$version" ]; then
            echo -e "  ${NC}${BOLD}Версия:${NC} ${GREEN}${version}${NC}"
        fi
        config_path=$(get_config_path)
        if [ -f "$config_path" ]; then
            port=$(get_mtg_port "$config_path")
            if [ -n "$port" ]; then
                echo -e "  ${BOLD}Порт:${NC} ${CYAN}${port}${NC}"
            fi
        fi
        echo ""
    else
        echo -e "  ${YELLOW}MTG не установлен${NC}"
        echo ""
    fi

    echo -e "  ${CYAN}[1]${NC}  ${BOLD}Установить/переустановить MTG${NC}"
    echo -e "  ${CYAN}[2]${NC}  ${BOLD}Открыть конфиг MTG${NC}"
    echo -e "  ${CYAN}[3]${NC}  ${BOLD}Перезапустить MTG${NC}"
    echo -e "  ${CYAN}[4]${NC}  ${BOLD}Обновить путь к конфигу MTG${NC}"
    echo -e "  ${CYAN}[5]${NC}  ${BOLD}Посмотреть логи MTG${NC}"
    echo -e "  ${CYAN}[6]${NC}  ${BOLD}Показать ссылку для подключения${NC}"
    echo -e "  ${RED}[7]${NC}  ${BOLD}Удалить MTG${NC}"
    echo -e "  ${CYAN}[0]${NC}  ${BOLD}Назад в прокси меню${NC}"
    echo ""

    if is_mtg_installed; then
        current_path=$(get_config_path)
        echo -e "  ${DIM}Текущий путь к конфигу: ${current_path}${NC}"
        echo ""
    fi

    echo -en "  ${BOLD}Выбор:${NC} "
    read -r choice

    case "$choice" in
        1)
            install_mtg
            ;;
        2)
            edit_config
            ;;
        3)
            restart_mtg
            ;;
        4)
            update_config_path
            ;;
        5)
            view_logs
            ;;
        6)
            echo ""
            generate_proxy_links
            echo ""
            echo -e "  ${GRAY}Нажмите любую клавишу для возврата...${NC}"
            read -rsn1
            ;;
        7)
            purge_mtg
            ;;
        0)
            exec /opt/mtpr-simple/proxys/proxymenu.sh
            ;;
        *)
            echo "  Неверный выбор"
            sleep 0.1
            ;;
    esac
done
