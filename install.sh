#!/bin/bash
# install.sh – Главный установщик MEKOPR с поддержкой аргументов

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

# ── Функция получения последней версии Telemt ──────────────
get_latest_telemt_version() {
    local version=""
    version=$(timeout 10 curl -fsS --max-time 5 "https://api.github.com/repos/telemt/telemt/releases/latest" 2>/dev/null | awk -F'"' '/"tag_name"/ {print $4}')
    if [ -z "$version" ]; then
        version="3.4.24"
    fi
    echo "$version"
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
    echo -e "       ${DIM}Откроет меню автоматической и полуавтоматической установки прокси${NC}"
    echo -e ""
    echo -e "       ${DIM}Полуавтоматический вариант попросит ввести кастомные параметры"
    echo -e "       ${DIM}Автоматический вариант установит универсальные параметры сам"
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
        echo -e "  ${CYAN}${BOLD}⚙️ ${NC}${BOLD}MEKO MANAGER ${CYAN}${BOLD}V1.95 ${NC}${BOLD}Меню установщика ${CYAN}${BOLD}⚙️${NC}"
        echo -e "  ${BOLD}${DIM}═════════════════════════════════════════════════${NC}"
        echo ""
        echo -e "  ${BOLD}Выберите что вы хотите открыть:${NC}"
        echo ""
        echo -e "  ${GREEN}[1]${NC}  ${BOLD}Меню proxy${NC}"
        echo -e "       ${DIM}Меню установки Mtproto фикса, proxy,  ${NC}"
        echo -e "       ${DIM}И/или Meko Managerа для дальнейшего управления и "
        echo -e "       ${DIM}Отслеживания работы"
        echo ""
        echo -e "  ${CYAN}[2]${NC}  ${BOLD}Меню VPN${NC}"
        echo -e "       ${DIM}Меню автоматической установки${NC}"
        echo -e "       ${DIM}VPN через 3x-ui или Remnawave"
        echo ""
        echo -e "  ${YELLOW}[3]${NC}  ${BOLD}Установка mtproxyl${NC}"
        echo -e "       ${DIM}Установка Telegram MTProto прокси менеджера${NC}"
        echo -e "       ${DIM}на базе движка telemt (Docker)${NC}"
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
            3)
                echo ""
                log_info "Запуск установки mtproxyl..."
                echo ""
                wget -qO /tmp/mtproxyl-install.sh https://raw.githubusercontent.com/Liafanx/MTProxyL/main/install.sh && sudo bash /tmp/mtproxyl-install.sh && source ~/.bashrc
                echo ""
                log_success "Установка mtproxyl завершена"
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

# ══════════════════════════════════════════════════════════════
#  ПАРСИНГ АРГУМЕНТОВ КОМАНДНОЙ СТРОКИ
# ══════════════════════════════════════════════════════════════

