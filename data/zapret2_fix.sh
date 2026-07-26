#!/bin/bash
# ═══════════════════════════════════════════════════════════════
#  Zapret2 MTProto fix by CHKRON
# ═══════════════════════════════════════════════════════════════

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

# ── Файл с портом (берём из основного скрипта) ─────────────
PORT_FILE="/opt/mtpr-simple/port"

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
ZAPRET2_OUT_RANGE="-s1"
ZAPRET2_IN_RANGE="-s1"
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
    _port=$(cat "$PORT_FILE" 2>/dev/null | head -1)
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

# ── Запись Lua-скрипта для MTProto ──────────────────────────
zapret2_write_lua() {
    mkdir -p "$ZAPRET2_LUA_DIR"
    cat > "$ZAPRET2_LUA" << LUAEOF
-- Zapret2 MTProto fix by CHKRON
-- Серверный обход ТСПУ: disorder + badsum + window control
-- https://github.com/Liafanx/MTproxy-reanimation

function lets_resend(ctx, desync)
    -- iOS fingerprint bypass
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
            return VERDICT_PASS
        end
    end

    -- SYN+ACK: зажимаем окно чтобы клиент дробил ClientHello
    if bitand(desync.dis.tcp.th_flags, TH_SYN + TH_ACK) == (TH_SYN + TH_ACK) then
        desync.dis.tcp.th_win = ${ZAPRET2_WIN_SYNACK}
        return VERDICT_MODIFY
    end

    -- Пустые ACK от сервера: ещё сильнее зажимаем окно
    if direction_check(desync) and bitand(desync.dis.tcp.th_flags, TH_SYN + TH_ACK) == (TH_ACK) then
        desync.dis.tcp.th_win = ${ZAPRET2_WIN_ACK}
        return VERDICT_MODIFY
    end

    -- Только первый data-пакет клиента
    if #desync.dis.payload == 0 or desync.track == nil or desync.track.pos.client.tcp.rseq ~= 1 then
        return VERDICT_PASS
    end

    -- Split на 3 части, средняя с badsum (disorder)
    local len = ${ZAPRET2_SPLIT_LEN}
    first = string.sub(desync.dis.payload, 1, len)
    second = string.sub(desync.dis.payload, len + 1, 2 * len)
    third = string.sub(desync.dis.payload, 2 * len + 1)
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

# ── Создание systemd сервиса для Zapret2 ────────────────────
zapret2_write_service() {
    local _nft_script="/usr/local/sbin/mtpr-zapret2-start.sh"
    local _port
    _port=$(cat "$PORT_FILE" 2>/dev/null | head -1)
    [ -z "$_port" ] && _port="443"

    cat > "$_nft_script" << NFTSTART
#!/bin/bash
set -e

TABLE="${ZAPRET2_NFT_TABLE}"
FWMARK="${ZAPRET2_FWMARK}"
PORT="${_port}"
QNUM="${ZAPRET2_QNUM}"

# Удаляем старую таблицу если есть
/usr/sbin/nft delete table ip "\$TABLE" 2>/dev/null || true

# Применяем NFT правила
/usr/sbin/nft add table ip "\$TABLE"

/usr/sbin/nft "add chain ip \$TABLE predefrag { type filter hook output priority -401; policy accept; }"
/usr/sbin/nft "add rule ip \$TABLE predefrag meta mark and \$FWMARK != 0x00000000 notrack"

/usr/sbin/nft "add chain ip \$TABLE postrouting { type filter hook postrouting priority srcnat + 1; policy accept; }"
/usr/sbin/nft "add rule ip \$TABLE postrouting meta mark and \$FWMARK == 0x00000000 tcp sport \$PORT queue flags bypass to \$QNUM"

/usr/sbin/nft "add chain ip \$TABLE prerouting { type filter hook prerouting priority mangle; policy accept; }"
/usr/sbin/nft "add rule ip \$TABLE prerouting meta mark and \$FWMARK == 0x00000000 tcp dport \$PORT queue flags bypass to \$QNUM"

echo "MTproxy-reanimation: NFT table \$TABLE applied (port=\$PORT qnum=\$QNUM)"

# Запускаем nfqws2
exec ${ZAPRET2_BIN} @${ZAPRET2_CONF}
NFTSTART
    chmod +x "$_nft_script"

    cat > "/etc/systemd/system/${ZAPRET2_SERVICE}" << EOF
[Unit]
Description=MTproxy-reanimation Zapret2 MTProto fix by CHKRON
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

# ── Применение NFT правил для Zapret2 ──────────────────────
zapret2_apply_nft() {
    local _table="${ZAPRET2_NFT_TABLE}"
    local _fwmark="${ZAPRET2_FWMARK}"
    local _port
    _port=$(cat "$PORT_FILE" 2>/dev/null | head -1)
    [ -z "$_port" ] && _port="443"

    /usr/sbin/nft delete table ip "$_table" 2>/dev/null || true

    /usr/sbin/nft add table ip "$_table"

    /usr/sbin/nft "add chain ip $_table predefrag { type filter hook output priority -401; policy accept; }"
    /usr/sbin/nft "add rule ip $_table predefrag meta mark and $_fwmark != 0x00000000 notrack"

    /usr/sbin/nft "add chain ip $_table postrouting { type filter hook postrouting priority srcnat + 1; policy accept; }"
    /usr/sbin/nft "add rule ip $_table postrouting meta mark and $_fwmark == 0x00000000 tcp sport ${_port} queue flags bypass to ${ZAPRET2_QNUM}"

    /usr/sbin/nft "add chain ip $_table prerouting { type filter hook prerouting priority mangle; policy accept; }"
    /usr/sbin/nft "add rule ip $_table prerouting meta mark and $_fwmark == 0x00000000 tcp dport ${_port} queue flags bypass to ${ZAPRET2_QNUM}"

    log_success "NFT таблица ${_table} применена (порт=${_port} qnum=${ZAPRET2_QNUM})"
}

# ── Удаление NFT правил Zapret2 ─────────────────────────────
zapret2_remove_nft() {
    /usr/sbin/nft delete table ip "${ZAPRET2_NFT_TABLE}" 2>/dev/null || true
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
        log_success "zapret2 запущен и добавлен в автозапуск"
        return 0
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
    zapret2_remove_nft
    log_success "zapret2 остановлен"
}

# ── Установка Zapret2 (главная функция) ─────────────────────
zapret2_install() {
    echo ""
    echo -e "  ${CYAN}${BOLD}Zapret2 MTProto fix by CHKRON${NC}"
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

    # Если SYN FIX активен (проверяем через функции из rules.sh), предлагаем отключить
    if declare -f is_syn_fix_chain_installed &>/dev/null; then
        if is_syn_fix_chain_installed || is_nft_fix_installed; then
            echo ""
            echo -e "  ${YELLOW}⚠ SYN FIX активен.${NC}"
            echo -e "  ${DIM}Zapret2 fix работает на уровне пакетов и заменяет SYN FIX.${NC}"
            echo -e "  ${DIM}Использование обоих одновременно не рекомендуется.${NC}"
            echo ""
            echo -en "  ${BOLD}Отключить SYN FIX? [Y/n]:${NC} "
            local _yn_syn; read -r _yn_syn
            if [[ ! "$_yn_syn" =~ ^[nN]$ ]]; then
                if declare -f remove_syn_fix &>/dev/null; then
                    remove_syn_fix 2>/dev/null || true
                    log_success "SYN FIX отключён"
                else
                    log_warn "Функция remove_syn_fix не найдена — пропускаем"
                fi
            else
                log_warn "SYN FIX оставлен — возможны конфликты"
            fi
        fi
    else
        log_info "Функции SYN FIX не загружены — пропускаем проверку"
    fi

    zapret2_write_conf
    zapret2_write_lua
    zapret2_write_service
    zapret2_start || return 1

    ZAPRET2_APPLIED="true"
    ZAPRET2_SERVICE_ENABLED="true"

    # СОХРАНЯЕМ В ОБЩИЙ ФАЙЛ НАСТРОЕК (как в репе Васи)
    if declare -f save_settings &>/dev/null; then
        save_settings
        log_success "Статус сохранён в общий settings.conf"
    else
        log_warn "Функция save_settings не найдена — статус может не сохраниться"
    fi

    if systemctl is-enabled "$ZAPRET2_SERVICE" >/dev/null 2>&1; then
        log_success "Автозапуск ${ZAPRET2_SERVICE} включён"
    else
        log_warn "Автозапуск ${ZAPRET2_SERVICE} не включился"
    fi

    echo ""
    log_success "Zapret2 MTProto fix by CHKRON установлен и запущен"
    echo ""
    echo -e "  ${BOLD}Что было сделано:${NC}"
    echo -e "    ${GREEN}✓${NC} Скачан и установлен nfqws2 в ${ZAPRET2_DIR}"
    echo -e "    ${GREEN}✓${NC} Создан конфиг ${ZAPRET2_CONF}"
    echo -e "    ${GREEN}✓${NC} Создан Lua скрипт ${ZAPRET2_LUA}"
    echo -e "    ${GREEN}✓${NC} Создана и запущена служба ${ZAPRET2_SERVICE}"
    echo -e "    ${GREEN}✓${NC} Применена NFT таблица ip ${ZAPRET2_NFT_TABLE}"
    echo ""
    echo -e "  ${DIM}Параметры можно изменить в меню [Z] → Настройки.${NC}"
}

# ── Удаление Zapret2 ─────────────────────────────────────────
zapret2_remove() {
    if [ "${ZAPRET2_APPLIED:-false}" != "true" ]; then
        log_info "Zapret2 не установлен"
        return 0
    fi
    echo ""
    echo -e "  ${RED}${BOLD}Удаление Zapret2 MTProto fix by CHKRON${NC}"
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

    if declare -f save_settings &>/dev/null; then
        save_settings
    fi

    log_success "Zapret2 MTProto fix полностью удалён"
}

# ── Обновление конфигурации Zapret2 (после изменения параметров) ──
zapret2_update_config() {
    if [ "${ZAPRET2_APPLIED:-false}" != "true" ]; then
        log_warn "Zapret2 не установлен"
        return 1
    fi
    zapret2_write_conf
    zapret2_write_lua
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

# ── Меню настроек Zapret2 ────────────────────────────────────
show_zapret2_settings_menu() {
    while true; do
        clear
        echo -e "  ${BOLD}Настройки Zapret2 MTProto fix by CHKRON${NC}"
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
                [ -n "$_v" ] && { ZAPRET2_OUT_RANGE="$_v"; if declare -f save_settings &>/dev/null; then save_settings; fi; zapret2_update_config; } ;;
            2)
                echo -en "  split len [${ZAPRET2_SPLIT_LEN}]: "
                local _v; read -r _v
                if [[ "$_v" =~ ^[0-9]+$ ]] && [ "$_v" -ge 50 ] && [ "$_v" -le 1000 ]; then
                    ZAPRET2_SPLIT_LEN="$_v"; if declare -f save_settings &>/dev/null; then save_settings; fi; zapret2_update_config
                elif [ -n "$_v" ]; then
                    log_error "Диапазон 50..1000"
                fi ;;
            3)
                echo -en "  win SYN+ACK [${ZAPRET2_WIN_SYNACK}]: "
                local _v; read -r _v
                if [[ "$_v" =~ ^[0-9]+$ ]] && [ "$_v" -ge 10 ] && [ "$_v" -le 65535 ]; then
                    ZAPRET2_WIN_SYNACK="$_v"; if declare -f save_settings &>/dev/null; then save_settings; fi; zapret2_update_config
                elif [ -n "$_v" ]; then
                    log_error "Диапазон 10..65535"
                fi ;;
            4)
                echo -en "  win ACK [${ZAPRET2_WIN_ACK}]: "
                local _v; read -r _v
                if [[ "$_v" =~ ^[0-9]+$ ]] && [ "$_v" -ge 1 ] && [ "$_v" -le 65535 ]; then
                    ZAPRET2_WIN_ACK="$_v"; if declare -f save_settings &>/dev/null; then save_settings; fi; zapret2_update_config
                elif [ -n "$_v" ]; then
                    log_error "Диапазон 1..65535"
                fi ;;
            5)
                echo -en "  in-range [${ZAPRET2_IN_RANGE}]: "
                local _v; read -r _v
                [ -n "$_v" ] && { ZAPRET2_IN_RANGE="$_v"; if declare -f save_settings &>/dev/null; then save_settings; fi; zapret2_update_config; } ;;
            6)
                echo -en "  NFQUEUE num [${ZAPRET2_QNUM}]: "
                local _v; read -r _v
                if [[ "$_v" =~ ^[0-9]+$ ]] && [ "$_v" -ge 0 ] && [ "$_v" -le 65535 ]; then
                    ZAPRET2_QNUM="$_v"; zapret2_remove_nft; zapret2_apply_nft; if declare -f save_settings &>/dev/null; then save_settings; fi; zapret2_update_config
                elif [ -n "$_v" ]; then
                    log_error "Диапазон 0..65535"
                fi ;;
            7)
                echo -en "  fwmark [${ZAPRET2_FWMARK}]: "
                local _v; read -r _v
                [ -n "$_v" ] && { ZAPRET2_FWMARK="$_v"; zapret2_remove_nft; zapret2_apply_nft; if declare -f save_settings &>/dev/null; then save_settings; fi; zapret2_update_config; } ;;
            8)
                if [ "${ZAPRET2_DEBUG:-false}" = "true" ]; then
                    echo -en "  Выключить debug? [Y/n]: "
                    local _yn; read -r _yn
                    [[ ! "$_yn" =~ ^[nN]$ ]] && { ZAPRET2_DEBUG="false"; if declare -f save_settings &>/dev/null; then save_settings; fi; zapret2_update_config; }
                else
                    echo -e "  ${YELLOW}Debug лог будет записываться в ${ZAPRET2_DEBUG_LOG}${NC}"
                    echo -en "  Включить debug? [Y/n]: "
                    local _yn; read -r _yn
                    [[ ! "$_yn" =~ ^[nN]$ ]] && { ZAPRET2_DEBUG="true"; if declare -f save_settings &>/dev/null; then save_settings; fi; zapret2_update_config; }
                fi ;;
            0|"") return ;;
        esac
        echo ""; read -rsn1 -p "  Нажмите любую клавишу..."
    done
}

