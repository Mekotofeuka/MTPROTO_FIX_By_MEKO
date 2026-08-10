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
        echo -e "       ${DIM}Меню установки MTProxyl by Liafanx ${NC}"
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
