#!/bin/bash
# data/security.sh — Безопасность: TLS-отпечатки клиентов и блокировка IP/подсетей
#
# Разделы меню:
#   1) Просмотр TLS-отпечатков из API движка Telemt по четырём скоупам:
#      по отпечатку (JA3/JA4), по IP, по подсети, по пользователю.
#      В строках по IP и по подсети доступна кнопка «в блокировку».
#   2) Блокировка IP/подсетей на собственной nft-таблице mtpr_block.
#      Механизм полностью независим от движка: работает и при выключенном сборе
#      отпечатков. Чужие nft-таблицы (ip mangle/filter/MTProto/nat, inet mtpr_synfix)
#      не читаются и не изменяются.
#
# Запуск:
#   bash /opt/mtpr-simple/data/security.sh                # интерактивное меню
#   bash /opt/mtpr-simple/data/security.sh --status       # статус (неинтерактивно)
#   bash /opt/mtpr-simple/data/security.sh --block <ip|cidr>
#   bash /opt/mtpr-simple/data/security.sh --unblock <ip|cidr>
#   bash /opt/mtpr-simple/data/security.sh --restore      # применить блок-лист (юнит)
#   bash /opt/mtpr-simple/data/security.sh --disable-nft  # снять nft-таблицу (юнит)
set -euo pipefail

INSTALL_DIR="/opt/mtpr-simple"
BLOCK_LIST="${INSTALL_DIR}/ipblock.list"
BLOCK_META="${INSTALL_DIR}/ipblock.meta"
BLOCK_COUNTERS="${INSTALL_DIR}/ipblock.counters"
BLOCK_UNIT="/etc/systemd/system/mtpr-block.service"
UNIT_NAME="mtpr-block.service"

NFT_TABLE="mtpr_block"
NFT_SET4="mtpr_block4"
NFT_SET6="mtpr_block6"
NFT_CHAIN="prerouting"
NFT_PRIO="-150"

DEFAULT_LIMIT=50
SEC_LIMIT="$DEFAULT_LIMIT"
SEC_SUSP=0

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
log_info()    { echo -e "  ${BLUE}[i]${NC} $1"; }
log_success() { echo -e "  ${GREEN}[✓]${NC} $1"; }
log_error()   { echo -e "  ${RED}[✗]${NC} $1" >&2; }
log_warning() { echo -e "  ${YELLOW}[!]${NC} $1"; }

_pause() {
    echo ""
    echo -e "  ${GRAY}Нажмите любую клавишу для продолжения...${NC}"
    { read -rsn1 </dev/tty; } 2>/dev/null || { echo; return 1; }
    IFS= read -r -t 0.05 _ </dev/tty 2>/dev/null || true
}

_need_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "Требуются права root"
        return 1
    fi
    return 0
}

_sec_cut() { local s="${1:-}" n="${2:-0}"; printf '%s' "${s:0:n}"; }

_sec_ts() {
    case "${1:-}" in
        ''|0) printf '-' ; return 0 ;;
    esac
    date -d "@$1" '+%m-%d %H:%M' 2>/dev/null || printf '%s' "$1"
}

# ============================================================
#  Определение движка и его конфига
# ============================================================
SEC_KIND="none"       # docker | systemd | path | none
SEC_CFG=""            # путь к конфигу работающего движка
SEC_RESTART=""        # команда перезапуска
SEC_CTR=""            # имя docker-контейнера

_sec_engine_detect() {
    SEC_KIND="none"; SEC_CFG=""; SEC_RESTART=""; SEC_CTR=""
    local cid cname msrc m

    # 1) Запущенный docker-контейнер с bind-mount конфига в /app/config.toml
    if command -v docker >/dev/null 2>&1; then
        while IFS= read -r cid; do
            [ -n "$cid" ] || continue
            msrc=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/app/config.toml"}}{{.Source}}{{"\n"}}{{end}}{{end}}' "$cid" 2>/dev/null || true)
            [ -n "$msrc" ] || continue
            m=$(printf '%s\n' "$msrc" | sed -n '1p')
            [ -n "$m" ] || continue
            cname=$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null || true)
            cname="${cname#/}"
            [ -n "$cname" ] || cname="$cid"
            if [ -f "$m" ]; then
                SEC_KIND="docker"; SEC_CFG="$m"; SEC_CTR="$cname"
                SEC_RESTART="docker restart $cname"
                return 0
            fi
        done < <(docker ps -q 2>/dev/null || true)
    fi

    # 2) systemd-юнит telemt.service (ExecStart ... <config>.toml)
    if command -v systemctl >/dev/null 2>&1 && systemctl cat telemt.service >/dev/null 2>&1; then
        local txt exe t cfg=""
        txt=$(systemctl cat telemt.service 2>/dev/null || true)
        while IFS= read -r exe; do
            case "$exe" in
                ExecStart=*)
                    t="${exe#ExecStart=}"
                    t="${t%\"}"
                    t="${t##* }"
                    t="${t#\"}"
                    case "$t" in *.toml) cfg="$t" ;; esac
                    ;;
            esac
        done <<< "$txt"
        if [ -n "$cfg" ] && [ -f "$cfg" ]; then
            SEC_KIND="systemd"; SEC_CFG="$cfg"; SEC_RESTART="systemctl restart telemt"
            return 0
        fi
    fi

    # 3) путь из файла лаунчера (если движок запускается иначе)
    local cp=""
    if [ -s "${INSTALL_DIR}/config_path" ]; then
        cp=$(sed -n '1p' "${INSTALL_DIR}/config_path" 2>/dev/null || true)
    fi
    if [ -n "$cp" ] && [ -f "$cp" ]; then
        SEC_KIND="path"; SEC_CFG="$cp"; SEC_RESTART=""
        return 0
    fi

    SEC_KIND="none"; SEC_CFG=""; SEC_RESTART=""
    return 1
}

_sec_engine_desc() {
    case "$SEC_KIND" in
        docker)  printf 'docker-контейнер «%s», конфиг %s' "$SEC_CTR" "$SEC_CFG" ;;
        systemd) printf 'systemd-юнит telemt.service, конфиг %s' "$SEC_CFG" ;;
        path)    printf 'конфиг %s (способ перезапуска не определён)' "$SEC_CFG" ;;
        *)       printf 'Telemt не обнаружен (не запущен или не установлен)' ;;
    esac
}

