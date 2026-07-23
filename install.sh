#!/bin/bash
# install.sh – Главный установщик MEKOPR

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
    echo -e "${RED}[✗]${NC} Запустите от root: ${BOLD}curl -fsSL ... | sudo bash${NC}" >&2
    exit 1
fi

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

# ── Функция проверки и загрузки файла ────────────────────────
ensure_file() {
    local file="$1"
    local dest="$INSTALL_DIR/$file"
    
    if [ ! -f "$dest" ]; then
        log_info "Скачивание $file..."
        if download_file "$file" "$dest"; then
            log_success "$file загружен"
        else
            log_error "Не удалось загрузить $file"
            return 1
        fi
    fi
    chmod +x "$dest" 2>/dev/null || true
    return 0
}

# ── СТАРОЕ МЕНЮ (ПРОКСИ) ──────────────────────────────────────
show_proxy_menu() {
    clear 2>/dev/null || printf '\033[2J\033[H'
    echo ""
    echo -e "  ${CYAN}${BOLD}⚙️ ${NC}${BOLD}Meko Manager ${CYAN}${BOLD} v1.9 ${CYAN}${BOLD}| ${NC}${BOLD}Меню proxy ⚙️${NC}"
    echo -e "  ${BOLD}${DIM}═════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${BOLD}Выберите вариант установки:${NC}"
    echo ""
    echo -e "  ${GREEN}[1]${NC}  ${BOLD}Стандартная установка${NC}  ${GREEN}${BOLD}(рекомендуется)${NC}"
    echo -e "       ${DIM}Установит MEKO Launcher и все необходимые файлы${NC}"
    echo -e "       ${DIM}Для дальнейшей работы и управления Mtproto proxy"
    echo ""
    echo -e "  ${CYAN}[2]${NC}  ${BOLD}Автоматическая установка${NC}  ${CYAN}(для новичков)${NC}"
    echo -e "       ${DIM}Откроет простое меню автоматической и полуавтоматической установки${NC}"
    echo -e "       ${DIM}Полуавтоматический вариант попросит ввести кастомные параметры"
    echo -e "       ${DIM}Автоматический вариант установит универсальный вариант сам"
    echo ""
    echo -e "  ${RED}${BOLD}[0]${NC}  ${RED}${BOLD}Назад ${NC}"
    echo ""
    echo -en "  ${NC}${BOLD}Ввод (${GREEN}${BOLD}Enter${NC}${BOLD} - стандартная установка):${NC} "

    if ! read -r choice </dev/tty 2>/dev/null; then
        echo ""
        echo -e "  ${RED}[✗]${NC} Не удалось прочитать ввод. Запустите скрипт интерактивно."
        exit 1
    fi

    case "$choice" in
        0)
            echo ""
            log_info "Возврат в главное меню..."
            return 0
            ;;
        2)
            echo ""
            log_info "Запуск автоустановки..."
            if ensure_file "install_auto.sh"; then
                bash "$INSTALL_DIR/install_auto.sh"
                exit 0
            else
                log_error "Не удалось загрузить install_auto.sh"
                exit 1
            fi
            ;;
        3)
            echo ""
            log_info "Запуск ручной установки..."
            if ensure_file "install_manual.sh"; then
                bash "$INSTALL_DIR/install_manual.sh"
                exit 0
            else
                log_error "Не удалось загрузить install_manual.sh"
                exit 1
            fi
            ;;
        *)
            # 1 или Enter — стандартная установка
            echo ""
            log_info "Запуск стандартной установки MEKO Launcher..."
            if ensure_file "install_main.sh"; then
                bash "$INSTALL_DIR/install_main.sh"
                exit 0
            else
                log_error "Не удалось загрузить install_main.sh"
                exit 1
            fi
            ;;
    esac
}

# ── НОВОЕ ГЛАВНОЕ МЕНЮ ────────────────────────────────────────
show_main_menu() {
    while true; do
        clear 2>/dev/null || printf '\033[2J\033[H'
        echo ""
        echo -e "  ${CYAN}${BOLD}⚙️ ${NC}${BOLD}MEKO MANAGER ${CYAN}${BOLD}V1.9 ${CYAN}${BOLD}⚙️${NC}"
        echo -e "  ${BOLD}${DIM}═════════════════════════════════════════════════${NC}"
        echo ""
        echo -e "  ${BOLD}Выберите вариант установки:${NC}"
        echo ""
        echo -e "  ${GREEN}[1]${NC}  ${BOLD}Меню proxy${NC}"
        echo -e "       ${DIM}Меню установки MEKO Manager${NC}"
        echo -e "       ${DIM}Для дальнейшей установки, работы и управления Mtproto proxy"
        echo ""
        echo -e "  ${CYAN}[2]${NC}  ${BOLD}Меню VPN${NC}"
        echo -e "       ${DIM}Меню выбора для автоматической установки${NC}"
        echo -e "       ${DIM}VPN через 3x-ui или Remnawave"
        echo ""
        echo -e "  ${RED}${BOLD}[0]${NC}  ${RED}${BOLD}Выход${NC}"
        echo ""
        echo -en "  ${NC}${BOLD}Ввод (${GREEN}${BOLD}Enter${NC}${BOLD} - установка proxy):${NC} "

        if ! read -r choice </dev/tty 2>/dev/null; then
            echo ""
            echo -e "  ${RED}[✗]${NC} Не удалось прочитать ввод."
            exit 1
        fi

        case "$choice" in
            0)
                echo ""
                log_info "Выход..."
                exit 0
                ;;
            2)
                echo ""
                log_info "Запуск установки VPN..."
                if ensure_file "install_vpn.sh"; then
                    bash "$INSTALL_DIR/install_vpn.sh"
                else
                    log_error "Не удалось загрузить install_vpn.sh"
                fi
                echo ""
                echo -e "  ${GRAY}Нажмите Enter для возврата в главное меню...${NC}"
                read -r </dev/tty 2>/dev/null
                ;;
            *)
                # 1 или Enter — меню proxy
                show_proxy_menu
                ;;
        esac
    done
}

# ── ЗАПУСК ────────────────────────────────────────────────────
show_main_menu
