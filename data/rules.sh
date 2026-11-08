#!/bin/bash
# data/rules.sh – все функции и наборы для работы с SYN FIX (iptables/nftables)

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

# pause_key [подсказка] — ждём клавишу, только если есть терминал
pause_key() {
    { : </dev/tty; } 2>/dev/null || return 0
    echo -e "  ${GRAY}${1:-Нажмите любую клавишу}${NC}"
    read -rsn1 </dev/tty || true
    IFS= read -r -t 0.05 _ </dev/tty 2>/dev/null || true
}

# ── Файл для хранения порта ─────────────────────────────────
PORT_FILE="/opt/mtpr-simple/port"

# ── Название кастомной цепочки iptables ─────────────────────
SYNFIX_CHAIN="MTPR_SYNFIX"

# ── Функция обрезки пробелов ──────────────────────────────
trim() {
    local var="$1"
    var="${var#"${var%%[![:space:]]*}"}"
    var="${var%"${var##*[![:space:]]}"}"
    printf '%s' "$var"
}

# ── Открыть TCP-порт в активном файрволе ────────────────────
# ufw и firewalld держат собственные цепочки в INPUT: без явного allow
# пакеты до прокси не доходят, даже когда SYN-фикс применён (issue #34).
# Идемпотентно; молча выходим, если файрвол не активен.
open_port_in_firewall() {
    local p="$1"
    [ -z "$p" ] && return 0
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi '^Status: active'; then
        if ufw allow "$p"/tcp >/dev/null 2>&1; then
            log_success "ufw: открыт порт $p/tcp"
        else
            log_warning "ufw: не удалось открыть порт $p/tcp (проверьте вручную)"
        fi
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        if firewall-cmd --permanent --add-port="$p"/tcp >/dev/null 2>&1 && firewall-cmd --reload >/dev/null 2>&1; then
            log_success "firewalld: открыт порт $p/tcp"
        else
            log_warning "firewalld: не удалось открыть порт $p/tcp (проверьте вручную)"
        fi
    fi
    return 0
}

# ── Функция определения порта SSH ────────────────────────────
get_ssh_port() {
    local port
    if command -v sshd >/dev/null 2>&1; then
        port=$(timeout 3 sshd -T 2>/dev/null | grep '^port ' | awk '{print $2}' | head -1)
        if [[ "$port" =~ ^[0-9]+$ ]]; then
            echo "$port"
            return 0
        fi
    fi

    if [ -f /etc/ssh/sshd_config ]; then
        port=$(grep -E '^Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config | head -1 | awk '{print $2}')
        if [[ "$port" =~ ^[0-9]+$ ]]; then
            echo "$port"
            return 0
        fi
    fi

    if [ -d /etc/ssh/sshd_config.d ]; then
        for cfg in /etc/ssh/sshd_config.d/*.conf; do
            if [ -f "$cfg" ]; then
                port=$(grep -E '^Port[[:space:]]+[0-9]+' "$cfg" | head -1 | awk '{print $2}')
                if [[ "$port" =~ ^[0-9]+$ ]]; then
                    echo "$port"
                    return 0
                fi
            fi
        done
    fi

    echo "22"
    return 0
}

save_port() {
    # Пишем порт только после успешной установки: иначе отменённая установка
    # оставляет в файле порт, который реально нигде не открыт.
    mkdir -p "$(dirname "$PORT_FILE")"
    echo "$1" >"$PORT_FILE"
}

# ── Цепочка SYN FIX (iptables): установлена? ────────────────
is_syn_fix_chain_installed() {
    iptables -L "$SYNFIX_CHAIN" -n >/dev/null 2>&1
}

is_syn_fix_service_running() {
    systemctl is-active --quiet mtpr-synfix.service
}

get_synfix_status() {
    if is_syn_fix_chain_installed; then
        if is_syn_fix_service_running; then
            echo "active"
        else
            echo "has_chain_only"
        fi
    else
        echo "inactive"
    fi
}

# ── Таблица SYN FIX (nftables): установлена? ────────────────
is_nft_fix_installed() {
    nft list table inet mtpr_synfix &>/dev/null 2>&1
}

is_nft_fix_service_running() {
    systemctl is-active --quiet mtpr-nft-synfix.service 2>/dev/null
}

get_nft_fix_status() {
    if is_nft_fix_installed; then
        if is_nft_fix_service_running; then
            echo "active"
        else
            echo "has_table_only"
        fi
    else
        echo "inactive"
    fi
}

# ── Генерация скрипта применения правил ──────────────────────────
generate_apply_script() {
    local fix_type="${1:-new}"
    shift

    if [ "$fix_type" = "old" ]; then
        cat >/opt/mtpr-simple/apply-mtpr-synfix.sh <<'APPLY_SCRIPT_EOF'
#!/bin/bash
set -e

# ── Парсим порты из файла ──────────────────────────────────
if [ -f /opt/mtpr-simple/port ]; then
    PORTS=$(cat /opt/mtpr-simple/port)
else
    echo "SYN FIX: Файл с портами не найден" >&2
    exit 1
fi

CHAIN="MTPR_SYNFIX"
SSH_PORT=$(sshd -T 2>/dev/null | grep '^port ' | awk '{print $2}'); [ -n "$SSH_PORT" ] || SSH_PORT=22

if ! iptables -C INPUT -p tcp --dport "$SSH_PORT" -j ACCEPT 2>/dev/null; then
    iptables -I INPUT 1 -p tcp --dport "$SSH_PORT" -j ACCEPT
    echo "SSH-доступ (${SSH_PORT}) разрешён"
fi

iptables -t filter -N "$CHAIN" 2>/dev/null || true
iptables -t filter -F "$CHAIN"

if ! iptables -t filter -C INPUT -j "$CHAIN" 2>/dev/null; then
    iptables -t filter -I INPUT 2 -j "$CHAIN"
    echo "Цепочка $CHAIN подключена к INPUT"
fi

# ── Проходим по каждому порту ──────────────────────────────
IFS=',' read -ra PORT_ARRAY <<< "$PORTS"
for PORT in "${PORT_ARRAY[@]}"; do
    PORT=$(echo "$PORT" | xargs)
    [ -z "$PORT" ] && continue

    # ── iOS — проверка TTL+Length, ACCEPT БЕЗ ЛИМИТА ────────
    iptables -t filter -A "$CHAIN" -p tcp --dport "$PORT" --syn \
        -m tcp --tcp-flags SYN SYN \
        -m length --length 64 \
        -m ttl --ttl-lt 65 \
        -j ACCEPT

    # ── ВТОРОЙ СЛОЙ — все остальные → hashlimit 54/мин ──────
    iptables -t filter -A "$CHAIN" -p tcp --dport "$PORT" --syn \
        -m hashlimit \
        --hashlimit-name mtproto_"$PORT" \
        --hashlimit-mode srcip \
        --hashlimit-upto 54/minute \
        --hashlimit-burst 1 \
        --hashlimit-htable-expire 60000 \
        --hashlimit-htable-size 32768 \
        -j ACCEPT

    # ── REJECT для всех остальных ────────────────────────────
    iptables -t filter -A "$CHAIN" -p tcp --dport "$PORT" --syn \
        -j REJECT --reject-with tcp-reset
done

APPLY_SCRIPT_EOF
    else
        # Новый вариант (u32 + ACCEPT без лимита)
        cat >/opt/mtpr-simple/apply-mtpr-synfix.sh <<'APPLY_SCRIPT_EOF'
#!/bin/bash
set -e

# ── Парсим порты из файла ──────────────────────────────────
if [ -f /opt/mtpr-simple/port ]; then
    PORTS=$(cat /opt/mtpr-simple/port)
else
    echo "SYN FIX: Файл с портами не найден" >&2
    exit 1
fi

CHAIN="MTPR_SYNFIX"
SSH_PORT=$(sshd -T 2>/dev/null | grep '^port ' | awk '{print $2}'); [ -n "$SSH_PORT" ] || SSH_PORT=22

if ! iptables -C INPUT -p tcp --dport "$SSH_PORT" -j ACCEPT 2>/dev/null; then
    iptables -I INPUT 1 -p tcp --dport "$SSH_PORT" -j ACCEPT
    echo "SSH-доступ (${SSH_PORT}) разрешён"
fi

iptables -t filter -N "$CHAIN" 2>/dev/null || true
iptables -t filter -F "$CHAIN"

if ! iptables -t filter -C INPUT -j "$CHAIN" 2>/dev/null; then
    iptables -t filter -I INPUT 2 -j "$CHAIN"
    echo "Цепочка $CHAIN подключена к INPUT"
fi

# ── 1. Маркировка iOS (iptables u32, а без xt_u32 — тем же фильтром в nftables) ──
U32_FILTER="32 & 0x000FFFFF = 0x0002FFFF && 40 & 0xFF000000 = 0x02000000 && 44 & 0xFFFF0000 = 0x01030000 && 48 & 0xFFFFFF00 = 0x01010800 && 60 & 0xFFFFFFFF = 0x04020000"
# Сначала сносим все ранее накопившиеся дубликаты этого правила
while iptables -t mangle -C PREROUTING -m u32 --u32 "$U32_FILTER" -j MARK --set-mark 0x400 2>/dev/null; do
    iptables -t mangle -D PREROUTING -m u32 --u32 "$U32_FILTER" -j MARK --set-mark 0x400 2>/dev/null || break
done
if iptables -t mangle -A PREROUTING -m u32 --u32 "$U32_FILTER" -j MARK --set-mark 0x400 2>/dev/null; then
    nft delete table inet mtpr_synfix_u32 2>/dev/null || true
else
    # Ядро без xt_u32 (RHEL/Alma/Rocky 9 и т.п.): те же смещения читаем
    # штатным nftables через @nh (смещения там в битах), mark общий.
    echo "xt_u32 недоступен — маркировка через nftables"
    nft delete table inet mtpr_synfix_u32 2>/dev/null || true
    nft add table inet mtpr_synfix_u32
    nft add chain inet mtpr_synfix_u32 pre '{ type filter hook prerouting priority mangle; policy accept; }'
    # Каждое условие — отдельный аргумент в кавычках: nft склеивает их через AND.
    # Смещения u32 (в байтах от начала IP-заголовка) переводим в биты для @nh.
    for PORT in $(echo "$PORTS" | tr ',' ' '); do
        nft add rule inet mtpr_synfix_u32 pre meta nfproto ipv4 tcp dport "$PORT" \
            '@nh,256,32 & 0x000FFFFF == 0x0002FFFF' \
            '@nh,320,32 & 0xFF000000 == 0x02000000' \
            '@nh,352,32 & 0xFFFF0000 == 0x01030000' \
            '@nh,384,32 & 0xFFFFFF00 == 0x01010800' \
            '@nh,480,32 & 0xFFFFFFFF == 0x04020000' \
            meta mark set 0x400
    done
fi

# ── Проходим по каждому порту ──────────────────────────────
IFS=',' read -ra PORT_ARRAY <<< "$PORTS"
for PORT in "${PORT_ARRAY[@]}"; do
    PORT=$(echo "$PORT" | xargs)
    [ -z "$PORT" ] && continue

    # ── ACCEPT для маркированных iOS (БЕЗ ЛИМИТА) ─────────────
    iptables -t filter -A "$CHAIN" -p tcp --dport "$PORT" --syn -m mark --mark 0x400 -j ACCEPT

    # ── ВТОРОЙ СЛОЙ — все остальные → hashlimit 54/мин ──────
    iptables -t filter -A "$CHAIN" -p tcp --dport "$PORT" --syn \
        -m hashlimit \
        --hashlimit-name mtproto_"$PORT" \
        --hashlimit-mode srcip \
        --hashlimit-upto 54/minute \
        --hashlimit-burst 1 \
        --hashlimit-htable-expire 60000 \
        --hashlimit-htable-size 32768 \
        -j ACCEPT

    # ── REJECT для всех остальных ────────────────────────────
    iptables -t filter -A "$CHAIN" -p tcp --dport "$PORT" --syn \
        -j REJECT --reject-with tcp-reset
done

APPLY_SCRIPT_EOF
    fi

    chmod +x /opt/mtpr-simple/apply-mtpr-synfix.sh
}

# ── Генерация systemd юнита ────────────────────────────────────
generate_service_unit() {
    cat >/etc/systemd/system/mtpr-synfix.service <<'SERVICE_UNIT_EOF'
[Unit]
Description=MTProto SYN FIX rules for Telemt
After=network-online.target netfilter-persistent.service docker.service ufw.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/opt/mtpr-simple/apply-mtpr-synfix.sh
Restart=on-failure

[Install]
WantedBy=multi-user.target
SERVICE_UNIT_EOF
    if systemctl daemon-reload 2>/dev/null; then
        log_info "Системный менеджер служб перезапущен"
    fi
}

# ── u32-фильтр для v3 (используется для явной проверки применения) ──
U32_FILTER="32 & 0x000FFFFF = 0x0002FFFF && 40 & 0xFF000000 = 0x02000000 && 44 & 0xFFFF0000 = 0x01030000 && 48 & 0xFFFFFF00 = 0x01010800 && 60 & 0xFFFFFFFF = 0x04020000"

# ── Список стран, для которых GEOIP-обход SYN-лимита НЕ применяется ──
GEOIP_CC_LIST="RU,CN,IR,VN,CU,SO,NP,TM,OM,UA"

# ── Модуль xt_u32: фактическая проверка и установка (Alma/Rocky/CentOS) ──
u32_module_available() {
    # 1) уже загружен в ядро?
    if lsmod 2>/dev/null | grep -q '^xt_u32'; then
        return 0
    fi
    # 2) пробуем загрузить и перепроверяем факт
    if modprobe xt_u32 2>/dev/null; then
        lsmod 2>/dev/null | grep -q '^xt_u32' && return 0
    fi
    # 3) косвенная проверка: iptables -m u32 -h печатает справку даже без
    # ядра-модуля (exit 0), поэтому пробуем настоящее правило в тестовой цепочке.
    if command -v iptables >/dev/null 2>&1; then
        local _test_chain="MTPR_U32TEST"
        if iptables -t mangle -N "$_test_chain" 2>/dev/null; then
            if iptables -t mangle -A "$_test_chain" -m u32 --u32 "0=0" 2>/dev/null; then
                iptables -t mangle -F "$_test_chain" 2>/dev/null || true
                iptables -t mangle -X "$_test_chain" 2>/dev/null || true
                return 0
            fi
            iptables -t mangle -X "$_test_chain" 2>/dev/null || true
        fi
    fi
    return 1
}

# Мажорная версия RHEL-совместимого дистрибутива (Alma/Rocky/CentOS/Oracle)
detect_el_major() {
    local v=""
    if [ -f /etc/almalinux-release ]; then
        v=$(grep -oE '[0-9]+' /etc/almalinux-release | head -1)
    elif [ -f /etc/rocky-release ]; then
        v=$(grep -oE '[0-9]+' /etc/rocky-release | head -1)
    elif [ -f /etc/centos-release ]; then
        v=$(grep -oE '[0-9]+' /etc/centos-release | head -1)
    elif [ -f /etc/oracle-release ]; then
        v=$(grep -oE '[0-9]+' /etc/oracle-release | head -1)
    elif [ -f /etc/os-release ]; then
        v=$(grep -E '^VERSION_ID=' /etc/os-release | grep -oE '[0-9]+' | head -1)
    fi
    if [ -z "$v" ]; then
        log_warning "Не удалось определить мажорную версию дистрибутива — предполагаю 9"
        v="9"
    fi
    printf '%s' "$v"
}

# kmod-xt_u32 на RHEL ставится из elrepo; результат проверяем явно, без || true
install_u32_module_elrepo() {
    local rel elrepo_url sudo_cmd
    if [ "$(id -u)" -eq 0 ]; then sudo_cmd=""; else sudo_cmd="sudo"; fi

    if ! command -v dnf >/dev/null 2>&1; then
        log_error "dnf не найден — установка kmod-xt_u32 поддерживается только на RHEL-совместимых системах (Alma/Rocky/CentOS)"
        return 1
    fi

    rel=$(detect_el_major)
    case "$rel" in
        8)  elrepo_url="https://www.elrepo.org/elrepo-release-8.el8.elrepo.noarch.rpm" ;;
        10) elrepo_url="https://www.elrepo.org/elrepo-release-10.el10.elrepo.noarch.rpm" ;;
        *)  rel="9"; elrepo_url="https://www.elrepo.org/elrepo-release-9.el9.elrepo.noarch.rpm" ;;
    esac

    if timeout 20 $sudo_cmd dnf repolist 2>/dev/null | grep -qi 'elrepo'; then
        log_info "Репозиторий elrepo уже подключён"
    else
        log_info "Подключение репозитория elrepo (RHEL/CentOS ${rel}.x)..."
        if ! timeout 90 $sudo_cmd dnf install -y --setopt=timeout=20 --setopt=retries=1 "$elrepo_url"; then
            log_error "Не удалось подключить репозиторий elrepo ($elrepo_url)"
            return 1
        fi
    fi

    log_info "Установка модуля kmod-xt_u32..."
    # Пакет уже стоит (например, после обновления ядра): не дёргаем dnf,
    # у elrepo метаданные иногда тянутся минутами.
    if command -v rpm >/dev/null 2>&1 && rpm -q kmod-xt_u32 >/dev/null 2>&1; then
        $sudo_cmd modprobe xt_u32 2>/dev/null || modprobe xt_u32 2>/dev/null || true
        if u32_module_available; then
            log_success "Модуль xt_u32 загружен и доступен"
            return 0
        fi
        log_warning "kmod-xt_u32 установлен, но модуль не загрузился (собран под другое ядро?) — будет nftables"
        return 1
    fi

    # Сначала прямой rpm: металлинк elrepo умеет висеть в «B/s ETA» до таймаута dnf,
    # а листинг каталога отдаётся быстро. dnf — только запасной путь.
    local arch base rpm_name rpm_path installed=false
    arch=$(uname -m)
    base="https://elrepo.org/linux/elrepo/el${rel}/${arch}/RPMS/"
    rpm_name=$(curl -fsSL --max-time 20 "$base" 2>/dev/null | grep -oE 'kmod-xt_u32-[^"]+\.rpm' | sort -uV | tail -1)
    if [ -n "$rpm_name" ]; then
        rpm_path="/tmp/${rpm_name}"
        if curl -fsSL --max-time 90 -o "$rpm_path" "${base}${rpm_name}" \
           && $sudo_cmd rpm -Uvh --nodeps "$rpm_path"; then
            installed=true
        else
            log_warning "Прямая установка kmod-xt_u32 не удалась — пробую dnf"
        fi
    else
        log_info "В elrepo нет kmod-xt_u32 для el${rel} — пробую dnf"
    fi
    if [ "$installed" != true ]; then
        timeout 90 $sudo_cmd dnf install -y --setopt=timeout=20 --setopt=retries=1 kmod-xt_u32 >/dev/null 2>&1 || true
    fi

    # Явная загрузка и ПРОВЕРКА факта наличия модуля
    $sudo_cmd modprobe xt_u32 2>/dev/null || modprobe xt_u32 2>/dev/null || true
    if u32_module_available; then
        log_success "Модуль xt_u32 загружен и доступен"
        return 0
    fi
    log_error "Пакет kmod-xt_u32 установлен, но модуль xt_u32 НЕ загрузился (проверьте: modprobe xt_u32; lsmod | grep xt_u32)."
    log_error "Если kmod собран под другое ядро (например, после обновления kernel) — перезагрузите сервер и повторите."
    return 1
}

# ── GEOIP: обход SYN-лимита для IP вне РФ ───────────────────
geoip_port() {
    if [ -r "$PORT_FILE" ] && [ -n "$(cat "$PORT_FILE" 2>/dev/null)" ]; then
        cat "$PORT_FILE"
    else
        echo "443"
    fi
}

geoip_module_available() {
    lsmod 2>/dev/null | grep -q '^xt_geoip' || \
    { command -v iptables >/dev/null 2>&1 && iptables -m geoip -h >/dev/null 2>&1; }
}

geoip_rule_present() {
    local port
    port=$(geoip_port)
    iptables -C INPUT -p tcp --dport "$port" -m geoip ! --src-cc "$GEOIP_CC_LIST" -j ACCEPT 2>/dev/null
}

# ── Пути к утилитам xt_geoip: не полагаемся только на PATH ──
# На Debian/Ubuntu xt_geoip_dl и xt_geoip_build лежат в /usr/libexec/xtables-addons
# (в PATH их нет), поэтому ищем их и в PATH, и в известных каталогах.
GEOIP_TOOL_DIRS="/usr/libexec/xtables-addons /usr/lib/xtables-addons /usr/share/xtables-addons"

_geoip_tool() {
    local name="$1" d
    if command -v "$name" >/dev/null 2>&1; then
        command -v "$name"
        return 0
    fi
    for d in $GEOIP_TOOL_DIRS; do
        if [ -x "$d/$name" ]; then
            printf '%s' "$d/$name"
            return 0
        fi
    done
    return 1
}

geoip_cron_script() {
    local sudo_cmd
    if [ "$(id -u)" -eq 0 ]; then sudo_cmd=""; else sudo_cmd="sudo"; fi
    $sudo_cmd tee /etc/cron.daily/xt_geoip >/dev/null <<'GEOIP_CRON_EOF'
#!/bin/bash
# Обновление базы xt_geoip (GEOIP-обход SYN-лимита)
set -e
mkdir -p /usr/share/xt_geoip
cd /usr/share/xt_geoip
find_geoip_tool() {
    local n="$1" d
    if command -v "$n" >/dev/null 2>&1; then command -v "$n"; return 0; fi
    for d in /usr/libexec/xtables-addons /usr/lib/xtables-addons /usr/share/xtables-addons; do
        if [ -x "$d/$n" ]; then printf '%s' "$d/$n"; return 0; fi
    done
    return 1
}
DL=$(find_geoip_tool xt_geoip_dl) || { echo "xt_geoip_dl не найден" >&2; exit 1; }
BLD=$(find_geoip_tool xt_geoip_build) || { echo "xt_geoip_build не найден" >&2; exit 1; }
"$DL"
"$BLD" -D /usr/share/xt_geoip
GEOIP_CRON_EOF
    $sudo_cmd chmod +x /etc/cron.daily/xt_geoip
    log_info "Cron-задача обновления базы: /etc/cron.daily/xt_geoip"
}

install_geoip_bypass() {
    local port sudo_cmd geoip_dl geoip_build ipt_err ip6t_err
    if [ "$(id -u)" -eq 0 ]; then sudo_cmd=""; else sudo_cmd="sudo"; fi
    port=$(geoip_port)

    log_info "Установка GEOIP-обхода SYN-лимита (порт $port, страны вне РФ: $GEOIP_CC_LIST)"

    # 1) Пакеты xtables-addons (подбор по ОС)
    if ! geoip_module_available; then
        if command -v apt-get >/dev/null 2>&1; then
            log_info "Установка xtables-addons (APT)..."
            $sudo_cmd apt-get update -qq 2>/dev/null || true
            $sudo_cmd apt-get install -y xtables-addons-common xtables-addons-dkms libtext-csv-perl curl unzip || true
        elif command -v dnf >/dev/null 2>&1; then
            log_info "Установка xtables-addons (DNF)..."
            $sudo_cmd dnf install -y xtables-addons libtext-csv-perl curl unzip || true
        else
            log_error "Не найден пакетный менеджер (apt/dnf) — установите xtables-addons вручную"
            return 1
        fi
        $sudo_cmd modprobe xt_geoip 2>/dev/null || modprobe xt_geoip 2>/dev/null || true
    fi

    if ! geoip_module_available; then
        log_error "Модуль xt_geoip недоступен после установки xtables-addons (проверьте: modprobe xt_geoip)"
        return 1
    fi

    # 2) База GeoIP: скачивание и сборка (утилиты ищем в PATH и в известных каталогах)
    log_info "Скачивание и сборка базы GeoLite2 Country..."
    $sudo_cmd mkdir -p /usr/share/xt_geoip
    if ! geoip_dl=$(_geoip_tool xt_geoip_dl); then
        log_error "Утилита xt_geoip_dl не найдена (проверьте пакет xtables-addons-common)"
        return 1
    fi
    if ! geoip_build=$(_geoip_tool xt_geoip_build); then
        log_error "Утилита xt_geoip_build не найдена (проверьте пакет xtables-addons-common)"
        return 1
    fi
    ( cd /usr/share/xt_geoip && $sudo_cmd "$geoip_dl" ) || true
    if ! ls /usr/share/xt_geoip/*.iv4 >/dev/null 2>&1; then
        $sudo_cmd "$geoip_build" -D /usr/share/xt_geoip 2>/dev/null || \
            ( cd /usr/share/xt_geoip && $sudo_cmd "$geoip_build" ) || true
    fi
    if ls /usr/share/xt_geoip/*.iv4 >/dev/null 2>&1; then
        log_success "База GeoIP собрана (/usr/share/xt_geoip/*.iv4)"
    else
        log_warning "База GeoIP не найдена в /usr/share/xt_geoip — без базы правило GEOIP добавить НЕ удастся (iptables вернёт ошибку)"
    fi

    # 3) Правило INPUT первым (идемпотентно: снять дубли, затем вставить)
    while iptables -C INPUT -p tcp --dport "$port" -m geoip ! --src-cc "$GEOIP_CC_LIST" -j ACCEPT 2>/dev/null; do
        iptables -D INPUT -p tcp --dport "$port" -m geoip ! --src-cc "$GEOIP_CC_LIST" -j ACCEPT 2>/dev/null || break
    done
    if ! ipt_err=$(iptables -I INPUT 1 -p tcp --dport "$port" -m geoip ! --src-cc "$GEOIP_CC_LIST" -j ACCEPT 2>&1); then
        log_error "Не удалось добавить правило GEOIP: ${ipt_err:-неизвестная ошибка}"
        return 1
    fi
    log_success "Правило IPv4 добавлено: INPUT 1 TCP/$port ! --src-cc $GEOIP_CC_LIST -j ACCEPT"

    # 4) IPv6 (по возможности)
    if command -v ip6tables >/dev/null 2>&1; then
        while ip6tables -C INPUT -p tcp --dport "$port" -m geoip ! --src-cc "$GEOIP_CC_LIST" -j ACCEPT 2>/dev/null; do
            ip6tables -D INPUT -p tcp --dport "$port" -m geoip ! --src-cc "$GEOIP_CC_LIST" -j ACCEPT 2>/dev/null || break
        done
        if ! ip6t_err=$(ip6tables -I INPUT 1 -p tcp --dport "$port" -m geoip ! --src-cc "$GEOIP_CC_LIST" -j ACCEPT 2>&1); then
            log_warning "IPv6-правило не добавлено: ${ip6t_err:-нет поддержки IPv6/базы .iv6} — пропускаю"
        else
            log_success "Правило IPv6 добавлено"
        fi
    else
        log_warning "ip6tables не найден — IPv6-правило пропущено"
    fi

    # 5) Cron для обновления базы
    geoip_cron_script

    log_success "GEOIP-обход SYN-лимита установлен"
    return 0
}

geoip_status() {
    local port
    port=$(geoip_port)
    echo ""
    echo -e "  ${BOLD}Статус GEOIP-обхода SYN-лимита${NC}"
    if geoip_module_available; then
        echo -e "  Модуль xt_geoip: ${GREEN}доступен${NC}"
    else
        echo -e "  Модуль xt_geoip: ${RED}не доступен${NC}"
    fi
    if geoip_rule_present; then
        echo -e "  Правило INPUT (TCP/$port): ${GREEN}установлено${NC}"
        iptables -L INPUT -n --line-numbers 2>/dev/null | grep -- "--dport $port" | head -3 | sed 's/^/    /'
    else
        echo -e "  Правило INPUT (TCP/$port): ${RED}отсутствует${NC}"
    fi
    if ls /usr/share/xt_geoip/*.iv4 >/dev/null 2>&1; then
        echo -e "  База GeoIP: ${GREEN}есть${NC} ($(ls /usr/share/xt_geoip/*.iv4 2>/dev/null | head -1))"
    else
        echo -e "  База GeoIP: ${RED}нет${NC} (/usr/share/xt_geoip)"
    fi
    if [ -x /etc/cron.daily/xt_geoip ]; then
        echo -e "  Cron: ${GREEN}/etc/cron.daily/xt_geoip${NC}"
    else
        echo -e "  Cron: ${RED}отсутствует${NC}"
    fi
    echo ""
}

remove_geoip_bypass() {
    local port sudo_cmd
    if [ "$(id -u)" -eq 0 ]; then sudo_cmd=""; else sudo_cmd="sudo"; fi
    port=$(geoip_port)
    log_info "Удаление GEOIP-обхода SYN-лимита (порт $port)..."
    while iptables -C INPUT -p tcp --dport "$port" -m geoip ! --src-cc "$GEOIP_CC_LIST" -j ACCEPT 2>/dev/null; do
        iptables -D INPUT -p tcp --dport "$port" -m geoip ! --src-cc "$GEOIP_CC_LIST" -j ACCEPT 2>/dev/null || break
    done
    if command -v ip6tables >/dev/null 2>&1; then
        while ip6tables -C INPUT -p tcp --dport "$port" -m geoip ! --src-cc "$GEOIP_CC_LIST" -j ACCEPT 2>/dev/null; do
            ip6tables -D INPUT -p tcp --dport "$port" -m geoip ! --src-cc "$GEOIP_CC_LIST" -j ACCEPT 2>/dev/null || break
        done
    fi
    if [ -f /etc/cron.daily/xt_geoip ]; then
        $sudo_cmd rm -f /etc/cron.daily/xt_geoip
        log_info "Cron-задача удалена"
    fi
    log_success "GEOIP-обход SYN-лимита удалён"
}


geoip_menu() {
    while true; do
        clear 2>/dev/null || true
        echo ""
        echo -e "  ${BOLD}GEOIP-обход SYN-лимита${NC} ${DIM}(IP вне РФ не проходят через SYN-лимит)${NC}"
        echo -e "  ${DIM}═══════════════════════════════════════════════════════════${NC}"
        echo ""
        # ── Статус выводится шапкой прямо в меню (без отдельной кнопки) ──
        geoip_status
        echo ""
        echo -e "  ${CYAN}[1]${NC}  ${BOLD}Установить${NC}"
        echo -e "  ${CYAN}[2]${NC}  ${BOLD}Удалить${NC}"
        echo -e "  ${CYAN}[0]${NC}  ${BOLD}Назад${NC}"
        echo ""
        echo -en "  ${BOLD}Выбор:${NC} "
        { read -r geoip_choice </dev/tty; } 2>/dev/null || return 1
        case "$geoip_choice" in
            1) install_geoip_bypass; pause_key ;;
            2) remove_geoip_bypass; pause_key ;;
            0) return 0 ;;
            "") echo; return 0 ;;
            *) echo "  Неверный выбор"; sleep 0.3 ;;
        esac
    done
}

# ── Бэкап и восстановление правил/фикса (пункт [B] меню правил) ──
_rules_backup_fix() {
    local bp="/opt/mtpr-simple/data/backup_panel.sh"
    if [ ! -f "$bp" ]; then
        local self_dir
        self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
        [ -f "$self_dir/backup_panel.sh" ] && bp="$self_dir/backup_panel.sh"
    fi
    if [ ! -f "$bp" ]; then
        log_error "backup_panel.sh не найден (ожидается /opt/mtpr-simple/data/backup_panel.sh)"
        return 1
    fi
    log_info "Запуск бэкапа/восстановления правил и фикса (scope=fix)..."
    bash "$bp" --scope fix
}

# ── Установка SYN FIX (с аргументами) ──────────────────────
install_syn_fix() {
    local ports_input
    local fix_choice
    local auto_install=false
    local forced_ports=""
    local FIX_TYPE="new"   # new=v3, old=v2, docker_smart=nft, zapret2
    local GEOIP_MODE=false
    local geoip_action="menu"

    # ── Парсинг аргументов ──────────────────────────────────
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -auto_install)
                auto_install=true
                shift
                ;;
            -port)
                forced_ports="$2"
                shift 2
                ;;
            -type)
                case "$2" in
                    v2|old)   FIX_TYPE="old" ;;
                    v3|new)   FIX_TYPE="new" ;;
                    nft)      FIX_TYPE="docker_smart" ;;
                    v4|zapret2) FIX_TYPE="zapret2" ;;
                    *) log_warning "Неизвестный тип фикса: $2, используем v3"; FIX_TYPE="new" ;;
                esac
                shift 2
                ;;
            -geoip)
                if [[ "$2" =~ ^(install|status|remove|menu)$ ]]; then
                    geoip_action="$2"
                    shift 2
                else
                    geoip_action="menu"
                    shift
                fi
                GEOIP_MODE=true
                ;;
            *)
                shift
                ;;
        esac
    done

    # ── Режим GEOIP (обход SYN-лимита для IP вне РФ) ────────
    if [ "$GEOIP_MODE" = true ]; then
        case "$geoip_action" in
            install) install_geoip_bypass ;;
            status)  geoip_status ;;
            remove)  remove_geoip_bypass ;;
            *)       geoip_menu ;;
        esac
        return $?
    fi

    # ── Если auto_install и тип zapret2 – вызываем отдельную функцию ──
    if [ "$auto_install" = true ] && [ "$FIX_TYPE" = "zapret2" ]; then
        if [ -z "$forced_ports" ]; then
            forced_ports="443"
        fi
        # Служба, nft-правила и Lua для v4 лежат в отдельном файле.
        # Из меню его подключают заранее, а при запуске из CLI он ещё не загружен.
        if ! declare -f zapret2_install_auto &>/dev/null; then
            _zapret2_file="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/zapret2_fix.sh"
            if [ ! -r "$_zapret2_file" ]; then
                _zapret2_file="/opt/mtpr-simple/data/zapret2_fix.sh"
            fi
            if [ -r "$_zapret2_file" ]; then
                . "$_zapret2_file"
            fi
        fi
        log_info "Установка Zapret2 (v4) на порт $forced_ports..."
        if declare -f zapret2_install_auto &>/dev/null; then
            zapret2_install_auto "$forced_ports"
            return $?
        else
            log_error "Функция zapret2_install_auto не найдена: файл data/zapret2_fix.sh отсутствует или повреждён"
            return 1
        fi
    fi

    # ── Если auto_install и тип nft – вызываем установку nftables ──
    if [ "$auto_install" = true ] && [ "$FIX_TYPE" = "docker_smart" ]; then
        if [ -z "$forced_ports" ]; then
            forced_ports="443"
        fi
        # Установка nftables в автоматическом режиме
        install_nft_auto "$forced_ports"
        return $?
    fi

    # ── Интерактивный режим требует tty ──────────────────────
    # Без tty (setsid/SSH/`<&-`) все `read` дают EOF и меню молча
    # ставит SYN FIX с дефолтами — это и был инцидент no-args.
    if [ "$auto_install" = false ] && ! { : </dev/tty; } 2>/dev/null; then
        log_error "Нет доступа к /dev/tty — интерактивное меню недоступно, установка отменена."
        log_info "Неинтерактивно: bash data/rules.sh -auto_install -port 443 -type v3"
        return 1
    fi

    # ── Далее интерактивный режим или auto_install для v2/v3 ──

    if [ "$auto_install" = true ]; then
        if [[ -n "$forced_ports" ]]; then
            ports_input="$forced_ports"
            log_info "Используем порты, переданные аргументом: $ports_input"
        else
            log_info "Порты не переданы, используем 443"
            ports_input="443"
        fi
    else
        echo ""
        if { : </dev/tty; } 2>/dev/null; then
            clear 2>/dev/null || true
            echo -e ""
            echo -e "  ${BOLD}Меню установки MTPRoto FIX V1.21"
            echo -e "  ${DIM}═══════════════════════════════════════════════════════════════"
            echo -e "  ${DIM}Для работы прокси на ios необходим корректно работающий домен"
            echo -e "  ${DIM}Подробнее в data/dictionary.md в репозитории. (обязательно к прочтению)"
            echo -e ""
            echo -e "  ${NC}${BOLD}Введите порт для SYN FIX ${DIM}(Например: 443)"
            echo -e "  ${NC}${BOLD}Либо введите порты через запятую ${DIM}(Например: 443,8443) "
            echo -e ""
            echo -en "  ${NC}${BOLD}Ввод ${GREEN}${BOLD}(По умолчанию Enter - 443, 0 - выход)${NC}${BOLD}:${NC}"
            read -r ports_input </dev/tty
        else
            echo -e "  ${NC}${BOLD}Введите порт для SYN FIX ${DIM}(Например: 443)"
            echo -e "  ${NC}${BOLD}Либо введите порты через запятую ${DIM}(Например: 443,8443) "
            echo -e ""
            echo -en "  ${NC}${BOLD}Ввод ${GREEN}${BOLD}(По умолчанию Enter - 443, 0 - выход)${NC}${BOLD}:${NC}"
            { read -r ports_input; } 2>/dev/null || true
        fi
        case "$ports_input" in
            0|q|Q)
                echo ""
                log_info "Выход без установки SYN FIX"
                return 0
                ;;
        esac
        if [ -z "$ports_input" ]; then
            ports_input="443"
        fi

        while true; do
        clear 2>/dev/null || true
        echo ""
        echo -e "  ${BOLD}Выберите вариант правил ниже"
        echo -e "  ${DIM}══════════════════════════════════════════════"
        echo ""
        echo -e "  ${GREEN}[1]${NC}  ${BOLD}V3 фикс iptables${NC} (Разделение устройств с помощью u32 по байтам из пакета) — ${GREEN}${BOLD}рекомендуется (универсальный)${NC}"
        echo -e "${DIM}  Если совпало -> это ios и принимаем пакеты без лимита"
        echo -e "${DIM}  Если не совпало -> это другое ус-во и ставим SYN 1 пакет в 1.1 сек."
        echo -e ""
        echo -e "  ${CYAN}[2]${NC}  ${BOLD}V4 фикс zapret2 ${NC} — быстрый ${NC}"
        echo -e "${DIM}  Работает с помощью zapret2 на уровне TCP-пакетов: ${NC}"
        echo -e "${DIM}  disorder + badsum + window control"
        echo ""
        echo -e "  ${YELLOW}[3]${NC}  ${BOLD}v2 фикс iptables${NC} (Разделение устройств определяя их TTL+Length)"
        echo -e "${DIM}  Если TTL <65 и length 64 -> это ios и принимаем пакеты без лимита"
        echo -e "${DIM}  Иначе -> это другое ус-во и ставим SYN 1 пакет в 1.1 сек."
        echo ""
        echo -e "  ${GREEN}[4]${NC}  ${BOLD}v3 фикс nftables${GREEN}${BOLD} - рекомендуется (Совместим с Docker)${NC}"
        echo -e "${DIM}  Если совпало -> это ios и принимаем пакеты без лимита"
        echo -e "${DIM}  Если не совпало -> это другое ус-во и ставим SYN 1 пакет в 1.1 сек."
        echo -e "  ${YELLOW}[5]${NC}  ${BOLD}v2 фикс nftables${NC}${BOLD}${NC}${BOLD} (Совместим с Docker)"
        echo -e "${DIM}  Если TTL <65 и length 64 -> это ios и принимаем пакеты без лимита"
        echo -e "${DIM}  Иначе -> это другое ус-во и ставим SYN 1 пакет в 1.1 сек."
        echo ""
        echo -e "  ${CYAN}[B]${NC}  ${BOLD}Бэкап и восстановление правил/фикса${NC} ${DIM}(backup_panel.sh --scope fix)${NC}"
        echo -e "  ${CYAN}[0]${NC}  ${BOLD}Назад/Выход${NC} ${DIM}(ничего не устанавливать)${NC}"
        echo ""
        if { : </dev/tty; } 2>/dev/null; then
            echo -en "  ${NC}${BOLD}Ввод (По умолчанию - ${GREEN}${BOLD}1 или enter${NC}${BOLD}):${NC} "
            read -r fix_choice </dev/tty
        else
            echo -en "  ${NC}${BOLD}Ввод (${GREEN}${BOLD}По умолчанию - 1(Enter)${NC}${BOLD}):${NC} "
            { read -r fix_choice; } 2>/dev/null || true
        fi

        case "$fix_choice" in
            0|q|Q)
                echo ""
                log_info "Выход без установки SYN FIX"
                return 0
                ;;
            B|b|Б|б)
                echo ""
                _rules_backup_fix
                echo ""
                pause_key "Нажмите любую клавишу для возврата в меню..."
                continue
                ;;
        esac

        if [ -z "$fix_choice" ] || [ "$fix_choice" = "1" ]; then
            FIX_TYPE="new"
            log_info "Выбран v3 iptables"
        elif [ "$fix_choice" = "2" ]; then
            FIX_TYPE="zapret2"
            log_info "Выбран Zapret2 fix"
        elif [ "$fix_choice" = "3" ]; then
            FIX_TYPE="old"
            log_info "Выбран v2 iptables"
        elif [ "$fix_choice" = "4" ]; then
            FIX_TYPE="docker_smart"
            log_info "Выбран v3 nftables"
        elif [ "$fix_choice" = "5" ]; then
            FIX_TYPE="docker_classic"
            log_info "Выбран v2 nftables"
        else
            log_warning "Неверный выбор, используем первый вариант"
            FIX_TYPE="new"
        fi
        break
        done
    fi

    # ── Если выбран Zapret2 fix в интерактивном режиме ────────
    if [ "$FIX_TYPE" = "zapret2" ]; then
        if [ -f "/opt/mtpr-simple/data/zapret2_fix.sh" ]; then
            source /opt/mtpr-simple/data/zapret2_fix.sh
            if declare -f show_zapret2_menu >/dev/null 2>&1; then
                show_zapret2_menu
            else
                log_error "Функция show_zapret2_menu недоступна (файл zapret2_fix.sh не загружен или повреждён)"
            fi
        else
            log_error "zapret2_fix.sh не найден, скачиваю..."
            mkdir -p /opt/mtpr-simple/data
            curl -fsSL "https://raw.githubusercontent.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/main/data/zapret2_fix.sh" -o /opt/mtpr-simple/data/zapret2_fix.sh
            chmod +x /opt/mtpr-simple/data/zapret2_fix.sh
            source /opt/mtpr-simple/data/zapret2_fix.sh
            if declare -f show_zapret2_menu >/dev/null 2>&1; then
                show_zapret2_menu
            else
                log_error "Функция show_zapret2_menu недоступна (файл zapret2_fix.sh не загружен или повреждён)"
            fi
        fi
        return 0
    fi

    # ── Парсим порты ──────────────────────────────────────────
    IFS=',' read -ra PORTS_ARRAY <<< "$ports_input"
    local valid_ports=()
    for p in "${PORTS_ARRAY[@]}"; do
        p=$(echo "$p" | xargs)
        if [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ]; then
            valid_ports+=("$p")
        else
            log_warning "Некорректный порт '$p' пропущен"
        fi
    done

    if [ ${#valid_ports[@]} -eq 0 ]; then
        log_error "Нет корректных портов для установки"
        if [ "$auto_install" = false ] && { : </dev/tty; } 2>/dev/null; then
            pause_key "Нажмите любую клавишу..."
        fi
        return 1
    fi

    local ports_str
    ports_str=$(IFS=,; echo "${valid_ports[*]}")
    log_info "Установка SYN FIX на порты: $ports_str"

    # ── nftables режимы ──────────────────────────────────────
    if [ "$FIX_TYPE" = "docker_smart" ] || [ "$FIX_TYPE" = "docker_classic" ]; then
        # Проверяем nftables
        if ! command -v nft &>/dev/null; then
            log_warning "nftables не установлен, устанавливаю..."
            if command -v apt-get &>/dev/null; then
                apt-get update -qq && apt-get install -y -qq nftables
            elif command -v yum &>/dev/null; then
                yum install -y -q nftables
            elif command -v dnf &>/dev/null; then
                dnf install -y -q nftables
            else
                log_error "Не удалось установить nftables автоматически"
                if [ "$auto_install" = false ] && { : </dev/tty; } 2>/dev/null; then
                    pause_key "Нажмите любую клавишу"
                fi
                return 1
            fi
        fi

        if [ "$auto_install" = false ]; then
            echo ""
            log_warning "Будет выполнена установка SYN FIX (nftables) на порты: $ports_str"
            echo ""
            echo -e "  ${BOLD}Что будет сделано:${NC}"
            echo -e "  • Будет создана таблица nftables ${CYAN}mtpr_synfix${NC}"
            echo -e "  • Добавлены правила SYN-фильтрации для портов: ${CYAN}$ports_str${NC}"
            echo -e "  • Будет создан systemd сервис ${CYAN}mtpr-nft-synfix.service${NC}"
            echo ""
            log_warning "${BOLD}ВНИМАНИЕ:${NC} Данная настройка изменит файрвол системы."
            echo ""
            if { : </dev/tty; } 2>/dev/null; then
                echo -en "  ${BOLD}Продолжить установку? Y/n:${NC} "
                read -r confirm </dev/tty
            else
                echo -en "  ${BOLD}Продолжить установку? Y/n:${NC} "
                { read -r confirm; } 2>/dev/null || true
            fi
            if [[ -z "$confirm" || "$confirm" =~ ^[yY]$ ]]; then
                : # продолжить
            else
                log_info "Установка отменена"
                sleep 0.5
                return 1
            fi
        fi

        log_info "Установка nftables режима..."

        local NFT_SCRIPT="/opt/mtpr-simple/mtpr-synfix-nft.sh"

        cat > "$NFT_SCRIPT" << 'NFT_WRAPPER_EOF'
#!/bin/sh
set -eu

TABLE="mtpr_synfix"
CHAIN="input"

nft delete table inet "$TABLE" 2>/dev/null || true
nft add table inet "$TABLE"
nft "add chain inet $TABLE $CHAIN { type filter hook input priority -10; policy accept; }"

NFT_WRAPPER_EOF

        local NFT_RULES_TEMPLATE="/opt/mtpr-simple/mtpr-synfix-nft.rules.tmpl"
        if [ "$FIX_TYPE" = "docker_smart" ]; then
            cat > "$NFT_RULES_TEMPLATE" << 'SMART_RULES_EOF'
nft "add rule inet mtpr_synfix input tcp dport PORT_HERE tcp flags & (syn | ack) == syn @th,108,20 0x2ffff @th,160,16 0x204 @th,192,16 0x103 @th,224,24 0x10108 @th,320,32 0x4020000 counter accept comment \"ios_accept\""
nft "add rule inet mtpr_synfix input tcp dport PORT_HERE tcp flags & (syn | ack) == syn meter mtpr_other { ip saddr timeout 60s limit rate 54/minute burst 1 packets } counter accept comment \"other_accept\""
nft "add rule inet mtpr_synfix input tcp dport PORT_HERE tcp flags & (syn | ack) == syn meter mtpr_other6 { ip6 saddr timeout 60s limit rate 54/minute burst 1 packets } counter accept comment \"other_accept6\""
nft "add rule inet mtpr_synfix input tcp dport PORT_HERE tcp flags & (syn | ack) == syn counter reject with tcp reset comment \"other_reject\""
SMART_RULES_EOF
        else
            cat > "$NFT_RULES_TEMPLATE" << 'CLASSIC_RULES_EOF'
nft "add rule inet mtpr_synfix input tcp dport PORT_HERE tcp flags & (syn | ack) == syn meter mtpr_classic { ip saddr timeout 60s limit rate 1/second burst 1 packets } counter drop comment \"classic_drop\""
nft "add rule inet mtpr_synfix input tcp dport PORT_HERE tcp flags & (syn | ack) == syn meter mtpr_classic6 { ip6 saddr timeout 60s limit rate 1/second burst 1 packets } counter drop comment \"classic_drop6\""
CLASSIC_RULES_EOF
        fi

        # Рендерим шаблон отдельно на КАЖДЫЙ порт (не in-place),
        # иначе первый sed уничтожает все PORT_HERE и порты после первого теряются
        for port in "${valid_ports[@]}"; do
            sed "s/PORT_HERE/${port}/g" "$NFT_RULES_TEMPLATE" >> "$NFT_SCRIPT"
        done
        rm -f "$NFT_RULES_TEMPLATE"

        chmod +x "$NFT_SCRIPT"

        if /bin/sh "$NFT_SCRIPT"; then
            log_success "NFT правила применены успешно"
        else
            log_error "Ошибка применения NFT правил"
            if [ "$auto_install" = false ] && { : </dev/tty; } 2>/dev/null; then
                pause_key "Нажмите любую клавишу"
            fi
            return 1
        fi

        cat > /etc/systemd/system/mtpr-nft-synfix.service << 'SERVICE_NFT_EOF'
[Unit]
Description=MTProto SYN FIX (nftables) for Telemt/Docker
After=network-online.target netfilter-persistent.service docker.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh /opt/mtpr-simple/mtpr-synfix-nft.sh
ExecStop=/bin/sh -c '/usr/sbin/nft delete table inet mtpr_synfix 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
SERVICE_NFT_EOF

        systemctl daemon-reload || log_warning "systemctl daemon-reload завершился с ошибкой"
        systemctl enable mtpr-nft-synfix.service 2>/dev/null \
            || log_warning "Не удалось выполнить systemctl enable mtpr-nft-synfix.service"
        systemctl restart mtpr-nft-synfix.service 2>/dev/null \
            || log_error "Не удалось выполнить systemctl restart mtpr-nft-synfix.service (правила в ядре применены, но автозапуск не активен)"
        log_info "Автозапуск mtpr-nft-synfix.service: $(systemctl is-enabled mtpr-nft-synfix.service 2>/dev/null || echo неизвестно)"

        save_port "$ports_str"
        log_success "SYN FIX (nftables) успешно установлен на порты: $ports_str"
        if [ "$auto_install" = false ] && { : </dev/tty; } 2>/dev/null; then
            pause_key "Нажмите любую клавишу"
        fi
        return 0
    fi

    # ── iptables режимы (v2 и v3) ──────────────────────────
    # На Debian 13 / Ubuntu 24+ пакет iptables может отсутствовать (остаётся
    # только nft). Без бинарника правила молча не применяются — ставим пакет.
    if ! command -v iptables >/dev/null 2>&1; then
        log_info "iptables не найден, устанавливаю..."
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -qq && apt-get install -y -qq iptables
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y -q iptables
        elif command -v yum >/dev/null 2>&1; then
            yum install -y -q iptables
        elif command -v apk >/dev/null 2>&1; then
            apk add --no-cache iptables
        fi
        if ! command -v iptables >/dev/null 2>&1; then
            log_error "iptables не установлен — V2/V3 без него не работают (установите пакет iptables вручную)"
            if [ "$auto_install" = false ] && { : </dev/tty; } 2>/dev/null; then
                pause_key "Нажмите любую клавишу..."
            fi
            return 1
        fi
    fi

    if [ "$auto_install" = false ]; then
        echo ""
        log_warning "Будет выполнена установка SYN FIX на порты: $ports_str"
        echo ""
        echo -e "  ${BOLD}Что будет сделано:${NC}"
        echo -e "  • Создана отдельная цепочка iptables ${CYAN}$SYNFIX_CHAIN${NC}"
        echo -e "  • Добавлены правила SYN-фильтрации для портов: ${CYAN}$ports_str${NC}"
        echo -e "  • Вы сможете удалить данную настройку через меню скрипта."
        echo ""
        log_warning "${BOLD}ВНИМАНИЕ:${NC} Данная настройка изменит файрвол системы."
        echo ""
        if { : </dev/tty; } 2>/dev/null; then
            echo -en "  ${BOLD}Продолжить установку? [Y/n]:${NC} "
            read -r confirm </dev/tty
        else
            echo -en "  ${BOLD}Продолжить установку? [Y/n]:${NC} "
            { read -r confirm; } 2>/dev/null || true
        fi
        if [[ -z "$confirm" || "$confirm" =~ ^[yY]$ ]]; then
            : # продолжить
        else
            log_info "Установка отменена"
            sleep 0.5
            return 1
        fi
    fi

    # ── Для v3 (u32) заранее убеждаемся, что модуль xt_u32 реально доступен ──
    if [ "$FIX_TYPE" = "new" ] && ! u32_module_available; then
        echo ""
        echo -e "  ${YELLOW}[!]${NC} Модуль xt_u32 не найден на этой системе"
        echo -e "  ${YELLOW}[!]${NC} Он необходим для варианта V3 (iptables + u32)"
        echo ""
        if [ "$auto_install" = true ]; then
            log_info "Автоматическая установка kmod-xt_u32 через elrepo..."
            if ! install_u32_module_elrepo; then
                log_warning "Модуль xt_u32 поставить не удалось — маркировка iOS пойдёт через nftables (модуль не нужен)."
            fi
        else
            echo -e "  ${BOLD}Установить необходимый модуль xt_u32?${NC}"
            echo -e "  ${GREEN}Enter/Y${NC} — установить и продолжить"
            echo -e "  ${RED}N/n${NC} — отменить установку и вернуться в меню"
            echo ""
            if { : </dev/tty; } 2>/dev/null; then
                echo -en "  ${BOLD}Ввод:${NC} "
                { read -r install_u32 </dev/tty; } 2>/dev/null || install_u32=""
            else
                echo -en "  ${BOLD}Ввод:${NC} "
                read -r install_u32 2>/dev/null || install_u32=""
            fi
            if [[ -z "$install_u32" || "$install_u32" =~ ^[yY]$ ]]; then
                if ! install_u32_module_elrepo; then
                    log_warning "Модуль xt_u32 поставить не удалось — маркировка iOS пойдёт через nftables (модуль не нужен)."
                fi
            else
                log_info "Установка отменена"
                if { : </dev/tty; } 2>/dev/null; then
                    pause_key "Нажмите любую клавишу..."
                fi
                return 0
            fi
        fi
    fi

    # Скрипт применения читает порты из файла, поэтому пишем его здесь —
    # после всех подтверждений, но до применения правил.
    save_port "$ports_str"
    generate_apply_script "$FIX_TYPE" "${valid_ports[@]}"
    generate_service_unit
    systemctl daemon-reload || log_warning "systemctl daemon-reload завершился с ошибкой"

    local apply_output
    local apply_exit_code
    if apply_output=$(PORT="$ports_str" /opt/mtpr-simple/apply-mtpr-synfix.sh 2>&1); then
        apply_exit_code=0
    else
        apply_exit_code=$?
    fi

    # ── Явная проверка результата: успех НЕ определяется пустым выводом + кодом 0 ──
    # Проверяем ядро, а не лог. На RHEL-семействе первый проход иногда
    # проигрывает гонку (юнит остаётся inactive) — тогда один повтор.
    if [ "$FIX_TYPE" = "new" ]; then
        local _rules_ok=false _nft_dump=""
        if iptables -t mangle -C PREROUTING -m u32 --u32 "$U32_FILTER" -j MARK --set-mark 0x400 2>/dev/null; then
            _rules_ok=true
        else
            # Без пайпа: nft пишет больше, чем grep -q успевает прочитать, и при
            # pipefail SIGPIPE от grep даёт ложное «правил нет».
            _nft_dump=$(nft list table inet mtpr_synfix_u32 2>/dev/null || true)
            case "$_nft_dump" in *"@nh"*) _rules_ok=true ;; esac
        fi
        if [ "$_rules_ok" != true ]; then
            systemctl restart mtpr-synfix.service >/dev/null 2>&1 || true
            sleep 1
            if iptables -t mangle -C PREROUTING -m u32 --u32 "$U32_FILTER" -j MARK --set-mark 0x400 2>/dev/null; then
                _rules_ok=true
            else
                _nft_dump=$(nft list table inet mtpr_synfix_u32 2>/dev/null || true)
                case "$_nft_dump" in *"@nh"*) _rules_ok=true ;; esac
            fi
        fi
        if [ "$_rules_ok" != true ]; then
            log_error "SYN FIX (v3/u32) НЕ применён: ни правило u32 в mangle, ни таблица nft не созданы"
            echo -e "  ${DIM}apply_output:${NC} ${apply_output:-<пусто>}"
            if [ "$auto_install" = false ] && { : </dev/tty; } 2>/dev/null; then
                pause_key "Нажмите любую клавишу..."
            fi
            return 1
        fi
    fi

    if [ "$apply_exit_code" -ne 0 ]; then
        log_error "Ошибка применения правил iptables:"
        echo "$apply_output"
        if [ "$auto_install" = false ] && { : </dev/tty; } 2>/dev/null; then
            pause_key "Нажмите любую клавишу..."
        fi
        return 1
    fi

    systemctl enable mtpr-synfix.service \
        || log_warning "Не удалось выполнить systemctl enable mtpr-synfix.service"
    systemctl restart mtpr-synfix.service \
        || log_error "Не удалось выполнить systemctl restart mtpr-synfix.service (правила в ядре применены, но автозапуск не активен)"
    log_info "Автозапуск mtpr-synfix.service: $(systemctl is-enabled mtpr-synfix.service 2>/dev/null || echo неизвестно)"
    log_success "SYN FIX успешно установлен на порты: $ports_str"
    # Порт должен быть разрешён и в активном файрволе (ufw/firewalld), иначе
    # входящие SYN не доходят до прокси (issue #34).
    for _fw_port in "${valid_ports[@]}"; do
        open_port_in_firewall "$_fw_port"
    done
    if [ "$auto_install" = false ] && { : </dev/tty; } 2>/dev/null; then
        pause_key "Нажмите любую клавишу..."
    fi

    # Успешное завершение интерактивной установки: rc=0 независимо от
    # того, попал ли последний паузный `read` в EOF (иначе `-menu` из pty
    # завершался бы с кодом 1 и это маскировалось лишь прежним `|| true`).
    return 0
}

install_nft_auto() {
    local ports_str="$1"
    IFS=',' read -ra PORTS_ARRAY <<< "$ports_str"
    local valid_ports=()
    for p in "${PORTS_ARRAY[@]}"; do
        p=$(echo "$p" | xargs)
        if [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ]; then
            valid_ports+=("$p")
        else
            log_warning "Некорректный порт '$p' пропущен"
        fi
    done
    if [ ${#valid_ports[@]} -eq 0 ]; then
        log_error "Нет корректных портов"
        return 1
    fi

    local ports_str_clean
    ports_str_clean=$(IFS=,; echo "${valid_ports[*]}")


    # Проверяем nftables
    if ! command -v nft &>/dev/null; then
        log_warning "nftables не установлен, устанавливаю..."
        if command -v apt-get &>/dev/null; then
            apt-get update -qq && apt-get install -y -qq nftables
        elif command -v yum &>/dev/null; then
            yum install -y -q nftables
        elif command -v dnf &>/dev/null; then
            dnf install -y -q nftables
        else
            log_error "Не удалось установить nftables автоматически"
            return 1
        fi
    fi

    local NFT_SCRIPT="/opt/mtpr-simple/mtpr-synfix-nft.sh"
    cat > "$NFT_SCRIPT" << 'NFT_WRAPPER_EOF'
#!/bin/sh
set -eu

TABLE="mtpr_synfix"
CHAIN="input"

nft delete table inet "$TABLE" 2>/dev/null || true
nft add table inet "$TABLE"
nft "add chain inet $TABLE $CHAIN { type filter hook input priority -10; policy accept; }"

NFT_WRAPPER_EOF

    local NFT_RULES_TEMPLATE="/opt/mtpr-simple/mtpr-synfix-nft.rules.tmpl"
    cat > "$NFT_RULES_TEMPLATE" << 'SMART_RULES_EOF'
nft "add rule inet mtpr_synfix input tcp dport PORT_HERE tcp flags & (syn | ack) == syn @th,108,20 0x2ffff @th,160,16 0x204 @th,192,16 0x103 @th,224,24 0x10108 @th,320,32 0x4020000 counter accept comment \"ios_accept\""
nft "add rule inet mtpr_synfix input tcp dport PORT_HERE tcp flags & (syn | ack) == syn meter mtpr_other { ip saddr timeout 60s limit rate 54/minute burst 1 packets } counter accept comment \"other_accept\""
nft "add rule inet mtpr_synfix input tcp dport PORT_HERE tcp flags & (syn | ack) == syn meter mtpr_other6 { ip6 saddr timeout 60s limit rate 54/minute burst 1 packets } counter accept comment \"other_accept6\""
nft "add rule inet mtpr_synfix input tcp dport PORT_HERE tcp flags & (syn | ack) == syn counter reject with tcp reset comment \"other_reject\""
SMART_RULES_EOF

    # Рендерим шаблон отдельно на КАЖДЫЙ порт (не in-place),
    # иначе первый sed уничтожает все PORT_HERE и порты после первого теряются
    for port in "${valid_ports[@]}"; do
        sed "s/PORT_HERE/${port}/g" "$NFT_RULES_TEMPLATE" >> "$NFT_SCRIPT"
    done
    rm -f "$NFT_RULES_TEMPLATE"

    chmod +x "$NFT_SCRIPT"

    if /bin/sh "$NFT_SCRIPT"; then
        log_success "NFT правила применены успешно"
    else
        log_error "Ошибка применения NFT правил"
        return 1
    fi

    cat > /etc/systemd/system/mtpr-nft-synfix.service << 'SERVICE_NFT_EOF'
[Unit]
Description=MTProto SYN FIX (nftables) for Telemt/Docker
After=network-online.target netfilter-persistent.service docker.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh /opt/mtpr-simple/mtpr-synfix-nft.sh
ExecStop=/bin/sh -c '/usr/sbin/nft delete table inet mtpr_synfix 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
SERVICE_NFT_EOF

    systemctl daemon-reload || log_warning "systemctl daemon-reload завершился с ошибкой"
    systemctl enable mtpr-nft-synfix.service 2>/dev/null \
        || log_warning "Не удалось выполнить systemctl enable mtpr-nft-synfix.service"
    systemctl restart mtpr-nft-synfix.service 2>/dev/null \
        || log_error "Не удалось выполнить systemctl restart mtpr-nft-synfix.service (правила в ядре применены, но автозапуск не активен)"
    log_info "Автозапуск mtpr-nft-synfix.service: $(systemctl is-enabled mtpr-nft-synfix.service 2>/dev/null || echo неизвестно)"

    save_port "$ports_str_clean"
    log_success "SYN FIX (nftables) успешно установлен на порты: $ports_str_clean"
    # Разрешаем порты и в активном файрволе (ufw/firewalld) — issue #34.
    for _fw_port in "${valid_ports[@]}"; do
        open_port_in_firewall "$_fw_port"
    done
    return 0
}

# ── Удаление SYN FIX ────────────────────────────────────────
remove_syn_fix() {
    log_info "Удаление SYN FIX..."

    systemctl stop mtpr-synfix.service 2>/dev/null || true
    systemctl disable mtpr-synfix.service 2>/dev/null || true

    if iptables -C INPUT -j "$SYNFIX_CHAIN" 2>/dev/null; then
        iptables -D INPUT -j "$SYNFIX_CHAIN"
        log_info "Цепочка $SYNFIX_CHAIN отключена от INPUT"
    fi

    if iptables -L "$SYNFIX_CHAIN" -n >/dev/null 2>&1; then
        iptables -F "$SYNFIX_CHAIN"
        iptables -X "$SYNFIX_CHAIN"
        log_info "Цепочка $SYNFIX_CHAIN удалена"
    fi

    local u32_filter="32 & 0x000FFFFF = 0x0002FFFF && 40 & 0xFF000000 = 0x02000000 && 44 & 0xFFFF0000 = 0x01030000 && 48 & 0xFFFFFF00 = 0x01010800 && 60 & 0xFFFFFFFF = 0x04020000"
    
    if iptables -t mangle -L PREROUTING -n 2>/dev/null | grep -q "$u32_filter"; then
        log_info "Обнаружены правила u32 в mangle (iptables), удаляем..."
        iptables -t mangle -L PREROUTING --line-numbers 2>/dev/null | grep "$u32_filter" | awk '{print $1}' | tac | while read -r num; do
            if [ -n "$num" ]; then
                iptables -t mangle -D PREROUTING "$num" 2>/dev/null && log_info "Удалено правило u32 (номер $num)"
            fi
        done
    else
        log_info "Правил с нашим u32-фильтром в iptables/mangle не найдено"
    fi

    if command -v nft >/dev/null 2>&1; then
        if nft list table inet mtpr_synfix &>/dev/null; then
            log_info "Обнаружена таблица inet mtpr_synfix (nftables), удаляем..."
            nft delete table inet mtpr_synfix 2>/dev/null && log_info "Таблица inet mtpr_synfix удалена"
        else
            log_info "Таблицы inet mtpr_synfix не найдено"
        fi

        handles=$(nft -a list chain ip mangle PREROUTING 2>/dev/null | grep 'xt match "u32".*meta mark set 0x400' | grep -o 'handle [0-9]*' | awk '{print $2}') || true
        if [ -n "$handles" ]; then
            log_info "Найдены правила u32 в nftables (ip mangle), удаляем..."
            for h in $handles; do
                nft delete rule ip mangle PREROUTING handle "$h" 2>/dev/null && log_info "Удалено правило u32 через nftables (handle $h)"
            done
        fi

        nft delete table inet mtpr_synfix 2>/dev/null || true
    fi

    rm -f "$PORT_FILE"
    rm -f /etc/systemd/system/mtpr-synfix.service

    systemctl stop mtpr-nft-synfix.service 2>/dev/null || true
    systemctl disable mtpr-nft-synfix.service 2>/dev/null || true
    rm -f /etc/systemd/system/mtpr-nft-synfix.service
    rm -f /opt/mtpr-simple/mtpr-synfix-nft.sh

    systemctl daemon-reload

    log_success "SYN FIX (iptables + nftables) удалён"
}

# ── Точка входа при прямом запуске файла ────────────────────
#   bash data/rules.sh -geoip            -> меню GEOIP (шапка-статус, [1]/[2]/[0])
#   bash data/rules.sh -geoip install    -> установить GEOIP (неинтерактивно)
#   bash data/rules.sh -geoip status     -> статус GEOIP (неинтерактивно)
#   bash data/rules.sh -geoip remove     -> удалить GEOIP (неинтерактивно)
#   bash data/rules.sh [-menu]           -> интерактивное меню фикса
_rules_usage() {
    cat <<'USAGE'
Использование: bash data/rules.sh [КЛЮЧ]

  (без ключа)        интерактивное меню фикса (только при наличии tty)
  -menu              интерактивное меню фикса (только при наличии tty)
  -geoip             меню GEOIP (шапка-статус, [1]/[2]/[0])
  -geoip install     установить GEOIP (неинтерактивно)
  -geoip status      статус GEOIP (неинтерактивно)
  -geoip remove      удалить GEOIP (неинтерактивно)
  -auto_install ...  неинтерактивная установка фикса
USAGE
}

_rules_entrypoint() {
    case "${1:-}" in
        -geoip)
            if [ -n "${2:-}" ]; then
                install_syn_fix -geoip "$2"
            else
                install_syn_fix -geoip
            fi
            ;;
        -menu)
            install_syn_fix
            ;;
        "")
            # Без аргументов: меню только при доступном tty.
            # Без tty (setsid/SSH/`<&-`) — печатаем справку и НИЧЕГО не устанавливаем.
            if { : </dev/tty; } 2>/dev/null; then
                install_syn_fix
            else
                _rules_usage
            fi
            ;;
        *)
            install_syn_fix "$@"
            ;;
    esac
}

# Запускать только при прямом вызове (не при `source` из main.sh/node-manager)
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    _rules_entrypoint "$@"
fi