# ============================================================
#  Разбор TOML-конфига
# ============================================================
# _sec_cfg_get <file> <section> <key>
_sec_cfg_get() {
    local f="$1" sec="$2" key="$3"
    [ -f "$f" ] || return 1
    awk -v want="$sec" -v k="$key" '
        function secname(l,   s){ s=l; sub(/^[[:space:]]*/,"",s); if (s !~ /^\[/) return ""; sub(/^\[/,"",s); sub(/\].*/,"",s); return s }
        { line[NR]=$0 }
        END{
            cur=""
            for(i=1;i<=NR;i++){ s=secname(line[i]); if(s!="") cur=s
                if(cur==want){ t=line[i]; sub(/^[[:space:]]*/,"",t)
                    if(index(t,k)==1 && substr(t,length(k)+1,1) ~ /[[:space:]]/){ r=substr(t,length(k)+1); sub(/^[[:space:]]*=[[:space:]]*/,"",r)
                        sub(/^"/,"",r); sub(/"$/,"",r); sub(/[[:space:]]+$/,"",r); print r; exit }
                }
            }
        }' "$f" 2>/dev/null
}

# _sec_cfg_set <file> <section> <key> <value>
_sec_cfg_set() {
    local f="$1" sec="$2" key="$3" val="$4" tmp perm
    [ -f "$f" ] || return 1
    tmp=$(mktemp "${f}.tmp.XXXXXX") || return 1
    if ! awk -v want="$sec" -v k="$key" -v v="$val" '
        function secname(l,   s){ s=l; sub(/^[[:space:]]*/,"",s); if (s !~ /^\[/) return ""; sub(/^\[/,"",s); sub(/\].*/,"",s); return s }
        { line[NR]=$0 }
        END{
            sh=0; cur=""
            for(i=1;i<=NR;i++){ s=secname(line[i]); if(s!="") cur=s; if(cur==want){ sh=i; break } }
            if(sh==0){ print ""; print "["want"]"; print k" = "v; exit 0 }
            e=NR
            for(i=sh+1;i<=NR;i++){ if(secname(line[i])!=""){ e=i-1; break } }
            ki=0
            for(i=sh+1;i<=e;i++){ t=line[i]; sub(/^[[:space:]]*/,"",t); if(t ~ "^"k"[[:space:]]*="){ ki=i; break } }
            if(ki>0){ line[ki]=k" = "v } else { ins=sh+1 }
            for(i=1;i<=NR;i++){ if(ins>0 && i==ins) print k" = "v; print line[i] }
        }' "$f" > "$tmp"; then
        rm -f "$tmp"; return 1
    fi
    perm=$(stat -c '%a' "$f" 2>/dev/null || echo 644)
    mv -f "$tmp" "$f" || { rm -f "$tmp"; return 1; }
    chmod "$perm" "$f" 2>/dev/null || true
    return 0
}

# _sec_cfg_drop_section <file> <section>
_sec_cfg_drop_section() {
    local f="$1" sec="$2" tmp perm
    [ -f "$f" ] || return 0
    tmp=$(mktemp "${f}.tmp.XXXXXX") || return 1
    if ! awk -v want="$sec" '
        function secname(l,   s){ s=l; sub(/^[[:space:]]*/,"",s); if (s !~ /^\[/) return ""; sub(/^\[/,"",s); sub(/\].*/,"",s); return s }
        { line[NR]=$0 }
        END{
            start=0; stop=0; cur=""
            for(i=1;i<=NR;i++){ s=secname(line[i]); if(s!="") cur=s
                if(cur==want && start==0){ start=i; stop=NR
                    for(j=i+1;j<=NR;j++){ if(secname(line[j])!=""){ stop=j-1; break } }
                    break }
            }
            for(i=1;i<=NR;i++){ if(start>0 && i>=start && i<=stop) continue; print line[i] }
        }' "$f" > "$tmp"; then
        rm -f "$tmp"; return 1
    fi
    perm=$(stat -c '%a' "$f" 2>/dev/null || echo 644)
    mv -f "$tmp" "$f" || { rm -f "$tmp"; return 1; }
    chmod "$perm" "$f" 2>/dev/null || true
    return 0
}

# ============================================================
#  API движка
# ============================================================
_sec_api_addr() {
    local cfg="${1:-}" listen="" host port
    if [ -n "$cfg" ]; then
        listen=$(_sec_cfg_get "$cfg" "server.api" "listen" || true)
    fi
    [ -n "$listen" ] || listen="127.0.0.1:9091"
    host="${listen%:*}"
    port="${listen##*:}"
    host="${host#[}"; host="${host%]}"
    case "$host" in ''|0.0.0.0|::|'*') host="127.0.0.1" ;; esac
    case "$port" in ''|*[!0-9]*) port="9091" ;; esac
    printf '%s:%s' "$host" "$port"
}

_sec_api_json() {
    local limit="${1:-$SEC_LIMIT}" url addr
    command -v curl >/dev/null 2>&1 || return 1
    addr=$(_sec_api_addr "$SEC_CFG")
    url="http://${addr}/v1/runtime/tls-fingerprints?limit=${limit}"
    curl -fsS --max-time 5 "$url" 2>/dev/null
}

# Возвращает: enabled | disabled:<reason> | no-engine | no-api | no-curl | no-jq | bad-json
_sec_api_state() {
    _sec_engine_detect >/dev/null 2>&1 || true
    if [ "$SEC_KIND" = "none" ] && [ -z "$SEC_CFG" ]; then
        printf 'no-engine'; return 0
    fi
    if ! command -v curl >/dev/null 2>&1; then printf 'no-curl'; return 0; fi
    if ! command -v jq >/dev/null 2>&1; then printf 'no-jq'; return 0; fi
    local json ok en reason
    if ! json=$(_sec_api_json "$DEFAULT_LIMIT"); then
        printf 'no-api'; return 0
    fi
    ok=$(printf '%s' "$json" | jq -r 'if .ok == true then "1" else "0" end' 2>/dev/null || echo 0)
    if [ "$ok" != "1" ]; then printf 'bad-json'; return 0; fi
    en=$(printf '%s' "$json" | jq -r 'if .data.enabled == true then "1" else "0" end' 2>/dev/null || echo 0)
    if [ "$en" = "1" ]; then
        printf 'enabled'
    else
        reason=$(printf '%s' "$json" | jq -r '.data.reason // "feature_disabled"' 2>/dev/null || echo feature_disabled)
        printf 'disabled:%s' "$reason"
    fi
    return 0
}

# TSV-строки скоупа: ключ, ja4, ja3, total, auth, bad, first, last
_sec_api_rows() {
    local scope="$1" susp="$2" json
    json=$(_sec_api_json "$SEC_LIMIT") || return 1
    printf '%s' "$json" | jq -r --arg sc "$scope" --argjson susp "$susp" '
        (.data.data[$sc] // [])[]
        | select(($susp == 0) or (((.bad_or_probe // 0) > 0) and ((.auth_success // 0) == 0)))
        | [ (.scope // .ja4 // "-"), (.ja4 // "-"), (.ja3 // "-"),
            (.total // 0), (.auth_success // 0), (.bad_or_probe // 0),
            (.first_seen_epoch_secs // 0), (.last_seen_epoch_secs // 0) ] | @tsv' 2>/dev/null
}

# TSV: limit, retention, capacity, dropped, parse_error, entries
_sec_api_meta() {
    local json
    json=$(_sec_api_json "$SEC_LIMIT") || return 1
    printf '%s' "$json" | jq -r '[ (.data.data.limit // 0), (.data.data.retention_secs // 0),
        (.data.data.capacity // 0), (.data.data.dropped_total // 0),
        (.data.data.parse_error_total // 0), ((.data.data.by_fingerprint // []) | length) ] | @tsv' 2>/dev/null
}

_sec_collect_line() {
    local st meta lim ret dr pe ent
    st=$(_sec_api_state)
    case "$st" in
        enabled)
            meta=$(_sec_api_meta 2>/dev/null || true)
            IFS=$'\t' read -r lim ret _ dr pe ent <<< "$meta" || true
            printf 'сбор ВКЛ (записей %s, лимит Top-N %s, хранение %sс, отброшено %s, ошибок разбора %s)' \
                "${ent:-0}" "${lim:-0}" "${ret:-0}" "${dr:-0}" "${pe:-0}"
            ;;
        disabled:*) printf 'сбор ВЫКЛ (%s) — включить: пункт [5]' "${st#disabled:}" ;;
        no-engine)  printf 'движок не обнаружен' ;;
        no-api)     printf 'API недоступен (проверьте [server.api] enabled/listen)' ;;
        no-curl)    printf 'curl не найден' ;;
        no-jq)      printf 'jq не найден (нужен для разбора ответа API)' ;;
        bad-json)   printf 'API вернул некорректный ответ' ;;
        *)          printf 'состояние: %s' "$st" ;;
    esac
}

_sec_collect_explain() {
    case "$1" in
        disabled:*) log_warning "Сбор TLS-отпечатков выключен в движке (причина: ${1#disabled:})."
                    log_info "Включить можно пунктом [5] (правка конфига + перезапуск движка)." ;;
        no-engine)  log_warning "Движок Telemt не обнаружен — данных нет." ;;
        no-api)     log_error "API движка недоступен. Проверьте [server.api] enabled = true и listen в конфиге движка." ;;
        no-curl)    log_error "Не найден curl." ;;
        no-jq)      log_error "Не найден jq — установите: apt-get install -y jq" ;;
        bad-json)   log_error "API вернул некорректный ответ." ;;
        *)          log_error "Неизвестное состояние API: $1" ;;
    esac
}

