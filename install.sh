#!/bin/bash
# install.sh – Главный установщик MEKOPR с поддержкой аргументов

set -e

BASE_URL="https://raw.githubusercontent.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/main"
INSTALL_DIR="/opt/mtpr-simple"

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

# ── Проверка root ────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}[✗]${NC} Запустите от root: ${BOLD}curl -fsSL ... | sudo bash${NC}" >&2
    exit 1
fi

# ── Функция скачивания файла ─────────────────────────────────
download_file() {
    local file="$1"
    local dest="$2"
    local url="$BASE_URL/$file"
    
    mkdir -p "$(dirname "$dest")"
    
    if curl -fsSL "$url" -o "$dest" 2>/dev/null; then
        chmod +x "$dest" 2>/dev/null || true
        return 0
    else
        return 1
    fi
}

# ── Функция проверки и загрузки файла ────────────────────────
ensure_file() {
    local file="$1"
    local dest="$INSTALL_DIR/$file"
    
    if [ ! -f "$dest" ]; then
        log_info "Скачивание $file..."
        if download_file "$file" "$dest"; then
            log_success "$file загружен"
        else
            log_error "Не удалось загрузить $file"
            return 1
        fi
    fi
    chmod +x "$dest" 2>/dev/null || true
    return 0
}

# ── Функция обрезки пробелов ──────────────────────────────
trim() {
    local var="$1"
    var="${var#"${var%%[![:space:]]*}"}"
    var="${var%"${var##*[![:space:]]}"}"
    printf '%s' "$var"
}

# ── Файл для сохранения пути к конфигу ──────────────────────
CONFIG_PATH_FILE="/opt/mtpr-simple/config_path"

# ── Функция получения текущего пути к конфигу ──────────────
get_config_path() {
    if [ -f "$CONFIG_PATH_FILE" ] && [ -s "$CONFIG_PATH_FILE" ]; then
        local path=$(cat "$CONFIG_PATH_FILE")
        if [ "$path" != "skip" ]; then
            echo "$path"
            return 0
        fi
    fi
    echo "/etc/telemt/telemt.toml"
    return 0
}

# ── Функции для работы с TOML (из telemt1.sh) ──────────────
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

# ── Расширенное обнаружение Telemt ──────────────────────────
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
        DETECTED_TLS_DOMAIN=$(grep -E '^tls_domain[[:space:]]*=' "$DETECTED_CONFIG_PATH" 2>/dev/null | head -1 | awk -F'=' '{print $2}' | sed 's/#.*//' | tr -d ' "')
        
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

# ── Функция генерации ссылок для подключения (ИСПРАВЛЕНА) ────
generate_proxy_links() {
    local config_path=$(get_config_path)
    if [ ! -f "$config_path" ]; then
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
    
    # ── Попробуем получить public_addr из секции [[web.vhosts]] ──
    local web_public_addr=""
    if [ -f "$config_path" ]; then
        web_public_addr=$(grep -E '^public_addr[[:space:]]*=' "$config_path" | head -1 | awk -F'"' '{print $2}' | cut -d: -f1)
    fi
    
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
    
    # ── Определяем сервер (IP или public_host) ──
    local server=""
    if [ -n "$web_public_addr" ]; then
        server="$web_public_addr"
    elif [ -n "$detected_public_host" ]; then
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
            # Используем od вместо xxd для 100% совместимости
            hex_domain=$(echo -n "$detected_tls_domain" | od -An -tx1 | tr -d ' \n' 2>/dev/null)
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

# ── Функция добавления ad_tag в конфиг Telemt (без перезапуска) ──
add_ad_tag_to_config() {
    local ad_tag="$1"
    local config_path=$(get_config_path)
    
    if [ -z "$ad_tag" ]; then
        return 0
    fi
    
    if [ ! -f "$config_path" ]; then
        log_error "Файл конфига не найден: $config_path"
        return 1
    fi
    
    # Проверяем, есть ли уже ad_tag в секции [general]
    if grep -q '^ad_tag[[:space:]]*=' "$config_path"; then
        sed -i "s/^ad_tag[[:space:]]*=.*/ad_tag = \"$ad_tag\"/" "$config_path"
        log_info "ad_tag обновлён: $ad_tag"
    else
        if grep -q '^\[general\]' "$config_path"; then
            sed -i "/^\[general\]/a ad_tag = \"$ad_tag\"" "$config_path"
            log_info "ad_tag добавлен в секцию [general]: $ad_tag"
        else
            echo "" >> "$config_path"
            echo "[general]" >> "$config_path"
            echo "ad_tag = \"$ad_tag\"" >> "$config_path"
            log_info "Создана секция [general] и добавлен ad_tag: $ad_tag"
        fi
    fi
    return 0
}

# ── Функция генерации случайного 32-символьного hex-секрета ──
generate_secret() {
    if command -v openssl &>/dev/null; then
        openssl rand -hex 16 2>/dev/null
    elif command -v od &>/dev/null; then
        head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' 2>/dev/null
    else
        echo "$(date +%s)$RANDOM$RANDOM" | sha256sum | head -c 32
    fi
}

# ── Функция добавления пользователя в секцию [access.users] (без перезапуска) ──
add_user_to_config() {
    local user_name="$1"
    local user_secret="$2"
    local config_path=$(get_config_path)
    
    if [ -z "$user_name" ] || [ -z "$user_secret" ]; then
        log_error "Имя пользователя и секрет обязательны"
        return 1
    fi
    
    if [ ! -f "$config_path" ]; then
        log_error "Файл конфига не найден: $config_path"
        return 1
    fi
    
    if grep -q "^[[:space:]]*${user_name}[[:space:]]*=" "$config_path"; then
        log_warning "Пользователь '$user_name' уже существует в конфиге, пропускаем"
        return 0
    fi
    
    if grep -q '^\[access\.users\]' "$config_path"; then
        sed -i "/^\[access\.users\]/a ${user_name} = \"$user_secret\"" "$config_path"
        log_info "Добавлен пользователь: $user_name = $user_secret"
    else
        echo "" >> "$config_path"
        echo "[access.users]" >> "$config_path"
        echo "${user_name} = \"$user_secret\"" >> "$config_path"
        log_info "Создана секция [access.users] и добавлен пользователь: $user_name"
    fi
    return 0
}

# ── Функция добавления/обновления public_host в секции [server.links] (без перезапуска) ──
add_public_host_to_config() {
    local public_host="$1"
    local config_path=$(get_config_path)
    
    if [ -z "$public_host" ]; then
        return 0
    fi
    
    if [ ! -f "$config_path" ]; then
        log_error "Файл конфига не найден: $config_path"
        return 1
    fi
    
    # Проверяем, есть ли секция [server.links]
    if grep -q '^\[server\.links\]' "$config_path"; then
        # Секция есть – проверяем public_host
        if grep -q '^public_host[[:space:]]*=' "$config_path"; then
            sed -i "s/^public_host[[:space:]]*=.*/public_host = \"$public_host\"/" "$config_path"
            log_info "public_host обновлён: $public_host"
        else
            sed -i "/^\[server\.links\]/a public_host = \"$public_host\"" "$config_path"
            log_info "public_host добавлен в секцию [server.links]: $public_host"
        fi
    else
        # Секции нет – создаём
        echo "" >> "$config_path"
        echo "[server.links]" >> "$config_path"
        echo "public_host = \"$public_host\"" >> "$config_path"
        log_info "Создана секция [server.links] и добавлен public_host: $public_host"
    fi
    return 0
}

# ── Функция получения последней версии Telemt ──────────────
get_latest_telemt_version() {
    local version=""
    version=$(timeout 10 curl -fsS --max-time 5 "https://api.github.com/repos/telemt/telemt/releases/latest" 2>/dev/null | awk -F'"' '/"tag_name"/ {print $4}')
    if [ -z "$version" ]; then
        version="3.4.24"
    fi
    echo "$version"
}

# ── Функция скачивания и подстановки WEB-конфига ────────────
setup_web_config() {
    local web_user="$1"
    local web_secret="$2"
    local web_host="$3"
    local web_ip="$4"
    local config_path=$(get_config_path)
    
    # Скачиваем шаблон webconfig.txt
    local web_template="/tmp/webconfig.txt"
    log_info "Скачивание шаблона WEB-конфига..."
    if ! curl -fsSL "$BASE_URL/data/webconfig.txt" -o "$web_template"; then
        log_error "Не удалось скачать шаблон webconfig.txt"
        return 1
    fi
    
    # Проверяем обязательные параметры
    if [ -z "$web_host" ]; then
        log_error "WEB-хост (домен) обязателен. Укажите -web-host"
        return 1
    fi
    
    if [ -z "$web_ip" ]; then
        web_ip=$(get_public_ip)
        if [ -z "$web_ip" ]; then
            log_error "Не удалось определить внешний IP"
            return 1
        fi
        log_info "Внешний IP определён: $web_ip"
    fi
    
    # Генерируем секрет, если не передан
    if [ -z "$web_secret" ]; then
        web_secret=$(generate_secret)
        log_info "Сгенерирован секрет для WEB: $web_secret"
    fi
    
    # Если пользователь не указан, используем "webuser"
    if [ -z "$web_user" ]; then
        web_user="webuser"
        log_info "Имя пользователя не указано, используем: $web_user"
    fi
    
    # Читаем шаблон и подставляем значения
    local web_config_content=$(cat "$web_template")
    
    # Заменяем плейсхолдеры
    web_config_content="${web_config_content//\"zdez.tvoi.domen.com\"/\"$web_host\"}"
    web_config_content="${web_config_content//\"12.34.56.789:443\"/\"$web_ip:443\"}"
    web_config_content="${web_config_content//hello = \"e5544cb710bae52b8bcbc05375921c16\"/hello = \"$web_secret\"}"
    
    # Заменяем имя пользователя в access.users (если отличается от "hello")
    if [ "$web_user" != "hello" ]; then
        web_config_content="${web_config_content//hello = /$web_user = }"
        # Меняем в links_show
        web_config_content="${web_config_content//links_show = [\"hello\"]/links_show = [\"$web_user\"]}"
        # Меняем в профиле
        web_config_content="${web_config_content//user = \"hello\"/user = \"$web_user\"}"
    fi
    
    # Сохраняем полученный конфиг
    echo "$web_config_content" > "$config_path"
    log_success "WEB-конфиг сохранён в $config_path"
    
    rm -f "$web_template"
    return 0
}

# ── Функция установки и настройки Nginx для WEB-режима ──────
setup_nginx() {
    local web_host="$1"
    local web_ip="$2"
    
    if [ -z "$web_host" ]; then
        log_error "Для установки Nginx необходим домен (WEB_HOST)"
        return 1
    fi
    
    log_info "Установка Nginx и Certbot..."
    
    # Определяем пакетный менеджер
    if command -v apt-get &>/dev/null; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq nginx certbot python3-certbot-nginx
    elif command -v yum &>/dev/null; then
        yum install -y -q nginx certbot python3-certbot-nginx
    elif command -v dnf &>/dev/null; then
        dnf install -y -q nginx certbot python3-certbot-nginx
    else
        log_error "Не удалось определить пакетный менеджер для установки Nginx"
        return 1
    fi
    
    # Создаём decoy
    mkdir -p /var/lib/telemt/public
    echo "OK" > /var/lib/telemt/public/index.html
    log_success "Decoy создан: /var/lib/telemt/public/index.html"
    
    # Получаем сертификат с временным отключением IPv6 (если нужно)
    log_info "Получение SSL-сертификата для $web_host..."
    # Временно отключаем IPv6, чтобы certbot не пытался использовать его
    sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1
    sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1
    
    if ! certbot --nginx -d "$web_host" --non-interactive --agree-tos --email admin@"$web_host" 2>/dev/null; then
        # Если не получилось, пробуем standalone
        systemctl stop nginx
        if certbot certonly --standalone -d "$web_host" --non-interactive --agree-tos --email admin@"$web_host" 2>/dev/null; then
            systemctl start nginx
        else
            log_error "Не удалось получить SSL-сертификат"
            sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1
            sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1
            return 1
        fi
    fi
    
    # Включаем IPv6 обратно
    sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1
    sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1
    
    log_success "SSL-сертификат получен"
    
    # Создаём конфиг Nginx
    local nginx_config="/etc/nginx/sites-available/default"
    log_info "Создание конфига Nginx для $web_host..."
    
    cat > "$nginx_config" <<EOF
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
    
    # Проверяем и перезагружаем Nginx
    if nginx -t 2>/dev/null; then
        systemctl restart nginx
        log_success "Nginx перезагружен с новым конфигом"
    else
        log_error "Конфигурация Nginx невалидна"
        return 1
    fi
    
    log_success "Nginx настроен для $web_host"
    return 0
}

# ── СТАРОЕ МЕНЮ (ПРОКСИ) ──────────────────────────────────────
show_proxy_menu() {
    clear 2>/dev/null || printf '\033[2J\033[H'
    echo ""
    echo -e "  ${CYAN}${BOLD}⚙️ ${NC}${BOLD}Meko Manager ${CYAN}${BOLD} v1.9 ${CYAN}${BOLD}| ${NC}${BOLD}Меню proxy ⚙️${NC}"
    echo -e "  ${BOLD}${DIM}═════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${BOLD}Выберите вариант установки:${NC}"
    echo ""
    echo -e "  ${GREEN}[1]${NC}  ${BOLD}Стандартная установка${NC}  ${GREEN}${BOLD}(рекомендуется)${NC}"
    echo -e "       ${DIM}Установит MEKO Launcher и все необходимые файлы${NC}"
    echo -e "       ${DIM}Для дальнейшей работы и управления Mtproto proxy"
    echo ""
    echo -e "  ${CYAN}[2]${NC}  ${BOLD}Автоматическая установка${NC}  ${CYAN}(для новичков)${NC}"
    echo -e "       ${DIM}Откроет меню автоматической и полуавтоматической установки прокси${NC}"
    echo -e ""
    echo -e "       ${DIM}Полуавтоматический вариант попросит ввести кастомные параметры"
    echo -e "       ${DIM}Автоматический вариант установит универсальные параметры сам"
    echo ""
    echo -e "  ${RED}${BOLD}[0]${NC}  ${RED}${BOLD}Назад ${NC}"
    echo ""
    echo -en "  ${NC}${BOLD}Ввод (${GREEN}${BOLD}Enter${NC}${BOLD} - стандартная установка):${NC} "

    if ! read -r choice </dev/tty 2>/dev/null; then
        echo ""
        echo -e "  ${RED}[✗]${NC} Не удалось прочитать ввод. Запустите скрипт интерактивно."
        exit 1
    fi

    case "$choice" in
        0)
            echo ""
            log_info "Возврат в главное меню..."
            return 0
            ;;
        2)
            echo ""
            log_info "Запуск автоустановки..."
            if ensure_file "install_auto.sh"; then
                bash "$INSTALL_DIR/install_auto.sh"
                exit 0
            else
                log_error "Не удалось загрузить install_auto.sh"
                exit 1
            fi
            ;;
        3)
            echo ""
            log_info "Запуск ручной установки..."
            if ensure_file "install_manual.sh"; then
                bash "$INSTALL_DIR/install_manual.sh"
                exit 0
            else
                log_error "Не удалось загрузить install_manual.sh"
                exit 1
            fi
            ;;
        *)
            # 1 или Enter — стандартная установка
            echo ""
            log_info "Запуск стандартной установки MEKO Launcher..."
            if ensure_file "install_main.sh"; then
                bash "$INSTALL_DIR/install_main.sh"
                exit 0
            else
                log_error "Не удалось загрузить install_main.sh"
                exit 1
            fi
            ;;
    esac
}

