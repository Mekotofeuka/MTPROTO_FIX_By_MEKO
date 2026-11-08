#!/bin/bash
# caddy_pq.sh — Caddy как PQ-заглушка (SelfSteal) без nginx + OpenSSL 3.5
#
# Caddy — статический Go-бинарь, X25519MLKEM768 включён по умолчанию,
# системный OpenSSL не нужен. Работает на Ubuntu 22.04/24.04.

set -euo pipefail

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

# ── Пути и константы ──────────────────────────────────────────
CADDYFILE="/etc/caddy/Caddyfile"
SITE_DIR="/var/www/site"
CERT_DIR_BASE="/etc/letsencrypt/live"
CERT_EXPORT_DIR="/etc/caddy/certs"
SERVICE="caddy"
PORT="8443"
# Маркер «наш» файл: по нему отличаем сгенерированный нами Caddyfile
# от чужого рабочего конфига, который нельзя затирать молча.
CADDY_MARKER="# managed by MEKO Manager"

# ── Логирование ───────────────────────────────────────────────
log_info()    { echo -e "  ${BLUE}[i]${NC} $1"; }
log_success() { echo -e "  ${GREEN}[✓]${NC} $1"; }
log_warning() { echo -e "  ${YELLOW}[!]${NC} $1"; }
log_error()   { echo -e "  ${RED}[✗]${NC} $1" >&2; }

# ── Обрезка пробелов ──────────────────────────────────────────
trim() {
    local var="$1"
    var="${var#"${var%%[![:space:]]*}"}"
    var="${var%"${var##*[![:space:]]}"}"
    printf '%s' "$var"
}

# ── Пауза (все read — с </dev/tty) ────────────────────────────
pause() {
    echo ""
    echo -e "  ${GRAY}Нажмите любую клавишу для продолжения...${NC}"
    { read -rsn1 </dev/tty; } 2>/dev/null || { echo; return 1; }
    IFS= read -r -t 0.05 _ </dev/tty 2>/dev/null || true
}

# ── Проверка root ─────────────────────────────────────────────
require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "Скрипт нужно запускать от root"
        return 1
    fi
}

# ── Скачивание файла с проверкой кода curl ────────────────────
# Никаких `curl | sh`: качаем во временный файл, проверяем код curl
# и непустой размер, только затем кладём на место.
download_file() {
    local url="$1" dest="$2"
    local tmp
    tmp=$(mktemp) || return 1
    if ! curl -fsSL --max-time 60 "$url" -o "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    if [ ! -s "$tmp" ]; then
        rm -f "$tmp"
        return 1
    fi
    mv -f "$tmp" "$dest"
}

# ── Валидация домена ──────────────────────────────────────────
is_valid_domain() {
    [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]
}

# ── Занят ли порт ─────────────────────────────────────────────
# Один awk вместо пайпа на grep: под set -euo pipefail `grep -q` выходит
# рано и роняет предыдущий awk по SIGPIPE (rc=141), из-за чего занятый
# порт мог ошибочно определиться как свободный.
port_is_busy() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -H -ltn 2>/dev/null | awk -v p=":${port}" '$4 ~ p"$" {f=1} END{exit !f}'
    elif command -v netstat >/dev/null 2>&1; then
        netstat -ltn 2>/dev/null | awk -v p=":${port}" '$4 ~ p"$" {f=1} END{exit !f}'
    else
        return 1
    fi
}