# ============================================================
#  Перезапуск движка и управление сбором
# ============================================================
_sec_engine_restart() {
    [ -n "$SEC_RESTART" ] || return 1
    case "$SEC_RESTART" in
        docker\ restart\ *)   docker restart "${SEC_RESTART#docker restart }" >/dev/null 2>&1 || return 1 ;;
        systemctl\ restart\ *) systemctl restart "${SEC_RESTART#systemctl restart }" >/dev/null 2>&1 || return 1 ;;
        *)
            local -a _r=()
            read -r -a _r <<< "$SEC_RESTART" || true
            [ "${#_r[@]}" -gt 0 ] || return 1
            "${_r[@]}" >/dev/null 2>&1 || return 1
            ;;
    esac
    sleep 3
    return 0
}

_sec_wait_api() {
    local want="$1" i out
    for i in $(seq 1 20); do
        out=$(_sec_api_state)
        case "$want" in
            enabled) [ "$out" = "enabled" ] && { printf '%s' "$out"; return 0; } ;;
            disabled) case "$out" in disabled:*|no-engine) printf '%s' "$out"; return 0 ;; esac ;;
        esac
        sleep 1
    done
    printf '%s' "$out"
    return 1
}

_sec_collect_enable() {
    _sec_engine_detect >/dev/null 2>&1 || true
    if [ "$SEC_KIND" = "none" ]; then
        log_error "Движок Telemt не обнаружен — включать нечего"; return 1
    fi
    if [ -z "$SEC_RESTART" ]; then
        log_error "Способ перезапуска движка не определён — конфиг не правлю"; return 1
    fi
    local st; st=$(_sec_api_state)
    if [ "$st" = "enabled" ]; then
        log_info "Сбор отпечатков уже включён"; return 0
    fi
    local bak
    bak="${SEC_CFG}.bak-security.$(date +%Y%m%d%H%M%S)"
    cp "$SEC_CFG" "$bak" || { log_error "Не удалось сделать бэкап конфига"; return 1; }
    log_info "Бэкап конфига: $bak"
    _sec_cfg_drop_section "$SEC_CFG" "tls_fingerprints" || true
    if ! _sec_cfg_set "$SEC_CFG" "server.api" "runtime_edge_enabled" "true"; then
        log_error "Не удалось изменить конфиг"
        cp "$bak" "$SEC_CFG" 2>/dev/null || true
        return 1
    fi
    log_info "Конфиг изменён: [server.api] runtime_edge_enabled = true"
    if ! _sec_engine_restart; then
        log_error "Перезапуск движка не удался — откатываю конфиг"
        cp "$bak" "$SEC_CFG" 2>/dev/null || true
        _sec_engine_restart >/dev/null 2>&1 || true
        return 1
    fi
    local out
    if out=$(_sec_wait_api enabled); then
        log_success "Сбор отпечатков включён (подтверждено API: enabled=true)"
        return 0
    fi
    log_error "API не подтвердил enabled=true (состояние: ${out:-нет ответа}) — откатываю конфиг"
    cp "$bak" "$SEC_CFG" 2>/dev/null || true
    _sec_engine_restart >/dev/null 2>&1 || true
    return 1
}

_sec_collect_disable() {
    _sec_engine_detect >/dev/null 2>&1 || true
    if [ "$SEC_KIND" = "none" ]; then
        log_error "Движок Telemt не обнаружен"; return 1
    fi
    if [ -z "$SEC_RESTART" ]; then
        log_error "Способ перезапуска движка не определён — конфиг не правлю"; return 1
    fi
    local st; st=$(_sec_api_state)
    case "$st" in
        disabled:*|no-engine) log_info "Сбор отпечатков уже выключен"; return 0 ;;
    esac
    local bak
    bak="${SEC_CFG}.bak-security.$(date +%Y%m%d%H%M%S)"
    cp "$SEC_CFG" "$bak" || { log_error "Не удалось сделать бэкап конфига"; return 1; }
    log_info "Бэкап конфига: $bak"
    if ! _sec_cfg_set "$SEC_CFG" "server.api" "runtime_edge_enabled" "false"; then
        log_error "Не удалось изменить конфиг"
        cp "$bak" "$SEC_CFG" 2>/dev/null || true
        return 1
    fi
    log_info "Конфиг изменён: [server.api] runtime_edge_enabled = false"
    if ! _sec_engine_restart; then
        log_error "Перезапуск движка не удался — откатываю конфиг"
        cp "$bak" "$SEC_CFG" 2>/dev/null || true
        _sec_engine_restart >/dev/null 2>&1 || true
        return 1
    fi
    local out
    if out=$(_sec_wait_api disabled); then
        log_success "Сбор отпечатков выключен (API: ${out})"
        return 0
    fi
    log_warning "API всё ещё отдаёт данные (состояние: ${out:-нет ответа}) — проверьте конфиг движка вручную"
    return 1
}

# ============================================================
#  Метаданные блокировки
# ============================================================
_sec_meta_get() {
    local k="$1"
    [ -f "$BLOCK_META" ] || return 1
    awk -F= -v k="$k" '$1==k { sub(/^[^=]*=/,""); print; exit }' "$BLOCK_META" 2>/dev/null || true
}

_sec_meta_set() {
    local k="$1" v="$2" tmp
    mkdir -p "$(dirname "$BLOCK_META")" 2>/dev/null || true
    [ -f "$BLOCK_META" ] || : > "$BLOCK_META"
    tmp=$(mktemp "${BLOCK_META}.XXXXXX") || return 1
    if ! awk -F= -v k="$k" -v v="$v" '
        BEGIN{ done=0 }
        { if ($1==k) { if(done==0){ print k"="v; done=1 } ; next } print }
        END{ if(done==0) print k"="v }' "$BLOCK_META" > "$tmp"; then
        rm -f "$tmp"; return 1
    fi
    mv -f "$tmp" "$BLOCK_META" || { rm -f "$tmp"; return 1; }
    return 0
}

_sec_list_init() {
    mkdir -p "$(dirname "$BLOCK_LIST")" 2>/dev/null || true
    if [ ! -f "$BLOCK_LIST" ]; then
        {
            printf '# Список блокировки IP/подсетей (по одной записи на строку)\n'
            printf '# Формат: IPv4/IPv6-адрес или CIDR. Строки с # игнорируются.\n'
        } > "$BLOCK_LIST" 2>/dev/null || true
    fi
    [ -f "$BLOCK_META" ] || {
        printf 'enabled=0\naction=drop\n' > "$BLOCK_META" 2>/dev/null || true
    }
}

