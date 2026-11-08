#!/bin/bash
# telemt_in_docker1.sh - Установка Telemt в Docker

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

# ── Функции логирования ─────────────────────────────────────
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

# ── Проверка root ────────────────────────────────────────────
# `return N 2>/dev/null || exit N` работает в обоих режимах запуска:
#   source из proxys/telemt1.sh -> return из файла (меню не гибнет);
#   прямой запуск (install_auto.sh) -> return неприменим, срабатывает exit.
if [ "$(id -u)" -ne 0 ]; then
    log_error "Требуются права root"
    # Файл обычно source-ится из telemt1.sh — не убиваем родительский процесс
    return 1 2>/dev/null || exit 1
fi

# ── Требуется интерактивный терминал ─────────────────────────
# Без терминала read с /dev/tty молча возвращает пустоту, и скрипт
# трактовал бы пустое подтверждение как согласие (боевая установка
# без согласия). Поэтому неинтерактивный запуск отменяем сразу.
if ! { : </dev/tty; } 2>/dev/null; then
    log_error "Нет интерактивного терминала — установка отменена"
    return 1 2>/dev/null || exit 1
fi

# ── Получаем последнюю версию Telemt ────────────────────────
log_info "Получение последней версии Telemt..."
TELEMT_VERSION=$(curl -fsSL --max-time 20 https://api.github.com/repos/telemt/telemt/releases/latest | grep -o '"tag_name": *"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/^v//')

if [ -z "$TELEMT_VERSION" ]; then
    log_warning "Не удалось получить версию, используем 3.4.22"
    TELEMT_VERSION="3.4.22"
else
    log_success "Последняя версия: $TELEMT_VERSION"
fi

# ── Проверка Docker ──────────────────────────────────────────
if ! command -v docker &>/dev/null; then
    log_warning "Docker не установлен"
    echo -en "  ${BOLD}Установить Docker? y/N:${NC} "
    { read -r install_docker </dev/tty; } 2>/dev/null || true
    if [[ "$install_docker" =~ ^[yY]$ ]]; then
        log_info "Установка Docker..."
        # Скачиваем во временный файл (непредсказуемое имя), чистим на всех путях.
        docker_inst=$(mktemp) || { log_error "Не удалось создать временный файл"; return 1 2>/dev/null || exit 1; }
        if ! curl -fsSL --max-time 60 https://get.docker.com -o "$docker_inst" || [ ! -s "$docker_inst" ]; then
            rm -f "$docker_inst"
            log_error "Не удалось скачать установщик Docker"
            pause_key "Нажмите любую клавишу для возврата..."
            return 1 2>/dev/null || exit 1
        fi
        if ! sh "$docker_inst"; then
            rm -f "$docker_inst"
            log_error "Установка Docker не удалась"
            pause_key "Нажмите любую клавишу для возврата..."
            return 1 2>/dev/null || exit 1
        fi
        rm -f "$docker_inst"
    else
        log_info "Установка отменена"
        pause_key "Нажмите любую клавишу для возврата..."
        return 0 2>/dev/null || exit 0
    fi
fi

# ── Проверка docker compose ──────────────────────────────────
# Docker из apt (docker.io) ставится БЕЗ плагина compose, и тогда
# `docker compose up -d` падает с «unknown shorthand flag: 'd' in -d»
# уже после того, как config.toml и docker-compose.yml созданы.
COMPOSE_CMD=""
if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD="docker-compose"
else
    log_warning "docker compose не найден — устанавливаю"
    # Пакеты называются по-разному, а apt падает на всём списке, если хотя бы
    # одного имени нет в репозитории, — поэтому пробуем их по одному.
    if command -v apt-get >/dev/null 2>&1; then
        for _pkg in docker-compose-v2 docker-compose-plugin docker-compose; do
            docker compose version >/dev/null 2>&1 && break
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$_pkg" >/dev/null 2>&1 || true
        done
    fi
    if ! docker compose version >/dev/null 2>&1 && ! command -v docker-compose >/dev/null 2>&1; then
        for _tool in dnf yum; do
            command -v "$_tool" >/dev/null 2>&1 || continue
            "$_tool" install -y -q docker-compose-plugin >/dev/null 2>&1 || true
            break
        done
    fi
    if docker compose version >/dev/null 2>&1; then
        COMPOSE_CMD="docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then
        COMPOSE_CMD="docker-compose"
    else
        log_error "docker compose недоступен — поставьте docker-compose-v2 (Debian/Ubuntu) или docker-compose-plugin (RHEL) и повторите"
        pause_key "Нажмите любую клавишу для возврата..."
        return 1 2>/dev/null || exit 1
    fi
    log_success "docker compose установлен"
fi

# ── Заголовок ─────────────────────────────────────────────────
clear 2>/dev/null || true
echo ""
echo -e "  ${BOLD}УСТАНОВКА TELEMT В DOCKER v0.2${NC}"
echo -e "  ${DIM}================================${NC}"
echo ""
echo -e "  Будет установлен Telemt ${GREEN}${TELEMT_VERSION}${NC} в Docker контейнере"
echo -e "  ${DIM}Версия: ${TELEMT_VERSION}${NC}"
echo ""
echo -en "  ${BOLD}Продолжить установку? y/N:${NC} "
{ read -r confirm </dev/tty; } 2>/dev/null || true
if [[ ! "$confirm" =~ ^[yY]$ ]]; then
    log_info "Установка отменена"
    pause_key "Нажмите любую клавишу для возврата..."
    return 0 2>/dev/null || exit 0
fi

# ── 1) Автозапуск Docker ─────────────────────────────────────
echo ""
echo -e "  ${BOLD}1. Включить автозапуск Docker при старте системы?${NC}"
echo -e "  ${DIM}(systemctl enable docker && systemctl start docker)${NC}"
echo -en "  ${BOLD}Включить? Y/n:${NC} "
{ read -r docker_autostart </dev/tty; } 2>/dev/null || true
if [[ -z "$docker_autostart" || "$docker_autostart" =~ ^[yY]$ ]]; then
    log_info "Включение автозапуска Docker..."
    if systemctl enable docker >/dev/null 2>&1 && systemctl start docker >/dev/null 2>&1; then
        log_success "Docker автозапуск включён"
    else
        log_warning "Не удалось включить автозапуск Docker (проверьте systemctl вручную)"
    fi
else
    log_info "Автозапуск Docker пропущен"
fi

# ── 2) Путь установки ────────────────────────────────────────
echo ""
echo -e "  ${BOLD}2. Путь установки Telemt${NC}"
echo -e "  ${DIM}По умолчанию: /root/telemt${NC}"
echo -en "  ${BOLD}Введите путь или нажмите Enter для выбора стандартного:${NC} "
{ read -r install_path </dev/tty; } 2>/dev/null || true
if [ -z "$install_path" ]; then
    install_path="/root/telemt"
fi
log_info "Путь: $install_path"

# ── 3) Порт ───────────────────────────────────────────────────
echo ""
echo -e "  ${BOLD}3. Порт для прокси${NC}"
echo -e "  ${DIM}По умолчанию: 443${NC}"
echo -en "  ${BOLD}Введите порт или нажмите Enter для выбора порта поумолчанию:${NC} "
{ read -r port_input </dev/tty; } 2>/dev/null || true
if [ -z "$port_input" ]; then
    port="443"
elif [[ "$port_input" =~ ^[0-9]+$ ]] && [ "$port_input" -ge 1 ] && [ "$port_input" -le 65535 ]; then
    port="$port_input"
else
    log_warning "Некорректный порт, используем 443"
    port="443"
fi
echo -e "  ${GREEN}✓${NC} Использован порт: ${CYAN}${port}${NC}"

# ── 4) Секрет (с циклом) ─────────────────────────────────────
echo ""
echo -e "  ${BOLD}4. Секрет для доступа к прокси${NC}"

gen_secret() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 16 2>/dev/null
    else
        head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n'
    fi
}

