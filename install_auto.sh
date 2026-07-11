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

echo -e "  ${BOLD}${CYAN}⚙️ УСТАНОВКА MEKOPR (РЕЖИМ: Auto) v0.1${NC}"
echo -e "  ${BOLD}${DIM}═════════════════════════════════════════════════${NC}"

# ── Меню выбора правил SYN FIX ──────────────────────────────
echo ""
echo -e "  ${BOLD}${CYAN}🔧 УСТАНОВКА SYN FIX${NC}"
echo -e "  ${BOLD}${DIM}═════════════════════════════════════════════════${NC}"
echo ""

echo -e "  ${BOLD}Выберите тип SYN FIX:${NC}"
echo -e "  ${GREEN}[1]${NC}  ${BOLD}Новый вариант(iptables)${NC} (Разделение устройств с помощью u32 по байтам из пакета) — ${GREEN}рекомендуется${NC}"
echo -e "${NC}  Если совпало -> это ios и принимаем пакеты без лимита"
echo -e "${NC}  Если не совпало -> это другое ус-во и ставим SYN 1/s"
echo -e "  ${CYAN}[2]${NC}  ${BOLD}Старый вариант(iptables)${NC} (Разделение устройств определяя их TTL+Length)"
echo -e "${NC}  Если TTL <65 и length 64 -> это ios и принимаем пакеты без лимита"
echo -e "${NC}  Иначе -> это другое ус-во и ставим SYN 1/s"
echo ""
echo -e "  ${YELLOW}[3]${NC}  ${BOLD}Новый вариант(nftables)${GREEN}${BOLD} - рекомендуется (совместим с Docker)${NC}"
echo -e "${NC}  Если совпало -> это ios и принимаем пакеты без лимита"
echo -e "${NC}  Если не совпало -> это другое ус-во и ставим SYN 1/s"
echo -e "  ${YELLOW}[4]${NC}  ${BOLD}Старый вариант(nftables)${NC}${BOLD} ${NC}${BOLD} - (совместим с Docker)${NC}"
echo -e "${NC}  Если TTL <65 и length 64 -> это ios и принимаем пакеты без лимита"
echo -e "${NC}  Иначе -> это другое ус-во и ставим SYN 1/s"
echo ""
echo -e "  ${YELLOW}[0]${NC}  ${BOLD}Пропустить установку SYN FIX${NC}"
echo ""
echo -en "  ${NC}${BOLD}Ввод (Новый - ${GREEN}${BOLD}1 или enter${NC}${BOLD}, старый - ${RED}${BOLD}2${NC}${BOLD}, nftables Новый - ${YELLOW}${BOLD}3${NC}${BOLD}, nftables старый - ${RED}${BOLD}4${NC}${BOLD}, пропустить - ${YELLOW}${BOLD}0${NC}${BOLD}):${NC} "

fix_choice=$(read_input)

case "$fix_choice" in
    0|"") ;;
    1|2|3|4)
        echo ""
        log_info "Запуск установки SYN FIX..."
        install_syn_fix
        ;;
    *)
        log_warning "Неверный выбор, пропускаем установку SYN FIX"
        ;;
esac

# ── Меню выбора прокси ──────────────────────────────────────
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
echo -en "  ${BOLD}Выбор:${NC} "

proxy_choice=$(read_input)

case "$proxy_choice" in
    1)
        echo ""
        log_info "Установка TELEMT..."
        if ensure_proxy_file "proxys/telemt1.sh"; then
            source "$INSTALL_DIR/proxys/telemt1.sh"
            install_telemt
        else
            exit 1
        fi
        ;;
    2)
        echo ""
        log_info "Установка TELEMT в Docker..."
        if ensure_proxy_file "proxys/telemt_in_docker1.sh"; then
            source "$INSTALL_DIR/proxys/telemt_in_docker1.sh"
        else
            exit 1
        fi
        ;;
    3)
        echo ""
        log_info "Установка MTG..."
        if ensure_proxy_file "proxys/mtgv2_1.sh"; then
            source "$INSTALL_DIR/proxys/mtgv2_1.sh"
            install_mtg
        else
            exit 1
        fi
        ;;
    4)
        echo ""
        log_info "Установка MTProtoZig..."
        if ensure_proxy_file "proxys/mtprotozig1.sh"; then
            source "$INSTALL_DIR/proxys/mtprotozig1.sh"
            install_zig_cli && install_proxy
        else
            exit 1
        fi
        ;;
    5)
        echo ""
        log_info "Установка прокси пропущена."
        ;;
    0)
        echo ""
        log_info "Выход..."
        exit 0
        ;;
    *)
        echo ""
        log_error "Неверный выбор"
        exit 1
        ;;
esac

# ── Финальное меню ──────────────────────────────────────────
echo ""
echo -e "  ${BOLD}${GREEN}✅ Установка завершена${NC}"
echo -e "  ${DIM}═════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${GREEN}[1]${NC}  ${BOLD}Поставить MEKO Launcher${NC}  ${DIM}(для работы/отслеживания прокси)${NC}"
echo -e "  ${RED}[0]${NC}  ${BOLD}Закрыть меню установки${NC}"
echo ""
echo -en "  ${BOLD}Выбор (Enter - установить лаунчер):${NC} "

final_choice=$(read_input)

case "$final_choice" in
    0)
        echo ""
        log_info "Выход..."
        exit 0
        ;;
    *)
        echo ""
        log_info "Установка MEKO Launcher..."
        curl -fsSL "$BASE_URL/install_main.sh" | sudo bash
        ;;
esac
