#!/bin/bash
# install.sh – Главный установщик MEKOPR с поддержкой аргументов

set -e

BASE_URL="https://raw.githubusercontent.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/main"
INSTALL_DIR="/opt/mtpr-simple"

# elrepo виснет на металлинке; на Fedora его нет, и dnf с --disablerepo=elrepo падает.
DNF_ELREPO_OPT=""
[ -f /etc/yum.repos.d/elrepo.repo ] && DNF_ELREPO_OPT="--disablerepo=elrepo"

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

# ── WEB-ссылка (путь внутри домена, telemt >= 3.5.8) ──────────
WEB_PATH_MIN_VERSION="3.5.8"

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

# ── Цвета (только когда stdout — терминал; в пайп/файл не течём ESC) ──
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    GRAY='\033[0;90m'
    BOLD='\033[1m'
    DIM='\033[2m'
    NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; GRAY=''; BOLD=''; DIM=''; NC=''
fi

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

download_file() {
    local file="$1"
    local dest="$2"
    local url="$BASE_URL/$file"
    
    mkdir -p "$(dirname "$dest")"
    
    if curl -fsSL "$url" -o "$dest" 2>/dev/null; then
        chmod +x "$dest" 2>/dev/null || true
        return 0
    fi
    return 1
}

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
}

