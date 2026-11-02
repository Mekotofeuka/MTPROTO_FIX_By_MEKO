#!/bin/bash
# data/backup_panel.sh — Бэкап и восстановление панели MEKO Manager
# Для переноса установки на другой сервер (scp архива + восстановление).
#
# Запуск: bash /opt/mtpr-simple/data/backup_panel.sh
#         (обычно вызывается из main.sh: [8] Дополнительно → [5] Бэкап и восстановление панели)
# CLI:
#   --scope all|telemt|fix                 область бэкапа/восстановления
#   --restore-file <архив> [--yes]         восстановить конкретный архив без интерактива
#   --migrate-to <host>                    перенести архив на другой сервер (scp)
#   --migrate-port N --migrate-user U --migrate-dir D
#   --archive <файл>                       что переносить (иначе спросит/создаст)
#   --deploy [--yes]                       после передачи развернуть архив на новом сервере
#                                          (без --deploy развёртывание не запускается даже с --yes)
# Пароль SSH для переноса можно отдать через переменную окружения SSHPASS (не через аргументы).
set -euo pipefail

INSTALL_DIR="/opt/mtpr-simple"
BACKUP_DIR="/root/mtpr-backups"
CONFIG_PATH_FILE="/opt/mtpr-simple/config_path"
MTG_CONFIG_PATH_FILE="/opt/mtpr-simple/mtg_config_path"

# ── Цвета ─────────────────────────────────────────────────────
# Включаем ANSI-цвета только при выводе в терминал; при пайпе/редиректе — пусто,
# чтобы escape-последовательности не текли в логи и захваченный вывод.
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    GRAY='\033[0;90m'
    BOLD='\033[1m'
    DIM='\033[2m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    CYAN=''
    GRAY=''
    BOLD=''
    DIM=''
    NC=''
fi

# ── Логирование ──────────────────────────────────────────────
log_info() { echo -e "  ${BLUE}[i]${NC} $1"; }
log_success() { echo -e "  ${GREEN}[✓]${NC} $1"; }
log_error() { echo -e "  ${RED}[✗]${NC} $1" >&2; }
log_warning() { echo -e "  ${YELLOW}[!]${NC} $1"; }

# ── Проверка root ────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
    log_error "Требуются права root"
    exit 1
fi

# ── Область бэкапа (scope) ───────────────────────────────────
# all     — полный бэкап (панель + правила + telemt), поведение по умолчанию
# telemt  — только /etc/telemt и юнит telemt.service
# fix     — только панель и правила (без /etc/telemt)
SCOPE="all"

# ── Параметры CLI: перенос на другой сервер / неинтерактивный restore ──
RESTORE_FILE=""        # --restore-file: восстановить конкретный архив без вопроса о пути
MIGRATE_HOST=""        # --migrate-to: задан → запускаем перенос, а не меню
MIGRATE_PORT="22"
MIGRATE_USER="root"
MIGRATE_DIR="/root"
MIGRATE_ARCHIVE=""     # --archive: что переносить (иначе спросит/создаст свежий)
MIGRATE_DEPLOY=0       # --deploy: после передачи развернуть на новом сервере
ASSUME_YES=0           # --yes: не задавать подтверждающих вопросов
MEKO_INSTALL_URL="https://raw.githubusercontent.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/main/install.sh"

usage() {
    echo "Использование: bash $0 [--scope all|telemt|fix]"
    echo "  all     — полный бэкап (по умолчанию)"
    echo "  telemt  — только конфиги telemt (/etc/telemt + юнит telemt.service)"
    echo "  fix     — только панель и правила (/opt/mtpr-simple, юниты mtpr-*, cron)"
    echo ""
    echo "Перенос на другой сервер:"
    echo "  --migrate-to <host>          IP или домен нового сервера"
    echo "  --migrate-port <N>           SSH-порт (по умолчанию 22)"
    echo "  --migrate-user <U>           SSH-пользователь (по умолчанию root)"
    echo "  --migrate-dir <path>         каталог для архива на новом сервере (по умолчанию /root)"
    echo "  --archive <file>             какой архив переносить (иначе создать/спросить)"
    echo "  --deploy                     после передачи развернуть архив на новом сервере"
    echo "  --restore-file <file>        восстановить указанный архив без интерактива"
    echo "  --yes                        не спрашивать подтверждения (для скриптов; сам архив не разворачивает)"
    echo ""
    echo "  Доступ: по SSH-ключу, либо пароль через переменную SSHPASS (или интерактивный ввод)."
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --scope)
            if [ "$#" -ge 2 ]; then
                SCOPE="$2"
                shift 2
            else
                echo "Опция --scope требует значения (all|telemt|fix)" >&2
                usage >&2
                exit 2
            fi
            ;;
        --scope=*)
            SCOPE="${1#--scope=}"
            shift
            ;;
        --restore-file)
            if [ "$#" -ge 2 ]; then
                RESTORE_FILE="$2"
                shift 2
            else
                echo "Опция --restore-file требует значения (путь к архиву)" >&2
                usage >&2
                exit 2
            fi
            ;;
        --restore-file=*)
            RESTORE_FILE="${1#--restore-file=}"
            shift
            ;;
        --migrate-to)
            if [ "$#" -ge 2 ]; then
                MIGRATE_HOST="$2"
                shift 2
            else
                echo "Опция --migrate-to требует значения (IP/домен)" >&2
                usage >&2
                exit 2
            fi
            ;;
        --migrate-to=*)
            MIGRATE_HOST="${1#--migrate-to=}"
            shift
            ;;
        --migrate-port | --migrate-user | --migrate-dir | --archive)
            if [ "$#" -lt 2 ]; then
                echo "Опция $1 требует значения" >&2
                usage >&2
                exit 2
            fi
            case "$1" in
                --migrate-port) MIGRATE_PORT="$2" ;;
                --migrate-user) MIGRATE_USER="$2" ;;
                --migrate-dir) MIGRATE_DIR="$2" ;;
                --archive) MIGRATE_ARCHIVE="$2" ;;
            esac
            shift 2
            ;;
        --migrate-port=* | --migrate-user=* | --migrate-dir=* | --archive=*)
            case "$1" in
                --migrate-port=*) MIGRATE_PORT="${1#--migrate-port=}" ;;
                --migrate-user=*) MIGRATE_USER="${1#--migrate-user=}" ;;
                --migrate-dir=*) MIGRATE_DIR="${1#--migrate-dir=}" ;;
                --archive=*) MIGRATE_ARCHIVE="${1#--archive=}" ;;
            esac
            shift
            ;;
        --deploy)
            MIGRATE_DEPLOY=1
            shift
            ;;
        --yes | -y)
            ASSUME_YES=1
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            echo "Неизвестный аргумент: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done
case "$SCOPE" in
    all | telemt | fix) ;;
    *)
        echo "Неверный --scope '${SCOPE}' (ожидается all|telemt|fix)" >&2
        usage >&2
        exit 2
        ;;
esac

_scope_suffix() {
    case "$1" in
        telemt) echo "-telemt-" ;;
        fix) echo "-fix-" ;;
        *) echo "-full-" ;;
    esac
}

_scope_summary() {
    # Что будет затронуто при восстановлении архива данной области
    case "$1" in
        telemt) echo "каталог /etc/telemt/ и юнит systemd telemt.service" ;;
        fix)    echo "каталог /opt/mtpr-simple/ (кроме backups/logs/tmp), скрипты синфикса, cron xt_geoip/mtpr*, юниты mtpr-*.service" ;;
        *)      echo "каталог /etc/telemt/, /opt/mtpr-simple/, скрипты синфикса, cron, юниты mtpr-*.service и telemt.service, mtg/mtprotozig, etc/x-ui" ;;
    esac
}

# ── Вспомогательные ──────────────────────────────────────────
_pause() {
    echo ""
    echo -e "  ${GRAY}Нажмите любую клавишу для продолжения...${NC}"
    { read -rsn1 </dev/tty; } 2>/dev/null || { echo; return 1; }
    IFS= read -r -t 0.05 _ </dev/tty 2>/dev/null || true
}