FLAG_TELEMT=""
FLAG_ZIG=""
FLAG_MTG=""
FLAG_FIX=""
FLAG_NO_FIX=""
FIX_TYPE=""              # v2, v3, v4, nft
FIX_PORT=""              # порт для фикса
PROXY_PORT=""            # порт прокси
DOMAIN=""
TELEMT_VERSION=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -telemt)
            FLAG_TELEMT="true"
            shift
            ;;
        -zig)
            FLAG_ZIG="true"
            shift
            ;;
        -mtg)
            FLAG_MTG="true"
            shift
            ;;
        -fix)
            FLAG_FIX="true"
            shift
            ;;
        -no-fix)
            FLAG_NO_FIX="true"
            shift
            ;;
        -fix-type)
            case "$2" in
                v2|v3|v4|nft) FIX_TYPE="$2" ;;
                *) echo -e "${RED}[✗]${NC} Неверный тип фикса: $2 (доступны: v2, v3, v4, nft)"; exit 1 ;;
            esac
            shift 2
            ;;
        -fix-port)
            if [[ "$2" =~ ^[0-9]+$ ]] && [ "$2" -ge 1 ] && [ "$2" -le 65535 ]; then
                FIX_PORT="$2"
                shift 2
            else
                echo -e "${RED}[✗]${NC} Неверный порт: $2"; exit 1
            fi
            ;;
        -port)
            if [[ "$2" =~ ^[0-9]+$ ]] && [ "$2" -ge 1 ] && [ "$2" -le 65535 ]; then
                PROXY_PORT="$2"
                shift 2
            else
                echo -e "${RED}[✗]${NC} Неверный порт: $2"; exit 1
            fi
            ;;
        -domain)
            DOMAIN="$2"
            shift 2
            ;;
        -version)
            TELEMT_VERSION="$2"
            shift 2
            ;;
        -h|--help)
            echo ""
            echo -e "  ${BOLD}Использование:${NC}"
            echo -e "    curl ... | sudo bash -s -- [опции]"
            echo ""
            echo -e "  ${BOLD}Опции:${NC}"
            echo -e "    -telemt                установить Telemt"
            echo -e "    -zig                   установить Mtproto.zig"
            echo -e "    -mtg                   установить MTG (пока не реализовано)"
            echo -e "    -fix                   установить фикс"
            echo -e "    -fix-type {v2|v3|v4|nft}   тип фикса (по умолчанию v3)"
            echo -e "    -fix-port <порт>       порт для фикса (если не указан, берётся из -port или спросится)"
            echo -e "    -port <порт>           порт для прокси (и для фикса, если не задан -fix-port)"
            echo -e "    -domain <домен>        SNI домен для прокси (по умолчанию ozon.ru)"
            echo -e "    -version <версия>      версия Telemt (по умолчанию последняя)"
            echo -e "    -no-fix                отключить установку фикса"
            echo -e "    -h, --help             показать эту справку"
            echo ""
            echo -e "  ${BOLD}Примеры:${NC}"
            echo -e "    # Только фикс V3 на порт 8443"
            echo -e "    curl ... | sudo bash -s -- -fix -fix-port 8443"
            echo ""
            echo -e "    # Telemt + V3 фикс на порт 9443, домен my.domain"
            echo -e "    curl ... | sudo bash -s -- -telemt -domain my.domain -port 9443 -fix"
            echo ""
            echo -e "    # Telemt без фикса"
            echo -e "    curl ... | sudo bash -s -- -telemt -no-fix"
            echo ""
            echo -e "    # V4 фикс (zapret2) на порт 443"
            echo -e "    curl ... | sudo bash -s -- -fix -fix-type v4"
            exit 0
            ;;
        *)
            echo -e "${RED}[✗]${NC} Неизвестный аргумент: $1"
            echo -e "  Используйте -h для справки"
            exit 1
            ;;
    esac
done

# ══════════════════════════════════════════════════════════════
#  АВТОМАТИЧЕСКАЯ УСТАНОВКА (если передан хотя бы один флаг)
# ══════════════════════════════════════════════════════════════

