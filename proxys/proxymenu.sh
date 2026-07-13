#!/bin/bash
# proxymenu.sh

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

while true; do
    clear
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
    read -r choice

    case "$choice" in
        1)
            if [ -f "/opt/mtpr-simple/proxys/telemt1.sh" ]; then
                exec /opt/mtpr-simple/proxys/telemt1.sh
            else
                echo ""
                echo "  [✗] Файл /opt/mtpr-simple/proxys/telemt1.sh не найден"
                echo -e "  ${GRAY}Нажмите любую клавишу для возврата...${NC}"
                read -rsn1
            fi
            ;;
        2)
            # Подменю панели Telemt
            while true; do
                clear
                echo ""
                echo -e "  ${BOLD}Меню панелей для Telemt${NC}"
                echo -e "  ${DIM}===========================${NC}"
                echo ""
                echo -e "  ${CYAN}[1]${NC}  ${BOLD}Меню telemt_panel${NC}"
                echo ""
                echo -e "  ${RED}[0]${NC}  ${BOLD}Назад в прокси меню${NC}"
                echo ""
                echo -en "  ${BOLD}Ввод:${NC} "
                read -r sub_choice

                case "$sub_choice" in
                    1)
                        if [ -f "/opt/mtpr-simple/proxys/telemt_panel_amirotin.sh" ]; then
                            exec /opt/mtpr-simple/proxys/telemt_panel_amirotin.sh
                        else
                            echo ""
                            echo "  [✗] Файл /opt/mtpr-simple/proxys/telemt_panel_amirotin.sh не найден"
                            echo -e "  ${GRAY}Нажмите любую клавишу для возврата...${NC}"
                            read -rsn1
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
            if [ -f "/opt/mtpr-simple/proxys/mtprotozig1.sh" ]; then
                exec /opt/mtpr-simple/proxys/mtprotozig1.sh
            else
                echo ""
                echo "  [✗] Файл /opt/mtpr-simple/proxys/mtprotozig1.sh не найден"
                echo -e "  ${GRAY}Нажмите любую клавишу для возврата...${NC}"
                read -rsn1
            fi
            ;;
        4)
            if [ -f "/opt/mtpr-simple/proxys/mtgv2_1.sh" ]; then
                exec /opt/mtpr-simple/proxys/mtgv2_1.sh
            else
                echo ""
                echo "  [✗] Файл /opt/mtpr-simple/proxys/mtgv2_1.sh не найден"
                echo -e "  ${GRAY}Нажмите любую клавишу для возврата...${NC}"
                read -rsn1
            fi
            ;;
        0)
            exec /opt/mtpr-simple/main.sh
            ;;
        *)
            echo "  Неверный выбор"
            sleep 0.1
            ;;
    esac
done
