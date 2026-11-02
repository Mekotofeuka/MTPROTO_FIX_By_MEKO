#!/usr/bin/env bash
# ============================================================
#  data/extra_menu.sh — Дополнительные инструменты MEKO Manager
#  Объединяет: GEOIP-обход, шейпинг, Caddy-PQ, доп. сервисы, бэкап.
#  Самодостаточный интерактивный скрипт (запускается из main.sh [8]).
# ============================================================
set -euo pipefail

INSTALL_DIR="/opt/mtpr-simple"
EXTRA_BASE_URL="https://raw.githubusercontent.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/main"

# ── Цвета ───────────────────────────────────────────────────
if [ -t 1 ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    BLUE='\033[0;34m'; CYAN='\033[0;36m'
    BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''
    BOLD=''; DIM=''; NC=''
fi

# ── Логи ────────────────────────────────────────────────────
log_info()    { echo -e "  ${BLUE}[i]${NC} $1"; }
log_success() { echo -e "  ${GREEN}[✓]${NC} $1"; }
log_error()   { echo -e "  ${RED}[✗]${NC} $1" >&2; }
log_warning() { echo -e "  ${YELLOW}[!]${NC} $1"; }

# ── Догрузка дочернего скрипта (аналог ensure_data_script из main.sh) ──
_ensure_child() {
    local rel="$1"
    local dest="${INSTALL_DIR}/${rel}"
    if [ -s "$dest" ]; then
        return 0
    fi
    log_warning "Файл $dest не найден, скачиваю с GitHub..."
    mkdir -p "$(dirname "$dest")"
    if curl -fsSL --max-time 20 "${EXTRA_BASE_URL}/${rel}" -o "$dest"; then
        if [ -s "$dest" ]; then
            chmod +x "$dest" 2>/dev/null || true
            return 0
        fi
        rm -f "$dest" 2>/dev/null || true
        log_error "Скачанный файл $rel пуст или повреждён"
        return 1
    fi
    rm -f "$dest" 2>/dev/null || true
    log_error "Не удалось скачать $rel"
    return 1
}

# ── Запуск дочернего меню в дочернем bash (аналог run_menu_script) ──
_run_child() {
    local rel="$1"; shift
    local dest="${INSTALL_DIR}/${rel}"
    if ! _ensure_child "$rel"; then
        return 1
    fi
    if { : </dev/tty; } 2>/dev/null; then
        bash "$dest" "$@" </dev/tty || true
    else
        log_warning "Нет доступа к /dev/tty — запуск без интерактивного ввода"
        bash "$dest" "$@" || true
    fi
    return 0
}

# ── Меню ────────────────────────────────────────────────────
show_extra_menu() {
    while true; do
        if [ -t 1 ]; then clear 2>/dev/null || printf '\033[2J\033[H'; fi
        echo ""
        echo -e "  ${CYAN}${BOLD}══════════ Дополнительно ══════════${NC}"
        echo ""
        echo -e "  ${CYAN}[1]${NC}  ${BOLD}GEOIP-обход SYN-лимита${NC}"
        echo -e "  ${CYAN}[2]${NC}  ${BOLD}Ограничение скорости${NC} ${DIM}(шейпинг по IPv4)${NC}"
        echo -e "  ${CYAN}[3]${NC}  ${BOLD}Caddy как PQ-заглушка${NC} ${DIM}(SelfSteal)${NC}"
        echo -e "  ${CYAN}[4]${NC}  ${BOLD}Дополнительные сервисы${NC} ${DIM}(WARP, AdGuard Home)${NC}"
        echo -e "  ${CYAN}[5]${NC}  ${BOLD}Бэкап и восстановление панели${NC} ${DIM}(всё: Telemt + правила)${NC}"
        echo -e "  ${CYAN}[6]${NC}  ${BOLD}Безопасность${NC} ${DIM}(TLS-отпечатки, блокировка IP/подсетей)${NC}"
        echo ""
        echo -e "  ${CYAN}[0]${NC}  ${BOLD}Назад в главное меню${NC}"
        echo ""
        echo -en "  ${BOLD}Выбор:${NC} "
        local choice
        { read -r choice </dev/tty; } 2>/dev/null || { echo; return 0; }

        case "$choice" in
            1)
                echo ""
                _run_child "data/rules.sh" -geoip || true
                ;;
            2)
                echo ""
                _run_child "data/shaping.sh" || true
                ;;
            3)
                echo ""
                _run_child "proxys/caddy_pq.sh" || true
                ;;
            4)
                echo ""
                _run_child "data/services_menu.sh" || true
                ;;
            5)
                echo ""
                _run_child "data/backup_panel.sh" --scope all || true
                ;;
            6)
                echo ""
                _run_child "data/security.sh" || true
                ;;
            0 | "")
                return 0
                ;;
            *)
                log_error "Неверный выбор"
                sleep 0.2
                ;;
        esac
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    show_extra_menu
fi
