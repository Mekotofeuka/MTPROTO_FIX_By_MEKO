#!/bin/bash
# data/services_menu.sh — Дополнительные сервисы MEKO Manager
#   [1] Cloudflare WARP  — установка БЕЗ автоподключения; подключение в двух режимах:
#                          proxy (SOCKS5, маршрут не меняется) и полный туннель
#                          (снимок маршрута/DNS + автооткат + отложенный сторож)
#   [2] AdGuard Home     — локальный DNS-сервер (занимает порт 53)
#
# Запуск: bash /opt/mtpr-simple/data/services_menu.sh
#         (вызывается из data/extra_menu.sh, пункт [4] «Дополнительные сервисы»)
set -euo pipefail

# ── Цвета ─────────────────────────────────────────────────────
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
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; GRAY=''
    BOLD=''; DIM=''; NC=''
fi

# ── Логирование ──────────────────────────────────────────────
log_info() { echo -e "  ${BLUE}[i]${NC} $1"; }
log_success() { echo -e "  ${GREEN}[✓]${NC} $1"; }
log_error() { echo -e "  ${RED}[✗]${NC} $1" >&2; }
log_warning() { echo -e "  ${YELLOW}[!]${NC} $1"; }

# ── Проверка root ────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
    log_error "Требуются права root"
    exit 1
fi

# ── Вспомогательные ──────────────────────────────────────────
_pause() {
    echo ""
    echo -e "  ${GRAY}Нажмите любую клавишу для продолжения...${NC}"
    { read -rsn1 </dev/tty; } 2>/dev/null || { echo; return 1; }
    IFS= read -r -t 0.05 _ </dev/tty 2>/dev/null || true
}

_confirm() {
    # _confirm "текст" → 0 если пользователь ответил y/Y
    local _prompt="$1" _ans=""
    echo -en "  ${BOLD}${_prompt} [y/N]:${NC} "
    { read -r _ans </dev/tty; } 2>/dev/null || { echo; return 1; }
    [[ "$_ans" =~ ^[yY]$ ]]
}

_confirm_word() {
    # _confirm_word "текст" СЛОВО → 0 если пользователь ввёл ровно СЛОВО
    # Защита от случайного нажатия y при действиях, способных оборвать SSH.
    local _prompt="$1" _word="$2" _ans=""
    echo -en "  ${BOLD}${_prompt} — введите слово ${RED}${_word}${NC}${BOLD} для подтверждения:${NC} "
    { read -r _ans </dev/tty; } 2>/dev/null || { echo; return 1; }
    [ "$_ans" = "$_word" ]
}

_svc_exists() {
    local _svc="$1" _out=""
    # Без пайпа на `grep -q`: под `set -euo pipefail` ранний выход grep даёт SIGPIPE (rc=141),
    # плюс наследуется rc самого systemctl — возможен ложный «не установлен».
    _out="$(systemctl list-unit-files --type=service 2>/dev/null || true)"
    printf '%s\n' "$_out" | awk -v s="${_svc}.service" '$1==s{f=1} END{exit !f}'
}

# ══════════════════════════════════════════════════════════════
#  CLOUDFLARE WARP
# ══════════════════════════════════════════════════════════════
# У Cloudflare WARP (warp-cli) два принципиально разных режима:
#
#   proxy   — WARP поднимает локальный SOCKS5 на 127.0.0.1:<порт>
#             (warp-cli mode proxy + warp-cli proxy port <port>).
#             Маршрутизация и DNS СЕРВЕРА НЕ МЕНЯЮТСЯ, SSH не рвётся.
#             Это рекомендуемый режим: он же штатный upstream для
#             MTProto-прокси (telemt: [[upstreams]] type="socks5").
#
#   warp    — полный туннель: WARP заменяет default route и DNS.
#             Именно так сервер один раз потерял сеть (SSH lost). Только
#             со снимком маршрута/DNS, автооткатом при потере связности
#             и отложенным сторожем (systemd-run --on-active), который
#             переживает обрыв SSH-сессии.
WARP_STATE_DIR="/var/lib/mtpr-warp-safety"
WARP_WATCHDOG_SCRIPT="/usr/local/sbin/mtpr-warp-watchdog.sh"
WARP_WATCHDOG_UNIT="mtpr-warp-watchdog"
WARP_PROXY_PORT="40000"
WARP_TUNNEL_DELAY="10min"
WARP_RESOLV_STUB="/run/systemd/resolve/stub-resolv.conf"

warp_installed() {
    command -v warp-cli >/dev/null 2>&1
}

_warp_connected() {
    # 0 = WARP подключён. Disconnected проверяем РАНЬШЕ Connected: в выводе
    # `warp-cli status` строка «Status update: Disconnected» содержит слово
    # Connected, и наивный матч *Connected* считал отключённый WARP подключённым.
    local _st=""
    _st="$(warp-cli --accept-tos status 2>/dev/null || true)"
    case "$_st" in
        *[Dd]isconnected*) return 1 ;;
        *[Cc]onnected*)    return 0 ;;
        *) return 1 ;;
    esac
}

_warp_mode() {
    local _s=""
    _s="$(warp-cli --accept-tos settings 2>/dev/null || true)"
    # В proxy-режиме строка — «(user set)  Mode: WarpProxy on port 40000»,
    # поэтому берём всё после «Mode: », а не последнее поле (был возврат «40000»).
    printf '%s\n' "$_s" | awk -F'Mode: ' '/Mode:/{print $2; exit}'
}

