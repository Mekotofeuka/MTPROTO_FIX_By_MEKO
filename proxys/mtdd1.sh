#!/bin/bash
# mtdd1.sh — меню mtdd (MTProto/FakeTLS, движок ugDeDe/mtdd).
#
# Управление идёт через штатный /usr/local/bin/mtdd-ctl: он уже умеет статус,
# пользователей, ссылки, метрики и подозрительные адреса, поэтому своего JSON-
# клиента здесь нет. Своими руками — только установка, обновление и удаление.

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

INSTALL_URL="https://raw.githubusercontent.com/ugDeDe/mtdd/main/install.sh"
MTDD_CTL="/usr/local/bin/mtdd-ctl"
MTDD_BIN="/usr/local/bin/mtdd"
MTDD_CONFIG="/etc/mtdd/config.json"
MTDD_ENV="/etc/mtdd/credentials.env"

pause_key() {
    echo ""
    echo -e "  ${GRAY}Нажмите любую клавишу для продолжения...${NC}"
    { read -rsn1 </dev/tty; } 2>/dev/null || true
}

# Скачать установщик во временный файл и выполнить. Без `curl | bash`, чтобы
# при обрыве сети не выполнить половину скрипта.
fetch_and_run() {
    local mode="$1" url="$2"
    shift 2
    local tmp rc=1
    tmp=$(mktemp) || return 1
    if curl -fsSL --max-time 90 "$url" -o "$tmp" && [ -s "$tmp" ]; then
        case "$mode" in
            bash) bash "$tmp" "$@" ;;
            sudo-bash) sudo bash "$tmp" "$@" ;;
        esac
        rc=$?
    fi
    rm -f "$tmp" 2>/dev/null || true
    return "$rc"
}

is_mtdd_installed() {
    [ -x "$MTDD_BIN" ]
}

get_mtdd_version() {
    if is_mtdd_installed; then
        "$MTDD_BIN" --version 2>/dev/null | head -1 | awk '{print $2}'
    fi
}

get_mtdd_port() {
    local _port=""
    if [ -f "$MTDD_CONFIG" ]; then
        _port=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("proxy_port",""))' \
            "$MTDD_CONFIG" 2>/dev/null)
        [ -n "$_port" ] || _port=$(grep -oE '"proxy_port"[[:space:]]*:[[:space:]]*[0-9]+' "$MTDD_CONFIG" \
            2>/dev/null | head -1 | grep -oE '[0-9]+')
    fi
    case "$_port" in
        '' | *[!0-9]*) echo "" ;;
        *) echo "$_port" ;;
    esac
}

get_mtdd_domain() {
    local _dom=""
    if [ -f "$MTDD_CONFIG" ]; then
        _dom=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("tls_domain",""))' \
            "$MTDD_CONFIG" 2>/dev/null)
        [ -n "$_dom" ] || _dom=$(grep -oE '"tls_domain"[[:space:]]*:[[:space:]]*"[^"]*"' "$MTDD_CONFIG" \
            2>/dev/null | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
    fi
    printf '%s\n' "$_dom"
}

# Метрики закрыты токеном из credentials.env; без токена вернём пусто.
_mtdd_metrics_token() {
    sed -n 's/^MTDD_METRICS_TOKEN=//p' "$MTDD_ENV" 2>/dev/null | head -1 | tr -d '"'
}

# Онлайн = уникальные IP, которые уже прошли авторизацию (mtdd_unique_ips_seen).
# Пустой вывод = счётчик недоступен, это не ноль.
get_mtdd_online() {
    is_mtdd_installed || return 1
    local _tok _val
    _tok=$(_mtdd_metrics_token)
    _val=$(curl -s --connect-timeout 1 --max-time 3 \
        -H "Authorization: Bearer $_tok" \
        "http://127.0.0.1:9091/metrics" 2>/dev/null |
        awk '$1 == "mtdd_unique_ips_seen" {print $2; exit}')
    case "$_val" in
        '' | *[!0-9.]*) return 1 ;;
    esac
    printf '%s\n' "${_val%%.*}"
}

mtdd_ctl() {
    if [ ! -x "$MTDD_CTL" ]; then
        echo ""
        echo -e "  ${RED}[✗]${NC} Не найден $MTDD_CTL — mtdd не установлен"
        return 1
    fi
    "$MTDD_CTL" "$@"
}

