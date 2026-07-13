#!/bin/bash
# telemt_panel_amirotin.sh — управление панелью Telemt Panel (amirotin)

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

# ── Файл для сохранения пути к конфигу (используем общий с main.sh) ──
CONFIG_PATH_FILE="/opt/mtpr-simple/config_path"

# ── Функция обрезки пробелов ──────────────────────────────
trim() {
    local var="$1"
    var="${var#"${var%%[![:space:]]*}"}"
    var="${var%"${var##*[![:space:]]}"}"
    printf '%s' "$var"
}

# ── Функция получения текущего пути к конфигу Telemt ──────────────
get_config_path() {
    if [ -f "$CONFIG_PATH_FILE" ] && [ -s "$CONFIG_PATH_FILE" ]; then
        path=$(cat "$CONFIG_PATH_FILE")
        if [ "$path" != "skip" ]; then
            echo "$path"
            return 0
        fi
    fi
    echo "/etc/telemt/telemt.toml"
    return 0
}

# ── Функции для работы с TOML ──────────────────────────────
_toml_get_value() {
    local _key="$1" _file="$2"
    [ -f "$_file" ] || return 0
    awk -v k="$_key" '
        /^[[:space:]]*#/ { next }
        $1 == k && $2 == "=" { gsub(/[^0-9]/, "", $3); print $3; exit }
    ' "$_file" 2>/dev/null
}

# ── Функция проверки, установлен ли Telemt ──────────────────
is_telemt_installed() {
    if command -v telemt >/dev/null 2>&1; then
        return 0
    fi
    if systemctl is-active --quiet telemt 2>/dev/null; then
        return 0
    fi
    if pgrep -x telemt >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

# ── Функция получения версии Telemt ─────────────────────────
get_telemt_version() {
    if command -v telemt >/dev/null 2>&1; then
        telemt --version 2>/dev/null | head -1 | awk '{print $2}'
    else
        echo ""
    fi
}

# ── Функция получения порта(ов) из конфига ──────────────────
get_telemt_ports() {
    local config_path=$(get_config_path)
    if [ ! -f "$config_path" ]; then
        echo ""
        return 1
    fi
    grep -E '^port[[:space:]]*=' "$config_path" 2>/dev/null | awk -F'=' '{print $2}' | tr -d ' "'
}

# ── Функция проверки, установлена ли панель ─────────────────
is_panel_installed() {
    if command -v telemt-panel >/dev/null 2>&1; then
        return 0
    fi
    if systemctl is-active --quiet telemt-panel 2>/dev/null; then
        return 0
    fi
    if [ -f "/usr/local/bin/telemt-panel" ]; then
        return 0
    fi
    return 1
}

# ── Функция получения версии панели ─────────────────────────
get_panel_version() {
    if command -v telemt-panel >/dev/null 2>&1; then
        telemt-panel version 2>/dev/null | head -1 | awk '{print $2}'
    else
        echo ""
    fi
}

# ── Функция получения порта панели из конфига ──────────────
get_panel_port() {
    local config_path="/etc/telemt-panel/config.toml"
    if [ -f "$config_path" ]; then
        grep -E '^listen[[:space:]]*=' "$config_path" 2>/dev/null | head -1 | sed -E 's/^[[:space:]]*listen[[:space:]]*=[[:space:]]*"//; s/".*$//' | awk -F: '{print $2}'
    else
        echo ""
    fi
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

# ── Функция вывода информации о Telemt перед установкой ─────
show_telemt_info() {
    echo ""
    echo -e "  ${NC}${BOLD}Информация о${CYAN} Telemt${NC}${BOLD}:"
    echo -e "  ${DIM}─────────────────────────────────────────${NC}"
    
    if is_telemt_installed; then
        echo -e "  ${BOLD}Telemt:${NC} ${GREEN}${BOLD}установлен${NC}"
        
        local version=$(get_telemt_version)
        if [ -n "$version" ]; then
            echo -e "  ${BOLD}Версия:${NC} ${GREEN}${BOLD}${version}${NC}"
        fi
        
        local ports=$(get_telemt_ports)
        if [ -n "$ports" ]; then
            echo -e "  ${BOLD}Порт(ы):${NC} ${CYAN}${ports}${NC}"
        fi
        
        # Получаем путь к конфигу
        local config_path=$(get_config_path)
        if [ -f "$config_path" ]; then
            # Извлекаем путь к папке из пути к конфигу
            local telemt_dir=$(dirname "$config_path")
            echo -e "  ${BOLD}Путь к папке:${NC} ${CYAN}${telemt_dir}${NC}  ${DIM}(скопируйте это, когда установщик спросит - вставьте)${NC}"
            echo -e "  ${BOLD}Путь к конфигу:${NC} ${CYAN}${config_path}${NC}"
            
            # Генерируем пароль (подходит для всех ОС)
            local generated_password=""
            # Пробуем через /dev/urandom (самый надежный)
            if [ -c /dev/urandom ] 2>/dev/null; then
                generated_password=$(tr -dc 'A-Za-z0-9!@#$%^&*()_+-=' < /dev/urandom 2>/dev/null | head -c 24)
            fi
            # Если не вышло — пробуем через openssl (fallback)
            if [ -z "$generated_password" ] && command -v openssl >/dev/null 2>&1; then
                generated_password=$(openssl rand -base64 24 2>/dev/null | tr -d '/+=' | head -c 24)
            fi
            # Если всё еще пусто — генерируем через bash (самый простой вариант)
            if [ -z "$generated_password" ]; then
                generated_password="$(date +%s | sha256sum | base64 | head -c 24 | tr -d '/+=')"
            fi
            
            if [ -n "$generated_password" ]; then
                echo -e "  ${BOLD}Сгенерированный пароль для учетки:${NC} ${GREEN}${BOLD}${generated_password}${NC}"
				echo -e "  ${DIM}(Вы можете либо придумать свой пароль во время установки панели, либо использовать пароль выше.)"
            fi
        fi
    else
        echo -e "  ${BOLD}Telemt:${NC} ${RED}не установлен${NC}"
        echo -e "  ${YELLOW}⚠ Для работы панели требуется установленный Telemt${NC}"
    fi
    
    echo ""
    echo -e "  ${DIM}Эти данные пригодятся вам для дальнейшей установки панели.${NC}"
    echo -e "  ${DIM}Панель автоматически определит API Telemt (По умолчанию - http://127.0.0.1:9091)${NC}"
    echo ""
}

# ── Функция установки панели ────────────────────────────────
install_panel() {
    echo ""
    echo -e "  ${BLUE}[i]${NC} Установка Telemt Panel (amirotin)"
    
    # Проверяем, установлен ли Telemt
    if ! is_telemt_installed; then
        echo ""
        echo -e "  ${YELLOW}[!]${NC} Telemt не установлен!"
        echo -e "  ${YELLOW}Панель требует работающий Telemt-сервер с доступным API.${NC}"
        echo ""
        echo -en "  ${BOLD}Продолжить установку панели? ${GREEN}${BOLD}Y - да${NC}${BOLD}/${RED}${BOLD}N - назад в меню${NC}${BOLD}:${NC} "
        local confirm
        read -r confirm
        if [[ ! "$confirm" =~ ^[yY]$ ]]; then
            echo -e "  ${GRAY}Установка отменена${NC}"
            echo ""
            echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню${NC}"
            read -rsn1
            return 1
        fi
    fi
    
    # Показываем информацию о Telemt
    show_telemt_info
    
    echo -en "  ${BOLD}Продолжить установку панели? ${GREEN}${BOLD}Y - да${NC}${BOLD}/${RED}${BOLD}N - назад в меню${NC}${BOLD}:${NC} "
    local confirm
    read -r confirm
    if [[ "$confirm" =~ ^[nN]$ ]]; then
        echo -e "  ${GRAY}Установка отменена${NC}"
        echo ""
        echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню${NC}"
        read -rsn1
        return 1
    fi
    
    echo ""
    echo -e "  ${BLUE}[i]${NC} Запуск установочного скрипта..."
    echo ""
    
    # Запускаем установку через официальный скрипт
    if curl -fsSL https://raw.githubusercontent.com/amirotin/telemt_panel/main/install.sh | bash; then
        echo ""
        echo -e "  ${GREEN}${BOLD}[✓]${NC} Панель Telemt Panel успешно установлена!"
        
        local panel_port=$(get_panel_port)
        local server_ip=$(get_public_ip)
        if [ -n "$panel_port" ] && [ -n "$server_ip" ]; then
            echo ""
            echo -e "  ${BOLD}Панель доступна по адресу:${NC}"
            echo -e "  ${CYAN}http://${server_ip}:${panel_port}${NC}"
        fi
    else
        echo ""
        echo -e "  ${RED}[✗]${NC} Ошибка установки панели"
    fi
    
    echo ""
    echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню${NC}"
    read -rsn1
}

# ── Функция удаления панели ──────────────────────────────────
uninstall_panel() {
    echo ""
    echo -e "  ${RED}${BOLD}ВНИМАНИЕ:${NC} Будет выполнено удаление Telemt Panel!"
    echo ""
    echo -e "  ${BOLD}Будут удалены:${NC}"
    echo -e "  • Бинарник /usr/local/bin/telemt-panel"
    echo -e "  • Systemd служба telemt-panel.service"
    echo -e "  • Пользователь telemt-panel (при purge)"
    echo ""
    echo -e "  ${YELLOW}[!]${NC} Конфиг и данные останутся (при uninstall)."
    echo -e "  ${YELLOW}[!]${NC} Для полного удаления используйте purge."
    echo ""
    echo -e "  ${BOLD}Выберите тип удаления:${NC}"
    echo -e "  ${CYAN}[1]${NC}  ${BOLD}Uninstall${NC} — удалить сервис и бинарник (конфиг и данные сохраняются)"
    echo -e "  ${RED}[2]${NC}  ${BOLD}Purge${NC} — полное удаление (включая пользователя, конфиг и данные)"
    echo -e "  ${CYAN}[0]${NC}  ${BOLD}Назад${NC}"
    echo ""
    echo -en "  ${BOLD}Выбор:${NC} "
    local choice
    read -r choice
    
    case "$choice" in
        1)
            echo ""
            echo -e "  ${BLUE}[i]${NC} Выполнение uninstall..."
            if curl -fsSL https://raw.githubusercontent.com/amirotin/telemt_panel/main/install.sh | bash -s uninstall; then
                echo ""
                echo -e "  ${GREEN}${BOLD}[✓]${NC} Панель удалена (конфиг и данные сохранены)"
            else
                echo ""
                echo -e "  ${RED}[✗]${NC} Ошибка удаления"
            fi
            ;;
        2)
            echo ""
            echo -en "  ${BOLD}Вы уверены? Полное удаление необратимо! ${GREEN}${BOLD}Y - да${NC}${BOLD}/${RED}${BOLD}N - назад в меню${NC}${BOLD}:${NC} "
            local confirm
            read -r confirm
            if [[ ! "$confirm" =~ ^[yY]$ ]]; then
                echo -e "  ${GRAY}Удаление отменено${NC}"
                echo ""
                echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню${NC}"
                read -rsn1
                return 1
            fi
            echo ""
            echo -e "  ${BLUE}[i]${NC} Выполнение purge..."
            if curl -fsSL https://raw.githubusercontent.com/amirotin/telemt_panel/main/install.sh | bash -s purge; then
                echo ""
                echo -e "  ${GREEN}${BOLD}[✓]${NC} Панель полностью удалена"
            else
                echo ""
                echo -e "  ${RED}[✗]${NC} Ошибка удаления"
            fi
            ;;
        0)
            return 0
            ;;
        *)
            echo "  Неверный выбор"
            sleep 0.5
            ;;
    esac
    
    echo ""
    echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню${NC}"
    read -rsn1
}

