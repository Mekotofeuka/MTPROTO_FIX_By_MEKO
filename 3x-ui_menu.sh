#!/bin/bash
# 3x-ui_menu.sh – Меню управления панелью 3x-ui

set -euo pipefail

# ── Цвета ─────────────────────────────────────────────────────
if [ -t 1 ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
    BLUE='\033[0;34m'; CYAN='\033[0;36m'; GRAY='\033[0;90m'
    BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; GRAY=''
    BOLD=''; DIM=''; NC=''
fi

log_info() { echo -e "  ${BLUE}[i]${NC} $1"; }
log_success() { echo -e "  ${GREEN}[✓]${NC} $1"; }
log_error() { echo -e "  ${RED}[✗]${NC} $1" >&2; }
log_warning() { echo -e "  ${YELLOW}[!]${NC} $1"; }

# ── Проверка root ────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}[✗]${NC} Запустите от root" >&2
    exit 1
fi

# ── URL-ы установщика 3x-ui-pro ──────────────────────────────
XUI_INSTALLER_URL="https://raw.githubusercontent.com/mozaroc/3x-ui-pro/main/x-ui-latest.sh"
XUI_PATCH_URL="https://raw.githubusercontent.com/mozaroc/3x-ui-pro/main/x-ui-patch.sh"

# ── Внешний IPv4 сервера ─────────────────────────────────────
get_public_ip() {
    local ip
    # pipefail активен: без `|| true` неудачный `ip route get` (нет маршрута)
    # сделал бы пайп фатальным и убил бы fallback на icanhazip ниже.
    ip=$(ip route get 8.8.8.8 2>/dev/null | grep -Po -- 'src \K\S*' | head -1 || true)
    if ! [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
        ip=$(curl -4 -fsS --max-time 10 https://ipv4.icanhazip.com 2>/dev/null | tr -d '[:space:]' || true)
    fi
    if [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
        echo "$ip"
    fi
}

# ── Пауза «нажмите любую клавишу» ────────────────────────────
pause_key() {
    { : </dev/tty; } 2>/dev/null || return 0
    echo -e "  ${GRAY}${1:-Нажмите любую клавишу для возврата...}${NC}"
    read -rsn1 </dev/tty || true
    IFS= read -r -t 0.05 _ </dev/tty 2>/dev/null || true
}

# ── Ввод домена (пустой ввод = значение по умолчанию) ────────
#  Спрашиваем через /dev/tty, значение отдаём в stdout — чтобы
#  вызывающий код мог забрать его через $(ask_domain ...).
ask_domain() {
    local prompt="$1" default="$2" value=""
    { echo -en "  ${BOLD}${prompt}${NC} ${DIM}[${default}]${NC}: " >/dev/tty; } 2>/dev/null || true
    { read -r value </dev/tty; } 2>/dev/null || value=""
    value="${value//[[:space:]]/}"
    if [ -n "$value" ]; then
        echo "$value"
    else
        echo "$default"
    fi
}

# ── Проверка, что домен указывает A-записью на наш IP ────────
domain_points_here() {
    local d="$1" ip="$2" a
    a=$(getent ahostsv4 "$d" 2>/dev/null | awk 'NR==1{print $1}' || true)
    [ "$a" = "$ip" ]
}

# ── Проверка установки 3x-ui ────────────────────────────────
is_3xui_installed() {
    command -v x-ui >/dev/null 2>&1
}

# ── Установка 3x-ui (с ожиданием освобождения apt) ──────────
install_3xui() {
    echo ""
    log_info "Установка 3x-ui..."
    echo ""

    # ── Проверка поддержки (как в upstream check_os/check_cpu) ──
    local os_id="" os_ver=""
    if [ -r /etc/os-release ]; then
        . /etc/os-release 2>/dev/null || true
        os_id="${ID:-}"
        os_ver="${VERSION_ID:-}"
    fi
    case "$os_id" in
        ubuntu)
            if [[ "$os_ver" != "24.04" && "$os_ver" != "26.04" ]]; then
                log_error "Установщик 3x-ui-pro поддерживает Ubuntu 24.04 и 26.04 (у вас $os_id $os_ver)."
                pause_key
                return 1
            fi
            ;;
        debian)
            if [[ "$os_ver" != "12" && "$os_ver" != "13" ]]; then
                log_error "Установщик 3x-ui-pro поддерживает Debian 12 и 13 (у вас $os_id $os_ver)."
                pause_key
                return 1
            fi
            ;;
        *)
            log_error "3x-ui-pro не поддерживает $os_id $os_ver (только Ubuntu 24.04/26.04, Debian 12/13)."
            pause_key
            return 1
            ;;
    esac
    if grep -qiE 'model name.*QEMU' /proc/cpuinfo 2>/dev/null; then
        log_error "Обнаружен эмулированный QEMU-процессор — установщик 3x-ui-pro откажется работать."
        log_error "Попросите хостера включить host-passthrough (host CPU)."
        pause_key
        return 1
    fi

    # ── Проверка занятости 443 ──────────────────────────────
    #  Upstream поднимает nginx с SSL на 443. Если порт занят (например telemt
    #  держит MTProto на 443), nginx не стартует и патч панели не применится —
    #  ровно это и наблюдалось вживую. Предупреждаем заранее.
    local holder443=""
    if command -v ss >/dev/null 2>&1 && [ -n "$(ss -tlnH 2>/dev/null | awk '$4 ~ /[:.]443$/ {print $4; exit}')" ]; then
        holder443=$(ss -tlnpH 2>/dev/null | awk '$4 ~ /[:.]443$/ {print $NF; exit}' || true)
        log_warning "Порт 443 уже занят${holder443:+ (${holder443})}!"
        log_warning "3x-ui-pro поднимает nginx+SSL на 443: пока порт занят, панель не установится полностью."
        log_warning "Освободите порт (например: systemctl stop telemt) и повторите установку."
        if { : </dev/tty; } 2>/dev/null; then
            echo -en "  ${BOLD}Продолжить всё равно? [y/N]:${NC} "
            local c443=""
            { read -r c443 </dev/tty; } 2>/dev/null || c443=""
            if [[ ! "$c443" =~ ^[yY]$ ]]; then
                log_info "Установка отменена. Освободите порт 443 и запустите снова."
                return 0
            fi
        else
            log_error "Порт 443 занят, а терминала для подтверждения нет."
            return 1
        fi
    fi

    # Проверка блокировки apt
    log_info "Проверка блокировки менеджера пакетов apt..."
    local wait_seconds=0
    local max_wait=120
    while command -v fuser >/dev/null 2>&1 && fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
        if [ "$wait_seconds" -ge "$max_wait" ]; then
            log_error "Блокировка apt не снята за $max_wait секунд."
            log_error "Попробуйте остановить unattended-upgrades вручную: sudo systemctl stop unattended-upgrades"
            pause_key
            return 1
        fi
        log_warning "Обнаружена блокировка apt (возможно, unattended-upgrades). Ждём 5 секунд..."
        sleep 5
        wait_seconds=$((wait_seconds + 5))
    done
    log_success "Блокировка apt снята, продолжаем установку."

    # ── Домены ──────────────────────────────────────────────
    #  Upstream-установщик НЕ знает флага -auto_domain (он принимает только
    #  -subdomain и -reality_domain). Если домен не передан, validate_domains()
    #  крутит бесконечный prompt «Enter available subdomain» (issue #28),
    #  поэтому домены спрашиваем сами и передаём явно.
    local IP PANEL_DOMAIN REALITY_DOMAIN
    IP=$(get_public_ip)
    if [ -z "$IP" ]; then
        log_error "Не удалось определить внешний IPv4 сервера."
        pause_key
        return 1
    fi

    echo ""
    log_info "Для установки нужны два разных домена с A-записью на IP ${BOLD}$IP${NC}"
    log_info "Пустое поле = бесплатный домен sslip.io (DNS уже настроен, сертификат Let's Encrypt)."
    echo ""
    if { : </dev/tty; } 2>/dev/null; then
        PANEL_DOMAIN=$(ask_domain "Домен панели:" "$IP.sslip.io")
        REALITY_DOMAIN=$(ask_domain "Домен REALITY (другой):" "reality.$IP.sslip.io")
    else
        PANEL_DOMAIN="$IP.sslip.io"
        REALITY_DOMAIN="reality.$IP.sslip.io"
    fi

    if [ "$PANEL_DOMAIN" = "$REALITY_DOMAIN" ]; then
        log_error "Домен панели и домен REALITY должны различаться."
        pause_key
        return 1
    fi

    local d
    for d in "$PANEL_DOMAIN" "$REALITY_DOMAIN"; do
        if ! domain_points_here "$d" "$IP"; then
            log_error "$d не указывает на $IP (нет A-записи)."
            log_error "Настройте DNS или оставьте поле пустым — подставится sslip.io."
            pause_key
            return 1
        fi
    done
    log_success "Домены проверены: $PANEL_DOMAIN / $REALITY_DOMAIN"

    # ── Установка ───────────────────────────────────────────
    local installer
    installer=$(mktemp /tmp/x-ui-latest.XXXXXX.sh) || { log_error "Не удалось создать временный файл (mktemp)"; return 1; }
    log_info "Загрузка установщика 3x-ui-pro..."
    if ! curl -fsSL "$XUI_INSTALLER_URL" -o "$installer" || [ ! -s "$installer" ]; then
        log_error "Не удалось загрузить установщик 3x-ui-pro."
        rm -f "$installer"
        pause_key
        return 1
    fi

    log_info "Запуск установки 3x-ui (это может занять несколько минут)..."
    echo ""
    local rc=0
    if { : </dev/tty; } 2>/dev/null; then
        bash "$installer" -install y -subdomain "$PANEL_DOMAIN" -reality_domain "$REALITY_DOMAIN" </dev/tty || rc=$?
    else
        bash "$installer" -install y -subdomain "$PANEL_DOMAIN" -reality_domain "$REALITY_DOMAIN" </dev/null || rc=$?
    fi
    rm -f "$installer"

    if [ "$rc" -eq 0 ]; then
        log_success "3x-ui установлен"
    else
        log_error "Ошибка установки 3x-ui (код возврата $rc)"
        pause_key
        return 1
    fi

    # ── Проверка, что служба поднялась ──────────────────────
    sleep 2
    if is_3xui_installed && systemctl is-active --quiet x-ui; then
        log_success "Служба x-ui активна"
    else
        log_warning "Служба x-ui не активна — проверьте: journalctl -u x-ui -n 50"
    fi

    # ── Применение патча ────────────────────────────────────
    log_info "Применение патча 3x-ui..."
    wait_seconds=0
    while command -v fuser >/dev/null 2>&1 && fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
        if [ "$wait_seconds" -ge "$max_wait" ]; then
            log_warning "Блокировка apt не снята, патч может не примениться."
            break
        fi
        log_warning "Снова блокировка apt, ждём 5 секунд..."
        sleep 5
        wait_seconds=$((wait_seconds + 5))
    done

    local patcher
    patcher=$(mktemp /tmp/x-ui-patch.XXXXXX.sh) || { log_error "Не удалось создать временный файл (mktemp)"; return 1; }
    rc=0
    if ! curl -fsSL "$XUI_PATCH_URL" -o "$patcher" || [ ! -s "$patcher" ]; then
        rc=1
    else
        bash "$patcher" </dev/null || rc=$?
    fi
    rm -f "$patcher"
    if [ "$rc" -eq 0 ]; then
        log_success "Патч применён"
    else
        log_warning "Патч не применился (возможно, он не требуется или apt всё ещё занят)"
    fi

    echo ""
    log_success "Установка 3x-ui завершена!"
    pause_key
}

# ── Выполнение команды x-ui с проверкой установки ────────────
run_xui_cmd() {
    local cmd="$1"
    local desc="$2"
    
    if ! is_3xui_installed; then
        echo ""
        log_error "Панель 3x-ui не установлена. Сначала выполните установку (пункт 1)."
        pause_key
        return 1
    fi
    
    echo ""
    log_info "$desc..."
    echo ""
    case "$cmd" in
        log)
            # Логи показываем с возможностью выхода по Ctrl+C
            x-ui log
            ;;
        *)
            x-ui "$cmd"
            ;;
    esac
    echo ""
    pause_key "Нажмите любую клавишу для возврата в меню..."
}

