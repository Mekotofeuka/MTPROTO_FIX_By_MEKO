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
        # Берём первую часть до пробела — это версия
        mtg --version 2>/dev/null | head -1 | awk '{print $1}'
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

# ── Функция скачивания и установки бинарника MTG ────────────
install_mtg_binary() {
    echo -e "  ${BLUE}[i]${NC} Скачивание и установка MTG..."

    # Определяем архитектуру
    local arch
    arch=$(uname -m)
    local mtg_arch=""
    case "$arch" in
        x86_64)  mtg_arch="amd64" ;;
        aarch64) mtg_arch="arm64" ;;
        armv7l)  mtg_arch="armv7" ;;
        armv6l)  mtg_arch="armv6" ;;
        *)
            echo -e "  ${RED}[✗] Неподдерживаемая архитектура: $arch${NC}"
            return 1
            ;;
    esac

    # Скачиваем последнюю версию
    local tmp_dir=$(mktemp -d)
    cd "$tmp_dir"

    echo -e "  ${BLUE}[i]${NC} Загрузка MTG для архитектуры ${mtg_arch}..."
    
    # Получаем URL последней версии
    local download_url
    download_url=$(curl -s https://api.github.com/repos/9seconds/mtg/releases/latest | grep -o "https://.*mtg-.*-linux-${mtg_arch}.*\.tar\.gz" | head -1)
    
    if [ -z "$download_url" ]; then
        echo -e "  ${RED}[✗] Не удалось найти последнюю версию MTG${NC}"
        cd / && rm -rf "$tmp_dir"
        return 1
    fi

    echo -e "  ${BLUE}[i]${NC} Скачивание: ${download_url##*/}"
    
    if ! curl -fsSL --max-time 60 "$download_url" -o mtg.tar.gz; then
        echo -e "  ${RED}[✗] Ошибка скачивания MTG${NC}"
        cd / && rm -rf "$tmp_dir"
        return 1
    fi

    # Распаковываем
    tar -xzf mtg.tar.gz
    local mtg_bin
    mtg_bin=$(find . -type f -name "mtg" ! -path "*/.*" 2>/dev/null | head -1)
    
    if [ -z "$mtg_bin" ]; then
        echo -e "  ${RED}[✗] Бинарник mtg не найден в архиве${NC}"
        cd / && rm -rf "$tmp_dir"
        return 1
    fi

    # Устанавливаем
    mv "$mtg_bin" /usr/local/bin/mtg
    chmod +x /usr/local/bin/mtg

    cd / && rm -rf "$tmp_dir"

    # Проверяем установку
    if command -v mtg >/dev/null 2>&1; then
        local version=$(get_mtg_version)
        echo -e "  ${GREEN}✓${NC} MTG успешно установлен (версия: ${version})"
        return 0
    else
        echo -e "  ${RED}[✗] Ошибка установки MTG${NC}"
        return 1
    fi
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

# ── Функция проверки MTG (doctor) ────────────────────────────
mtg_doctor() {
    local config_path="/etc/mtg.toml"
    
    echo ""
    echo -e "  ${BOLD}${CYAN}Проверка MTG прокси${NC}"
    echo -e "  ${DIM}─────────────────────────────────────────${NC}"
    
    if [ ! -f "$config_path" ]; then
        echo -e "  ${RED}[✗] Конфиг не найден: $config_path${NC}"
        echo ""
        echo -e "  ${GRAY}Нажмите любую клавишу для возврата...${NC}"
        read -rsn1
        return 1
    fi
    
    # Запускаем doctor и сохраняем вывод, игнорируя exit code
    local output
    output=$(mtg doctor "$config_path" 2>&1)
    
    # Если вывод пустой - ошибка
    if [ -z "$output" ]; then
        echo -e "  ${RED}[✗] Не удалось выполнить проверку. Убедитесь, что MTG запущен.${NC}"
        echo ""
        echo -e "  ${GRAY}Нажмите любую клавишу для возврата...${NC}"
        read -rsn1
        return 1
    fi
    
    # ── Извлечение домена из секрета через bash ──────────────
    local domain=""
    local secret_line
    secret_line=$(grep -E '^secret' "$config_path" 2>/dev/null | head -1)
    if [ -n "$secret_line" ]; then
        local secret_hex
        secret_hex=$(echo "$secret_line" | sed -E 's/^secret[[:space:]]*=[[:space:]]*"//; s/".*$//')
        # Удаляем префикс ee (2 символа) и 32 символа секрета
        local domain_hex
        domain_hex=$(echo "$secret_hex" | sed -E 's/^ee[0-9a-f]{32}//')
        if [ -n "$domain_hex" ]; then
            # Конвертируем hex в текст через printf (без od)
            domain=$(printf '%b' "$(echo "$domain_hex" | sed 's/../\\x&/g')" 2>/dev/null)
            if [ -z "$domain" ]; then
                domain="$domain_hex (hex)"
            fi
        fi
    fi
    if [ -z "$domain" ]; then
        domain="не определён"
    fi
    
    # Парсим вывод
    echo ""
    
    # 1. Time skewness
    local time_skew
    time_skew=$(echo "$output" | grep -A 2 "Time skewness" | grep -o "Time drift is [0-9.-]*[ms]*" | head -1)
    if [ -n "$time_skew" ]; then
        echo -e "  ${GREEN}✓${NC} Расхождение времени: ${time_skew} (допуск 3с)"
    else
        echo -e "  ${YELLOW}⚠${NC} Расхождение времени: не удалось определить"
    fi
    
    # 2. Validate native network connectivity (DC)
    echo -e "  ${BOLD}Подключение к дата-центрам Telegram:${NC}"
    local dc_count=0
    local dc_ok=0
    while IFS= read -r line; do
        if echo "$line" | grep -q "DC [0-9]"; then
            dc_count=$((dc_count + 1))
            if echo "$line" | grep -q "✅"; then
                dc_ok=$((dc_ok + 1))
                echo -e "    ${GREEN}✓${NC} $(echo "$line" | sed 's/^[[:space:]]*//')"
            else
                echo -e "    ${RED}✗${NC} $(echo "$line" | sed 's/^[[:space:]]*//')"
            fi
        fi
    done <<< "$output"
    if [ $dc_count -gt 0 ] && [ $dc_count -eq $dc_ok ]; then
        echo -e "    ${GREEN}Все DC доступны${NC}"
    elif [ $dc_count -gt 0 ]; then
        echo -e "    ${YELLOW}Некоторые DC недоступны${NC}"
    else
        echo -e "    ${YELLOW}⚠ Не удалось проверить DC${NC}"
    fi
    
    # 3. Validate fronting domain connectivity
    local domain_line
    domain_line=$(echo "$output" | grep -A 1 "Validate fronting domain connectivity" | tail -1 | sed 's/^[[:space:]]*//')
    if echo "$domain_line" | grep -q "reachable"; then
        echo -e "  ${GREEN}✓${NC} Домен маскировки: ${domain} — ${GREEN}доступен${NC}"
    else
        echo -e "  ${RED}✗${NC} Домен маскировки: ${domain} — ${RED}недоступен${NC}"
    fi
    
    # 4. Validate SNI-DNS match (перевод на русский с предупреждением)
    local sni_line
    sni_line=$(echo "$output" | grep -A 1 "Validate SNI-DNS match" | tail -1 | sed 's/^[[:space:]]*//')
    
    # Получаем IP сервера
    local server_ip
    server_ip=$(get_public_ip)
    
    if echo "$sni_line" | grep -q "Hostname"; then
        # Парсим строку
        local domain_name=$(echo "$sni_line" | sed -E 's/.*Hostname ([^ ]*) .*/\1/')
        local resolved_ips=$(echo "$sni_line" | grep -o '"\([0-9]\{1,3\}\.\)\{3\}[0-9]\{1,3\}"' | tr -d '"' | tr '\n' ' ' | sed 's/ $//')
        
        echo -e "  ${CYAN}ℹ${NC} SNI-информация:"
        echo -e "     ${CYAN}Домен:${NC} ${domain_name}"
        echo -e "     ${CYAN}IP-адреса домена:${NC} ${resolved_ips}"
        if [ -n "$server_ip" ]; then
            echo -e "     ${CYAN}IP текущего сервера:${NC} ${server_ip}"
        fi
        
        # Проверяем, есть ли IP сервера в списке IP домена
        if [ -n "$server_ip" ] && ! echo "$resolved_ips" | grep -q "$server_ip"; then
            echo -e "     ${YELLOW}⚠ ВНИМАНИЕ: IP сервера (${server_ip}) НЕ СОВПАДАЕТ с IP домена (${resolved_ips})${NC}"
            echo -e "     ${YELLOW}⚠ Если вы используете SelfSteal, проверьте DNS-запись A для домена!${NC}"
            echo -e "     ${YELLOW}⚠ Домен должен резолвиться в IP вашего сервера, иначе iOS-клиенты могут не работать.${NC}"
        fi
    else
        echo -e "  ${CYAN}ℹ${NC} SNI-информация: не получена"
        if [ -n "$server_ip" ]; then
            echo -e "     ${CYAN}IP текущего сервера:${NC} ${server_ip}"
        fi
    fi

# ── Функция установки MTG ────────────────────────────────────
install_mtg() {
    echo ""
    echo -e "  ${BLUE}[i]${NC} Установка MTG"

    # Проверяем, установлен ли уже бинарник
    if is_mtg_installed; then
        local current_version=$(get_mtg_version)
        echo -e "  ${YELLOW}[!] Обнаружена старая версия MTG: ${current_version}${NC}"
        echo -e "  ${YELLOW}[!] Будет выполнена переустановка${NC}"
        echo ""
        # Удаляем старую версию без подтверждения
        purge_mtg_silent
    fi

    # 1. Сначала устанавливаем бинарник mtg
    if ! install_mtg_binary; then
        echo ""
        echo -e "  ${RED}[✗] Не удалось установить MTG${NC}"
        echo ""
        echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
        read -rsn1
        return 1
    fi

    # Теперь mtg установлен, можно генерировать секрет

    # Запрос порта с циклом
    local default_port="443"
    local port=""
    while true; do
        echo ""
        echo -en "  ${BOLD}Введите порт для MTG [${default_port}]:${NC} "
        read -r port_input
        if [ -z "$port_input" ]; then
            port="$default_port"
            break
        fi
        if [[ "$port_input" =~ ^[0-9]+$ ]] && [ "$port_input" -ge 1 ] && [ "$port_input" -le 65535 ]; then
            port="$port_input"
            break
        else
            echo -e "  ${RED}[✗] Некорректный порт. Введите число от 1 до 65535 или нажмите Enter для порта по умолчанию.${NC}"
        fi
    done

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
                echo -e "  ${RED}[✗] Не удалось сгенерировать секрет. Попробуйте ввести вручную.${NC}"
                SECRET=""
            fi
        fi
        
        if [ -n "$SECRET" ]; then
            echo -e "  ${DIM}Сгенерирован секрет: ${CYAN}${SECRET}${NC}"
        fi
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
            continue
        elif [[ -n "$secret_input" ]] && [[ ! "$secret_input" =~ ^[yY]$ ]]; then
            SECRET="$secret_input"
            echo ""
            echo -e "  ${GREEN}✓${NC} Использован секрет: ${CYAN}${SECRET}${NC}"
            echo ""
            break
        elif [ -z "$SECRET" ]; then
            # Секрета нет, а пользователь нажал Enter без секрета
            echo -e "  ${YELLOW}[!] Секрет не сгенерирован. Попробуйте ввести 'gen' или введите вручную.${NC}"
            continue
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

    # Добавление опций keep-alive (по желанию) с новыми значениями
    echo ""
    echo -e "  ${BOLD}Добавить настройки TCP keep-alive для мобильных клиентов?${NC}"
    echo -e "  ${DIM}Это улучшает стабильность на iOS/Android.${NC}"
    echo -en "  ${BOLD}Добавить? [Y/n]:${NC} "
    read -r add_keepalive
    if [[ ! "$add_keepalive" =~ ^[nN]$ ]]; then
        cat >> /etc/mtg.toml << 'EOF'

[network.keep-alive]
disabled = false
idle = "10s"
interval = "10s"
count = 3
EOF
        echo -e "  ${GREEN}✓${NC} Настройки keep-alive добавлены (idle=10s, interval=10s, count=3)."
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
        echo -e "  ${YELLOW}[!] Для запуска используйте: mtg run /etc/mtg.toml${NC}"
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
    echo -e  "  ${BLUE}[i]${NC} Генерация ссылки для подключения..."
    
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
    echo -e "  ${BOLD}MTG меню v0.2${NC}"
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

    echo -e "  ${CYAN}[1]${NC}  ${BOLD}Установить MTG${NC}"
    echo -e "  ${CYAN}[2]${NC}  ${BOLD}Открыть конфиг MTG${NC}"
    echo -e "  ${CYAN}[3]${NC}  ${BOLD}Перезапустить MTG${NC}"
    echo -e "  ${CYAN}[4]${NC}  ${BOLD}Обновить путь к конфигу MTG${NC}"
    echo -e "  ${CYAN}[5]${NC}  ${BOLD}Посмотреть логи MTG${NC}"
    echo -e "  ${CYAN}[6]${NC}  ${BOLD}Показать ссылку для подключения${NC}"
    echo -e "  ${CYAN}[7]${NC}  ${BOLD}Проверить MTG (doctor)${NC}"
    echo -e "  ${RED}[8]${NC}  ${BOLD}Удалить MTG${NC}"
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
            mtg_doctor
            ;;
        8)
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