_sec_list_has() {
    [ -f "$BLOCK_LIST" ] || return 1
    grep -Fxq -- "$1" "$BLOCK_LIST" 2>/dev/null
}

_sec_list_entries() {
    [ -f "$BLOCK_LIST" ] || return 0
    awk '{ sub(/#.*$/,""); gsub(/^[[:space:]]+|[[:space:]]+$/,""); if (length($0)>0) print }' "$BLOCK_LIST" 2>/dev/null
}

_sec_list_count() {
    [ -f "$BLOCK_LIST" ] || { printf '0'; return 0; }
    awk '{ sub(/#.*$/,""); gsub(/^[[:space:]]+|[[:space:]]+$/,""); if (length($0)>0) c++ } END{ print c+0 }' "$BLOCK_LIST" 2>/dev/null || printf '0'
}

# ── Валидация IPv4/IPv6/CIDR ─────────────────────────────────
# Строгая проверка IPv6-адреса (без маски): не более одного «::»,
# группы по 1..4 hex-цифры, суммарно ровно 8 групп с учётом сжатия.
_sec_val_ip6() {
    local a="${1:-}" re
    case "$a" in ''|*[!0-9a-fA-F:]*) return 1 ;; esac
    re='^(([0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}'
    re="${re}|([0-9a-fA-F]{1,4}:){1,7}:"
    re="${re}|([0-9a-fA-F]{1,4}:){1,6}:[0-9a-fA-F]{1,4}"
    re="${re}|([0-9a-fA-F]{1,4}:){1,5}(:[0-9a-fA-F]{1,4}){1,2}"
    re="${re}|([0-9a-fA-F]{1,4}:){1,4}(:[0-9a-fA-F]{1,4}){1,3}"
    re="${re}|([0-9a-fA-F]{1,4}:){1,3}(:[0-9a-fA-F]{1,4}){1,4}"
    re="${re}|([0-9a-fA-F]{1,4}:){1,2}(:[0-9a-fA-F]{1,4}){1,5}"
    re="${re}|([0-9a-fA-F]{1,4}:)(:[0-9a-fA-F]{1,4}){1,6}"
    re="${re}|:(:[0-9a-fA-F]{1,4}){1,7}"
    re="${re}|::)$"
    [[ "$a" =~ $re ]]
}

_sec_val_ip() {
    local s="${1:-}" ip mask part
    [ -n "$s" ] || return 1
    if [[ "$s" == */* ]]; then
        ip="${s%%/*}"; mask="${s#*/}"
        [ -n "$ip" ] && [ -n "$mask" ] || return 1
        case "$mask" in *[!0-9]*) return 1 ;; esac
        [ "${#mask}" -le 3 ] || return 1
        # Маска 0 (/0) блокирует ВЕСЬ трафик, включая SSH — само-лок-аут.
        # Отсекаем и «0», и ведущие нули («00», «09»).
        case "$mask" in 0|0*) return 1 ;; esac
    else
        ip="$s"; mask=""
    fi
    case "$ip" in
        *:*)
            _sec_val_ip6 "$ip" || return 1
            if [ -n "$mask" ]; then [ "$mask" -le 128 ] || return 1; fi
            return 0
            ;;
        *)
            case "$ip" in .*|*.|*..*) return 1 ;; esac
            local IFS='.'
            local -a o=()
            IFS='.' read -r -a o <<< "$ip"
            [ "${#o[@]}" -eq 4 ] || return 1
            for part in "${o[@]}"; do
                case "$part" in ''|*[!0-9]*) return 1 ;; esac
                [ "${#part}" -le 3 ] || return 1
                case "$part" in 0) ;; 0*) return 1 ;; esac
                [ "$part" -le 255 ] || return 1
            done
            if [ -n "$mask" ]; then [ "$mask" -le 32 ] || return 1; fi
            return 0
            ;;
    esac
}

# Запись вида <addr>/0 блокирует ВСЁ (включая SSH) — это само-лок-аут.
_sec_is_world() {
    case "${1:-}" in
        */0) return 0 ;;
        *)   return 1 ;;
    esac
}

_sec_ip4_int() {
    local ip="$1" a b c d
    IFS='.' read -r a b c d <<< "$ip" || return 1
    case "$a$b$c$d" in *[!0-9]*) return 1 ;; esac
    printf '%s' "$(( (a<<24) + (b<<16) + (c<<8) + d ))"
}

# _sec_cover_by <ip> -> печатает CIDR из списка, который покрывает ip (IPv4)
_sec_cover_by() {
    local ip="${1:-}" entry e_ip e_mask m net ipi ei
    [ -f "$BLOCK_LIST" ] || return 1
    case "$ip" in ''|*:*) return 1 ;; esac
    ipi=$(_sec_ip4_int "$ip") || return 1
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        case "$entry" in
            */*) ;;
            *) continue ;;
        esac
        case "$entry" in *:*) continue ;; esac
        e_ip="${entry%%/*}"; e_mask="${entry##*/}"
        case "$e_mask" in ''|*[!0-9]*) continue ;; esac
        [ "$e_mask" -le 32 ] || continue
        ei=$(_sec_ip4_int "$e_ip") || continue
        if [ "$e_mask" -eq 0 ]; then
            m=0
        else
            m=$(( (0xFFFFFFFF << (32 - e_mask)) & 0xFFFFFFFF ))
        fi
        net=$(( ei & m ))
        if [ $(( ipi & m )) -eq "$net" ]; then
            printf '%s' "$entry"
            return 0
        fi
    done < <(_sec_list_entries)
    return 1
}

# ============================================================
#  nft: таблица mtpr_block
# ============================================================
_sec_nft_verdict() {
    case "${1:-drop}" in
        reject) printf 'reject with tcp reset' ;;
        *)      printf 'drop' ;;
    esac
}

_sec_nft_present() {
    command -v nft >/dev/null 2>&1 || return 1
    nft list table inet "$NFT_TABLE" >/dev/null 2>&1
}

_sec_nft_create_table() {
    local action="${1:-drop}" verdict
    verdict=$(_sec_nft_verdict "$action")
    nft -f - <<EOF
table inet ${NFT_TABLE} {
    set ${NFT_SET4} {
        type ipv4_addr
        flags interval
        counter
    }
    set ${NFT_SET6} {
        type ipv6_addr
        flags interval
        counter
    }
    chain ${NFT_CHAIN} {
        type filter hook prerouting priority ${NFT_PRIO}; policy accept;
        ip saddr @${NFT_SET4} counter ${verdict}
        ip6 saddr @${NFT_SET6} counter ${verdict}
    }
}
EOF
}

_sec_nft_create_chain() {
    local action="${1:-drop}" verdict
    verdict=$(_sec_nft_verdict "$action")
    nft -f - <<EOF
table inet ${NFT_TABLE} {
    chain ${NFT_CHAIN} {
        type filter hook prerouting priority ${NFT_PRIO}; policy accept;
        ip saddr @${NFT_SET4} counter ${verdict}
        ip6 saddr @${NFT_SET6} counter ${verdict}
    }
}
EOF
}

