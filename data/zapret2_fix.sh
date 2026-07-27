#!/bin/bash
# data/zapret2_fix.sh

# ── Цвета ─────────────────────────────────────────────────────
if [ -z "$RED" ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
    BLUE='\033[0;34m'; CYAN='\033[0;36m'; GRAY='\033[0;90m'
    BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
fi

# ── Логирование ─────────────────────────────────────────────
log_info()    { echo -e "  ${BLUE}[i]${NC} $1"; }
log_success() { echo -e "  ${GREEN}[✓]${NC} $1"; }
log_warn()    { echo -e "  ${YELLOW}[!]${NC} $1" >&2; }
log_error()   { echo -e "  ${RED}[✗]${NC} $1" >&2; }

# ── Путь к файлу настроек  ─────────────
INSTALL_DIR="/opt/mtpr-simple"
SETTINGS_FILE="${INSTALL_DIR}/settings.conf"
PORT_FILE="${INSTALL_DIR}/port"

# ── Свои save_settings / load_settings ──
save_settings() {
    mkdir -p "$INSTALL_DIR"
    cat > "$SETTINGS_FILE" << EOF
# MTProto Manager — настройки (дополнено Zapret2)
SERVER_IP='${SERVER_IP:-}'
SERVER_PORT='${SERVER_PORT:-}'
NFT_RATE='${NFT_RATE:-1/second}'
NFT_BURST='${NFT_BURST:-1}'
NFT_METER_TIMEOUT='${NFT_METER_TIMEOUT:-60s}'
NFT_TABLE='${NFT_TABLE:-telemt_limit}'
NFT_HOOK='${NFT_HOOK:-input}'
NFT_MODE='${NFT_MODE:-classic}'
NFT_IOS_RATE='${NFT_IOS_RATE:-15/second}'
NFT_IOS_BURST='${NFT_IOS_BURST:-30}'
NFT_OTHER_RATE='${NFT_OTHER_RATE:-54/minute}'
NFT_OTHER_BURST='${NFT_OTHER_BURST:-1}'
NFT_IOS_LIMIT_ENABLED='${NFT_IOS_LIMIT_ENABLED:-false}'
NFT_OTHER_LIMIT_ENABLED='${NFT_OTHER_LIMIT_ENABLED:-true}'
NFT_OTHER_ACTION='${NFT_OTHER_ACTION:-icmp-host-unreachable}'
NFT_IOS_DETECT='${NFT_IOS_DETECT:-fingerprint}'
TUNING_TG_CONNECT='${TUNING_TG_CONNECT:-30}'
TUNING_CLIENT_HANDSHAKE='${TUNING_CLIENT_HANDSHAKE:-90}'
TUNING_CLIENT_KEEPALIVE='${TUNING_CLIENT_KEEPALIVE:-120}'
TUNING_APPLIED='${TUNING_APPLIED:-false}'
NFT_SERVICE_ENABLED='${NFT_SERVICE_ENABLED:-false}'
IOS_FIX_APPLIED='${IOS_FIX_APPLIED:-false}'
IOS_KA_TIME='${IOS_KA_TIME:-60}'
IOS_KA_INTVL='${IOS_KA_INTVL:-15}'
IOS_KA_PROBES='${IOS_KA_PROBES:-3}'
IOS_ORIG_TIME='${IOS_ORIG_TIME:-}'
IOS_ORIG_INTVL='${IOS_ORIG_INTVL:-}'
IOS_ORIG_PROBES='${IOS_ORIG_PROBES:-}'
IOS2_FIX_APPLIED='${IOS2_FIX_APPLIED:-false}'
IOS2_EXTERNAL_PORT='${IOS2_EXTERNAL_PORT:-4443}'
IOS2_TARGET_PORT='${IOS2_TARGET_PORT:-}'
IOS2_MSS='${IOS2_MSS:-92}'
IOS2_TABLE='${IOS2_TABLE:-mtpr_ios2_fix}'
DOCKER_BRIDGE_MODE='${DOCKER_BRIDGE_MODE:-simple}'
BRIDGE_WATCH_INTERVAL='${BRIDGE_WATCH_INTERVAL:-5}'
EXTRA_RULES_COUNT='${EXTRA_RULES_COUNT:-0}'
ZAPRET2_QNUM='${ZAPRET2_QNUM:-200}'
ZAPRET2_OUT_RANGE='${ZAPRET2_OUT_RANGE:-a}'
ZAPRET2_IN_RANGE='${ZAPRET2_IN_RANGE:-a}'
ZAPRET2_SPLIT_LEN='${ZAPRET2_SPLIT_LEN:-400}'
ZAPRET2_WIN_SYNACK='${ZAPRET2_WIN_SYNACK:-1400}'
ZAPRET2_WIN_ACK='${ZAPRET2_WIN_ACK:-10}'
ZAPRET2_APPLIED='${ZAPRET2_APPLIED:-false}'
ZAPRET2_SERVICE_ENABLED='${ZAPRET2_SERVICE_ENABLED:-false}'
ZAPRET2_RELEASE_REPO='${ZAPRET2_RELEASE_REPO:-Liafanx/MTproxy-reanimation}'
ZAPRET2_RELEASE_TAG='${ZAPRET2_RELEASE_TAG:-zapret2-bundle}'
ZAPRET2_FWMARK='${ZAPRET2_FWMARK:-0x40000000}'
ZAPRET2_DEBUG='${ZAPRET2_DEBUG:-false}'
ZAPRET2_DEBUG_LOG='${ZAPRET2_DEBUG_LOG:-/var/log/nfqws2-mtproto.log}'
MEKO_OPT_APPLIED='${MEKO_OPT_APPLIED:-false}'
MEKO_ORIG_KEEPALIVE_TIME='${MEKO_ORIG_KEEPALIVE_TIME:-}'
MEKO_ORIG_KEEPALIVE_INTVL='${MEKO_ORIG_KEEPALIVE_INTVL:-}'
MEKO_ORIG_KEEPALIVE_PROBES='${MEKO_ORIG_KEEPALIVE_PROBES:-}'
MEKO_ORIG_SOMAXCONN='${MEKO_ORIG_SOMAXCONN:-}'
MEKO_ORIG_TCP_MAX_SYN_BACKLOG='${MEKO_ORIG_TCP_MAX_SYN_BACKLOG:-}'
MEKO_ORIG_NETDEV_MAX_BACKLOG='${MEKO_ORIG_NETDEV_MAX_BACKLOG:-}'
MEKO_ORIG_TCP_FASTOPEN='${MEKO_ORIG_TCP_FASTOPEN:-}'
MEKO_ORIG_FILE_MAX='${MEKO_ORIG_FILE_MAX:-}'
MEKO_ORIG_DEFAULT_QDISC='${MEKO_ORIG_DEFAULT_QDISC:-}'
MEKO_ORIG_TCP_CONGESTION='${MEKO_ORIG_TCP_CONGESTION:-}'
EOF
    # Сохраняем дополнительные правила, только если они есть
    if [ -n "$EXTRA_RULES_COUNT" ] && [ "$EXTRA_RULES_COUNT" -gt 0 ]; then
        for _i in $(seq 1 "$EXTRA_RULES_COUNT"); do
            cat >> "$SETTINGS_FILE" << EOF
EXTRA_RULES_${_i}_PORT='${EXTRA_RULES_PORT[$_i]:-}'
EXTRA_RULES_${_i}_IP='${EXTRA_RULES_IP[$_i]:-}'
EXTRA_RULES_${_i}_RATE='${EXTRA_RULES_RATE[$_i]:-1/second}'
EXTRA_RULES_${_i}_BURST='${EXTRA_RULES_BURST[$_i]:-1}'
EOF
        done
    fi
    chmod 600 "$SETTINGS_FILE"
}

load_settings() {
    [ -f "$SETTINGS_FILE" ] || return 0
    while IFS= read -r _line; do
        [[ "$_line" =~ ^[[:space:]]*# ]] && continue
        [[ "$_line" =~ ^[[:space:]]*$ ]] && continue
        if [[ "$_line" =~ ^([A-Z_][A-Z0-9_]*)=\'([^\']*)\'$ ]]; then
            local _key="${BASH_REMATCH[1]}" _val="${BASH_REMATCH[2]}"
            case "$_key" in
                SERVER_IP|SERVER_PORT|NFT_RATE|NFT_BURST|NFT_METER_TIMEOUT|\
                NFT_TABLE|NFT_HOOK|TUNING_TG_CONNECT|TUNING_CLIENT_HANDSHAKE|\
                NFT_MODE|NFT_IOS_RATE|NFT_IOS_BURST|NFT_OTHER_RATE|NFT_OTHER_BURST|NFT_OTHER_ACTION|NFT_IOS_DETECT|\
                TUNING_CLIENT_KEEPALIVE|TUNING_APPLIED|NFT_SERVICE_ENABLED|\
                IOS_FIX_APPLIED|IOS_KA_TIME|IOS_KA_INTVL|IOS_KA_PROBES|\
                IOS_ORIG_TIME|IOS_ORIG_INTVL|IOS_ORIG_PROBES|\
                IOS2_FIX_APPLIED|IOS2_EXTERNAL_PORT|\
                IOS2_TARGET_PORT|IOS2_MSS|IOS2_TABLE|\
                DOCKER_BRIDGE_MODE|BRIDGE_WATCH_INTERVAL|EXTRA_RULES_COUNT|\
                ZAPRET2_QNUM|ZAPRET2_OUT_RANGE|ZAPRET2_IN_RANGE|ZAPRET2_SPLIT_LEN|\
                ZAPRET2_WIN_SYNACK|ZAPRET2_WIN_ACK|ZAPRET2_FWMARK|\
                ZAPRET2_APPLIED|ZAPRET2_SERVICE_ENABLED|ZAPRET2_RELEASE_REPO|ZAPRET2_RELEASE_TAG|\
                ZAPRET2_DEBUG|ZAPRET2_DEBUG_LOG|\
                MEKO_OPT_APPLIED|\
                MEKO_ORIG_KEEPALIVE_TIME|MEKO_ORIG_KEEPALIVE_INTVL|MEKO_ORIG_KEEPALIVE_PROBES|\
                MEKO_ORIG_SOMAXCONN|MEKO_ORIG_TCP_MAX_SYN_BACKLOG|MEKO_ORIG_NETDEV_MAX_BACKLOG|\
                MEKO_ORIG_TCP_FASTOPEN|MEKO_ORIG_FILE_MAX|\
                MEKO_ORIG_DEFAULT_QDISC|MEKO_ORIG_TCP_CONGESTION|NFT_IOS_LIMIT_ENABLED|NFT_OTHER_LIMIT_ENABLED)
                    printf -v "$_key" '%s' "$_val"
                    ;;
                EXTRA_RULES_*_PORT)
                    local _idx="${_key#EXTRA_RULES_}"; _idx="${_idx%_PORT}"
                    EXTRA_RULES_PORT[$_idx]="$_val"
                    ;;
                EXTRA_RULES_*_IP)
                    local _idx="${_key#EXTRA_RULES_}"; _idx="${_idx%_IP}"
                    EXTRA_RULES_IP[$_idx]="$_val"
                    ;;
                EXTRA_RULES_*_RATE)
                    local _idx="${_key#EXTRA_RULES_}"; _idx="${_idx%_RATE}"
                    EXTRA_RULES_RATE[$_idx]="$_val"
                    ;;
                EXTRA_RULES_*_BURST)
                    local _idx="${_key#EXTRA_RULES_}"; _idx="${_idx%_BURST}"
                    EXTRA_RULES_BURST[$_idx]="$_val"
                    ;;
            esac
        fi
    done < "$SETTINGS_FILE"
    [[ "$EXTRA_RULES_COUNT" =~ ^[0-9]+$ ]] || EXTRA_RULES_COUNT=0
    case "$NFT_MODE" in
        classic|smart) ;;
        *) NFT_MODE="classic" ;;
    esac
    case "$NFT_OTHER_ACTION" in
        reject|drop|icmp-host-unreachable) ;;
        *) NFT_OTHER_ACTION="icmp-host-unreachable" ;;
    esac
    case "$NFT_IOS_DETECT" in
        fingerprint|ttl) ;;
        *) NFT_IOS_DETECT="fingerprint" ;;
    esac
}

