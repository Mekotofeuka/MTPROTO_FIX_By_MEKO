#!/bin/bash
# data/shaping.sh — Ограничение скорости (шейпинг) для портов прокси
#
# Назначение: ограничить исходящую скорость трафика прокси-порта:
#   • общий потолок на все порты прокси;
#   • персональный лимит НА КАЖДЫЙ IPv4 клиента (по src-IP);
#   • исключения по IP/подсети (не попадают под общий потолок).
#
# Механизм: egress tc HTB + flower-фильтры (src_port = порт прокси, dst_ip = IP клиента).
# Входящий SYN-фикс (MTPR_SYNFIX / nftables) не затрагивается: шейпинг работает
# только на исходящем трафике (root qdisc интерфейса), SYNFIX — ingress/mangle.
#
# Запуск:  bash /opt/mtpr-simple/data/shaping.sh            # интерактивное меню
#          bash /opt/mtpr-simple/data/shaping.sh --remove   # снять шейпинг (без меню)
#          bash /opt/mtpr-simple/data/shaping.sh --restore  # применить из конфига (boot)
#          bash /opt/mtpr-simple/data/shaping.sh --tick     # пересчёт dynamic (таймер)
#          bash /opt/mtpr-simple/data/shaping.sh --status   # напечатать статус
set -euo pipefail

INSTALL_DIR="/opt/mtpr-simple"
PORT_FILE="${INSTALL_DIR}/port"
CONFIG_FILE="${INSTALL_DIR}/shaping.json"
STATE_FILE="${INSTALL_DIR}/shaping.state"
META_FILE="${INSTALL_DIR}/shaping.meta"
SNAPSHOT_FILE="${INSTALL_DIR}/shaping.snapshot"
LOCK_FILE="/run/mtpr-shaping.lock"

# ── Наши идентификаторы (не пересекаются с MTPR_SYNFIX: там fwmark 0x400/mangle) ──
SHAPE_ROOT_HANDLE="7a11:"
SHAPE_CLS_ROOT="7a11:1"      # корень дерева
SHAPE_CLS_TOTAL="7a11:10"    # общий потолок
SHAPE_CLS_EXEMPT="7a11:20"   # ip_exempt (без общего потолка) + дефолт неклассифицированного трафика
SHAPE_CLS_PROFILE="7a11:30"  # profile_exempt (без персонального лимита)
SHAPE_CLS_DEFAULT="7a11:40"  # дефолт для новых IP (персональный лимит)
SHAPE_MINOR_FIRST=256
SHAPE_MINOR_MAX=4096
SHAPE_PREF_EXEMPT=10
SHAPE_PREF_IP=1000
SHAPE_PREF_DEFAULT=10000
SHAPE_QUANTUM=15140
SHAPE_UNLIMITED_BPS=100000000000   # 100 Гбит/с — «без лимита»
ALLOWED_ROOT_QDISC="fq_codel|fq|pfifo_fast|mq"

SVC_RESTORE="mtpr-shaping-restore.service"
SVC_TICK="mtpr-shaping-tick.service"
TMR_TICK="mtpr-shaping-tick.timer"

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

# ── Логирование ──────────────────────────────────────────────
log_info() { echo -e "  ${BLUE}[i]${NC} $1"; }
log_success() { echo -e "  ${GREEN}[✓]${NC} $1"; }
log_error() { echo -e "  ${RED}[✗]${NC} $1" >&2; }
log_warning() { echo -e "  ${YELLOW}[!]${NC} $1"; }

_pause() {
    echo ""
    echo -e "  ${GRAY}Нажмите любую клавишу для продолжения...${NC}"
    { read -rsn1 </dev/tty; } 2>/dev/null || { echo; return 1; }
    IFS= read -r -t 0.05 _ </dev/tty 2>/dev/null || true
}

# ── Конфиг ───────────────────────────────────────────────────
SH_ENABLED="false"
SH_MODE="manual"
SH_CHANNEL="1000"
SH_RESERVE="10"
SH_USERS="10"
SH_MANUAL_TOTAL="900"
SH_MANUAL_IP="90"
SH_IP_EXEMPT=""
SH_PROFILE_EXEMPT=""
SH_LAST_ERROR=""
SH_CONFIG_BROKEN=0

_sh_have_jq() { command -v jq >/dev/null 2>&1; }

_sh_load() {
    SH_ENABLED="false"; SH_MODE="manual"
    SH_CHANNEL="1000"; SH_RESERVE="10"; SH_USERS="10"
    SH_MANUAL_TOTAL="900"; SH_MANUAL_IP="90"
    SH_IP_EXEMPT=""; SH_PROFILE_EXEMPT=""; SH_LAST_ERROR=""
    SH_CONFIG_BROKEN=0
    [ -s "$CONFIG_FILE" ] || return 0
    if ! _sh_have_jq; then
        log_warning "jq не установлен — конфиг шейпинга не прочитан (используются значения по умолчанию)"
        return 0
    fi
    if ! jq -e . "$CONFIG_FILE" >/dev/null 2>&1; then
        # Битый JSON: НЕ применяем молча дефолты 900/90 Мбит — это могло бы
        # внезапно урезать живому прокси скорость. Показываем дефолты для
        # --status, но sh_apply отказывается работать (SH_CONFIG_BROKEN).
        SH_CONFIG_BROKEN=1
        log_error "Конфиг шейпинга повреждён ($CONFIG_FILE) — применяю значения по умолчанию только для показа; применение/изменение лимитов заблокировано"
        return 0
    fi
    SH_ENABLED=$(jq -r 'if .enabled == true then "true" else "false" end' "$CONFIG_FILE" 2>/dev/null || echo false)
    SH_MODE=$(jq -r '.mode // "manual"' "$CONFIG_FILE" 2>/dev/null || echo manual)
    SH_CHANNEL=$(jq -r '.channel_mbps // 1000' "$CONFIG_FILE" 2>/dev/null || echo 1000)
    SH_RESERVE=$(jq -r '.reserve_percent // 10' "$CONFIG_FILE" 2>/dev/null || echo 10)
    SH_USERS=$(jq -r '.expected_users // 10' "$CONFIG_FILE" 2>/dev/null || echo 10)
    SH_MANUAL_TOTAL=$(jq -r '.manual_total_mbps // 900' "$CONFIG_FILE" 2>/dev/null || echo 900)
    SH_MANUAL_IP=$(jq -r '.manual_ip_mbps // 90' "$CONFIG_FILE" 2>/dev/null || echo 90)
    SH_IP_EXEMPT=$(jq -r '(.ip_exempt // []) | join(" ")' "$CONFIG_FILE" 2>/dev/null || true)
    SH_PROFILE_EXEMPT=$(jq -r '(.profile_exempt // []) | join(" ")' "$CONFIG_FILE" 2>/dev/null || true)
    SH_LAST_ERROR=$(jq -r '.last_error // ""' "$CONFIG_FILE" 2>/dev/null || true)
}