# ── НОВОЕ ГЛАВНОЕ МЕНЮ ────────────────────────────────────────
show_main_menu() {
    while true; do
        clear 2>/dev/null || printf '\033[2J\033[H'
        echo ""
        echo -e "  ${CYAN}${BOLD}⚙️ ${NC}${BOLD}MEKO MANAGER ${CYAN}${BOLD}V1.95 ${NC}${BOLD}Меню установщика ${CYAN}${BOLD}⚙️${NC}"
        echo -e "  ${BOLD}${DIM}═════════════════════════════════════════════════${NC}"
        echo ""
        echo -e "  ${BOLD}Выберите что вы хотите открыть:${NC}"
        echo ""
        echo -e "  ${GREEN}[1]${NC}  ${BOLD}Меню proxy${NC}"
        echo -e "       ${DIM}Меню установки Mtproto фикса, proxy,  ${NC}"
        echo -e "       ${DIM}И/или Meko Managerа для дальнейшего управления и "
        echo -e "       ${DIM}Отслеживания работы"
        echo ""
        echo -e "  ${CYAN}[2]${NC}  ${BOLD}Меню VPN${NC}"
        echo -e "       ${DIM}Меню автоматической установки${NC}"
        echo -e "       ${DIM}VPN через 3x-ui или Remnawave"
        echo ""
        echo -e "  ${YELLOW}[3]${NC}  ${BOLD}Установка mtproxyl${NC}"
        echo -e "       ${DIM}Установка Telegram MTProto прокси менеджера${NC}"
        echo -e "       ${DIM}на базе движка telemt (Docker)${NC}"
        echo ""
        echo -e "  ${RED}${BOLD}[0]${NC}  ${RED}${BOLD}Выход${NC}"
        echo ""
        echo -en "  ${NC}${BOLD}Ввод (${GREEN}${BOLD}Enter${NC}${BOLD} - установка proxy):${NC} "

        if ! read -r choice </dev/tty 2>/dev/null; then
            echo ""
            echo -e "  ${RED}[✗]${NC} Не удалось прочитать ввод."
            exit 1
        fi

        case "$choice" in
            0)
                echo ""
                log_info "Выход..."
                exit 0
                ;;
            2)
                echo ""
                log_info "Запуск установки VPN..."
                if ensure_file "install_vpn.sh"; then
                    bash "$INSTALL_DIR/install_vpn.sh"
                else
                    log_error "Не удалось загрузить install_vpn.sh"
                fi
                echo ""
                echo -e "  ${GRAY}Нажмите Enter для возврата в главное меню...${NC}"
                read -r </dev/tty 2>/dev/null
                ;;
            3)
                echo ""
                log_info "Запуск установки mtproxyl..."
                echo ""
                wget -qO /tmp/mtproxyl-install.sh https://raw.githubusercontent.com/Liafanx/MTProxyL/main/install.sh && sudo bash /tmp/mtproxyl-install.sh && source ~/.bashrc
                echo ""
                log_success "Установка mtproxyl завершена"
                echo ""
                echo -e "  ${GRAY}Нажмите Enter для возврата в главное меню...${NC}"
                read -r </dev/tty 2>/dev/null
                ;;
            *)
                # 1 или Enter — меню proxy
                show_proxy_menu
                ;;
        esac
    done
}

