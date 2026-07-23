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

# ── Функция рисования меню ─────────────────────────────────────
draw_menu() {
    local selected=$1
    clear 2>/dev/null || printf '\033[2J\033[H'
    echo ""
    echo -e "  ${CYAN}${BOLD}⚙️ ${NC}${BOLD}Установка фикса ${CYAN}${BOLD}MEKO ${VERSION}2 ${CYAN}${BOLD}⚙️${NC}"
    echo -e "  ${BOLD}${DIM}═════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${BOLD}Выберите вариант установки:${NC}"
    echo ""

    # Пункты меню: номер, заголовок, описание строки 1, описание строки 2 (может быть пусто)
    items=(
        "1|Стандартная установка|Установит MEKO Launcher и все необходимые файлы|Для дальнейшей работы и управления Mtproto proxy|${GREEN}${BOLD}(рекомендуется)${NC}"
        "2|Автоматическая установка|Откроет простое меню автоматической и полуавтоматической установки|Полуавтоматический вариант попросит ввести кастомные параметры|Автоматический вариант установит универсальный вариант сам|${CYAN}(для новичков)${NC}"
        "0|Выход|||"
    )

    local idx=0
    for item in "${items[@]}"; do
        IFS='|' read -r num title line1 line2 extra <<< "$item"
        local marker=" "
        local color="${NC}"
        if [ $idx -eq $selected ]; then
            marker="${GREEN}${BOLD}▶${NC}"
            color="${GREEN}${BOLD}"
        fi
        # Вывод номера + маркер
        printf "  %s  " "$marker"
        if [ -n "$extra" ]; then
            printf "${GREEN}${BOLD}[%s]${NC}  ${color}%s${NC}  %s\n" "$num" "$title" "$extra"
        else
            printf "${GREEN}${BOLD}[%s]${NC}  ${color}%s${NC}\n" "$num" "$title"
        fi
        if [ -n "$line1" ] && [ -n "$line2" ]; then
            printf "       ${DIM}%s${NC}\n" "$line1"
            printf "       ${DIM}%s${NC}\n" "$line2"
        elif [ -n "$line1" ]; then
            printf "       ${DIM}%s${NC}\n" "$line1"
        fi
        printf "\n"
        ((idx++))
    done

    echo -e "  ${DIM}Используйте ${BOLD}↑↓${NC}${DIM} или ${BOLD}j/k${NC}${DIM} для перемещения, ${BOLD}Enter${NC}${DIM} для выбора, ${BOLD}0/1/2${NC}${DIM} для быстрого выбора${NC}"
    echo ""
    echo -en "  ${NC}${BOLD}Ввод: ${NC}"
}

# ── Основная функция меню ─────────────────────────────────────
show_menu() {
    local current=0
    local total_items=3

    while true; do
        draw_menu $current

        # Читаем один символ без эха
        read -s -n1 key 2>/dev/null
        # Обработка специальных клавиш
        if [[ $key == $'\033' ]]; then
            # Это ESC - читаем остальные символы (стрелки)
            read -s -n1 -t 0.1 key2
            if [[ $key2 == '[' ]]; then
                read -s -n1 -t 0.1 key3
                case "$key3" in
                    'A') # стрелка вверх
                        ((current--))
                        if [ $current -lt 0 ]; then current=$((total_items-1)); fi
                        ;;
                    'B') # стрелка вниз
                        ((current++))
                        if [ $current -ge $total_items ]; then current=0; fi
                        ;;
                esac
            fi
        else
            case "$key" in
                'j'|'J') # вниз
                    ((current++))
                    if [ $current -ge $total_items ]; then current=0; fi
                    ;;
                'k'|'K') # вверх
                    ((current--))
                    if [ $current -lt 0 ]; then current=$((total_items-1)); fi
                    ;;
                '0') # выход
                    current=2
                    break
                    ;;
                '1') # стандартная
                    current=0
                    break
                    ;;
                '2') # автоматическая
                    current=1
                    break
                    ;;
                'q'|'Q') # выход
                    current=2
                    break
                    ;;
                '') # Enter – выбрать текущий
                    break
                    ;;
                *) # любой другой символ – игнорируем
                    ;;
            esac
        fi
    done

    # Возвращаем выбранный индекс
    echo "" > /dev/tty
    return $current
}

# ── Запуск меню и обработка выбора ──────────────────────────
show_menu
choice=$?

clear 2>/dev/null || printf '\033[2J\033[H'
echo ""
case "$choice" in
    0) # стандартная установка
        echo -e "  ${GREEN}[✓]${NC} Выбрана стандартная установка"
        sleep 1
        if ensure_file "install_main.sh"; then
            bash "$INSTALL_DIR/install_main.sh"
            exit 0
        else
            log_error "Не удалось загрузить install_main.sh"
            exit 1
        fi
        ;;
    1) # автоматическая установка
        echo -e "  ${GREEN}[✓]${NC} Выбрана автоматическая установка"
        sleep 1
        if ensure_file "install_auto.sh"; then
            bash "$INSTALL_DIR/install_auto.sh"
            exit 0
        else
            log_error "Не удалось загрузить install_auto.sh"
            exit 1
        fi
        ;;
    2) # выход
        echo -e "  ${YELLOW}[!]${NC} Выход..."
        exit 0
        ;;
    *)
        # fallback (если что-то пошло не так) – стандартная установка
        echo -e "  ${YELLOW}[!]${NC} Неверный выбор, запускаем стандартную установку"
        sleep 1
        if ensure_file "install_main.sh"; then
            bash "$INSTALL_DIR/install_main.sh"
            exit 0
        else
            log_error "Не удалось загрузить install_main.sh"
            exit 1
        fi
        ;;
esac