_warp_ssh_peer() {
    # IP текущего SSH-клиента (для исключения из туннеля).
    local _p="${SSH_CONNECTION:-}"
    _p="${_p%% *}"
    if [ -z "$_p" ]; then
        _p="${SSH_CLIENT:-}"
        _p="${_p%% *}"
    fi
    printf '%s' "$_p"
}

_warp_resolv_info() {
    local _t="" _s=""
    _t="$(readlink -f /etc/resolv.conf 2>/dev/null || true)"
    _s="$(sha256sum /etc/resolv.conf 2>/dev/null | awk '{print $1}')"
    printf '%s (sha256 %.12s)' "${_t:-/etc/resolv.conf}" "${_s:-unknown}"
}

# ── Снимок состояния (до любых изменений маршрута/DNS) ────────
_warp_snapshot_save() {
    local _d="$WARP_STATE_DIR"
    if ! mkdir -p "$_d"; then
        log_error "Не удалось создать $_d"
        return 1
    fi
    { ip route show default 2>/dev/null || true; } > "$_d/default-route.before"
    { ip -6 route show default 2>/dev/null || true; } > "$_d/default-route6.before"
    { cp -f /etc/resolv.conf "$_d/resolv.conf.before"; } 2>/dev/null || true
    { readlink -f /etc/resolv.conf; } > "$_d/resolv.conf.link" 2>/dev/null || true
    { warp-cli --accept-tos settings 2>&1 || true; } > "$_d/warp-settings.before" 2>/dev/null || true
    { ss -lntup 2>/dev/null || true; } > "$_d/listeners.before" 2>/dev/null || true
    date -Is > "$_d/snapshot.time" 2>/dev/null || true
    return 0
}

_warp_snapshot_show() {
    local _d="$WARP_STATE_DIR"
    if [ ! -d "$_d" ]; then
        echo -e "    ${DIM}Снимок состояния ещё не делался.${NC}"
        return 0
    fi
    echo -e "    ${CYAN}Снимок:${NC} ${_d}  ${DIM}($(cat "$_d/snapshot.time" 2>/dev/null || echo unknown))${NC}"
    echo -e "    ${CYAN}default route (в снимке):${NC}"
    sed 's/^/      /' "$_d/default-route.before" 2>/dev/null || true
    echo -e "    ${CYAN}resolv.conf (в снимке):${NC} $(sha256sum "$_d/resolv.conf.before" 2>/dev/null | awk '{print $1}')"
    return 0
}

# ── Восстановление маршрута и DNS из снимка ──────────────────
_warp_restore_route() {
    local _d="$WARP_STATE_DIR" _want="" _cur="" _link="" _line="" _touched=0
    _want="$(cat "$_d/default-route.before" 2>/dev/null || true)"
    _cur="$(ip route show default 2>/dev/null || true)"
    if [ -n "$_want" ] && [ "$_want" != "$_cur" ]; then
        ip route del default 2>/dev/null || true
        printf '%s\n' "$_want" | while IFS= read -r _line; do
            [ -n "$_line" ] || continue
            ip route add $_line 2>/dev/null || true
        done
        _touched=1
    fi
    _want="$(cat "$_d/default-route6.before" 2>/dev/null || true)"
    _cur="$(ip -6 route show default 2>/dev/null || true)"
    if [ -n "$_want" ] && [ "$_want" != "$_cur" ]; then
        ip -6 route del default 2>/dev/null || true
        printf '%s\n' "$_want" | while IFS= read -r _line; do
            [ -n "$_line" ] || continue
            ip -6 route add $_line 2>/dev/null || true
        done
        _touched=1
    fi
    # DNS: восстанавливаем ТОЛЬКО из снимка. Без снимка resolv.conf не трогаем
    # и systemd-resolved не дёргаем (иначе можно увести DNS на отсутствующий stub).
    if [ -s "$_d/resolv.conf.before" ]; then
        _link="$(cat "$_d/resolv.conf.link" 2>/dev/null || true)"
        if [ -n "$_link" ] && [ -e "$_link" ]; then
            ln -sf "$_link" /etc/resolv.conf 2>/dev/null || true
        else
            cp -f "$_d/resolv.conf.before" /etc/resolv.conf 2>/dev/null || true
        fi
        _touched=1
    fi
    if [ "$_touched" -eq 1 ]; then
        systemctl restart systemd-resolved >/dev/null 2>&1 || true
    fi
    return 0
}

# ── Сторож отложенного отключения (systemd-run, переживает SSH) ──
_warp_watchdog_write() {
    cat > "$WARP_WATCHDOG_SCRIPT" <<'EOS'
#!/bin/bash
# mtpr-warp-watchdog.sh — страховка MEKO для Cloudflare WARP в режиме полного
# туннеля. Запускается отдельным transient-юнитом (systemd-run --on-active),
# поэтому не зависит от SSH-сессии и породившего его скрипта меню: если SSH
# потерян, откат всё равно произойдёт.
set -u
STATE_DIR="/var/lib/mtpr-warp-safety"
STUB="/run/systemd/resolve/stub-resolv.conf"

log() { logger -t mtpr-warp-watchdog "$*"; }

st="$(warp-cli --accept-tos status 2>/dev/null || true)"
case "$st" in
    *[Dd]isconnected*) log "WARP уже отключён — сторож ничего не делает"; exit 0 ;;
    *[Cc]onnected*) : ;;
    *) log "WARP уже отключён — сторож ничего не делает"; exit 0 ;;
esac