_svc_exists() {
    local _svc="$1" _out=""
    # Без пайпа на `grep -q`: под `set -euo pipefail` ранний выход grep даёт
    # SIGPIPE апстриму и rc=141, из-за чего установленный сервис считался
    # отсутствующим. awk читает поток до конца — SIGPIPE невозможен.
    # rc самого systemctl НЕ наследуем: при сломанном DBus/`systemctl` (rc≠0)
    # вывод всё равно надо разобрать, а не считать сервис отсутствующим.
    _out="$(systemctl list-unit-files --type=service 2>/dev/null || true)"
    printf '%s\n' "$_out" | awk -v s="${_svc}.service" '$1==s{f=1} END{exit !f}'
}

# ── Разбор списка файлов архива (для restore) ────────────────
# Заполняется в restore_backup; хелперы ниже сверяют пути по нему.
RESTORE_MEMBERS=()

# Литеральная (без regex) проверка: есть ли в архиве путь _pre или что-то под ним.
_member_matches_prefix() {
    local _pre="$1" _m
    for _m in "${RESTORE_MEMBERS[@]}"; do
        case "$_m" in
            "$_pre" | "$_pre"/*) return 0 ;;
        esac
    done
    return 1
}

# Базовые имена сервисов, юниты которых реально присутствуют в архиве.
# Путь берётся из списка членов как есть, в regex не подставляется.
_services_from_members() {
    local _m _base _seen=" "
    for _m in "${RESTORE_MEMBERS[@]}"; do
        case "$_m" in
            etc/systemd/system/*.service) ;;
            *) continue ;;
        esac
        _base="${_m#etc/systemd/system/}"
        case "$_base" in */*) continue ;; esac # только плоские юниты верхнего уровня
        _base="${_base%.service}"
        [ -n "$_base" ] || continue
        case "$_seen" in *" ${_base} "*) continue ;; esac
        _seen="${_seen}${_base} "
        printf '%s\n' "$_base"
    done
}

# ── Формирование списка источников бэкапа ────────────────────
BACKUP_PATHS=()

_backup_add() {
    local _p="${1#/}"
    [ -e "/${_p}" ] || return 0
    local _e
    local -a _keep=()
    if [ "${#BACKUP_PATHS[@]}" -gt 0 ]; then
        for _e in "${BACKUP_PATHS[@]}"; do
            # Точное совпадение или новый путь уже покрыт более широкой записью —
            # добавлять нечего, выходим, ничего не меняя.
            if [ "$_e" = "$_p" ] || [[ "$_p" == "$_e/"* ]]; then
                return 0
            fi
            # Существующая запись — потомок новой: новая шире и покрывает её,
            # поэтому заменяем старую, а не молча отбрасываем новую.
            if [[ "$_e" == "$_p/"* ]]; then
                log_info "Путь /${_e} включён в более широкий /${_p} — заменяю запись"
                continue
            fi
            _keep+=("$_e")
        done
        BACKUP_PATHS=("${_keep[@]}")
    fi
    BACKUP_PATHS+=("$_p")
}

# Добавить конфиг, путь к которому записан в файле-указателе
_backup_add_from_pathfile() {
    local _pf="$1" _val=""
    [ -s "$_pf" ] || return 0
    _val="$(head -1 "$_pf" 2>/dev/null | tr -d '\r\n' || true)"
    [ -n "$_val" ] || return 0
    [ "$_val" = "skip" ] && return 0
    _backup_add "$_val"
}

build_backup_source_list() {
    BACKUP_PATHS=()
    local _u

    # ── telemt (scope telemt и all) ──
    if [ "$SCOPE" = "all" ] || [ "$SCOPE" = "telemt" ]; then
        _backup_add "etc/telemt"
        _backup_add "etc/systemd/system/telemt.service"
    fi

    # ── fix: панель и правила (scope fix и all) ──
    if [ "$SCOPE" = "all" ] || [ "$SCOPE" = "fix" ]; then
        # Данные панели (backups/logs/tmp исключаются на этапе tar)
        _backup_add "$INSTALL_DIR"
        # Скрипты правил (на случай, если лежат вне каталога панели)
        _backup_add "${INSTALL_DIR}/apply-mtpr-synfix.sh"
        _backup_add "${INSTALL_DIR}/mtpr-synfix-nft.sh"
        # Юниты systemd
        for _u in /etc/systemd/system/mtpr-*.service; do
            [ -e "$_u" ] && _backup_add "${_u#/}"
        done
        # Cron (geoip-обновление и прочие mtpr-задачи)
        _backup_add "etc/cron.daily/xt_geoip"
        _backup_add "etc/cron.d/xt_geoip"
        for _u in /etc/cron.d/mtpr* /etc/cron.daily/mtpr*; do
            [ -e "$_u" ] && _backup_add "${_u#/}"
        done
        # Указатели панели на внешние конфиги (не telemt)
        _backup_add_from_pathfile "$MTG_CONFIG_PATH_FILE"
    fi

    # ── MTG / MTProtoZig и прочее — только в полном бэкапе ──
    if [ "$SCOPE" = "all" ]; then
        _backup_add "etc/mtg.toml"
        _backup_add "etc/mtg"
        _backup_add "etc/mtprotozig"
        _backup_add "root/.mtg.toml"
        _backup_add "root/.mtprotozig"
        # Конфиг, путь к которому сохранён панелью (может быть и вне /etc/telemt)
        _backup_add_from_pathfile "$CONFIG_PATH_FILE"
        # Панель 3x-ui (опционально)
        _backup_add "etc/x-ui"
    fi
}

# ── (1) Создание бэкапа ──────────────────────────────────────
create_backup() {
    echo ""
    log_info "Формирую список данных для бэкапа (scope: ${SCOPE})..."
    build_backup_source_list

    if [ "${#BACKUP_PATHS[@]}" -eq 0 ]; then
        log_error "Не найдено ни одного каталога/файла для бэкапа"
        return 1
    fi

    echo -e "  ${GRAY}Источники:${NC}"
    local _p
    for _p in "${BACKUP_PATHS[@]}"; do
        echo -e "    ${DIM}/${_p}${NC}"
    done
    echo ""

    if ! mkdir -p "$BACKUP_DIR"; then
        log_error "Не удалось создать каталог $BACKUP_DIR"
        return 1
    fi

    local _host _ts _archive
    _host="$(hostname -s 2>/dev/null || echo server)"
    _ts="$(date +%Y%m%d-%H%M%S)"
    _archive="${BACKUP_DIR}/backup-${_host}$(_scope_suffix "$SCOPE")${_ts}.tar.gz"

    log_info "Создаю архив (это может занять время)..."
    if ! tar -czf "$_archive" -C / \
        --exclude='opt/mtpr-simple/backups' \
        --exclude='opt/mtpr-simple/logs' \
        --exclude='opt/mtpr-simple/tmp' \
        --exclude='opt/mtpr-simple/__pycache__' \
        --exclude='opt/mtpr-simple/*.log' \
        --exclude='opt/mtpr-simple/*.tar.gz' \
        --exclude='etc/telemt/*.log' \
        "${BACKUP_PATHS[@]}" 2>"/tmp/mtpr-backup-err.$$"; then
        log_error "Ошибка создания архива:"
        sed 's/^/    /' "/tmp/mtpr-backup-err.$$" >&2 || true
        rm -f "$_archive" "/tmp/mtpr-backup-err.$$"
        return 1
    fi
    rm -f "/tmp/mtpr-backup-err.$$"

    local _size
    _size="$(du -h "$_archive" 2>/dev/null | awk '{print $1}' || echo '?')"

    if ! {
        echo "host=${_host}"
        echo "date=$(date -Is 2>/dev/null || date)"
        echo "scope=${SCOPE}"
        echo "sources=${BACKUP_PATHS[*]}"
    } > "${_archive}.info" 2>/dev/null; then
        log_warning "Не удалось записать ${_archive}.info — при восстановлении/переносе область (scope) определится как неизвестная"
    fi

    log_success "Бэкап создан: ${_archive} (${_size})"
    echo -e "  ${GRAY}Информация о бэкапе: ${_archive}.info${NC}"
    return 0
}