# ── Zapret2 настройки по умолчанию ─────────────────────────────
ZAPRET2_DIR="/opt/zapret2"
ZAPRET2_ETC_DIR="/etc/zapret2"
ZAPRET2_BIN="${ZAPRET2_DIR}/bin/nfqws2"
ZAPRET2_LUA_DIR="${ZAPRET2_DIR}/lua"
ZAPRET2_CONF="${ZAPRET2_ETC_DIR}/mtproto.conf"
ZAPRET2_LUA="${ZAPRET2_LUA_DIR}/mtproto.lua"
ZAPRET2_SERVICE="mtpr-zapret2.service"
ZAPRET2_NFT_TABLE="MTProto"
ZAPRET2_FWMARK="0x40000000"
ZAPRET2_QNUM="200"
ZAPRET2_OUT_RANGE="a"
ZAPRET2_IN_RANGE="a"
ZAPRET2_SPLIT_LEN="400"
ZAPRET2_DEBUG="false"
ZAPRET2_DEBUG_LOG="/var/log/nfqws2-mtproto.log"
ZAPRET2_WIN_SYNACK="1400"
ZAPRET2_WIN_ACK="10"
ZAPRET2_APPLIED="false"
ZAPRET2_SERVICE_ENABLED="false"
ZAPRET2_RELEASE_REPO="Liafanx/MTproxy-reanimation"
ZAPRET2_RELEASE_TAG="zapret2-bundle"

# ── Проверка статуса Zapret2 ────────────────────────────────
zapret2_status() {
    if [ "${ZAPRET2_APPLIED:-false}" != "true" ]; then
        echo -e "${DIM}не установлен${NC}"
        return
    fi
    if ! [ -x "$ZAPRET2_BIN" ]; then
        echo -e "${YELLOW}бинарник не найден${NC}"
        return
    fi
    if systemctl is-active "$ZAPRET2_SERVICE" &>/dev/null 2>&1; then
        local _dbg=""
        [ "${ZAPRET2_DEBUG:-false}" = "true" ] && _dbg=" ${YELLOW}debug${NC}"
        echo -e "${GREEN}активен${NC} (out-range=${ZAPRET2_OUT_RANGE} len=${ZAPRET2_SPLIT_LEN} win=${ZAPRET2_WIN_SYNACK}/${ZAPRET2_WIN_ACK})${_dbg}"
    else
        echo -e "${YELLOW}установлен, остановлен${NC}"
    fi
}