if [[ -n "$FLAG_TELEMT" || -n "$FLAG_ZIG" || -n "$FLAG_MTG" || -n "$FLAG_FIX" ]]; then

    echo ""
    echo -e "  ${CYAN}${BOLD}⚙️ АВТОМАТИЧЕСКАЯ УСТАНОВКА v0.4${NC}"
    echo -e "  ${DIM}═════════════════════════════════════════════════${NC}"
    echo ""

    # ── 1. Запрос недостающих параметров ──────────────────────

    # Домен (если ставится прокси)
    if [[ -n "$FLAG_TELEMT" || -n "$FLAG_ZIG" ]]; then
        if [ -z "$DOMAIN" ]; then
            echo -en "  ${BOLD}Введите SNI домен${NC} ${DIM}(по умолчанию: ozon.ru)${NC}: " >&2
            if [ -r /dev/tty ]; then
                read -r DOMAIN </dev/tty
            else
                DOMAIN=""
            fi
            [ -z "$DOMAIN" ] && DOMAIN="ozon.ru"
        fi
        if [ -z "$PROXY_PORT" ]; then
            echo -en "  ${BOLD}Введите порт для прокси${NC} ${DIM}(по умолчанию: 443)${NC}: " >&2
            if [ -r /dev/tty ]; then
                read -r PROXY_PORT </dev/tty
            else
                PROXY_PORT=""
            fi
            [ -z "$PROXY_PORT" ] && PROXY_PORT="443"
        fi
        # Версия Telemt
        if [[ -n "$FLAG_TELEMT" && -z "$TELEMT_VERSION" ]]; then
            echo -en "  ${BOLD}Введите версию Telemt${DIM} (Enter - последняя версия)${NC}: " >&2
            if [ -r /dev/tty ]; then
                read -r TELEMT_VERSION </dev/tty
            else
                TELEMT_VERSION=""
            fi
            if [ -z "$TELEMT_VERSION" ] || [ "$TELEMT_VERSION" = "последняя" ]; then
                TELEMT_VERSION=$(get_latest_telemt_version)
				log_info "Выбран SNI: $DOMAIN"
                log_info "Выбрана последняя версия: $TELEMT_VERSION"
            fi
        fi
    fi

    # Порт фикса
    if [[ -n "$FLAG_FIX" && -z "$FLAG_NO_FIX" ]]; then
        if [ -z "$FIX_PORT" ]; then
            if [ -n "$PROXY_PORT" ]; then
                FIX_PORT="$PROXY_PORT"
                log_info "Порт фикса взят из порта прокси: $FIX_PORT"
            else
                echo -en "  ${BOLD}Введите порт для фикса${NC} ${DIM}(по умолчанию: 443)${NC}: " >&2
                if [ -r /dev/tty ]; then
                    read -r FIX_PORT </dev/tty
                else
                    FIX_PORT=""
                fi
                [ -z "$FIX_PORT" ] && FIX_PORT="443"
            fi
        fi
        # Тип фикса (если не указан, спрашиваем)
        if [ -z "$FIX_TYPE" ]; then
            echo "" >&2
            echo -e "  ${BOLD}Выберите вариант фикса:${NC}" >&2
            echo -e "  ${DIM}══════════════════════════════════════════════${NC}" >&2
            echo "" >&2
            echo -e "  ${YELLOW}[V2]${NC}  ${BOLD}v2 фикс iptables${NC} (TTL+Length) — разделение по TTL+Length" >&2
            echo -e "${DIM}  Если TTL <65 и length 64 -> это ios и принимаем пакеты без лимита" >&2
            echo -e "${DIM}  Иначе -> это другое ус-во и ставим SYN 1 пакет в 1.1 сек." >&2
            echo "" >&2
            echo -e "  ${GREEN}[V3]${NC}  ${BOLD}v3 фикс iptables${NC} (u32) — разделение по байтам из пакета — ${GREEN}рекомендуется${NC}" >&2
            echo -e "${DIM}  Если совпало -> это ios и принимаем пакеты без лимита" >&2
            echo -e "${DIM}  Если не совпало -> это другое ус-во и ставим SYN 1 пакет в 1.1 сек." >&2
            echo "" >&2
            echo -e "  ${CYAN}[V4]${NC}  ${BOLD}v4 фикс zapret2${NC} — быстрый (на этапе тестирования)" >&2
            echo -e "${DIM}  Работает с помощью zapret2 на уровне TCP-пакетов:" >&2
            echo -e "${DIM}  disorder + badsum + window control" >&2
            echo "" >&2
            echo -e "  ${GREEN}[nft]${NC}  ${BOLD}v3 фикс nftables${NC} — совместим с Docker" >&2
            echo -e "${DIM}  Разделение по байтам из пакета, как в v3 iptables" >&2
            echo -e "${DIM}  Если совпало -> это ios и принимаем пакеты без лимита" >&2
            echo -e "${DIM}  Если не совпало -> это другое ус-во и ставим SYN 1 пакет в 1.1 сек." >&2
            echo "" >&2
            while true; do
                echo -en "  ${NC}${BOLD}Ввод${GREEN}${BOLD} (v2/v3/v4/nft, Enter - v3)${NC}:${NC} " >&2
                if [ -r /dev/tty ]; then
                    read -r answer </dev/tty
                else
                    answer=""
                fi
                answer="${answer:-v3}"
                case "$answer" in
                    v2|v3|v4|nft) FIX_TYPE="$answer"; break ;;
                    *) echo -e "  ${RED}Неверный ввод. Допустимо: v2, v3, v4, nft${NC}" >&2 ;;
                esac
            done
        fi
    fi

    # ── 2. Подготовка окружения ──────────────────────────────

    # Всегда скачиваем свежий rules.sh
    mkdir -p "$INSTALL_DIR/data"
    log_info "Загрузка свежего rules.sh..."
    curl -fsSL "$BASE_URL/data/rules.sh" -o "$INSTALL_DIR/data/rules.sh"
    chmod +x "$INSTALL_DIR/data/rules.sh"

    # Если тип фикса v4, скачиваем zapret2_fix.sh
    if [[ "$FIX_TYPE" == "v4" ]]; then
        log_info "Загрузка свежего zapret2_fix.sh..."
        curl -fsSL "$BASE_URL/data/zapret2_fix.sh" -o "$INSTALL_DIR/data/zapret2_fix.sh"
        chmod +x "$INSTALL_DIR/data/zapret2_fix.sh"
    fi

    # Подключаем rules.sh
    source "$INSTALL_DIR/data/rules.sh"

    # Если тип v4, подключаем zapret2_fix.sh
    if [[ "$FIX_TYPE" == "v4" ]]; then
        if [ -f "$INSTALL_DIR/data/zapret2_fix.sh" ]; then
            source "$INSTALL_DIR/data/zapret2_fix.sh"
        else
            log_error "zapret2_fix.sh не загружен"
            exit 1
        fi
    fi

    # ── 3. Установка прокси ──────────────────────────────────

    # Telemt
    if [[ -n "$FLAG_TELEMT" ]]; then
        echo "" >&2
        log_info "Установка Telemt версии $TELEMT_VERSION на домен $DOMAIN, порт $PROXY_PORT..."
        curl -fsSL https://raw.githubusercontent.com/telemt/telemt/main/install.sh | sh -s -- "$TELEMT_VERSION" -l 2 -d "$DOMAIN" -p "$PROXY_PORT"
        log_success "Telemt установлен"
    fi

    # Zig
    if [[ -n "$FLAG_ZIG" ]]; then
        echo "" >&2
        log_info "Установка Mtproto.zig на домен $DOMAIN, порт $PROXY_PORT..."
        curl -fsSL https://raw.githubusercontent.com/sleep3r/mtproto.zig/main/deploy/bootstrap.sh | sudo bash
        sudo mtbuddy install --port "$PROXY_PORT" --domain "$DOMAIN" --middle-proxy --no-tcpmss --no-masking --no-nfqws --no-dpi --yes
        log_success "Mtproto.zig установлен"
    fi

    # MTG (пока заглушка)
    if [[ -n "$FLAG_MTG" ]]; then
        log_warning "Установка MTG пока не реализована в автоматическом режиме."
    fi

    # ── 4. Установка фикса ──────────────────────────────────

    if [[ -n "$FLAG_FIX" && -z "$FLAG_NO_FIX" ]]; then
        echo "" >&2
        log_info "Установка фикса типа $FIX_TYPE на порт $FIX_PORT..."

        # Вызываем install_syn_fix с переданными параметрами
        install_syn_fix -auto_install -port "$FIX_PORT" -type "$FIX_TYPE"

        log_success "Фикс установлен"
    fi

    echo "" >&2
    log_success "Автоматическая установка завершена!"
    echo "" >&2
    exit 0
fi

# ── ЕСЛИ АРГУМЕНТОВ НЕТ — ПОКАЗЫВАЕМ ИНТЕРАКТИВНОЕ МЕНЮ ──────
show_main_menu
