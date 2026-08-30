#!/usr/bin/env bash

set -Eeuo pipefail
umask 027

# stdout предназначен для автоматизации: при успехе в нём только одна tg:// ссылка.
exec 3>&1
exec 1>&2

readonly APP_NAME="tg-meko-proxy"
readonly APP_DIR="/opt/${APP_NAME}"
readonly CONFIG_DIR="/etc/${APP_NAME}"
readonly DATA_DIR="/var/lib/${APP_NAME}"
readonly CONFIG_FILE="${CONFIG_DIR}/telemt.toml"
readonly LINK_FILE="${DATA_DIR}/proxy.link"
readonly STATE_FILE="${DATA_DIR}/state.env"
readonly TELEMT_SERVICE="${APP_NAME}.service"
readonly NFT_SERVICE="${APP_NAME}-synfix.service"
readonly TELEMT_UNIT="/etc/systemd/system/${TELEMT_SERVICE}"
readonly NFT_UNIT="/etc/systemd/system/${NFT_SERVICE}"
readonly NFT_SCRIPT="${APP_DIR}/apply-synfix.sh"
readonly NFT_TABLE="tg_meko_proxy"
readonly SERVICE_USER="tg-meko-proxy"
readonly SERVICE_GROUP="tg-meko-proxy"
readonly DEFAULT_TELEMT_VERSION="3.5.5"
readonly DEFAULT_SNI_DOMAIN="rutube.ru"
readonly DEFAULT_PORT_MIN="10000"
readonly DEFAULT_PORT_MAX="29999"

TELEMT_VERSION="${TELEMT_VERSION:-${DEFAULT_TELEMT_VERSION}}"
SNI_DOMAIN="${SNI_DOMAIN:-${DEFAULT_SNI_DOMAIN}}"
PORT_MIN="${PORT_MIN:-${DEFAULT_PORT_MIN}}"
PORT_MAX="${PORT_MAX:-${DEFAULT_PORT_MAX}}"
REQUESTED_PORT="${PORT:-}"
PUBLIC_HOST="${PUBLIC_HOST:-}"
FORCE_REINSTALL="${FORCE_REINSTALL:-0}"
ALLOW_UNSUPPORTED_UBUNTU="${ALLOW_UNSUPPORTED_UBUNTU:-0}"

TEMP_DIR=""
BACKUP_DIR=""
COMMIT_STARTED=0
HAD_INSTALL=0
OLD_WAS_ACTIVE=0
UFW_RULE_ADDED=0
FIREWALLD_RULE_ADDED=0
PORT=""

log() {
    printf '[%s] %s\n' "$APP_NAME" "$*" >&2
}

die() {
    log "ОШИБКА: $*"
    exit 1
}

cleanup() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf -- "$TEMP_DIR"
    fi
}

restore_previous_install() {
    set +e
    systemctl stop "$TELEMT_SERVICE" "$NFT_SERVICE" >/dev/null 2>&1
    /usr/sbin/nft delete table inet "$NFT_TABLE" >/dev/null 2>&1

    if (( HAD_INSTALL )); then
        rm -rf -- "$APP_DIR" "$CONFIG_DIR" "$DATA_DIR"
        rm -f -- "$TELEMT_UNIT" "$NFT_UNIT"
        for target in "$APP_DIR" "$CONFIG_DIR" "$DATA_DIR" "$TELEMT_UNIT" "$NFT_UNIT"; do
            if [[ -e "${BACKUP_DIR}${target}" ]]; then
                mkdir -p -- "$(dirname "$target")"
                cp -a -- "${BACKUP_DIR}${target}" "$target"
            fi
        done
        systemctl daemon-reload
        systemctl enable "$NFT_SERVICE" "$TELEMT_SERVICE" >/dev/null 2>&1
        if (( OLD_WAS_ACTIVE )); then
            systemctl restart "$NFT_SERVICE" "$TELEMT_SERVICE" >/dev/null 2>&1
        fi
    else
        systemctl disable "$TELEMT_SERVICE" "$NFT_SERVICE" >/dev/null 2>&1
        rm -rf -- "$APP_DIR" "$CONFIG_DIR" "$DATA_DIR"
        rm -f -- "$TELEMT_UNIT" "$NFT_UNIT"
        systemctl daemon-reload
    fi

    if (( UFW_RULE_ADDED )); then
        ufw --force delete allow "${PORT}/tcp" >/dev/null 2>&1
    fi
    if (( FIREWALLD_RULE_ADDED )); then
        firewall-cmd --permanent --remove-port="${PORT}/tcp" >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    fi
}