# ── Определение архитектуры для загрузки бинарника ──────────
zapret2_detect_arch() {
    local _arch
    _arch=$(uname -m)
    case "$_arch" in
        x86_64)  echo "amd64" ;;
        aarch64) echo "arm64" ;;
        arm64)   echo "arm64" ;;
        *)       echo "" ;;
    esac
}

# ── Скачивание и установка бинарника nfqws2 ────────────────
zapret2_download_bundle() {
    local _arch
    _arch=$(zapret2_detect_arch)
    if [ -z "$_arch" ]; then
        log_error "Неподдерживаемая архитектура: $(uname -m)"
        return 1
    fi

    local _zapret_arch
    case "$_arch" in
        amd64) _zapret_arch="linux-x86_64" ;;
        arm64) _zapret_arch="linux-arm64" ;;
        *)     log_error "Неподдерживаемая архитектура: $_arch"; return 1 ;;
    esac

    local _ver="v1.0.3"
    local _url="https://github.com/bol-van/zapret2/releases/download/${_ver}/zapret2-${_ver}.tar.gz"
    local _tmp="/tmp/zapret2-release.tar.gz"
    local _tmpdir="/tmp/zapret2-unpack-$$"

    log_info "Архитектура: ${_arch} (${_zapret_arch})"
    log_info "Скачивание: ${_url}"

    if ! curl -fsSL --max-time 120 -o "$_tmp" "$_url"; then
        log_error "Не удалось скачать zapret2 релиз"
        rm -f "$_tmp"
        return 1
    fi

    log_info "Распаковка..."
    rm -rf "$_tmpdir"
    mkdir -p "$_tmpdir"
    if ! tar xzf "$_tmp" -C "$_tmpdir"; then
        log_error "Не удалось распаковать архив"
        rm -f "$_tmp"
        rm -rf "$_tmpdir"
        return 1
    fi
    rm -f "$_tmp"

    local _root
    _root=$(find "$_tmpdir" -maxdepth 1 -mindepth 1 -type d | head -1)
    if [ -z "$_root" ]; then
        log_error "Не удалось найти корень архива"
        rm -rf "$_tmpdir"
        return 1
    fi
    log_info "Корень архива: ${_root}"

    local _bindir="${_root}/binaries/${_zapret_arch}"
    if [ ! -d "$_bindir" ]; then
        log_error "Бинарники для ${_zapret_arch} не найдены в архиве"
        log_info "Доступные архитектуры:"
        ls -1 "${_root}/binaries/" 2>/dev/null | sed 's/^/    /'
        rm -rf "$_tmpdir"
        return 1
    fi

    if [ ! -f "${_bindir}/nfqws2" ]; then
        log_error "nfqws2 не найден в ${_bindir}"
        rm -rf "$_tmpdir"
        return 1
    fi

    local _luasrc=""
    local _lua_candidates=(
        "${_root}/nfq2/lua"
        "${_root}/lua"
        "${_root}/nfq/lua"
    )
    for _candidate in "${_lua_candidates[@]}"; do
        if [ -d "$_candidate" ]; then
            if ls "$_candidate"/zapret-lib.lua* &>/dev/null; then
                _luasrc="$_candidate"
                break
            fi
        fi
    done

    if [ -z "$_luasrc" ]; then
        log_error "Lua файлы не найдены в архиве"
        find "$_root" -name 'zapret-lib*' -type f 2>/dev/null | head -10 | sed 's/^/    /'
        rm -rf "$_tmpdir"
        return 1
    fi
    log_info "Lua файлы: ${_luasrc}"

    mkdir -p "${ZAPRET2_DIR}/bin" "${ZAPRET2_LUA_DIR}" "${ZAPRET2_ETC_DIR}"

    cp -f "${_bindir}/nfqws2" "${ZAPRET2_DIR}/bin/"
    [ -f "${_bindir}/mdig" ] && cp -f "${_bindir}/mdig" "${ZAPRET2_DIR}/bin/"
    [ -f "${_bindir}/ip2net" ] && cp -f "${_bindir}/ip2net" "${ZAPRET2_DIR}/bin/"
    chmod +x "${ZAPRET2_DIR}/bin/"*

    local _lua_files="zapret-lib zapret-antidpi zapret-auto"
    for _name in $_lua_files; do
        if [ -f "${_luasrc}/${_name}.lua" ]; then
            cp -f "${_luasrc}/${_name}.lua" "${ZAPRET2_LUA_DIR}/"
        elif [ -f "${_luasrc}/${_name}.lua.gz" ]; then
            cp -f "${_luasrc}/${_name}.lua.gz" "${ZAPRET2_LUA_DIR}/"
        else
            log_warn "Lua файл ${_name}.lua не найден"
        fi
    done

    echo "zapret2 ${_ver} ($(date -u +%Y-%m-%d))" > "${ZAPRET2_DIR}/version"

    rm -rf "$_tmpdir"

    if [ -x "$ZAPRET2_BIN" ]; then
        local _version_out
        _version_out=$("$ZAPRET2_BIN" --version 2>&1 | head -1 || echo "ok")
        log_success "nfqws2 установлен: ${_version_out}"
    else
        log_error "Бинарник nfqws2 не работает"
        return 1
    fi

    log_success "zapret2 ${_ver} установлен в ${ZAPRET2_DIR}"
    return 0
}

# ── Запись конфига Zapret2 ──────────────────────────────────
zapret2_write_conf() {
    local _port
    if [ -f "$PORT_FILE" ]; then
        _port=$(cat "$PORT_FILE" 2>/dev/null | head -1 | xargs)
    fi
    [ -z "$_port" ] && _port="443"
    mkdir -p "$ZAPRET2_ETC_DIR"
    local _debug_line=""
    if [ "${ZAPRET2_DEBUG:-false}" = "true" ]; then
        _debug_line="--debug=@${ZAPRET2_DEBUG_LOG}"
    fi

    cat > "$ZAPRET2_CONF" << EOF
--qnum ${ZAPRET2_QNUM}
--fwmark=${ZAPRET2_FWMARK}
--server
${_debug_line}
--lua-init=@${ZAPRET2_LUA_DIR}/zapret-lib.lua
--lua-init=@${ZAPRET2_LUA_DIR}/zapret-antidpi.lua
--lua-init=@${ZAPRET2_LUA_DIR}/mtproto.lua
--filter-tcp=${_port}
--out-range=${ZAPRET2_OUT_RANGE}
--in-range=${ZAPRET2_IN_RANGE}
--payload-disable=all
--lua-desync=lets_resend
--new
EOF
    log_success "Конфиг записан: ${ZAPRET2_CONF} (порт=${_port})"
}