# ── (2) Восстановление ───────────────────────────────────────
restore_backup() {
    echo ""
    local _archive=""
    if [ -n "$RESTORE_FILE" ]; then
        _archive="$RESTORE_FILE"
        log_info "Архив (--restore-file): ${_archive}"
    else
        echo -en "  ${BOLD}Путь к архиву (.tar.gz):${NC} "
        { read -r _archive </dev/tty; } 2>/dev/null || { echo; return 1; }
        _archive="${_archive%\"}"; _archive="${_archive#\"}"
        _archive="${_archive%\'}"; _archive="${_archive#\'}"
    fi

    if [ -z "$_archive" ]; then
        log_error "Путь не указан"
        return 1
    fi
    if [ ! -f "$_archive" ]; then
        log_error "Файл не найден: $_archive"
        return 1
    fi
    if ! tar -tzf "$_archive" >/dev/null 2>&1; then
        log_error "Архив повреждён или не является tar.gz"
        return 1
    fi

    # ── Область архива (scope) ───────────────────────────────
    local _info="${_archive}.info"
    local _arc_scope="" _scope_known=0
    if [ -s "$_info" ]; then
        local _s=""
        _s="$(grep -m1 '^scope=' "$_info" 2>/dev/null | cut -d= -f2- || true)"
        case "$_s" in
            all | telemt | fix)
                _arc_scope="$_s"
                _scope_known=1
                ;;
        esac
    fi
    local _rscope="$_arc_scope"
    [ -n "$_rscope" ] || _rscope="unknown"
    if [ "$_scope_known" -eq 1 ]; then
        log_info "Область архива (scope): ${_rscope}"
    else
        log_warning "В архиве нет валидного scope= (sidecar .info отсутствует или повреждён) — определить область невозможно."
    fi

    # ── Разбор архива и сверка с sidecar .info ───────────────
    RESTORE_MEMBERS=()
    local _m
    while IFS= read -r _m; do
        [ -n "$_m" ] || continue
        RESTORE_MEMBERS+=("$_m")
    done < <(tar -tzf "$_archive" 2>/dev/null)

    if [ "${#RESTORE_MEMBERS[@]}" -eq 0 ]; then
        log_error "Архив пуст — восстановление отменено"
        return 1
    fi

    # Сервисы берём из фактических юнитов архива, а не из жёсткого перечисления:
    # глобом etc/systemd/system/mtpr-*.service в архив fix/all попадает ЛЮБОЙ mtpr-юнит
    # (например mtpr-zapret2.service), и после restore его тоже надо поднять.
    local _restore_services="" _svc_list_msg=""
    _restore_services="$(_services_from_members)"
    _svc_list_msg="$_restore_services"
    [ -n "$_svc_list_msg" ] || _svc_list_msg="(systemd-юнитов в архиве нет)"

    echo ""
    echo -e "  ${GRAY}Содержимое (первые 20 записей):${NC}"
    tar -tzf "$_archive" 2>/dev/null | head -20 | sed 's/^/    /' || true
    echo ""
    log_warning "Восстановление ПЕРЕЗАПИШЕТ текущие файлы панели и конфиги данными из архива."

    if [ -s "$_info" ]; then
        local _srcs="" _need=""
        _srcs="$(grep -m1 '^sources=' "$_info" 2>/dev/null | cut -d= -f2- || true)"
        [ -n "$_srcs" ] && echo -e "  ${GRAY}Сверка с .info (sources): ${_srcs}${NC}"
        for _need in $_srcs; do
            _need="${_need#/}"; _need="${_need%/}"
            [ -n "$_need" ] || continue
            # Сверка литеральная (case, без grep -E): метасимволы в пути безопасны.
            if ! _member_matches_prefix "$_need"; then
                log_warning "В .info указан '${_need}', но в архиве его нет"
            fi
        done
    else
        log_warning "Sidecar .info не найден — сверка набора путей пропущена"
    fi

    if [ "$_scope_known" -eq 0 ]; then
        # Область неизвестна — якорную проверку делать не по чему.
        log_warning "Область архива не определена: восстанавливаю по фактическому содержимому архива."
        log_warning "Будут распакованы ВСЕ ${#RESTORE_MEMBERS[@]} путей архива; сервисы для перезапуска:"
        echo -e "      ${GRAY}${_svc_list_msg}${NC}"
    else
        # Мягкий режим: при расхождении области запроса и архива НЕ отказываем —
        # восстанавливаем по области АРХИВА, но предупреждаем перед подтверждением.
        if [ "$SCOPE" != "$_rscope" ]; then
            log_warning "Архив области '${_rscope}', запрошено '${SCOPE}'."
            log_warning "Восстановление будет по области АРХИВА ('${_rscope}'); будут затронуты:"
            echo -e "      ${GRAY}$(_scope_summary "$_rscope")${NC}"
            echo -e "      ${GRAY}сервисы: ${_svc_list_msg}${NC}"
        fi
        # Обязательные записи: без них это не бэкап нужной области.
        # Проверяем ДО подтверждения, чтобы не спрашивать про заведомо чужой архив.
        local _mand_ok=0 _mand_list=""
        case "$_rscope" in
            telemt) _mand_list="etc/telemt" ;;
            fix) _mand_list="opt/mtpr-simple" ;;
            *) _mand_list="opt/mtpr-simple etc/telemt" ;;
        esac
        for _m in $_mand_list; do
            if _member_matches_prefix "$_m"; then
                _mand_ok=1
                break
            fi
        done
        if [ "$_mand_ok" -eq 0 ]; then
            log_error "В архиве нет обязательных записей для scope '${_rscope}' (${_mand_list}) — это не бэкап этой области. Отменено."
            return 1
        fi
    fi

    if [ "$ASSUME_YES" -ne 1 ]; then
        echo -en "  ${BOLD}Продолжить? [y/N]:${NC} "
        local _c=""
        { read -r _c </dev/tty; } 2>/dev/null || { echo; return 1; }
        if [[ ! "$_c" =~ ^[yY]$ ]]; then
            log_info "Восстановление отменено"
            return 1
        fi
    else
        log_info "Подтверждение пропущено (--yes)"
    fi

    # ── Снапшот перезаписываемых путей (для отката при сбое) ──
    local -a _exist=()
    for _m in "${RESTORE_MEMBERS[@]}"; do
        [ -n "$_m" ] || continue
        if [ -e "/$_m" ] || [ -L "/$_m" ]; then
            _exist+=("$_m")
        fi
    done

    local _ts _snap _snap_ok=0 _list=""
    _ts="$(date +%Y%m%d-%H%M%S)"
    _snap="${BACKUP_DIR}/pre-restore-${_ts}.tar.gz"
    mkdir -p "$BACKUP_DIR" 2>/dev/null || true
    _list="$(mktemp 2>/dev/null || true)"

    if [ "${#_exist[@]}" -eq 0 ]; then
        log_info "Существующих путей из архива нет — снапшот не требуется"
        _snap_ok=1
    elif [ -z "$_list" ]; then
        log_warning "Не удалось создать временный файл для снапшота"
    else
        printf '%s\n' "${_exist[@]}" > "$_list"
        log_info "Создаю снапшот перезаписываемых путей (${#_exist[@]})..."
        if tar -czf "$_snap" -C / -T "$_list" 2>/dev/null; then
            _snap_ok=1
            log_success "Снапшот: ${_snap}"
        else
            rm -f "$_snap" 2>/dev/null || true
            log_warning "Не удалось создать снапшот"
        fi
    fi
    if [ -n "$_list" ]; then rm -f "$_list" 2>/dev/null || true; fi

    if [ "$_snap_ok" -ne 1 ]; then
        if [ "$ASSUME_YES" -eq 1 ]; then
            log_warning "Снапшот не создан: откат недоступен, продолжаю из-за --yes"
        else
            echo -en "  ${BOLD}Продолжить без возможности отката? [y/N]:${NC} "
            local _c2=""
            { read -r _c2 </dev/tty; } 2>/dev/null || { echo; return 1; }
            if [[ ! "$_c2" =~ ^[yY]$ ]]; then
                log_info "Восстановление отменено"
                return 1
            fi
        fi
    fi

    echo ""
    log_info "Распаковываю архив в / ..."
    if ! tar -xzf "$_archive" -C /; then
        log_error "Ошибка распаковки архива (повреждён или прерван?)"
        if [ "$_snap_ok" -eq 1 ] && [ -s "$_snap" ]; then
            log_warning "Откатываю перезаписанные пути из снапшота..."
            if tar -xzf "$_snap" -C / 2>/dev/null; then
                log_success "Откат выполнен. Проверьте сервисы вручную."
            else
                log_error "Откат не удался. Ручной откат: tar -xzf ${_snap} -C /"
            fi
        else
            log_error "Снапшота нет — автоматический откат невозможен"
        fi
        return 1
    fi
    log_success "Файлы распакованы"
    if [ "$_snap_ok" -eq 1 ] && [ -s "$_snap" ]; then
        echo -e "  ${GRAY}Снапшот до восстановления: ${_snap}${NC}"
    fi

    log_info "systemctl daemon-reload..."
    systemctl daemon-reload >/dev/null 2>&1 || log_warning "daemon-reload завершился с ошибкой"

    local _svc _total=0 _enabled_ok=0 _active_ok=0 _restart_ok=0
    local _bad_n=0 _skip_n=0
    local _ok_names="" _bad_names="" _skip_names=""
    for _svc in $_restore_services; do
        if ! _svc_exists "$_svc"; then
            log_info "${_svc}.service не установлен — пропущен"
            _skip_n=$((_skip_n + 1))
            _skip_names="${_skip_names} ${_svc}"
            continue
        fi
        _total=$((_total + 1))
        if systemctl enable "$_svc" >/dev/null 2>&1; then
            _enabled_ok=$((_enabled_ok + 1))
        else
            log_warning "Не удалось включить автозапуск: ${_svc}"
        fi
        if systemctl restart "$_svc" >/dev/null 2>&1; then
            _restart_ok=$((_restart_ok + 1))
        fi
        sleep 1
        local _st _sub _failed _full _why _l
        _st="$(systemctl is-active "$_svc" 2>/dev/null || true)"
        if [ "$_st" = "active" ]; then
            _active_ok=$((_active_ok + 1))
            _ok_names="${_ok_names} ${_svc}"
            echo -e "    ${GREEN}${_svc}: ${_st}${NC}"
        else
            _bad_n=$((_bad_n + 1))
            _bad_names="${_bad_names} ${_svc}"
            _sub="$(systemctl show "$_svc" -p SubState --value 2>/dev/null || true)"
            _failed="$(systemctl is-failed "$_svc" 2>/dev/null || true)"
            echo -e "    ${RED}${_svc}: ${_st:-unknown}${_sub:+ (${_sub})}${NC}"
            # Печатаем is-failed только для реальных failed/inactive:
            # при activating (auto-restart) строка 'is-failed: activating' вводит в заблуждение.
            if [ "$_failed" = "failed" ] || [ "$_failed" = "inactive" ]; then
                echo -e "      ${GRAY}is-failed: ${_failed}${NC}"
            fi
            _full="$(systemctl status "$_svc" --no-pager -n 5 2>&1 || true; journalctl -u "$_svc" -n 10 --no-pager 2>&1 || true)"
            _why=""
            while IFS= read -r _l; do
                case "$_l" in
                    *[Ee]rror*|*[Aa]ddr[Ii]n[Uu]se*|*"already in use"*) _why="$_l"; break ;;
                esac
            done <<< "$_full"
            if [ -z "$_why" ]; then
                while IFS= read -r _l; do
                    case "$_l" in
                        *[Ff]ailed*|*FAILURE*) _why="$_l"; break ;;
                    esac
                done <<< "$_full"
            fi
            if [ -n "$_why" ]; then
                echo -e "      ${GRAY}${_why}${NC}"
            fi
        fi
    done

    echo ""
    if [ "$_total" -eq 0 ]; then
        log_warning "Ни одного сервиса для перезапуска не найдено (юниты в архиве: ${_svc_list_msg})"
    else
        # Итог перечисляет сервисы поимённо: что поднято, что не удалось, что пропущено.
        if [ -n "$_ok_names" ]; then
            log_success "Перезапущено и активно (${_active_ok}/${_total}):${_ok_names}"
        fi
        if [ "$_bad_n" -gt 0 ]; then
            log_warning "НЕ удалось поднять (${_bad_n}):${_bad_names}"
        fi
        if [ "$_skip_n" -gt 0 ]; then
            log_info "Пропущено (юнит не установлен):${_skip_names}"
        fi
        if [ "$_active_ok" -eq "$_total" ] && [ "$_enabled_ok" -eq "$_total" ]; then
            log_success "Восстановление завершено: все сервисы (${_total}) активны и включены в автозапуск"
        else
            log_warning "Восстановление завершено ЧАСТИЧНО: активны ${_active_ok}/${_total}, в автозапуске ${_enabled_ok}/${_total}, restart rc=0 у ${_restart_ok}/${_total}"
            log_warning "Проверьте: systemctl status <сервис> и journalctl -u <сервис>"
        fi
    fi
    return 0
}

