#!/bin/bash
# mtprotozig1.sh

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

# ── Функция проверки, установлен ли MTProtoZig ──────────────
is_mtprotozig_installed() {
    if command -v mtbuddy >/dev/null 2>&1; then
        return 0
    fi
    if systemctl is-active --quiet mtproto-proxy 2>/dev/null; then
        return 0
    fi
    if pgrep -x mtbuddy >/dev/null 2>&1; then
        return 0
    fi
    if [ -f "/opt/mtproto-proxy/config.toml" ]; then
        return 0
    fi
    return 1
}

# ── Функция получения версии MTProtoZig ─────────────────────
get_mtprotozig_version() {
    if command -v mtbuddy >/dev/null 2>&1; then
        sudo mtbuddy --version 2>/dev/null | head -1 | awk '{print $2}'
    else
        echo ""
    fi
}

# ── Функция получения порта из конфига ──────────────────────
get_mtprotozig_port() {
    local config_path="/opt/mtproto-proxy/config.toml"
    if [ -f "$config_path" ]; then
        grep -E '^port[[:space:]]*=' "$config_path" 2>/dev/null | awk -F'=' '{print $2}' | tr -d ' "'
    else
        echo ""
    fi
}

# ── Функция получения онлайна из логов ──────────────────────
get_mtprotozig_online() {
    if is_mtprotozig_installed; then
        sudo journalctl -u mtproto-proxy -n 50 2>/dev/null | grep -o 'users_total=[0-9]*' | tail -1 | cut -d'=' -f2
    else
        echo ""
    fi
}

# ── Функция получения ссылки для подключения ────────────────
get_proxy_link() {
    if command -v mtbuddy >/dev/null 2>&1; then
        sudo mtbuddy links 2>/dev/null | grep -E '^  fakeTLS tg:' | head -1 | awk '{print $3}'
    else
        echo ""
    fi
}

# ── Функция установки Zig CLI ──────────────────────────────
install_zig_cli() {
    echo ""
    echo -e "  ${BLUE}[i]${NC} Установка Zig CLI для MTProtoZig..."
    echo ""
    if curl -fsSL https://raw.githubusercontent.com/sleep3r/mtproto.zig/main/deploy/bootstrap.sh | sudo bash; then
        echo ""
        echo -e "  ${GREEN}[✓]${NC} Zig CLI успешно установлен"
    else
        echo ""
        echo -e "  ${RED}[✗]${NC} Ошибка установки Zig CLI"
    fi
    echo ""
    echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
    read -rsn1
}

# ── Функция установки прокси ────────────────────────────────
install_proxy() {
    echo ""
    echo -e "  ${BLUE}[i]${NC} Установка MTProtoZig прокси..."
    echo ""
    echo -e "  ${BOLD}Хотите установить с параметрами по умолчанию?${NC}"
    echo ""
    echo -e "  Команда:"
    echo -e "  ${CYAN}sudo mtbuddy install --port 443 --domain ozon.ru --middle-proxy --no-tcpmss --no-masking --yes${NC}"
    echo ""
    echo -e "  ${BOLD}Параметры:${NC}"
    echo -e "  • Порт: ${GREEN}443${NC}"
    echo -e "  • TLS домен: ${GREEN}ozon.ru${NC}"
    echo -e "  • MiddleProxy: ${GREEN}включён${NC}"
    echo -e "  • MSS: ${GREEN}отключён${NC}"
    echo ""
    echo -e "  ${DIM}Если хотите установить с кастомными параметрами, просто введите команду с ними${NC}"
    echo -e "  ${DIM}Например: sudo mtbuddy install --port 8443 --domain example.com --middle-proxy --no-tcpmss --yes${NC}"
    echo ""
    echo -en "  ${BOLD}Ввод ${DIM} (Enter/y - установить с параметрами по умолчанию, n - назад, или введите свою команду)${NC}${BOLD}:${NC} "
    read -r choice

    case "$choice" in
        ""|y|Y)
            echo ""
            echo -e "  ${BLUE}[i]${NC} Установка с параметрами по умолчанию..."
            echo ""
            if sudo mtbuddy install --port 443 --domain rutube.ru --middle-proxy --no-tcpmss --yes; then
                echo ""
                echo -e "  ${GREEN}[✓]${NC} Прокси успешно установлен"
            else
                echo ""
                echo -e  "  ${RED}[✗]${NC} Ошибка установки прокси"
            fi
            ;;
        n|N)
            echo ""
            echo -e "  ${GRAY}Возврат в меню...${NC}"
            sleep 0.1
            return 0
            ;;
        *)
            # Пользователь ввёл свою команду, выполняем её
            echo ""
            echo -e "  ${BLUE}[i]${NC} Выполнение: $choice"
            echo ""
            if eval "$choice"; then
                echo ""
                echo -e "  ${GREEN}[✓]${NC} Команда выполнена успешно"
            else
                echo ""
                echo -e "  ${RED}[✗]${NC} Ошибка выполнения команды"
            fi
            ;;
    esac
    echo ""
    echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
    read -rsn1
}

