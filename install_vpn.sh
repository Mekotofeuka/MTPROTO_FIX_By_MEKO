#!/bin/bash
# install_vpn.sh – Меню установки VPN (3x-ui / Remnawave)

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

# ── Открытие меню 3x-ui ──────────────────────────────────────
open_3xui_menu() {
    local menu_file="$INSTALL_DIR/3x-ui_menu.sh"
    
    # Скачиваем, если отсутствует
    if [ ! -f "$menu_file" ]; then
        log_info "Меню 3x-ui не найдено, скачиваю..."
        if download_file "3x-ui_menu.sh" "$menu_file"; then
            chmod +x "$menu_file"
            log_success "Меню 3x-ui загружено"
        else
            log_error "Не удалось загрузить меню 3x-ui"
            echo -e "  ${GRAY}Нажмите любую клавишу для возврата...${NC}"
            read -rsn1 </dev/tty 2>/dev/null
            return
        fi
    fi
    
    # Запускаем подменю (без exec, чтобы вернуться после выхода)
    bash "$menu_file"
}

# ── Установка Remnawave ──────
install_remnawave() {
    echo ""
    log_info "Установка Remnawave..."
    echo ""
    log_info "Запуск установщика Remnawave (интерактивный режим)..."
    echo ""

    # Заменяем текущий процесс на выполнение команды с терминальным вводом
    exec sudo bash -c "$(curl -sL https://raw.githubusercontent.com/xxphantom/remnawave-installer/main/install.sh)" @ --lang=ru </dev/tty
}

# ── Очистка экрана и шапка ────────────────────────────────────
clear 2>/dev/null || printf '\033[2J\033[H'
echo ""
echo -e "  ${CYAN}${BOLD}⚙️ ${NC}${BOLD}Meko Manager ${CYAN}${BOLD}| ${NC}${BOLD}Меню VPN ${CYAN}${BOLD}v1.95 ${CYAN}${BOLD}⚙️${NC}"
echo -e "  ${BOLD}${DIM}═════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${BOLD}Выберите пункт для установки:${NC}"
echo ""
echo -e "  ${GREEN}[1]${NC}  ${BOLD}Меню 3x-ui${NC}"
echo -e "       ${DIM}Откроет меню панели 3x-ui:${NC}"
echo -e "       ${DIM}установка, статус, удаление, настройки и т.д.${NC}"
echo ""
echo -e "  ${CYAN}[2]${NC}  ${BOLD}Установка Remnawave${NC}"
echo -e "       ${DIM}Откроет меню установки Remnawave для выбора:${NC}"
echo -e "       ${DIM}Установить панель (full caddy / simple cookie) / Ноду / Всё вместе${NC}"
echo ""
echo -e "  ${RED}${BOLD}[0]${NC}  ${RED}${BOLD}Выход${NC}"
echo ""
echo -en "  ${NC}${BOLD}Ввод (${GREEN}${BOLD}Enter${NC}${BOLD} - меню 3x-ui):${NC} "

# ── Читаем ввод с терминала ──────────────────────────────────
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
        install_remnawave
        # После exec сюда не вернёмся, но для безопасности:
        exit 0
        ;;
    *)
        open_3xui_menu
        # После возврата из подменю перезапускаем install_vpn.sh, чтобы обновить экран
        exec "$0"
        ;;
esac