# ── (3) Список бэкапов ───────────────────────────────────────
# Заполняет BACKUP_FILES найденными архивами (по возрастанию имени).
# read читает вывод find (process substitution), а не tty.
BACKUP_FILES=()
_backup_scan() {
    BACKUP_FILES=()
    local _line
    while IFS= read -r _line; do
        [ -n "$_line" ] || continue
        BACKUP_FILES+=("$_line")
    done < <(find "$BACKUP_DIR" -maxdepth 1 -name 'backup-*.tar.gz' -print 2>/dev/null | sort)
}

list_backups() {
    echo ""
    log_info "Каталог бэкапов: ${BACKUP_DIR}"
    if [ ! -d "$BACKUP_DIR" ]; then
        log_warning "Каталог ещё не создан — бэкапов нет"
        echo -e "  ${GRAY}Нажмите [1] — бэкап создастся одной кнопкой и появится в ${BACKUP_DIR}.${NC}"
        return 0
    fi

    _backup_scan

    if [ "${#BACKUP_FILES[@]}" -eq 0 ]; then
        log_warning "Бэкапов нет: в ${BACKUP_DIR} не найдено ни одного backup-*.tar.gz"
        echo -e "  ${GRAY}Нажмите [1] — бэкап создастся одной кнопкой (вводить ничего не нужно).${NC}"
        return 0
    fi

    echo -e "  ${BOLD}Бэкапов найдено: ${#BACKUP_FILES[@]}${NC}"
    local _n=0 _f _sz _info _scp
    for _f in "${BACKUP_FILES[@]}"; do
        _n=$((_n + 1))
        _sz="$(du -h "$_f" 2>/dev/null | awk '{print $1}' || echo '?')"
        _info="${_f}.info"
        _scp="?"
        if [ -s "$_info" ]; then
            _scp="$(grep -m1 '^scope=' "$_info" 2>/dev/null | cut -d= -f2- || true)"
            [ -n "$_scp" ] || _scp="all"
        fi
        echo -e "    ${CYAN}${_n})${NC} ${_f} (${_sz}) [scope: ${_scp}]"
    done

    # Готовый путь для scp: файл + обязательный sidecar .info (из него берётся scope).
    echo ""
    log_info "Путь для scp (первый из списка): ${BACKUP_FILES[0]}"
    echo -e "    ${DIM}scp ${BACKUP_FILES[0]} root@<НОВЫЙ_IP>:/root/${NC}"
    echo -e "    ${DIM}scp ${BACKUP_FILES[0]}.info root@<НОВЫЙ_IP>:/root/   # sidecar со scope — тоже нужен${NC}"
    log_info "Или выберите пункт [4] — перенос автоматически (со сверкой sha и развёртыванием)."
    return 0
}