# Синхронизирует элементы одного набора (комма-список желаемых).
# Все изменения применяются ОДНИМ `nft -f <файл>` (батч): не упираемся в
# ARG_MAX на больших списках и не делаем по вызову nft на элемент.
_sec_nft_sync_set() {
    local setname="$1" want="$2" have add del e norm out
    local -A W=()
    local -A H=()
    if [ -n "$want" ]; then
        local IFS=','
        local -a parts=()
        IFS=',' read -r -a parts <<< "$want"
        for e in "${parts[@]}"; do
            norm="$e"
            norm="${norm#"${norm%%[![:space:]]*}"}"
            norm="${norm%"${norm##*[![:space:]]}"}"
            [ -n "$norm" ] && W["$norm"]=1
        done
    fi
    have=$(nft -j list set inet "$NFT_TABLE" "$setname" 2>/dev/null | jq -r '
        .nftables[]? | select(.set) | .set.elem[]?
        | ( .elem.val
            | if type == "object" then (((.prefix.addr // "?") + "/" + ((.prefix.len // 0) | tostring)))
              else tostring end )' 2>/dev/null || true)
    if [ -n "$have" ]; then
        while IFS= read -r e; do
            [ -n "$e" ] && H["$e"]=1
        done <<< "$have"
    fi
    add=""; del=""
    for e in "${!W[@]}"; do
        [ -n "${H[$e]:-}" ] || add="${add:+$add, }$e"
    done
    for e in "${!H[@]}"; do
        [ -n "${W[$e]:-}" ] || del="${del:+$del, }$e"
    done
    [ -n "$add$del" ] || return 0
    out=$(mktemp) || return 1
    {
        if [ -n "$del" ]; then
            printf 'delete element inet %s %s { %s }\n' "$NFT_TABLE" "$setname" "$del"
        fi
        if [ -n "$add" ]; then
            printf 'add element inet %s %s { %s }\n' "$NFT_TABLE" "$setname" "$add"
        fi
    } > "$out" || { rm -f "$out"; return 1; }
    if ! nft -f "$out" >/dev/null 2>&1; then
        rm -f "$out"
        return 1
    fi
    rm -f "$out"
    return 0
}

_sec_nft_sync() {
    command -v nft >/dev/null 2>&1 || { log_error "nft не найден"; return 1; }
    _sec_list_init
    local action; action=$(_sec_meta_get action || true)
    [ -n "$action" ] || action="drop"
    if ! _sec_nft_present; then
        _sec_nft_create_table "$action" || { log_error "Не удалось создать nft-таблицу ${NFT_TABLE}"; return 1; }
    fi
    local v4="" v6="" line e
    while IFS= read -r line || [ -n "$line" ]; do
        e="${line%%#*}"
        e="${e#"${e%%[![:space:]]*}"}"
        e="${e%"${e##*[![:space:]]}"}"
        [ -n "$e" ] || continue
        if _sec_is_world "$e"; then
            log_warning "Пропущена запись, блокирующая ВЕСЬ трафик (маска 0): $e"
            continue
        fi
        if ! _sec_val_ip "$e"; then
            log_warning "Пропущена некорректная запись: $e"
            continue
        fi
        case "$e" in
            *:*) v6="${v6:+$v6, }$e" ;;
            *)   v4="${v4:+$v4, }$e" ;;
        esac
    done < "$BLOCK_LIST"
    _sec_nft_sync_set "$NFT_SET4" "$v4" || { log_error "Ошибка синхронизации набора IPv4"; return 1; }
    _sec_nft_sync_set "$NFT_SET6" "$v6" || log_warning "Не удалось синхронизировать набор IPv6 — блокировка IPv4 при этом работает"
    return 0
}

_sec_nft_delete() {
    if _sec_nft_present; then
        nft delete table inet "$NFT_TABLE" >/dev/null 2>&1 || return 1
    fi
    return 0
}

_sec_nft_set_action() {
    local action="$1"
    _sec_meta_set action "$action" || return 1
    if [ "$(_sec_meta_get enabled || true)" = "1" ] && _sec_nft_present; then
        nft delete chain inet "$NFT_TABLE" "$NFT_CHAIN" >/dev/null 2>&1 || true
        _sec_nft_create_chain "$action" || { log_error "Не удалось применить действие ${action}"; return 1; }
    fi
    return 0
}

_sec_counters_total() {
    local v=0
    if _sec_nft_present; then
        v=$(nft -j list table inet "$NFT_TABLE" 2>/dev/null | jq -r '[ .nftables[]? | select(.rule) | .rule.expr[]? | select(.counter) | .counter.packets ] | add // 0' 2>/dev/null || echo 0)
    fi
    case "$v" in ''|*[!0-9]*) v=0 ;; esac
    printf '%s' "$v"
}

# Сохраняет текущий счётчик и печатает дельту с прошлого показа
_sec_counter_delta() {
    local now last delta
    now=$(_sec_counters_total)
    last=""
    [ -f "$BLOCK_COUNTERS" ] && last=$(sed -n '1p' "$BLOCK_COUNTERS" 2>/dev/null || true)
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    delta=$(( now - last ))
    [ "$delta" -lt 0 ] && delta=0
    printf '%s' "$now" > "$BLOCK_COUNTERS" 2>/dev/null || true
    printf '%s' "$delta"
}

# Таблица «запись -> отбито пакетов»
_sec_element_counters() {
    _sec_nft_present || return 0
    nft -j list table inet "$NFT_TABLE" 2>/dev/null | jq -r '
        .nftables[]? | select(.set) | .set.elem[]?
        | ( .elem.val
            | if type == "object" then (((.prefix.addr // "?") + "/" + ((.prefix.len // 0) | tostring)))
              else (. | tostring) end ) as $k
        | [ $k, (.elem.counter.packets // 0) ] | @tsv' 2>/dev/null || true
}

# Число элементов в одном nft-наборе (0, если таблицы/набора нет)
_sec_nft_set_count() {
    local setname="$1" v=0
    if _sec_nft_present; then
        v=$(nft -j list set inet "$NFT_TABLE" "$setname" 2>/dev/null \
            | jq -r '.nftables[]? | select(.set) | ((.set.elem // []) | length)' 2>/dev/null || echo 0)
    fi
    case "$v" in ''|*[!0-9]*) v=0 ;; esac
    printf '%s' "$v"
}

_sec_rules_active() {
    [ "$(_sec_meta_get enabled || true)" = "1" ] || return 1
    _sec_nft_present || return 1
    [ "$(_sec_list_count)" -gt 0 ] || return 1
    [ "$(( $(_sec_nft_set_count "$NFT_SET4") + $(_sec_nft_set_count "$NFT_SET6") ))" -gt 0 ] || return 1
    return 0
}

_sec_apply_if_enabled() {
    [ "$(_sec_meta_get enabled || true)" = "1" ] || return 0
    _sec_nft_sync
}

_sec_block_line() {
    local action enabled st n cnt delta nft_n
    action=$(_sec_meta_get action || true); [ -n "$action" ] || action="drop"
    enabled=$(_sec_meta_get enabled || true)
    n=$(_sec_list_count)
    if [ "$enabled" = "1" ] && _sec_nft_present; then
        nft_n=$(( $(_sec_nft_set_count "$NFT_SET4") + $(_sec_nft_set_count "$NFT_SET6") ))
        if [ "$nft_n" -eq 0 ] && [ "$n" -gt 0 ]; then
            st="правила АКТИВНЫ (${action}), но набор ПУСТ / синхронизация не завершена"
        elif [ "$nft_n" -lt "$n" ]; then
            st="правила АКТИВНЫ (${action}), применено ${nft_n} из ${n}"
        else
            st="правила АКТИВНЫ (${action})"
        fi
    elif [ "$enabled" = "1" ]; then
        st="включено, но nft-таблица отсутствует"
    else
        st="правила выключены"
    fi
    cnt=$(_sec_counters_total)
    delta=$(_sec_counter_delta)
    printf '%s, записей в списке %s, отбито %s пакетов (+%s с прошлого показа)' "$st" "$n" "$cnt" "$delta"
}

# ============================================================
#  Операции со списком блокировки
# ============================================================
_sec_list_add() {
    local entry="${1:-}"
    _sec_list_init
    if _sec_is_world "$entry"; then
        log_error "Подсеть ${entry} блокирует ВЕСЬ трафик, включая SSH — отклонено"
        return 1
    fi
    if ! _sec_val_ip "$entry"; then
        log_error "Некорректный адрес или подсеть: ${entry:-<пусто>}"
        return 1
    fi
    if _sec_list_has "$entry"; then
        log_warning "Уже в списке: $entry"
    else
        printf '%s\n' "$entry" >> "$BLOCK_LIST"
        log_success "Добавлено в список: $entry"
    fi
    if [ "$(_sec_meta_get enabled || true)" = "1" ]; then
        _sec_nft_sync || { log_error "Запись в списке, но правила nft не применились"; return 1; }
        log_success "Правило блокировки применено (nft ${NFT_TABLE})"
    else
        log_info "Правила выключены — запись сохранена и вступит в силу после включения [4]"
    fi
    return 0
}

_sec_list_del() {
    local entry="${1:-}" tmp rc=0
    _sec_list_init
    if ! _sec_list_has "$entry"; then
        log_warning "Нет в списке: $entry"
        return 1
    fi
    tmp=$(mktemp "${BLOCK_LIST}.XXXXXX") || return 1
    grep -vxF -- "$entry" "$BLOCK_LIST" > "$tmp" 2>/dev/null || rc=$?
    if [ "$rc" -gt 1 ]; then
        rm -f "$tmp"
        log_error "Не удалось обновить список (ошибка grep, код $rc)"
        return 1
    fi
    mv -f "$tmp" "$BLOCK_LIST" || { rm -f "$tmp"; return 1; }
    log_success "Удалено из списка: $entry"
    if [ "$(_sec_meta_get enabled || true)" = "1" ]; then
        _sec_nft_sync || { log_error "Запись удалена, но правила nft не синхронизировались"; return 1; }
    fi
    return 0
}

_sec_list_clear() {
    _sec_list_init
    {
        printf '# Список блокировки IP/подсетей (по одной записи на строку)\n'
        printf '# Формат: IPv4/IPv6-адрес или CIDR. Строки с # игнорируются.\n'
    } > "$BLOCK_LIST"
    log_success "Список очищен"
    _sec_apply_if_enabled || true
    return 0
}

_sec_list_export() {
    local dst="${1:-/root/ipblock-export-$(date +%Y%m%d-%H%M%S).list}"
    _sec_list_init
    cp "$BLOCK_LIST" "$dst" || { log_error "Не удалось сохранить в $dst"; return 1; }
    log_success "Список сохранён: $dst"
    return 0
}

_sec_list_import() {
    local src="${1:-}" line n=0
    [ -f "$src" ] || { log_error "Файл не найден: ${src:-<пусто>}"; return 1; }
    _sec_list_init
    while IFS= read -r line || [ -n "$line" ]; do
        line=$(printf '%s' "$line" | sed -e 's/#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        [ -n "$line" ] || continue
        if _sec_val_ip "$line"; then
            if ! _sec_list_has "$line"; then
                printf '%s\n' "$line" >> "$BLOCK_LIST"
                n=$((n+1))
            fi
        else
            log_warning "Пропущена некорректная запись: $line"
        fi
    done < "$src"
    log_success "Импортировано новых записей: $n"
    _sec_apply_if_enabled || true
    return 0
}

_sec_block_enable() {
    _sec_list_init
    _sec_meta_set enabled 1 || return 1
    if ! _sec_nft_sync; then
        _sec_meta_set enabled 0 || true
        log_error "Не удалось включить блокировку"
        return 1
    fi
    _sec_unit_install
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable --now "$UNIT_NAME" >/dev/null 2>&1 || log_warning "Автозапуск юнита ${UNIT_NAME} не включён"
    if ! _sec_nft_present; then
        log_error "nft-таблица ${NFT_TABLE} не создана"
        return 1
    fi
    log_success "Блокировка включена (nft-таблица ${NFT_TABLE}, действие $(_sec_meta_get action || echo drop))"
    return 0
}

_sec_block_disable() {
    systemctl disable --now "$UNIT_NAME" >/dev/null 2>&1 || true
    _sec_meta_set enabled 0 || true
    if _sec_nft_present; then
        if ! _sec_nft_delete; then
            log_error "Не удалось удалить nft-таблицу ${NFT_TABLE}"
            return 1
        fi
    fi
    if _sec_nft_present; then
        log_error "nft-таблица ${NFT_TABLE} всё ещё присутствует"
        return 1
    fi
    log_success "Блокировка выключена (список сохранён)"
    return 0
}

_sec_unit_install() {
    mkdir -p "$(dirname "$BLOCK_UNIT")" 2>/dev/null || true
    if ! cat > "$BLOCK_UNIT" <<EOF
[Unit]
Description=MEKO Manager: блокировка IP/подсетей (nftables)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutStartSec=60
ExecStart=/bin/bash ${INSTALL_DIR}/data/security.sh --restore
ExecStop=/bin/bash ${INSTALL_DIR}/data/security.sh --disable-nft

[Install]
WantedBy=multi-user.target
EOF
    then
        log_error "Не удалось записать юнит ${BLOCK_UNIT}"
        return 1
    fi
    chmod 644 "$BLOCK_UNIT" 2>/dev/null || true
    return 0
}

# ============================================================
#  Представление таблиц отпечатков
# ============================================================
_sec_row_mark() {
    local scope="$1" key="$2" cover
    case "$key" in ''|'-') return 0 ;; esac
    case "$scope" in
        by_ip|by_cidr)
            if _sec_list_has "$key"; then
                if _sec_rules_active; then printf 'Заблокирован'
                else printf 'В списке'; fi
                return 0
            fi
            cover=$(_sec_cover_by "$key" || true)
            if [ -n "$cover" ]; then printf 'охвачен подсетью %s' "$cover"; fi
            ;;
    esac
    return 0
}

_sec_print_table() {
    local scope="$1" rows="$2" i=0 key ja4 ja3 total auth bad first last mark
    printf '  %-3s %-20s %-24s %-9s %6s %6s %7s  %-12s %-12s %s\n' \
        "№" "Ключ" "JA4" "JA3" "Всего" "Успех" "Подозр" "Первый" "Последний" "Метка"
    while IFS=$'\t' read -r key ja4 ja3 total auth bad first last; do
        [ -n "${key:-}" ] || continue
        i=$((i + 1))
        mark=$(_sec_row_mark "$scope" "$key")
        printf '  %-3s %-20s %-24s %-9s %6s %6s %7s  %-12s %-12s %s\n' \
            "$i" "$(_sec_cut "$key" 20)" "$(_sec_cut "$ja4" 24)" "$(_sec_cut "$ja3" 9)" \
            "${total:-0}" "${auth:-0}" "${bad:-0}" "$(_sec_ts "${first:-0}")" "$(_sec_ts "${last:-0}")" "$mark"
    done <<< "$rows"
    echo ""
    echo -e "  ${DIM}Строк: $i${NC}"
}

_sec_show_scope() {
    local scope="$1" title="$2" blockable="$3"
    while true; do
        clear 2>/dev/null || true
        echo ""
        echo -e "  ${CYAN}${BOLD}TLS-отпечатки: ${title}${NC}"
        echo -e "  ${DIM}Фильтр: $( [ "$SEC_SUSP" = "1" ] && printf 'только подозрительные' || printf 'все' ), лимит строк: ${SEC_LIMIT}${NC}"
        echo ""
        local st
        st=$(_sec_api_state)
        if [ "$st" != "enabled" ]; then
            _sec_collect_explain "$st"
            _pause || true
            return 0
        fi
        local rows
        if ! rows=$(_sec_api_rows "$scope" "$SEC_SUSP"); then
            log_error "Не удалось получить данные от API"
            _pause || true
            return 0
        fi
        if [ -z "$rows" ]; then
            log_warning "Данных пока нет (трафика может не быть или фильтр слишком строгий)"
        else
            _sec_print_table "$scope" "$rows"
        fi
        local n=0
        if [ -n "$rows" ]; then
            n=$(printf '%s\n' "$rows" | awk 'END{print NR+0}')
        fi
        echo ""
        echo -e "  ${DIM}Номер строки — в блокировку, f — фильтр, l — лимит, Enter — назад${NC}"
        echo -en "  ${BOLD}Действие:${NC} "
        local sel
        { read -r sel </dev/tty; } 2>/dev/null || { echo; return 0; }
        case "$sel" in
            ''|0) return 0 ;;
            f|F)
                if [ "$SEC_SUSP" = "1" ]; then SEC_SUSP=0; else SEC_SUSP=1; fi
                ;;
            l|L)
                echo -en "  ${BOLD}Лимит строк [10-1000] (сейчас ${SEC_LIMIT}):${NC} "
                local lim
                { read -r lim </dev/tty; } 2>/dev/null || { echo; continue; }
                case "$lim" in
                    ''|*[!0-9]*) log_error "Введите число" ; sleep 0.6 ;;
                    *) if [ "$lim" -ge 1 ] && [ "$lim" -le 1000 ]; then SEC_LIMIT="$lim"; else log_error "Допустимо 1..1000"; sleep 0.6; fi ;;
                esac
                ;;
            *[!0-9]*) log_error "Введите номер строки, f или l"; sleep 0.6 ;;
            *)
                if [ "$blockable" != "1" ]; then
                    log_warning "В этом скоупе блокировка по клику недоступна — используйте «по IP» или «по подсети»"
                    sleep 1
                    continue
                fi
                if [ "$sel" -lt 1 ] || [ "$sel" -gt "$n" ]; then
                    log_error "Нет такой строки: $sel"; sleep 0.6; continue
                fi
                local key
                key=$(printf '%s\n' "$rows" | awk -v k="$sel" 'NR==k{print $1}')
                [ -n "$key" ] || { log_error "Не удалось определить запись"; sleep 0.6; continue; }
                if [ "$scope" = "by_cidr" ]; then
                    echo -en "  ${YELLOW}Заблокировать всю подсеть ${key}? [y/N]:${NC} "
                    local ans
                    { read -r ans </dev/tty; } 2>/dev/null || { echo; continue; }
                    case "$ans" in
                        y|Y|yes|YES|д|Д|да|ДА) ;;
                        *) log_info "Отменено"; sleep 0.5; continue ;;
                    esac
                fi
                _sec_list_add "$key" || true
                _pause || true
                ;;
        esac
    done
}