# ── Главное меню 3x-ui ────────────────────────────────────────
while true; do
    if [ -t 1 ]; then clear 2>/dev/null || printf '\033[2J\033[H'; fi
    echo ""
    echo -e "  ${CYAN}${BOLD}⚙️ ${NC}${BOLD}Meko Manager ${CYAN}${BOLD}| ${NC}${BOLD}Меню 3x-ui ${CYAN}${BOLD}v1.97 ${CYAN}${BOLD}⚙️${NC}"
    echo -e "  ${BOLD}${DIM}═════════════════════════════════════════════════${NC}"
    echo ""

    if is_3xui_installed; then
        echo -e "  ${BOLD}Статус:${NC} ${GREEN}Установлена${NC}"
        echo ""
        echo -e "  ${DIM}Текущие настройки:${NC}"
        x-ui settings 2>/dev/null | grep -E "Panel port|Panel path|Sub path|Sub port" | sed 's/^/  /' || echo -e "  ${YELLOW}Не удалось получить настройки${NC}"
    else
        echo -e "  ${BOLD}Статус:${NC} ${RED}Не установлена${NC}"
    fi
    echo ""

    echo -e "  ${BOLD}Доступные действия:${NC}"
    echo ""
    echo -e "  ${GREEN}[1]${NC}  ${BOLD}Установить 3x-ui${NC}"
    if is_3xui_installed; then
        echo -e "  ${CYAN}[2]${NC}  ${BOLD}Запустить панель${NC}  ${DIM}(x-ui start)${NC}"
        echo -e "  ${CYAN}[3]${NC}  ${BOLD}Остановить панель${NC}  ${DIM}(x-ui stop)${NC}"
        echo -e "  ${CYAN}[4]${NC}  ${BOLD}Перезапустить панель${NC}  ${DIM}(x-ui restart)${NC}"
        echo -e "  ${CYAN}[5]${NC}  ${BOLD}Статус панели${NC}  ${DIM}(x-ui status)${NC}"
        echo -e "  ${CYAN}[6]${NC}  ${BOLD}Показать настройки${NC}  ${DIM}(x-ui settings)${NC}"
        echo -e "  ${CYAN}[7]${NC}  ${BOLD}Посмотреть логи${NC}  ${DIM}(x-ui log)${NC}"
        echo -e "  ${CYAN}[8]${NC}  ${BOLD}Включить автозапуск${NC}  ${DIM}(x-ui enable)${NC}"
        echo -e "  ${CYAN}[9]${NC}  ${BOLD}Отключить автозапуск${NC}  ${DIM}(x-ui disable)${NC}"
        echo -e "  ${CYAN}[10]${NC} ${BOLD}Обновить панель${NC}  ${DIM}(x-ui update)${NC}"
        echo -e "  ${CYAN}[11]${NC} ${BOLD}Удалить панель${NC}  ${DIM}(x-ui uninstall)${NC}"
    else
        echo -e "  ${DIM}Для управления сначала установите панель (пункт 1)${NC}"
    fi
    echo ""
    echo -e "  ${RED}${BOLD}[0]${NC}  ${RED}${BOLD}Назад в главное меню VPN${NC}"
    echo ""
    echo -en "  ${NC}${BOLD}Выбор:${NC} "

    if ! { read -r choice </dev/tty; } 2>/dev/null; then
        echo ""
        log_warning "Нет доступа к терминалу — выход из меню 3x-ui."
        exit 0
    fi

    case "$choice" in
        1)
            install_3xui || true
            ;;
        2)
            run_xui_cmd "start" "Запуск панели" || true
            ;;
        3)
            run_xui_cmd "stop" "Остановка панели" || true
            ;;
        4)
            run_xui_cmd "restart" "Перезапуск панели" || true
            ;;
        5)
            run_xui_cmd "status" "Статус панели" || true
            ;;
        6)
            run_xui_cmd "settings" "Настройки панели" || true
            ;;
        7)
            run_xui_cmd "log" "Просмотр логов (Ctrl+C для выхода)" || true
            ;;
        8)
            run_xui_cmd "enable" "Включение автозапуска" || true
            ;;
        9)
            run_xui_cmd "disable" "Отключение автозапуска" || true
            ;;
        10)
            run_xui_cmd "update" "Обновление панели" || true
            ;;
        11)
            if is_3xui_installed; then
                echo ""
                log_warning "Вы уверены, что хотите удалить панель 3x-ui и Xray?"
                echo -en "  ${BOLD}Продолжить? [y/N]:${NC} "
                confirm=""
                { read -r confirm </dev/tty; } 2>/dev/null || confirm=""
                if [[ "$confirm" =~ ^[yY]$ ]]; then
                    log_info "Запуск удаления..."
                    # Автоматически подтверждаем второй запрос
                    if echo "y" | x-ui uninstall; then
                        log_success "Панель удалена."
                    else
                        log_error "Ошибка при удалении панели."
                    fi
                else
                    log_info "Удаление отменено."
                fi
                pause_key "Нажмите любую клавишу для возврата в меню..."
            else
                echo ""
                log_error "Панель не установлена."
                pause_key
            fi
            ;;
        0)
            echo ""
            log_info "Возврат в главное меню VPN..."
            exit 0
            ;;
        *)
            echo ""
            log_warning "Неверный выбор."
            pause_key "Нажмите любую клавишу для продолжения..."
            ;;
    esac
done