# ── Запись Lua-скрипта для MTProto (обновлённая логика iOS bypass + ACK) ──────────
zapret2_write_lua() {
    mkdir -p "$ZAPRET2_LUA_DIR"
    cat > "$ZAPRET2_LUA" << LUAEOF
-- Zapret2 MTProto fix
-- Серверный обход: disorder + badsum + window control + iOS fwmark bypass
-- https://github.com/Liafanx/MTproxy-reanimation

function lets_resend(ctx, desync)
    -- iOS fingerprint bypass: пропускаем через fwmark без обработки
    if bitand(desync.dis.tcp.th_flags, TH_SYN + TH_ACK) == TH_SYN then
        if desync.dis.tcp.th_win == 65535 and
           #desync.dis.tcp.options == 8 and
           desync.dis.tcp.options[1].kind == 2 and
           desync.dis.tcp.options[2].kind == 1 and
           desync.dis.tcp.options[3].kind == 3 and
           desync.dis.tcp.options[4].kind == 1 and
           desync.dis.tcp.options[5].kind == 1 and
           desync.dis.tcp.options[6].kind == 8 and
           desync.dis.tcp.options[7].kind == 4 and
           desync.dis.tcp.options[8].kind == 0 then
            instance_cutoff(ctx, nil)
            desync.arg.fwmark = 0x40000
            rawsend_dissect_segmented(desync)
            return VERDICT_DROP
        end
    end

    -- SYN+ACK: запоминаем ack и зажимаем окно чтобы клиент дробил ClientHello
    if bitand(desync.dis.tcp.th_flags, TH_SYN + TH_ACK) == (TH_SYN + TH_ACK) then
        desync.track.lua_state["ack0"] = desync.dis.tcp.th_ack
        desync.dis.tcp.th_win = ${ZAPRET2_WIN_SYNACK}
        return VERDICT_MODIFY
    end

    -- Пустые ACK от сервера: зажимаем окно, но отпускаем после первого payload клиента
    if direction_check(desync) and bitand(desync.dis.tcp.th_flags, TH_SYN + TH_ACK) == (TH_ACK) then
        if desync.track and desync.dis.tcp.th_ack - desync.track.lua_state["ack0"] >= 1400 then
            instance_cutoff(ctx, true)
            desync.arg.fwmark = 0x40000
            rawsend_dissect_segmented(desync)
            return VERDICT_DROP
        end
        desync.dis.tcp.th_win = ${ZAPRET2_WIN_ACK}
        return VERDICT_MODIFY
    end

    -- Только первый data-пакет клиента
    if #desync.dis.payload == 0 or desync.track == nil or desync.track.pos.client.tcp.rseq ~= 1 then
        return VERDICT_PASS
    end

    -- Split на 3 части, средняя с badsum (disorder)
    local len = ${ZAPRET2_SPLIT_LEN}
    local first  = string.sub(desync.dis.payload, 1, len)
    local second = string.sub(desync.dis.payload, len + 1, 2 * len)
    local third  = string.sub(desync.dis.payload, 2 * len + 1)
    rawsend_payload_segmented(desync, first)
    rawsend_payload_segmented(desync, third, 2 * len)
    desync.arg["badsum"] = true
    rawsend_payload_segmented(desync, second, len)
    instance_cutoff(ctx, false)
    return VERDICT_DROP
end
LUAEOF
    log_success "Lua скрипт записан: ${ZAPRET2_LUA}"
}

# ── Создание systemd сервиса для Zapret2 (обновлённая NFT таблица) ────────────────────
zapret2_write_service() {
    local _nft_script="/usr/local/sbin/mtpr-zapret2-start.sh"
    local _port
    if [ -f "$PORT_FILE" ]; then
        _port=$(cat "$PORT_FILE" 2>/dev/null | head -1 | xargs)
    fi
    [ -z "$_port" ] && _port="443"
    local _ct_mark="0x00040000"
    local _combined_mark
    printf -v _combined_mark '0x%08x' "$(( ZAPRET2_FWMARK | _ct_mark ))"

    cat > "$_nft_script" << NFTSTART
#!/bin/bash
set -e

TABLE="${ZAPRET2_NFT_TABLE}"
FWMARK="${ZAPRET2_FWMARK}"
PORT="${_port}"
QNUM="${ZAPRET2_QNUM}"
CT_MARK="${_ct_mark}"
COMBINED_MARK="${_combined_mark}"

# Удаляем старую таблицу если есть
nft delete table ip "\$TABLE" 2>/dev/null || true

# Применяем NFT правила
nft add table ip "\$TABLE"

nft "add chain ip \$TABLE predefrag { type filter hook output priority -401; policy accept; }"
nft "add rule ip \$TABLE predefrag meta mark \$COMBINED_MARK counter accept"
nft "add rule ip \$TABLE predefrag meta mark and \$FWMARK != 0x00000000 counter notrack"

nft "add chain ip \$TABLE output { type route hook output priority mangle; policy accept; }"
nft "add rule ip \$TABLE output meta mark and \$COMBINED_MARK == \$COMBINED_MARK ct mark set \$CT_MARK counter accept"

nft "add chain ip \$TABLE postrouting { type filter hook postrouting priority srcnat + 1; policy accept; }"
nft "add rule ip \$TABLE postrouting ct mark \$CT_MARK counter accept"
nft "add rule ip \$TABLE postrouting meta mark and \$FWMARK == 0x00000000 tcp sport \$PORT counter queue flags bypass to \$QNUM"

nft "add chain ip \$TABLE prerouting { type filter hook prerouting priority mangle; policy accept; }"
nft "add rule ip \$TABLE prerouting ct state invalid counter drop"
nft "add rule ip \$TABLE prerouting ct mark \$CT_MARK counter accept"
nft "add rule ip \$TABLE prerouting meta mark and \$FWMARK == 0x00000000 tcp dport \$PORT counter queue flags bypass to \$QNUM"

echo "MTproxy-reanimation: NFT table \$TABLE applied (port=\$PORT qnum=\$QNUM fwmark=\$FWMARK ctmark=\$CT_MARK)"

# Запускаем nfqws2
exec ${ZAPRET2_BIN} @${ZAPRET2_CONF}
NFTSTART
    chmod +x "$_nft_script"

    cat > "/etc/systemd/system/${ZAPRET2_SERVICE}" << EOF
[Unit]
Description=MTproxy-reanimation Zapret2 MTProto fix
After=network-online.target nftables.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=$_nft_script
ExecStop=/usr/sbin/nft delete table ip ${ZAPRET2_NFT_TABLE}
Restart=on-failure
RestartSec=2
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    chmod 644 "/etc/systemd/system/${ZAPRET2_SERVICE}"
    systemctl daemon-reload
    systemctl reset-failed "${ZAPRET2_SERVICE}" 2>/dev/null || true
    log_success "Служба создана: ${ZAPRET2_SERVICE}"
}

# ── Применение NFT правил для Zapret2 (обновлённая таблица с ct mark) ──────────────────────
zapret2_apply_nft() {
    local _table="${ZAPRET2_NFT_TABLE}"
    local _fwmark="${ZAPRET2_FWMARK}"
    local _port
    if [ -f "$PORT_FILE" ]; then
        _port=$(cat "$PORT_FILE" 2>/dev/null | head -1 | xargs)
    fi
    [ -z "$_port" ] && _port="443"
    local _ct_mark="0x00040000"
    local _combined_mark
    printf -v _combined_mark '0x%08x' "$(( _fwmark | _ct_mark ))"

    nft delete table ip "$_table" 2>/dev/null || true
    nft add table ip "$_table"

    nft "add chain ip $_table predefrag { type filter hook output priority -401; policy accept; }"
    nft "add rule ip $_table predefrag meta mark ${_combined_mark} counter accept"
    nft "add rule ip $_table predefrag meta mark and $_fwmark != 0x00000000 counter notrack"

    nft "add chain ip $_table output { type route hook output priority mangle; policy accept; }"
    nft "add rule ip $_table output meta mark and ${_combined_mark} == ${_combined_mark} ct mark set ${_ct_mark} counter accept"

    nft "add chain ip $_table postrouting { type filter hook postrouting priority srcnat + 1; policy accept; }"
    nft "add rule ip $_table postrouting ct mark ${_ct_mark} counter accept"
    nft "add rule ip $_table postrouting meta mark and $_fwmark == 0x00000000 tcp sport ${_port} counter queue flags bypass to ${ZAPRET2_QNUM}"

    nft "add chain ip $_table prerouting { type filter hook prerouting priority mangle; policy accept; }"
    nft "add rule ip $_table prerouting ct state invalid counter drop"
    nft "add rule ip $_table prerouting ct mark ${_ct_mark} counter accept"
    nft "add rule ip $_table prerouting meta mark and $_fwmark == 0x00000000 tcp dport ${_port} counter queue flags bypass to ${ZAPRET2_QNUM}"

    log_success "NFT таблица ${_table} применена (порт=${_port} qnum=${ZAPRET2_QNUM} fwmark=${_fwmark} ctmark=${_ct_mark})"
}