# ============================================================
#  Меню блокировки
# ============================================================
_sec_block_status() {
    echo ""
    echo -e "  ${CYAN}${BOLD}Блокировка IP/подсетей${NC}"
    echo ""
    echo -e "  Список: ${BLOCK_LIST}"
    echo -e "  Правила: $(_sec_block_line)"
    echo -e "  nft-таблица: $( _sec_nft_present && printf 'inet %s (присутствует)' "$NFT_TABLE" || printf 'отсутствует' )"
    echo -e "  Юнит автозапуска: $( systemctl is-enabled "$UNIT_NAME" >/dev/null 2>&1 && printf 'включён' || printf 'не включён' )"
    echo ""
    local line key pk
    local printed=0
    while IFS=$'\t' read -r key pk; do
        [ -n "${key:-}" ] || continue
        if [ "$printed" = "0" ]; then
            echo -e "  ${DIM}запись                                             отбито${NC}"
            printed=1
        fi
        printf '  %-50s %s\n' "$(_sec_cut "$key" 50)" "${pk:-0}"
    done < <(_sec_element_counters)
    if [ "$printed" = "0" ]; then
        echo -e "  ${DIM}(в списке нет активных записей)${NC}"
    fi
    echo ""
}

_sec_block_menu() {
    while true; do
        clear 2>/dev/null || true
        _sec_block_status
        echo -e "  ${CYAN}[1]${NC}  Показать список блокировки"
        echo -e "  ${CYAN}[2]${NC}  Добавить IP/подсеть"
        echo -e "  ${CYAN}[3]${NC}  Удалить IP/подсеть"
        echo -e "  ${CYAN}[4]${NC}  Включить блокировку"
        echo -e "  ${CYAN}[5]${NC}  Выключить блокировку"
        echo -e "  ${CYAN}[6]${NC}  Экспорт списка в файл"
        echo -e "  ${CYAN}[7]${NC}  Импорт списка из файла"
        echo -e "  ${CYAN}[8]${NC}  Очистить список"
        echo -e "  ${CYAN}[9]${NC}  Действие (drop/reject)"
        echo ""
        echo -e "  ${CYAN}[0]${NC}  Назад"
        echo ""
        echo -en "  ${BOLD}Выбор:${NC} "
        local choice
        { read -r choice </dev/tty; } 2>/dev/null || { echo; return 0; }
        case "$choice" in
            1) _sec_list_show; _pause || true ;;
            2) _sec_prompt_add ;;
            3) _sec_prompt_del ;;
            4) _sec_block_enable || true; _pause || true ;;
            5) _sec_block_disable || true; _pause || true ;;
            6) _sec_list_export || true; _pause || true ;;
            7) _sec_prompt_import ;;
            8) _sec_prompt_clear ;;
            9) _sec_prompt_action ;;
            0 | "") return 0 ;;
            *) log_error "Неверный выбор"; sleep 0.4 ;;
        esac
    done
}

