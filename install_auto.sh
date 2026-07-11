# ── Меню выбора правил SYN FIX ──────────────────────────────
echo ""
echo -e "  ${BOLD}${CYAN}🔧 УСТАНОВКА SYN FIX${NC}"
echo -e "  ${BOLD}${DIM}═════════════════════════════════════════════════${NC}"
echo ""

echo -e "  ${BOLD}Выберите тип SYN FIX:${NC}"
echo -e "  ${GREEN}[1]${NC}  ${BOLD}Новый вариант(iptables)${NC} (Разделение устройств с помощью u32 по байтам из пакета) — ${GREEN}рекомендуется${NC}"
echo -e "${NC}  Если совпало -> это ios и принимаем пакеты без лимита"
echo -e "${NC}  Если не совпало -> это другое ус-во и ставим SYN 1/s"
echo -e "  ${CYAN}[2]${NC}  ${BOLD}Старый вариант(iptables)${NC} (Разделение устройств определяя их TTL+Length)"
echo -e "${NC}  Если TTL <65 и length 64 -> это ios и принимаем пакеты без лимита"
echo -e "${NC}  Иначе -> это другое ус-во и ставим SYN 1/s"
echo ""
echo -e "  ${YELLOW}[3]${NC}  ${BOLD}Новый вариант(nftables)${GREEN}${BOLD} - рекомендуется (совместим с Docker)${NC}"
echo -e "${NC}  Если совпало -> это ios и принимаем пакеты без лимита"
echo -e "${NC}  Если не совпало -> это другое ус-во и ставим SYN 1/s"
echo -e "  ${YELLOW}[4]${NC}  ${BOLD}Старый вариант(nftables)${NC}${BOLD} ${NC}${BOLD} - (совместим с Docker)${NC}"
echo -e "${NC}  Если TTL <65 и length 64 -> это ios и принимаем пакеты без лимита"
echo -e "${NC}  Иначе -> это другое ус-во и ставим SYN 1/s"
echo ""
echo -e "  ${YELLOW}[0]${NC}  ${BOLD}Пропустить установку SYN FIX${NC}"
echo ""
echo -en "  ${NC}${BOLD}Ввод (По умолчанию${GREEN}${BOLD} - 1 (Enter)${NC}${BOLD}):${NC} "

fix_choice=$(read_input)
# Если пустой ввод — ставим 1
[ -z "$fix_choice" ] && fix_choice="1"

case "$fix_choice" in
    0)
        log_info "Установка SYN FIX пропущена"
        ;;
    1|2|3|4)
        echo ""
        log_info "Запуск установки SYN FIX..."
        # Пропускаем ввод портов через отдельный вызов, чтобы не было конфликта буфера
        # Устанавливаем порты вручную с отдельным read
        echo ""
        echo -en "  ${BOLD}Введите порты для SYN FIX (через запятую, например: 443,8443,8080):${NC} "
        ports_input=$(read_input)
        if [ -z "$ports_input" ]; then
            ports_input="443"
        fi
        # Передаём порты в install_syn_fix через переменную окружения
        export FORCED_PORTS="$ports_input"
        install_syn_fix
        unset FORCED_PORTS
        ;;
    *)
        log_warning "Неверный выбор, пропускаем установку SYN FIX"
        ;;
esac

sleep 0.4
clear