# ── Удаление NFT правил Zapret2 ─────────────────────────────
zapret2_remove_nft() {
    nft delete table ip "${ZAPRET2_NFT_TABLE}" 2>/dev/null || true
    log_success "NFT таблица ${ZAPRET2_NFT_TABLE} удалена"
}

# ── Запуск Zapret2 ───────────────────────────────────────────
zapret2_start() {
    if [ ! -x "$ZAPRET2_BIN" ]; then
        log_error "Бинарник nfqws2 не найден: ${ZAPRET2_BIN}"
        return 1
    fi
    systemctl daemon-reload
    systemctl enable --now "$ZAPRET2_SERVICE" >/dev/null 2>&1 || true
    sleep 1

    if systemctl is-active "$ZAPRET2_SERVICE" &>/dev/null; then
        ZAPRET2_SERVICE_ENABLED="true"
        save_settings
        log_success "zapret2 запущен и добавлен в автозапуск"
    else
        log_error "zapret2 не запустился"
        journalctl -u "$ZAPRET2_SERVICE" -n 10 --no-pager 2>/dev/null || true
        return 1
    fi
}

# ── Запуск существующего (если остановлен) ──────────────────
zapret2_start_existing() {
    if [ "${ZAPRET2_APPLIED:-false}" != "true" ] || [ ! -x "$ZAPRET2_BIN" ]; then
        log_error "Zapret2 не установлен — используйте [1] Установить"
        return 1
    fi
    zapret2_apply_nft || return 1
    systemctl daemon-reload
    systemctl enable "$ZAPRET2_SERVICE" >/dev/null 2>&1 || true
    systemctl start "$ZAPRET2_SERVICE" 2>/dev/null || true
    sleep 1
    if systemctl is-active "$ZAPRET2_SERVICE" &>/dev/null; then
        ZAPRET2_SERVICE_ENABLED="true"
        save_settings
        log_success "zapret2 запущен"
    else
        log_error "zapret2 не запустился"
        journalctl -u "$ZAPRET2_SERVICE" -n 10 --no-pager 2>/dev/null || true
        return 1
    fi
}

# ── Остановка Zapret2 ────────────────────────────────────────
zapret2_stop() {
    systemctl stop "$ZAPRET2_SERVICE" 2>/dev/null || true
    systemctl disable "$ZAPRET2_SERVICE" 2>/dev/null || true
    nft delete table ip "${ZAPRET2_NFT_TABLE}" 2>/dev/null || true
    ZAPRET2_SERVICE_ENABLED="false"
    save_settings
    log_success "zapret2 остановлен"
}

# ── Проверка wscale и расчёт win ACK (новая функция) ──────
zapret2_check_wscale() {
    local _show_only="${1:-false}"
    local _target=1280
    local _max_allowed=1399

    local _rmem_max
    _rmem_max=$(sysctl -n net.core.rmem_max 2>/dev/null || echo "212992")
    local _tcp_rmem_max
    _tcp_rmem_max=$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null | awk '{print $3}')
    [ -z "$_tcp_rmem_max" ] && _tcp_rmem_max="$_rmem_max"

    local _buf_size
    if [ "$_tcp_rmem_max" -gt "$_rmem_max" ]; then
        _buf_size="$_tcp_rmem_max"
    else
        _buf_size="$_rmem_max"
    fi

    local _wscale=0
    local _shifted="$_buf_size"
    while [ "$_shifted" -gt 65535 ]; do
        _wscale=$((_wscale + 1))
        _shifted=$((_buf_size >> _wscale))
    done

    local _scale=$((1 << _wscale))
    local _win_ack_rec=$(( _max_allowed / _scale ))
    [ "$_win_ack_rec" -lt 1 ] && _win_ack_rec=1
    local _real_win=$((_win_ack_rec * _scale))

    local _impossible="false"
    if [ $(( 1 * _scale )) -ge 1400 ]; then
        _impossible="true"
        _win_ack_rec=1
        _real_win=$(( 1 * _scale ))
    fi

    echo ""
    echo -e "  ${BOLD}=== Проверка TCP буфера / wscale ===${NC}"
    echo ""
    echo -e "  net.core.rmem_max:       ${_rmem_max}"
    echo -e "  net.ipv4.tcp_rmem (max): ${_tcp_rmem_max}"
    echo -e "  Буфер для расчёта:       ${_buf_size}"
    echo ""
    echo -e "  Рассчитанный wscale:     ${_wscale}"
    echo -e "  2^wscale (гранулярность):${_scale} байт"
    echo -e "  Целевое окно:            < 1400 байт (идеал ~${_target})"
    echo ""

    local _current_win_ack="${ZAPRET2_WIN_ACK:-10}"
    local _current_real=$((_current_win_ack * _scale))

    echo -e "  Текущий win ACK:         ${_current_win_ack}  → реальное окно: ${_current_real} байт"
    echo -e "  Рекомендуемый win ACK:   ${_win_ack_rec}  → реальное окно: ${_real_win} байт"
    echo ""

    if [ "$_impossible" = "true" ]; then
        echo -e "  ${RED}⚠ КРИТИЧНО: 2^wscale = ${_scale} байт — минимальный шаг окна${NC}"
        echo -e "  ${RED}  уже >= 1400 байт. Дробление ClientHello невозможно!${NC}"
        echo -e "  ${RED}  Нужно уменьшить net.core.rmem_max / net.ipv4.tcp_rmem${NC}"
        echo -e "  ${RED}  чтобы ядро выбрало меньший wscale.${NC}"
        echo ""
        echo -e "  ${YELLOW}Пример для wscale=7 (подходит для win ACK=10):${NC}"
        echo -e "  ${DIM}  sysctl -w net.core.rmem_max=8388608${NC}"
        echo -e "  ${DIM}  sysctl -w net.ipv4.tcp_rmem='4096 131072 8388608'${NC}"
        echo -e "  ${DIM}  # Затем перезапустите zapret2${NC}"
    elif [ "$_current_real" -ge 1400 ]; then
        echo -e "  ${RED}⚠ Реальное окно (${_current_real} байт) >= 1400 байт${NC}"
        echo -e "  ${RED}  Дробление ClientHello НЕ произойдёт — обход не будет работать!${NC}"
    elif [ "$_real_win" -ge 512 ] && [ "$_current_real" -lt 1400 ]; then
        echo -e "  ${GREEN}✓ Реальное окно (${_current_real} байт) < 1400 — дробление будет работать${NC}"
    elif [ "$_real_win" -lt 512 ]; then
        echo -e "  ${YELLOW}⚠ Реальное окно (${_real_win} байт) — очень маленькое, возможны проблемы${NC}"
    fi

    if [ "$_impossible" != "true" ] && [ "$_show_only" != "true" ]; then
        if [ "$_current_real" -ge 1400 ] && [ "$_win_ack_rec" != "$_current_win_ack" ]; then
            echo ""
            echo -e "  ${BOLD}Необходимо изменить win ACK: ${_current_win_ack} → ${_win_ack_rec}${NC}"
            echo -e "  ${DIM}(реальное окно: ${_current_real} → ${_real_win} байт)${NC}"
            echo -en "  Применить? [Y/n]: "
            local _yn; read -r _yn
            if [[ ! "$_yn" =~ ^[nN]$ ]]; then
                ZAPRET2_WIN_ACK="$_win_ack_rec"
                save_settings
                log_success "win ACK установлен: ${_win_ack_rec} (реальное окно: ${_real_win} байт)"
                zapret2_update_config
            else
                log_info "Значение не изменено"
            fi
        elif [ "$_win_ack_rec" != "$_current_win_ack" ] && [ "$_current_real" -lt 1400 ]; then
            echo ""
            echo -e "  ${DIM}Текущее значение работает, но можно оптимизировать:${NC}"
            echo -e "  ${DIM}win ACK ${_current_win_ack} (${_current_real} байт) → ${_win_ack_rec} (${_real_win} байт)${NC}"
            echo -en "  Оптимизировать? [y/N]: "
            local _yn; read -r _yn
            if [[ "$_yn" =~ ^[yY]$ ]]; then
                ZAPRET2_WIN_ACK="$_win_ack_rec"
                save_settings
                log_success "win ACK установлен: ${_win_ack_rec} (реальное окно: ${_real_win} байт)"
                zapret2_update_config
            fi
        fi
    fi
}