# ── Установка Caddy из официального репозитория ───────────────
install_caddy_repo() {
    local caddy_ver

    if ! command -v apt-get >/dev/null 2>&1; then
        # RHEL-семейство: официальный репозиторий Caddy — COPR.
        local pm=""
        if command -v dnf >/dev/null 2>&1; then
            pm="dnf"
        elif command -v yum >/dev/null 2>&1; then
            pm="yum"
        else
            log_error "Не найден apt-get/dnf/yum — не знаю, как ставить Caddy"
            return 1
        fi
        local dnf_opt=""
        if [ "$pm" = "dnf" ]; then
            dnf_opt="--setopt=timeout=15 --setopt=retries=1"
            [ -f /etc/yum.repos.d/elrepo.repo ] && dnf_opt="$dnf_opt --disablerepo=elrepo"
        fi
        log_info "Установка зависимостей..."
        "$pm" install -y -q $dnf_opt 'dnf-command(copr)' >/dev/null 2>&1 || true
        log_info "Добавление официального репозитория Caddy (COPR)..."
        "$pm" copr enable -y @caddy/caddy || { log_error "Не удалось подключить COPR @caddy/caddy"; return 1; }
        "$pm" install -y -q $dnf_opt caddy || { log_error "Не удалось установить caddy"; return 1; }
        caddy_ver=$(caddy version 2>/dev/null | grep -oE 'v?[0-9]+\.[0-9]+' | head -1 | tr -d 'v' || true)
        if [ -z "$caddy_ver" ] || [ "$(printf '%s\n2.10\n' "$caddy_ver" | LC_ALL=C sort -V | head -1)" != "2.10" ]; then
            log_error "Установлен Caddy ${caddy_ver:-неизвестной версии} — PQ (X25519MLKEM768) поддерживается только с Caddy 2.10+."
            return 1
        fi
        log_success "Caddy ${caddy_ver} — PQ (X25519MLKEM768) поддерживается"
        return 0
    fi

    local keyring="/usr/share/keyrings/caddy-stable-archive-keyring.gpg"
    local sourcelist="/etc/apt/sources.list.d/caddy-stable.list"

    log_info "Установка зависимостей..."
    apt-get update -qq || { log_error "apt-get update не удался"; return 1; }
    apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl gnupg \
        || { log_error "Не удалось установить зависимости"; return 1; }

    log_info "Добавление официального репозитория Caddy..."
    # Ключ cloudsmith отдаётся в ASCII-armor (-----BEGIN PGP PUBLIC KEY BLOCK-----),
    # apt такой файл НЕ принимает («unsupported filetype»), репозиторий остаётся
    # неподписанным и apt молча ставит старый caddy из репозитория дистрибутива
    # (2.6.x — без PQ). Поэтому ключ обязательно dearmor'им.
    local key_tmp
    key_tmp=$(mktemp) || { log_error "mktemp не удался"; return 1; }
    if ! curl -fsSL --max-time 60 "https://dl.cloudsmith.io/public/caddy/stable/gpg.key" -o "$key_tmp"; then
        rm -f "$key_tmp"; log_error "Не удалось скачать GPG-ключ Caddy"; return 1
    fi
    mkdir -p "$(dirname "$keyring")"
    if ! gpg --dearmor < "$key_tmp" > "$keyring"; then
        rm -f "$key_tmp" "$keyring"
        log_error "Не удалось преобразовать GPG-ключ Caddy (gpg --dearmor)"; return 1
    fi
    rm -f "$key_tmp"
    download_file "https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt" "$sourcelist" \
        || { log_error "Не удалось скачать список репозитория Caddy"; return 1; }

    apt-get update -qq || { log_error "apt-get update не удался"; return 1; }
    log_info "Установка пакета caddy..."
    apt-get install -y caddy || { log_error "Не удалось установить caddy"; return 1; }

    # Проверяем, что поставилась именно версия с PQ: X25519MLKEM768 есть с Caddy 2.10+
    # (Go 1.24). Старше — значит репозиторий cloudsmith не подключился и это
    # системный пакет, в котором PQ нет: фича бесполезна, честно падаем.
    local caddy_ver
    caddy_ver=$(caddy version 2>/dev/null | grep -oE 'v?[0-9]+\.[0-9]+' | head -1 | tr -d 'v' || true)
    if [ -z "$caddy_ver" ] || [ "$(printf '%s\n2.10\n' "$caddy_ver" | LC_ALL=C sort -V | head -1)" != "2.10" ]; then
        log_error "Установлен Caddy ${caddy_ver:-неизвестной версии} — PQ (X25519MLKEM768) поддерживается только с Caddy 2.10+."
        log_error "Скорее всего не подключился официальный репозиторий cloudsmith и взялся пакет из репозитория дистрибутива."
        log_error "Проверь: apt-cache policy caddy; ls -l /usr/share/keyrings/caddy-stable-archive-keyring.gpg"
        return 1
    fi
    log_success "Caddy ${caddy_ver} — PQ (X25519MLKEM768) поддерживается"
    return 0
}

