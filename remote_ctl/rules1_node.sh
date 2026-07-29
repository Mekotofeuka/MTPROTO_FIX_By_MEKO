#!/bin/bash
# remote_ctl/rules1_node.sh – управление SYN FIX на удалённой ноде (копия+запуск)

if [ $# -lt 3 ]; then
    echo "❌ Использование: $0 <IP> <USER> <PORT>"
    exit 1
fi
REMOTE_IP="$1"
REMOTE_USER="$2"
REMOTE_PORT="$3"

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

# ── Определяем пути к локальным файлам ────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LOCAL_RULES=""
for p in "$SCRIPT_DIR/rules.sh" "/opt/mtpr-simple/data/rules.sh"; do
    if [ -f "$p" ]; then
        LOCAL_RULES="$p"
        break
    fi
done

LOCAL_ZAPRET2=""
for p in "$SCRIPT_DIR/zapret2_fix.sh" "/opt/mtpr-simple/data/zapret2_fix.sh"; do
    if [ -f "$p" ]; then
        LOCAL_ZAPRET2="$p"
        break
    fi
done

if [ -z "$LOCAL_RULES" ]; then
    log_error "Не найден локальный файл rules.sh ни в $SCRIPT_DIR, ни в /opt/mtpr-simple/data/"
    echo "Пожалуйста, скопируйте rules.sh в одну из этих папок."
    exit 1
fi

# ── Главное меню ─────────────────────────────────────────────
main_menu() {
    while true; do
        clear
        echo ""
        echo -e "  ${BOLD}Меню фиксов (SYN FIX/Zapret2) для ${CYAN}${REMOTE_USER}@${REMOTE_IP}${NC}${BOLD} (порт $REMOTE_PORT)${NC}"
        echo -e "  ${DIM}═══════════════════════════════════════════════════════════${NC}"
        echo ""
        echo -e "  ${CYAN}[1]${NC}  ${BOLD}Запустить меню установки/удаления SYN FIX${NC}"
        echo -e "  ${CYAN}[0]${NC}  ${BOLD}Назад${NC}"
        echo ""
        echo -en "  ${BOLD}Выбор:${NC} "
        read -r choice

        case "$choice" in
            1)
                echo ""
                log_info "Копируем $LOCAL_RULES на $REMOTE_IP..."
                scp -P "$REMOTE_PORT" -o StrictHostKeyChecking=no "$LOCAL_RULES" "$REMOTE_USER@$REMOTE_IP:/tmp/rules.sh" >/dev/null 2>&1
                if [ $? -eq 0 ]; then
                    log_success "rules.sh скопирован."
                else
                    log_error "Не удалось скопировать rules.sh."
                    read -p "Нажмите Enter для продолжения..."
                    continue
                fi

                if [ -n "$LOCAL_ZAPRET2" ]; then
                    log_info "Копируем $LOCAL_ZAPRET2 на $REMOTE_IP..."
                    scp -P "$REMOTE_PORT" -o StrictHostKeyChecking=no "$LOCAL_ZAPRET2" "$REMOTE_USER@$REMOTE_IP:/tmp/zapret2_fix.sh" >/dev/null 2>&1
                    if [ $? -eq 0 ]; then
                        # Перемещаем в правильную папку
                        ssh -p "$REMOTE_PORT" "$REMOTE_USER@$REMOTE_IP" "mkdir -p /opt/mtpr-simple/data && mv /tmp/zapret2_fix.sh /opt/mtpr-simple/data/zapret2_fix.sh && chmod +x /opt/mtpr-simple/data/zapret2_fix.sh" 2>/dev/null
                        if [ $? -eq 0 ]; then
                            log_success "zapret2_fix.sh скопирован и установлен в /opt/mtpr-simple/data/"
                        else
                            log_warning "Не удалось переместить zapret2_fix.sh в /opt/mtpr-simple/data/ (возможно, он остался в /tmp)."
                        fi
                    else
                        log_warning "Не удалось скопировать zapret2_fix.sh."
                    fi
                else
                    log_warning "zapret2_fix.sh не найден локально, пропускаем."
                fi

                echo ""
                log_info "Запуск интерактивного меню на удалённом сервере..."
                echo -e "  ${DIM}Следуйте инструкциям на экране.${NC}"
                echo -e "  ${GRAY}Нажмите любую клавишу для продолжения...${NC}"
                read -rsn1
                ssh -t -p "$REMOTE_PORT" "$REMOTE_USER@$REMOTE_IP" "bash /tmp/rules.sh"
                echo ""
                log_info "Работа с удалённым сервером завершена."
                read -p "Нажмите Enter для продолжения..."
                ;;
            0)
                echo ""
                log_info "Возврат..."
                exit 0
                ;;
            *)
                log_error "Неверный выбор"
                sleep 0.5
                ;;
        esac
    done
}

main_menu