on_error() {
    local exit_code=$?
    local line_no=${1:-unknown}
    trap - ERR
    if (( COMMIT_STARTED )); then
        log "Сбой установки в строке ${line_no}; восстанавливаю предыдущее состояние"
        restore_previous_install
    else
        log "Сбой установки в строке ${line_no}; конфигурация служб не изменялась"
    fi
    exit "$exit_code"
}

trap cleanup EXIT
trap 'on_error $LINENO' ERR

require_root() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] || die "запустите установщик от root"
}

validate_os() {
    [[ -r /etc/os-release ]] || die "не найден /etc/os-release"
    # shellcheck disable=SC1091
    source /etc/os-release
    [[ ${ID:-} == "ubuntu" ]] || die "поддерживается только Ubuntu 24.x–26.x"
    local major=${VERSION_ID%%.*}
    if [[ ! "$major" =~ ^[0-9]+$ ]] || (( major < 24 || major > 26 )); then
        [[ "$ALLOW_UNSUPPORTED_UBUNTU" == "1" ]] || die "Ubuntu ${VERSION_ID:-неизвестно} не поддерживается; требуется версия 24.x–26.x"
        log "ПРЕДУПРЕЖДЕНИЕ: включён тестовый режим на неподдерживаемой Ubuntu ${VERSION_ID:-неизвестно}"
    fi
    command -v systemctl >/dev/null || die "необходим systemd"
}