# ── Функция открытия конфига ────────────────────────────────
edit_config() {
    local config_path="/opt/mtproto-proxy/config.toml"
    
    if [ ! -f "$config_path" ]; then
        echo ""
        echo -e "  ${YELLOW}[!]${NC} Файл конфига не найден по пути: $config_path"
        echo -e "  ${GRAY}Возможно, прокси ещё не установлен${NC}"
        echo ""
        echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
        read -rsn1
        return 1
    fi
    
    echo ""
    echo -e "  ${BLUE}[i]${NC} Открытие конфига: $config_path"
    
    # Проверяем, доступен ли редактор
    if command -v nano >/dev/null 2>&1; then
        echo -e "  ${GRAY}После редактирования сохраните файл (Ctrl+O) и закройте (Ctrl+X)${NC}"
        echo ""
        echo -e "  ${GRAY}Нажмите любую клавишу для продолжения...${NC}"
        read -rsn1
        sudo nano "$config_path"
    elif command -v vim >/dev/null 2>&1; then
        echo -e "  ${YELLOW}[!]${NC} nano не установлен. Используем vim для открытия файла."
        echo -e "  ${GRAY}Для сохранения: нажмите ESC, затем введите :wq и Enter${NC}"
        echo -e "  ${GRAY}Для выхода без сохранения: ESC, затем :q! и Enter${NC}"
        echo ""
        echo -e "  ${GRAY}Нажмите любую клавишу для продолжения...${NC}"
        read -rsn1
        sudo vim "$config_path"
    elif command -v vi >/dev/null 2>&1; then
        echo -e "  ${YELLOW}[!]${NC} Использую vi."
        echo -e "  ${GRAY}Для сохранения: нажмите ESC, затем введите :wq и Enter${NC}"
        echo ""
        echo -e "  ${GRAY}Нажмите любую клавишу для продолжения...${NC}"
        read -rsn1
        sudo vi "$config_path"
    else
        echo -e "  ${RED}[✗]${NC} Ни один редактор не найден (nano, vim, vi)"
        echo -e "  ${GRAY}Установите один из редакторов: apt install nano или vim${NC}"
        echo ""
        echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
        read -rsn1
        return 1
    fi
    
    echo ""
    echo -e "  ${GREEN}[✓]${NC} Редактирование завершено"
    echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
    read -rsn1
}

# ── Функция перезапуска прокси ──────────────────────────────
restart_proxy() {
    echo ""
    echo -e "  ${BLUE}[i]${NC} Перезапуск MTProtoZig прокси..."
    echo ""
    if sudo systemctl restart mtproto-proxy 2>/dev/null; then
        echo -e "  ${GREEN}[✓]${NC} Прокси успешно перезапущен"
    else
        echo -e "  ${YELLOW}[!]${NC} Не удалось перезапустить прокси (возможно, он не установлен как служба)"
        echo -e "  ${GRAY}Попробуйте сначала установить прокси (пункт 2)${NC}"
    fi
    echo ""
    echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
    read -rsn1
}

# ── Функция просмотра логов ──────────────────────────────────
view_logs() {
    echo ""
    echo -e "  ${BLUE}[i]${NC} Просмотр логов MTProtoZig (Ctrl+C для выхода)..."
    echo ""
    echo -e "  ${GRAY}Нажмите любую клавишу для продолжения...${NC}"
    read -rsn1
    sudo journalctl -u mtproto-proxy -f
    echo ""
    echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
    read -rsn1
}