_sh_save() {
    _sh_have_jq || { log_error "jq не установлен — не могу сохранить конфиг"; return 1; }
    local tmp="${CONFIG_FILE}.tmp.$$"
    jq -n \
        --arg enabled "$SH_ENABLED" \
        --arg mode "$SH_MODE" \
        --arg channel "$SH_CHANNEL" \
        --arg reserve "$SH_RESERVE" \
        --arg users "$SH_USERS" \
        --arg mtotal "$SH_MANUAL_TOTAL" \
        --arg mip "$SH_MANUAL_IP" \
        --arg ip_exempt "$SH_IP_EXEMPT" \
        --arg profile_exempt "$SH_PROFILE_EXEMPT" \
        --arg last_error "$SH_LAST_ERROR" \
        '{
            enabled: ($enabled == "true"),
            mode: $mode,
            channel_mbps: ($channel | tonumber? // 1000),
            reserve_percent: ($reserve | tonumber? // 10),
            expected_users: ($users | tonumber? // 10),
            manual_total_mbps: ($mtotal | tonumber? // 900),
            manual_ip_mbps: ($mip | tonumber? // 90),
            ip_exempt: ($ip_exempt | split(" ") | map(select(length > 0))),
            profile_exempt: ($profile_exempt | split(" ") | map(select(length > 0))),
            last_error: $last_error
        }' > "$tmp"
    mv "$tmp" "$CONFIG_FILE"
}

_sh_save_last_error() {
    SH_LAST_ERROR="$1"
    _sh_save >/dev/null 2>&1 || true
}

# ── Проверки окружения ───────────────────────────────────────
sh_iface() {
    ip -4 route get 1.1.1.1 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }'
}

sh_ports() {
    local raw p out=""
    [ -r "$PORT_FILE" ] && raw="$(cat "$PORT_FILE" 2>/dev/null || true)"
    [ -n "${raw:-}" ] || raw="443"
    raw="${raw//,/ }"
    for p in $raw; do
        if [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ]; then
            out="${out}${out:+ }${p}"
        else
            log_warning "Некорректный порт '$p' пропущен" >&2
        fi
    done
    printf '%s' "$out"
}

_sh_root_kind() { tc qdisc show dev "$1" 2>/dev/null | awk 'NR==1{print $2}'; }
_sh_root_handle() { tc qdisc show dev "$1" 2>/dev/null | awk 'NR==1{print $3}'; }
_sh_is_ours() {
    [ "$(_sh_root_kind "$1")" = "htb" ] && [ "$(_sh_root_handle "$1")" = "$SHAPE_ROOT_HANDLE" ]
}

# ── Снимок/откат исходного qdisc ─────────────────────────────
_sh_snapshot() { # kind исходного qdisc
    printf '%s\n' "$1" > "$SNAPSHOT_FILE"
}
_sh_restore_snapshot() {
    local if="$1" kind=""
    [ -s "$SNAPSHOT_FILE" ] && kind="$(head -1 "$SNAPSHOT_FILE" 2>/dev/null || true)"
    # Возвращаем только ТИП исходного qdisc. Явный handle (например `fq_codel 800e:`)
    # без перезагрузки не восстановить — ядро присваивает новый авто-handle.
    # Это безопасно: handle не влияет на поведение qdisc, важен только тип.
    case "$kind" in
        fq_codel|fq|pfifo_fast|mq)
            tc qdisc replace dev "$if" root "$kind" 2>/dev/null || true
            ;;
    esac
}
_sh_rollback() {
    local if="$1"
    # Трогаем root qdisc ТОЛЬКО если это наше дерево — иначе затрём чужой qdisc
    _sh_is_ours "$if" || return 0
    log_warning "Откат шейпинга: удаляю наше дерево и возвращаю исходный qdisc"
    tc qdisc del dev "$if" root 2>/dev/null || true
    _sh_restore_snapshot "$if"
}

# ── Состояние IP→minor ───────────────────────────────────────
_sh_minor_for_ip() {
    awk -v ip="$1" '$1==ip{print $2; exit}' "$STATE_FILE" 2>/dev/null || true
}
_sh_minor_set() {
    local ip="$1" m="$2" tmp="${STATE_FILE}.tmp.$$"
    { grep -v "^${ip} " "$STATE_FILE" 2>/dev/null || true; echo "$ip $m"; } > "$tmp"
    mv "$tmp" "$STATE_FILE"
}
_sh_next_minor() {
    # Один проход awk (без пайпов с grep -q: под set -o pipefail grep -q даёт
    # SIGPIPE/141 и цикл «не видит» занятый minor -> коллизия классов).
    [ -s "$STATE_FILE" ] || { printf '%s' "$SHAPE_MINOR_FIRST"; return 0; }
    awk -v first="$SHAPE_MINOR_FIRST" -v max="$SHAPE_MINOR_MAX" '
        { if ($2 ~ /^[0-9]+$/) used[$2] = 1 }
        END {
            for (m = first; m <= max; m++) if (!(m in used)) { print m; exit }
            print max + 1
        }
    ' "$STATE_FILE" 2>/dev/null || printf '%s' "$(( SHAPE_MINOR_MAX + 1 ))"
}
_sh_meta_get() { awk -v k="$1" '$1==k{print $2; exit}' "$META_FILE" 2>/dev/null || true; }
_sh_meta_set() {
    local k="$1" v="$2" tmp="${META_FILE}.tmp.$$"
    { grep -v "^${k} " "$META_FILE" 2>/dev/null || true; echo "$k $v"; } > "$tmp"
    mv "$tmp" "$META_FILE"
}

# ── Активные IP клиентов ─────────────────────────────────────
sh_active_source() {
    if command -v conntrack >/dev/null 2>&1; then printf 'conntrack'; else printf 'ss'; fi
}

sh_active_ips() {
    local port
    if command -v conntrack >/dev/null 2>&1; then
        for port in $(sh_ports); do
            # Берём ТОЛЬКО original src (клиент). Обычный `dst=` даёт и наш сервер,
            # и клиента (original+reply) -> мусор в активных IP.
            conntrack -L -p tcp --dport "$port" 2>/dev/null | awk '
                { for (i = 1; i <= NF; i++) if ($i ~ /^src=/) { sub(/^src=/, "", $i); print $i; break } }' || true
        done | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | grep -vE '^(127\.|0\.0\.0\.0)' | sort -u
        return 0
    fi
    if command -v ss >/dev/null 2>&1; then
        for port in $(sh_ports); do
            # ss с state-фильтром НЕ печатает колонку State, поэтому peer-адрес
            # лежит в ПОСЛЕДНЕМ поле ($NF), а не в $5 (иначе пусто -> IP не находятся).
            # -H убирает строку-заголовок; sed отрезает :port.
            ss -Htn state established "( sport = :${port} )" 2>/dev/null | awk '{print $NF}' \
                | sed -E 's/:[0-9]+$//' || true
        done | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | grep -vE '^(127\.|0\.0\.0\.0)' | sort -u
        return 0
    fi
    return 1
}

# ── Валидация конфига ────────────────────────────────────────
_sh_is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }
_sh_valid_cidr() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]]
}