net_ok=0
if timeout 8 ping -c1 -W3 1.1.1.1 >/dev/null 2>&1; then net_ok=1; fi
ssh_n="$(ss -Htn state established '( sport = :22 )' 2>/dev/null | awk 'END{print NR+0}')"

# Отложенное отключение: безусловное (страховочный таймер).
warp-cli --accept-tos disconnect >/dev/null 2>&1 || true
warp-cli --accept-tos mode warp >/dev/null 2>&1 || true

if [ -s "$STATE_DIR/default-route.before" ]; then
    want="$(cat "$STATE_DIR/default-route.before" 2>/dev/null || true)"
    cur="$(ip route show default 2>/dev/null || true)"
    if [ -n "$want" ] && [ "$want" != "$cur" ]; then
        ip route del default 2>/dev/null || true
        printf '%s\n' "$want" | while IFS= read -r l; do
            [ -n "$l" ] || continue
            ip route add $l 2>/dev/null || true
        done
    fi
fi
if [ -s "$STATE_DIR/resolv.conf.before" ]; then
    link="$(cat "$STATE_DIR/resolv.conf.link" 2>/dev/null || true)"
    if [ -n "$link" ] && [ -e "$link" ]; then
        ln -sf "$link" /etc/resolv.conf 2>/dev/null || true
    else
        cp -f "$STATE_DIR/resolv.conf.before" /etc/resolv.conf 2>/dev/null || true
    fi
elif [ -e "$STUB" ]; then
    ln -sf "$STUB" /etc/resolv.conf 2>/dev/null || true
fi
systemctl restart systemd-resolved >/dev/null 2>&1 || true

if [ "$net_ok" -eq 1 ]; then
    log "сторож: истёк таймер, связность была в норме → WARP отключён (net_ok=1 ssh=$ssh_n)"
else
    log "сторож: связность потеряна → WARP отключён, маршрут/DNS восстановлены (net_ok=0 ssh=$ssh_n)"
fi
exit 0
EOS
    chmod +x "$WARP_WATCHDOG_SCRIPT" 2>/dev/null || true
    return 0
}

_warp_watchdog_arm() {
    local _delay="${1:-$WARP_TUNNEL_DELAY}" _next=""
    _warp_watchdog_write
    _warp_watchdog_disarm
    if ! systemd-run --on-active="$_delay" --unit="$WARP_WATCHDOG_UNIT" --collect \
        --description="MEKO WARP watchdog (delayed disconnect + rollback)" \
        "$WARP_WATCHDOG_SCRIPT" >/dev/null 2>&1; then
        log_error "Не удалось взвести сторож WARP (systemd-run завершился ошибкой)"
        return 1
    fi
    # systemd-run мог вернуть 0, а таймер не подняться — проверяем факт взведения.
    if ! systemctl is-active --quiet "${WARP_WATCHDOG_UNIT}.timer"; then
        log_error "Сторож WARP создан, но таймер ${WARP_WATCHDOG_UNIT}.timer не активен"
        return 1
    fi
    _next="$(systemctl show -p NextElapseUSecMonotonic --value "${WARP_WATCHDOG_UNIT}.timer" 2>/dev/null || true)"
    case "$_next" in
        ""|0|infinity|n/a)
            log_error "У таймера сторожа нет времени срабатывания (NextElapseUSecMonotonic='${_next:-empty}')"
            return 1
            ;;
    esac
    return 0
}

_warp_watchdog_disarm() {
    systemctl stop "${WARP_WATCHDOG_UNIT}.timer" >/dev/null 2>&1 || true
    systemctl stop "${WARP_WATCHDOG_UNIT}.service" >/dev/null 2>&1 || true
    systemctl reset-failed "${WARP_WATCHDOG_UNIT}.timer" >/dev/null 2>&1 || true
    systemctl reset-failed "${WARP_WATCHDOG_UNIT}.service" >/dev/null 2>&1 || true
    return 0
}

_warp_watchdog_info() {
    local _t="" _s=""
    _t="$(systemctl is-active "${WARP_WATCHDOG_UNIT}.timer" 2>/dev/null || true)"
    _s="$(systemctl is-active "${WARP_WATCHDOG_UNIT}.service" 2>/dev/null || true)"
    printf 'timer=%s service=%s' "${_t:-none}" "${_s:-none}"
}

# ── Проверка связности и откат ───────────────────────────────
_warp_check_net() {
    if timeout 8 ping -c1 -W3 1.1.1.1 >/dev/null 2>&1; then return 0; fi
    if timeout 12 curl -fsS -o /dev/null --max-time 10 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null; then return 0; fi
    return 1
}

_warp_proxy_trace() {
    # $1 = порт; печатает значение warp= из cdn-cgi/trace, полученного ЧЕРЕЗ SOCKS5
    timeout 25 curl -fsS --max-time 20 --socks5-hostname "127.0.0.1:$1" \
        https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null \
        | awk -F= '$1=="warp"{print $2; exit}' || true
}

_warp_port_busy() {
    # $1 = порт; 0 = порт уже слушается локально
    ss -lnt 2>/dev/null | awk -v p=":$1" '$4 ~ p"$"{f=1} END{exit !f}'
}

_warp_rollback() {
    warp-cli --accept-tos disconnect >/dev/null 2>&1 || true
    warp-cli --accept-tos mode warp >/dev/null 2>&1 || true
    _warp_watchdog_disarm
    _warp_restore_route
    logger -t mtpr-warp "автооткат: WARP отключён, маршрут/DNS восстановлены" 2>/dev/null || true
    log_success "Откат выполнен: WARP отключён, маршрут/DNS восстановлены из снимка."
    return 0
}

