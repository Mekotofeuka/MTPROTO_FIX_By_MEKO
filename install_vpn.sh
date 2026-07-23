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

# ── Установка 3x-ui ───────────────────────────────────────────
install_3xui() {
    echo ""
    log_info "Установка 3x-ui..."

    echo ""
    echo -e "  ${YELLOW}[!]${NC} Будет выполнена установка:"
    echo -e "  • Панель 3x-ui"
    echo -e "  • 3 ноды"
    echo -e "  • Фикс xray ядра"
    echo ""
    echo -en "  ${BOLD}Продолжить установку? [Y/n]:${NC} "
    local confirm
    read -r confirm </dev/tty 2>/dev/null
    if [[ -n "$confirm" && ! "$confirm" =~ ^[yY]$ ]]; then
        log_info "Установка отменена"
        return 1
    fi

    echo ""
    log_info "Запуск установки 3x-ui (это может занять несколько минут)..."
    echo ""

    # 1. Установка 3x-ui
    if sudo su -c "bash <(wget -qO- https://raw.githubusercontent.com/mozaroc/3x-ui-pro/main/x-ui-latest.sh) -install yes -auto_domain y"; then
        log_success "3x-ui установлен"
    else
        log_error "Ошибка установки 3x-ui"
        return 1
    fi

    # 2. Применение патча
    log_info "Применение патча 3x-ui..."
    if bash <(curl -fsSL https://raw.githubusercontent.com/mozaroc/3x-ui-pro/main/x-ui-patch.sh); then
        log_success "Патч применён"
    else
        log_warning "Патч не применился (возможно, он не требуется)"
    fi

    echo ""
    log_success "Установка 3x-ui завершена!"
    echo ""
    echo -e "  ${GRAY}Нажмите Enter для возврата в меню...${NC}"
    read -r </dev/tty 2>/dev/null
    return 0
}

# ── Установка Remnawave ───────────────────────────────────────
install_remnawave() {
    echo ""
    log_info "Установка Remnawave..."

    echo ""
    echo -e "  ${YELLOW}[!]${NC} Будет выполнена установка:"
    echo -e "  • Remnawave Panel (VPN-панель)"
    echo -e "  • Выбор режима установки (Full / Panel Only / Node / All-in-One)"
    echo ""
    echo -en "  ${BOLD}Продолжить установку? [Y/n]:${NC} "
    local confirm
    read -r confirm </dev/tty 2>/dev/null
    if [[ -n "$confirm" && ! "$confirm" =~ ^[yY]$ ]]; then
        log_info "Установка отменена"
        return 1
    fi

    echo ""
    log_info "Запуск установки Remnawave..."
    echo ""

    if sudo bash -c "$(curl -sL https://raw.githubusercontent.com/xxphantom/remnawave-installer/main/install.sh)" @ --lang=ru; then
        log_success "Remnawave установлен"
    else
        log_error "Ошибка установки Remnawave"
        return 1
    fi

    echo ""
    log_success "Установка Remnawave завершена!"
    echo ""
    echo -e "  ${GRAY}Нажмите Enter для возврата в меню...${NC}"
    read -r </dev/tty 2>/dev/null
    return 0
}

# ── Очистка экрана и шапка ────────────────────────────────────
clear 2>/dev/null || printf '\033[2J\033[H'
echo ""
echo -e "  ${CYAN}${BOLD}⚙️ ${NC}${BOLD}Meko Manager ${CYAN}${BOLD}| ${NC}${BOLD}Меню VPN ${CYAN}${BOLD}v1.9 ${CYAN}${BOLD}⚙️${NC}"
echo -e "  ${BOLD}${DIM}═════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${BOLD}Выберите пункт для установки:${NC}"
echo ""
echo -e "  ${GREEN}[1]${NC}  ${BOLD}Установка 3x-ui${NC}"
echo -e "       ${DIM}Установит:${NC}"
echo -e "       ${DIM}панель 3x-ui и все необходимые файлы${NC}"
echo -e "       ${DIM}3 ноды и фикс xray ядра${NC}"
echo ""
echo -e "  ${CYAN}[2]${NC}  ${BOLD}Установка Remnawave${NC}"
echo -e "       ${DIM}Откроет меню установки Remnawave для выбора:${NC}"
echo -e "       ${DIM}Установить панель (full caddy / simple cookie) / Ноду / Всё вместе${NC}"
echo ""
echo -e "  ${RED}${BOLD}[0]${NC}  ${RED}${BOLD}Выход${NC}"
echo ""
echo -en "  ${NC}${BOLD}Ввод (${GREEN}${BOLD}Enter${NC}${BOLD} - установить 3x-ui):${NC} "

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
        # После завершения установки Remnawave перезапускаем скрипт, чтобы показать меню снова
        exec "$0"
        ;;
    *)
        # 1 или Enter — установка 3x-ui
        install_3xui
        # После завершения установки 3x-ui перезапускаем скрипт, чтобы показать меню снова
        exec "$0"
        ;;
esac
