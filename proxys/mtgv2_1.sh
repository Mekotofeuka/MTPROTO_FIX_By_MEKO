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

pause_key() {
    { : </dev/tty; } 2>/dev/null || return 0
    echo -e "  ${GRAY}${1:-Нажмите любую клавишу}${NC}"
    read -rsn1 </dev/tty || true
    IFS= read -r -t 0.05 _ </dev/tty 2>/dev/null || true
}

# ── Файл для сохранения пути к конфигу (как в telemt1.sh) ──
CONFIG_PATH_FILE="/opt/mtpr-simple/mtg_config_path"

# 2.x живёт с конфигом /etc/mtg.toml, 1.0.x — только флагами запуска,
# поэтому выбранное поколение храним отдельно и читаем в каждой операции.
MTG_GEN_FILE="/opt/mtpr-simple/mtg_gen"
MTG_V1_CONF="/opt/mtpr-simple/mtg_v1.conf"
MTG_V1_TAG="v1.0.12"

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
        local path; path=$(cat "$CONFIG_PATH_FILE")
        if [ "$path" != "skip" ]; then
            echo "$path"
            return 0
        fi
    fi
    echo "/etc/mtg.toml"
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
        # 1.0.x печатает версию в stderr, 2.x — в stdout
        mtg --version 2>&1 | head -1 | awk '{print $1}'
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

# ── Поколение MTG: v2 (конфиг) или v1 (только флаги) ─────────
get_mtg_gen() {
    if [ -f "$MTG_GEN_FILE" ]; then
        local saved; saved=$(trim "$(cat "$MTG_GEN_FILE" 2>/dev/null)")
        case "$saved" in v1|v2) echo "$saved"; return 0 ;; esac
    fi
    # Фолбэк по версии: у 1.0.x она начинается с "1."
    case "$(get_mtg_version)" in
        1.*) echo "v1" ;;
        *)   echo "v2" ;;
    esac
}

_mtg_v1_get() {
    [ -f "$MTG_V1_CONF" ] || return 0
    grep -E "^$1=" "$MTG_V1_CONF" 2>/dev/null | head -1 | cut -d= -f2-
}

mtg_current_port() {
    if [ "$(get_mtg_gen)" = "v1" ]; then
        _mtg_v1_get port
    else
        get_mtg_port "$(get_config_path)"
    fi
}

# У 2.x секрет печатается через --hex, у 1.0.x — только -c <домен> tls
_gen_mtg_secret() {
    local _domain="$1" _gen="$2"
    if [ "$_gen" = "v1" ]; then
        mtg generate-secret -c "$_domain" tls 2>/dev/null
    else
        mtg generate-secret --hex "$_domain" 2>/dev/null
    fi
}

# ── Получение публичного IP ──────────────────────────────────
get_public_ip() {
    local _ip="" _u=""
    # Перебираем сервисы и требуем НЕПУСТОЙ ответ: curl с rc=0 и пустым
    # телом иначе «защёлкнул» бы пустой IP вместо фолбэка.
    for _u in https://api.ipify.org https://ifconfig.me https://icanhazip.com; do
        _ip=$(curl -4 -fsS --max-time 5 "$_u" 2>/dev/null | tr -d '[:space:]')
        [ -n "$_ip" ] && break
    done
    echo "$_ip"
}