warp_status() {
    echo ""
    if ! warp_installed; then
        log_warning "Cloudflare WARP не установлен"
        return 0
    fi
    local _v="" _act="" _en="" _pl=""
    _v="$(warp-cli --version 2>/dev/null || true)"
    _act="$(systemctl is-active warp-svc 2>/dev/null || true)"
    _en="$(systemctl is-enabled warp-svc 2>/dev/null || true)"
    echo -e "    ${CYAN}warp-cli:${NC} ${_v:-установлен}"
    echo -e "    ${CYAN}warp-svc:${NC} ${_act:-unknown} / автозапуск: ${_en:-unknown}"
    echo -e "    ${CYAN}Режим:${NC} $(_warp_mode)"
    echo -e "    ${CYAN}Статус подключения:${NC}"
    warp-cli --accept-tos status 2>&1 | sed 's/^/      /' || true
    _pl="$(ss -lnt 2>/dev/null | awk '$4 ~ /^127\.0\.0\.1:/{print $4}' | sort -u | tr '\n' ' ')"
    echo -e "    ${CYAN}SOCKS5 127.0.0.1:${NC} ${_pl:-нет}"
    echo -e "    ${CYAN}default route:${NC}"
    ip route show default 2>/dev/null | sed 's/^/      /' || true
    echo -e "    ${CYAN}resolv.conf:${NC} $(_warp_resolv_info)"
    echo -e "    ${CYAN}Сторож:${NC} $(_warp_watchdog_info)"
    if _warp_connected; then
        if _warp_check_net; then
            echo -e "    ${GREEN}Связность: OK${NC}"
        else
            echo -e "    ${RED}Связность: ПОТЕРЯНА — отключите WARP (пункт [4])${NC}"
        fi
    fi
    return 0
}

warp_install() {
    echo ""
    log_warning "Cloudflare WARP меняет исходящую маршрутизацию и DNS сервера"
    log_warning "(это МОЖЕТ нарушить работу MTProto/Telemt и оборвать SSH)."
    log_info "Устанавливается ТОЛЬКО пакет + регистрация, БЕЗ подключения."
    log_info "Подключать отдельно: пункт [3] — есть безопасный режим proxy (SOCKS5)."
    if ! _confirm_word "Установить WARP" WARP; then
        log_info "Отменено"
        return 0
    fi

    _warp_snapshot_save || log_warning "Не удалось сохранить снимок состояния маршрута/DNS"

    log_info "Устанавливаю зависимости..."
    if ! apt-get update -qq; then
        log_error "apt-get update завершился с ошибкой"
        return 1
    fi
    if ! apt-get install -y -qq curl gpg lsb-release apt-transport-https ca-certificates; then
        log_error "Не удалось установить зависимости"
        return 1
    fi

    log_info "Добавляю официальный репозиторий Cloudflare..."
    mkdir -p /usr/share/keyrings
    local _key_tmp
    _key_tmp="$(mktemp /tmp/cloudflare-warp.XXXXXX.gpg 2>/dev/null || true)"
    if [ -z "$_key_tmp" ]; then
        log_error "Не удалось создать временный файл для ключа"
        return 1
    fi
    if ! curl -fsSL "https://pkg.cloudflareclient.com/pubkey.gpg" -o "$_key_tmp"; then
        log_error "Не удалось скачать ключ репозитория Cloudflare"
        rm -f "$_key_tmp"
        return 1
    fi
    if [ ! -s "$_key_tmp" ]; then
        log_error "Скачанный ключ пуст"
        rm -f "$_key_tmp"
        return 1
    fi
    if ! gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg "$_key_tmp"; then
        log_error "Не удалось импортировать ключ (gpg)"
        rm -f "$_key_tmp"
        return 1
    fi
    rm -f "$_key_tmp"

    local _codename=""
    _codename="$(lsb_release -cs 2>/dev/null || true)"
    if [ -z "$_codename" ] && [ -r /etc/os-release ]; then
        _codename="$(. /etc/os-release 2>/dev/null; printf '%s' "${VERSION_CODENAME:-}")"
    fi
    if [ -z "$_codename" ]; then
        log_error "Не удалось определить кодовое имя дистрибутива (lsb_release)"
        return 1
    fi
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ ${_codename} main" \
        > /etc/apt/sources.list.d/cloudflare-client.list

    if ! apt-get update -qq; then
        log_error "apt-get update после добавления репозитория завершился ошибкой"
        return 1
    fi
    log_info "Устанавливаю cloudflare-warp..."
    if ! apt-get install -y -qq cloudflare-warp; then
        log_error "Не удалось установить cloudflare-warp"
        return 1
    fi

    if warp_installed; then
        log_info "Регистрирую клиент WARP (подключение НЕ выполняется)..."
        if ! warp-cli --accept-tos registration new </dev/tty; then
            log_warning "Авторегистрация не удалась. Выполните вручную: warp-cli --accept-tos registration new"
        fi
        log_warning "WARP установлен и зарегистрирован, но НЕ подключён."
        log_info "Подключение — пункт [3]: режим proxy (безопасно) или полный туннель."
    fi
    warp_status
    return 0
}