validate_inputs() {
    [[ "$TELEMT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "некорректная TELEMT_VERSION"
    [[ "$SNI_DOMAIN" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]] || die "некорректный SNI_DOMAIN"
    [[ "$PORT_MIN" =~ ^[0-9]+$ && "$PORT_MAX" =~ ^[0-9]+$ ]] || die "некорректный диапазон портов"
    (( PORT_MIN >= 1024 && PORT_MAX <= 65535 && PORT_MIN <= PORT_MAX )) || die "диапазон портов должен находиться в пределах 1024–65535"
    if [[ -n "$REQUESTED_PORT" ]]; then
        [[ "$REQUESTED_PORT" =~ ^[0-9]+$ ]] || die "PORT должен быть числом"
        (( REQUESTED_PORT != 443 )) || die "порт 443 оставлен существующим сервисам и не будет изменён"
        (( REQUESTED_PORT >= 1024 && REQUESTED_PORT <= 65535 )) || die "PORT должен находиться в пределах 1024–65535"
    fi
}

port_is_free() {
    local candidate=$1
    (( candidate != 443 )) || return 1
    ! ss -H -lnt "sport = :${candidate}" | grep -q . &&
        ! ss -H -lnu "sport = :${candidate}" | grep -q .
}

choose_port() {
    local candidate
    if [[ -n "$REQUESTED_PORT" ]]; then
        port_is_free "$REQUESTED_PORT" || die "запрошенный порт ${REQUESTED_PORT} уже занят"
        PORT=$REQUESTED_PORT
        return
    fi

    for _ in $(seq 1 256); do
        candidate=$(shuf -i "${PORT_MIN}-${PORT_MAX}" -n 1)
        if port_is_free "$candidate"; then
            PORT=$candidate
            return
        fi
    done
    die "не удалось найти свободный TCP/UDP-порт в диапазоне ${PORT_MIN}–${PORT_MAX}"
}

discover_public_host() {
    local candidate=""
    if [[ -n "$PUBLIC_HOST" ]]; then
        [[ "$PUBLIC_HOST" =~ ^[A-Za-z0-9.-]+$ ]] || die "некорректный PUBLIC_HOST"
        return
    fi
    for endpoint in \
        "https://api.ipify.org" \
        "https://ifconfig.me/ip" \
        "https://ipv4.icanhazip.com"; do
        candidate=$(curl -4fsS --connect-timeout 4 --max-time 8 "$endpoint" 2>/dev/null | tr -d '[:space:]') || true
        if [[ "$candidate" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            PUBLIC_HOST=$candidate
            return
        fi
    done
    die "не удалось определить публичный IPv4; задайте PUBLIC_HOST явно"
}

existing_install_is_healthy() {
    [[ "$FORCE_REINSTALL" != "1" ]] || return 1
    [[ -s "$LINK_FILE" && -s "$STATE_FILE" ]] || return 1
    systemctl is-active --quiet "$TELEMT_SERVICE" || return 1
    systemctl is-active --quiet "$NFT_SERVICE" || return 1
    local old_port
    old_port=$(awk -F= '$1 == "PORT" {print $2}' "$STATE_FILE" | tail -1)
    [[ "$old_port" =~ ^[0-9]+$ ]] || return 1
    ss -H -lnt "sport = :${old_port}" | grep -q . || return 1
    return 0
}

install_dependencies() {
    export DEBIAN_FRONTEND=noninteractive
    export NEEDRESTART_MODE=l
    apt-get update -qq
    apt-get install -y -qq ca-certificates curl iproute2 nftables openssl tar util-linux
}

check_sni() {
    log "Проверяю TLS 1.3 на домене ${SNI_DOMAIN}"
    if ! timeout 12 openssl s_client -connect "${SNI_DOMAIN}:443" -servername "$SNI_DOMAIN" -tls1_3 </dev/null 2>/dev/null | grep -q "TLSv1.3"; then
        die "домен ${SNI_DOMAIN} не прошёл проверку TLS 1.3"
    fi

    if openssl list -tls-groups 2>/dev/null | grep -q 'X25519MLKEM768'; then
        timeout 12 openssl s_client -connect "${SNI_DOMAIN}:443" -servername "$SNI_DOMAIN" -groups X25519MLKEM768 </dev/null 2>/dev/null |
            grep -q "TLSv1.3" || die "домен ${SNI_DOMAIN} не прошёл проверку X25519MLKEM768"
    else
        log "OpenSSL не поддерживает дополнительную проверку X25519MLKEM768; использую проверенный SNI по умолчанию"
    fi
}

download_telemt() {
    local arch asset base_url
    arch=$(uname -m)
    case "$arch" in
        x86_64) asset="telemt-x86_64-linux-gnu.tar.gz" ;;
        aarch64|arm64) asset="telemt-aarch64-linux-gnu.tar.gz" ;;
        *) die "неподдерживаемая архитектура процессора: ${arch}" ;;
    esac
    base_url="https://github.com/telemt/telemt/releases/download/${TELEMT_VERSION}"

    log "Загружаю Telemt ${TELEMT_VERSION} (${arch})"
    curl -fL --retry 3 --connect-timeout 10 -o "${TEMP_DIR}/${asset}" "${base_url}/${asset}"
    curl -fL --retry 3 --connect-timeout 10 -o "${TEMP_DIR}/${asset}.sha256" "${base_url}/${asset}.sha256"
    (
        cd "$TEMP_DIR"
        sha256sum -c "${asset}.sha256"
        tar -xzf "$asset"
    )
    [[ -x "${TEMP_DIR}/telemt" ]] || die "в архиве Telemt нет исполняемого файла"
    "${TEMP_DIR}/telemt" --version | grep -q "${TELEMT_VERSION}" || die "версия загруженного Telemt не совпадает с запрошенной"
}

create_service_account() {
    if ! getent group "$SERVICE_GROUP" >/dev/null; then
        groupadd --system "$SERVICE_GROUP"
    fi
    if ! id "$SERVICE_USER" >/dev/null 2>&1; then
        useradd --system --gid "$SERVICE_GROUP" --home-dir "$DATA_DIR" --shell /usr/sbin/nologin "$SERVICE_USER"
    fi
}

stage_files() {
    local secret=$1
    local domain_hex=$2
    local link=$3

    cat >"${TEMP_DIR}/telemt.toml" <<EOF
[general]
use_middle_proxy = true

[general.modes]
classic = false
secure = false
tls = true

[server]
port = ${PORT}

[server.api]
enabled = false

[censorship]
tls_domain = "${SNI_DOMAIN}"

[access.users]
proxy = "${secret}"
EOF

    cat >"${TEMP_DIR}/${TELEMT_SERVICE}" <<EOF
[Unit]
Description=Отдельный MTProto-прокси Telemt
Documentation=https://github.com/telemt/telemt
Requires=${NFT_SERVICE}
After=network-online.target ${NFT_SERVICE}
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_GROUP}
WorkingDirectory=${DATA_DIR}
ExecStart=${APP_DIR}/telemt ${CONFIG_FILE}
Restart=on-failure
RestartSec=5s
LimitNOFILE=65536
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
ReadWritePaths=${DATA_DIR}

[Install]
WantedBy=multi-user.target
EOF

    # SYN-правила V3 для nftables адаптированы из MTPROTO_FIX_By_MEKO.
    cat >"${TEMP_DIR}/apply-synfix.sh" <<EOF
#!/bin/sh
set -eu
NFT=\$(command -v nft)
TABLE="${NFT_TABLE}"
\$NFT delete table inet "\$TABLE" 2>/dev/null || true
\$NFT add table inet "\$TABLE"
\$NFT "add chain inet \$TABLE input { type filter hook input priority 0; policy accept; }"
\$NFT "add rule inet \$TABLE input tcp dport ${PORT} tcp flags & (syn|ack) == syn @th,108,20 0x2ffff @th,160,16 0x204 @th,192,16 0x103 @th,224,24 0x10108 @th,320,32 0x4020000 counter accept comment \"ios_accept\""
\$NFT "add rule inet \$TABLE input tcp dport ${PORT} tcp flags & (syn|ack) == syn meter tg_meko_other { ip saddr timeout 60s limit rate 54/minute burst 1 packets } counter accept comment \"other_accept\""
\$NFT "add rule inet \$TABLE input meta nfproto ipv4 tcp dport ${PORT} tcp flags & (syn|ack) == syn counter reject with icmp type host-unreachable comment \"other_reject\""
EOF

    cat >"${TEMP_DIR}/${NFT_SERVICE}" <<EOF
[Unit]
Description=SYN-фикс MEKO V3 для ${APP_NAME}
Documentation=https://github.com/Mekotofeuka/MTPROTO_FIX_By_MEKO
After=network-pre.target
Before=${TELEMT_SERVICE}

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh ${NFT_SCRIPT}
ExecStop=/bin/sh -c 'nft delete table inet ${NFT_TABLE} 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
EOF

    cat >"${TEMP_DIR}/state.env" <<EOF
PORT=${PORT}
PUBLIC_HOST=${PUBLIC_HOST}
SNI_DOMAIN=${SNI_DOMAIN}
TELEMT_VERSION=${TELEMT_VERSION}
DOMAIN_HEX=${domain_hex}
EOF
    printf '%s\n' "$link" >"${TEMP_DIR}/proxy.link"
}

