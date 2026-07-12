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

# ── Функция получения последней версии из GitHub ─────────────
get_latest_version() {
    local version
    version=$(curl -fsSL "https://api.github.com/repos/Mekotofeuka/MTPROTO_FIX_By_MEKO/releases/latest" 2>/dev/null | grep -o '"tag_name": *"[^"]*"' | head -1 | cut -d'"' -f4)
    if [ -z "$version" ]; then
        echo "v0.1"
    else
        echo "$version"
    fi
}

VERSION=$(get_latest_version)

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

# ── Функция чтения ввода с терминала ──────────────────────────
read_input() {
    local input
    # Пытаемся прочитать с /dev/tty (реальный терминал)
    if [ -r /dev/tty ]; then
        read -r input </dev/tty
        echo "$input"
    else
        # Если /dev/tty недоступен — ничего не делаем
        echo ""
    fi
}

# ── Очистка экрана и шапка ────────────────────────────────────
clear 2>/dev/null || printf '\033[2J\033[H'
echo ""
echo -e "  ${CYAN}${BOLD}⚙️ ${NC}${BOLD}Установка фикса ${CYAN}${BOLD}MEKO ${VERSION}1 ${CYAN}${BOLD}⚙️${NC}"
echo -e "  ${BOLD}${DIM}═════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${BOLD}Выберите способ установки:${NC}"
echo ""
echo -e "  ${GREEN}[1]${NC}  ${BOLD}Стандартная установка${NC}  ${GREEN}${BOLD}(рекомендуется)${NC}"
echo -e "      ${DIM}Установит MEKO Launcher и все необходимые файлы${NC}"
echo ""
echo -e "  ${CYAN}[2]${NC}  ${BOLD}Автоустановка${NC}  ${CYAN}(для новичков)${NC}"
echo -e "      ${DIM}Установит фикс и сам прокси с нуля в два клика${NC}"
echo ""
echo -e "  ${RED}${BOLD}[0]${NC}  ${RED}${BOLD}Выход${NC}"
echo ""
echo -en "  ${NC}${BOLD}Выбор (${GREEN}${BOLD}Enter${NC}${BOLD} - стандартная установка):${NC} "

# ── Читаем выбор с терминала ──────────────────────────────────
choice=$(read_input)

case "$choice" in
    0)
        echo ""
        log_info "Выход..."
        exit 0
        ;;
    2)
        echo ""
        log_info "Запуск автоустановки..."
        
        if ensure_file "install_auto.sh"; then
            exec "$INSTALL_DIR/install_auto.sh"
        else
            log_error "Не удалось загрузить install_auto.sh"
            exit 1
        fi
        ;;
    3)
        echo ""
        log_info "Запуск ручной установки..."
        
        if ensure_file "install_manual.sh"; then
            exec "$INSTALL_DIR/install_manual.sh"
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
            # Запускаем install_main.sh с перенаправлением stdin на /dev/tty
            # и ждём его завершения, после чего выходим
            "$INSTALL_DIR/install_main.sh" </dev/tty
            exit 0
        else
            log_error "Не удалось загрузить install_main.sh"
            exit 1
        fi
        ;;
esac