# ── (5) Подсказка по ручному переносу ────────────────────────
show_transfer_hint() {
    echo ""
    echo -e "  ${BOLD}${CYAN}Как перенести панель на другой сервер (вручную)${NC}"
    echo ""
    echo -e "  ${YELLOW}Проще всего:${NC} пункт ${CYAN}[4]${NC} — «Перенести на другой сервер (авто)»."
    echo -e "  Он сам создаст бэкап, передаст архив по ${BOLD}scp${NC} (со сверкой sha256)"
    echo -e "  и, если разрешите, развернёт его на новом сервере."
    echo ""
    echo -e "  ${BOLD}Ручной порядок:${NC}"
    echo -e "  ${BOLD}1.${NC} На этом (старом) сервере создайте бэкап: пункт ${CYAN}[1]${NC}."
    echo -e "     Архив лежит в ${BOLD}${BACKUP_DIR}/${NC} (напр. backup-myhost-20250601-120000.tar.gz)."
    echo ""
    echo -e "  ${BOLD}2.${NC} Скопируйте архив ${BOLD}вместе с sidecar${NC} .info на новый сервер:"
    echo -e "     ${DIM}scp -P <порт> ${BACKUP_DIR}/backup-<host>-<дата>.tar.gz root@<НОВЫЙ_IP>:/root/${NC}"
    echo -e "     ${DIM}scp -P <порт> ${BACKUP_DIR}/backup-<host>-<дата>.tar.gz.info root@<НОВЫЙ_IP>:/root/${NC}"
    echo -e "     ${DIM}# .info нужен: из него берётся область архива (scope).${NC}"
    echo ""
    echo -e "  ${BOLD}3.${NC} На ${BOLD}новом${NC} сервере сначала установите MEKO Manager:"
    echo -e "     ${DIM}curl -fsSL ${MEKO_INSTALL_URL} | sudo bash${NC}"
    echo -e "     затем откройте это меню:"
    echo -e "     ${CYAN}Главное меню → [8] Дополнительно → [5] Бэкап и восстановление панели${NC},"
    echo -e "     пункт ${CYAN}[2]${NC} — «Восстановить из архива», укажите путь к скопированному .tar.gz."
    echo ""
    echo -e "  ${YELLOW}Важно:${NC} конфиги привязаны к IP/домену. Если домен/порт меняются —"
    echo -e "  после восстановления проверьте конфиги Telemt/MTG (меню прокси) и SYN FIX."
    echo -e "  ${YELLOW}Не забудьте про DNS:${NC} A-запись домена должна указывать на новый IP."
    return 0
}

# ═════════════════════════════════════════════════════════════
# ── (4) Перенос бэкапа на другой сервер (scp) ────────────────
# ═════════════════════════════════════════════════════════════
# Пароль SSH живёт только в переменной окружения процесса: он отдаётся
# sshpass через SSHPASS (`sshpass -e`), а НЕ аргументом командной строки,
# поэтому не попадает ни в `ps`, ни в shell-историю. На экран и в логи
# пароль не выводится никогда.
MIG_PASS=""
MIG_AUTH=""          # key | pass
MIG_ARCHIVE_SEL=""
MIG_OUT=""
MIG_RC=0
_SELF="${BASH_SOURCE[0]}"

# Оборачивает строку в одинарные кавычки, чтобы подставить её в удалённую
# команду без риска инъекции (одиночная кавычка внутри экранируется).
_shq() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

_mig_join_remote() {
    local _d="${1%/}"
    [ -n "$_d" ] || _d=""
    printf '%s/%s' "$_d" "$2"
}

# sha256 локального файла. Если sha256sum недоступен — __NOHASH__:
# сравнивать sha1 с удалённым sha256 нельзя (было бы ложное «sha НЕ совпал»).
_mig_hash_local() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" 2>/dev/null | awk '{print $1}'
    else
        printf '__NOHASH__'
    fi
}

# Подтверждение: под --yes вопрос не задаётся, ответ считается «да».
_mig_confirm() {
    local _prompt="$1" _c=""
    if [ "$ASSUME_YES" -eq 1 ]; then
        log_info "${_prompt} — пропущено (--yes)"
        return 0
    fi
    echo -en "  ${BOLD}${_prompt} [y/N]:${NC} "
    { read -r _c </dev/tty; } 2>/dev/null || { echo; return 1; }
    [[ "$_c" =~ ^[yY]$ ]]
}

# Выполняет удалённую команду, кладя rc в MIG_RC, а вывод — в MIG_OUT.
# Форма `A && B || C` не даёт `set -e` прервать скрипт на ненулевом rc.
_mig_run() {
    MIG_OUT="$(_mig_ssh "$1" 2>&1)" && MIG_RC=0 || MIG_RC=$?
}

_mig_ssh() {
    local _cmd="$1"
    if [ "$MIG_AUTH" = "pass" ]; then
        SSHPASS="$MIG_PASS" sshpass -e ssh -n -o StrictHostKeyChecking=accept-new \
            -o ConnectTimeout=10 -o LogLevel=ERROR -o PreferredAuthentications=password \
            -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1 \
            -p "$MIGRATE_PORT" "${MIGRATE_USER}@${MIGRATE_HOST}" "$_cmd"
    else
        # ssh -n: удалённым командам stdin не нужен, локальный stdin не расходуем.
        ssh -n -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
            -o ConnectTimeout=10 -o LogLevel=ERROR \
            -p "$MIGRATE_PORT" "${MIGRATE_USER}@${MIGRATE_HOST}" "$_cmd"
    fi
}

_mig_scp() {
    local _lf="$1" _rd="${2%/}"
    if [ "$MIG_AUTH" = "pass" ]; then
        SSHPASS="$MIG_PASS" sshpass -e scp -o StrictHostKeyChecking=accept-new \
            -o ConnectTimeout=10 -o LogLevel=ERROR -o PreferredAuthentications=password \
            -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1 \
            -P "$MIGRATE_PORT" "$_lf" "${MIGRATE_USER}@${MIGRATE_HOST}:${_rd}/"
    else
        scp -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
            -o ConnectTimeout=10 -o LogLevel=ERROR \
            -P "$MIGRATE_PORT" "$_lf" "${MIGRATE_USER}@${MIGRATE_HOST}:${_rd}/"
    fi
}