# ── Получение сертификата Let's Encrypt ───────────────────────
obtain_certificate() {
    local domain="$1"
    local cert_dir="${CERT_DIR_BASE}/${domain}"

    if [ -f "${cert_dir}/fullchain.pem" ] && [ -f "${cert_dir}/privkey.pem" ]; then
        log_success "Сертификат уже существует: ${cert_dir}"
        return 0
    fi

    if ! command -v certbot >/dev/null 2>&1; then
        log_info "Установка certbot..."
        if command -v apt-get >/dev/null 2>&1; then
            apt-get install -y certbot || { log_error "Не удалось установить certbot"; return 1; }
        elif command -v dnf >/dev/null 2>&1; then
            local dop="--setopt=timeout=15 --setopt=retries=1"
            [ -f /etc/yum.repos.d/elrepo.repo ] && dop="$dop --disablerepo=elrepo"
            grep -qi '^ID=fedora' /etc/os-release 2>/dev/null || dnf install -y -q $dop epel-release >/dev/null 2>&1 || true
            dnf install -y -q $dop certbot python3-certbot-nginx || { log_error "Не удалось установить certbot (EPEL)"; return 1; }
            dnf install -y -q $dop python3-pyparsing >/dev/null 2>&1 || true
        elif command -v yum >/dev/null 2>&1; then
            yum install -y -q epel-release >/dev/null 2>&1 || true
            yum install -y -q certbot python3-certbot-nginx || { log_error "Не удалось установить certbot (EPEL)"; return 1; }
        else
            log_error "Не найден пакетный менеджер для установки certbot"
            return 1
        fi
    fi

    if systemctl is-active --quiet nginx 2>/dev/null; then
        log_info "Обнаружен активный nginx — получаю сертификат через плагин --nginx"
        if command -v apt-get >/dev/null 2>&1; then
            apt-get install -y python3-certbot-nginx >/dev/null 2>&1 || true
        elif command -v dnf >/dev/null 2>&1; then
            local dop2="--setopt=timeout=15 --setopt=retries=1"
            [ -f /etc/yum.repos.d/elrepo.repo ] && dop2="$dop2 --disablerepo=elrepo"
            dnf install -y -q $dop2 python3-certbot-nginx >/dev/null 2>&1 || true
        elif command -v yum >/dev/null 2>&1; then
            yum install -y -q python3-certbot-nginx >/dev/null 2>&1 || true
        fi
        certbot --nginx -d "$domain" --non-interactive --agree-tos --register-unsafely-without-email \
            || { log_error "certbot (--nginx) не смог получить сертификат"; return 1; }
    else
        log_info "Получение сертификата Let's Encrypt (standalone, нужен свободный порт 80)"
        if port_is_busy 80; then
            log_error "Порт 80 занят — certbot --standalone не сможет получить сертификат."
            log_error "Освободите порт 80 и повторите."
            return 1
        fi
        local was_active=false
        if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
            was_active=true
        fi
        systemctl stop "$SERVICE" 2>/dev/null || true
        if ! certbot certonly --standalone -d "$domain" --non-interactive --agree-tos --register-unsafely-without-email; then
            log_error "certbot (standalone) не смог получить сертификат"
            if [ "$was_active" = true ]; then
                log_info "Caddy был запущен — возвращаю в прежнее состояние..."
                systemctl start "$SERVICE" 2>/dev/null || log_warning "Не удалось запустить ${SERVICE} обратно"
            fi
            return 1
        fi
    fi

    if [ ! -f "${cert_dir}/fullchain.pem" ] || [ ! -f "${cert_dir}/privkey.pem" ]; then
        log_error "Сертификат не найден в ${cert_dir}"
        return 1
    fi
    return 0
}