# ── Базовые зависимости минимальных систем ────────────────────
# Минимальный Alma идёт без tar, голый Debian — без curl: установщик
# падал «Необходимая команда не найдена: tar». Ставим сами.
ensure_base_deps() {
    local missing=() pm
    command -v curl >/dev/null 2>&1 || missing+=(curl)
    command -v tar  >/dev/null 2>&1 || missing+=(tar)
    [ ${#missing[@]} -eq 0 ] && return 0

    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq >/dev/null 2>&1 || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" ca-certificates >/dev/null 2>&1 || true
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y -q --setopt=timeout=15 --setopt=retries=1 $DNF_ELREPO_OPT "${missing[@]}" ca-certificates >/dev/null 2>&1 || true
    elif command -v yum >/dev/null 2>&1; then
        yum install -y -q "${missing[@]}" ca-certificates >/dev/null 2>&1 || true
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache "${missing[@]}" ca-certificates >/dev/null 2>&1 || true
    fi

    for pm in "${missing[@]}"; do
        if ! command -v "$pm" >/dev/null 2>&1; then
            log_error "Не удалось установить $pm — установите вручную и повторите"
            return 1
        fi
    done
    return 0
}

trim() {
    local var="$1"
    var="${var#"${var%%[![:space:]]*}"}"
    var="${var%"${var##*[![:space:]]}"}"
    printf '%s' "$var"
}

# ── Файл для сохранения пути к конфигу ──────────────────────
CONFIG_PATH_FILE="/opt/mtpr-simple/config_path"

get_config_path() {
    if [ -f "$CONFIG_PATH_FILE" ] && [ -s "$CONFIG_PATH_FILE" ]; then
        local path
        path=$(cat "$CONFIG_PATH_FILE")
        if [ "$path" != "skip" ]; then
            echo "$path"
            return 0
        fi
    fi
    echo "/etc/telemt/telemt.toml"
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
        local _saved_path
        _saved_path=$(cat "$CONFIG_PATH_FILE")
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

get_public_ip() {
    local _ip=""
    _ip=$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null) ||
    _ip=$(curl -4 -fsS --max-time 5 https://ifconfig.me 2>/dev/null) ||
    _ip=$(curl -4 -fsS --max-time 5 https://icanhazip.com 2>/dev/null) ||
    _ip=""
    echo "$_ip"
}

generate_proxy_links() {
    local config_path
    config_path=$(get_config_path)
    if [ ! -f "$config_path" ]; then
        return 1
    fi
    
    # Получаем данные из конфига через расширенное обнаружение
    local detected_info
    detected_info=$(detect_telemt_advanced)
    local parts=()
    IFS=':' read -r -a parts <<< "$detected_info"
    
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
    
    # TLS режим (ee + secret + hex(домен)). При нескольких FakeTLS-доменах
    # (tls_domain + tls_domains) печатаем отдельную ссылку на каждый домен.
    if [ "$tls_enabled" = true ]; then
        local _domains_cfg="$config_path"
        if [ -n "$detected_path" ]; then
            _domains_cfg="$detected_path"
        fi
        local tls_domains=""
        tls_domains=$(get_tls_domains "$_domains_cfg")
        local domain_count=0
        if [ -n "$tls_domains" ]; then
            domain_count=$(printf '%s\n' "$tls_domains" | grep -c .)
        fi
        local _tls_links="" _tls_ok=true
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
                    _tls_links="${_tls_links}  TLS:\n"
                else
                    _tls_links="${_tls_links}  TLS (${_d}):\n"
                fi
                _tls_links="${_tls_links}  tg://proxy?server=${server}&port=${port}&secret=ee${detected_secret}${hex_domain}\n"
            done <<< "$tls_domains"
        fi
        if [ "$domain_count" -eq 0 ] || [ "$_tls_ok" = false ]; then
            # Домен не задан или hex не собрался — одна ссылка без hex
            links="${links}  TLS:\n"
            links="${links}  tg://proxy?server=${server}&port=${port}&secret=ee${detected_secret}\n"
        else
            links="${links}${_tls_links}"
        fi
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
    local config_path
    config_path=$(get_config_path)
    
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
    local config_path
    config_path=$(get_config_path)
    
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
        log_info "Добавлен пользователь: $user_name"
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
    local config_path
    config_path=$(get_config_path)
    
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
    local config_path
    config_path=$(get_config_path)
    
    # Скачиваем шаблон webconfig.txt во временный файл (непредсказуемое имя)
    local web_template
    web_template=$(mktemp /tmp/webconfig.XXXXXX.txt 2>/dev/null) || web_template=""
    if [ -z "$web_template" ]; then
        log_error "Не удалось создать временный файл для шаблона WEB-конфига"
        return 1
    fi
    log_info "Скачивание шаблона WEB-конфига..."
    if ! curl -fsSL "$BASE_URL/data/webconfig.txt" -o "$web_template"; then
        log_error "Не удалось скачать шаблон webconfig.txt"
        rm -f "$web_template"
        return 1
    fi
    
    # Проверяем обязательные параметры
    if [ -z "$web_host" ]; then
        log_error "WEB-хост (домен) обязателен. Укажите -web-host"
        rm -f "$web_template"
        return 1
    fi
    
    if [ -z "$web_ip" ]; then
        web_ip=$(get_public_ip)
        if [ -z "$web_ip" ]; then
            log_error "Не удалось определить внешний IP"
            rm -f "$web_template"
            return 1
        fi
        log_info "Внешний IP определён: $web_ip"
    fi
    
    # Генерируем секрет, если не передан
    if [ -z "$web_secret" ]; then
        web_secret=$(generate_secret)
    fi
    
    # Если пользователь не указан, используем "webuser"
    if [ -z "$web_user" ]; then
        web_user="webuser"
        log_info "Имя пользователя не указано, используем: $web_user"
    fi
    
    # Читаем шаблон и подставляем значения ПО КЛЮЧАМ (не по литералам:
    # правки data/webconfig.txt не должны ломать подстановку)
    local web_config_content esc_host esc_ip esc_secret
    esc_host=$(printf '%s' "$web_host" | sed 's/[&#\\]/\\&/g')
    esc_ip=$(printf '%s' "$web_ip" | sed 's/[&#\\]/\\&/g')
    esc_secret=$(printf '%s' "$web_secret" | sed 's/[&#\\]/\\&/g')
    web_config_content=$(sed -E \
        -e "s#^([[:space:]]*tls_domain[[:space:]]*=[[:space:]]*)\"[^\"]*\"#\1\"$esc_host\"#" \
        -e "s#^([[:space:]]*host[[:space:]]*=[[:space:]]*)\"[^\"]*\"#\1\"$esc_host\"#" \
        -e "s#^([[:space:]]*public_addr[[:space:]]*=[[:space:]]*)\"[^\"]*\"#\1\"$esc_ip:443\"#" \
        -e "s#^([[:space:]]*hello[[:space:]]*=[[:space:]]*)\"[^\"]*\"#\1\"$esc_secret\"#" \
        "$web_template")

    # Проверяем, что подстановка реально произошла (иначе тихий no-op)
    if ! grep -qF -- "$web_host" <<< "$web_config_content" \
       || ! grep -qF -- "$web_ip:443" <<< "$web_config_content" \
       || ! grep -qF -- "$web_secret" <<< "$web_config_content" \
       || grep -qF -- 'CHANGE_ME_32HEX' <<< "$web_config_content"; then
        log_error "Не удалось подставить значения в WEB-конфиг (проверьте ключи tls_domain/host/public_addr/access.users в data/webconfig.txt)"
        rm -f "$web_template"
        return 1
    fi
    
    # Заменяем имя пользователя в access.users (если отличается от "hello")
    if [ "$web_user" != "hello" ]; then
        web_config_content="${web_config_content//hello = /$web_user = }"
        web_config_content="${web_config_content//show = \[\"hello\"\]/show = [\"$web_user\"]}"
        # Меняем в профиле
        web_config_content="${web_config_content//user = \"hello\"/user = \"$web_user\"}"
    fi

    if ! grep -qF -- "show = [\"$web_user\"]" <<< "$web_config_content"; then
        log_error "WEB-конфиг: не удалось ограничить [general.links].show на пользователя $web_user"
        rm -f "$web_template"
        return 1
    fi
    
    # Сохраняем полученный конфиг
    echo "$web_config_content" > "$config_path"
    log_success "WEB-конфиг сохранён в $config_path"
    
    rm -f "$web_template"
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
    elif command -v dnf &>/dev/null; then
        # В EL (Alma/Rocky/CentOS) nginx есть в базовых репозиториях,
        # certbot — только в EPEL.
        dnf install -y -q --setopt=timeout=15 --setopt=retries=1 $DNF_ELREPO_OPT nginx
        if ! command -v certbot &>/dev/null; then
            grep -qi '^ID=fedora' /etc/os-release 2>/dev/null || dnf install -y -q --setopt=timeout=15 --setopt=retries=1 $DNF_ELREPO_OPT epel-release >/dev/null 2>&1 || true
            dnf install -y -q --setopt=timeout=15 --setopt=retries=1 $DNF_ELREPO_OPT certbot python3-certbot-nginx
            dnf install -y -q --setopt=timeout=15 --setopt=retries=1 $DNF_ELREPO_OPT python3-pyparsing >/dev/null 2>&1 || true
        fi
    elif command -v yum &>/dev/null; then
        yum install -y -q nginx
        if ! command -v certbot &>/dev/null; then
            yum install -y -q epel-release >/dev/null 2>&1 || true
            yum install -y -q certbot python3-certbot-nginx
        fi
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
    local nginx_config
    if [ -d /etc/nginx/sites-available ]; then
        nginx_config="/etc/nginx/sites-available/default"
    else
        nginx_config="/etc/nginx/conf.d/telemt-web.conf"
    fi
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
    
    # firewalld (EL) и SELinux: без этого nginx не откроет 443 и не сможет
    # проксировать на 127.0.0.1:18080.
    if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --permanent --add-service=http >/dev/null 2>&1 || true
        firewall-cmd --permanent --add-service=https >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi
    if command -v getenforce &>/dev/null && [ "$(getenforce 2>/dev/null)" != "Disabled" ]; then
        setsebool -P httpd_can_network_connect 1 >/dev/null 2>&1 || true
    fi

    # Проверяем и перезагружаем Nginx
    if nginx -t 2>/dev/null; then
        systemctl enable nginx >/dev/null 2>&1 || true
        systemctl restart nginx
        log_success "Nginx перезагружен с новым конфигом"
    else
        log_error "Конфигурация Nginx невалидна"
        return 1
    fi
    
    log_success "Nginx настроен для $web_host"
}

# ── СТАРОЕ МЕНЮ (ПРОКСИ) ──────────────────────────────────────
show_proxy_menu() {
    if [ -t 1 ]; then clear 2>/dev/null || printf '\033[2J\033[H'; fi
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

    if ! { read -r choice </dev/tty; } 2>/dev/null; then
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
        if [ -t 1 ]; then clear 2>/dev/null || printf '\033[2J\033[H'; fi
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
        echo -e "       ${DIM}Установка Telegram MTProto прокси менеджера MTProxyL${NC}"
        echo -e "       ${DIM}на базе движка telemt (Docker)${NC}"
        echo -e "       ${DIM}Аналог MEKO"
        echo ""
        echo -e "  ${RED}${BOLD}[0]${NC}  ${RED}${BOLD}Выход${NC}"
        echo ""
        echo -en "  ${NC}${BOLD}Ввод (${GREEN}${BOLD}Enter${NC}${BOLD} - установка proxy):${NC} "

        if ! { read -r choice </dev/tty; } 2>/dev/null; then
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
                { read -r </dev/tty; } 2>/dev/null || true
                ;;
            3)
                echo ""
                log_info "Запуск установки mtproxyl..."
                echo ""
                local mtproxyl_tmp
                mtproxyl_tmp=$(mktemp /tmp/mtproxyl.XXXXXX.sh 2>/dev/null) || mtproxyl_tmp=""
                if [ -z "$mtproxyl_tmp" ]; then
                    log_error "Не удалось создать временный файл для установщика mtproxyl"
                elif curl -fsSL "https://raw.githubusercontent.com/Liafanx/MTProxyL/main/install.sh" -o "$mtproxyl_tmp" && [ -s "$mtproxyl_tmp" ]; then
                    if bash "$mtproxyl_tmp"; then
                        log_success "Установка mtproxyl завершена"
                    else
                        log_error "Установщик mtproxyl завершился с ошибкой"
                    fi
                else
                    log_error "Не удалось скачать установщик mtproxyl"
                fi
                [ -n "$mtproxyl_tmp" ] && rm -f "$mtproxyl_tmp" || true
                echo ""
                echo -e "  ${GRAY}Нажмите Enter для возврата в главное меню...${NC}"
                { read -r </dev/tty; } 2>/dev/null || true
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

# Опция без значения: под set -e `shift 2` падает с «shift count out of range»
# и человек видит ошибку bash вместо причины. Проверяем заранее.
_need_arg() {
    local opt="$1" val="${2:-}"
    if [ -z "$val" ] || [[ "$val" == -* ]]; then
        echo -e "  ${RED}[✗]${NC} ${opt}: не указано значение"
        echo -e "  ${DIM}Справка по опциям: -h${NC}"
        exit 1
    fi
}

# Домен или IPv4: остальное ломает конфиг Telemt и ссылки для клиентов.
_is_host() {
    [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] ||
        [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

_invalid_arg() {
    echo -e "  ${RED}[✗]${NC} ${1}: недопустимое значение '${2}'"
    echo -e "  ${DIM}${3}${NC}"
    exit 1
}

ensure_base_deps || exit 1

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
            _need_arg "-web-user" "${2:-}"
            [[ "$2" =~ ^[A-Za-z0-9_.-]{1,32}$ ]] ||
                _invalid_arg "-web-user" "$2" "Имя WEB-пользователя: латиница, цифры, точка, тире, подчёркивание."
            WEB_USER="$2"
            shift 2
            ;;
        -web-secret)
            _need_arg "-web-secret" "${2:-}"
            if [[ "$2" =~ [[:space:]\"\\] ]]; then
                _invalid_arg "-web-secret" "$2" "Секрет не должен содержать пробелов, кавычек и обратных слешей."
            fi
            WEB_SECRET="$2"
            shift 2
            ;;
        -web-host)
            _need_arg "-web-host" "${2:-}"
            _is_host "$2" || _invalid_arg "-web-host" "$2" "Нужен домен вида example.com."
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
            _need_arg "-domain" "${2:-}"
            _is_host "$2" || _invalid_arg "-domain" "$2" "Нужен домен вида example.com — без схемы, слешей и пробелов."
            DOMAIN="$2"
            shift 2
            ;;
        -version)
            _need_arg "-version" "${2:-}"
            [[ "$2" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || "$2" == "latest" ]] ||
                _invalid_arg "-version" "$2" "Ожидается версия вида 3.5.6 или latest."
            TELEMT_VERSION="$2"
            shift 2
            ;;
        -ad_tag)
            _need_arg "-ad_tag" "${2:-}"
            [[ "$2" =~ ^[0-9a-fA-F]{32}$ ]] ||
                _invalid_arg "-ad_tag" "$2" "ad_tag — 32 hex-символа (16 байт), как в README."
            AD_TAG="$2"
            shift 2
            ;;
        -user)
            _need_arg "-user" "${2:-}"
            [[ "$2" =~ ^[A-Za-z0-9_.-]{1,32}$ ]] ||
                _invalid_arg "-user" "$2" "Имя пользователя: латиница, цифры, точка, тире, подчёркивание (до 32 символов)."
            USER_NAME="$2"
            if [[ -n "${3:-}" && ! "$3" =~ ^- ]]; then
                [[ "$3" =~ ^[0-9a-fA-F]+$ ]] ||
                    _invalid_arg "-user" "$3" "Секрет — hex-строка. Не указывать вовсе — сгенерируется автоматически."
                USER_SECRET="$3"
                shift 3
            else
                USER_SECRET=""
                shift 2
            fi
            ;;
        -public_host)
            _need_arg "-public_host" "${2:-}"
            _is_host "$2" || _invalid_arg "-public_host" "$2" "Нужен домен или IPv4, который видят клиенты."
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
            echo -e "    -mtg                   установить MTG 2.x (последняя ветка)"
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
    if [[ -n "$FLAG_TELEMT" || -n "$FLAG_ZIG" || -n "$FLAG_MTG" ]]; then
        if [ -z "$DOMAIN" ]; then
            # При обновлении домен берём из текущего конфига: иначе повторная
            # установка молча переписывала tls_domain на ozon.ru.
            default_sni_domain="ozon.ru" _cur_cfg="" _cur_dom=""
            _cur_info=$(detect_telemt_advanced 2>/dev/null) || _cur_info=""
            _cur_cfg=${_cur_info%%:*}
            if [ -n "$_cur_cfg" ] && [ -f "$_cur_cfg" ]; then
                _cur_dom=$(grep -E '^tls_domain[[:space:]]*=' "$_cur_cfg" 2>/dev/null | head -1 | awk -F'=' '{print $2}' | sed 's/#.*//' | tr -d ' "')
                if [[ "$_cur_dom" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then
                    default_sni_domain="$_cur_dom"
                fi
            fi
            while true; do
                echo -en "  ${BOLD}Введите SNI домен${NC} ${DIM}(по умолчанию: ${default_sni_domain})${NC}: " >&2
                if { : </dev/tty; } 2>/dev/null; then
                    read -r DOMAIN </dev/tty || true
                else
                    DOMAIN=""
                fi
                DOMAIN=$(trim "$DOMAIN")
                [ -z "$DOMAIN" ] && DOMAIN="$default_sni_domain"
                if [[ "$DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then
                    break
                fi
                echo -e "  ${RED}[✗]${NC} Неверный домен: ${DOMAIN}. Допустимы буквы, цифры, точка и дефис." >&2
                DOMAIN=""
            done
        fi
        if [ -z "$PROXY_PORT" ]; then
            # При обновлении порт берём из текущего конфига: иначе на сервере
            # с WEB (nginx на 443) переустановка падала на «Порт уже занят».
            default_proxy_port="" _cur_info="" _cur_port=""
            _cur_info=$(detect_telemt_advanced 2>/dev/null) || _cur_info=""
            _cur_port=$(printf '%s\n' "$_cur_info" | cut -d: -f2)
            if ! [[ "$_cur_port" =~ ^[0-9]+$ ]] && [ -s /opt/mtpr-simple/port ]; then
                _cur_port=$(head -1 /opt/mtpr-simple/port 2>/dev/null | tr -d '[:space:]')
            fi
            if [[ "$_cur_port" =~ ^[0-9]+$ ]] && [ "$_cur_port" -ge 1 ] && [ "$_cur_port" -le 65535 ]; then
                default_proxy_port="$_cur_port"
            else
                default_proxy_port="443"
            fi
            while true; do
                echo -en "  ${BOLD}Введите порт для прокси${NC} ${DIM}(по умолчанию: ${default_proxy_port})${NC}: " >&2
                if { : </dev/tty; } 2>/dev/null; then
                    read -r PROXY_PORT </dev/tty || true
                else
                    PROXY_PORT=""
                fi
                [ -z "$PROXY_PORT" ] && PROXY_PORT="$default_proxy_port"
                if [[ "$PROXY_PORT" =~ ^[0-9]+$ ]] && [ "$PROXY_PORT" -ge 1 ] && [ "$PROXY_PORT" -le 65535 ]; then
                    break
                fi
                echo -e "  ${RED}[✗]${NC} Неверный порт: ${PROXY_PORT} (нужно 1-65535)." >&2
                PROXY_PORT=""
            done
        fi
        # Версия Telemt
        if [[ -n "$FLAG_TELEMT" && -z "$TELEMT_VERSION" ]]; then
            echo -en "  ${BOLD}Введите версию Telemt${DIM} (Enter - последняя версия)${NC}: " >&2
            if { : </dev/tty; } 2>/dev/null; then
                read -r TELEMT_VERSION </dev/tty || true
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
            if { : </dev/tty; } 2>/dev/null; then
                read -r WEB_HOST </dev/tty || true
            else
                WEB_HOST=""
            fi
            if [ -z "$WEB_HOST" ]; then
                log_error "Домен для WEB-режима обязателен. Укажите -web-host или введите сейчас."
                exit 1
            fi
        fi
        # Домен попадает в URL и конфиг nginx — не принимаем мусор
        if ! [[ "$WEB_HOST" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then
            log_error "Неверный домен WEB-хоста: $WEB_HOST"
            exit 1
        fi
        
        # WEB-пользователь
        if [ -z "$WEB_USER" ]; then
            echo -en "  ${BOLD}Введите имя пользователя для WEB${NC} ${DIM}(по умолчанию: webuser)${NC}: "
            if { : </dev/tty; } 2>/dev/null; then
                read -r WEB_USER </dev/tty || true
            else
                WEB_USER=""
            fi
            [ -z "$WEB_USER" ] && WEB_USER="webuser"
        fi
        
        # WEB-секрет
        if [ -z "$WEB_SECRET" ]; then
            echo -en "  ${BOLD}Введите секрет для WEB${NC} ${DIM}(Enter - сгенерировать автоматически)${NC}: "
            if { : </dev/tty; } 2>/dev/null; then
                read -r WEB_SECRET </dev/tty || true
            else
                WEB_SECRET=""
            fi
            if [ -z "$WEB_SECRET" ]; then
                WEB_SECRET=$(generate_secret)
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
                while true; do
                    echo -en "  ${BOLD}Введите порт для фикса${NC} ${DIM}(по умолчанию: 443)${NC}: " >&2
                    if { : </dev/tty; } 2>/dev/null; then
                        read -r FIX_PORT </dev/tty || true
                    else
                        FIX_PORT=""
                    fi
                    [ -z "$FIX_PORT" ] && FIX_PORT="443"
                    if [[ "$FIX_PORT" =~ ^[0-9]+$ ]] && [ "$FIX_PORT" -ge 1 ] && [ "$FIX_PORT" -le 65535 ]; then
                        break
                    fi
                    echo -e "  ${RED}[✗]${NC} Неверный порт: ${FIX_PORT} (нужно 1-65535)." >&2
                    FIX_PORT=""
                done
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
                if { : </dev/tty; } 2>/dev/null; then
                    read -r answer </dev/tty || true
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
    if ! curl -fsSL "$BASE_URL/data/rules.sh" -o "$INSTALL_DIR/data/rules.sh"; then
        log_error "Не удалось загрузить data/rules.sh"
        exit 1
    fi
    chmod +x "$INSTALL_DIR/data/rules.sh" || true

    # Если тип фикса v4, скачиваем zapret2_fix.sh
    if [[ "$FIX_TYPE" == "v4" ]]; then
        log_info "Загрузка свежего zapret2_fix.sh..."
        if ! curl -fsSL "$BASE_URL/data/zapret2_fix.sh" -o "$INSTALL_DIR/data/zapret2_fix.sh"; then
            log_error "Не удалось загрузить data/zapret2_fix.sh"
            exit 1
        fi
        chmod +x "$INSTALL_DIR/data/zapret2_fix.sh" || true
    fi

    # Подключаем rules.sh
    if [ ! -f "$INSTALL_DIR/data/rules.sh" ]; then
        log_error "data/rules.sh не найден"
        exit 1
    fi
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
        if fetch_and_run sh "https://raw.githubusercontent.com/telemt/telemt/main/install.sh" "$TELEMT_VERSION" -l 2 -d "$DOMAIN" -p "$PROXY_PORT"; then
            log_success "Telemt установлен"
        else
            log_error "Не удалось установить Telemt"
            exit 1
        fi
        
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
                    if { : </dev/tty; } 2>/dev/null; then
                        read -r input_secret </dev/tty || true
                    else
                        input_secret=""
                    fi
                    if [ -z "$input_secret" ]; then
                        USER_SECRET=$(generate_secret)
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
        links=$(generate_proxy_links) || links=""
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
            web_path=""
            if [ -n "$config_path" ] && [ -f "$config_path" ]; then
                web_path=$(awk '
                    /^[[:space:]]*\[\[web\.vhosts\]\][[:space:]]*$/ { inv=1; next }
                    inv && /^[[:space:]]*\[/ { exit }
                    inv && /^[[:space:]]*base_path[[:space:]]*=/ { sub(/#.*/,""); sub(/^[^=]*=/,""); gsub(/[[:space:]"]/,""); print; exit }
                ' "$config_path" 2>/dev/null)
            fi
            if [ -n "$web_path" ]; then
                web_ver=$(telemt --version 2>/dev/null | head -1 | awk '{print $2}')
                if ! _ver_ge "$web_ver" "$WEB_PATH_MIN_VERSION"; then
                    log_warning "Путь WEB '/${web_path}' требует telemt ${WEB_PATH_MIN_VERSION}+ (установлен ${web_ver:-?}) — ссылка без пути"
                    web_path=""
                fi
            fi
            if [ "$secret_mode" = "dd" ]; then
                echo -e "  $(_web_make_link "$WEB_HOST" "$web_path" "$WEB_SECRET" 1)" >&2
            else
                echo -e "  $(_web_make_link "$WEB_HOST" "$web_path" "$WEB_SECRET" 0)" >&2
            fi
            echo "" >&2
        fi
        echo "" >&2
    fi

    # Zig
    if [[ -n "$FLAG_ZIG" ]]; then
        echo "" >&2
        log_info "Установка Mtproto.zig на домен $DOMAIN, порт $PROXY_PORT..."
        if ! fetch_and_run sudo-bash "https://raw.githubusercontent.com/sleep3r/mtproto.zig/main/deploy/bootstrap.sh"; then
            log_error "Не удалось установить Mtproto.zig"
            exit 1
        fi
        sudo mtbuddy install --port "$PROXY_PORT" --domain "$DOMAIN" --middle-proxy --no-tcpmss --no-masking --no-nfqws --no-dpi --yes
        log_success "Mtproto.zig установлен"
    fi

    # MTG ставим 2.x: ветку 1.0.x выбирают в интерактивном меню прокси
    if [[ -n "$FLAG_MTG" ]]; then
        log_info "Установка MTG (2.x) на порт $PROXY_PORT..."
        if ensure_file "proxys/mtgv2_1.sh" &&
           bash "$INSTALL_DIR/proxys/mtgv2_1.sh" --install-silent v2 "$PROXY_PORT" "$DOMAIN" >&2 &&
           systemctl is-active --quiet mtg.service; then
            log_success "MTG установлен"
        else
            log_error "Не удалось установить MTG"
            exit 1
        fi
    fi

    # ── 4. Установка фикса ──────────────────────────────────

    if [[ -n "$FLAG_FIX" && -z "$FLAG_NO_FIX" ]]; then
        echo "" >&2
        log_info "Установка фикса типа $FIX_TYPE на порт $FIX_PORT..."

        # Вызываем install_syn_fix с переданными параметрами
        install_syn_fix -auto_install -port "$FIX_PORT" -type "$FIX_TYPE"

        log_success "Фикс установлен"
    fi

    # ── 5. Установка менеджера (лаунчер mekopr/meko + меню) ──
    # Ставим ПОСЛЕ telemt и фикса, но БЕЗ запуска меню: flag-режим часто
    # вызывают в &&-цепочке, и ожидание ввода на /dev/tty заблокировало бы её.
    echo "" >&2
    log_info "Установка менеджера MEKO (лаунчер mekopr/meko + меню)..."
    if ! ensure_file "install_main.sh"; then
        log_error "Не удалось загрузить install_main.sh — менеджер MEKO не установлен"
        exit 1
    fi
    if ! MEKOPR_NO_MENU=1 bash "$INSTALL_DIR/install_main.sh"; then
        log_error "Не удалось установить менеджер MEKO"
        exit 1
    fi
    log_success "Менеджер MEKO установлен (запуск: sudo mekopr)"

    echo "" >&2
    log_success "Автоматическая установка завершена!"
    echo "" >&2
    exit 0
fi

# ── ЕСЛИ АРГУМЕНТОВ НЕТ — ПОКАЗЫВАЕМ ИНТЕРАКТИВНОЕ МЕНЮ ──────
show_main_menu