# ── Установка Zapret2 (главная функция) ─────────────────────
zapret2_install() {
    echo ""
    echo -e "  ${CYAN}${BOLD}Zapret2 MTProto fix${NC}"
    echo ""
    echo -e "  ${DIM}Серверный обход для MTProto прокси.${NC}"
    echo -e "  ${DIM}Метод: disorder + badsum + TCP window control.${NC}"
    echo -e "  ${DIM}Работает на сервере — клиент ничего не ставит.${NC}"
    echo ""
    echo -e "  ${BOLD}Текущие параметры:${NC}"
    echo -e "    out-range:   ${ZAPRET2_OUT_RANGE}  ${DIM}(сколько исходящих пакетов обрабатывать)${NC}"
    echo -e "    split len:   ${ZAPRET2_SPLIT_LEN}  ${DIM}(размер частей при разрезке ClientHello)${NC}"
    echo -e "    win SYN+ACK: ${ZAPRET2_WIN_SYNACK}  ${DIM}(TCP window в SYN+ACK)${NC}"
    echo -e "    win ACK:     ${ZAPRET2_WIN_ACK}  ${DIM}(TCP window в пустых ACK)${NC}"
    echo ""

    if [ "${ZAPRET2_APPLIED:-false}" = "true" ] && [ -x "$ZAPRET2_BIN" ]; then
        echo -e "  ${YELLOW}Zapret2 уже установлен. Переустановить?${NC}"
        echo -en "  ${BOLD}Продолжить? [Y/n]:${NC} "
        local _yn; read -r _yn
        [[ "$_yn" =~ ^[nN]$ ]] && { log_info "Отменено"; return 0; }
    fi

    echo -en "  ${BOLD}Скачать и установить zapret2 bundle? [Y/n]:${NC} "
    local _yn; read -r _yn
    [[ "$_yn" =~ ^[nN]$ ]] && { log_info "Отменено"; return 0; }

    zapret2_download_bundle || return 1

    # Zapret2 fix заменяет SYN limiter — отключаем его если активен
    if [ "${NFT_SERVICE_ENABLED:-false}" = "true" ] || nft list table inet "${NFT_TABLE:-telemt_limit}" &>/dev/null 2>&1; then
        echo ""
        echo -e "  ${YELLOW}⚠ SYN limiter активен.${NC}"
        echo -e "  ${DIM}Zapret2 fix работает на уровне пакетов и заменяет SYN limiter.${NC}"
        echo -e "  ${DIM}Использование обоих одновременно не рекомендуется.${NC}"
        echo ""
        echo -en "  ${BOLD}Отключить SYN limiter? [Y/n]:${NC} "
        local _yn_syn; read -r _yn_syn
        if [[ ! "$_yn_syn" =~ ^[nN]$ ]]; then
            remove_nft_rules 2>/dev/null || true
            remove_service 2>/dev/null || true
            log_success "SYN limiter отключён"
        else
            log_warn "SYN limiter оставлен — возможны конфликты"
        fi
    fi

    zapret2_write_conf
    zapret2_write_lua
    zapret2_write_service
    zapret2_start || return 1

    ZAPRET2_APPLIED="true"
    ZAPRET2_SERVICE_ENABLED="true"
    save_settings

    # контрольная проверка
    if systemctl is-enabled "$ZAPRET2_SERVICE" >/dev/null 2>&1; then
        log_success "Автозапуск ${ZAPRET2_SERVICE} включён"
    else
        log_warn "Автозапуск ${ZAPRET2_SERVICE} не включился"
    fi

    # проверка wscale
    zapret2_check_wscale "false"

    echo ""
    log_success "Zapret2 MTProto fix установлен и запущен"
    echo ""
    echo -e "  ${BOLD}Что было сделано:${NC}"
    echo -e "    ${GREEN}✓${NC} Скачан и установлен nfqws2 в ${ZAPRET2_DIR}"
    echo -e "    ${GREEN}✓${NC} Создан конфиг ${ZAPRET2_CONF}"
    echo -e "    ${GREEN}✓${NC} Создан Lua скрипт ${ZAPRET2_LUA}"
    echo -e "    ${GREEN}✓${NC} Создана и запущена служба ${ZAPRET2_SERVICE}"
    echo -e "    ${GREEN}✓${NC} Применена NFT таблица ip ${ZAPRET2_NFT_TABLE}"
    echo ""
    echo -e "  ${DIM}Параметры можно изменить в меню [z] → Настройки.${NC}"
}

# ── Удаление Zapret2 ─────────────────────────────────────────
zapret2_remove() {
    if [ "${ZAPRET2_APPLIED:-false}" != "true" ]; then
        log_info "Zapret2 не установлен"
        return 0
    fi
    echo ""
    echo -e "  ${RED}${BOLD}Удаление Zapret2 MTProto fix${NC}"
    echo ""
    echo -e "  ${DIM}Будет удалено:${NC}"
    echo -e "  ${DIM}- Служба ${ZAPRET2_SERVICE}${NC}"
    echo -e "  ${DIM}- NFT таблица ip ${ZAPRET2_NFT_TABLE}${NC}"
    echo -e "  ${DIM}- Конфиг ${ZAPRET2_CONF}${NC}"
    echo -e "  ${DIM}- Lua скрипт ${ZAPRET2_LUA}${NC}"
    echo -e "  ${DIM}- Директория ${ZAPRET2_DIR}${NC}"
    echo ""
    echo -en "  ${BOLD}Продолжить? [y/N]:${NC} "
    local _yn; read -r _yn
    [[ "$_yn" =~ ^[yY]$ ]] || { log_info "Отменено"; return 0; }

    zapret2_stop
    systemctl disable "$ZAPRET2_SERVICE" 2>/dev/null || true
    rm -f "/etc/systemd/system/${ZAPRET2_SERVICE}"
    systemctl daemon-reload 2>/dev/null || true
    rm -f "$ZAPRET2_CONF"
    rm -f "$ZAPRET2_LUA"
    rm -rf "$ZAPRET2_DIR"
    rm -rf "$ZAPRET2_ETC_DIR"

    ZAPRET2_APPLIED="false"
    ZAPRET2_SERVICE_ENABLED="false"
    save_settings

    log_success "Zapret2 MTProto fix полностью удалён"
}