backup_existing_install() {
    BACKUP_DIR="${TEMP_DIR}/backup"
    mkdir -p "$BACKUP_DIR"
    for target in "$APP_DIR" "$CONFIG_DIR" "$DATA_DIR" "$TELEMT_UNIT" "$NFT_UNIT"; do
        if [[ -e "$target" ]]; then
            HAD_INSTALL=1
            mkdir -p -- "${BACKUP_DIR}$(dirname "$target")"
            cp -a -- "$target" "${BACKUP_DIR}${target}"
        fi
    done
    if systemctl is-active --quiet "$TELEMT_SERVICE"; then
        OLD_WAS_ACTIVE=1
    fi
}

open_local_firewall() {
    if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; then
        if ! ufw status | grep -Eq "^${PORT}/tcp[[:space:]]+ALLOW"; then
            ufw allow "${PORT}/tcp" >/dev/null
            UFW_RULE_ADDED=1
        fi
    fi
    if command -v firewall-cmd >/dev/null && systemctl is-active --quiet firewalld; then
        if ! firewall-cmd --quiet --query-port="${PORT}/tcp"; then
            firewall-cmd --permanent --add-port="${PORT}/tcp" >/dev/null
            firewall-cmd --reload >/dev/null
            FIREWALLD_RULE_ADDED=1
        fi
    fi
}