# Выбирает способ доступа: ключ, иначе пароль (SSHPASS или интерактивный ввод).
# sshpass не запускается «вслепую»: без ключа и без пароля — честный отказ.
_mig_detect_auth() {
    MIG_AUTH=""
    local _o=""
    _o="$(ssh -n -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
        -o LogLevel=ERROR -p "$MIGRATE_PORT" "${MIGRATE_USER}@${MIGRATE_HOST}" \
        'printf __MIG_OK__' 2>/dev/null || true)"
    case "$_o" in
        *__MIG_OK__*)
            MIG_AUTH="key"
            log_success "Доступ по SSH-ключу: ${MIGRATE_USER}@${MIGRATE_HOST}:${MIGRATE_PORT}"
            return 0
            ;;
    esac

    log_warning "Вход по ключу не сработал (BatchMode) — нужен пароль."
    if [ -z "$MIG_PASS" ] && [ -n "${SSHPASS:-}" ]; then
        MIG_PASS="$SSHPASS"
        log_info "Пароль взят из переменной окружения SSHPASS"
    fi
    # sshpass нужен и для пароля из SSHPASS, и для интерактивного ввода —
    # проверяем один раз, до вопроса.
    if ! command -v sshpass >/dev/null 2>&1; then
        log_error "Нужен доступ по ключу или пароль, но sshpass не установлен."
        log_info "Поставьте sshpass (apt-get install -y sshpass) или настройте SSH-ключ."
        return 1
    fi
    if [ -z "$MIG_PASS" ]; then
        echo -en "  ${BOLD}Пароль SSH для ${MIGRATE_USER}@${MIGRATE_HOST}:${NC} "
        local _p=""
        { read -rs _p </dev/tty; } 2>/dev/null || { echo; return 1; }
        echo ""
        if [ -z "$_p" ]; then
            log_error "Пароль не задан — нужен доступ по ключу или укажите пароль."
            return 1
        fi
        MIG_PASS="$_p"
    fi

    MIG_AUTH="pass"
    _o="$(SSHPASS="$MIG_PASS" sshpass -e ssh -n -o StrictHostKeyChecking=accept-new \
        -o ConnectTimeout=10 -o LogLevel=ERROR -o PreferredAuthentications=password \
        -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1 \
        -p "$MIGRATE_PORT" "${MIGRATE_USER}@${MIGRATE_HOST}" 'printf __MIG_OK__' 2>/dev/null || true)"
    case "$_o" in
        *__MIG_OK__*)
            log_success "Доступ по паролю: ${MIGRATE_USER}@${MIGRATE_HOST}:${MIGRATE_PORT}"
            return 0
            ;;
    esac
    log_error "Не удалось войти ни по ключу, ни по паролю — проверьте адрес, порт, пользователя и пароль."
    MIG_AUTH=""
    return 1
}

# Что переносить. Без --archive спрашивает: свежий бэкап / из списка / путь.
# Результат — в MIG_ARCHIVE_SEL (никакого stdout-захвата: create_backup много печатает).
_mig_choose_archive() {
    MIG_ARCHIVE_SEL=""
    if [ -n "$MIGRATE_ARCHIVE" ]; then
        if [ ! -f "$MIGRATE_ARCHIVE" ]; then
            log_error "Указанный архив не найден: ${MIGRATE_ARCHIVE}"
            return 1
        fi
        MIG_ARCHIVE_SEL="$MIGRATE_ARCHIVE"
        return 0
    fi

    echo ""
    echo -e "  ${BOLD}Что переносить?${NC}"
    echo -e "    ${CYAN}[1]${NC} Создать свежий бэкап сейчас (scope: ${SCOPE})"
    echo -e "    ${CYAN}[2]${NC} Выбрать существующий из списка"
    echo -e "    ${CYAN}[3]${NC} Указать путь к архиву"
    echo -en "  ${BOLD}Выбор [1]:${NC} "
    local _c=""
    { read -r _c </dev/tty; } 2>/dev/null || { echo; return 1; }
    _c="${_c:-1}"

    case "$_c" in
        1)
            create_backup || return 1
            local _lst=""
            _lst="$(find "$BACKUP_DIR" -maxdepth 1 -name 'backup-*.tar.gz' -printf '%T@ %p\n' 2>/dev/null || true)"
            MIG_ARCHIVE_SEL="$(printf '%s\n' "$_lst" | sort -rn | sed -n '1{s/^[^ ]* //;p}')"
            if [ -z "$MIG_ARCHIVE_SEL" ] || [ ! -f "$MIG_ARCHIVE_SEL" ]; then
                log_error "Не удалось определить свежесозданный архив в ${BACKUP_DIR}"
                return 1
            fi
            log_info "Свежий архив: ${MIG_ARCHIVE_SEL}"
            return 0
            ;;
        2)
            _backup_scan
            if [ "${#BACKUP_FILES[@]}" -eq 0 ]; then
                log_error "Бэкапов нет — сначала создайте бэкап (пункт [1])."
                return 1
            fi
            local _i=0 _f
            for _f in "${BACKUP_FILES[@]}"; do
                _i=$((_i + 1))
                echo -e "    ${CYAN}${_i})${NC} ${_f}"
            done
            echo -en "  ${BOLD}Номер:${NC} "
            local _n=""
            { read -r _n </dev/tty; } 2>/dev/null || { echo; return 1; }
            case "$_n" in
                '' | *[!0-9]*)
                    log_error "Нужен номер из списка"
                    return 1
                    ;;
            esac
            if [ "$_n" -lt 1 ] || [ "$_n" -gt "${#BACKUP_FILES[@]}" ]; then
                log_error "Номер вне диапазона (1..${#BACKUP_FILES[@]})"
                return 1
            fi
            MIG_ARCHIVE_SEL="${BACKUP_FILES[$((_n - 1))]}"
            return 0
            ;;
        3)
            echo -en "  ${BOLD}Путь к архиву (.tar.gz):${NC} "
            local _p=""
            { read -r _p </dev/tty; } 2>/dev/null || { echo; return 1; }
            _p="${_p%\"}"; _p="${_p#\"}"; _p="${_p%\'}"; _p="${_p#\'}"
            if [ ! -f "$_p" ]; then
                log_error "Файл не найден: ${_p}"
                return 1
            fi
            MIG_ARCHIVE_SEL="$_p"
            return 0
            ;;
        *)
            log_error "Неверный выбор"
            return 1
            ;;
    esac
}

# Проверки на новом сервере + передача архива и sidecar .info + сверка sha256.
_mig_transfer() {
    local _archive="$1"
    local _base _rpath _lsize _need _free _lhash _rhash _rsize
    _base="$(basename "$_archive")"
    _rpath="$(_mig_join_remote "$MIGRATE_DIR" "$_base")"
    _lsize="$(stat -c %s "$_archive" 2>/dev/null || echo 0)"

    # ── tar и записываемый каталог ──
    _mig_run "if ! command -v tar >/dev/null 2>&1; then echo __NO_TAR__; else mkdir -p $(_shq "$MIGRATE_DIR") && echo __DIR_OK__; fi"
    case "$MIG_OUT" in
        *__DIR_OK__*)
            log_success "На новом сервере есть tar, каталог ${MIGRATE_DIR} готов"
            ;;
        *__NO_TAR__*)
            log_error "На новом сервере нет tar — перенос невозможен"
            return 1
            ;;
        *)
            log_error "Не удалось подготовить каталог ${MIGRATE_DIR} на новом сервере (rc=${MIG_RC}): ${MIG_OUT}"
            return 1
            ;;
    esac

    # ── свободное место (КБ) ──
    _need=$(( _lsize / 1024 ))
    _mig_run "df -Pk $(_shq "$MIGRATE_DIR") 2>/dev/null | awk 'NR==2{print \$4}'"
    _free="${MIG_OUT//[!0-9]/}"
    if [ -n "$_free" ]; then
        if [ "$_free" -lt $(( _need * 2 )) ]; then
            log_warning "Мало места на новом сервере: свободно ${_free} КБ, архив ${_need} КБ"
            _mig_confirm "Продолжить несмотря на это?" || return 1
        else
            log_info "Свободно на новом сервере: ${_free} КБ (архив ${_need} КБ)"
        fi
    else
        log_warning "Не удалось определить свободное место на новом сервере — проверку пропускаю"
    fi

    # ── файл уже есть? ──
    _mig_run "test -e $(_shq "$_rpath") && echo __EXISTS__ || echo __ABSENT__"
    case "$MIG_OUT" in
        *__EXISTS__*)
            log_warning "На новом сервере уже есть ${_rpath}"
            _mig_confirm "Перезаписать его?" || return 1
            ;;
    esac

    # ── сама передача ──
    if [ "$MIG_AUTH" = "pass" ]; then
        log_info "Передаю ${_base} → ${MIGRATE_USER}@${MIGRATE_HOST}:${MIGRATE_DIR}/ (scp, пароль через sshpass) ..."
    else
        log_info "Передаю ${_base} → ${MIGRATE_USER}@${MIGRATE_HOST}:${MIGRATE_DIR}/ (scp по ключу, BatchMode) ..."
    fi
    if ! _mig_scp "$_archive" "$MIGRATE_DIR"; then
        log_error "scp завершился с ошибкой — архив не передан"
        return 1
    fi
    log_success "scp: архив передан (rc=0)"

    local _info="${_archive}.info"
    if [ -s "$_info" ]; then
        if _mig_scp "$_info" "$MIGRATE_DIR"; then
            log_success "scp: sidecar ${_info##*/} передан (rc=0)"
        else
            log_warning "Не удалось передать ${_info##*/} — на новом сервере scope определится как неизвестный"
        fi
    else
        log_warning "Sidecar .info отсутствует — на новом сервере scope определится как неизвестный"
    fi

    # ── проверка на той стороне: файл существует, размер и sha256 совпадают ──
    _lhash="$(_mig_hash_local "$_archive")"
    _mig_run "if command -v sha256sum >/dev/null 2>&1; then sha256sum $(_shq "$_rpath") 2>/dev/null | awk '{print \$1}'; else echo __NOHASH__; fi"
    _rhash="$(printf '%s' "$MIG_OUT" | tr -d '\r\n')"
    _mig_run "stat -c %s $(_shq "$_rpath") 2>/dev/null || echo 0"
    _rsize="$(printf '%s' "$MIG_OUT" | tr -d '\r\n')"

    if [ "$_lhash" = "__NOHASH__" ] || [ "$_rhash" = "__NOHASH__" ] || [ -z "$_rhash" ]; then
        log_warning "sha256 недоступен локально или на новом сервере — сверяю только размер"
        if [ "$_rsize" = "$_lsize" ]; then
            log_success "Размер совпал: ${_rsize} байт (${_rpath})"
        else
            log_error "Размер НЕ совпал: локально ${_lsize}, на новом ${_rsize}"
            return 1
        fi
    elif [ "$_lhash" = "$_rhash" ]; then
        log_success "Файл на новом сервере: ${_rpath} (${_rsize} байт)"
        log_success "sha256 совпал: ${_lhash}"
    else
        log_error "sha256 НЕ совпал! локально=${_lhash}, на новом=${_rhash} — файл повреждён"
        return 1
    fi
    return 0
}