_sh_validate() {
    case "$SH_MODE" in
        manual|fixed|dynamic) ;;
        *) log_error "Некорректный режим шейпинга: '$SH_MODE'"; return 1 ;;
    esac
    _sh_is_uint "$SH_MANUAL_TOTAL" && [ "$SH_MANUAL_TOTAL" -ge 1 ] && [ "$SH_MANUAL_TOTAL" -le 1000000 ] || { log_error "Общий потолок должен быть целым числом 1..1000000 Мбит/с"; return 1; }
    _sh_is_uint "$SH_MANUAL_IP" && [ "$SH_MANUAL_IP" -ge 1 ] && [ "$SH_MANUAL_IP" -le 1000000 ] || { log_error "Лимит на IPv4 должен быть целым числом 1..1000000 Мбит/с"; return 1; }
    _sh_is_uint "$SH_CHANNEL" && [ "$SH_CHANNEL" -ge 1 ] && [ "$SH_CHANNEL" -le 1000000 ] || { log_error "Канал должен быть целым числом 1..1000000 Мбит/с"; return 1; }
    _sh_is_uint "$SH_RESERVE" && [ "$SH_RESERVE" -le 99 ] || { log_error "Резерв должен быть числом 0..99 %"; return 1; }
    _sh_is_uint "$SH_USERS" && [ "$SH_USERS" -ge 1 ] && [ "$SH_USERS" -le 1000000 ] || { log_error "Ожидаемое число пользователей должно быть 1..1000000"; return 1; }
    local item
    for item in $SH_IP_EXEMPT; do
        _sh_valid_cidr "$item" || { log_error "Некорректный адрес/подсеть в исключениях: '$item'"; return 1; }
    done
    return 0
}

# ── Расчёт лимитов (бит/с) ───────────────────────────────────
_sh_rates() {
    local total ip n active=0
    case "$SH_MODE" in
        manual)
            total=$(( SH_MANUAL_TOTAL * 1000000 ))
            ip=$(( SH_MANUAL_IP * 1000000 ))
            ;;
        *)
            total=$(( SH_CHANNEL * (100 - SH_RESERVE) * 10000 ))
            n=$SH_USERS
            if [ "$SH_MODE" = "dynamic" ]; then
                active=$(sh_active_ips | grep -c . || true)
                [ "${active:-0}" -gt "$n" ] && n="$active"
            fi
            [ "$n" -lt 1 ] && n=1
            ip=$(( total / n ))
            ;;
    esac
    [ "$total" -lt 1 ] && total=1
    [ "$ip" -lt 1 ] && ip=1
    # Страховка от переполнения, если shaping.json правили руками в обход _sh_validate
    [ "$total" -gt "$SHAPE_UNLIMITED_BPS" ] && total=$SHAPE_UNLIMITED_BPS
    [ "$ip" -gt "$total" ] && ip=$total
    printf '%s %s\n' "$total" "$ip"
}