# ── Обновление конфигурации Zapret2 (пересоздаёт службу и NFT) ──
zapret2_update_config() {
    if [ "${ZAPRET2_APPLIED:-false}" != "true" ]; then
        log_warn "Zapret2 не установлен"
        return 1
    fi
    zapret2_write_conf
    zapret2_write_lua
    zapret2_write_service   # теперь пересоздаёт сервис и скрипт запуска
    zapret2_apply_nft
    systemctl daemon-reload
    systemctl enable "$ZAPRET2_SERVICE" >/dev/null 2>&1 || true
    systemctl restart "$ZAPRET2_SERVICE" 2>/dev/null || true
    sleep 1
    if systemctl is-active "$ZAPRET2_SERVICE" &>/dev/null; then
        log_success "Конфигурация обновлена, zapret2 перезапущен"
    else
        log_error "zapret2 не запустился после обновления конфигурации"
        journalctl -u "$ZAPRET2_SERVICE" -n 10 --no-pager 2>/dev/null || true
    fi
}

# ── Меню настроек Zapret2 (добавлены debug и сброс) ──────────
show_zapret2_settings_menu() {
    while true; do
        clear
        echo -e "  ${BOLD}Настройки Zapret2 MTProto fix${NC}"
        echo ""
        echo -e "  ${DIM}Изменение параметров автоматически перезаписывает конфиг и Lua,${NC}"
        echo -e "  ${DIM}затем перезапускает zapret2.${NC}"
        echo ""
        echo -e "  ${DIM}[1]${NC} out-range  [${ZAPRET2_OUT_RANGE}]"
        echo -e "        ${DIM}Формат: -<режим><число>  Примеры: -n5  -s1  -d2${NC}"
        echo -e "  ${DIM}[2]${NC} split len  [${ZAPRET2_SPLIT_LEN}]  ${DIM}(50..1000)${NC}"
        echo -e "  ${DIM}[3]${NC} win SYN+ACK [${ZAPRET2_WIN_SYNACK}]  ${DIM}(10..65535)${NC}"
        echo -e "  ${DIM}[4]${NC} win ACK     [${ZAPRET2_WIN_ACK}]  ${DIM}(1..65535)${NC}"
        echo -e "  ${DIM}[5]${NC} in-range    [${ZAPRET2_IN_RANGE}]"
        echo -e "  ${DIM}[6]${NC} NFQUEUE num [${ZAPRET2_QNUM}]  ${DIM}(0..65535)${NC}"
        echo -e "  ${DIM}[7]${NC} fwmark      [${ZAPRET2_FWMARK}]"
        echo -e "  ${DIM}[8]${NC} Debug лог   [$([ "${ZAPRET2_DEBUG:-false}" = "true" ] && echo "включён" || echo "выключен")]"
        echo ""
        echo -e "  ${DIM}[0]${NC} Назад"
        echo ""
        echo -en "  Выбор: "
        local _choice; read -r _choice
        case "$_choice" in
            1)
                echo -en "  out-range [${ZAPRET2_OUT_RANGE}]: "
                local _v; read -r _v
                [ -n "$_v" ] && { ZAPRET2_OUT_RANGE="$_v"; save_settings; zapret2_update_config; } ;;
            2)
                echo -en "  split len [${ZAPRET2_SPLIT_LEN}]: "
                local _v; read -r _v
                if [[ "$_v" =~ ^[0-9]+$ ]] && [ "$_v" -ge 50 ] && [ "$_v" -le 1000 ]; then
                    ZAPRET2_SPLIT_LEN="$_v"; save_settings; zapret2_update_config
                elif [ -n "$_v" ]; then
                    log_error "Диапазон 50..1000"
                fi ;;
            3)
                echo -en "  win SYN+ACK [${ZAPRET2_WIN_SYNACK}]: "
                local _v; read -r _v
                if [[ "$_v" =~ ^[0-9]+$ ]] && [ "$_v" -ge 10 ] && [ "$_v" -le 65535 ]; then
                    ZAPRET2_WIN_SYNACK="$_v"; save_settings; zapret2_update_config
                elif [ -n "$_v" ]; then
                    log_error "Диапазон 10..65535"
                fi ;;
            4)
                echo -en "  win ACK [${ZAPRET2_WIN_ACK}]: "
                local _v; read -r _v
                if [[ "$_v" =~ ^[0-9]+$ ]] && [ "$_v" -ge 1 ] && [ "$_v" -le 65535 ]; then
                    ZAPRET2_WIN_ACK="$_v"; save_settings; zapret2_update_config
                elif [ -n "$_v" ]; then
                    log_error "Диапазон 1..65535"
                fi ;;
            5)
                echo -en "  in-range [${ZAPRET2_IN_RANGE}]: "
                local _v; read -r _v
                [ -n "$_v" ] && { ZAPRET2_IN_RANGE="$_v"; save_settings; zapret2_update_config; } ;;
            6)
                echo -en "  NFQUEUE num [${ZAPRET2_QNUM}]: "
                local _v; read -r _v
                if [[ "$_v" =~ ^[0-9]+$ ]] && [ "$_v" -ge 0 ] && [ "$_v" -le 65535 ]; then
                    ZAPRET2_QNUM="$_v"; save_settings; zapret2_remove_nft; zapret2_apply_nft; zapret2_update_config
                elif [ -n "$_v" ]; then
                    log_error "Диапазон 0..65535"
                fi ;;
            7)
                echo -en "  fwmark [${ZAPRET2_FWMARK}]: "
                local _v; read -r _v
                [ -n "$_v" ] && { ZAPRET2_FWMARK="$_v"; save_settings; zapret2_remove_nft; zapret2_apply_nft; zapret2_update_config; } ;;
            8)
                if [ "${ZAPRET2_DEBUG:-false}" = "true" ]; then
                    echo -en "  Выключить debug? [Y/n]: "
                    local _yn; read -r _yn
                    [[ ! "$_yn" =~ ^[nN]$ ]] && { ZAPRET2_DEBUG="false"; save_settings; zapret2_update_config; }
                else
                    echo -e "  ${YELLOW}Debug лог будет записываться в ${ZAPRET2_DEBUG_LOG}${NC}"
                    echo -en "  Включить debug? [Y/n]: "
                    local _yn; read -r _yn
                    [[ ! "$_yn" =~ ^[nN]$ ]] && { ZAPRET2_DEBUG="true"; save_settings; zapret2_update_config; }
                fi ;;
            0|"") return ;;
        esac
        echo ""; read -rsn1 -p "  Нажмите любую клавишу для возврата в меню"
    done
}