warp_connect_proxy() {
    local _port="$WARP_PROXY_PORT" _ans="" _i="" _ok=0 _warp_is=""
    echo ""
    log_info "Безопасный режим: WARP поднимает локальный SOCKS5, маршрут сервера не меняется."
    echo -en "  ${BOLD}Порт SOCKS5 на 127.0.0.1 [${_port}]:${NC} "
    { read -r _ans </dev/tty; } 2>/dev/null || true
    if [ -n "$_ans" ]; then _port="$_ans"; fi
    if ! printf '%s' "$_port" | awk '$0 ~ /^[0-9]+$/ && $0>=1024 && $0<=65535 {ok=1} END{exit !ok}'; then
        log_error "Некорректный порт '$_port' (нужно целое 1024..65535)"
        return 1
    fi
    if _warp_port_busy "$_port"; then
        log_error "Порт ${_port} уже занят другим процессом"
        return 1
    fi
    _warp_snapshot_save || return 1
    log_info "Включаю режим proxy (SOCKS5 на 127.0.0.1:${_port})..."
    if ! warp-cli --accept-tos mode proxy; then
        log_error "Не удалось переключить WARP в режим proxy"
        return 1
    fi
    if ! warp-cli --accept-tos proxy port "$_port"; then
        log_warning "Не удалось задать порт прокси (политика клиента?) — проверьте статус"
    fi
    if ! warp-cli --accept-tos connect; then
        log_error "Не удалось подключить WARP (режим proxy)"
        return 1
    fi
    for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
        if _warp_port_busy "$_port"; then _ok=1; break; fi
        sleep 1
    done
    if [ "$_ok" -ne 1 ]; then
        log_error "SOCKS5-порт 127.0.0.1:${_port} не появился — откатываю WARP"
        warp-cli --accept-tos disconnect >/dev/null 2>&1 || true
        return 1
    fi
    log_success "WARP подключён в режиме proxy: SOCKS5 на 127.0.0.1:${_port}"
    _warp_is="$(_warp_proxy_trace "$_port")"
    if [ "$_warp_is" = "on" ]; then
        log_success "Проверка через прокси: warp=on (трафик действительно идёт через Cloudflare WARP)"
    elif [ -n "$_warp_is" ]; then
        log_warning "Проверка через прокси: warp=${_warp_is} (ожидалось on)"
    else
        log_warning "Проверить прокси не удалось (curl через SOCKS5 не ответил)"
    fi
    echo -e "    ${CYAN}default route (не изменён):${NC} $(ip route show default 2>/dev/null | awk 'NR==1{print}')"
    echo -e "    ${CYAN}resolv.conf:${NC} $(_warp_resolv_info)"
    log_info "Как использовать этот прокси как upstream для Telemt — пункт [5]."
    return 0
}

warp_connect_tunnel() {
    echo ""
    log_warning "ПОЛНЫЙ ТУННЕЛЬ: WARP заменит default route и DNS сервера."
    log_warning "Этот режим уже один раз обрывал SSH (сервер становился недоступен)."
    log_info "Будут выполнены: снимок маршрута/DNS → исключение IP вашей SSH-сессии →"
    log_info "сторож systemd-run (отложенный автооткат) → проверка связности → автооткат."
    echo ""
    _warp_snapshot_show
    echo ""
    local _peer="" _delay="$WARP_TUNNEL_DELAY" _dans=""
    _peer="$(_warp_ssh_peer)"
    if [ -n "$_peer" ]; then
        echo -e "    ${CYAN}Ваша SSH-сессия:${NC} ${_peer} (будет исключена из туннеля)"
    else
        echo -e "    ${YELLOW}IP SSH-сессии не определён — исключить его из туннеля не получится.${NC}"
    fi
    echo ""
    if ! _confirm_word "Подключить WARP в режиме полного туннеля" WARP; then
        log_info "Отменено"
        return 0
    fi
    _warp_snapshot_save || return 1
    echo -en "  ${BOLD}Через сколько отключить автоматически [${_delay}]:${NC} "
    { read -r _dans </dev/tty; } 2>/dev/null || true
    if [ -n "$_dans" ]; then _delay="$_dans"; fi
    if ! _warp_watchdog_arm "$_delay"; then
        log_error "Не удалось взвести сторож (systemd-run) — НЕ подключаю туннель без страховки"
        return 1
    fi
    log_success "Сторож взведён: ${WARP_WATCHDOG_UNIT}.timer (отключит через ${_delay})"
    if [ -n "$_peer" ]; then
        if warp-cli --accept-tos tunnel ip add "$_peer" >/dev/null 2>&1; then
            log_success "IP ${_peer} исключён из туннеля (warp-cli tunnel ip add)"
        else
            log_warning "Не удалось исключить ${_peer} из туннеля"
        fi
    fi
    if ! warp-cli --accept-tos mode warp; then
        log_warning "Не удалось явно выставить режим warp — используется режим по умолчанию"
    fi
    if ! warp-cli --accept-tos connect; then
        log_error "warp-cli connect не удался"
        _warp_rollback
        return 1
    fi
    sleep 5
    if _warp_check_net; then
        log_success "WARP подключён (полный туннель), связность есть."
        log_info "Автоотключение через ${_delay}; если WARP нужно оставить — снимите сторожа:"
        echo -e "      ${DIM}systemctl stop ${WARP_WATCHDOG_UNIT}.timer${NC}"
    else
        log_error "Связность потеряна сразу после подключения — АВТООТКАТ"
        _warp_rollback
        return 1
    fi
    return 0
}