_sec_list_show() {
    local n; n=$(_sec_list_count)
    echo ""
    if [ "$n" = "0" ]; then
        log_info "Список пуст"
        return 0
    fi
    local i=0 e
    while IFS= read -r e; do
        [ -n "$e" ] || continue
        i=$((i + 1))
        printf '  %-3s %s\n' "$i" "$e"
    done < <(_sec_list_entries)
    echo ""
    echo -e "  ${DIM}Всего записей: $n${NC}"
}

_sec_prompt_add() {
    echo ""
    echo -en "  ${BOLD}IP или подсеть (например 1.2.3.4 или 1.2.3.0/24):${NC} "
    local v
    { read -r v </dev/tty; } 2>/dev/null || { echo; return 0; }
    [ -n "$v" ] || return 0
    _sec_list_add "$v" || true
    _pause || true
}

_sec_prompt_del() {
    _sec_list_show
    echo -en "  ${BOLD}Что удалить (IP/подсеть):${NC} "
    local v
    { read -r v </dev/tty; } 2>/dev/null || { echo; return 0; }
    [ -n "$v" ] || return 0
    _sec_list_del "$v" || true
    _pause || true
}

_sec_prompt_clear() {
    echo -en "  ${YELLOW}Очистить весь список блокировки? [y/N]:${NC} "
    local a
    { read -r a </dev/tty; } 2>/dev/null || { echo; return 0; }
    case "$a" in y|Y|yes|YES|д|Д|да|ДА) _sec_list_clear || true ;; *) log_info "Отменено" ;; esac
    _pause || true
}

