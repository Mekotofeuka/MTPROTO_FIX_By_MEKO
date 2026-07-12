#!/bin/bash
# install_auto.sh – автоматическая установка прокси и правил

set -e

BASE_URL="https://raw.githubusercontent.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/main"
INSTALL_DIR="/opt/mtpr-simple"

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

# ── Проверка root ────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}[✗]${NC} Запустите от root" >&2
    exit 1
fi

# ── Функция чтения ввода с терминала ──────────────────────────
read_input() {
    local input
    if [ -r /dev/tty ]; then
        read -r input </dev/tty
        echo "$input"
    else
        echo ""
    fi
}

# ── Функция скачивания файла ─────────────────────────────────
download_file() {
    local file="$1"
    local dest="$2"
    local url="$BASE_URL/$file"
    
    mkdir -p "$(dirname "$dest")"
    
    if curl -fsSL "$url" -o "$dest" 2>/dev/null; then
        chmod +x "$dest" 2>/dev/null || true
        return 0
    else
        return 1
    fi
}

# ── 1. ПРОВЕРКА И УСТАНОВКА RULES.SH ──────────────────────────
RULES_SCRIPT="$INSTALL_DIR/data/rules.sh"

if [ ! -f "$RULES_SCRIPT" ]; then
    log_info "Скачивание data/rules.sh..."
    if download_file "data/rules.sh" "$RULES_SCRIPT"; then
        log_success "data/rules.sh загружен"
    else
        log_error "Не удалось загрузить data/rules.sh"
        exit 1
    fi
fi

# Подключаем rules.sh
source "$RULES_SCRIPT"

# ── Функция-обёртка для install_syn_fix с корректным stdin ──
run_syn_fix() {
    # Сохраняем текущий stdin
    exec 3<&0
    # Перенаправляем stdin на /dev/tty
    exec </dev/tty 2>/dev/null || true
    # Вызываем install_syn_fix из rules.sh
    install_syn_fix
    # Восстанавливаем stdin
    exec <&3 2>/dev/null || true
    exec 3<&- 2>/dev/null || true
}

# ── Функция проверки и загрузки файла прокси ──────────────────
ensure_proxy_file() {
    local proxy_file="$1"
    local dest="$INSTALL_DIR/$proxy_file"
    
    if [ ! -f "$dest" ]; then
        log_info "Скачивание $proxy_file..."
        if download_file "$proxy_file" "$dest"; then
            log_success "$proxy_file загружен"
        else
            log_error "Не удалось загрузить $proxy_file"
            return 1
        fi
    fi
    chmod +x "$dest" 2>/dev/null || true
    return 0
}

clear
echo -e "  ${NC}${BOLD}⚙️ УСТАНОВКА${CYAN}${BOLD} MEKOPR ${NC}${BOLD}(РЕЖИМ: ${CYAN}${BOLD}Auto${NC}${BOLD}) v0.19${NC}"
echo -e "  ${BOLD}${DIM}═════════════════════════════════════════════════${NC}"
echo ""

# ── 1. Установка SYN FIX ──────────────────────────────────────
echo ""
echo -e "  ${BOLD}${CYAN}🔧 УСТАНОВКА SYN FIX${NC}"
echo -e "  ${BOLD}${DIM}═════════════════════════════════════════════════${NC}"
echo ""

run_syn_fix

clear
# ── Меню выбора прокси ──────────────────────────────────────
while true; do
    echo ""
    echo -e "  ${BOLD}${CYAN}📦 ВЫБОР ПРОКСИ ДЛЯ УСТАНОВКИ${NC}"
    echo -e "  ${BOLD}${DIM}═════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${GREEN}[1]${NC}  ${BOLD}Установить TELEMT${NC}  ${DIM}(стандартный)${NC}"
    echo -e "  ${GREEN}[2]${NC}  ${BOLD}Установить TELEMT в Docker${NC}"
    echo -e "  ${GREEN}[3]${NC}  ${BOLD}Установить MTG${NC}"
    echo -e "  ${GREEN}[4]${NC}  ${BOLD}Установить MTProtoZig${NC}"
    echo -e "  ${YELLOW}[5]${NC}  ${BOLD}Пропустить установку прокси${NC}  ${DIM}(если уже установлен)${NC}"
    echo -e "  ${RED}[0]${NC}  ${BOLD}Выйти${NC}"
    echo ""
    echo -en "  ${BOLD}Выбор (По умолчанию ${GREEN}${BOLD}1(Enter)${NC}${BOLD}):${NC} "

    proxy_choice=$(read_input)
    [ -z "$proxy_choice" ] && proxy_choice="1"

    case "$proxy_choice" in
        1)
            echo ""
            log_info "Установка TELEMT..."
            if ensure_proxy_file "proxys/telemt1.sh"; then
                exec "$INSTALL_DIR/proxys/telemt1.sh" </dev/tty
            else
                exit 1
            fi
            ;;
        2)
            echo ""
            log_info "Установка TELEMT в Docker..."
            if ensure_proxy_file "proxys/telemt_in_docker1.sh"; then
                exec "$INSTALL_DIR/proxys/telemt_in_docker1.sh" </dev/tty
            else
                exit 1
            fi
            ;;
        3)
            echo ""
            log_info "Установка MTG..."
            if ensure_proxy_file "proxys/mtgv2_1.sh"; then
                exec "$INSTALL_DIR/proxys/mtgv2_1.sh" </dev/tty
            else
                exit 1
            fi
            ;;
        4)
            echo ""
            log_info "Установка MTProtoZig..."
            if ensure_proxy_file "proxys/mtprotozig1.sh"; then
                exec "$INSTALL_DIR/proxys/mtprotozig1.sh" </dev/tty
            else
                exit 1
            fi
            ;;
        5)
            echo ""
            log_info "Установка прокси пропущена."
            break
            ;;
        0)
            echo ""
            log_info "Выход..."
            exit 0
            ;;
        *)
            echo ""
            log_warning "Неверный выбор, попробуйте снова"
            sleep 1
            ;;
    esac
done

# ── Финальное меню ──────────────────────────────────────────
while true; do
    echo ""
    echo -e "  ${BOLD}${GREEN}✅ Установка завершена${NC}"
    echo -e "  ${DIM}═════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${GREEN}[1]${NC}  ${BOLD}Поставить MEKO Launcher${NC}  ${DIM}(для работы/отслеживания прокси)${NC}"
    echo -e "  ${RED}[0]${NC}  ${BOLD}Закрыть меню установки${NC}"
    echo ""
    echo -en "  ${BOLD}Выбор (Enter - установить лаунчер):${NC} "

    final_choice=$(read_input)
    [ -z "$final_choice" ] && final_choice="1"

    case "$final_choice" in
        0)
            echo ""
            log_info "Выход..."
            exit 0
            ;;
        1)
            echo ""
            log_info "Установка MEKO Launcher..."
            curl -fsSL "$BASE_URL/install_main.sh" | sudo bash
            break
            ;;
        *)
            echo ""
            log_warning "Неверный выбор, попробуйте снова"
            sleep 1
            ;;
    esac
done
