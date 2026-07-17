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

# ── Логирование (все сообщения в stderr, чтобы не ломать подстановки) ──
log_info() { echo -e "  ${BLUE}[i]${NC} $1" >&2; }
log_success() { echo -e "  ${GREEN}[✓]${NC} $1" >&2; }
log_error() { echo -e "  ${RED}[✗]${NC} $1" >&2; }
log_warning() { echo -e "  ${YELLOW}[!]${NC} $1" >&2; }

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

# ── Функция получения публичного IP ──────────────────────────
get_public_ip() {
    local _ip=""
    _ip=$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null) ||
    _ip=$(curl -4 -fsS --max-time 5 https://ifconfig.me 2>/dev/null) ||
    _ip=$(curl -4 -fsS --max-time 5 https://icanhazip.com 2>/dev/null) ||
    _ip=""
    echo "$_ip"
}

# ── Функция получения последней версии Telemt из релизов ─────
get_latest_telemt_version() {
    local version=""
    # Пробуем получить через GitHub API с помощью awk (надёжный парсер)
    version=$(curl -fsS --max-time 5 "https://api.github.com/repos/telemt/telemt/releases/latest" 2>/dev/null | awk -F'"' '/"tag_name"/ {print $4}')
    # Если не получилось — пробуем через список релизов
    if [ -z "$version" ]; then
        version=$(curl -fsS --max-time 5 "https://api.github.com/repos/telemt/telemt/releases" 2>/dev/null | awk -F'"' '/"tag_name"/ {print $4; exit}')
    fi
    # Если всё равно пусто — используем fallback (3.4.23)
    if [ -z "$version" ]; then
        version="3.4.23"
        # Предупреждение выводим отдельной строкой в stderr
        log_warning "Не удалось определить последнюю версию Telemt, используем $version" >&2
    fi
    echo "$version"
}

# ── Режим автоустановки (БЕЗ ЗАПРОСОВ) ─────────────────────
auto_install_mode() {
    clear
    echo ""
    echo -e "  ${NC}${BOLD}⚙️ АВТОУСТАНОВКА${CYAN}${BOLD} MEKOPR ${NC}${BOLD}v0.29${NC}"
    echo -e "  ${BOLD}${DIM}═════════════════════════════════════════════════${NC}"
    echo ""
    
    # Параметры по умолчанию
    local domain="ozon.ru"
    local port="443"
    local server_ip=$(get_public_ip)
    [ -z "$server_ip" ] && server_ip="не определено"
    
    # Получаем последнюю версию Telemt (без мусора в stdout)
    local telemt_version=$(get_latest_telemt_version)
    
    # Информация о предстоящей установке (теперь версия выводится корректно)
    echo -e "  ${BOLD}Будет выполнена установка:${NC}"
    echo -e "  • Telemt версии ${GREEN}${telemt_version}${NC} на домен ${CYAN}$domain${NC}, порт ${CYAN}$port${NC}"
    echo -e "  • SYN FIX (новый iptables, вариант 1) на порт ${CYAN}$port${NC}"
    echo -e "  • IP-адрес сервера: ${CYAN}$server_ip${NC}"
    echo ""
    echo -e "  ${YELLOW}Установка с кастомными параметрами доступна в полуавтоматическом режиме${NC}"
    echo ""
    echo -en "  ${BOLD}Продолжить установку? [y/N]:${NC} "
    local confirm
    confirm=$(read_input)
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        log_info "Установка отменена"
        sleep 1
        return
    fi
    
    echo ""
    log_info "Начинаем автоустановку..."
    echo ""
    
    # 1. Установка Telemt (конкретная версия, русский язык)
    log_info "Установка Telemt версии ${telemt_version} на домен $domain, порт $port..."
    if curl -fsSL https://raw.githubusercontent.com/telemt/telemt/main/install.sh | sh -s -- "$telemt_version" -l 2 -d "$domain" -p "$port"; then
        log_success "Telemt ${telemt_version} установлен успешно"
    else
        log_error "Ошибка установки Telemt ${telemt_version}"
        echo -e "  ${GRAY}Нажмите любую клавишу...${NC}"
        read -rsn1
        return
    fi
    
    # 2. Установка SYN FIX (автоматически, вариант 1, порт)
    log_info "Установка SYN FIX (новый iptables, порт $port)..."
    if install_syn_fix -auto_install "$port"; then
        log_success "SYN FIX установлен успешно"
    else
        log_error "Ошибка установки SYN FIX"
        echo -e "  ${GRAY}Нажмите любую клавишу...${NC}"
        read -rsn1
        return
    fi
    
    echo ""
    log_success "Автоустановка завершена успешно!"
    echo -e "  ${BOLD}Данные для подключения:${NC}"
    echo -e "  • Домен: ${CYAN}$domain${NC}"
    echo -e "  • Порт: ${CYAN}$port${NC}"
    echo -e "  • IP: ${CYAN}$server_ip${NC}"
    echo -e "  • Версия Telemt: ${GREEN}${telemt_version}${NC}"
    echo -e "  • Секрет: (сгенерирован автоматически, смотрите логи Telemt)"
    echo ""
    echo -e "  ${GRAY}Нажмите любую клавишу для выхода...${NC}"
    read -rsn1
    exit 0
}

# ── Режим полуавтоматической установки ─────────────────────
semi_auto_install_mode() {
    clear
    echo ""
    echo -e "  ${NC}${BOLD}⚙️ ПОЛУАВТОМАТИЧЕСКАЯ УСТАНОВКА${CYAN}${BOLD} MEKOPR ${NC}${BOLD}v0.29${NC}"
    echo -e "  ${BOLD}${DIM}═════════════════════════════════════════════════${NC}"
    echo ""
    log_info "Запуск стандартного установщика..."
    sleep 1
    
    # ── Установка SYN FIX ──────────────────────────────────────
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
}

# ── Главное меню выбора режима ──────────────────────────────
show_mode_menu() {
    clear
    echo ""
    echo -e "  ${NC}${BOLD}⚙️ УСТАНОВКА${CYAN}${BOLD} MEKOPR ${NC}${BOLD}(РЕЖИМ: ${CYAN}${BOLD}Auto${NC}${BOLD}) v0.29${NC}"
    echo -e "  ${BOLD}${DIM}═════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${BOLD}Выберите режим установки:${NC}"
    echo ""
    echo -e "  ${CYAN}[1]${NC}  ${BOLD}Автоустановка${NC}  ${NC}"
    echo -e "  ${DIM}Выведет параметры с которыми будет установлен прокси и фикс"
	echo -e "  ${DIM}Запросит подтверждение и выполнит установку"
    echo -e "  ${CYAN}[2]${NC}  ${BOLD}Полуавтоматическая установка${NC}  ${NC}"
	echo -e "  ${DIM}Спросит порт, версию фикса, версию телемт и выполнит установку "
    echo -e "  ${RED}[0]${NC}  ${BOLD}Выйти${NC}"
    echo ""
    echo -en "  ${BOLD}Выбор (по умолчанию ${GREEN}${BOLD}1 или Enter${NC}${BOLD}):${NC} "
    local mode_choice
    mode_choice=$(read_input)
    [ -z "$mode_choice" ] && mode_choice="1"
    
    case "$mode_choice" in
        1)
            auto_install_mode
            ;;
        2)
            semi_auto_install_mode
            ;;
        0)
            echo ""
            log_info "Выход..."
            exit 0
            ;;
        *)
            log_warning "Неверный выбор, попробуйте снова"
            sleep 1
            show_mode_menu
            ;;
    esac
}

# ── Точка входа ──────────────────────────────────────────────
show_mode_menu