# ── Функция скачивания и установки бинарника MTG ────────────
install_mtg_binary() {
    local gen="${1:-v2}"
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
    local tmp_dir
    tmp_dir=$(mktemp -d) || { echo -e "  ${RED}[✗] Не удалось создать временный каталог${NC}"; return 1; }
    cd "$tmp_dir" || { echo -e "  ${RED}[✗] Не удалось перейти в $tmp_dir${NC}"; rm -rf "$tmp_dir"; return 1; }

    echo -e "  ${BLUE}[i]${NC} Загрузка MTG для архитектуры ${mtg_arch}..."
    
    # Ветка 1.0.x закрыта — тег фиксирован, у 2.x берём последний релиз
    local download_url=""
    if [ "$gen" = "v1" ]; then
        download_url="https://github.com/9seconds/mtg/releases/download/${MTG_V1_TAG}/mtg-${MTG_V1_TAG#v}-linux-${mtg_arch}.tar.gz"
    else
        # К сборкам с суффиксом -v3 добавлены инструкции AVX2: на старых CPU
        # они падают с SIGILL, поэтому берём обычную сборку, а -v3 только фолбэком
        local _assets
        _assets=$(curl -fsSL --max-time 20 https://api.github.com/repos/9seconds/mtg/releases/latest | grep -o "https://.*mtg-.*-linux-${mtg_arch}.*\.tar\.gz")
        download_url=$(printf '%s\n' "$_assets" | grep -v -- '-v3\.tar\.gz$' | head -1)
        [ -z "$download_url" ] && download_url=$(printf '%s\n' "$_assets" | head -1)
    fi
    
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
    if ! tar -xzf mtg.tar.gz; then
        echo -e "  ${RED}[✗] Ошибка распаковки архива MTG${NC}"
        cd / && rm -rf "$tmp_dir"
        return 1
    fi
    local mtg_bin
    mtg_bin=$(find . -type f -name "mtg" ! -path "*/.*" 2>/dev/null | head -1)
    
    if [ -z "$mtg_bin" ]; then
        echo -e "  ${RED}[✗] Бинарник mtg не найден в архиве${NC}"
        cd / && rm -rf "$tmp_dir"
        return 1
    fi

    # Устанавливаем
    if ! mv "$mtg_bin" /usr/local/bin/mtg || ! chmod +x /usr/local/bin/mtg; then
        echo -e "  ${RED}[✗] Не удалось установить бинарник MTG в /usr/local/bin${NC}"
        cd / && rm -rf "$tmp_dir"
        return 1
    fi

    cd / && rm -rf "$tmp_dir"

    # Проверяем установку
    if command -v mtg >/dev/null 2>&1; then
        local version; version=$(get_mtg_version)
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
    rm -f "$MTG_GEN_FILE" "$MTG_V1_CONF"
    # Чистим остатки прежних установок только в известном каталоге (не в cwd)
    rm -f /root/mtg-latest.tar.gz /root/mtg-*.tar.gz 2>/dev/null || true
    rm -rf /root/mtg-*/ 2>/dev/null || true
}

# ── Функция проверки MTG (doctor) ────────────────────────────
mtg_doctor() {
    if [ "$(get_mtg_gen)" = "v1" ]; then
        echo ""
        echo -e "  ${YELLOW}[!] doctor есть только в MTG 2.x, у 1.0.x проверка недоступна${NC}"
        echo ""
        pause_key "Нажмите любую клавишу для возврата..."
        return 0
    fi
    local config_path
    config_path=$(get_config_path)
    
    echo ""
    echo -e "  ${BOLD}${CYAN}Проверка MTG прокси${NC}"
    echo -e "  ${DIM}─────────────────────────────────────────${NC}"
    
    if [ ! -f "$config_path" ]; then
        echo -e "  ${RED}[✗] Конфиг не найден: $config_path${NC}"
        echo ""
        pause_key "Нажмите любую клавишу для возврата..."
        return 1
    fi
    
    # Запускаем doctor и сохраняем вывод, игнорируя exit code
    local output
    output=$(mtg doctor "$config_path" 2>&1)
    
    # Если вывод пустой - ошибка
    if [ -z "$output" ]; then
        echo -e "  ${RED}[✗] Не удалось выполнить проверку. Убедитесь, что MTG запущен.${NC}"
        echo ""
        pause_key "Нажмите любую клавишу для возврата..."
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
        domain_hex="${secret_hex:34}"
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
                echo -e "    ${GREEN}✓${NC} $(trim "$line")"
            else
                echo -e "    ${RED}✗${NC} $(trim "$line")"
            fi
        fi
    done <<< "$output"
    if [ "$dc_count" -gt 0 ] && [ "$dc_count" -eq "$dc_ok" ]; then
        echo -e "    ${GREEN}Все DC доступны${NC}"
    elif [ "$dc_count" -gt 0 ]; then
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
        local domain_name
        domain_name=$(echo "$sni_line" | sed -E 's/.*Hostname ([^ ]*) .*/\1/')
        local resolved_ips
        resolved_ips=$(echo "$sni_line" | grep -o '"\([0-9]\{1,3\}\.\)\{3\}[0-9]\{1,3\}"' | tr -d '"' | tr '\n' ' ' | sed 's/ $//')
        
        echo -e "  ${CYAN}ℹ${NC} SNI-информация:"
        echo -e "     ${CYAN}Домен:${NC} ${domain_name}"
        echo -e "     ${CYAN}IP-адреса домена:${NC} ${resolved_ips}"
        if [ -n "$server_ip" ]; then
            echo -e "     ${CYAN}IP текущего сервера:${NC} ${server_ip}"
        fi
        
        # Проверяем, есть ли IP сервера в списке IP домена
        if [ -n "$server_ip" ] && ! echo "$resolved_ips" | grep -q "$server_ip"; then
            echo -e "     ${YELLOW}${BOLD}⚠ ВНИМАНИЕ:${NC}${BOLD} IP текущего сервера ${CYAN}${BOLD}${server_ip} ${NC}${BOLD}НЕ СОВПАДАЕТ с IP домена ${CYAN}${BOLD}${resolved_ips}${NC}"
            echo -e "     ${NC}${BOLD}  Если вы используете SelfSteal, проверьте DNS-запись A для домена${NC}"
            echo -e "     ${NC}${BOLD}  Если же вы не используете SelfSteal - не обращайте внимания на этот текст${NC}"
        fi
    else
        echo -e "  ${CYAN}ℹ${NC} SNI-информация: не получена"
        if [ -n "$server_ip" ]; then
            echo -e "     ${CYAN}IP текущего сервера:${NC} ${server_ip}"
        fi
    fi
    
    echo ""
    pause_key "Нажмите любую клавишу для возврата в меню..."
}

# ── Функция установки MTG ────────────────────────────────────
install_mtg() {
    echo ""
    echo -e "  ${BLUE}[i]${NC} Установка MTG"

    # Проверяем, установлен ли уже бинарник
    if is_mtg_installed; then
        local current_version; current_version=$(get_mtg_version)
        echo -e "  ${YELLOW}[!] Обнаружена старая версия MTG: ${current_version}${NC}"
        echo -e "  ${YELLOW}[!] Будет выполнена переустановка${NC}"
        echo ""
        # Удаляем старую версию без подтверждения
        purge_mtg_silent
    fi

    # Поколение: у 1.0.x нет конфиг-файла, запуск собирается из флагов
    local gen
    echo -e "  ${BOLD}Какое поколение MTG ставить?${NC}"
    echo -e "  ${CYAN}[1]${NC} 2.x   — актуальная ветка, конфиг /etc/mtg.toml"
    echo -e "  ${CYAN}[2]${NC} 1.0.x — старая ветка, запуск только флагами"
    echo -en "  ${BOLD}Выбор [1]:${NC} "
    { read -r gen_input </dev/tty; } 2>/dev/null || true
    case "$gen_input" in
        2) gen="v1" ;;
        *) gen="v2" ;;
    esac
    echo ""

    # 1. Сначала устанавливаем бинарник mtg
    if ! install_mtg_binary "$gen"; then
        echo ""
        echo -e "  ${RED}[✗] Не удалось установить MTG${NC}"
        echo ""
        pause_key "Нажмите любую клавишу для возврата в меню..."
        return 1
    fi

    # Теперь mtg установлен, можно генерировать секрет

    # Запрос порта с циклом
    local default_port="443"
    local port=""
    while true; do
        echo ""
        echo -en "  ${BOLD}Введите порт для MTG [${default_port}]:${NC} "
        { read -r port_input </dev/tty; } 2>/dev/null || true
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
    { read -r domain_input </dev/tty; } 2>/dev/null || true
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
            SECRET=$(_gen_mtg_secret "$domain" "$gen")
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
        { read -r secret_input </dev/tty; } 2>/dev/null || true
        
        if [[ "$secret_input" =~ ^[Gg][Ee][Nn]$ ]]; then
            SECRET=$(_gen_mtg_secret "$domain" "$gen")
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
            # 2.x: 34 hex (ee + ключ), 1.0.x tls: 66 hex (ee + ключ + домен)
            if [[ ! "$secret_input" =~ ^[0-9a-fA-F]{32,66}$ ]] || (( ${#secret_input} % 2 )); then
                echo -e "  ${RED}[✗] Секрет должен быть hex-строкой чётной длины (обычно 32, 34 или 66 символов).${NC}"
                continue
            fi
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

    mkdir -p /opt/mtpr-simple
    if [ "$gen" = "v1" ]; then
        # У 1.0.x конфига нет: параметры запуска храним в своём файле
        printf 'gen=v1\nsecret=%s\nport=%s\ndomain=%s\n' "$SECRET" "$port" "$domain" > "$MTG_V1_CONF"
        rm -f "$CONFIG_PATH_FILE"
        echo ""
        echo -e "  ${BLUE}[i]${NC} Параметры запуска сохранены: ${MTG_V1_CONF}"
    else
        echo ""
        echo -e "  ${BLUE}[i]${NC} Создание конфига /etc/mtg.toml..."
        cat > /etc/mtg.toml << EOF
secret = "${SECRET}"
bind-to = "0.0.0.0:${port}"
EOF
    fi

    # keep-alive описывается в конфиге, у 1.0.x конфига нет
    if [ "$gen" = "v2" ]; then
    echo ""
    echo -e "  ${BOLD}Добавить настройки TCP keep-alive для мобильных клиентов?${NC}"
    echo -e "  ${DIM}Это улучшает стабильность на iOS/Android.${NC}"
    echo -en "  ${BOLD}Добавить? [Y/n]:${NC} "
    { read -r add_keepalive </dev/tty; } 2>/dev/null || true
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

    fi

    # Путь к конфигу нужен только 2.x
    if [ "$gen" = "v2" ]; then
        echo "/etc/mtg.toml" > "$CONFIG_PATH_FILE"
    fi
    echo "$gen" > "$MTG_GEN_FILE"

    # Запуск через systemd (если доступен)
    echo ""
    echo -e "  ${BOLD}Установить автозапуск через systemd?${NC}"
    echo -en "  ${BOLD}Установить? [Y/n]:${NC} "
    { read -r add_systemd </dev/tty; } 2>/dev/null || true
    if [[ ! "$add_systemd" =~ ^[nN]$ ]]; then
        if [ "$gen" = "v1" ]; then
            cat > /etc/systemd/system/mtg.service << EOF
[Unit]
Description=MTG - MTProto proxy (1.0.x)
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/mtg run -b 0.0.0.0:${port} ${SECRET}
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
        else
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
        fi
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable mtg.service 2>/dev/null || true
        if systemctl start mtg.service; then
            echo -e "  ${GREEN}✓${NC} Служба mtg.service установлена и запущена."
        else
            echo -e "  ${YELLOW}[!]${NC} Служба mtg.service установлена, но не запустилась. Проверьте: systemctl status mtg.service"
        fi
    else
        if [ "$gen" = "v1" ]; then
            echo -e "  ${YELLOW}[!] Для запуска используйте: mtg run -b 0.0.0.0:${port} ${SECRET}${NC}"
        else
            echo -e "  ${YELLOW}[!] Для запуска используйте: mtg run /etc/mtg.toml${NC}"
        fi
    fi

    echo ""
    echo -e "  ${GREEN}✓${NC} Установка MTG завершена!"
    echo ""
    pause_key "Нажмите любую клавишу для возврата в меню..."
}

# ── Функция открытия конфига ─────────────────────────────────
edit_config() {
    if [ "$(get_mtg_gen)" = "v1" ]; then
        echo ""
        echo -e "  ${YELLOW}[!] У MTG 1.0.x нет конфиг-файла: параметры задаются при установке${NC}"
        echo ""
        pause_key "Нажмите любую клавишу для возврата..."
        return 0
    fi
    config_path=$(get_config_path)
    if [ ! -f "$config_path" ]; then
        echo ""
        echo -e "  ${YELLOW}[!] Файл конфига не найден по пути: $config_path"
        echo -e "  ${GRAY}Используйте пункт 4 для обновления пути к конфигу${NC}"
        echo ""
        pause_key "Нажмите любую клавишу для возврата..."
        return 1
    fi
    echo ""
    echo -e "  ${BLUE}[i]${NC} Открытие конфига: $config_path"
    if command -v nano >/dev/null 2>&1; then
        echo -e "  ${GRAY}После редактирования сохраните файл (Ctrl+O) и закройте (Ctrl+X)${NC}"
        echo ""
        pause_key "Нажмите любую клавишу для продолжения..."
        nano "$config_path"
    elif command -v vim >/dev/null 2>&1; then
        echo -e "  ${YELLOW}[!] nano не установлен. Использую vim.${NC}"
        echo -e "  ${GRAY}Для сохранения: ESC → :wq, для выхода без сохранения: ESC → :q!${NC}"
        echo ""
        pause_key "Нажмите любую клавишу для продолжения..."
        vim "$config_path"
    elif command -v vi >/dev/null 2>&1; then
        echo -e "  ${YELLOW}[!] Использую vi.${NC}"
        echo -e "  ${GRAY}Для сохранения: ESC → :wq, для выхода без сохранения: ESC → :q!${NC}"
        echo ""
        pause_key "Нажмите любую клавишу для продолжения..."
        vi "$config_path"
    else
        echo -e "  ${RED}[✗] Ни один редактор не найден (nano, vim, vi)${NC}"
        pause_key "Нажмите любую клавишу для возврата..."
        return 1
    fi
    echo ""
    echo -e "  ${GREEN}[✓] Редактирование завершено"
    pause_key "Нажмите любую клавишу для возврата..."
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
    pause_key "Нажмите любую клавишу для возврата..."
}

# ── Функция просмотра логов ──────────────────────────────────
view_logs() {
    echo ""
    echo -e "  ${BLUE}[i]${NC} Просмотр логов MTG (Ctrl+C для выхода)..."
    echo ""
    pause_key "Нажмите любую клавишу для продолжения..."
    journalctl -u mtg.service -f
    echo ""
    pause_key "Нажмите любую клавишу для возврата..."
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
    { read -r confirm </dev/tty; } 2>/dev/null || true
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        echo -e "  ${GRAY}Удаление отменено${NC}"
        echo ""
        pause_key "Нажмите любую клавишу для возврата..."
        return 1
    fi

    echo ""
    echo -e "  ${BLUE}[i]${NC} Удаление MTG..."
    purge_mtg_silent

    echo -e "  ${GREEN}[✓] MTG успешно удалён"
    echo ""
    pause_key "Нажмите любую клавишу для возврата..."
}

# ── Функция обновления пути к конфигу ──────────────────────
update_config_path() {
    if [ "$(get_mtg_gen)" = "v1" ]; then
        echo ""
        echo -e "  ${YELLOW}[!] У MTG 1.0.x нет конфиг-файла, путь указывать нечему${NC}"
        echo ""
        pause_key "Нажмите любую клавишу для возврата..."
        return 0
    fi
    echo ""
    local default_path="/etc/mtg.toml"
    local input
    local confirm
    echo -en "Укажите путь к конфигу MTG (Enter для ${default_path}, N/n для отмены): "
    { read -r input </dev/tty; } 2>/dev/null || { echo; return 1; }
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
        { read -r confirm </dev/tty; } 2>/dev/null || true
        if [[ ! "$confirm" =~ ^[yY]$ ]]; then
            echo -e "  ${GRAY}Отменено${NC}"
            return 1
        fi
    fi
    mkdir -p /opt/mtpr-simple
    echo "$input" > "$CONFIG_PATH_FILE"
    echo -e "  ${GREEN}[✓] Путь сохранён: $input"
    echo ""
    pause_key "Нажмите любую клавишу для возврата..."
}

# ── Функция показа ссылки ────────────────────────────────────
show_link() {
    echo ""
    echo -e  "  ${BLUE}[i]${NC} Генерация ссылки для подключения..."
    
    local config_path secret
    config_path=$(get_config_path)
    if [ "$(get_mtg_gen)" = "v1" ]; then
        secret=$(_mtg_v1_get secret)
    else
        secret=$(get_mtg_secret "$config_path")
    fi
    
    if [ -z "$secret" ]; then
        echo -e "  ${RED}[✗] Не удалось получить секрет из конфига.${NC}"
        pause_key "Нажмите любую клавишу для возврата..."
        return 1
    fi
    
    local ip
    ip=$(get_public_ip)
    if [ -z "$ip" ]; then
        ip="SERVER_IP"
    fi
    
    local port
    port=$(mtg_current_port)
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
    pause_key "Нажмите любую клавишу для возврата..."
}

# ── Неинтерактивная установка (install.sh, автоматизация) ────
install_mtg_silent() {
    local gen="${1:-v2}" port="${2:-443}" domain="${3:-rutube.ru}"
    local secret=""

    if is_mtg_installed; then
        purge_mtg_silent
    fi
    install_mtg_binary "$gen" || return 1

    secret=$(_gen_mtg_secret "$domain" "$gen")
    if [ -z "$secret" ]; then
        echo -e "  ${RED}[✗] Не удалось сгенерировать секрет${NC}" >&2
        return 1
    fi

    mkdir -p /opt/mtpr-simple
    if [ "$gen" = "v1" ]; then
        printf 'gen=v1\nsecret=%s\nport=%s\ndomain=%s\n' "$secret" "$port" "$domain" > "$MTG_V1_CONF"
        rm -f "$CONFIG_PATH_FILE"
        cat > /etc/systemd/system/mtg.service << EOF
[Unit]
Description=MTG - MTProto proxy (1.0.x)
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/mtg run -b 0.0.0.0:${port} ${secret}
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
    else
        cat > /etc/mtg.toml << EOF
secret = "${secret}"
bind-to = "0.0.0.0:${port}"
EOF
        echo "/etc/mtg.toml" > "$CONFIG_PATH_FILE"
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
    fi
    echo "$gen" > "$MTG_GEN_FILE"

    # Порт на MTG ставится тот же, что и для других прокси: без правила
    # в ufw входящие SYN приходят, а ответа нет (issue #34)
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi '^Status: active'; then
        ufw allow "$port"/tcp >/dev/null 2>&1 && echo -e "  ${GREEN}[✓] ufw: открыт порт ${port}/tcp${NC}"
    fi

    systemctl daemon-reload 2>/dev/null || true
    systemctl enable mtg.service >/dev/null 2>&1 || true
    if systemctl restart mtg.service 2>/dev/null; then
        echo -e "  ${GREEN}[✓] MTG (${gen}) установлен на порт ${port}${NC}"
    else
        echo -e "  ${RED}[✗] Служба mtg.service не запустилась${NC}" >&2
        return 1
    fi

    local ip
    ip=$(get_public_ip)
    [ -z "$ip" ] && ip="SERVER_IP"
    echo "  https://t.me/proxy?server=${ip}&port=${port}&secret=${secret}"
    return 0
}

if [ "${1:-}" = "--install-silent" ]; then
    install_mtg_silent "${2:-v2}" "${3:-443}" "${4:-rutube.ru}"
    exit $?
fi

# ── Главное меню ─────────────────────────────────────────────
while true; do
    clear 2>/dev/null || true
    echo ""
    echo -e "  ${BOLD}MTG меню v0.21${NC}"
    echo -e "  ${DIM}===========================${NC}"
    echo ""

    if is_mtg_installed; then
        echo -e "  ${NC}${BOLD}MTG:${NC}${GREEN} установлен${NC}"
        version=$(get_mtg_version)
        if [ -n "$version" ]; then
            echo -e "  ${NC}${BOLD}Версия:${NC} ${GREEN}${version}${NC}"
        fi
        if [ "$(get_mtg_gen)" = "v1" ]; then
            echo -e "  ${BOLD}Поколение:${NC} 1.0.x"
        else
            echo -e "  ${BOLD}Поколение:${NC} 2.x"
        fi
        port=$(mtg_current_port)
        if [ -n "$port" ]; then
            echo -e "  ${BOLD}Порт:${NC} ${CYAN}${port}${NC}"
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
        if [ "$(get_mtg_gen)" = "v1" ]; then
            # У 1.0.x нет файла конфига: параметры передаются флагами в службе.
            echo -e "  ${DIM}Конфиг: нет (MTG 1.0.x работает без файла)${NC}"
        else
            current_path=$(get_config_path)
            echo -e "  ${DIM}Текущий путь к конфигу: ${current_path}${NC}"
        fi
        echo ""
    fi

    echo -en "  ${BOLD}Выбор:${NC} "
    { read -r choice </dev/tty; } 2>/dev/null || { echo; break; }

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
            # Только выходим: proxymenu.sh запущен выше и сам вернётся в цикл.
            break
            ;;
        *)
            echo "  Неверный выбор"
            sleep 0.1
            ;;
    esac
done