warp_connect() {
    echo ""
    if ! warp_installed; then
        log_warning "Cloudflare WARP не установлен — сначала пункт [2] «Установить»"
        return 0
    fi
    echo -e "  ${BOLD}${CYAN}Режим подключения WARP${NC}"
    echo -e "  ${GREEN}[1]${NC}  proxy — локальный SOCKS5 ${DIM}(безопасно: маршрут и DNS сервера не меняются)${NC}"
    echo -e "  ${RED}[2]${NC}  полный туннель ${YELLOW}(меняет маршрут/DNS; автооткат + отложенный сторож)${NC}"
    echo -e "  ${RED}[0]${NC}  Отмена"
    echo ""
    echo -en "  ${BOLD}Выбор:${NC} "
    local _c=""
    { read -r _c </dev/tty; } 2>/dev/null || { echo; return 1; }
    case "$_c" in
        1) warp_connect_proxy ;;
        2) warp_connect_tunnel ;;
        *) log_info "Отменено" ;;
    esac
    return 0
}

warp_disconnect() {
    echo ""
    if ! warp_installed; then
        log_warning "Cloudflare WARP не установлен"
        return 0
    fi
    _warp_watchdog_disarm
    if warp-cli --accept-tos disconnect; then
        log_success "WARP отключён"
    else
        log_warning "warp-cli disconnect вернул ошибку (возможно, WARP уже отключён)"
    fi
    warp-cli --accept-tos mode warp >/dev/null 2>&1 || true
    _warp_restore_route
    log_info "Маршрут/DNS сверены со снимком. resolv.conf: $(_warp_resolv_info)"
    return 0
}

warp_telemt_hint() {
    echo ""
    echo -e "  ${BOLD}${CYAN}WARP как upstream для MTProto-прокси${NC}"
    echo -e "  ${DIM}──────────────────────────────────────────────${NC}"
    echo -e "  В режиме proxy WARP отдаёт обычный SOCKS5 на 127.0.0.1, поэтому"
    echo -e "  его можно указать как upstream (исходящий прокси) для Telemt."
    echo -e "  В конфиге Telemt (документация: docs/FAQ.en.md, раздел Upstream Manager):"
    echo ""
    echo -e "      ${GREEN}[[upstreams]]${NC}"
    echo -e "      ${GREEN}type = \"socks5\"${NC}"
    echo -e "      ${GREEN}address = \"127.0.0.1:${WARP_PROXY_PORT}\"${NC}"
    echo -e "      ${GREEN}weight = 1${NC}"
    echo -e "      ${GREEN}enabled = true${NC}"
    echo ""
    echo -e "  ${DIM}Смысл: Telegram видит исходящий трафик с адреса Cloudflare WARP,"
    echo -e "  а не с IP вашего сервера. Можно комбинировать с direct: задайте"
    echo -e "  несколько [[upstreams]] с разными weight (проценты трафика).${NC}"
    echo ""
    echo -e "  ${YELLOW}Честные ограничения:${NC}"
    echo -e "  ${DIM}• mtg (9seconds/mtg) штатного upstream-через-SOCKS5 в конфиге НЕ имеет:"
    echo -e "    в mtglib нет поля исходящего прокси (есть только приём SOCKS5 от клиента)."
    echo -e "    Для mtg нужен обход на уровне ОС (сеть/маршруты), а не параметр конфига."
    echo -e "• Схема проверена на Telemt ([[upstreams]] type=\"socks5\") и на MTProxyMax,"
    echo -e "  который документирует WARP именно как 127.0.0.1:40000."
    echo -e "• Egress-адреса Cloudflare WARP у Telegram в части регионов могут"
    echo -e "  блокироваться — проверяйте фактическую работу после настройки.${NC}"
    return 0
}

warp_remove() {
    echo ""
    if ! warp_installed && [ ! -f /etc/apt/sources.list.d/cloudflare-client.list ]; then
        log_warning "Cloudflare WARP не установлен"
        return 0
    fi
    log_warning "Удаление: снять клиент, репозиторий и вернуть маршрут/DNS/resolv.conf."
    if ! _confirm "Удалить Cloudflare WARP?"; then
        log_info "Отменено"
        return 0
    fi
    warp-cli --accept-tos disconnect >/dev/null 2>&1 || true
    warp-cli --accept-tos mode warp >/dev/null 2>&1 || true
    _warp_watchdog_disarm
    # DNS вернуть ДО удаления пакета; если снимка нет — штатный stub systemd-resolved
    if [ ! -s "$WARP_STATE_DIR/resolv.conf.before" ] && [ -e "$WARP_RESOLV_STUB" ]; then
        ln -sf "$WARP_RESOLV_STUB" /etc/resolv.conf 2>/dev/null || true
    fi
    _warp_restore_route
    if apt-get purge -y -qq cloudflare-warp >/dev/null 2>&1; then
        log_success "Пакет cloudflare-warp удалён (purge)"
    else
        log_warning "apt-get purge вернул ошибку (пакет мог быть уже удалён)"
    fi
    systemctl stop warp-svc >/dev/null 2>&1 || true
    rm -f /etc/apt/sources.list.d/cloudflare-client.list
    rm -f /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    rm -f "$WARP_WATCHDOG_SCRIPT"
    rm -rf /var/lib/cloudflare-warp
    _warp_restore_route
    rm -rf "$WARP_STATE_DIR"
    log_info "resolv.conf: $(_warp_resolv_info)"
    log_success "Cloudflare WARP удалён; маршрут и DNS восстановлены"
    return 0
}