# ── Функция перезапуска панели ──────────────────────────────
restart_panel() {
    echo ""
    echo -e "  ${BLUE}[i]${NC} Перезапуск Telemt Panel..."
    echo ""
    if systemctl restart telemt-panel 2>/dev/null; then
        echo -e "  ${GREEN}${BOLD}[✓]${NC} Панель успешно перезапущена"
    else
        echo -e "  ${YELLOW}[!]${NC} Не удалось перезапустить панель (возможно, она не установлена как служба, либо отсутствует)"
        echo -e "  ${GRAY}Попробуйте сначала установить панель${NC}"
    fi
    echo ""
    echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню${NC}"
    read -rsn1
}

# ── Функция просмотра логов панели ──────────────────────────
view_panel_logs() {
    echo ""
    echo -e "  ${BLUE}[i]${NC} Просмотр логов Telemt Panel (Ctrl+C для выхода)..."
    echo ""
    echo -e "  ${GRAY}Нажмите любую клавишу для продолжения...${NC}"
    read -rsn1
    journalctl -u telemt-panel -f
    echo ""
    echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню${NC}"
    read -rsn1
}

# ── Функция открытия конфига панели ─────────────────────────
edit_panel_config() {
    local config_path="/etc/telemt-panel/config.toml"
    
    if [ ! -f "$config_path" ]; then
        echo ""
        echo -e "  ${YELLOW}[!]${NC}${BOLD} Файл конфига не найден по пути: $config_path"
        echo -e "  ${GRAY}Возможно, панель ещё не установлена${NC}"
        echo ""
        echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню${NC}"
        read -rsn1
        return 1
    fi
    
    echo ""
    echo -e "  ${BLUE}[i]${NC} Открытие конфига: $config_path"
    
    if command -v nano >/dev/null 2>&1; then
        echo -e "  ${GRAY}После редактирования сохраните файл (Ctrl+O) и закройте (Ctrl+X)${NC}"
        echo ""
        echo -e "  ${GRAY}Нажмите любую клавишу для продолжения...${NC}"
        read -rsn1
        nano "$config_path"
    elif command -v vim >/dev/null 2>&1; then
        echo -e "  ${YELLOW}[!]${NC} nano не установлен. Использую vim."
        echo -e "  ${GRAY}Для сохранения: ESC → :wq, для выхода без сохранения: ESC → :q!${NC}"
        echo ""
        echo -e "  ${GRAY}Нажмите любую клавишу для продолжения...${NC}"
        read -rsn1
        vim "$config_path"
    elif command -v vi >/dev/null 2>&1; then
        echo -e "  ${YELLOW}[!]${NC} Использую vi."
        echo -e "  ${GRAY}Для сохранения: ESC → :wq, для выхода без сохранения: ESC → :q!${NC}"
        echo ""
        echo -e "  ${GRAY}Нажмите любую клавишу для продолжения...${NC}"
        read -rsn1
        vi "$config_path"
    else
        echo -e "  ${RED}[✗]${NC} Ни один редактор не найден (nano, vim, vi)"
        echo -e "  ${GRAY}Установите один из редакторов: apt install nano или vim${NC}"
        echo ""
        echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню${NC}"
        read -rsn1
        return 1
    fi
    
    echo ""
    echo -e "  ${GREEN}${BOLD}[✓]${NC} Редактирование завершено"
    echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню${NC}"
    read -rsn1
}