# ── Главное меню Zapret2 (обновлённое, с диагностикой и сбросом) ──
show_zapret2_menu() {
    while true; do
        clear
        echo ""
        echo -e "  ${NC}${BOLD}Меню v0.2 | ${CYAN}${BOLD}V4.2 Zapret2 MTProto fix${NC}"
        echo -e "  ${DIM}══════════════════════════════"
        echo -e "  ${DIM}disorder + badsum + window control${NC}"
        echo ""
        echo -e "  Статус: $(zapret2_status)"
        echo ""

        if [ "${ZAPRET2_APPLIED:-false}" = "true" ]; then
            echo -e "  ${BOLD}Текущие параметры:${NC}"
            echo -e "    out-range:     ${GREEN}${ZAPRET2_OUT_RANGE}${NC}"
            echo -e "    in-range:      ${ZAPRET2_IN_RANGE}"
            echo -e "    split len:     ${GREEN}${ZAPRET2_SPLIT_LEN}${NC}"
            echo -e "    win SYN+ACK:   ${ZAPRET2_WIN_SYNACK}"
            echo -e "    win ACK:       ${ZAPRET2_WIN_ACK}"
            echo -e "    NFQUEUE num:   ${ZAPRET2_QNUM}"
            echo -e "    fwmark:        ${ZAPRET2_FWMARK}"
            echo -e "    Порт:          ${SERVER_PORT:-не задан}"
            echo -e "    Debug:         $([ "${ZAPRET2_DEBUG:-false}" = "true" ] && echo "${YELLOW}включён${NC}" || echo "${DIM}выключен${NC}")"
            echo ""

            local _svc_status="${DIM}не установлена${NC}"
            if systemctl is-enabled "$ZAPRET2_SERVICE" &>/dev/null 2>&1; then
                if systemctl is-active "$ZAPRET2_SERVICE" &>/dev/null 2>&1; then
                    _svc_status="${GREEN}работает${NC}"
                else
                    _svc_status="${YELLOW}остановлена${NC}"
                fi
            fi
            echo -e "  ${BOLD}Служба:${NC} ${_svc_status}"
            if nft list table ip "${ZAPRET2_NFT_TABLE}" &>/dev/null 2>&1; then
                echo -e "  ${BOLD}NFT:${NC}    ${GREEN}таблица ip ${ZAPRET2_NFT_TABLE} активна${NC}"
            else
                echo -e "  ${BOLD}NFT:${NC}    ${RED}таблица ip ${ZAPRET2_NFT_TABLE} не найдена${NC}"
            fi
            echo ""
        fi

        echo -e "  ${GREEN}[1]${NC}  Установить / Переустановить v4 zapret2 fix "
        if [ "${ZAPRET2_APPLIED:-false}" = "true" ]; then
            echo -e "  ${CYAN}[2]${NC}  Перезапустить zapret2"
            echo -e "  ${CYAN}[3]${NC}  Остановить zapret2"
            echo -e "  ${CYAN}[4]${NC}  Настройки параметров"
            echo -e "  ${CYAN}[5]${NC}  Показать конфиг + Lua"
            echo -e "  ${CYAN}[6]${NC}  Логи службы (journalctl)"
            echo -e "  ${CYAN}[7]${NC}  Диагностика очереди / конфликтов"
            echo -e "  ${CYAN}[r]${NC}  Сбросить настройки к значениям по умолчанию"
            echo -e "  ${RED}[8]${NC}  Удалить zapret2"
        fi
        echo -e "  ${DIM}[0]${NC}  Назад"
        echo ""
        echo -en "  Выбор: "
        local _choice; read -r _choice
        case "$_choice" in
            1) zapret2_install ;;
            2)
                [ "${ZAPRET2_APPLIED:-false}" = "true" ] && { zapret2_apply_nft; systemctl restart "$ZAPRET2_SERVICE" 2>/dev/null; sleep 1; systemctl status "$ZAPRET2_SERVICE" --no-pager -l 2>/dev/null || true; } ;;
            3)
                if [ "${ZAPRET2_APPLIED:-false}" = "true" ]; then
                    if systemctl is-active "$ZAPRET2_SERVICE" &>/dev/null 2>&1; then
                        zapret2_stop
                    else
                        zapret2_start_existing
                    fi
                fi ;;
            4) [ "${ZAPRET2_APPLIED:-false}" = "true" ] && show_zapret2_settings_menu ;;
            5)
                if [ "${ZAPRET2_APPLIED:-false}" = "true" ]; then
                    echo ""
                    echo -e "  ${BOLD}=== ${ZAPRET2_CONF} ===${NC}"
                    cat "$ZAPRET2_CONF" 2>/dev/null || echo "  (файл не найден)"
                    echo ""
                    echo -e "  ${BOLD}=== ${ZAPRET2_LUA} ===${NC}"
                    cat "$ZAPRET2_LUA" 2>/dev/null || echo "  (файл не найден)"
                    echo ""
                    echo -e "  ${BOLD}=== NFT table ip ${ZAPRET2_NFT_TABLE} ===${NC}"
                    nft list table ip "${ZAPRET2_NFT_TABLE}" 2>/dev/null || echo "  (таблица не найдена)"
                fi ;;
            6)
                if [ "${ZAPRET2_APPLIED:-false}" = "true" ]; then
                    echo ""
                    journalctl -u "$ZAPRET2_SERVICE" -n 30 --no-pager 2>/dev/null || log_warn "Логов нет"
                fi ;;
            7)
                if [ "${ZAPRET2_APPLIED:-false}" = "true" ]; then
                    echo ""
                    echo -e "  ${BOLD}=== systemd status ===${NC}"
                    systemctl status "$ZAPRET2_SERVICE" --no-pager -l 2>/dev/null || true
                    echo ""
                    echo -e "  ${BOLD}=== journal (последние 20 строк) ===${NC}"
                    journalctl -u "$ZAPRET2_SERVICE" -n 20 --no-pager 2>/dev/null || true
                    echo ""
                    echo -e "  ${BOLD}=== queue info ===${NC}"
                    modprobe nfnetlink_queue 2>/dev/null || true
                    cat /proc/net/netfilter/nfnetlink_queue 2>/dev/null || echo "  queue info unavailable"
                    echo ""
                    echo -e "  ${BOLD}=== nft table ip ${ZAPRET2_NFT_TABLE} ===${NC}"
                    nft list table ip "${ZAPRET2_NFT_TABLE}" 2>/dev/null || echo "  not found"
                fi ;;
            r|R)
                if [ "${ZAPRET2_APPLIED:-false}" = "true" ]; then
                    echo ""
                    echo -e "  ${BOLD}Сброс настроек Zapret2 к значениям по умолчанию:${NC}"
                    echo -e "    out-range:   a"
                    echo -e "    in-range:    a"
                    echo -e "    split len:   400"
                    echo -e "    win SYN+ACK: 1400"
                    echo -e "    win ACK:     10"
                    echo -e "    NFQUEUE:     200"
                    echo -e "    fwmark:      0x40000000"
                    echo ""
                    echo -en "  ${BOLD}Сбросить настройки и перезапустить? [y/N]:${NC} "
                    local _yn; read -r _yn
                    if [[ "$_yn" =~ ^[yY]$ ]]; then
                        ZAPRET2_OUT_RANGE="a"
                        ZAPRET2_IN_RANGE="a"
                        ZAPRET2_SPLIT_LEN="400"
                        ZAPRET2_WIN_SYNACK="1400"
                        ZAPRET2_WIN_ACK="10"
                        ZAPRET2_QNUM="200"
                        ZAPRET2_FWMARK="0x40000000"
                        save_settings
                        zapret2_update_config
                        log_success "Настройки сброшены к значениям по умолчанию"
                    else
                        log_info "Отменено"
                    fi
                fi ;;
            8) [ "${ZAPRET2_APPLIED:-false}" = "true" ] && zapret2_remove ;;
            0|"") return ;;
        esac
        echo ""; read -rsn1 -p "  Нажмите любую клавишу для возврата в меню"
    done
}

# ── Загрузка настроек при старте ────────────────────────────
load_settings
