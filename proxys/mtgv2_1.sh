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

# ── Функция установки MTG ────────────────────────────────────
install_mtg() {
    echo ""
    echo -e "  ${BLUE}[i]${NC} Установка MTG"

    # Проверяем, установлен ли уже (просто показываем, что установка начата)
    local already_installed=false
    if is_mtg_installed; then
        already_installed=true
        local current_version=$(get_mtg_version)
        echo -e "  ${YELLOW}[!] Обнаружена старая версия MTG: ${current_version}${NC}"
        echo -e "  ${YELLOW}[!] Будет выполнена переустановка (старая версия будет удалена)${NC}"
        echo ""
        # Удаляем старую версию без подтверждения
        purge_mtg_silent
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

    # Генерация секрета с циклом (как в telemt_in_docker1.sh)
    echo ""
    echo -e "  ${BOLD}Секрет для доступа к прокси${NC}"

    SECRET=""
    while true; do
        # Генерируем секрет при первом проходе или при gen
        if [ -z "$SECRET" ]; then
            SECRET=$(mtg generate-secret --hex "$domain" 2>/dev/null)
            if [ -z "$SECRET" ]; then
                echo -e "  ${RED}[✗] Не удалось сгенерировать секрет. Убедитесь, что mtg установлен.${NC}"
                echo ""
                echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
                read -rsn1
                return 1
            fi
        fi
        
        echo -e "  ${DIM}Сгенерирован секрет: ${CYAN}${SECRET}${NC}"
        echo ""
        echo -e "  ${BOLD}Варианты:${NC}"
        echo -e "  ${GREEN}Enter/Y${NC} — использовать сгенерированный секрет"
        echo -e "  ${CYAN}Ввести вручную${NC} — указать свой секрет (в hex формате)"
        echo -e "  ${RED}gen${NC} — перегенерировать новый секрет"
        echo ""
        echo -en "  ${BOLD}Ваш выбор:${NC} "
        read -r secret_input
        
        if [[ "$secret_input" =~ ^[Gg][Ee][Nn]$ ]]; then
            SECRET=$(mtg generate-secret --hex "$domain" 2>/dev/null)
            if [ -z "$SECRET" ]; then
                echo -e "  ${RED}[✗] Не удалось сгенерировать секрет.${NC}"
                sleep 1
                continue
            fi
            echo ""
            echo -e "  ${GREEN}✓${NC} Новый секрет: ${CYAN}${SECRET}${NC}"
            echo ""
            # Показываем меню снова с новым секретом
            continue
        elif [[ -n "$secret_input" ]] && [[ ! "$secret_input" =~ ^[yY]$ ]]; then
            # Ввели что-то кроме gen, enter, y, Y — считаем это ручным вводом секрета
            SECRET="$secret_input"
            echo ""
            echo -e "  ${GREEN}✓${NC} Использован секрет: ${CYAN}${SECRET}${NC}"
            echo ""
            break
        else
            # Enter или y/Y
            echo ""
            echo -e "  ${GREEN}✓${NC} Использован сгенерированный секрет: ${CYAN}${SECRET}${NC}"
            echo ""
            break
        fi
    done

    # Создание конфига
    echo ""
    echo -e "  ${BLUE}[i]${NC} Создание конфига /etc/mtg.toml..."
    cat > /etc/mtg.toml << EOF
secret = "${SECRET}"
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

# ── Функция тихого удаления MTG (без подтверждения) ─────────
purge_mtg_silent() {
    systemctl stop mtg.service 2>/dev/null || true
    systemctl disable mtg.service 2>/dev/null || true
    rm -f /etc/systemd/system/mtg.service
    systemctl daemon-reload 2>/dev/null || true
    rm -f /usr/local/bin/mtg
    rm -f /etc/mtg.toml
    rm -f "$CONFIG_PATH_FILE"
    rm -f mtg-latest.tar.gz 2>/dev/null || true
    rm -f mtg-*.tar.gz 2>/dev/null || true
    rm -rf mtg-*/ 2>/dev/null || true
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
    echo -e "  • Все скачанные архивы MTG"
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
    purge_mtg_silent

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

# ── Функция показа ссылки ────────────────────────────────────
show_link() {
    echo ""
    echo -e "  ${BLUE}[i]${NC} Генерация ссылки для подключения..."
    
    local secret
    secret=$(sudo cat /etc/mtg.toml 2>/dev/null | grep '^secret' | awk -F'"' '{print $2}' | tr -d '\n')
    
    if [ -z "$secret" ]; then
        echo -e "  ${RED}[✗] Не удалось получить секрет из конфига.${NC}"
        echo -e "  ${GRAY}Нажмите любую клавишу для возврата...${NC}"
        read -rsn1
        return 1
    fi
    
    local ip
    ip=$(curl -4 -fsS --max-time 3 ifconfig.me 2>/dev/null || curl -4 -fsS --max-time 3 icanhazip.com 2>/dev/null || echo "SERVER_IP")
    
    local port
    port=$(get_mtg_port "/etc/mtg.toml")
    if [ -z "$port" ]; then
        port="443"
    fi
    
    echo ""
    echo -e "  ${BOLD}Ссылка для подключения:${NC}"
    echo -e "  ${CYAN}https://t.me/proxy?server=${ip}&port=${port}&secret=${secret}${NC}"
    echo ""
    echo -e "  ${BOLD}Данные для подключения:${NC}"
    echo -e "  ${BOLD}Сервер:${NC} ${ip}"
    echo -e "  ${BOLD}Порт:${NC} ${port}"
    echo -e "  ${BOLD}Секрет:${NC} ${secret}"
    echo ""
    echo -e "  ${GRAY}Нажмите любую клавишу для возврата...${NC}"
    read -rsn1
}

# ── Главное меню ─────────────────────────────────────────────
while true; do
    clear
    echo ""
    echo -e "  ${BOLD}MTG меню v0.12${NC}"
    echo -e "  ${DIM}===========================${NC}"
    echo ""

    if is_mtg_installed; then
        echo -e "  ${NC}${BOLD}MTG:${NC}${GREEN} установлен${NC}"
        version=$(get_mtg_version)
        if [ -n "$version" ] && [ "$version" != "go1.26.1:" ]; then
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

    echo -e "  ${CYAN}[1]${NC}  ${BOLD}Установить MTG${NC}"
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
            show_link
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
