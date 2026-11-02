#!/bin/bash
# proxymenu.sh

# ── Цвета ─────────────────────────────────────────────────────
RED='\033[0;31m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

pause_or_break() {
    echo -e "  ${GRAY}Нажмите любую клавишу для возврата...${NC}"
    { read -rsn1 </dev/tty; } 2>/dev/null || { echo; return 1; }
    IFS= read -r -t 0.05 _ </dev/tty 2>/dev/null || true
}


while true; do
    clear 2>/dev/null || true
    echo ""
    echo -e "  ${BOLD}Меню движков и панелей Mtproto v0.32${NC}"
    echo -e "  ${DIM}===========================${NC}"
    echo ""
    echo -e "  ${CYAN}[1]${NC}  ${BOLD}Меню Telemt${NC}"
    echo -e "  ${CYAN}[2]${NC}  ${BOLD}Меню панелей для Telemt${NC}"
    echo -e "  ${CYAN}[3]${NC}  ${BOLD}Меню MTProtoZig${NC}"
    echo -e "  ${CYAN}[4]${NC}  ${BOLD}Меню MTG${NC}"
    echo -e ""
    echo -e "  ${RED}[0]${NC}  ${BOLD}Назад в главное меню${NC}"
    echo ""
    echo -en "  ${BOLD}Ввод:${NC} "
    { read -r choice </dev/tty; } 2>/dev/null || { echo; break; }

    case "$choice" in
        1)
            if [ -x "/opt/mtpr-simple/proxys/telemt1.sh" ]; then
                bash /opt/mtpr-simple/proxys/telemt1.sh || true
            else
                echo ""
                echo "  [✗] Файл /opt/mtpr-simple/proxys/telemt1.sh не найден или не исполняем"
                pause_or_break || break
            fi
            ;;
        2)
            # Подменю панели Telemt
            while true; do
                clear 2>/dev/null || true
                echo ""
                echo -e "  ${BOLD}Меню панелей для Telemt${NC}"
                echo -e "  ${DIM}===========================${NC}"
                echo ""
                echo -e "  ${CYAN}[1]${NC}  ${BOLD}Меню telemt_panel${NC}"
                echo ""
                echo -e "  ${RED}[0]${NC}  ${BOLD}Назад в прокси меню${NC}"
                echo ""
                echo -en "  ${BOLD}Ввод:${NC} "
                { read -r sub_choice </dev/tty; } 2>/dev/null || { echo; break; }

                case "$sub_choice" in
                    1)
                        if [ -x "/opt/mtpr-simple/proxys/telemt_panel_amirotin.sh" ]; then
                            bash /opt/mtpr-simple/proxys/telemt_panel_amirotin.sh || true
                        else
                            echo ""
                            echo "  [✗] Файл /opt/mtpr-simple/proxys/telemt_panel_amirotin.sh не найден или не исполняем"
                            pause_or_break || break
                        fi
                        ;;
                    0)
                        break
                        ;;
                    *)
                        echo "  Неверный выбор"
                        sleep 0.1
                        ;;
                esac
            done
            ;;
        3)
            if [ -x "/opt/mtpr-simple/proxys/mtprotozig1.sh" ]; then
                bash /opt/mtpr-simple/proxys/mtprotozig1.sh || true
            else
                echo ""
                echo "  [✗] Файл /opt/mtpr-simple/proxys/mtprotozig1.sh не найден или не исполняем"
                pause_or_break || break
            fi
            ;;
        4)
            if [ -x "/opt/mtpr-simple/proxys/mtgv2_1.sh" ]; then
                bash /opt/mtpr-simple/proxys/mtgv2_1.sh || true
            else
                echo ""
                echo "  [✗] Файл /opt/mtpr-simple/proxys/mtgv2_1.sh не найден или не исполняем"
                pause_or_break || break
            fi
            ;;
        0)
            # Только выходим: main.sh запущен выше как дочерний процесс и сам
            # вернётся в свой цикл. Запуск его здесь копил вложенность (issue #35).
            break
            ;;
        *)
            echo "  Неверный выбор"
            sleep 0.1
            ;;
    esac
done
