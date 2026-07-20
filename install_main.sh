#!/bin/bash
set -e

BASE_URL="https://raw.githubusercontent.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/main" 
MANIFEST_URL="$BASE_URL/data/manifest.txt"
MANIFEST_FILE="/tmp/manifest.txt"
INSTALL_DIR="/opt/mtpr-simple"

# ── Цвета ─────────────────────────────────────────────────────
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ── Экспортируем цвета для дочерних процессов ──────────────
export GREEN BLUE CYAN YELLOW RED BOLD DIM NC

# ── Проверка root ────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}[✗]${NC} Запустите от root: ${BOLD}curl -fsSL ... | sudo bash${NC}" >&2
    exit 1
fi

clear
# ── Шапка ─────────────────────────────────────────────────────
echo ""
echo -e "  ${NC}${BOLD}⚙️ УСТАНОВКА${CYAN}${BOLD} MEKOPR ${NC}${BOLD}(РЕЖИМ: ${CYAN}${BOLD}Main${NC}${BOLD}) v0.20${NC}"
echo -e "  ${BOLD}${DIM}═════════════════════════════════════════════════${NC}"
echo ""

# ── Получение манифеста ──────────────────────────────────────
echo -e "  ${BLUE}[i]${NC} Загрузка данных..."
if ! curl -fsSL "$MANIFEST_URL" -o "$MANIFEST_FILE"; then
    echo -e "  ${RED}[✗]${NC} Не удалось загрузить информацию о необходимых файлах"
    exit 1
fi

# ── Определение имени текущего скрипта ──────────────────────
if [ -f "$0" ]; then
    SCRIPT_NAME=$(basename "$0")
else
    SCRIPT_NAME="install_auto.sh"
fi

echo -e "  ${BLUE}[i]${NC} Исполняемый файл: ${SCRIPT_NAME}"
echo ""

# ── СОЗДАНИЕ ВСЕХ НЕОБХОДИМЫХ ПАПОК ЗАРАНЕЕ ────────────────
mkdir -p "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR/proxys"
mkdir -p "$INSTALL_DIR/data"

# ── Функция скачивания файла (без создания папок) ──────────
download_file() {
    local file="$1"
    local desc="$2"
    local url="$BASE_URL/$file"
    local dest="$INSTALL_DIR/$file"
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
    
    echo -e "  ${CYAN}⏳${NC}${BOLD} Загрузка ${GREEN}${BOLD}${name}${NC}${BOLD} (${desc})"
    
    if curl -fsSL "$url" -o "$dest" 2>/dev/null; then
        echo -e "  ${GREEN}${BOLD}✓${NC}${BOLD} Скачан успешно:${NC} ${GREEN}${BOLD}${name}${NC} (${size_str})"
        return 0
    else
        echo -e "  ${RED}✗${NC} ${RED}${name}${NC} — ошибка загрузки"
        return 1
    fi
}
export -f download_file
export BASE_URL INSTALL_DIR

# ── Чтение манифеста и исключение себя ──────────────────────
echo -e "  ${BOLD}Чтение файлов из репозитория для загрузки и подготовка к установке...${NC}"
echo ""

FILES_TO_DOWNLOAD=()
while IFS='|' read -r file_path description; do

    [[ "$file_path" =~ ^[[:space:]]*#.*$ ]] && continue
    [ -z "$file_path" ] && continue

    file_path=$(echo "$file_path" | xargs)
    description=$(echo "$description" | xargs)
    
    file_name=$(basename "$file_path")
    
    if [ "$file_name" = "$SCRIPT_NAME" ]; then
        echo -e "  ${DIM}⊘ Пропускаем себя: ${file_name}${NC}"
        continue
    fi
    
    FILES_TO_DOWNLOAD+=("$file_path|$description")
    
done < "$MANIFEST_FILE"

# ── Вывод списка файлов для загрузки ────────────────────────
echo -e "  ${BOLD}Файлы для загрузки (${#FILES_TO_DOWNLOAD[@]} шт.):${NC}"
for entry in "${FILES_TO_DOWNLOAD[@]}"; do
    file_path=$(echo "$entry" | cut -d'|' -f1)
    desc=$(echo "$entry" | cut -d'|' -f2)
    echo -e "    ${DIM}• ${file_path}${NC} (${desc})"
done
echo ""

# ── Загрузка файлов (параллельно, 6 потоков) ───────────────
echo -e "  ${BOLD}Загрузка файлов...${NC}"
echo ""

printf "%s\n" "${FILES_TO_DOWNLOAD[@]}" | xargs -P 6 -I {} bash -c '
    IFS="|" read -r file_path description <<< "$1"
    download_file "$file_path" "$description"
' _ {}

# ── Установка прав и создание ссылки ────────────────────────
echo ""
echo -ne "  ${CYAN}[+]${NC} Установка прав выполнения... "
chmod +x "$INSTALL_DIR/main.sh" 2>/dev/null || true
chmod +x "$INSTALL_DIR"/proxys/*.sh 2>/dev/null || true
chmod +x "$INSTALL_DIR"/*.py 2>/dev/null || true
echo -e "${GREEN}✓${NC}"

# Проверяем, что main.sh существует
if [ ! -f "$INSTALL_DIR/main.sh" ]; then
    echo -e "  ${RED}[✗]${NC} main.sh не найден после загрузки!"
    exit 1
fi

echo -ne "  ${CYAN}[+]${NC} Создание ссылки ${BOLD}mekopr${NC}... "
ln -sf "$INSTALL_DIR/main.sh" /usr/local/bin/mekopr && echo -e "${GREEN}✓${NC}"

# ── Завершение ───────────────────────────────────────────────
echo ""
echo -e "  ${BOLD}${GREEN}✅ Установка MEKO | MTProto Launcher успешно завершена!${NC}"
echo -e "  ${DIM}─────────────────────────────────────────────────────${NC}"
echo ""
echo -e "  Для открытия меню при дальнейшей работе используйте команду ${BOLD}${GREEN}mekopr${NC}"
echo ""

# Удаляем временный манифест
rm -f "$MANIFEST_FILE"

# Запускаем main.sh если доступен терминал
if [ -r /dev/tty ]; then
    exec "$INSTALL_DIR/main.sh" </dev/tty
fi

echo -e "  ${YELLOW}[!]${NC} Интерактивный терминал недоступен, меню не запущено."
echo -e "  Запустите ${BOLD}sudo mekopr${NC}, чтобы открыть меню вручную."