_sec_prompt_import() {
    echo ""
    echo -en "  ${BOLD}Путь к файлу для импорта:${NC} "
    local p
    { read -r p </dev/tty; } 2>/dev/null || { echo; return 0; }
    [ -n "$p" ] || return 0
    _sec_list_import "$p" || true
    _pause || true
}

_sec_prompt_action() {
    echo ""
    echo -e "  ${DIM}drop — молча отбрасывать; reject — отклонять (для TCP: tcp reset)${NC}"
    echo -en "  ${BOLD}Действие [drop/reject] (сейчас $(_sec_meta_get action || echo drop)):${NC} "
    local a
    { read -r a </dev/tty; } 2>/dev/null || { echo; return 0; }
    case "$a" in
        drop|DROP) _sec_nft_set_action drop || true ;;
        reject|REJECT) _sec_nft_set_action reject || true ;;
        '') return 0 ;;
        *) log_error "Допустимо: drop или reject" ;;
    esac
    _pause || true
}

_sec_collect_menu() {
    while true; do
        clear 2>/dev/null || true
        echo ""
        echo -e "  ${CYAN}${BOLD}Сбор TLS-отпечатков${NC}"
        echo ""
        echo -e "  Состояние: $(_sec_collect_line)"
        echo -e "  ${DIM}Движок: $(_sec_engine_desc)${NC}"
        echo -e "  ${DIM}API: http://$(_sec_api_addr "$SEC_CFG")/v1/runtime/tls-fingerprints${NC}"
        echo ""
        echo -e "  ${CYAN}[1]${NC}  Включить сбор"
        echo -e "  ${CYAN}[2]${NC}  Выключить сбор"
        echo ""
        echo -e "  ${CYAN}[0]${NC}  Назад"
        echo ""
        echo -en "  ${BOLD}Выбор:${NC} "
        local choice
        { read -r choice </dev/tty; } 2>/dev/null || { echo; return 0; }
        case "$choice" in
            1) _sec_collect_enable || true; _pause || true ;;
            2) _sec_collect_disable || true; _pause || true ;;
            0 | "") return 0 ;;
            *) log_error "Неверный выбор"; sleep 0.4 ;;
        esac
    done
}

# ============================================================
#  Главное меню
# ============================================================
_sec_header() {
    _sec_list_init
    _sec_engine_detect >/dev/null 2>&1 || true
    echo ""
    echo -e "  ${CYAN}${BOLD}══════════ Безопасность ══════════${NC}"
    echo -e "  ${DIM}Движок: $(_sec_engine_desc)${NC}"
    echo -e "  ${DIM}API: http://$(_sec_api_addr "$SEC_CFG")/v1/runtime/tls-fingerprints${NC}"
    echo -e "  Отпечатки: $(_sec_collect_line)"
    echo -e "  Блокировка: $(_sec_block_line)"
    echo ""
}

security_menu() {
    _need_root || return 1
    _sec_list_init
    while true; do
        clear 2>/dev/null || true
        _sec_header
        echo -e "  ${CYAN}[1]${NC}  Отпечатки: по отпечатку ${DIM}(JA3/JA4)${NC}"
        echo -e "  ${CYAN}[2]${NC}  Отпечатки: по IP ${DIM}(можно в блок)${NC}"
        echo -e "  ${CYAN}[3]${NC}  Отпечатки: по подсети ${DIM}(можно в блок)${NC}"
        echo -e "  ${CYAN}[4]${NC}  Отпечатки: по пользователю"
        echo -e "  ${CYAN}[5]${NC}  Сбор отпечатков: вкл/выкл"
        echo -e "  ${CYAN}[6]${NC}  Блокировка IP/подсетей"
        echo ""
        echo -e "  ${CYAN}[0]${NC}  Назад"
        echo ""
        echo -en "  ${BOLD}Выбор:${NC} "
        local choice
        { read -r choice </dev/tty; } 2>/dev/null || { echo; return 0; }
        case "$choice" in
            1) _sec_show_scope by_fingerprint "по отпечатку" 0 ;;
            2) _sec_show_scope by_ip "по IP" 1 ;;
            3) _sec_show_scope by_cidr "по подсети" 1 ;;
            4) _sec_show_scope by_user "по пользователю" 0 ;;
            5) _sec_collect_menu ;;
            6) _sec_block_menu ;;
            0 | "") return 0 ;;
            *) log_error "Неверный выбор"; sleep 0.4 ;;
        esac
    done
}

# ============================================================
#  CLI
# ============================================================
_cli_status() {
    _sec_list_init
    _sec_engine_detect >/dev/null 2>&1 || true
    echo "Движок: $(_sec_engine_desc)"
    echo "Отпечатки: $(_sec_collect_line)"
    echo "Блокировка: $(_sec_block_line)"
    echo "nft-таблица: $( _sec_nft_present && echo "inet ${NFT_TABLE} присутствует" || echo "отсутствует" )"
    return 0
}

_cli_help() {
    cat <<EOF
data/security.sh — Безопасность (TLS-отпечатки и блокировка IP/подсетей)

  (без аргументов)          интерактивное меню
  --status                  краткий статус
  --block <ip|cidr>         добавить в блокировку
  --unblock <ip|cidr>       убрать из блокировки
  --restore                 применить список к nft (для юнита автозапуска)
  --disable-nft             снять nft-таблицу ${NFT_TABLE}
  --enable-block            включить блокировку
  --disable-block           выключить блокировку
  --collect-enable          включить сбор TLS-отпечатков
  --collect-disable         выключить сбор TLS-отпечатков
  --help                    эта справка
EOF
}

_cli_restore() {
    _sec_list_init
    [ "$(_sec_meta_get enabled || true)" = "1" ] || return 0
    _sec_nft_sync
}

_cli_disable_nft() {
    _sec_nft_delete
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        --status)        _cli_status ;;
        --block)         shift; _need_root && _sec_list_add "${1:-}" ;;
        --unblock)       shift; _need_root && _sec_list_del "${1:-}" ;;
        --restore)       _need_root && _cli_restore ;;
        --disable-nft)   _need_root && _cli_disable_nft ;;
        --enable-block)  _need_root && _sec_block_enable ;;
        --disable-block) _need_root && _sec_block_disable ;;
        --collect-enable)  _need_root && _sec_collect_enable ;;
        --collect-disable) _need_root && _sec_collect_disable ;;
        --help|-h)       _cli_help ;;
        "")              security_menu ;;
        *)               echo "Неизвестный аргумент: $1 (см. --help)" >&2; exit 2 ;;
    esac
fi