# ══════════════════════════════════════════════════════════════
#  ПАРСИНГ АРГУМЕНТОВ КОМАНДНОЙ СТРОКИ
# ══════════════════════════════════════════════════════════════

FLAG_TELEMT=""
FLAG_ZIG=""
FLAG_MTG=""
FLAG_FIX=""
FLAG_NO_FIX=""
FLAG_WEB=""
FLAG_NGINX=""
FIX_TYPE=""              # v2, v3, v4, nft
FIX_PORT=""              # порт для фикса
PROXY_PORT=""            # порт прокси
DOMAIN=""
TELEMT_VERSION=""
AD_TAG=""
USER_NAME=""
USER_SECRET=""
PUBLIC_HOST=""
WEB_USER=""
WEB_SECRET=""
WEB_HOST=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -telemt)
            FLAG_TELEMT="true"
            shift
            ;;
        -zig)
            FLAG_ZIG="true"
            shift
            ;;
        -mtg)
            FLAG_MTG="true"
            shift
            ;;
        -fix)
            FLAG_FIX="true"
            shift
            ;;
        -no-fix)
            FLAG_NO_FIX="true"
            shift
            ;;
        -web)
            FLAG_WEB="true"
            shift
            ;;
        -web-user)
            WEB_USER="$2"
            shift 2
            ;;
        -web-secret)
            WEB_SECRET="$2"
            shift 2
            ;;
        -web-host)
            WEB_HOST="$2"
            shift 2
            ;;
        -nginx)
            FLAG_NGINX="true"
            shift
            ;;
        -fix-type)
            case "$2" in
                v2|v3|v4|nft) FIX_TYPE="$2" ;;
                *) echo -e "${RED}[✗]${NC} Неверный тип фикса: $2 (доступны: v2, v3, v4, nft)"; exit 1 ;;
            esac
            shift 2
            ;;
        -fix-port)
            if [[ "$2" =~ ^[0-9]+$ ]] && [ "$2" -ge 1 ] && [ "$2" -le 65535 ]; then
                FIX_PORT="$2"
                shift 2
            else
                echo -e "${RED}[✗]${NC} Неверный порт: $2"; exit 1
            fi
            ;;
        -port)
            if [[ "$2" =~ ^[0-9]+$ ]] && [ "$2" -ge 1 ] && [ "$2" -le 65535 ]; then
                PROXY_PORT="$2"
                shift 2
            else
                echo -e "${RED}[✗]${NC} Неверный порт: $2"; exit 1
            fi
            ;;
        -domain)
            DOMAIN="$2"
            shift 2
            ;;
        -version)
            TELEMT_VERSION="$2"
            shift 2
            ;;
        -ad_tag)
            AD_TAG="$2"
            shift 2
            ;;
        -user)
            USER_NAME="$2"
            if [[ -n "$3" && ! "$3" =~ ^- ]]; then
                USER_SECRET="$3"
                shift 3
            else
                USER_SECRET=""
                shift 2
            fi
            ;;
        -public_host)
            PUBLIC_HOST="$2"
            shift 2
            ;;
        -h|--help)
            echo ""
            echo -e "  ${BOLD}Использование:${NC}"
            echo -e "    curl ... | sudo bash -s -- [опции]"
            echo ""
            echo -e "  ${BOLD}Опции:${NC}"
            echo -e "    -telemt                установить Telemt"
            echo -e "    -zig                   установить Mtproto.zig"
            echo -e "    -mtg                   установить MTG (пока не реализовано)"
            echo -e "    -fix                   установить фикс"
            echo -e "    -fix-type {v2|v3|v4|nft}   тип фикса (по умолчанию v3)"
            echo -e "    -fix-port <порт>       порт для фикса (если не указан, берётся из -port или спросится)"
            echo -e "    -port <порт>           порт для прокси (и для фикса, если не задан -fix-port)"
            echo -e "    -domain <домен>        SNI домен для прокси (по умолчанию ozon.ru)"
            echo -e "    -version <версия>      версия Telemt (по умолчанию последняя)"
            echo -e "    -ad_tag <тег>          добавить ad_tag в конфиг Telemt (в секцию [general])"
            echo -e "    -user <имя> [секрет]   добавить пользователя в [access.users] (если секрет не указан — будет запрошен или сгенерирован)"
            echo -e "    -public_host <домен>   добавить/обновить public_host в секции [server.links]"
            echo -e "    -web                   установить Telemt в WEB-режиме"
            echo -e "    -web-user <имя>        имя пользователя для WEB-режима (по умолчанию webuser)"
            echo -e "    -web-secret <секрет>   секрет для WEB-режима (если не указан — генерируется автоматически)"
            echo -e "    -web-host <домен>      домен для WEB-хоста (обязательно)"
            echo -e "    -nginx                 установить и настроить Nginx + Certbot для WEB-режима (требует -web и -web-host)"
            echo -e "    -no-fix                отключить установку фикса"
            echo -e "    -h, --help             показать эту справку"
            echo ""
            echo -e "  ${BOLD}Примеры:${NC}"
            echo -e "    # Только фикс V3 на порт 8443"
            echo -e "    curl ... | sudo bash -s -- -fix -fix-port 8443"
            echo ""
            echo -e "    # Telemt + V3 фикс с ad_tag, пользователем и public_host"
            echo -e "    curl ... | sudo bash -s -- -telemt -domain my.domain -port 9443 -fix -ad_tag 4c4140a4c40c5e2b080578a7e4e38c95 -user vasya -public_host my.domain"
            echo ""
            echo -e "    # Telemt без фикса"
            echo -e "    curl ... | sudo bash -s -- -telemt -no-fix"
            echo ""
            echo -e "    # V4 фикс (zapret2) на порт 443"
            echo -e "    curl ... | sudo bash -s -- -fix -fix-type v4"
            echo ""
            echo -e "    # Telemt в WEB-режиме с полной автоматической установкой Nginx"
            echo -e "    curl ... | sudo bash -s -- -telemt -web -web-host my.domain.com -web-user myuser -nginx"
            exit 0
            ;;
        *)
            echo -e "${RED}[✗]${NC} Неизвестный аргумент: $1"
            echo -e "  Используйте -h для справки"
            exit 1
            ;;
    esac