# ── Установка/обновление ────────────────────────────────────
install_mtdd() {
    echo ""
    if is_mtdd_installed; then
        echo -e "  ${BOLD}mtdd уже установлен:${NC} ${CYAN}$(get_mtdd_version)${NC}"
        echo -e "  ${DIM}Повторный запуск установщика обновит бинарник, пользователи и токен сохранятся.${NC}"
        echo -en "  ${BOLD}Обновить? [y/N]:${NC} "
        local _ans
        { read -r _ans </dev/tty; } 2>/dev/null || return 1
        [[ "$_ans" =~ ^[yY]$ ]] || return 1
    fi

    local _port _domain _user _publichost _adtag _def_port _def_domain
    _def_port=$(get_mtdd_port)
    [ -n "$_def_port" ] || _def_port=443
    _def_domain=$(get_mtdd_domain)
    [ -n "$_def_domain" ] || _def_domain="ozon.ru"

    echo -en "  ${BOLD}Порт прокси${NC} ${DIM}(по умолчанию: $_def_port)${NC}: "
    { read -r _in </dev/tty; } 2>/dev/null || _in=""
    _port=$(printf '%s' "$_in" | tr -d '[:space:]')
    [ -n "$_port" ] || _port="$_def_port"
    case "$_port" in
        *[!0-9]*)
            echo -e "  ${RED}[✗]${NC} Порт должен быть числом 1-65535"
            return 1
            ;;
    esac
    if [ "$_port" -lt 1 ] || [ "$_port" -gt 65535 ]; then
        echo -e "  ${RED}[✗]${NC} Порт должен быть числом 1-65535"
        return 1
    fi

    echo -en "  ${BOLD}Домен маскировки (SNI)${NC} ${DIM}(по умолчанию: $_def_domain)${NC}: "
    { read -r _domain </dev/tty; } 2>/dev/null || _domain=""
    _domain=$(printf '%s' "$_domain" | tr -d '[:space:]')
    [ -n "$_domain" ] || _domain="$_def_domain"

    echo -en "  ${BOLD}Первый пользователь${NC} ${DIM}(по умолчанию: admin)${NC}: "
    { read -r _user </dev/tty; } 2>/dev/null || _user=""
    _user=$(printf '%s' "$_user" | tr -d '[:space:]')
    [ -n "$_user" ] || _user="admin"

    echo -en "  ${BOLD}Публичный адрес для ссылок${NC} ${DIM}(IP или домен, Enter — автоопределение)${NC}: "
    { read -r _publichost </dev/tty; } 2>/dev/null || _publichost=""
    _publichost=$(printf '%s' "$_publichost" | tr -d '[:space:]')

    echo -en "  ${BOLD}Рекламный тег Telegram${NC} ${DIM}(32 hex, Enter — без тега)${NC}: "
    { read -r _adtag </dev/tty; } 2>/dev/null || _adtag=""
    _adtag=$(printf '%s' "$_adtag" | tr -d '[:space:]')

    local -a _args=(--domain "$_domain" --port "$_port" --user "$_user")
    [ -n "$_publichost" ] && _args+=(--public-host "$_publichost")
    [ -n "$_adtag" ] && _args+=(--ad-tag "$_adtag")

    echo ""
    echo -e "  ${BOLD}Запуск:${NC} install.sh --domain ${_domain} --port ${_port} --user ${_user}${_publichost:+ --public-host $_publichost}"
    echo ""
    if ! fetch_and_run bash "$INSTALL_URL" "${_args[@]}"; then
        echo ""
        echo -e "  ${RED}[✗]${NC} Установка mtdd завершилась ошибкой"
        return 1
    fi
    echo ""
    echo -e "  ${GREEN}[✓]${NC} mtdd установлен: ${CYAN}$(get_mtdd_version)${NC}"
    echo ""
    echo -e "  ${BOLD}Ссылки:${NC}"
    mtdd_ctl links 2>/dev/null | sed 's/^/  /'
    return 0
}

# Неинтерактивная установка для install.sh: --install-silent ПОРТ ДОМЕН [ЮЗЕР] [PUBLIC_HOST] [AD_TAG]
install_mtdd_silent() {
    local _port="${1:-443}" _domain="${2:-ozon.ru}" _user="${3:-admin}"
    local _publichost="${4:-}" _adtag="${5:-}"
    local -a _args=(--domain "$_domain" --port "$_port" --user "$_user")
    [ -n "$_publichost" ] && _args+=(--public-host "$_publichost")
    [ -n "$_adtag" ] && _args+=(--ad-tag "$_adtag")
    fetch_and_run bash "$INSTALL_URL" "${_args[@]}" >&2 || return 1
    is_mtdd_installed
}