# ── tc helpers ───────────────────────────────────────────────
_sh_class() { # iface parent classid rate_bps [ceil_bps]
    local if="$1" parent="$2" cid="$3" rate="$4" ceil="${5:-$4}"
    tc class replace dev "$if" parent "$parent" classid "$cid" htb \
        rate "${rate}bit" ceil "${ceil}bit" quantum "$SHAPE_QUANTUM"
}
_sh_fq() { # iface parent
    local _if="$1" _parent="$2"
    tc qdisc replace dev "$_if" parent "$_parent" fq_codel 2>/dev/null || true
}

_sh_sync_ip() { # iface ip minor rate ports
    local if="$1" ipaddr="$2" minor="$3" rate="$4" ports="$5"
    local cid="7a11:${minor}" port idx=0 rc=0
    _sh_class "$if" "$SHAPE_CLS_TOTAL" "$cid" "$rate" "$rate" || return 1
    _sh_fq "$if" "$cid"
    for port in $ports; do
        local handle
        # minor*64 (а не *8): при >8 портах на IP хендлы не должны пересекаться
        handle=$(printf '0x%x' $(( minor * 64 + idx )))
        tc filter replace dev "$if" parent "$SHAPE_ROOT_HANDLE" protocol ip pref "$SHAPE_PREF_IP" \
            handle "$handle" flower ip_proto tcp src_port "$port" dst_ip "$ipaddr" \
            classid "$cid" 2>/dev/null || rc=1
        idx=$(( idx + 1 ))
    done
    # Провал установки фильтра НЕ должен выглядеть успехом: без него у IP не будет лимита.
    [ "$rc" = "0" ] || log_warning "Не удалось установить фильтр лимита для ${ipaddr} (порт(ы): ${ports})"
    return "$rc"
}

# ── Применение ───────────────────────────────────────────────
_sh_delete_filters() {
    local if="$1"
    tc filter del dev "$if" parent "$SHAPE_ROOT_HANDLE" protocol ip pref "$SHAPE_PREF_EXEMPT" 2>/dev/null || true
    tc filter del dev "$if" parent "$SHAPE_ROOT_HANDLE" protocol ip pref "$SHAPE_PREF_IP" 2>/dev/null || true
    tc filter del dev "$if" parent "$SHAPE_ROOT_HANDLE" protocol ip pref "$SHAPE_PREF_DEFAULT" 2>/dev/null || true
}

# ── Защита от аварии в фазе построения дерева (trap) ─────────
SH_APPLY_DONE=1
SH_APPLY_IF=""
_sh_apply_guard() {
    [ "$SH_APPLY_DONE" = "1" ] && return 0
    SH_APPLY_DONE=1
    log_warning "Настройка шейпинга прервана — возвращаю исходное состояние"
    _sh_rollback "$SH_APPLY_IF"
}