# Опционально: установить панель (если нет), положить архив в /root/mtpr-backups
# и запустить восстановление на новом сервере.
_mig_deploy() {
    local _archive="$1"
    local _base _rpath _panel _dest _info _rscope _s _irc _trc _remote_panel
    _base="$(basename "$_archive")"
    _rpath="$(_mig_join_remote "$MIGRATE_DIR" "$_base")"
    _panel="/opt/mtpr-simple/data/backup_panel.sh"
    _dest="/root/mtpr-backups/${_base}"
    _info="${_archive}.info"

    echo ""
    log_info "Проверяю MEKO Manager на новом сервере..."
    _mig_run "if [ -f $(_shq "$_panel") ]; then echo __PANEL_OK__; else echo __PANEL_NO__; fi"
    case "$MIG_OUT" in
        *__PANEL_OK__*)
            log_success "MEKO Manager найден (${_panel})"
            ;;
        *__PANEL_NO__*)
            log_warning "MEKO Manager на новом сервере не установлен"
            if ! _mig_confirm "Скачать и запустить официальный install.sh на новом сервере?"; then
                log_info "Авто-развёртывание пропущено. Архив уже лежит на новом сервере: ${_rpath}"
                log_info "Установите MEKO Manager: curl -fsSL ${MEKO_INSTALL_URL} | sudo bash"
                return 0
            fi
            log_info "Скачиваю install.sh на новом сервере..."
            _mig_run "command -v curl >/dev/null 2>&1 || { echo __NO_CURL__; exit 0; }; curl -fsSL --max-time 120 $(_shq "$MEKO_INSTALL_URL") -o /tmp/meko-install.sh && [ -s /tmp/meko-install.sh ] && echo __GOT__"
            case "$MIG_OUT" in
                *__GOT__*)
                    log_success "install.sh загружен на новом сервере"
                    ;;
                *__NO_CURL__*)
                    log_error "На новом сервере нет curl — установите MEKO Manager вручную"
                    return 0
                    ;;
                *)
                    log_error "Не удалось скачать install.sh: ${MIG_OUT}"
                    return 0
                    ;;
            esac
            log_warning "Запускаю install.sh на новом сервере (интерактив недоступен; вывод идёт как есть)..."
            _irc=0
            _mig_ssh "timeout 900 bash /tmp/meko-install.sh </dev/null" || _irc=$?
            if [ "$_irc" -eq 0 ]; then
                log_success "install.sh завершился с rc=0"
            else
                log_error "install.sh завершился с rc=${_irc} — смотрите вывод выше"
            fi
            _mig_run "if [ -f $(_shq "$_panel") ]; then echo __PANEL_OK__; else echo __PANEL_NO__; fi"
            case "$MIG_OUT" in
                *__PANEL_OK__*)
                    log_success "MEKO Manager установлен"
                    ;;
                *)
                    log_error "После установки ${_panel} всё ещё нет — авто-развёртывание невозможно."
                    log_info "Установите MEKO Manager вручную и восстановите архив: ${_rpath}"
                    return 0
                    ;;
            esac
            ;;
        *)
            log_error "Не удалось проверить наличие MEKO Manager (rc=${MIG_RC}): ${MIG_OUT}"
            return 0
            ;;
    esac

    # ── Чем восстанавливать на новом сервере ──
    # Если панель на новом сервере старой версии (без --restore-file) или её нет,
    # используем ТЕКУЩИЙ скрипт: копируем его на новый сервер и восстанавливаем им.
    # Установленную панель нового сервера при этом не трогаем.
    _remote_panel="$_panel"
    _mig_run "grep -q -- '--restore-file' $(_shq "$_panel") 2>/dev/null && echo __HAS_RF__ || echo __NO_RF__"
    case "$MIG_OUT" in
        *__HAS_RF__*)
            log_info "Панель на новом сервере поддерживает --restore-file"
            ;;
        *)
            log_warning "Панель на новом сервере не поддерживает --restore-file — беру текущий скрипт"
            if ! _mig_scp "$_SELF" "$MIGRATE_DIR"; then
                log_error "Не удалось передать текущий скрипт на новый сервер — авто-развёртывание невозможно"
                log_info "Архив уже лежит на новом сервере: ${_rpath}"
                return 0
            fi
            _remote_panel="$(_mig_join_remote "$MIGRATE_DIR" "$(basename "$_SELF")")"
            log_success "Скрипт для восстановления: ${_remote_panel}"
            ;;
    esac

    if ! _mig_confirm "Развернуть ${_base} на новом сервере и перезапустить сервисы?"; then
        log_info "Развёртывание отменено. Архив лежит на новом сервере: ${_rpath}"
        return 0
    fi

    _mig_run "mkdir -p /root/mtpr-backups && cp $(_shq "$_rpath") $(_shq "$_dest") && echo __COPIED__"
    case "$MIG_OUT" in
        *__COPIED__*)
            log_success "Архив на новом сервере: ${_dest}"
            ;;
        *)
            log_error "Не удалось скопировать архив в /root/mtpr-backups: ${MIG_OUT}"
            return 0
            ;;
    esac

    if [ -s "$_info" ]; then
        _mig_run "cp $(_shq "$(_mig_join_remote "$MIGRATE_DIR" "${_info##*/}")") $(_shq "${_dest}.info") && echo __COPIED__"
        case "$MIG_OUT" in
            *__COPIED__*) log_success "Sidecar: ${_dest}.info" ;;
            *) log_warning "Sidecar .info не скопирован — scope может определиться как неизвестный" ;;
        esac
    fi

    _rscope="$SCOPE"
    if [ -s "$_info" ]; then
        _s="$(grep -m1 '^scope=' "$_info" 2>/dev/null | cut -d= -f2- || true)"
        case "$_s" in
            all | telemt | fix) _rscope="$_s" ;;
        esac
    fi

    log_info "Запускаю восстановление на новом сервере (scope: ${_rscope}) — это займёт время..."
    _trc=0
    _mig_ssh "bash $(_shq "$_remote_panel") --restore-file $(_shq "$_dest") --scope $(_shq "$_rscope") --yes" || _trc=$?
    if [ "$_trc" -eq 0 ]; then
        log_success "Восстановление на новом сервере завершено (rc=0)"
        log_info "Проверьте сервисы: ssh -p ${MIGRATE_PORT} ${MIGRATE_USER}@${MIGRATE_HOST} 'systemctl --failed'"
    else
        log_error "Восстановление на новом сервере завершилось с rc=${_trc}"
        log_info "Архив на месте: ${_dest}; повторить:"
        log_info "  ssh -p ${MIGRATE_PORT} ${MIGRATE_USER}@${MIGRATE_HOST} 'bash ${_remote_panel} --restore-file ${_dest}'"
    fi
    return 0
}