purge_mtdd() {
    if [ ! -x "$MTDD_CTL" ]; then
        echo ""
        echo -e "  ${YELLOW}[!]${NC} mtdd не установлен"
        return 0
    fi
    echo ""
    echo -e "  ${RED}${BOLD}Удаление mtdd:${NC} служба, бинарник, конфиг, пользователи, ключи."
    echo -en "  ${BOLD}Продолжить? [y/N]:${NC} "
    local _ans
    { read -r _ans </dev/tty; } 2>/dev/null || return 1
    [[ "$_ans" =~ ^[yY]$ ]] || return 1
    "$MTDD_CTL" uninstall --yes || return 1
    echo -e "  ${GREEN}[✓]${NC} mtdd удалён"
}

edit_config() {
    if [ ! -f "$MTDD_CONFIG" ]; then
        echo ""
        echo -e "  ${RED}[✗]${NC} Конфиг не найден: $MTDD_CONFIG"
        return 1
    fi
    if command -v nano >/dev/null 2>&1; then
        nano "$MTDD_CONFIG"
    elif command -v vim >/dev/null 2>&1; then
        vim "$MTDD_CONFIG"
    elif command -v vi >/dev/null 2>&1; then
        vi "$MTDD_CONFIG"
    else
        echo -e "  ${RED}[✗]${NC} Нет nano/vim/vi — откройте $MTDD_CONFIG вручную"
        return 1
    fi
    echo ""
    echo -e "  ${DIM}Конфиг применён после: mtdd-ctl service restart${NC}"
}

users_menu() {
    while true; do
        clear 2>/dev/null || true
        echo ""
        echo -e "  ${BOLD}Пользователи mtdd${NC}"
        echo -e "  ${DIM}===========================${NC}"
        echo ""
        echo -e "  ${CYAN}[1]${NC}  Список пользователей"
        echo -e "  ${CYAN}[2]${NC}  Добавить пользователя"
        echo -e "  ${CYAN}[3]${NC}  Показать политики и статистику"
        echo -e "  ${CYAN}[4]${NC}  Сменить секрет (новая ссылка)"
        echo -e "  ${CYAN}[5]${NC}  Устройства пользователя"
        echo -e "  ${CYAN}[6]${NC}  Включить / отключить"
        echo -e "  ${CYAN}[7]${NC}  Удалить пользователя"
        echo -e "  ${CYAN}[8]${NC}  Журнал аудита"
        echo ""
        echo -e "  ${RED}[0]${NC}  Назад"
        echo ""
        echo -en "  ${BOLD}Ввод:${NC} "
        local _ch _name
        { read -r _ch </dev/tty; } 2>/dev/null || return 0
        case "$_ch" in
            1) mtdd_ctl users list ;;
            2)
                echo -en "  ${BOLD}Имя:${NC} "
                { read -r _name </dev/tty; } 2>/dev/null || _name=""
                [ -n "$_name" ] && mtdd_ctl users add "$_name"
                ;;
            3)
                echo -en "  ${BOLD}Имя:${NC} "
                { read -r _name </dev/tty; } 2>/dev/null || _name=""
                [ -n "$_name" ] && mtdd_ctl users show "$_name"
                ;;
            4)
                echo -en "  ${BOLD}Имя:${NC} "
                { read -r _name </dev/tty; } 2>/dev/null || _name=""
                [ -n "$_name" ] && mtdd_ctl users rotate "$_name"
                ;;
            5)
                echo -en "  ${BOLD}Имя:${NC} "
                { read -r _name </dev/tty; } 2>/dev/null || _name=""
                [ -n "$_name" ] && mtdd_ctl users devices "$_name"
                ;;
            6)
                echo -en "  ${BOLD}Имя и действие (например: vasya enable):${NC} "
                { read -r _name _act </dev/tty; } 2>/dev/null || _name=""
                if [ -n "$_name" ] && [ -n "$_act" ]; then
                    mtdd_ctl users "$_act" "$_name"
                fi
                ;;
            7)
                echo -en "  ${BOLD}Имя:${NC} "
                { read -r _name </dev/tty; } 2>/dev/null || _name=""
                [ -n "$_name" ] && mtdd_ctl users remove "$_name"
                ;;
            8) mtdd_ctl users audit ;;
            0) return 0 ;;
            *) echo "  Неверный выбор" ;;
        esac
        pause_key
    done
}