sh_apply() {
    local if ports kind total ip port item ipaddr minor idx active source skipped failed
    skipped=0
    failed=0
    if ! command -v tc >/dev/null 2>&1; then
        log_error "Утилита tc не найдена (пакет iproute2)"
        if [ "${SH_ALLOW_TC_INSTALL:-0}" = "1" ]; then
            log_info "Пробую установить iproute2..."
            if apt-get install -y iproute2 >/dev/null 2>&1; then
                log_success "iproute2 установлен"
            else
                log_error "Не удалось установить iproute2"; _sh_save_last_error "tc missing"; return 1
            fi
        else
            log_info "Установите пакет iproute2 (apt-get install -y iproute2) и повторите"
            _sh_save_last_error "tc missing"; return 1
        fi
    fi
    if ! _sh_have_jq; then
        log_error "jq не найден (apt-get install -y jq)"; return 1
    fi
    if [ "${SH_CONFIG_BROKEN:-0}" = "1" ]; then
        log_error "Конфиг шейпинга повреждён (${CONFIG_FILE}) — применение отменено. Исправьте файл или удалите его (rm -f ${CONFIG_FILE}) и настройте заново"
        return 1
    fi
    _sh_validate || { _sh_save_last_error "invalid config"; return 1; }

    if="$(sh_iface || true)"
    if [ -z "$if" ]; then
        log_error "Не удалось определить сетевой интерфейс (нет маршрута по умолчанию)"
        _sh_save_last_error "no default route"; return 1
    fi
    ports="$(sh_ports || true)"
    if [ -z "$ports" ]; then
        log_error "Нет корректных портов прокси (проверьте ${PORT_FILE})"
        _sh_save_last_error "no valid ports"; return 1
    fi

    read -r total ip < <(_sh_rates)

    kind="$(_sh_root_kind "$if" || true)"

    if _sh_is_ours "$if"; then
        log_info "Дерево шейпинга уже установлено — обновляю лимиты"
    elif [[ "$kind" =~ ^(${ALLOWED_ROOT_QDISC})$ ]]; then
        _sh_snapshot "$kind"
        log_info "Заменяю корневой qdisc '$kind' на HTB (handle ${SHAPE_ROOT_HANDLE})"
        if ! tc qdisc replace dev "$if" root handle "$SHAPE_ROOT_HANDLE" htb default 20 2>/dev/null; then
            log_error "Не удалось создать HTB qdisc (нужен NET_ADMIN; LXC/контейнер может не поддерживать)"
            _sh_save_last_error "htb replace failed"; return 1
        fi
    else
        log_error "Корневой qdisc '$kind' не поддерживается. Разрешены: ${ALLOWED_ROOT_QDISC//|/, }${kind:+ (сейчас: $kind)}"
        log_error "Сервер не поддерживает HTB (например, LXC/noqueue) — шейпинг не включён"
        _sh_save_last_error "unsupported root qdisc: $kind"; return 1
    fi

    # С этого момента мы можем менять root qdisc: при аварии/сигнале — откат.
    # trap взводится ТОЛЬКО после успешной проверки kind — иначе на честном
    # отказе «неподдерживаемый qdisc» печаталось бы «Настройка прервана».
    SH_APPLY_DONE=0; SH_APPLY_IF="$if"
    trap '_sh_apply_guard' EXIT INT TERM

    # Каркас дерева
    if ! _sh_class "$if" "$SHAPE_ROOT_HANDLE" "$SHAPE_CLS_ROOT" "$SHAPE_UNLIMITED_BPS"; then
        _sh_rollback "$if"; _sh_save_last_error "class root failed"; return 1; fi
    if ! _sh_class "$if" "$SHAPE_CLS_ROOT" "$SHAPE_CLS_TOTAL" "$total" "$total"; then
        _sh_rollback "$if"; _sh_save_last_error "class total failed"; return 1; fi
    if ! _sh_class "$if" "$SHAPE_CLS_ROOT" "$SHAPE_CLS_EXEMPT" "$SHAPE_UNLIMITED_BPS"; then
        _sh_rollback "$if"; _sh_save_last_error "class exempt failed"; return 1; fi
    if ! _sh_class "$if" "$SHAPE_CLS_TOTAL" "$SHAPE_CLS_PROFILE" "$total" "$total"; then
        _sh_rollback "$if"; _sh_save_last_error "class profile failed"; return 1; fi
    if ! _sh_class "$if" "$SHAPE_CLS_TOTAL" "$SHAPE_CLS_DEFAULT" "$ip" "$ip"; then
        _sh_rollback "$if"; _sh_save_last_error "class default failed"; return 1; fi
    _sh_fq "$if" "$SHAPE_CLS_EXEMPT"
    _sh_fq "$if" "$SHAPE_CLS_PROFILE"
    _sh_fq "$if" "$SHAPE_CLS_DEFAULT"

    # Фильтры (пересоздаём наши pref'ы — идемпотентно)
    _sh_delete_filters "$if"

    # Исключения по IP/подсети → без общего потолка
    idx=0
    for item in $SH_IP_EXEMPT; do
        for port in $ports; do
            local handle
            handle=$(printf '0x%x' $(( 1 * 65536 + idx )))
            tc filter replace dev "$if" parent "$SHAPE_ROOT_HANDLE" protocol ip pref "$SHAPE_PREF_EXEMPT" \
                handle "$handle" flower ip_proto tcp src_port "$port" dst_ip "$item" \
                classid "$SHAPE_CLS_EXEMPT" 2>/dev/null || true
            idx=$(( idx + 1 ))
        done
    done

    # Персональные классы: уже изученные IP (state) + текущие активные
    if [ -s "$STATE_FILE" ]; then
        active="$({ awk '{print $1}' "$STATE_FILE" 2>/dev/null || true; sh_active_ips 2>/dev/null || true; } | grep -E '^[0-9]+(\.[0-9]+){3}$' | sort -u || true)"
    else
        active="$(sh_active_ips 2>/dev/null || true)"
    fi
    for ipaddr in $active; do
        minor="$(_sh_minor_for_ip "$ipaddr")"
        if [ -z "$minor" ]; then
            minor="$(_sh_next_minor)"
            if [ "$minor" -gt "$SHAPE_MINOR_MAX" ]; then
                skipped=$(( skipped + 1 ))
                continue
            fi
            _sh_minor_set "$ipaddr" "$minor"
        fi
        _sh_sync_ip "$if" "$ipaddr" "$minor" "$ip" "$ports" \
            || { failed=$(( failed + 1 )); log_warning "Не удалось применить лимит для ${ipaddr}"; }
    done

    # Catch-all на каждый порт → дефолт (персональный лимит)
    idx=0
    for port in $ports; do
        local handle
        handle=$(printf '0x%x' $(( 2 * 65536 + idx )))
        tc filter replace dev "$if" parent "$SHAPE_ROOT_HANDLE" protocol ip pref "$SHAPE_PREF_DEFAULT" \
            handle "$handle" flower ip_proto tcp src_port "$port" classid "$SHAPE_CLS_DEFAULT" 2>/dev/null || true
        idx=$(( idx + 1 ))
    done

    # ── Явная проверка: catch-all фильтры должны реально стоять (иначе ложный «успех») ──
    local _have=""
    _have="$(tc filter show dev "$if" parent "$SHAPE_ROOT_HANDLE" 2>/dev/null || true)"
    if [[ "$_have" != *"pref ${SHAPE_PREF_DEFAULT}"* ]]; then
        log_error "Шейпинг НЕ включён: catch-all фильтры (pref ${SHAPE_PREF_DEFAULT}) не установились"
        _sh_save_last_error "tc filter install failed"
        SH_APPLY_DONE=1; trap - EXIT INT TERM
        _sh_rollback "$if"
        return 1
    fi

    SH_ENABLED="true"; SH_LAST_ERROR=""
    if [ "$skipped" -gt 0 ]; then
        SH_LAST_ERROR="${skipped} IP без персонального класса (предел ${SHAPE_MINOR_MAX})"
    fi
    if [ "$failed" -gt 0 ]; then
        SH_LAST_ERROR="${SH_LAST_ERROR:+${SH_LAST_ERROR}; }${failed} персональных классов не создано"
    fi
    SH_APPLY_DONE=1; trap - EXIT INT TERM
    _sh_save
    _sh_write_units
    # Провал systemctl НЕ должен выглядеть успехом: иначе шейпинг «включён», но
    # не переживёт перезагрузку (restore) и не будет пересчитываться (tick).
    systemctl daemon-reload >/dev/null 2>&1 \
        || log_warning "systemctl daemon-reload не удался — юниты могут не подхватиться"
    systemctl enable "$SVC_RESTORE" >/dev/null 2>&1 \
        || log_warning "Не удалось включить автозапуск ${SVC_RESTORE} — шейпинг не восстановится после перезагрузки"
    systemctl enable --now "$TMR_TICK" >/dev/null 2>&1 \
        || log_warning "Не удалось запустить таймер ${TMR_TICK} — динамический пересчёт работать не будет"

    source="$(sh_active_source)"
    log_success "Шейпинг включён: интерфейс ${if}, порты ${ports// /,}"
    log_info "Общий потолок: $(( total / 1000000 )) Мбит/с, лимит на IPv4: $(( ip / 1000000 )) Мбит/с (режим: ${SH_MODE})"
    log_info "Источник активных IP: ${source}; персональных классов: $(awk 'END{print NR+0}' "$STATE_FILE" 2>/dev/null || echo 0)"
    [ -n "$SH_IP_EXEMPT" ] && log_info "Исключения (без общего потолка): ${SH_IP_EXEMPT}" || true
    if [ "$skipped" -gt 0 ]; then
        log_warning "${skipped} IP не получили персональный класс (предел ${SHAPE_MINOR_MAX}) — работают на общем дефолте"
    fi
    if [ "$failed" -gt 0 ]; then
        log_warning "Не удалось создать ${failed} персональных классов (см. last_error)"
    fi
    return 0
}