SECRET=""
while true; do
    # Генерируем секрет при первом проходе или при gen
    if [ -z "$SECRET" ]; then
        SECRET=$(gen_secret)
    fi
    
    echo -e "  ${DIM}Сгенерирован секрет: ${CYAN}${SECRET}${NC}"
    echo ""
    echo -e "  ${BOLD}Варианты:${NC}"
    echo -e "  ${GREEN}Enter/Y${NC} — использовать сгенерированный секрет"
    echo -e "  ${CYAN}Ввести вручную${NC} — указать свой секрет"
    echo -e "  ${RED}gen${NC} — перегенерировать новый секрет"
    echo ""
    echo -en "  ${BOLD}Ваш выбор:${NC} "
    { read -r secret_input </dev/tty; } 2>/dev/null || true
    
    if [[ "$secret_input" =~ ^[Gg][Ee][Nn]$ ]]; then
        SECRET=$(gen_secret)
        echo ""
        echo -e "  ${GREEN}✓${NC} Новый секрет: ${CYAN}${SECRET}${NC}"
        echo ""
        # Показываем меню снова с новым секретом
        continue
    elif [[ -n "$secret_input" ]] && [[ ! "$secret_input" =~ ^[yY]$ ]]; then
        # Ввели что-то кроме gen, enter, y, Y — это ручной секрет (hex), валидируем
        if ! [[ "$secret_input" =~ ^[0-9a-fA-F]{32}$ || "$secret_input" =~ ^[0-9a-fA-F]{64}$ ]]; then
            log_error "Секрет должен быть 32 или 64 hex-символа"
            continue
        fi
        SECRET="$secret_input"
        echo ""
        echo -e "  ${GREEN}✓${NC} Использован секрет: ${CYAN}${SECRET}${NC}"
        echo ""
        break
    else
        # Enter или y/Y
        echo ""
        echo -e "  ${GREEN}✓${NC} Использован сгенерированный секрет: ${CYAN}${SECRET}${NC}"
        echo ""
        break
    fi