done

# ══════════════════════════════════════════════════════════════
#  АВТОМАТИЧЕСКАЯ УСТАНОВКА (если передан хотя бы один флаг)
# ══════════════════════════════════════════════════════════════

if [[ -n "$FLAG_TELEMT" || -n "$FLAG_ZIG" || -n "$FLAG_MTG" || -n "$FLAG_FIX" || -n "$FLAG_WEB" ]]; then

    echo ""
    echo -e "  ${CYAN}${BOLD}⚙️ АВТОМАТИЧЕСКАЯ УСТАНОВКА v0.82${NC}"
    echo -e "  ${DIM}═════════════════════════════════════════════════${NC}"
    echo ""

    # ── 1. Запрос недостающих параметров ──────────────────────

    # Домен (если ставится прокси)
    if [[ -n "$FLAG_TELEMT" || -n "$FLAG_ZIG" ]]; then
        if [ -z "$DOMAIN" ]; then
            echo -en "  ${BOLD}Введите SNI домен${NC} ${DIM}(по умолчанию: ozon.ru)${NC}: " >&2
            if [ -r /dev/tty ]; then
                read -r DOMAIN </dev/tty
            else
                DOMAIN=""
            fi
            [ -z "$DOMAIN" ] && DOMAIN="ozon.ru"
        fi
        if [ -z "$PROXY_PORT" ]; then
            echo -en "  ${BOLD}Введите порт для прокси${NC} ${DIM}(по умолчанию: 443)${NC}: " >&2
            if [ -r /dev/tty ]; then
                read -r PROXY_PORT </dev/tty
            else
                PROXY_PORT=""
            fi
            [ -z "$PROXY_PORT" ] && PROXY_PORT="443"
        fi
        # Версия Telemt
        if [[ -n "$FLAG_TELEMT" && -z "$TELEMT_VERSION" ]]; then
            echo -en "  ${BOLD}Введите версию Telemt${DIM} (Enter - последняя версия)${NC}: " >&2
            if [ -r /dev/tty ]; then
                read -r TELEMT_VERSION </dev/tty
            else
                TELEMT_VERSION=""
            fi
            if [ -z "$TELEMT_VERSION" ] || [ "$TELEMT_VERSION" = "последняя" ]; then
                TELEMT_VERSION=$(get_latest_telemt_version)
                log_info "Выбран SNI: $DOMAIN"
                log_info "Выбрана последняя версия: $TELEMT_VERSION"
            fi
        fi
    fi

    # ── Запрос WEB-параметров, если передан флаг -web ──────
    if [[ -n "$FLAG_WEB" ]]; then
        # WEB-хост (обязательно)
        if [ -z "$WEB_HOST" ]; then
            echo ""
            echo -e "  ${BOLD}Для WEB-режима необходимо указать домен${NC}"
            echo -en "  ${BOLD}Введите домен для WEB-хоста:${NC} "
            if [ -r /dev/tty ]; then
                read -r WEB_HOST </dev/tty
            else
                WEB_HOST=""
            fi
            if [ -z "$WEB_HOST" ]; then
                log_error "Домен для WEB-режима обязателен. Укажите -web-host или введите сейчас."
                exit 1
            fi
        fi
        
        # WEB-пользователь
        if [ -z "$WEB_USER" ]; then
            echo -en "  ${BOLD}Введите имя пользователя для WEB${NC} ${DIM}(по умолчанию: webuser)${NC}: "
            if [ -r /dev/tty ]; then
                read -r WEB_USER </dev/tty
            else
                WEB_USER=""
            fi
            [ -z "$WEB_USER" ] && WEB_USER="webuser"
        fi
        
        # WEB-секрет
        if [ -z "$WEB_SECRET" ]; then
            echo -en "  ${BOLD}Введите секрет для WEB${NC} ${DIM}(Enter - сгенерировать автоматически)${NC}: "
            if [ -r /dev/tty ]; then
                read -r WEB_SECRET </dev/tty
            else
                WEB_SECRET=""
            fi
            if [ -z "$WEB_SECRET" ]; then
                WEB_SECRET=$(generate_secret)
                log_info "Сгенерирован секрет: $WEB_SECRET"
            fi
        fi
    fi

    # Порт фикса
    if [[ -n "$FLAG_FIX" && -z "$FLAG_NO_FIX" ]]; then
        if [ -z "$FIX_PORT" ]; then
            if [ -n "$PROXY_PORT" ]; then
                FIX_PORT="$PROXY_PORT"
                log_info "Порт фикса взят из порта прокси: $FIX_PORT"
            else
                echo -en "  ${BOLD}Введите порт для фикса${NC} ${DIM}(по умолчанию: 443)${NC}: " >&2
                if [ -r /dev/tty ]; then
                    read -r FIX_PORT </dev/tty
                else
                    FIX_PORT=""
                fi
                [ -z "$FIX_PORT" ] && FIX_PORT="443"
            fi
        fi
        # Тип фикса (если не указан, спрашиваем)
        if [ -z "$FIX_TYPE" ]; then
            echo "" >&2
            echo -e "  ${BOLD}Выберите вариант фикса:${NC}" >&2
            echo -e "  ${DIM}══════════════════════════════════════════════${NC}" >&2
            echo "" >&2
            echo -e "  ${YELLOW}[V2]${NC}  ${BOLD}v2 фикс iptables${NC} (TTL+Length) — разделение по TTL+Length" >&2
            echo -e "${DIM}  Если TTL <65 и length 64 -> это ios и принимаем пакеты без лимита" >&2
            echo -e "${DIM}  Иначе -> это другое ус-во и ставим SYN 1 пакет в 1.1 сек." >&2
            echo "" >&2
            echo -e "  ${GREEN}[V3]${NC}  ${BOLD}v3 фикс iptables${NC} (u32) — разделение по байтам из пакета — ${GREEN}рекомендуется${NC}" >&2
            echo -e "${DIM}  Если совпало -> это ios и принимаем пакеты без лимита" >&2
            echo -e "${DIM}  Если не совпало -> это другое ус-во и ставим SYN 1 пакет в 1.1 сек." >&2
            echo "" >&2
            echo -e "  ${CYAN}[V4]${NC}  ${BOLD}v4 фикс zapret2${NC} — быстрый (на этапе тестирования)" >&2
            echo -e "${DIM}  Работает с помощью zapret2 на уровне TCP-пакетов:" >&2
            echo -e "${DIM}  disorder + badsum + window control" >&2
            echo "" >&2
            echo -e "  ${GREEN}[nft]${NC}  ${BOLD}v3 фикс nftables${NC} — совместим с Docker" >&2
            echo -e "${DIM}  Разделение по байтам из пакета, как в v3 iptables" >&2
            echo -e "${DIM}  Если совпало -> это ios и принимаем пакеты без лимита" >&2
            echo -e "${DIM}  Если не совпало -> это другое ус-во и ставим SYN 1 пакет в 1.1 сек." >&2
            echo "" >&2
            while true; do
                echo -en "  ${NC}${BOLD}Ввод${GREEN}${BOLD} (v2/v3/v4/nft, Enter - v3)${NC}:${NC} " >&2
                if [ -r /dev/tty ]; then
                    read -r answer </dev/tty
                else
                    answer=""
                fi
                answer="${answer:-v3}"
                case "$answer" in
                    v2|v3|v4|nft) FIX_TYPE="$answer"; break ;;
                    *) echo -e "  ${RED}Неверный ввод. Допустимо: v2, v3, v4, nft${NC}" >&2 ;;
                esac
            done
        fi
    fi

    # ── 2. Подготовка окружения ──────────────────────────────

    # Всегда скачиваем свежий rules.sh
    mkdir -p "$INSTALL_DIR/data"
    log_info "Загрузка свежего rules.sh..."
    curl -fsSL "$BASE_URL/data/rules.sh" -o "$INSTALL_DIR/data/rules.sh"
    chmod +x "$INSTALL_DIR/data/rules.sh"

    # Если тип фикса v4, скачиваем zapret2_fix.sh
    if [[ "$FIX_TYPE" == "v4" ]]; then
        log_info "Загрузка свежего zapret2_fix.sh..."
        curl -fsSL "$BASE_URL/data/zapret2_fix.sh" -o "$INSTALL_DIR/data/zapret2_fix.sh"
        chmod +x "$INSTALL_DIR/data/zapret2_fix.sh"
    fi

    # Подключаем rules.sh
    source "$INSTALL_DIR/data/rules.sh"

    # Если тип v4, подключаем zapret2_fix.sh
    if [[ "$FIX_TYPE" == "v4" ]]; then
        if [ -f "$INSTALL_DIR/data/zapret2_fix.sh" ]; then
            source "$INSTALL_DIR/data/zapret2_fix.sh"
        else
            log_error "zapret2_fix.sh не загружен"
            exit 1
        fi
    fi

    # ── 3. Установка прокси ──────────────────────────────────

    # Telemt
    if [[ -n "$FLAG_TELEMT" ]]; then
        echo "" >&2
        log_info "Установка Telemt версии $TELEMT_VERSION на домен $DOMAIN, порт $PROXY_PORT..."
        curl -fsSL https://raw.githubusercontent.com/telemt/telemt/main/install.sh | sh -s -- "$TELEMT_VERSION" -l 2 -d "$DOMAIN" -p "$PROXY_PORT"
        log_success "Telemt установлен"
        
        # Если передан флаг -web, настраиваем WEB-конфиг
        if [[ -n "$FLAG_WEB" ]]; then
            log_info "Настройка WEB-режима..."
            
            # Получаем внешний IP
            web_ip=$(get_public_ip)   # Убрали local
            if [ -z "$web_ip" ]; then
                log_error "Не удалось определить внешний IP"
                exit 1
            fi
            log_info "Внешний IP: $web_ip"
            
            # Настраиваем WEB-конфиг
            if setup_web_config "$WEB_USER" "$WEB_SECRET" "$WEB_HOST" "$web_ip"; then
                log_success "WEB-конфиг успешно настроен"
            else
                log_error "Ошибка настройки WEB-конфига"
                exit 1
            fi
            
            # Если передан флаг -nginx, устанавливаем и настраиваем Nginx
            if [[ -n "$FLAG_NGINX" ]]; then
                log_info "Установка и настройка Nginx + Certbot..."
                if setup_nginx "$WEB_HOST" "$web_ip"; then
                    log_success "Nginx успешно настроен"
                else
                    log_error "Ошибка настройки Nginx"
                    exit 1
                fi
            fi
        else
            # Обычная установка: добавляем ad_tag, пользователя, public_host
            if [ -n "$AD_TAG" ]; then
                add_ad_tag_to_config "$AD_TAG"
            fi
            
            if [ -n "$USER_NAME" ]; then
                if [ -z "$USER_SECRET" ]; then
                    echo -en "  ${BOLD}Введите секрет для пользователя $USER_NAME (Enter - сгенерировать автоматически)${NC}: " >&2
                    if [ -r /dev/tty ]; then
                        read -r input_secret </dev/tty
                    else
                        input_secret=""
                    fi
                    if [ -z "$input_secret" ]; then
                        USER_SECRET=$(generate_secret)
                        log_info "Сгенерирован секрет: $USER_SECRET"
                    else
                        USER_SECRET="$input_secret"
                    fi
                fi
                add_user_to_config "$USER_NAME" "$USER_SECRET"
            fi
            
            if [ -n "$PUBLIC_HOST" ]; then
                add_public_host_to_config "$PUBLIC_HOST"
            fi
        fi
        
        # Единый перезапуск telemt после всех изменений
        if systemctl restart telemt 2>/dev/null; then
            log_success "Telemt перезапущен для применения всех изменений"
        else
            log_warning "Не удалось перезапустить telemt (возможно, он не установлен как служба)"
        fi
        
        # ── Вывод ссылки на прокси ────────────────────────────
        echo "" >&2
        log_info "Ссылка для подключения к прокси:"
        echo "" >&2
        links=$(generate_proxy_links)
        if [ -n "$links" ]; then
            echo -e "$links" >&2
        else
            echo -e "  ${YELLOW}[!]${NC} Не удалось сгенерировать ссылку. Проверьте конфиг." >&2
        fi
        
        # ── Вывод WEB-ссылки (ИСПРАВЛЕНО: убраны local) ───────
        if [[ -n "$FLAG_WEB" ]]; then
            echo "" >&2
            log_info "WEB-ссылка:"
            echo "" >&2
            # Определяем secret_mode из конфига для пользователя
            config_path=$(get_config_path)   # убрали local
            secret_mode=$(grep -A1 "user = \"$WEB_USER\"" "$config_path" | grep 'secret_mode' | head -1 | awk -F'"' '{print $2}')
            if [ -z "$secret_mode" ]; then
                # Если не нашли, пробуем для "hello"
                secret_mode=$(grep -A1 'user = "hello"' "$config_path" | grep 'secret_mode' | head -1 | awk -F'"' '{print $2}')
            fi
            if [ "$secret_mode" = "dd" ]; then
                echo -e "  tg://webproxy?server=${WEB_HOST}&secret=dd${WEB_SECRET}" >&2
            else
                echo -e "  tg://webproxy?server=${WEB_HOST}&secret=${WEB_SECRET}" >&2
            fi
            echo "" >&2
        fi
        echo "" >&2
    fi

    # Zig
    if [[ -n "$FLAG_ZIG" ]]; then
        echo "" >&2
        log_info "Установка Mtproto.zig на домен $DOMAIN, порт $PROXY_PORT..."
        curl -fsSL https://raw.githubusercontent.com/sleep3r/mtproto.zig/main/deploy/bootstrap.sh | sudo bash
        sudo mtbuddy install --port "$PROXY_PORT" --domain "$DOMAIN" --middle-proxy --no-tcpmss --no-masking --no-nfqws --no-dpi --yes
        log_success "Mtproto.zig установлен"
    fi

    # MTG (пока заглушка)
    if [[ -n "$FLAG_MTG" ]]; then
        log_warning "Установка MTG пока не реализована в автоматическом режиме."
    fi

    # ── 4. Установка фикса ──────────────────────────────────

    if [[ -n "$FLAG_FIX" && -z "$FLAG_NO_FIX" ]]; then
        echo "" >&2
        log_info "Установка фикса типа $FIX_TYPE на порт $FIX_PORT..."

        # Вызываем install_syn_fix с переданными параметрами
        install_syn_fix -auto_install -port "$FIX_PORT" -type "$FIX_TYPE"

        log_success "Фикс установлен"
    fi

    echo "" >&2
    log_success "Автоматическая установка завершена!"
    echo "" >&2
    exit 0
fi

# ── ЕСЛИ АРГУМЕНТОВ НЕТ — ПОКАЗЫВАЕМ ИНТЕРАКТИВНОЕ МЕНЮ ──────
show_main_menu