# ── Функция удаления прокси ──────────────────────────────────
purge_proxy() {
    echo ""
    echo -e "  ${RED}${BOLD}ВНИМАНИЕ:${NC} Будет выполнено полное удаление MTProtoZig!"
    echo ""
    echo -e "  ${BOLD}Будут удалены:${NC}"
    echo -e "  • Все файлы MTProtoZig"
    echo -e "  • Конфигурационные файлы"
    echo -e "  • Systemd служба"
    echo ""
    echo -e "  ${YELLOW}[!]${NC} Это действие нельзя отменить!"
    echo -en "  ${BOLD}Продолжить удаление? [y/N]:${NC} "
    local confirm
    read -r confirm

    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        echo -e "  ${GRAY}Удаление отменено${NC}"
        echo ""
        echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
        read -rsn1
        return 1
    fi

    echo ""
    echo -e "  ${BLUE}[i]${NC} Удаление MTProtoZig..."
    echo ""
    if sudo mtbuddy uninstall --yes; then
        echo ""
        echo -e "  ${GREEN}[✓]${NC} MTProtoZig успешно удалён"
    else
        echo ""
        echo -e "  ${RED}[✗]${NC} Ошибка удаления MTProtoZig"
    fi
    echo ""
    echo -e "  ${GRAY}Нажмите любую клавишу для возврата в меню...${NC}"
    read -rsn1
}

# ── Главное меню ─────────────────────────────────────────────
while true; do
    clear
    echo ""
    echo -e "  ${BOLD}MTProtoZig меню v0.25${NC}"
    echo -e "  ${DIM}===========================${NC}"
    
    # Проверяем, установлен ли MTProtoZig
    if is_mtprotozig_installed; then
        echo ""
        echo -e "  ${NC}${BOLD}MTProtoZig${GREEN}${BOLD} установлен${NC}"
        
        # Версия
        version=$(get_mtprotozig_version)
        if [ -n "$version" ]; then
            echo -e "  ${NC}${BOLD}Версия:${NC} ${GREEN}${version}${NC}"
        fi
        
        # Порт
        port=$(get_mtprotozig_port)
        if [ -n "$port" ]; then
            echo -e "  ${NC}${BOLD}Порт:${NC} ${CYAN}${port}${NC}"
        fi
        
        # Онлайн
        online=$(get_mtprotozig_online)
        if [ -n "$online" ] && [ "$online" -ge 0 ] 2>/dev/null; then
            echo -e "  ${NC}${BOLD}Подключено к прокси:${NC} ${CYAN}${BOLD}${online}${NC}${BOLD} человек"
        else
            echo -e "  ${NC}${BOLD}Подключено к прокси:${NC} ${CYAN}${BOLD}0${NC}${BOLD} человек"
        fi
        echo ""
    fi
    
    echo -e "  ${CYAN}[1]${NC}  ${BOLD}Установить Zig CLI${NC}"
    echo -e "  ${CYAN}[2]${NC}  ${BOLD}Установить прокси${NC}"
    echo -e "  ${CYAN}[3]${NC}  ${BOLD}Открыть конфиг${NC}"
    echo -e "  ${CYAN}[4]${NC}  ${BOLD}Перезапустить прокси${NC}"
    echo -e "  ${CYAN}[5]${NC}  ${BOLD}Смотреть логи${NC}"
    echo -e "  ${RED}[6]${NC}  ${BOLD}Удалить MTProtoZig${NC}"
    echo -e "  ${CYAN}[0]${NC}  ${BOLD}Назад в прокси меню${NC}"
    echo ""

    # Если MTProtoZig не установлен, показываем это
    if ! is_mtprotozig_installed; then
        echo -e "  ${YELLOW}MTProtoZig не установлен${NC}"
        echo ""
    else
        # Показываем текущий путь к конфигу и ссылку
        echo -e "  ${DIM}Текущий путь к конфигу: /opt/mtproto-proxy/config.toml${NC}"
        proxy_link=$(get_proxy_link)
        if [ -n "$proxy_link" ]; then
            echo -e "  ${DIM}Ссылка для подключения: ${CYAN}${proxy_link}${NC}"
        fi
        echo ""
    fi

    echo -en "  ${BOLD}Выбор:${NC} "
    read -r choice

    case "$choice" in
        1)
            install_zig_cli
            ;;
        2)
            install_proxy
            ;;
        3)
            edit_config
            ;;
        4)
            restart_proxy
            ;;
        5)
            view_logs
            ;;
        6)
            purge_proxy
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