sh_remove() {
    local if
    if="$(sh_iface || true)"
    if [ -n "$if" ]; then
        if _sh_is_ours "$if"; then
            log_info "Удаляю дерево шейпинга с интерфейса ${if}"
            tc qdisc del dev "$if" root 2>/dev/null || true
            _sh_restore_snapshot "$if"
        elif [ -z "$(_sh_root_kind "$if")" ]; then
            _sh_restore_snapshot "$if"
        else
            log_warning "Корневой qdisc '$(_sh_root_kind "$if")' не наш — не трогаю (удалять нечего)"
        fi
    fi
    systemctl disable --now "$TMR_TICK" >/dev/null 2>&1 || true
    systemctl disable "$SVC_RESTORE" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/${SVC_TICK}" "/etc/systemd/system/${TMR_TICK}" "/etc/systemd/system/${SVC_RESTORE}" 2>/dev/null || true
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl reset-failed "$SVC_TICK" "$TMR_TICK" "$SVC_RESTORE" >/dev/null 2>&1 || true

    SH_ENABLED="false"; SH_LAST_ERROR=""
    if _sh_have_jq; then
        _sh_save >/dev/null 2>&1 || log_warning "Не удалось сохранить конфиг (${CONFIG_FILE}) — в нём может остаться enabled:true"
    fi
    rm -f "$STATE_FILE" "$META_FILE" "$SNAPSHOT_FILE" 2>/dev/null || true
    log_success "Шейпинг выключен и удалён"
    return 0
}

# ── Юниты systemd ────────────────────────────────────────────
_sh_write_units() {
    mkdir -p /etc/systemd/system
    cat > "/etc/systemd/system/${SVC_RESTORE}" <<EOF
[Unit]
Description=MTProto FIX: восстановление ограничения скорости после перезагрузки
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash ${INSTALL_DIR}/data/shaping.sh --restore

[Install]
WantedBy=multi-user.target
EOF
    cat > "/etc/systemd/system/${SVC_TICK}" <<EOF
[Unit]
Description=MTProto FIX: пересчёт динамического лимита скорости

[Service]
Type=oneshot
ExecStart=/bin/bash ${INSTALL_DIR}/data/shaping.sh --tick
EOF
    cat > "/etc/systemd/system/${TMR_TICK}" <<EOF
[Unit]
Description=MTProto FIX: периодический пересчёт лимита скорости

[Timer]
OnBootSec=45s
OnUnitActiveSec=30s
AccuracySec=5s

[Install]
WantedBy=timers.target
EOF
}

# ── Dynamic tick (рост после 2 замеров, снижение сразу, не чаще 60 c) ──
sh_tick() {
    _sh_load
    [ "$SH_ENABLED" = "true" ] || return 0
    [ "$SH_MODE" = "dynamic" ] || return 0

    if ! command -v flock >/dev/null 2>&1; then
        log_warning "flock не найден (пакет util-linux) — динамический пересчёт без блокировки"
    else
        exec 9>"$LOCK_FILE" 2>/dev/null || { log_warning "Не удалось открыть ${LOCK_FILE} — пропускаю пересчёт"; return 0; }
        flock -n 9 2>/dev/null || return 0
    fi

    local active total ipnew ipcur now last
    active="$(sh_active_ips 2>/dev/null | grep -c . || true)"
    if [ "${active:-0}" -eq 0 ]; then
        _sh_save_last_error "dynamic: активные IP не обнаружены (ss/conntrack) — лимит не пересчитан"
        return 0
    fi

    read -r total ipnew < <(_sh_rates)
    ipcur="$(_sh_meta_get ip_rate)"
    now="$(date +%s)"; last="$(_sh_meta_get last_change)"; last="${last:-0}"

    if [ -n "$ipcur" ] && [ "$ipnew" -gt "$ipcur" ]; then
        local conf
        conf="$(_sh_meta_get grow_confirm)"; conf=$(( ${conf:-0} + 1 ))
        _sh_meta_set grow_confirm "$conf"
        if [ "$conf" -lt 2 ]; then
            log_info "Рост лимита ожидает подтверждения (${conf}/2)"
            return 0
        fi
    else
        _sh_meta_set grow_confirm 0
    fi
    if [ -n "$ipcur" ] && [ "$ipnew" -lt "$ipcur" ] && [ $(( now - last )) -lt 60 ]; then
        log_info "Снижение лимита отложено (<60 c с прошлого изменения)"
        return 0
    fi

    _sh_meta_set ip_rate "$ipnew"
    _sh_meta_set grow_confirm 0
    _sh_meta_set last_change "$now"
    sh_apply >/dev/null 2>&1 || { _sh_save_last_error "dynamic apply failed"; return 0; }
    return 0
}

