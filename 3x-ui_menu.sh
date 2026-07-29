#!/bin/bash
# 3x-ui_menu.sh – Меню управления панелью 3x-ui

set -e

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

log_info() { echo -e "  ${BLUE}[i]${NC} $1"; }
log_success() { echo -e "  ${GREEN}[✓]${NC} $1"; }
log_error() { echo -e "  ${RED}[✗]${NC} $1" >&2; }
log_warning() { echo -e "  ${YELLOW}[!]${NC} $1"; }

# ── Проверка root ────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}[✗]${NC} Запустите от root" >&2
    exit 1
fi

# ── Проверка установки 3x-ui ────────────────────────────────
is_3xui_installed() {
    command -v x-ui >/dev/null 2>&1
}

# ── Установка 3x-ui (с ожиданием освобождения apt) ──────────
install_3xui() {
    echo ""
    log_info "Установка 3x-ui..."
    echo ""

    # Проверка блокировки apt
    log_info "Проверка блокировки менеджера пакетов apt..."
    local wait_seconds=0
    local max_wait=120
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
        if [ $wait_seconds -ge $max_wait ]; then
            log_error "Блокировка apt не снята за $max_wait секунд."
            log_error "Попробуйте остановить unattended-upgrades вручную: sudo systemctl stop unattended-upgrades"
            echo -e "  ${GRAY}Нажмите любую клавишу для возврата...${NC}"
            read -rsn1 </dev/tty 2>/dev/null
            return 1
        fi
        log_warning "Обнаружена блокировка apt (возможно, unattended-upgrades). Ждём 5 секунд..."
        sleep 5
        wait_seconds=$((wait_seconds + 5))
    done
    log_success "Блокировка apt снята, продолжаем установку."

    log_info "Запуск установки 3x-ui (это может занять несколько минут)..."
    echo ""
    if sudo su -c "bash <(wget -qO- https://raw.githubusercontent.com/mozaroc/3x-ui-pro/main/x-ui-latest.sh) -install yes -auto_domain y"; then
        log_success "3x-ui установлен"
    else
        log_error "Ошибка установки 3x-ui"
        echo -e "  ${GRAY}Нажмите любую клавишу для возврата...${NC}"
        read -rsn1 </dev/tty 2>/dev/null
        return 1
    fi

    # Применение патча
    log_info "Применение патча 3x-ui..."
    wait_seconds=0
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
        if [ $wait_seconds -ge $max_wait ]; then
            log_warning "Блокировка apt не снята, патч может не примениться."
            break
        fi
        log_warning "Снова блокировка apt, ждём 5 секунд..."
        sleep 5
        wait_seconds=$((wait_seconds + 5))
    done

    if bash <(curl -fsSL https://raw.githubusercontent.com/mozaroc/3x-ui-pro/main/x-ui-patch.sh); then
        log_success "Патч применён"
    else
        log_warning "Патч не применился (возможно, он не требуется или apt всё ещё занят)"
    fi

    echo ""
    log_success "Установка 3x-ui завершена!"
    echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
    read -rsn1 </dev/tty 2>/dev/null
}

# ── Выполнение команды x-ui с проверкой установки ────────────
run_xui_cmd() {
    local cmd="$1"
    local desc="$2"
    
    if ! is_3xui_installed; then
        echo ""
        log_error "Панель 3x-ui не установлена. Сначала выполните установку (пункт 1)."
        echo -e "  ${GRAY}Нажмите любую клавишу для возврата...${NC}"
        read -rsn1 </dev/tty 2>/dev/null
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
    echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
    read -rsn1 </dev/tty 2>/dev/null
}

# ── Главное меню 3x-ui ────────────────────────────────────────
while true; do
    clear 2>/dev/null || printf '\033[2J\033[H'
    echo ""
    echo -e "  ${CYAN}${BOLD}⚙️ ${NC}${BOLD}Meko Manager ${CYAN}${BOLD}| ${NC}${BOLD}Меню 3x-ui ${CYAN}${BOLD}v1.95 ${CYAN}${BOLD}⚙️${NC}"
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

    if ! read -r choice </dev/tty 2>/dev/null; then
        echo ""
        echo -e "  ${RED}[✗]${NC} Не удалось прочитать ввод."
        exit 1
    fi

    case "$choice" in
        1)
            install_3xui
            ;;
        2)
            run_xui_cmd "start" "Запуск панели"
            ;;
        3)
            run_xui_cmd "stop" "Остановка панели"
            ;;
        4)
            run_xui_cmd "restart" "Перезапуск панели"
            ;;
        5)
            run_xui_cmd "status" "Статус панели"
            ;;
        6)
            run_xui_cmd "settings" "Настройки панели"
            ;;
        7)
            run_xui_cmd "log" "Просмотр логов (Ctrl+C для выхода)"
            ;;
        8)
            run_xui_cmd "enable" "Включение автозапуска"
            ;;
        9)
            run_xui_cmd "disable" "Отключение автозапуска"
            ;;
        10)
            run_xui_cmd "update" "Обновление панели"
            ;;
        11)
            if is_3xui_installed; then
                echo ""
                log_warning "Вы уверены, что хотите удалить панель 3x-ui и Xray?"
                echo -en "  ${BOLD}Продолжить? [y/N]:${NC} "
                confirm=""
                read -r confirm </dev/tty 2>/dev/null
                if [[ "$confirm" =~ ^[yY]$ ]]; then
                    log_info "Запуск удаления..."
                    x-ui uninstall
                    echo ""
                    log_success "Панель не удалена. Впишите y на вопрос об удалении"
                else
                    log_info "Удаление отменено."
                fi
                echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
                read -rsn1 </dev/tty 2>/dev/null
            else
                echo ""
                log_error "Панель не установлена."
                echo -e "  ${GRAY}Нажмите любую клавишу для возврата...${NC}"
                read -rsn1 </dev/tty 2>/dev/null
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
            echo -e "  ${GRAY}Нажмите любую клавишу для продолжения...${NC}"
            read -rsn1 </dev/tty 2>/dev/null
            ;;
    esac
done