# ── (4) Главная функция переноса ─────────────────────────────
migrate_backup() {
    echo ""
    echo -e "  ${BOLD}${CYAN}Перенос бэкапа на другой сервер${NC}"
    echo -e "  ${DIM}scp + сверка sha256 + (опционально) автоматическое развёртывание${NC}"
    echo ""

    if ! command -v ssh >/dev/null 2>&1 || ! command -v scp >/dev/null 2>&1; then
        log_error "ssh/scp не найдены — перенос невозможен"
        return 1
    fi

    # 1. Что переносим
    if ! _mig_choose_archive; then
        return 1
    fi
    local _archive="$MIG_ARCHIVE_SEL"
    echo ""
    log_info "Архив: ${_archive} ($(du -h "$_archive" 2>/dev/null | awk '{print $1}' || echo '?'))"

    # 2. Куда переносим (интерактивно, если адрес не задан через --migrate-to)
    local _x=""
    if [ -z "$MIGRATE_HOST" ]; then
        echo -en "  ${BOLD}IP или домен нового сервера:${NC} "
        { read -r MIGRATE_HOST </dev/tty; } 2>/dev/null || { echo; return 1; }
        if [ -z "$MIGRATE_HOST" ]; then
            log_error "Сервер не указан"
            return 1
        fi
        echo -en "  ${BOLD}SSH-порт [${MIGRATE_PORT}]:${NC} "
        { read -r _x </dev/tty; } 2>/dev/null || { echo; return 1; }
        if [ -n "$_x" ]; then MIGRATE_PORT="$_x"; fi
        echo -en "  ${BOLD}Пользователь [${MIGRATE_USER}]:${NC} "
        _x=""
        { read -r _x </dev/tty; } 2>/dev/null || { echo; return 1; }
        if [ -n "$_x" ]; then MIGRATE_USER="$_x"; fi
        echo -en "  ${BOLD}Каталог на новом сервере [${MIGRATE_DIR}]:${NC} "
        _x=""
        { read -r _x </dev/tty; } 2>/dev/null || { echo; return 1; }
        if [ -n "$_x" ]; then MIGRATE_DIR="$_x"; fi
    fi

    # 3. Валидация
    case "$MIGRATE_HOST" in
        *[!A-Za-z0-9._:-]*)
            log_error "Некорректный адрес сервера: ${MIGRATE_HOST}"
            return 1
            ;;
    esac
    case "$MIGRATE_PORT" in
        '' | *[!0-9]*)
            log_error "Некорректный SSH-порт: ${MIGRATE_PORT}"
            return 1
            ;;
    esac
    if [ "$MIGRATE_PORT" -lt 1 ] || [ "$MIGRATE_PORT" -gt 65535 ]; then
        log_error "SSH-порт вне диапазона 1..65535: ${MIGRATE_PORT}"
        return 1
    fi
    case "$MIGRATE_USER" in
        '' | *[!A-Za-z0-9._-]*)
            log_error "Некорректный пользователь SSH: ${MIGRATE_USER}"
            return 1
            ;;
    esac

    echo ""
    log_info "Новый сервер: ${MIGRATE_USER}@${MIGRATE_HOST}:${MIGRATE_PORT} (каталог ${MIGRATE_DIR})"
    log_warning "Изменения на новом сервере (копирование файлов) — только после подтверждений."
    if ! _mig_confirm "Начать перенос (scp) на этот сервер?"; then
        log_info "Перенос отменён"
        return 0
    fi

    # 4. Доступ и передача
    if ! _mig_detect_auth; then
        return 1
    fi
    if ! _mig_transfer "$_archive"; then
        return 1
    fi

    # 5. Развёртывание (по желанию)
    echo ""
    if [ "$MIGRATE_DEPLOY" -eq 1 ]; then
        _mig_deploy "$_archive"
    elif [ "$ASSUME_YES" -eq 1 ]; then
        # --yes не является согласием на развёртывание: это отдельное действие,
        # поэтому без --deploy ничего на новом сервере не разворачиваем.
        log_info "Готово: архив передан. Развёртывание не запускалось (для него нужен --deploy)."
        log_info "  Развернуть позже: bash /opt/mtpr-simple/data/backup_panel.sh --restore-file ${MIGRATE_DIR}/${_archive##*/}"
    elif _mig_confirm "Сразу развернуть архив на новом сервере (при необходимости поставить панель и восстановить)?"; then
        _mig_deploy "$_archive"
    else
        log_info "Готово: архив передан. Развернуть можно позже на новом сервере:"
        log_info "  bash /opt/mtpr-simple/data/backup_panel.sh --restore-file ${MIGRATE_DIR}/${_archive##*/}"
    fi
    return 0
}

# ── Меню ─────────────────────────────────────────────────────
show_backup_menu() {
    while true; do
        [ -t 1 ] && { clear 2>/dev/null || true; }
        echo ""
        echo -e "  ${BOLD}${CYAN}Бэкап и восстановление панели${NC}"
        echo -e "  ${DIM}Каталог: ${BACKUP_DIR}${NC}"
        echo -e "  ${DIM}══════════════════════════════${NC}"
        echo -e "  ${CYAN}[1]${NC}  Создать бэкап"
        echo -e "  ${CYAN}[2]${NC}  Восстановить из архива"
        echo -e "  ${CYAN}[3]${NC}  Показать бэкапы / путь для scp"
        echo -e "  ${CYAN}[4]${NC}  Перенести на другой сервер (авто)"
        echo -e "  ${CYAN}[5]${NC}  Как перенести вручную (справка)"
        echo -e "  ${CYAN}[6]${NC}  Область бэкапа: ${BOLD}${SCOPE}${NC}"
        echo -e "  ${RED}[0]${NC}  Назад"
        echo ""
        echo -en "  ${BOLD}Выбор:${NC} "
        local choice
        # Нет терминала (EOF на /dev/tty) — выходим штатно, а не с rc=1.
        { read -r choice </dev/tty; } 2>/dev/null || { echo; return 0; }
        case "$choice" in
            1)
                create_backup || true
                _pause || return 0
                ;;
            2)
                restore_backup || true
                _pause || return 0
                ;;
            3)
                list_backups
                _pause || return 0
                ;;
            4)
                migrate_backup || true
                _pause || return 0
                ;;
            5)
                show_transfer_hint
                _pause || return 0
                ;;
            6)
                echo -en "  ${BOLD}Область [all/telemt/fix] (Enter = ${SCOPE}):${NC} "
                local _sc=""
                { read -r _sc </dev/tty; } 2>/dev/null || { echo; return 0; }
                if [ -n "$_sc" ]; then
                    case "$_sc" in
                        all | telemt | fix)
                            SCOPE="$_sc"
                            log_success "Область бэкапа: ${SCOPE}"
                            ;;
                        *)
                            log_error "Неверная область '${_sc}' (all|telemt|fix)"
                            ;;
                    esac
                fi
                sleep 0.3
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
    # CLI-режимы (для скриптов/автоматизации) — иначе интерактивное меню.
    if [ -n "$RESTORE_FILE" ]; then
        restore_backup || exit $?
        exit 0
    fi
    if [ -n "$MIGRATE_HOST" ]; then
        migrate_backup || exit $?
        exit 0
    fi
    show_backup_menu
fi