warp_menu() {
    while true; do
        clear 2>/dev/null || true
        echo ""
        echo -e "  ${BOLD}${CYAN}Cloudflare WARP${NC}"
        echo -e "  ${DIM}══════════════════════════════${NC}"
        echo -e "  ${CYAN}[1]${NC}  Статус"
        echo -e "  ${CYAN}[2]${NC}  Установить ${GRAY}(без подключения)${NC}"
        echo -e "  ${CYAN}[3]${NC}  Подключить ${GRAY}(proxy = безопасно, туннель = с автооткатом)${NC}"
        echo -e "  ${CYAN}[4]${NC}  Отключить"
        echo -e "  ${CYAN}[5]${NC}  WARP как upstream для Telemt ${GRAY}(инструкция)${NC}"
        echo -e "  ${RED}[6]${NC}  Удалить ${GRAY}(с восстановлением DNS)${NC}"
        echo -e "  ${RED}[0]${NC}  Назад"
        echo ""
        echo -en "  ${BOLD}Выбор:${NC} "
        local choice
        { read -r choice </dev/tty; } 2>/dev/null || { echo; return 1; }
        case "$choice" in
            1) warp_status; _pause || return 1 ;;
            2) warp_install || true; _pause || return 1 ;;
            3) warp_connect || true; _pause || return 1 ;;
            4) warp_disconnect || true; _pause || return 1 ;;
            5) warp_telemt_hint; _pause || return 1 ;;
            6) warp_remove || true; _pause || return 1 ;;
            0 | "") return 0 ;;
            *) log_error "Неверный выбор"; sleep 0.2 ;;
        esac
    done
}

# ══════════════════════════════════════════════════════════════
#  ADGUARD HOME
# ══════════════════════════════════════════════════════════════
adguard_installed() {
    [ -x /opt/AdGuardHome/AdGuardHome ] || command -v AdGuardHome >/dev/null 2>&1
}

_adg_listens_on() {
    # 0 = порт $1 слушает ИМЕННО AdGuardHome.
    # Процесс и порт должны совпасть в ОДНОЙ строке `ss`: два независимых grep
    # дают ложный «OK», когда AdGuard слушает 3000, а :53 держит systemd-resolved.
    ss -lntup 2>/dev/null | awk -v p="[:.]$1\$" '$5 ~ p && /AdGuardHome/ {f=1} END{exit !f}'
}

_adg_port_used() {
    # 0 = порт $1 кем-то слушается (tcp/udp)
    ss -lntup 2>/dev/null | awk -v p="[:.]$1\$" '$5 ~ p {f=1} END{exit !f}'
}

adguard_status() {
    echo ""
    if ! adguard_installed; then
        log_warning "AdGuard Home не установлен"
        return 0
    fi
    local _act _en
    _act="$(systemctl is-active AdGuardHome 2>/dev/null || true)"
    _en="$(systemctl is-enabled AdGuardHome 2>/dev/null || true)"
    echo -e "    ${CYAN}Служба AdGuardHome:${NC} ${_act:-unknown}"
    echo -e "    ${CYAN}Автозапуск:${NC} ${_en:-unknown}"
    # Честная проверка: и процесс, и порт — в ОДНОЙ строке `ss` (см. _adg_listens_on).
    if _adg_listens_on 53; then
        echo -e "    ${GREEN}Порт 53 слушает AdGuardHome (DNS работает)${NC}"
    elif _adg_port_used 53; then
        echo -e "    ${YELLOW}Порт 53 занят другой службой (на Ubuntu это обычно systemd-resolved), НЕ AdGuard${NC}"
        echo -e "    ${DIM}AdGuard начнёт отвечать на 53 после мастера настройки: http://<IP>:3000${NC}"
        echo -e "    ${DIM}Если мастер не может занять 53 — отключите stub-слушатель systemd-resolved:${NC}"
        echo -e "    ${DIM}  DNSStubListener=no в /etc/systemd/resolved.conf + systemctl restart systemd-resolved${NC}"
    else
        echo -e "    ${YELLOW}Порт 53 не слушается${NC}"
    fi
    if _adg_listens_on 3000; then
        echo -e "    ${GREEN}Порт 3000 слушает AdGuardHome (веб-интерфейс)${NC}"
    else
        echo -e "    ${YELLOW}Порт 3000 не слушает AdGuardHome (веб-интерфейс: http://<IP>:3000)${NC}"
    fi
    echo -e "    ${CYAN}resolv.conf:${NC} $(_warp_resolv_info)"
    return 0
}

adguard_install() {
    echo ""
    if adguard_installed; then
        log_info "AdGuard Home уже установлен"
        adguard_status
        return 0
    fi
    log_warning "AdGuard Home займёт порт 53 (DNS) и откроет веб-интерфейс на порту 3000."
    log_warning "Если порт 53 уже занят (systemd-resolved/dnsmasq) — будет конфликт."
    if ! _confirm "Продолжить установку?"; then
        log_info "Отменено"
        return 0
    fi
    _warp_snapshot_save >/dev/null 2>&1 || true

    local _tmp=""
    _tmp="$(mktemp)" || { log_error "Не удалось создать временный файл"; return 1; }
    if ! curl -fsSL "https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh" -o "$_tmp"; then
        log_error "Не удалось скачать установщик AdGuard Home"
        rm -f "$_tmp"
        return 1
    fi
    if [ ! -s "$_tmp" ]; then
        log_error "Скачанный установщик пуст"
        rm -f "$_tmp"
        return 1
    fi

    log_info "Запускаю официальный установщик (без интерпретатора из pipe)..."
    if sh "$_tmp" -v </dev/tty; then
        log_success "Установщик AdGuard Home завершился успешно"
    else
        log_warning "Установщик вернул ошибку — проверьте вывод выше"
    fi
    rm -f "$_tmp"

    if [ -x /opt/AdGuardHome/AdGuardHome ]; then
        systemctl enable AdGuardHome >/dev/null 2>&1 || log_warning "Не удалось включить автозапуск AdGuardHome"
        systemctl start AdGuardHome >/dev/null 2>&1 || log_warning "Не удалось запустить AdGuardHome"
    fi
    adguard_status
    return 0
}