# ── Неинтерактивные режимы (из install.sh и main.sh) ────────
case "${1:-}" in
    --install-silent)
        shift
        install_mtdd_silent "$@"
        exit $?
        ;;
    --purge-silent)
        if [ -x "$MTDD_CTL" ]; then
            "$MTDD_CTL" uninstall --yes
        fi
        exit $?
        ;;
esac

# ── Интерактивное меню ──────────────────────────────────────
while true; do
    clear 2>/dev/null || true
    echo ""
    echo -e "  ${BOLD}mtdd меню v0.1${NC} ${DIM}(MTProto / FakeTLS)${NC}"
    echo -e "  ${DIM}===========================${NC}"
    echo ""

    if is_mtdd_installed; then
        local_port=$(get_mtdd_port)
        echo -e "  ${BOLD}Версия:${NC} ${CYAN}$(get_mtdd_version)${NC}${local_port:+   ${BOLD}Порт:${NC} ${CYAN}${local_port}${NC}}"
        if online=$(get_mtdd_online); then
            echo -e "  ${BOLD}Онлайн:${NC} ${CYAN}${online}${NC} ${BOLD}IP${NC}"
        else
            echo -e "  ${BOLD}Онлайн:${NC} ${GRAY}метрики недоступны${NC}"
        fi
    else
        echo -e "  ${GRAY}mtdd не установлен${NC}"
    fi
    echo ""
    echo -e "  ${CYAN}[1]${NC}  ${BOLD}Установить/обновить mtdd${NC}"
    echo -e "  ${CYAN}[2]${NC}  ${BOLD}Состояние${NC} ${DIM}(служба, API, пулы ME)${NC}"
    echo -e "  ${CYAN}[3]${NC}  ${BOLD}Ссылки подключения${NC}"
    echo -e "  ${CYAN}[4]${NC}  ${BOLD}Пользователи${NC}"
    echo -e "  ${CYAN}[5]${NC}  ${BOLD}Перезапустить${NC}"
    echo -e "  ${CYAN}[6]${NC}  ${BOLD}Логи${NC}"
    echo -e "  ${CYAN}[7]${NC}  ${BOLD}Открыть конфиг${NC}"
    echo -e "  ${CYAN}[8]${NC}  ${BOLD}Метрики${NC} ${DIM}(дашборд)${NC}"
    echo -e "  ${CYAN}[9]${NC}  ${BOLD}Подозрительные адреса${NC} ${DIM}(fraud score)${NC}"
    echo -e "  ${CYAN}[a]${NC}  ${BOLD}Полное меню mtdd-ctl${NC}"
    echo -e "  ${CYAN}[h]${NC}  ${BOLD}Сменить публичный адрес ссылок${NC}"
    echo ""
    echo -e "  ${RED}[d]${NC}  ${BOLD}Удалить mtdd${NC}"
    echo -e "  ${RED}[0]${NC}  ${BOLD}Назад в прокси меню${NC}"
    echo ""
    echo -en "  ${BOLD}Ввод:${NC} "
    choice=""
    { read -r choice </dev/tty; } 2>/dev/null || break

    case "$choice" in
        1) install_mtdd; pause_key ;;
        2) mtdd_ctl status; pause_key ;;
        3) mtdd_ctl links; pause_key ;;
        4) users_menu ;;
        5) mtdd_ctl service restart; pause_key ;;
        6)
            echo -en "  ${BOLD}Сколько строк (Enter — 50):${NC} "
            { read -r _n </dev/tty; } 2>/dev/null || _n=""
            mtdd_ctl logs "${_n:-50}"
            pause_key
            ;;
        7) edit_config; pause_key ;;
        8) mtdd_ctl metrics; pause_key ;;
        9) mtdd_ctl suspects; pause_key ;;
        a | A) mtdd_ctl menu ;;
        h | H)
            echo -en "  ${BOLD}Новый публичный адрес (IP или домен):${NC} "
            { read -r _h </dev/tty; } 2>/dev/null || _h=""
            [ -n "$_h" ] && mtdd_ctl host "$_h"
            pause_key
            ;;
        d | D) purge_mtdd; pause_key ;;
        0) break ;;
        *)
            echo "  Неверный выбор"
            sleep 0.1
            ;;
    esac
done
