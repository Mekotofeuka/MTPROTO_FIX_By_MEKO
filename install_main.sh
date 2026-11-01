#!/bin/bash
set -e

BASE_URL="https://raw.githubusercontent.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/main" 
MANIFEST_URL="$BASE_URL/data/manifest.txt"
MANIFEST_FILE="$(mktemp /tmp/mtpr-manifest.XXXXXX.txt 2>/dev/null)" || {
    echo "  [✗] Не удалось создать временный файл для манифеста" >&2
    exit 1
}
INSTALL_DIR="/opt/mtpr-simple"

# ── Неинтерактивный режим: не открывать меню в конце ─────────
# Включается переменной MEKOPR_NO_MENU=1 или флагом --no-menu.
# Нужен flag-установке: её вызывают в &&-цепочке, и ожидание ввода
# на /dev/tty заблокировало бы всю цепочку.
NO_MENU=0
if [ "${MEKOPR_NO_MENU:-0}" = "1" ]; then
    NO_MENU=1
fi
for _arg in "$@"; do
    if [ "$_arg" = "--no-menu" ]; then
        NO_MENU=1
    fi
done

# ── Цвета (только когда stdout — терминал; в пайп/файл не течём ESC) ──
if [ -t 1 ]; then
    GREEN='\033[0;32m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    YELLOW='\033[0;33m'
    RED='\033[0;31m'
    BOLD='\033[1m'
    DIM='\033[2m'
    NC='\033[0m'
else
    GREEN=''; BLUE=''; CYAN=''; YELLOW=''; RED=''; BOLD=''; DIM=''; NC=''
fi

# ── Экспортируем цвета для дочерних процессов ──────────────
export GREEN BLUE CYAN YELLOW RED BOLD DIM NC

# ── Проверка root ────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}[✗]${NC} Запустите от root: ${BOLD}curl -fsSL ... | sudo bash${NC}" >&2
    exit 1
fi

# ── Шапка ─────────────────────────────────────────────────────
echo ""
echo -e "  ${NC}${BOLD}⚙️ УСТАНОВКА${CYAN}${BOLD} MEKOPR ${NC}${BOLD}(РЕЖИМ: ${CYAN}${BOLD}Main${NC}${BOLD}) v0.22${NC}"
echo -e "  ${BOLD}${DIM}═════════════════════════════════════════════════${NC}"
echo ""

# ── Получение манифеста ──────────────────────────────────────
echo -e "  ${BLUE}[i]${NC} Загрузка данных..."
if ! curl -fsSL --connect-timeout 10 --max-time 120 "$MANIFEST_URL" -o "$MANIFEST_FILE"; then
    echo -e "  ${RED}[✗]${NC} Не удалось загрузить информацию о необходимых файлах"
    exit 1
fi

# ── Сохраняем локальную копию манифеста (нужна меню/обновлению) ──
mkdir -p "$INSTALL_DIR/data"
cp -f "$MANIFEST_FILE" "$INSTALL_DIR/data/manifest.txt" 2>/dev/null || true

# ── Определение имени текущего скрипта ──────────────────────
# При запуске через `curl | bash` $0 = "bash" (не файл), а BASH_SOURCE
# пуст — берём корректное имя установщика, чтобы самоисключение из
# манифеста всё равно сработало (раньше подставлялся install_auto.sh).
SCRIPT_NAME=""
if [ -n "${INSTALL_SCRIPT_NAME:-}" ]; then
    SCRIPT_NAME="$INSTALL_SCRIPT_NAME"
elif [ -f "$0" ]; then
    SCRIPT_NAME=$(basename "$0")
elif [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    SCRIPT_NAME=$(basename "${BASH_SOURCE[0]}")
else
    SCRIPT_NAME=$(basename "$0")
    case "$SCRIPT_NAME" in
        ""|bash|sh|dash|-bash|sudo) SCRIPT_NAME="install_main.sh" ;;
    esac
fi

echo -e "  ${BLUE}[i]${NC} Исполняемый файл: ${SCRIPT_NAME}"
echo ""

# ── СОЗДАНИЕ ВСЕХ НЕОБХОДИМЫХ ПАПОК ЗАРАНЕЕ ────────────────
mkdir -p "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR/proxys"
mkdir -p "$INSTALL_DIR/data"

# ── Функция скачивания файла с повторными попытками ──────────
download_file() {
    local file="$1"
    local desc="$2"
    local url="$BASE_URL/$file"
    local dest="$INSTALL_DIR/$file"
    local name
    name=$(basename "$file")
    local attempts=3
    local count=0
    local success=0
    local err_msg=""
    local errfile
    errfile=$(mktemp) || errfile="/tmp/curl_error.$$.$RANDOM.log"
    
    # Получаем размер файла (опционально)
    local size
    size=$(curl -sI --max-time 5 "$url" 2>/dev/null | grep -i "Content-Length" | awk '{print $2}' | tr -d '\r')
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
    
    while [ "$count" -lt "$attempts" ]; do
        # Убираем подавление ошибок, чтобы видеть причину
        if curl -fsSL --connect-timeout 10 --max-time 120 "$url" -o "$dest" 2>"$errfile"; then
            echo -e "  ${GREEN}${BOLD}✓${NC}${BOLD} Скачан успешно:${NC} ${GREEN}${BOLD}${name}${NC} (${size_str})"
            success=1
            break
        else
            err_msg=$(head -1 "$errfile" 2>/dev/null)
            count=$((count + 1))
            if [ "$count" -lt "$attempts" ]; then
                echo -e "  ${YELLOW}⚠${NC} Попытка $count не удалась (${err_msg:-неизвестная ошибка}), повтор через 1 сек..."
                sleep 1
            fi
        fi
    done
    rm -f "$errfile"
    
    if [ "$success" -eq 0 ]; then
        echo -e "  ${RED}✗${NC} ${RED}${name}${NC} — ошибка загрузки (после $attempts попыток, последняя ошибка: ${err_msg:-неизвестна})"
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

    # Обрезаем пробелы без xargs (xargs ломает пути с пробелами/кавычками)
    file_path="${file_path#"${file_path%%[![:space:]]*}"}"
    file_path="${file_path%"${file_path##*[![:space:]]}"}"
    description="${description#"${description%%[![:space:]]*}"}"
    description="${description%"${description##*[![:space:]]}"}"

    # Пропускаем комментарии и пустые (в т.ч. из одних пробелов) строки
    [[ "$file_path" =~ ^#.*$ ]] && continue
    [ -z "$file_path" ] && continue
    
    file_name=$(basename "$file_path")
    
    # Для install_main.sh нормально исключать себя, чтобы не перезаписывать работающий скрипт
    if [ "$file_name" = "$SCRIPT_NAME" ]; then
        echo -e "  ${DIM}⊘ Пропускаем себя: ${file_name}${NC}"
        continue
    fi
    
    FILES_TO_DOWNLOAD+=("$file_path|$description")
    
done < "$MANIFEST_FILE"

# ── Проверка, что манифест содержит main.sh ─────────────────
manifest_has_main=0
for _entry in "${FILES_TO_DOWNLOAD[@]}"; do
    IFS='|' read -r _fp _desc <<< "$_entry"
    if [ "$(basename "$_fp")" = "main.sh" ]; then manifest_has_main=1; break; fi
done
if [ "$manifest_has_main" -ne 1 ]; then
    echo -e "  ${RED}[✗]${NC} В манифесте нет main.sh — установка невозможна (манифест пуст или повреждён)"
    rm -f "$MANIFEST_FILE"
    exit 1
fi

# ── Вывод списка файлов для загрузки ────────────────────────
echo -e "  ${BOLD}Файлы для загрузки (${#FILES_TO_DOWNLOAD[@]} шт.):${NC}"
for entry in "${FILES_TO_DOWNLOAD[@]}"; do
    IFS='|' read -r file_path description <<< "$entry"
    echo -e "    ${DIM}• ${file_path}${NC} (${description})"
done
echo ""

# ── Загрузка файлов (параллельно, 6 потоков) ───────────────
echo -e "  ${BOLD}Загрузка файлов...${NC}"
echo ""

MAX_PARALLEL=6

# `wait -n` появился только в bash 4.3 (CentOS 7 везёт 4.2): там он падает, а
# очередь не уменьшается — цикл крутится вечно. Поэтому на старом bash ждём
# конкретный PID.
wait_one() {
    if (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 3) )); then
        wait -n || true
    else
        local pid
        pid=$(jobs -rp | head -1)
        [ -n "$pid" ] && wait "$pid"
    fi
    return 0
}

while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    IFS='|' read -r file_path description <<< "$entry"
    download_file "$file_path" "$description" &
    while [ "$(jobs -rp | wc -l)" -ge "$MAX_PARALLEL" ]; do
        wait_one
    done
done < <(printf '%s\n' "${FILES_TO_DOWNLOAD[@]}")
wait || true

# ── Проверка, что все файлы скачались ───────────────────────
echo ""
failed=0
for entry in "${FILES_TO_DOWNLOAD[@]}"; do
    IFS='|' read -r file_path description <<< "$entry"
    if [ ! -f "$INSTALL_DIR/$file_path" ]; then
        echo -e "  ${RED}[✗]${NC} Файл не найден: $file_path"
        failed=1
    fi
done

if [ $failed -eq 1 ]; then
    echo -e "  ${RED}[✗]${NC} Установка не удалась: некоторые файлы не загружены"
    echo -e "  ${YELLOW}Проверьте подключение к интернету и доступность репозитория.${NC}"
    echo -e "  ${YELLOW}Попробуйте запустить установку позже или вручную проверьте файлы.${NC}"
    rm -f "$MANIFEST_FILE"
    exit 1
fi

# ── Установка прав и создание ссылки ────────────────────────
echo ""
echo -ne "  ${CYAN}[+]${NC} Установка прав выполнения... "
if ! chmod +x "$INSTALL_DIR/main.sh"; then
    echo -e "  ${RED}[✗]${NC} Не удалось выставить права на main.sh"
    rm -f "$MANIFEST_FILE"
    exit 1
fi
if compgen -G "$INSTALL_DIR/proxys/*.sh" > /dev/null; then
    if ! chmod +x "$INSTALL_DIR"/proxys/*.sh; then
        echo -e "  ${RED}[✗]${NC} Не удалось выставить права на proxys/*.sh"
        rm -f "$MANIFEST_FILE"
        exit 1
    fi
fi
if compgen -G "$INSTALL_DIR/*.py" > /dev/null; then
    if ! chmod +x "$INSTALL_DIR"/*.py; then
        echo -e "  ${RED}[✗]${NC} Не удалось выставить права на *.py"
        rm -f "$MANIFEST_FILE"
        exit 1
    fi
fi
echo -e "${GREEN}✓${NC}"

# Проверяем, что main.sh существует
if [ ! -f "$INSTALL_DIR/main.sh" ]; then
    echo -e "  ${RED}[✗]${NC} main.sh не найден после загрузки!"
    rm -f "$MANIFEST_FILE"
    exit 1
fi

echo -ne "  ${CYAN}[+]${NC} Создание ссылки ${BOLD}mekopr${NC}... "
if ln -sf "$INSTALL_DIR/main.sh" /usr/local/bin/mekopr; then
    echo -e "${GREEN}✓${NC}"
else
    echo -e "  ${RED}[✗]${NC} Не удалось создать ссылку /usr/local/bin/mekopr"
    rm -f "$MANIFEST_FILE"
    exit 1
fi

echo -ne "  ${CYAN}[+]${NC} Создание короткой ссылки ${BOLD}meko${NC}... "
if ln -sf "$INSTALL_DIR/main.sh" /usr/local/bin/meko; then
    echo -e "${GREEN}✓${NC}"
else
    echo -e "  ${YELLOW}[!]${NC} Не удалось создать /usr/local/bin/meko (не критично — есть mekopr)"
fi

# ── Завершение ───────────────────────────────────────────────
echo ""
echo -e "  ${BOLD}${GREEN}✅ Установка MEKO | MTProto Launcher успешно завершена!${NC}"
echo -e "  ${DIM}─────────────────────────────────────────────────────${NC}"
echo ""
echo -e "  Для открытия меню при дальнейшей работе используйте команду ${BOLD}${GREEN}mekopr${NC} (или короткую ${BOLD}meko${NC})"
echo -e "  ${DIM}Примеры:${NC} ${BOLD}meko online${NC}, ${BOLD}meko telemt${NC}, ${BOLD}meko fix${NC}, ${BOLD}meko nodes${NC}, ${BOLD}mekopr --help${NC}"
echo ""

# Удаляем временный манифест
rm -f "$MANIFEST_FILE"

# Неинтерактивный режим (flag-установка): меню не открываем
if [ "$NO_MENU" -eq 1 ]; then
    echo -e "  ${GREEN}[✓]${NC} Меню установлено. Запустите ${BOLD}sudo mekopr${NC}, чтобы открыть меню."
    echo ""
    exit 0
fi

# Запускаем main.sh если доступен терминал
if { : </dev/tty; } 2>/dev/null; then
    exec "$INSTALL_DIR/main.sh" </dev/tty
fi

echo -e "  ${YELLOW}[!]${NC} Интерактивный терминал недоступен, меню не запущено."
echo -e "  Запустите ${BOLD}sudo mekopr${NC}, чтобы открыть меню вручную."
