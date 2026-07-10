#!/bin/bash
set -e

BASE_URL="https://raw.githubusercontent.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/main"
FILES=("main.sh" "proxys/proxymenu.sh" "proxys/telemt1.sh" "proxys/mtprotozig1.sh" "proxys/telemt_in_docker1.sh" "proxy_checker.py")

# ── Цвета ─────────────────────────────────────────────────────
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ── Проверка root ────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}[✗]${NC} Запустите от root: ${BOLD}curl -fsSL ... | sudo bash${NC}" >&2
    exit 1
fi

# ── Шапка ─────────────────────────────────────────────────────
echo ""
echo -e "  ${BOLD}${CYAN}⚙️ УСТАНОВКА MEKOPR${NC}"
echo -e "  ${BOLD}${DIM}═════════════════════════════════════════════════${NC}"
echo ""

# ── Создание директорий ──────────────────────────────────────
mkdir -p /opt/mtpr-simple/proxys

# ── Асинхронное скачивание ──────────────────────────────────
download_file() {
    local file="$1"
    local url="$BASE_URL/$file"
    local dest="/opt/mtpr-simple/$file"
    local name=$(basename "$file")
    
    # Получаем размер файла
    local size=$(curl -sI "$url" 2>/dev/null | grep -i "Content-Length" | awk '{print $2}' | tr -d '\r')
    local size_str="?"
    if [ -n "$size" ] && [ "$size" -gt 0 ] 2>/dev/null; then
        if [ "$size" -gt 1048576 ]; then
            local mb=$((size / 1048576))
            local remainder=$(((size % 1048576) / 104857))
            if [ "$remainder" -gt 0 ]; then
                size_str="${mb}.${remainder} MB"
            else
                size_str="${mb} MB"
            fi
        elif [ "$size" -gt 1024 ]; then
            size_str="$((size / 1024)) KB"
        else
            size_str="$size B"
        fi
    fi
    
    # Показываем процесс загрузки
    echo -e "  ${CYAN}⏳${NC} Загрузка ${BOLD}${name}${NC}..."
    
    if curl -fsSL "$url" -o "$dest" 2>/dev/null; then
        echo -e "  ${GREEN}✓${NC} ${BOLD}${name}${NC} (${size_str})"
    else
        echo -e "  ${RED}✗${NC} ${BOLD}${name}${NC} — ошибка загрузки"
    fi
}
export -f download_file
export BASE_URL

# ── Запуск параллельной загрузки ────────────────────────────
echo -e "  ${BOLD}Загрузка файлов...${NC}"
echo ""

printf "%s\n" "${FILES[@]}" | xargs -P 6 -I {} bash -c 'download_file "$@"' _ {}

# ── Установка прав и создание ссылки ────────────────────────
echo ""
echo -ne "  ${CYAN}[+]${NC} Установка прав выполнения... "
chmod +x /opt/mtpr-simple/main.sh && chmod +x /opt/mtpr-simple/proxys/*.sh && echo -e "${GREEN}✓${NC}"

echo -ne "  ${CYAN}[+]${NC} Создание ссылки ${BOLD}mekopr${NC}... "
ln -sf /opt/mtpr-simple/main.sh /usr/local/bin/mekopr && echo -e "${GREEN}✓${NC}"

# ── Завершение ───────────────────────────────────────────────
echo ""
echo -e "  ${BOLD}${GREEN}✅ Установка MEKOPR успешно завершена!${NC}"
echo -e "  ${DIM}─────────────────────────────────────────────────────${NC}"
echo ""
echo -e "  Для открытия меню при дальнейшей работе используйте команду ${BOLD}${GREEN}mekopr${NC}"
echo ""

if [ -r /dev/tty ]; then
    exec /opt/mtpr-simple/main.sh </dev/tty
fi

echo -e "  ${YELLOW}[!]${NC} Интерактивный терминал недоступен, меню не запущено."
echo -e "  Запустите ${BOLD}sudo mekopr${NC}, чтобы открыть меню вручную."