# ── Функция обновления панели ───────────────────────────────
update_panel() {
    echo ""
    echo -e "  ${BLUE}[i]${NC} Обновление Telemt Panel..."
    echo ""
    
    # Проверяем текущую версию
    local current_version=$(get_panel_version)
    if [ -n "$current_version" ]; then
        echo -e "  ${BOLD}Текущая версия:${NC} ${GREEN}${BOLD}${current_version}${NC}"
    fi
    
    echo ""
    echo -e "  ${BLUE}[i]${NC} Запуск обновления через установочный скрипт..."
    echo ""
    
    if curl -fsSL https://raw.githubusercontent.com/amirotin/telemt_panel/main/install.sh | bash; then
        echo ""
        local new_version=$(get_panel_version)
        echo -e "  ${GREEN}${BOLD}[✓]${NC} Панель обновлена!"
        if [ -n "$new_version" ] && [ "$new_version" != "$current_version" ]; then
            echo -e "  ${BOLD}Новая версия:${NC} ${GREEN}${BOLD}${new_version}${NC}"
        fi
    else
        echo ""
        echo -e "  ${RED}[✗]${NC} Ошибка обновления панели"
    fi
    
    echo ""
    echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню${NC}"
    read -rsn1
}

# ── Функция отображения информации о панели ─────────────────
show_panel_info() {
    echo ""
    echo -e "  ${NC}${BOLD}Информация о${CYAN} Telemt Panel:${NC}"
    echo -e "  ${DIM}─────────────────────────────────────────${NC}"
    
    if is_panel_installed; then
        echo -e "  ${BOLD}Панель:${NC} ${GREEN}${BOLD}Установлена${NC}"
        
        local version=$(get_panel_version)
        if [ -n "$version" ]; then
            echo -e "  ${BOLD}Версия:${NC} ${GREEN}${BOLD}${version}${NC}"
        fi
        
        local port=$(get_panel_port)
        if [ -n "$port" ]; then
            echo -e "  ${BOLD}Порт:${NC} ${CYAN}${port}${NC}"
        fi
        
        if systemctl is-active --quiet telemt-panel 2>/dev/null; then
            echo -e "  ${BOLD}Статус:${NC} ${GREEN}${BOLD}Активна${NC}"
        else
            echo -e "  ${BOLD}Статус:${NC} ${RED}остановлена${NC}"
        fi
        
        local config_path="/etc/telemt-panel/config.toml"
        if [ -f "$config_path" ]; then
            echo -e "  ${BOLD}Конфиг:${NC} ${CYAN}${config_path}${NC}"
        fi
        
        local server_ip=$(get_public_ip)
        if [ -n "$port" ] && [ -n "$server_ip" ]; then
            echo ""
            echo -e "  ${BOLD}Панель доступна по адресу:${NC}"
            echo -e "  ${CYAN}http://${server_ip}:${port}${NC}"
        fi
    else
        echo -e "  ${BOLD}Панель:${NC} ${RED}не установлена${NC}"
    fi
    
    echo ""
    echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню${NC}"
    read -rsn1
}