adguard_open_ports() {
    echo ""
    if command -v ufw >/dev/null 2>&1; then
        if _confirm "Открыть порты 53/tcp, 53/udp, 3000/tcp в ufw?"; then
            ufw allow 53/tcp >/dev/null 2>&1 || true
            ufw allow 53/udp >/dev/null 2>&1 || true
            ufw allow 3000/tcp >/dev/null 2>&1 || true
            log_success "ufw: добавлены правила для 53/tcp, 53/udp, 3000/tcp"
        else
            log_info "Отменено. Порты нужно открыть вручную:"
            echo -e "    ${DIM}ufw allow 53/tcp && ufw allow 53/udp && ufw allow 3000/tcp${NC}"
        fi
    else
        log_warning "ufw не найден — откройте порты 53/tcp, 53/udp, 3000/tcp вручную"
    fi
    return 0
}

adguard_remove() {
    echo ""
    if ! adguard_installed && ! _svc_exists AdGuardHome; then
        log_warning "AdGuard Home не установлен"
        return 0
    fi
    if ! _confirm "Удалить AdGuard Home?"; then
        log_info "Отменено"
        return 0
    fi
    if [ -x /opt/AdGuardHome/AdGuardHome ]; then
        /opt/AdGuardHome/AdGuardHome -s uninstall </dev/null >/dev/null 2>&1 || true
    fi
    systemctl stop AdGuardHome >/dev/null 2>&1 || true
    systemctl disable AdGuardHome >/dev/null 2>&1 || true
    if _confirm "Удалить каталог /opt/AdGuardHome (бинарь и конфиг)?"; then
        if rm -rf /opt/AdGuardHome; then
            log_success "Каталог /opt/AdGuardHome удалён"
        else
            log_warning "Не удалось удалить /opt/AdGuardHome"
        fi
    else
        log_info "Каталог /opt/AdGuardHome оставлен"
    fi
    # Порт 53 после удаления должен вернуться к systemd-resolved
    if [ -e "$WARP_RESOLV_STUB" ]; then
        ln -sf "$WARP_RESOLV_STUB" /etc/resolv.conf 2>/dev/null || true
    fi
    systemctl restart systemd-resolved >/dev/null 2>&1 || true
    log_info "resolv.conf: $(_warp_resolv_info)"
    log_success "AdGuard Home удалён"
    return 0
}

adguard_menu() {
    while true; do
        clear 2>/dev/null || true
        echo ""
        echo -e "  ${BOLD}${CYAN}AdGuard Home (DNS)${NC}"
        echo -e "  ${DIM}══════════════════════════════${NC}"
        echo -e "  ${CYAN}[1]${NC}  Статус"
        echo -e "  ${CYAN}[2]${NC}  Установить ${YELLOW}(займёт порт 53)${NC}"
        echo -e "  ${CYAN}[3]${NC}  Открыть порты 53/3000 (ufw)"
        echo -e "  ${RED}[4]${NC}  Удалить"
        echo -e "  ${RED}[0]${NC}  Назад"
        echo ""
        echo -en "  ${BOLD}Выбор:${NC} "
        local choice
        { read -r choice </dev/tty; } 2>/dev/null || { echo; return 1; }
        case "$choice" in
            1) adguard_status; _pause || return 1 ;;
            2) adguard_install || true; _pause || return 1 ;;
            3) adguard_open_ports; _pause || return 1 ;;
            4) adguard_remove || true; _pause || return 1 ;;
            0 | "") return 0 ;;
            *) log_error "Неверный выбор"; sleep 0.2 ;;
        esac
    done
}

# ── Главное меню раздела ─────────────────────────────────────
show_services_menu() {
    while true; do
        clear 2>/dev/null || true
        echo ""
        echo -e "  ${BOLD}${CYAN}Дополнительные сервисы${NC}"
        echo -e "  ${DIM}══════════════════════════════${NC}"
        echo -e "  ${CYAN}[1]${NC}  Cloudflare WARP ${DIM}(proxy = безопасно, туннель = с автооткатом)${NC}"
        echo -e "  ${CYAN}[2]${NC}  AdGuard Home — DNS ${DIM}(порт 53)${NC}"
        echo -e "  ${RED}[0]${NC}  Назад"
        echo ""
        echo -en "  ${BOLD}Выбор:${NC} "
        local choice
        { read -r choice </dev/tty; } 2>/dev/null || { echo; return 1; }
        case "$choice" in
            1) warp_menu || return 1 ;;
            2) adguard_menu || return 1 ;;
            0 | "") return 0 ;;
            *) log_error "Неверный выбор"; sleep 0.2 ;;
        esac
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Меню без управляющего терминала не должно завершаться аварийно (rc≠0),
    # иначе вызывающий скрипт решает, что раздел сломан.
    show_services_menu || true
fi