# ── Главное меню Zapret2 ─────────────────────────────────────
show_zapret2_menu() {
    while true; do
        clear
        echo ""
        echo -e "  ${CYAN}${BOLD}Zapret2 MTProto fix by CHKRON V0.11${NC}"
        echo -e "  ${DIM}Серверный обход: disorder + badsum + window control${NC}"
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
            echo -e "    Порт:          $(cat "$PORT_FILE" 2>/dev/null || echo "не задан")"
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

        echo -e "  ${GREEN}[1]${NC}  Установить / переустановить zapret2"
        if [ "${ZAPRET2_APPLIED:-false}" = "true" ]; then
            echo -e "  ${CYAN}[2]${NC}  Перезапустить zapret2"
            echo -e "  ${CYAN}[3]${NC}  Остановить zapret2"
            echo -e "  ${CYAN}[4]${NC}  Настройки параметров"
            echo -e "  ${CYAN}[5]${NC}  Показать конфиг + Lua"
            echo -e "  ${CYAN}[6]${NC}  Логи службы (journalctl)"
            echo -e "  ${CYAN}[7]${NC}  Диагностика очереди / конфликтов"
            echo -e "  ${RED}[8]${NC}  Удалить zapret2"
        fi
        echo -e "  ${DIM}[0]${NC}  Назад"
        echo ""
        echo -en "  Выбор: "
        local _choice; read -r _choice
        case "$_choice" in
            1) zapret2_install ;;
            2) [ "${ZAPRET2_APPLIED:-false}" = "true" ] && { zapret2_apply_nft; systemctl restart "$ZAPRET2_SERVICE" 2>/dev/null; sleep 1; systemctl status "$ZAPRET2_SERVICE" --no-pager -l 2>/dev/null || true; } ;;
            3) [ "${ZAPRET2_APPLIED:-false}" = "true" ] && zapret2_stop ;;
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
            8) [ "${ZAPRET2_APPLIED:-false}" = "true" ] && zapret2_remove ;;
            0|"") return ;;
        esac
        echo ""; read -rsn1 -p "  Нажмите любую клавишу..."
    done
}

# ── Загрузка настроек Zapret2 (для обратной совместимости) ──
zapret2_load_settings() {
    # просто заглушка.
    return 0
}