done

# ── 5) TLS домен ─────────────────────────────────────────────
echo ""
echo -e "  ${BOLD}5. TLS домен для маскировки${NC}"
echo -e "  ${DIM}По умолчанию: rutube.ru${NC}"
echo -en "  ${BOLD}Введите домен или нажмите Enter для выбора rutube.ru:${NC} "
{ read -r tls_domain_input </dev/tty; } 2>/dev/null || true
if [ -z "$tls_domain_input" ]; then
    tls_domain="rutube.ru"
elif [[ "$tls_domain_input" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,253})$ ]]; then
    tls_domain="$tls_domain_input"
else
    log_error "Некорректный домен (допустимы буквы/цифры/точка/дефис)"
    return 1 2>/dev/null || exit 1
fi
echo -e "  ${GREEN}✓${NC} Использован домен: ${CYAN}${tls_domain}${NC}"

# ── 6) Определяем IP ─────────────────────────────────────────
SERVER_IP=""
for _ip_url in https://ifconfig.me/ip https://icanhazip.com https://api.ipify.org; do
    SERVER_IP=$(curl -4 -fsS --max-time 10 "$_ip_url" 2>/dev/null | tr -d '[:space:]')
    [ -n "$SERVER_IP" ] && break
done
if [ -z "$SERVER_IP" ]; then
    log_warning "Не удалось автоматически определить внешний IP"
    echo -en "  ${BOLD}Введите IP сервера вручную:${NC} "
    { read -r SERVER_IP </dev/tty; } 2>/dev/null || true
fi
if [ -z "$SERVER_IP" ]; then
    log_error "IP сервера не задан — установка отменена"
    return 1 2>/dev/null || exit 1
fi
echo ""
log_info "Обнаружен IP: $SERVER_IP"

# ── 7) Установка ─────────────────────────────────────────────
echo ""
log_info "Начинаем установку Telemt ${TELEMT_VERSION} в Docker..."
echo ""

# Создаем папку
if ! mkdir -p "$install_path" || ! cd "$install_path"; then
    log_error "Не удалось создать/перейти в каталог: $install_path"
    return 1 2>/dev/null || exit 1
fi
log_success "Папка создана: $install_path"

# Страховка: пустой секрет в конфиг писать нельзя
if [ -z "$SECRET" ]; then
    log_error "Не удалось сгенерировать секрет — установка отменена"
    return 1 2>/dev/null || exit 1
fi

# Создаем config.toml
cat > config.toml <<EOF
[general]
use_middle_proxy = true
log_level = "normal"

[general.modes]
classic = false
secure = false
tls = true

[general.links]
show = "*"
public_host = "$SERVER_IP"
public_port = $port

[server]
port = $port

[server.api]
enabled = true
listen = "0.0.0.0:9091"
whitelist = ["0.0.0.0/0"]

[censorship]
tls_domain = "$tls_domain"
mask = true
tls_emulation = true
tls_front_dir = "tlsfront"

[access.users]
myuser = "$SECRET"
EOF
log_success "config.toml создан"