# ── Главное меню ─────────────────────────────────────────────
while true; do
    clear
    echo ""
    echo -e "  ${BOLD}Telemt_Panel меню v0.11${NC}"
    echo -e "  ${DIM}===========================${NC}"
    
    # Показываем информацию о панели, если установлена
    if is_panel_installed; then
        echo ""
        # Сначала выводим URL панели (если есть)
        panel_port=$(get_panel_port)
        server_ip=$(get_public_ip)
        if [ -n "$panel_port" ] && [ -n "$server_ip" ]; then
            echo -e "  ${BOLD}Панель доступна по адресу:${NC}"
            echo -e "  ${CYAN}http://${server_ip}:${panel_port}${NC}"
            echo ""
        fi
        echo -e "  ${NC}${BOLD}Панель:${NC}${GREEN}${BOLD} установлена${NC}"
        version=$(get_panel_version)
        if [ -n "$version" ]; then
            echo -e "  ${NC}${BOLD}Версия:${NC} ${GREEN}${BOLD}${version}${NC}"
        fi
        if [ -n "$panel_port" ]; then
            echo -e "  ${BOLD}Порт:${NC} ${CYAN}${panel_port}${NC}"
        fi
        if systemctl is-active --quiet telemt-panel 2>/dev/null; then
            echo -e "  ${BOLD}Статус:${NC} ${GREEN}${BOLD}активна${NC}"
        else
            echo -e "  ${BOLD}Статус:${NC} ${RED}остановлена${NC}"
        fi
        # Читаем username и session_ttl из конфига
        config_path="/etc/telemt-panel/config.toml"
        if [ -f "$config_path" ]; then
            username=$(grep -E '^username[[:space:]]*=' "$config_path" 2>/dev/null | head -1 | sed -E 's/^username[[:space:]]*=[[:space:]]*"//; s/".*$//')
            session_ttl=$(grep -E '^session_ttl[[:space:]]*=' "$config_path" 2>/dev/null | head -1 | sed -E 's/^session_ttl[[:space:]]*=[[:space:]]*"//; s/".*$//')
            if [ -n "$username" ]; then
                echo -e "  ${BOLD}Username:${NC} ${GREEN}${username}${NC}"
            fi
            if [ -n "$session_ttl" ]; then
                echo -e "  ${BOLD}Session TTL:${NC} ${CYAN}${session_ttl}${NC}"
            fi
            # Выводим путь к конфигу самым последним
            echo -e "  ${BOLD}Конфиг:${NC} ${CYAN}${config_path}${NC}"
        fi
        echo ""
    fi
    
    echo -e "  ${CYAN}[1]${NC}  ${BOLD}Установить/обновить панель${NC}"
    echo -e "  ${CYAN}[2]${NC}  ${BOLD}Удалить панель${NC}"
    echo -e "  ${CYAN}[3]${NC}  ${BOLD}Перезапустить панель${NC}"
    echo -e "  ${CYAN}[4]${NC}  ${BOLD}Посмотреть логи панели${NC}"
    echo -e "  ${CYAN}[5]${NC}  ${BOLD}Открыть конфиг панели${NC}"
    echo -e ""
    echo -e "  ${RED}${BOLD}[0]${NC}  ${BOLD}Назад в прокси меню${NC}"
    echo ""
    
    if ! is_panel_installed; then
        echo -e "  ${YELLOW}Панель не установлена${NC}"
        echo ""
    fi
    
    echo -en "  ${BOLD}Выбор:${NC} "
    read -r choice

    case "$choice" in
        1)
            install_panel
            ;;
        2)
            uninstall_panel
            ;;
        3)
            restart_panel
            ;;
        4)
            view_panel_logs
            ;;
        5)
            edit_panel_config
            ;;
        0)
            exec /opt/mtpr-simple/proxys/proxymenu.sh
            ;;
        *)
            echo "  Неверный выбор"
            sleep 0.1
            ;;
    esac
done