# ── Статус ───────────────────────────────────────────────────
# Единое человекочитаемое имя режима (чтобы не дублировать case в sh_status/_line)
_sh_mode_name() {
    case "$SH_MODE" in
        manual) printf '%s' "ручной" ;;
        fixed) printf '%s' "формула" ;;
        dynamic) printf '%s' "динамический" ;;
        *) printf '%s' "$SH_MODE" ;;
    esac
}

sh_status() {
    local if kind mode_line
    if="$(sh_iface || true)"
    kind=""
    [ -n "$if" ] && kind="$(_sh_root_kind "$if" || true)"
    case "$SH_MODE" in
        manual) mode_line="$(_sh_mode_name)" ;;
        fixed) mode_line="$(_sh_mode_name) (${SH_CHANNEL} Мбит, резерв ${SH_RESERVE}%, ${SH_USERS} польз.)" ;;
        dynamic) mode_line="$(_sh_mode_name) (канал ${SH_CHANNEL} Мбит, резерв ${SH_RESERVE}%, мин. ${SH_USERS} польз.)" ;;
        *) mode_line="$(_sh_mode_name)" ;;
    esac

    if [ "$SH_ENABLED" = "true" ] && [ -n "$if" ] && _sh_is_ours "$if"; then
        echo -e "  Статус: ${GREEN}${BOLD}включён${NC}"
    elif [ "$SH_ENABLED" = "true" ]; then
        echo -e "  Статус: ${YELLOW}${BOLD}включён в конфиге, но дерево не найдено${NC}"
    else
        echo -e "  Статус: ${RED}${BOLD}выключен${NC}"
    fi
    echo -e "  Режим: ${mode_line}"
    echo -e "  Интерфейс: ${if:-н/д} (qdisc: ${kind:-н/д}, поддерживаемые: ${ALLOWED_ROOT_QDISC//|/, })"
    echo -e "  Порты прокси: $(sh_ports || echo н/д)"
    if [ "$SH_ENABLED" = "true" ]; then
        local r total ip
        r="$(_sh_rates 2>/dev/null || echo '0 0')"; set -- $r; total="${1:-0}"; ip="${2:-0}"
        echo -e "  Общий потолок: $(( total / 1000000 )) Мбит/с; лимит на IPv4: $(( ip / 1000000 )) Мбит/с"
        echo -e "  Персональных классов: $(awk 'END{print NR+0}' "$STATE_FILE" 2>/dev/null || echo 0)"
        echo -e "  Исключения (без общего потолка): ${SH_IP_EXEMPT:-нет}"
        echo -e "  Активных IP: $(active=$(sh_active_ips 2>/dev/null | grep -c . || true); echo "${active:-0}") (источник: $(sh_active_source))"
        echo -e "  Таймер: $(systemctl is-active "$TMR_TICK" 2>/dev/null || echo unknown)"
    fi
    [ "${SH_CONFIG_BROKEN:-0}" = "1" ] && echo -e "  ${YELLOW}Конфиг повреждён (${CONFIG_FILE}) — показаны значения по умолчанию${NC}"
    [ -n "$SH_LAST_ERROR" ] && echo -e "  ${YELLOW}Последняя ошибка: ${SH_LAST_ERROR}${NC}"
    echo -e "  ${DIM}Ограничивается только исходящий IPv4-трафик; IPv6 и входящий SYN-фикс не трогаются.${NC}"
    return 0
}

sh_status_line() {
    if [ "$SH_ENABLED" != "true" ]; then
        printf '%s' "выкл"
        return 0
    fi
    local r total ip mode_line
    mode_line="$(_sh_mode_name)"
    r="$(_sh_rates 2>/dev/null || echo '0 0')"; set -- $r; total="${1:-0}"; ip="${2:-0}"
    printf '%s' "вкл (${mode_line}), общий $(( total / 1000000 )) Мбит/с, на IPv4 $(( ip / 1000000 )) Мбит/с"
}

# ── Меню ─────────────────────────────────────────────────────
_sh_prompt() { # prompt -> value
    local _p="$1" _v
    echo -en "  ${BOLD}${_p}${NC}" >&2
    { read -r _v </dev/tty; } 2>/dev/null || { echo; return 1; }
    printf '%s' "$_v"
}

_sh_menu_manual() {
    local t i
    t="$(_sh_prompt "Общий потолок для всех портов, Мбит/с [${SH_MANUAL_TOTAL}]: ")" || return 1
    [ -n "$t" ] && SH_MANUAL_TOTAL="$t"
    i="$(_sh_prompt "Лимит на каждый IPv4, Мбит/с [${SH_MANUAL_IP}]: ")" || return 1
    [ -n "$i" ] && SH_MANUAL_IP="$i"
    SH_MODE="manual"
    _sh_validate || { _pause; return 1; }
    _sh_apply_with_confirm
}

_sh_menu_formula() {
    local c r u
    c="$(_sh_prompt "Пропускная способность канала, Мбит/с [${SH_CHANNEL}]: ")" || return 1
    [ -n "$c" ] && SH_CHANNEL="$c"
    r="$(_sh_prompt "Резерв, % [${SH_RESERVE}]: ")" || return 1
    [ -n "$r" ] && SH_RESERVE="$r"
    u="$(_sh_prompt "Ожидаемое число пользователей [${SH_USERS}]: ")" || return 1
    [ -n "$u" ] && SH_USERS="$u"
    SH_MODE="fixed"
    _sh_validate || { _pause; return 1; }
    _sh_apply_with_confirm
}