# ── Копия сертификата, читаемая пользователем caddy ───────────
# Пакет Caddy в Debian/Ubuntu запускает службу под User=caddy, а
# /etc/letsencrypt/live у certbot — drwx------ root:root. Поэтому
# Caddyfile не может читать серт напрямую: копируем в отдельный
# каталог с группой caddy и правами 0640.
caddy_group() {
    if getent group caddy >/dev/null 2>&1; then
        printf 'caddy'
    else
        printf 'root'
    fi
}

export_cert_for_caddy() {
    local domain="$1"
    local src_dir="${CERT_DIR_BASE}/${domain}"
    local dst_dir="${CERT_EXPORT_DIR}/${domain}"
    local grp="" _ok=0

    if [ ! -f "${src_dir}/fullchain.pem" ] || [ ! -f "${src_dir}/privkey.pem" ]; then
        log_error "Сертификат не найден: ${src_dir}"
        return 1
    fi

    mkdir -p "$dst_dir" || return 1
    grp="$(caddy_group)"
    chown root:"$grp" "$dst_dir" 2>/dev/null || true
    chmod 755 "$CERT_EXPORT_DIR" 2>/dev/null || true
    chmod 750 "$dst_dir" 2>/dev/null || true
    cp -Lf "${src_dir}/fullchain.pem" "${dst_dir}/fullchain.pem" || return 1
    cp -Lf "${src_dir}/privkey.pem" "${dst_dir}/privkey.pem" || return 1
    chown root:"$grp" "${dst_dir}/fullchain.pem" "${dst_dir}/privkey.pem" 2>/dev/null || true
    chmod 640 "${dst_dir}/fullchain.pem" "${dst_dir}/privkey.pem" 2>/dev/null || true

    # Проверяем именно то, что важно: сможет ли caddy прочитать файлы.
    if id caddy >/dev/null 2>&1; then
        if command -v runuser >/dev/null 2>&1; then
            if runuser -u caddy -- test -r "${dst_dir}/fullchain.pem" 2>/dev/null; then
                if runuser -u caddy -- test -r "${dst_dir}/privkey.pem" 2>/dev/null; then
                    _ok=1
                fi
            fi
        else
            if su -s /bin/sh -c "test -r '${dst_dir}/fullchain.pem' && test -r '${dst_dir}/privkey.pem'" caddy >/dev/null 2>&1; then
                _ok=1
            fi
        fi
        if [ "$_ok" -ne 1 ]; then
            log_error "Caddy не сможет прочитать сертификат в ${dst_dir}"
            return 1
        fi
    fi

    log_success "Сертификат подготовлен для Caddy: ${dst_dir}"
    return 0
}