commit_install() {
    local old_port=""
    if [[ -s "$STATE_FILE" ]]; then
        old_port=$(awk -F= '$1 == "PORT" {print $2}' "$STATE_FILE" | tail -1)
    fi

    port_is_free "$PORT" || die "порт ${PORT} оказался занят перед запуском службы"
    backup_existing_install
    COMMIT_STARTED=1

    systemctl stop "$TELEMT_SERVICE" "$NFT_SERVICE" >/dev/null 2>&1 || true
    create_service_account
    install -d -o root -g root -m 0755 "$APP_DIR"
    install -d -o root -g "$SERVICE_GROUP" -m 0750 "$CONFIG_DIR"
    install -d -o "$SERVICE_USER" -g "$SERVICE_GROUP" -m 0750 "$DATA_DIR"
    install -o root -g root -m 0755 "${TEMP_DIR}/telemt" "${APP_DIR}/telemt"
    install -o root -g "$SERVICE_GROUP" -m 0640 "${TEMP_DIR}/telemt.toml" "$CONFIG_FILE"
    install -o root -g root -m 0755 "${TEMP_DIR}/apply-synfix.sh" "$NFT_SCRIPT"
    install -o root -g root -m 0644 "${TEMP_DIR}/${TELEMT_SERVICE}" "$TELEMT_UNIT"
    install -o root -g root -m 0644 "${TEMP_DIR}/${NFT_SERVICE}" "$NFT_UNIT"
    install -o root -g root -m 0600 "${TEMP_DIR}/state.env" "$STATE_FILE"
    install -o root -g root -m 0600 "${TEMP_DIR}/proxy.link" "$LINK_FILE"

    open_local_firewall
    systemctl daemon-reload
    systemctl enable "$NFT_SERVICE" "$TELEMT_SERVICE" >/dev/null
    systemctl restart "$NFT_SERVICE"
    /usr/sbin/nft list table inet "$NFT_TABLE" >/dev/null
    systemctl restart "$TELEMT_SERVICE"

    local ready=0
    for _ in $(seq 1 30); do
        if systemctl is-active --quiet "$TELEMT_SERVICE" && ss -H -lnt "sport = :${PORT}" | grep -q .; then
            ready=1
            break
        fi
        sleep 1
    done
    if (( ! ready )); then
        journalctl -u "$TELEMT_SERVICE" -n 80 --no-pager >&2 || true
        return 1
    fi

    timeout 5 bash -c "exec 8<>/dev/tcp/127.0.0.1/${PORT}" || return 1

    local upstream_ok=0
    for _ in $(seq 1 20); do
        # grep -q здесь не используется: при pipefail раннее совпадение может
        # передать journalctl сигнал SIGPIPE и превратить успешную проверку в сбой.
        if journalctl -u "$TELEMT_SERVICE" -n 250 --no-pager | grep -F 'RPC handshake OK' >/dev/null; then
            upstream_ok=1
            break
        fi
        sleep 1
    done
    if (( ! upstream_ok )); then
        journalctl -u "$TELEMT_SERVICE" -n 80 --no-pager >&2 || true
        return 1
    fi

    if [[ "$old_port" =~ ^[0-9]+$ && "$old_port" != "$PORT" ]]; then
        if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; then
            ufw --force delete allow "${old_port}/tcp" >/dev/null 2>&1 || true
        fi
        if command -v firewall-cmd >/dev/null && systemctl is-active --quiet firewalld; then
            firewall-cmd --permanent --remove-port="${old_port}/tcp" >/dev/null 2>&1 || true
            firewall-cmd --reload >/dev/null 2>&1 || true
        fi
    fi

    COMMIT_STARTED=0
}

main() {
    require_root
    validate_os
    validate_inputs

    exec 9>/run/${APP_NAME}-install.lock
    flock -n 9 || die "уже запущен другой экземпляр установщика"

    if existing_install_is_healthy; then
        cat "$LINK_FILE" >&3
        exit 0
    fi

    TEMP_DIR=$(mktemp -d "/tmp/${APP_NAME}.XXXXXX")
    install_dependencies
    choose_port
    discover_public_host
    check_sni
    download_telemt

    local secret domain_hex link
    secret=$(openssl rand -hex 16)
    domain_hex=$(printf '%s' "$SNI_DOMAIN" | od -An -tx1 | tr -d ' \n')
    link="tg://proxy?server=${PUBLIC_HOST}&port=${PORT}&secret=ee${secret}${domain_hex}"

    stage_files "$secret" "$domain_hex" "$link"
    commit_install
    log "Установка и проверки завершены, порт ${PORT}"
    printf '%s\n' "$link" >&3
}

main "$@"