# Создаем docker-compose.yml
cat > docker-compose.yml <<EOF
services:
  telemt:
    image: ghcr.io/telemt/telemt:${TELEMT_VERSION}
    container_name: telemt
    restart: unless-stopped
    ports:
      - "${port}:${port}"
      - "9091:9091"
    volumes:
      - ./config.toml:/app/config.toml:ro
      - ./tlsfront:/app/tlsfront:rw
    environment:
      - RUST_LOG=info
    cap_add:
      - NET_BIND_SERVICE
    cap_drop:
      - ALL
    ulimits:
      nofile:
        soft: 65536
        hard: 65536
    security_opt:
      - no-new-privileges:true
EOF
log_success "docker-compose.yml создан"

# Устанавливаем jq (в EL-семействе и Alpine пакетного скрипта "apt" нет)
if command -v apt >/dev/null 2>&1; then
    apt install -y jq >/dev/null 2>&1 || log_warning "Не удалось установить jq — ссылка может не отобразиться"
elif command -v dnf >/dev/null 2>&1; then
    _dop="--setopt=timeout=15 --setopt=retries=1"
    [ -f /etc/yum.repos.d/elrepo.repo ] && _dop="$_dop --disablerepo=elrepo"
    dnf install -y -q $_dop jq >/dev/null 2>&1 || log_warning "Не удалось установить jq — ссылка может не отобразиться"
elif command -v yum >/dev/null 2>&1; then
    yum install -y -q jq >/dev/null 2>&1 || log_warning "Не удалось установить jq — ссылка может не отобразиться"
elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache jq >/dev/null 2>&1 || log_warning "Не удалось установить jq — ссылка может не отобразиться"
fi

# Запускаем
log_info "Запуск Docker контейнера..."
if ! $COMPOSE_CMD up -d; then
    log_error "Ошибка запуска Telemt"
    return 1 2>/dev/null || exit 1
fi
log_success "Telemt успешно запущен"

# ── 8) Вывод ссылки ──────────────────────────────────────────
echo ""
echo -e "  ${BOLD}${GREEN}═════════════════════════════════════════════════${NC}"
echo -e "  ${BOLD}${GREEN}        TELEMT УСТАНОВЛЕН УСПЕШНО!${NC}"
echo -e "  ${BOLD}${GREEN}═════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${BOLD}ССЫЛКА ДЛЯ ПОДКЛЮЧЕНИЯ В TELEGRAM:${NC}"
echo ""

sleep 1

# Пробуем получить ссылку
LINK=$(curl -s http://localhost:9091/v1/users 2>/dev/null | jq -r '.data[].links.tls[]' 2>/dev/null | grep -v "::" | grep -v "0.0.0.0" | head -1)
if [ -n "$LINK" ]; then
    echo -e "  ${CYAN}${LINK}${NC}"
else
    echo -e "  ${YELLOW}Ссылка пока не доступна. Попробуйте позже:${NC}"
    echo -e "  ${DIM}  $COMPOSE_CMD logs -f${NC}"
    echo -e "  ${DIM}  Или проверьте вручную: curl http://localhost:9091/v1/users${NC}"
fi

echo ""
echo -e "  ${BOLD}Данные для подключения:${NC}"
echo -e "  ${BOLD}Версия:${NC} ${CYAN}${TELEMT_VERSION}${NC}"
echo -e "  ${BOLD}Секрет:${NC} ${CYAN}${SECRET}${NC}"
echo -e "  ${BOLD}IP сервера:${NC} ${CYAN}${SERVER_IP}${NC}"
echo -e "  ${BOLD}Порт:${NC} ${CYAN}${port}${NC}"
echo -e "  ${BOLD}TLS домен:${NC} ${CYAN}${tls_domain}${NC}"
echo ""
echo -e "  ${BOLD}Команды управления:${NC}"
echo -e "  ${DIM}  $COMPOSE_CMD logs -f  # просмотр логов${NC}"
echo -e "  ${DIM}  $COMPOSE_CMD restart  # перезапуск${NC}"
echo -e "  ${DIM}  $COMPOSE_CMD down     # остановка${NC}"
echo -e "  ${DIM}  $COMPOSE_CMD up -d    # запуск после остановки${NC}"
echo -e "  ${BOLD}${GREEN}═════════════════════════════════════════════════${NC}"
echo ""

pause_key "Нажмите любую клавишу для возврата в меню..."
return 0 2>/dev/null || exit 0