# ── Хук продления: обновляет копии после certbot renew ────────
install_cert_hook() {
    local hook_dir="/etc/letsencrypt/renewal-hooks/deploy"
    local hook="${hook_dir}/caddy-certs.sh"

    mkdir -p "$hook_dir" || return 1
    cat > "$hook" <<'HOOK'
#!/bin/sh
# managed by MEKO Manager: обновляет копии сертификатов для Caddy
set -eu
grp=root
if getent group caddy >/dev/null 2>&1; then
    grp=caddy
fi
for d in /etc/letsencrypt/live/*/; do
    [ -d "$d" ] || continue
    name=$(basename "$d")
    dst="/etc/caddy/certs/$name"
    [ -d "$dst" ] || continue
    cp -Lf "$d/fullchain.pem" "$dst/fullchain.pem"
    cp -Lf "$d/privkey.pem" "$dst/privkey.pem"
    chmod 640 "$dst/fullchain.pem" "$dst/privkey.pem"
    chown root:"$grp" "$dst/fullchain.pem" "$dst/privkey.pem" 2>/dev/null || true
done
if systemctl is-active --quiet caddy 2>/dev/null; then
    systemctl restart caddy || true
fi
exit 0
HOOK
    chmod 755 "$hook" || return 1
    log_success "Хук продления сертификата: ${hook}"
    return 0
}

# ── Запись Caddyfile ──────────────────────────────────────────
write_caddyfile() {
    local domain="$1"
    local fullchain="${CERT_EXPORT_DIR}/${domain}/fullchain.pem"
    local privkey="${CERT_EXPORT_DIR}/${domain}/privkey.pem"

    mkdir -p "$(dirname "$CADDYFILE")"

    # Не затираем чужой рабочий Caddyfile: если файл есть и в нём нет
    # нашего маркера — делаем бэкап и спрашиваем подтверждение.
    # Исключение — стандартный Caddyfile из пакета caddy (":80"): это не
    # чужой конфиг, а болванка, и спрашивать про неё незачем.
    if [ -f "$CADDYFILE" ] && ! grep -qF "$CADDY_MARKER" "$CADDYFILE" \
        && ! { grep -qF 'root * /usr/share/caddy' "$CADDYFILE" \
            && grep -qF 'The Caddyfile is an easy way to configure' "$CADDYFILE"; }; then
        local ts backup _ans
        ts=$(date +%Y%m%d-%H%M%S)
        backup="${CADDYFILE}.bak.${ts}"
        log_warning "Найден существующий ${CADDYFILE}, созданный НЕ нами."
        echo -e "  ${DIM}Перезапись уничтожит чужой конфиг Caddy.${NC}"
        echo -en "  ${BOLD}Сделать бэкап (${backup}) и перезаписать? [y/N]:${NC} "
        _ans=""
        { read -r _ans </dev/tty; } 2>/dev/null || { echo; log_error "Не удалось прочитать ответ — файл не изменён"; return 1; }
        if [[ ! "$_ans" =~ ^[yY]$ ]]; then
            log_error "Отменено: ${CADDYFILE} не изменён"
            return 1
        fi
        if ! cp -a "$CADDYFILE" "$backup"; then
            log_error "Не удалось сделать бэкап ${backup} — файл не изменён"
            return 1
        fi
        log_success "Бэкап сохранён: ${backup}"
    fi

    # Атомарная запись: пишем во временный файл в том же каталоге и
    # переименовываем — обрыв записи не оставит усечённый Caddyfile.
    local tmp_file="${CADDYFILE}.tmp.$$"
    if ! cat > "$tmp_file" <<EOF
${CADDY_MARKER}
{
	admin off
	auto_https off
	servers {
		protocols h1 h2
	}
}

https://${domain}:${PORT} {
	bind 127.0.0.1
	tls ${fullchain} ${privkey}
	root * ${SITE_DIR}
	file_server
}
EOF
    then
        log_error "Не удалось записать ${tmp_file}"
        rm -f "$tmp_file"
        return 1
    fi
    if ! mv -f "$tmp_file" "$CADDYFILE"; then
        log_error "Не удалось заменить ${CADDYFILE}"
        rm -f "$tmp_file"
        return 1
    fi
    log_success "Caddyfile записан: ${CADDYFILE}"
}

# ── Заглушка сайта ────────────────────────────────────────────
create_site_stub() {
    mkdir -p "$SITE_DIR"
    cat > "${SITE_DIR}/index.html" <<'EOF'
<!DOCTYPE html>
<html lang="ru">
<head><meta charset="utf-8"><title>Site</title></head>
<body><h1>It works!</h1></body>
</html>
EOF
    # Fedora/RHEL: без метки httpd_sys_content_t Caddy под SELinux отдаёт 403.
    if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce 2>/dev/null)" != "Disabled" ]; then
        chcon -R -t httpd_sys_content_t "$SITE_DIR" >/dev/null 2>&1 || true
    fi
    log_success "Заглушка создана: ${SITE_DIR}/index.html"
}

# ── Подсказка про @Sni_checker_bot ────────────────────────────
hint_sni_checker() {
    echo ""
    echo -e "  ${CYAN}${BOLD}Проверка:${NC} отправьте домен боту ${BOLD}@Sni_checker_bot${NC}"
    echo -e "  ${DIM}Ожидаемый результат: «Маркер: НЕТ» — PQ-заглушка Caddy работает.${NC}"
}

# ── Установка Caddy как PQ-заглушки ───────────────────────────
install_caddy_pq() {
    require_root || return 1

    echo ""
    log_info "Установка Caddy как PQ-заглушки (SelfSteal)"
    echo ""

    if ! command -v apt-get >/dev/null 2>&1 \
       && ! command -v dnf >/dev/null 2>&1 \
       && ! command -v yum >/dev/null 2>&1; then
        log_error "Не найден apt-get/dnf/yum (поддерживаются Debian/Ubuntu и RHEL-семейство)"
        pause || true
        return 1
    fi

    if port_is_busy "$PORT"; then
        log_error "Порт ${PORT} уже занят. Освободите его и повторите."
        pause || true
        return 1
    fi

    local domain
    echo -en "  ${BOLD}Введите домен${NC} ${DIM}(A-запись должна указывать на этот сервер)${NC}: "
    { read -r domain </dev/tty; } 2>/dev/null || { echo; return 1; }
    domain="$(trim "$domain")"
    if [ -z "$domain" ] || ! is_valid_domain "$domain"; then
        log_error "Некорректный домен: ${domain}"
        pause || true
        return 1
    fi

    if ! install_caddy_repo; then
        log_error "Установка Caddy прервана"
        pause || true
        return 1
    fi

    if ! obtain_certificate "$domain"; then
        log_error "Получение сертификата прервано"
        pause || true
        return 1
    fi

    if ! export_cert_for_caddy "$domain"; then
        log_error "Сертификат не подготовлен для Caddy"
        pause || true
        return 1
    fi

    if ! install_cert_hook; then
        log_error "Не удалось установить хук продления сертификата"
        pause || true
        return 1
    fi

    if ! write_caddyfile "$domain"; then
        log_error "Запись Caddyfile отменена или не удалась"
        pause || true
        return 1
    fi
    create_site_stub

    log_info "Перезапуск ${SERVICE} (при 'admin off' reload недоступен)..."
    systemctl enable "$SERVICE" >/dev/null 2>&1 || true
    if systemctl restart "$SERVICE"; then
        sleep 1
        if ! systemctl is-active --quiet "$SERVICE"; then
            log_error "Caddy упал сразу после старта: $(journalctl -u ${SERVICE} -n 20 --no-pager 2>/dev/null | grep -a '"level":"error"' | tail -1 | cut -c1-300)"
            pause || true
            return 1
        fi
        log_success "Caddy запущен и слушает 127.0.0.1:${PORT}"
        hint_sni_checker
    else
        log_error "Не удалось запустить ${SERVICE}. Проверьте: journalctl -u ${SERVICE} -n 50"
        pause || true
        return 1
    fi

    pause || true
    return 0
}

# ── Статус ────────────────────────────────────────────────────
show_status() {
    echo ""
    echo -e "  ${BOLD}Статус Caddy${NC}"
    echo -e "  ${DIM}===========================${NC}"

    if command -v caddy >/dev/null 2>&1; then
        local ver
        ver=$(caddy version 2>/dev/null || true)
        echo -e "  ${BOLD}Версия:${NC} ${CYAN}${ver}${NC}"
    else
        echo -e "  ${BOLD}Версия:${NC} ${RED}не установлен${NC}"
    fi

    if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
        echo -e "  ${BOLD}Служба:${NC} ${GREEN}active${NC}"
    else
        echo -e "  ${BOLD}Служба:${NC} ${RED}inactive${NC}"
    fi

    if systemctl is-enabled --quiet "$SERVICE" 2>/dev/null; then
        echo -e "  ${BOLD}Автозапуск:${NC} ${GREEN}enabled${NC}"
    else
        echo -e "  ${BOLD}Автозапуск:${NC} ${RED}disabled${NC}"
    fi

    if command -v ss >/dev/null 2>&1; then
        local listeners
        listeners=$(ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -E "[:.]${PORT}$" || true)
        if [ -n "$listeners" ]; then
            echo -e "  ${BOLD}Порт ${PORT}:${NC} ${GREEN}слушает${NC}"
            echo -e "  ${DIM}${listeners}${NC}"
        else
            echo -e "  ${BOLD}Порт ${PORT}:${NC} ${RED}не слушает${NC}"
        fi
    fi

    if [ -f "$CADDYFILE" ]; then
        echo -e "  ${BOLD}Caddyfile:${NC} ${CYAN}${CADDYFILE}${NC}"
    else
        echo -e "  ${BOLD}Caddyfile:${NC} ${RED}нет${NC}"
    fi

    return 0
}

# ── Удаление ──────────────────────────────────────────────────
remove_caddy_pq() {
    require_root || return 1

    echo ""
    echo -en "  ${BOLD}Удалить Caddy? [y/N]:${NC} "
    local ans
    { read -r ans </dev/tty; } 2>/dev/null || { echo; return 1; }
    if [[ ! "$ans" =~ ^[yY]$ ]]; then
        log_info "Удаление отменено"
        pause || true
        return 0
    fi

    log_info "Остановка и отключение ${SERVICE}..."
    systemctl stop "$SERVICE" 2>/dev/null || true
    systemctl disable "$SERVICE" 2>/dev/null || true

    log_info "Удаление пакета caddy..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get purge -y caddy || log_warning "apt-get purge caddy завершился с ошибкой"
        apt-get autoremove -y >/dev/null 2>&1 || true
    elif command -v dnf >/dev/null 2>&1; then
        dnf remove -y -q caddy || log_warning "dnf remove caddy завершился с ошибкой"
    elif command -v yum >/dev/null 2>&1; then
        yum remove -y -q caddy || log_warning "yum remove caddy завершился с ошибкой"
    fi

    echo -en "  ${BOLD}Удалить ${CADDYFILE} и ${SITE_DIR}? [y/N]:${NC} "
    local rmcfg
    { read -r rmcfg </dev/tty; } 2>/dev/null || { echo; return 1; }
    if [[ "$rmcfg" =~ ^[yY]$ ]]; then
        rm -f "$CADDYFILE"
        rm -rf "$SITE_DIR"
        rm -rf "$CERT_EXPORT_DIR"
        rm -f /etc/letsencrypt/renewal-hooks/deploy/caddy-certs.sh
        log_success "Caddyfile, заглушка, копии сертификатов и хук продления удалены"
    fi

    log_warning "Сертификат Let's Encrypt НЕ удалён (${CERT_DIR_BASE})."
    echo -e "  ${DIM}Для удаления: certbot delete --cert-name <домен>${NC}"

    pause || true
    return 0
}

# ── Меню ──────────────────────────────────────────────────────
menu() {
    local choice
    while true; do
        clear 2>/dev/null || true
        echo ""
        echo -e "  ${BOLD}Caddy как PQ-заглушка (SelfSteal)${NC}"
        echo -e "  ${DIM}=================================${NC}"
        show_status
        echo ""
        echo -e "  ${CYAN}[1]${NC}  ${BOLD}Установить Caddy как PQ-заглушку${NC}"
        echo -e "  ${RED}[2]${NC}  ${BOLD}Удалить Caddy${NC}"
        echo ""
        echo -e "  ${RED}[0]${NC}  ${BOLD}Назад${NC}"
        echo ""
        echo -en "  ${BOLD}Выбор:${NC} "
        { read -r choice </dev/tty; } 2>/dev/null || { echo; return 1; }

        case "$choice" in
            1) install_caddy_pq || true ;;
            2) remove_caddy_pq || true ;;
            0 | "") return 0 ;;
            *) echo "  Неверный выбор"; sleep 0.1 ;;
        esac
    done
}

menu || true
exit 0