_sh_menu_dynamic() {
    local c r u
    c="$(_sh_prompt "Пропускная способность канала, Мбит/с [${SH_CHANNEL}]: ")" || return 1
    [ -n "$c" ] && SH_CHANNEL="$c"
    r="$(_sh_prompt "Резерв, % [${SH_RESERVE}]: ")" || return 1
    [ -n "$r" ] && SH_RESERVE="$r"
    u="$(_sh_prompt "Минимальное ожидаемое число пользователей [${SH_USERS}]: ")" || return 1
    [ -n "$u" ] && SH_USERS="$u"
    SH_MODE="dynamic"
    _sh_validate || { _pause; return 1; }
    _sh_apply_with_confirm
}

_sh_apply_with_confirm() {
    local r total ip
    r="$(_sh_rates)"; set -- $r; total="$1"; ip="$2"
    echo ""
    log_info "Итог: общий потолок $(( total / 1000000 )) Мбит/с; на каждый IPv4 $(( ip / 1000000 )) Мбит/с"
    [ -n "$SH_IP_EXEMPT" ] && log_info "Исключения без общего потолка: ${SH_IP_EXEMPT}"
    echo -en "  ${BOLD}Применить? [Y/n]:${NC} "
    local c
    { read -r c </dev/tty; } 2>/dev/null || { echo; return 1; }
    if [ -z "$c" ] || [[ "$c" =~ ^[yY]$ ]]; then
        if sh_apply; then
            log_success "Применено"
        else
            log_error "Не удалось применить шейпинг"
        fi
    else
        log_info "Отмена"
    fi
    _pause
}

_sh_menu_exempt() {
    local v
    echo ""
    log_info "Исключения по IP/подсети не попадают под ОБЩИЙ потолок (но остаются под персональным лимитом)."
    v="$(_sh_prompt "Список IPv4/CIDR через пробел (пусто — очистить) [${SH_IP_EXEMPT}]: ")" || return 1
    SH_IP_EXEMPT="$v"
    _sh_validate || { _pause; return 1; }
    _sh_save
    log_success "Список исключений сохранён: ${SH_IP_EXEMPT:-пусто}"
    if [ "$SH_ENABLED" = "true" ]; then
        sh_apply || log_error "Не удалось применить"
    fi
    _pause
}

_sh_menu_profile_exempt() {
    echo ""
    log_warning "Исключение по ПРОФИЛЮ пока не применяется: без API движка имя профиля → IP не определить."
    echo -e "  ${GRAY}Список профилей в конфиге хранится отдельно (profile_exempt) и сейчас не влияет на шейпинг.${NC}"
    _pause
}

shaping_menu() {
    _sh_load
    while true; do
        echo ""
        echo -e "  ${CYAN}${BOLD}═══ Ограничение скорости (шейпинг) ═══${NC}"
        sh_status
        echo ""
        echo -e "  ${CYAN}[1]${NC}  Ручной лимит (общий потолок + лимит на каждый IPv4)"
        echo -e "  ${CYAN}[2]${NC}  Формула по ожидаемому числу пользователей"
        echo -e "  ${CYAN}[3]${NC}  Динамический расчёт по активным IP"
        echo -e "  ${CYAN}[4]${NC}  ${RED}Выключить и удалить шейпинг${NC}"
        echo -e "  ${CYAN}[5]${NC}  Исключения по IP/подсети"
        echo -e "  ${CYAN}[6]${NC}  Исключения по профилю ${DIM}(пока не применяется)${NC}"
        echo -e "  ${RED}[0]${NC}  Назад"
        echo ""
        echo -en "  ${BOLD}Выбор:${NC} "
        local c
        { read -r c </dev/tty; } 2>/dev/null || { echo; return 1; }
        case "$c" in
            1) _sh_menu_manual ;;
            2) _sh_menu_formula ;;
            3) _sh_menu_dynamic ;;
            4)
                echo -en "  ${BOLD}Выключить шейпинг и удалить дерево? [y/N]:${NC} "
                local y
                { read -r y </dev/tty; } 2>/dev/null || { echo; return 1; }
                if [[ "$y" =~ ^[yY]$ ]]; then sh_remove; else log_info "Отмена"; fi
                _pause
                ;;
            5) _sh_menu_exempt ;;
            6) _sh_menu_profile_exempt ;;
            0|q|Q) return 0 ;;
            *) log_error "Неверный выбор"; sleep 0.3 ;;
        esac
    done
}

# ── CLI ──────────────────────────────────────────────────────
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
case "${1:-}" in
    --remove)
        _sh_load
        sh_remove
        ;;
    --restore)
        _sh_load
        if [ "$SH_ENABLED" = "true" ]; then
            sh_apply || true
        fi
        ;;
    --apply)
        _sh_load
        # SH_ENABLED выставляет и сохраняет сам sh_apply ТОЛЬКО при успехе.
        # Предварительная установка "true" приводила к тому, что при отказе
        # валидации _sh_save_last_error записывал в конфиг enabled:true.
        sh_apply
        ;;
    --tick)
        sh_tick
        ;;
    --status)
        _sh_load
        sh_status
        ;;
    --status-line)
        _sh_load
        sh_status_line
        echo
        ;;
    "")
        if { : </dev/tty; } 2>/dev/null; then
            shaping_menu
        else
            _sh_load
            sh_status
        fi
        ;;
    *)
        echo "Использование: $0 [--remove|--restore|--apply|--tick|--status|--status-line]" >&2
        exit 2
        ;;
esac
fi
