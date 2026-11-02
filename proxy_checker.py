#!/usr/bin/env python3
"""MEKO SNI/PQ checker — проверка доменов и прокси на PQ-безопасность.

Что делает: для каждого домена смотрит, принимает ли сервер гибридную
группу X25519MLKEM768. Если нет и при этом сервер выбирает X25519 —
это «маркер», по которому ТСПУ вычисляет MTProto-прокси и блокирует
iOS-клиентов.

Три режима запуска:
    proxy_checker.py                    интерактивный (как было)
    proxy_checker.py ozon.ru rutube.ru  пакетный: сначала таблица, потом отчёт
    proxy_checker.py --table ozon.ru    пакетный: только таблица
"""
import os
import re
import shutil
import subprocess
import socket
import sys
import threading
import time
import urllib.parse
from concurrent.futures import ThreadPoolExecutor, as_completed

# Консоль с однобайтовой кодировкой (Windows-терминал, `LANG=C`, ssh без UTF-8)
# не умеет '━' и '🔎' и роняет отчёт UnicodeEncodeError прямо посреди вывода.
# errors="replace" оставляет отчёт читаемым вместо трейсбека.
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, ValueError):
        pass


# ── Цвета ─────────────────────────────────────────────────────
RED = '\033[0;31m'
GREEN = '\033[0;32m'
YELLOW = '\033[1;33m'
BLUE = '\033[0;34m'
CYAN = '\033[0;36m'
GRAY = '\033[0;90m'
NC = '\033[0m'
BOLD = '\033[1m'
DIM = '\033[2m'

TIMEOUT = 10
REQUIRED_GROUP = "X25519MLKEM768"

VERSION = "v1.17"

# Переопределение для нестандартных префиксов:
#   MEKO_OPENSSL_BIN=/path/to/openssl mekopr
_OPENSSL_ENV = "MEKO_OPENSSL_BIN"

# Порядок важен: сначала типичные префиксы ручных сборок, затем PATH,
# в самом конце — системный бинарник как фолбэк.
_OPENSSL_CANDIDATES = (
    "/opt/openssl-3.5/bin/openssl",
    "/usr/local/ssl/bin/openssl",
    "/usr/local/bin/openssl",
    "/opt/openssl/bin/openssl",
    None,                       # -> shutil.which("openssl")
    "/usr/bin/openssl",
)

# Насколько широко разворачивать отчёт в пакетном режиме.
# 0 = только таблица, 1 = + отчёт по каждому домену, 2 = + сертификаты.
VERBOSE = 1


def _supports_pq(path):
    """Умеет ли этот бинарник REQUIRED_GROUP.

    Проверяем через `list -tls-groups`, а не парсингом `openssl version`:
    отвечает ровно на нужный вопрос и не ломается о суффиксы вида
    3.5.7-dev или 3.5.7+quic.
    """
    try:
        proc = subprocess.run(
            [path, "list", "-tls-groups"],
            capture_output=True, text=True, timeout=5,
        )
    except (subprocess.SubprocessError, OSError):
        return False
    return REQUIRED_GROUP in proc.stdout


def _find_openssl():
    """Возвращает (путь, умеет_ли_PQ).

    На Ubuntu 24.04 системный openssl — 3.0.x, он не знает ML-KEM, а поставить
    3.5 в /usr штатно нельзя (сломается apt/ssh/systemd). Поэтому его собирают
    в отдельный префикс — ищем там в первую очередь.
    """
    candidates = []
    env_bin = os.environ.get(_OPENSSL_ENV)
    if env_bin:
        candidates.append(env_bin)
    for cand in _OPENSSL_CANDIDATES:
        candidates.append(shutil.which("openssl") if cand is None else cand)

    seen = set()
    fallback = None
    for path in candidates:
        if not path or path in seen:
            continue
        seen.add(path)
        if not (os.path.isfile(path) and os.access(path, os.X_OK)):
            if env_bin and path == env_bin:
                print(f"{YELLOW}⚠️  {_OPENSSL_ENV}={path} не существует или не исполняется — игнорирую.{NC}",
                      file=sys.stderr)
            continue
        if fallback is None:
            fallback = path
        if _supports_pq(path):
            return path, True
    return fallback or "/usr/bin/openssl", False


OPENSSL_BIN, OPENSSL_HAS_PQ = _find_openssl()
# Единственный источник истины: оба имени выводятся из одного вызова,
# поэтому OPENSSL_HAS_PQ и OPENSSL_SUPPORTS_PQ не могут разойтись.
OPENSSL_SUPPORTS_PQ = OPENSSL_HAS_PQ

# MEKO-фикс ограничивает входящие SYN: hashlimit 54/minute (~1.1 сек на IP),
# ответ — REJECT с tcp-reset, у клиента это ECONNREFUSED. Без паузы чекер
# режет сам себя при проверке прокси, на котором этот фикс и установлен.
# Lock обязателен: check_ip() вызывается из ThreadPoolExecutor, и без
# сериализации воркеры одновременно пройдут проверку времени и всё равно
# улетят в лимит.
RATE_DELAY = 1.3
_rate_lock = threading.Lock()
_last_call = 0.0


def _throttle():
    global _last_call
    with _rate_lock:
        gap = time.monotonic() - _last_call
        if gap < RATE_DELAY:
            time.sleep(RATE_DELAY - gap)
        _last_call = time.monotonic()

# Если OpenSSL не поддерживает PQ — выведем предупреждение при первом вызове check_one
_WARNED_PQ = False

def print_warning_pq():
    global _WARNED_PQ
    if not _WARNED_PQ:
        _WARNED_PQ = True
        print(f"{YELLOW}⚠️  Локальный OpenSSL ({OPENSSL_BIN}) не поддерживает X25519MLKEM768.{NC}")
        print(f"{YELLOW}    Результат PQ-проверки недостоверен. Требуется OpenSSL >= 3.5.{NC}")
        print(f"{YELLOW}    Установите свежую версию в /opt/openssl-3.5/bin/openssl{NC}")
        print()

# ── Вспомогательный вывод и парсинг ────────────────────────
def print_info(text):
    print(f"{BLUE}ℹ️ {text}{NC}")

def print_warning(text):
    print(f"{YELLOW}⚠️ {text}{NC}")

def normalize(raw):
    t = raw.strip()
    t = re.sub(r'^https?://', '', t)
    t = t.split('/')[0].split('?')[0].split('#')[0].strip()
    return t

def run_openssl(args, stdin=b""):
    _throttle()
    env = os.environ.copy()
    try:
        proc = subprocess.run(
            [OPENSSL_BIN] + args,
            input=stdin,
            capture_output=True,
            timeout=TIMEOUT,
            env=env,
        )
        return (proc.stdout + proc.stderr).decode(errors='replace')
    except subprocess.TimeoutExpired:
        return "TIMEOUT"
    except Exception as e:
        return f"ERROR: {e}"

def run_openssl_full(args):
    """Полный вывод (без -brief); на запрос сертификата отвечаем Q."""
    return run_openssl(args, stdin=b"Q\n")

def classify_failure(output):
    """Отличает проблему клиента от вердикта о сервере.

    Возвращает (уровень, текст) либо None. Только уровень "server" говорит
    что-либо о проверяемом домене: "client" — не тот openssl, "blocked" —
    соединение не дошло.
    """
    if "gid_cb" in output and REQUIRED_GROUP in output:
        return ("client",
                f"Локальный OpenSSL не поддерживает {REQUIRED_GROUP} — проверка "
                f"невозможна. Это НЕ значит, что сервер её не умеет. "
                f"Нужен OpenSSL >= 3.5.")
    if "Connection refused" in output or "BIO_connect" in output:
        return ("blocked",
                "Соединение отклонено (RST). Вероятно, сработал rate limit "
                "MEKO-фикса на целевом сервере. Повторите через ~2 сек.")
    if "handshake failure" in output:
        return ("server",
                f"Сервер отклонил {REQUIRED_GROUP} — PQ не поддерживается.")
    if "TIMEOUT" in output:
        return ("blocked", "Таймаут соединения.")
    return None


def _first_error_line(text):
    """Первая строка вывода с alert/error — для строки «Причина»."""
    for ln in text.splitlines():
        if "alert" in ln or "error:" in ln:
            return ln.strip()
    return ""


def render_failure(lines, output):
    """Печатает статус PQ с учётом того, ЧЬЯ это проблема."""
    verdict = classify_failure(output)
    if verdict and verdict[0] == "client":
        lines.append(f"{YELLOW}⚠️ Статус: проверить не удалось (проблема на этой машине){NC}")
        lines.append(f"  {YELLOW}{verdict[1]}{NC}")
        return
    if verdict and verdict[0] == "blocked":
        lines.append(f"{YELLOW}⚠️ Статус: проверить не удалось (соединение не дошло){NC}")
        lines.append(f"  {YELLOW}{verdict[1]}{NC}")
        return
    lines.append(f"{RED}🔸 Статус: не поддерживается{NC}")
    if verdict:
        lines.append(f"  Причина: {GRAY}{verdict[1]}{NC}")
        return
    reason = _first_error_line(output)
    if reason:
        lines.append(f"  Причина: {GRAY}{reason}{NC}")


def parse_field(text, key):
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith(key + ":"):
            return stripped.split(":", 1)[1].strip()
    return ""

def parse_field_full(text, key):
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.lower().startswith(key.lower() + ":"):
            return stripped.split(":", 1)[1].strip()
    return ""

def resolve_all_ips(host):
    """Возвращает список всех IP-адресов для домена."""
    try:
        ips = socket.getaddrinfo(host, None, socket.AF_UNSPEC, socket.SOCK_STREAM)
        seen = []
        for family, _, _, _, sockaddr in ips:
            ip = sockaddr[0]
            if ip not in seen and ':' not in ip:  # только IPv4
                seen.append(ip)
        return seen if seen else []
    except Exception:
        return []

def resolve_ip_str(host):
    """Возвращает строку с IP-адресами через запятую."""
    ips = resolve_all_ips(host)
    return ", ".join(ips) if ips else "не удалось определить"

def extract_cert_details(full_output):
    info = {}
    for line in full_output.splitlines():
        s = line.strip()
        if s.startswith("subject="):
            info["subject"] = s.split("=", 1)[1].strip()
        elif s.startswith("issuer="):
            info["issuer"] = s.split("=", 1)[1].strip()
        elif s.startswith("Protocol") and ":" in s:
            info["protocol"] = s.split(":", 1)[1].strip()
        elif s.startswith("Cipher") and ":" in s and "Ciphersuite" not in s:
            info["cipher_detail"] = s.split(":", 1)[1].strip()

    not_before = parse_field_full(full_output, "Not Before")
    not_after = parse_field_full(full_output, "Not After")
    if not_before:
        info["not_before"] = not_before
    if not_after:
        info["not_after"] = not_after

    return info


def _cert_cn(chunk):
    """CN из строки «subject=...» сертификата."""
    m = re.search(r'\bCN\s*=\s*([^,/\n]+)', chunk)
    return m.group(1).strip() if m else ""


def check_ip(ip, port, sni):
    """Проверяет один IP-адрес, возвращает краткий результат."""
    connect = f"{ip}:{port}"

    # ── Если OpenSSL не поддерживает X25519MLKEM768 ──────────
    if not OPENSSL_SUPPORTS_PQ:
        # Пропускаем PQ-проверку, сразу переходим к обычному TLS
        std = run_openssl([
            "s_client", "-connect", connect,
            "-servername", sni,
            "-brief",
        ])
        if "CONNECTION ESTABLISHED" not in std:
            return {
                "ip": ip,
                "pq_supported": False,
                "has_marker": False,
                "proto": "",
                "cipher": "",
                "temp_key": "",
                "error": True,
                "pq_output": "SKIPPED (openssl не поддерживает группу)",
                "std_output": std,
                "pq_skipped": True
            }
        proto = parse_field(std, "Protocol version")
        cipher = parse_field(std, "Ciphersuite")
        temp = parse_field(std, "Peer Temp Key")
        # Маркер: PQ не поддерживается + Peer Temp Key = X25519
        has_marker = temp.startswith("X25519")
        return {
            "ip": ip,
            "pq_supported": False,
            "has_marker": has_marker,
            "proto": proto,
            "cipher": cipher,
            "temp_key": temp,
            "pq_output": "SKIPPED",
            "std_output": std,
            "pq_skipped": True
        }

    # ── PQ-проверка (если OpenSSL поддерживает группу) ──────
    pq = run_openssl([
        "s_client", "-connect", connect,
        "-servername", sni,
        "-groups", "X25519MLKEM768",
        "-brief",
    ])

    # Проверяем, не вернулась ли ошибка от самого openssl (например, gid_cb)
    if "gid_cb" in pq or "invalid argument" in pq or "cannot be set" in pq:
        # Это означает, что наш бинарник не смог обработать группу (хотя ранее проверка прошла?)
        # На всякий случай сообщаем о проблеме
        return {
            "ip": ip,
            "pq_supported": False,
            "has_marker": False,
            "proto": "",
            "cipher": "",
            "temp_key": "",
            "error": True,
            "pq_output": pq,
            "std_output": "",
            "pq_skipped": True,
            "pq_error": "openssl не смог применить группу (возможно, несовместимость)"
        }

    if "CONNECTION ESTABLISHED" in pq:
        proto = parse_field(pq, "Protocol version")
        cipher = parse_field(pq, "Ciphersuite")
        return {
            "ip": ip,
            "pq_supported": True,
            "has_marker": False,
            "proto": proto,
            "cipher": cipher,
            "pq_output": pq
        }

    # PQ не поддерживается — проверяем обычный TLS
    std = run_openssl([
        "s_client", "-connect", connect,
        "-servername", sni,
        "-brief",
    ])

    if "CONNECTION ESTABLISHED" not in std:
        return {
            "ip": ip,
            "pq_supported": False,
            "has_marker": False,
            "proto": "",
            "cipher": "",
            "temp_key": "",
            "error": True,
            "pq_output": pq,
            "std_output": std
        }

    proto = parse_field(std, "Protocol version")
    cipher = parse_field(std, "Ciphersuite")
    temp = parse_field(std, "Peer Temp Key")
    has_marker = temp.startswith("X25519")
    return {
        "ip": ip,
        "pq_supported": False,
        "has_marker": has_marker,
        "proto": proto,
        "cipher": cipher,
        "temp_key": temp,
        "pq_output": pq,
        "std_output": std
    }

def decode_secret_sni(secret_hex):
    """Достаёт SNI (маскировочный домен) из MTProto-секрета.

    Формат `ee`-секрета (fake-TLS):
        ee  +  16 байт ключа  +  домен в ASCII
    То есть байты [17:] — это и есть SNI в открытом виде, без шифрования.

    У старых `dd`-секретов домена внутри нет — там только ключ.

    Возвращает (domain, key_hex) либо (None, None).
    """
    s = (secret_hex or "").strip().lower()
    if not s or len(s) % 2 or not re.fullmatch(r'[0-9a-f]+', s):
        return None, None
    if s.startswith("ee"):
        # 1 байт префикса + 16 байт ключа = 34 hex-символа
        if len(s) <= 34:
            return None, s[2:34]
        key = s[2:34]
        rest = s[34:]
        try:
            domain = bytes.fromhex(rest).decode("ascii", errors="strict")
        except (ValueError, UnicodeDecodeError):
            return None, key
        domain = domain.strip().strip("\x00").strip()
        # Отсекаем возможный мусор/управляющие байты
        domain = re.sub(r'[^A-Za-z0-9.\-]', '', domain)
        return (domain or None), key
    if s.startswith("dd"):
        return None, s[2:]
    # Секрет без префикса — просто ключ, домена нет
    return None, s


# Все виды ссылок на MTProto/WEB-прокси, которые умеет разбирать чекер.
#   tg://proxy?server=HOST&port=443&secret=...
#   tg://webproxy?server=HOST&secret=...          (порт всегда 443)
#   tg://socks?server=HOST&port=1080&user=..&pass=..
#   https://t.me/proxy?server=HOST&port=443&secret=..
# Плюс «голый» вид server:port без обёртки.
def parse_proxy_link(raw):
    """Разбирает ссылку на прокси в (host, port, kind, sni).

    kind: 'mtproto' | 'web' | 'socks' | None (не ссылка).
    sni: домен, зашитый в secret (для MTProto), иначе None.
    Возвращает (None, None, None, None), если это не ссылка.
    """
    s = raw.strip()
    low = s.lower()
    if low.startswith("tg://") or low.startswith("https://t.me/") \
            or low.startswith("t.me/"):
        kind = "mtproto"
        if "webproxy" in low:
            kind = "web"
        elif "socks" in low:
            kind = "socks"
        # tg://http/proxy? — WEB-прокси, но https://t.me/... это обычная
        # ссылка на MTProto, её за WEB принимать нельзя.
        elif low.startswith("tg://http"):
            kind = "web"
        # Приводим к виду, который понимает urlparse
        norm = s
        if low.startswith("tg://"):
            norm = "https://tg.invalid/" + s[len("tg://"):]
        elif low.startswith("t.me/"):
            norm = "https://" + s
        parsed = urllib.parse.urlparse(norm)
        params = urllib.parse.parse_qs(parsed.query)
        server = (params.get("server") or params.get("host") or [None])[0]
        if not server:
            return None, None, None, None
        port = (params.get("port") or [None])[0]
        if not port:
            # WEB-прокси всегда на 443, у socks стоковый 1080
            port = "1080" if kind == "socks" else "443"
        # У MTProto настоящий SNI спрятан в secret — его и надо проверять
        sni = None
        secret = (params.get("secret") or [None])[0]
        if secret and kind == "mtproto":
            sni, _ = decode_secret_sni(secret)
        return server.strip(), str(port), kind, sni
    return None, None, None, None


def _parse_host_port(target):
    """Разбирает host[:port] с поддержкой IPv6.

    Понимает: example.com:443, 1.2.3.4:443, [::1]:443, [::1], ::1.
    Если порт не указан или не число — возвращает 443.
    """
    host = target
    port = "443"
    if target.startswith("["):
        end = target.find("]")
        if end != -1:
            host = target[1:end]
            rest = target[end + 1:]
            if rest.startswith(":") and rest[1:].isdigit():
                port = rest[1:]
    elif target.count(":") == 1:
        h, _, p = target.partition(":")
        host = h
        if p.isdigit():
            port = p
    # 0 двоеточий — хост без порта; >=2 — чистый IPv6 без порта
    return host, port


# ── Разбор входной строки ─────────────────────────────────────
def split_inputs(raw_list):
    """Разворачивает аргументы/строку ввода в список целей.

    Принимает любые разделители: пробелы, запятые, точки с запятой, переводы
    строк. Ссылка tg://… содержит запятых не содержит, но содержит «&» и «=»,
    поэтому режем аккуратно: сначала по пробелам, потом каждый кусок — по
    запятым/точкам с запятой, НО только если в нём нет «?» (признак ссылки).
    """
    out = []
    for chunk in raw_list:
        s = chunk.strip()
        if not s:
            continue
        for piece in re.split(r'\s+', s):
            piece = piece.strip()
            if not piece:
                continue
            # Ссылку с query-строкой не дробим — внутри неё могут быть
            # легитимные разделители, а параметры склеены через «&».
            if "?" in piece:
                out.append(piece.strip(',;'))
                continue
            for tok in re.split(r'[,;]+', piece):
                tok = tok.strip()
                if tok:
                    out.append(tok)
    # уникализируем, сохраняя порядок
    seen = set()
    uniq = []
    for t in out:
        k = t.lower()
        if k not in seen:
            seen.add(k)
            uniq.append(t)
    return uniq


def verdict_of(result):
    """Единый вердикт по результату проверки домена.

    Возвращает (код, метка, цвет) где код:
      ok      — PQ есть, блокировки по маркеру не будет
      no_pq   — PQ нет, но Temp Key не X25519 → мягкий случай
      danger  — маркер найден, iOS-клиенты рискуют
      partial — часть IP с маркером, часть без
      fail    — проверить не удалось
    """
    if not result.get("ips"):
        return ("fail", "НЕТ ОТВЕТА", RED)
    if result.get("pq_skipped"):
        return ("unknown", "ПРОВЕРИТЬ НЕЛЬЗЯ", YELLOW)

    checked = [r for r in result["ips"] if not r.get("error")]
    if not checked:
        return ("fail", "НЕ ОТВЕЧАЕТ", RED)

    marked = [r for r in checked if r.get("has_marker")]
    good = [r for r in checked if r.get("pq_supported")]

    if marked and good:
        return ("partial", "ЧАСТИЧНО ПЛОХОЙ", YELLOW)
    if marked:
        return ("danger", "ПЛОХОЙ", RED)
    if good:
        return ("ok", "ХОРОШИЙ", GREEN)
    return ("no_pq", "ОК (без PQ)", GREEN)


def summarize(domain, result):
    """Короткая сводка по домену — для таблицы."""
    code, label, color = verdict_of(result)
    checked = [r for r in result.get("ips", []) if not r.get("error")]
    total = len(result.get("ips", []))
    marked = sum(1 for r in checked if r.get("has_marker"))
    good = sum(1 for r in checked if r.get("pq_supported"))
    bad_count = len(checked) - good - marked

    # В колонке ЦЕЛЬ показываем только имя хоста — длинная tg://-ссылка
    # растянула бы таблицу на весь экран. Тип ссылки уходит в ДЕТАЛИ.
    name = result.get("host", domain)
    kind = result.get("kind")
    if kind:
        name = f"{name} ({'WEB' if kind == 'web' else 'SOCKS' if kind == 'socks' else 'MTProto'})"
    if total > 1:
        name += f" [{total} IP]"

    return {
        "target": domain,
        "label_name": name,
        "host": result.get("host", domain),
        "port": result.get("port", "443"),
        "verdict": code,
        "label": label,
        "color": color,
        "ips_total": total,
        "ips_checked": len(checked),
        "ips_ok": good,
        "ips_marked": marked,
        "ips_nopq": bad_count,
        "cert_cn": result.get("cert_cn", ""),
        "reason": result.get("reason", ""),
    }


def _vis_len(text):
    """Длина строки без ANSI-последовательностей (для выравнивания)."""
    return len(re.sub(r'\033\[[0-9;]*m', '', text))


def _pad(text, width):
    return text + " " * max(0, width - _vis_len(text))


def render_table(summaries):
    """Печатает сводную таблицу по всем проверенным целям."""
    if not summaries:
        return []

    rows = []
    for s in summaries:
        status = f"{s['color']}{s['label']}{NC}"
        ips = f"{s['ips_checked']}/{s['ips_total']}" if s["ips_total"] else "—"
        if s["verdict"] == "partial":
            detail = f"{s['ips_ok']} ок, {s['ips_marked']} плохих"
        elif s["ips_marked"]:
            detail = f"{s['ips_marked']} с маркером"
        elif s["ips_ok"]:
            detail = "все с PQ"
        elif s["verdict"] == "fail":
            detail = s.get("reason") or "нет ответа"
        else:
            detail = "без PQ, но без маркера"
        rows.append((s["label_name"], status, ips, detail, s))

    w_target = max(_vis_len(r[0]) for r in rows)
    w_target = max(w_target, len("ЦЕЛЬ"))
    w_status = max(_vis_len(r[1]) for r in rows)
    w_status = max(w_status, len("СТАТУС"))
    w_ips = max(len(r[2]) for r in rows)
    w_ips = max(w_ips, len("IP"))

    out = []
    out.append(f"{CYAN}━━━ СВОДКА ({len(rows)} шт.) ━━━{NC}")
    head = f"  {_pad('ЦЕЛЬ', w_target)}  {_pad('СТАТУС', w_status)}  {_pad('IP', w_ips)}  ДЕТАЛИ"
    out.append(f"{BOLD}{head}{NC}")
    out.append(f"  {DIM}{'─' * (w_target + w_status + w_ips + 12)}{NC}")
    for target, status, ips, detail, _ in rows:
        out.append(f"  {_pad(target, w_target)}  {_pad(status, w_status)}  {_pad(ips, w_ips)}  {detail}")

    # Итоговая строка для тех, кто не хочет читать таблицу.
    bad = [r for r in rows if r[4]["verdict"] in ("danger", "partial")]
    unknown = [r for r in rows if r[4]["verdict"] in ("fail", "unknown")]
    out.append("")
    if bad:
        names = ", ".join(r[0] for r in bad)
        if unknown:
            out.append(f"{RED}{BOLD}ИТОГ: ЕСТЬ РИСК БЛОКИРОВКИ НА iOS — {names}{NC}")
            out.append(f"{YELLOW}      без вердикта: {', '.join(r[0] for r in unknown)}{NC}")
        else:
            out.append(f"{RED}{BOLD}ИТОГ: ЕСТЬ РИСК БЛОКИРОВКИ НА iOS — {names}{NC}")
    elif unknown:
        if len(unknown) == len(rows):
            out.append(f"{YELLOW}{BOLD}ИТОГ: ПРОВЕРИТЬ НЕ УДАЛОСЬ — {', '.join(r[0] for r in unknown)}{NC}")
        else:
            out.append(f"{YELLOW}{BOLD}ИТОГ: часть целей без вердикта — {', '.join(r[0] for r in unknown)}{NC}")
    else:
        out.append(f"{GREEN}{BOLD}ИТОГ: РИСКА НЕТ — все домены безопасны для iOS{NC}")
    return out


def render_domain(domain, result, verbose=1):
    """Подробный отчёт по одному домену."""
    code, label, color = verdict_of(result)
    lines = []
    lines.append("")
    title = f"{result.get('host', domain)}:{result.get('port', '443')}"
    lines.append(f"{BOLD}🔎 {title}{NC}")
    if result.get("kind"):
        kind_name = {"web": "WEB-прокси", "socks": "SOCKS-прокси"}.get(result["kind"], "MTProto-прокси")
        lines.append(f"{DIM}  Источник: ссылка {kind_name}{NC}")
    if result.get("sni_from_secret"):
        lines.append(f"{DIM}  SNI: {result['host']} (из secret){NC}")
        if result.get("link_server"):
            lines.append(f"{DIM}  Адрес прокси: {result['link_server']}:{result.get('port')}{NC}")
    ip_str = ", ".join(result.get("ips_raw", [])) or "не удалось определить"
    lines.append(f"{CYAN}🌐 IP: {NC}{ip_str}")

    if not result.get("ips"):
        lines.append("")
        lines.append(f"{RED}❌ {result.get('reason') or 'не удалось определить IP или подключиться'}{NC}")
        lines.append("")
        lines.append(f"{color}━━━ ВЕРДИКТ ━━━{NC}")
        lines.append(f"{color}{label} — проверить не удалось{NC}")
        return lines

    checked = [r for r in result["ips"] if not r.get("error")]
    if not checked:
        lines.append("")
        lines.append(f"{RED}❌ Ни один IP не ответил{NC}")
        lines.append("")
        lines.append(f"{color}━━━ ВЕРДИКТ ━━━{NC}")
        lines.append(f"{color}{label}{NC}")
        return lines

    # ── Покрытие ──────────────────────────────────────────
    lines.append("")
    lines.append(f"{CYAN}━━━ Проверка по IP ━━━{NC}")
    lines.append(f"  SNI: {result.get('host', domain)}")
    for r in checked:
        if r.get("pq_skipped", False):
            icon, text = "🟡", "PQ не проверялась (клиент не поддерживает)"
        elif r["pq_supported"]:
            icon, text = "🟢", "PQ OK"
        elif r["has_marker"]:
            icon, text = "🔴", "PQ нет, маркер ДА"
        else:
            icon, text = "🟡", "PQ нет, маркер НЕТ"
        details = f"{r.get('proto') or '?'} | {r.get('cipher') or '?'}"
        if r.get("temp_key"):
            details += f" | {r['temp_key']}"
        lines.append(f"  {icon} {r['ip']} — {text}")
        lines.append(f"    {details}")

    marked = sum(1 for r in checked if r.get("has_marker"))
    good = sum(1 for r in checked if r.get("pq_supported"))

    if code == "partial":
        lines.append("")
        lines.append(f"{YELLOW}⚠️ {good} из {len(checked)} IP без маркера, {marked} с маркером.{NC}")
        lines.append(f"{YELLOW}   Домен нестабилен: часть запросов уйдёт на плохой сервер.{NC}")
    elif marked:
        lines.append("")
        lines.append(f"{YELLOW}⚠️ Маркер есть на всех {marked} проверенных IP.{NC}")

    # ── PQ ────────────────────────────────────────────────
    lines.append("")
    lines.append(f"{CYAN}━━━ PQ-подключение (X25519MLKEM768) ━━━{NC}")
    if result.get("pq_skipped"):
        lines.append(f"{YELLOW}⚠️ Пропущено: локальный OpenSSL не умеет {REQUIRED_GROUP}.{NC}")
        lines.append(f"{YELLOW}   Нужен OpenSSL >= 3.5, путь можно задать: {_OPENSSL_ENV}=/path/to/openssl{NC}")
    elif result.get("pq_ok"):
        lines.append(f"{GREEN}✅ Статус: поддерживается{NC}")
        if result.get("pq_proto"):
            lines.append(f"  Протокол: {result['pq_proto']}")
        if result.get("pq_cipher"):
            lines.append(f"  Шифронабор: {result['pq_cipher']}")
    else:
        lines.append(f"{RED}🔸 Статус: не поддерживается{NC}")
        if result.get("pq_reason"):
            lines.append(f"  Причина: {GRAY}{result['pq_reason']}{NC}")

    # ── Обычный TLS ───────────────────────────────────────
    lines.append("")
    lines.append(f"{CYAN}━━━ Обычное TLS-подключение ━━━{NC}")
    if result.get("std_ok"):
        lines.append(f"{GREEN}🔹 Статус: OK{NC}")
        for lbl, key in (("Протокол", "std_proto"), ("Шифронабор", "std_cipher"),
                         ("Peer Temp Key", "std_temp"), ("Сертификат", "std_cert"),
                         ("Подпись", "std_sig"), ("Хэш", "std_hash"),
                         ("Верификация", "std_verify")):
            val = result.get(key)
            if val:
                lines.append(f"  {lbl}: {val}")
    else:
        lines.append(f"{RED}❌ Обычное TLS не удалось{NC}")
        if result.get("std_reason"):
            lines.append(f"  Причина: {GRAY}{result['std_reason']}{NC}")

    # ── Сертификат ────────────────────────────────────────
    cert = result.get("cert") or {}
    if verbose >= 2 and cert:
        lines.append("")
        lines.append(f"{CYAN}━━━ Сертификат ━━━{NC}")
        if cert.get("subject"):
            lines.append(f"  Subject: {cert['subject'][:120]}")
        if cert.get("issuer"):
            lines.append(f"  Issuer: {cert['issuer'][:120]}")
        if cert.get("not_before"):
            lines.append(f"  Действует с: {cert['not_before']}")
        if cert.get("not_after"):
            lines.append(f"  Истекает: {cert['not_after']}")

    # ── Вердикт ───────────────────────────────────────────
    lines.append("")
    lines.append(f"{color}━━━ ВЕРДИКТ ━━━{NC}")
    if code == "ok":
        lines.append(f"{GREEN}✅ ДОМЕН БЕЗОПАСЕН{NC}")
        lines.append(f"  Сервер принимает X25519MLKEM768 — ТСПУ маркер не увидит.")
    elif code == "partial":
        lines.append(f"{YELLOW}⚠️ ДОМЕН НЕНАДЁЖНЫЙ{NC}")
        lines.append(f"  Часть серверов ({marked} из {len(checked)}) отдаёт X25519 без PQ.")
        lines.append(f"  Подключение с iOS будет то работать, то нет. Лучше взять другой домен.")
    elif code == "danger":
        lines.append(f"{RED}❌ ДОМЕН ПЛОХОЙ — ЕСТЬ РИСК БЛОКИРОВКИ{NC}")
        lines.append(f"  PQ не поддерживается, сервер выбирает X25519 → это маркер ТСПУ.")
        lines.append(f"  С этого домена iOS-клиентов будет блокировать. Возьмите другой домен.")
    elif code == "unknown":
        lines.append(f"{YELLOW}🟡 ПРОВЕРИТЬ НЕ УДАЛОСЬ{NC}")
        lines.append(f"  Локальный OpenSSL не поддерживает PQ. Поставьте OpenSSL >= 3.5.")
    else:
        lines.append(f"{RED}❌ ПРОВЕРИТЬ НЕ УДАЛОСЬ{NC}")
        lines.append(f"  Ни один IP домена не ответил.")
    return lines


def check_domain(domain, want_cert=False):
    """Полная проверка одной цели: возвращает dict со всеми данными."""
    if not OPENSSL_SUPPORTS_PQ:
        print_warning_pq()

    raw_input = domain.strip()
    res = {"target": domain, "host": domain, "port": "443", "ips": [],
           "ips_raw": [], "reason": "", "cert_cn": "", "kind": None}

    # ── Ссылка на прокси (tg://proxy, tg://webproxy, t.me/proxy, socks) ──
    link_host, link_port, link_kind, link_sni = parse_proxy_link(raw_input)
    if link_kind:
        res["kind"] = link_kind
        res["link"] = raw_input
        if link_sni:
            # У MTProto настоящий SNI зашит в secret — проверяем именно его,
            # а server= это лишь адрес, куда стучаться.
            res["link_server"] = link_host
            host, port = link_sni, link_port
            res["host"] = host
            res["port"] = port
            res["sni_from_secret"] = True
            res["note"] = f"MTProto-прокси, SNI из secret: {link_sni}"
        else:
            host, port = link_host, link_port
            res["host"] = host
            res["port"] = port
            if link_kind == "web":
                res["note"] = "WEB-прокси (TLS на 443)"
            elif link_kind == "socks":
                res["note"] = "SOCKS-прокси"
            else:
                res["note"] = "MTProto-прокси"
    else:
        target = normalize(raw_input)
        if not target:
            res["reason"] = "пустой домен"
            return res
        host, port = _parse_host_port(target)
        res["host"] = host
        res["port"] = port

    ips = resolve_all_ips(host)
    res["ips_raw"] = ips
    if not ips:
        res["reason"] = f"не удалось определить IP для {host}"
        return res

    # ── Параллельная проверка всех IP домена ──────────────
    results = []
    workers = max(1, min(len(ips), 10))
    with ThreadPoolExecutor(max_workers=workers) as executor:
        futures = {executor.submit(check_ip, ip, port, host): ip for ip in ips}
        for future in as_completed(futures):
            try:
                results.append(future.result())
            except Exception as e:
                results.append({"ip": futures[future], "error": True,
                                "has_marker": False, "pq_supported": False,
                                "std_output": f"ERROR: {e}"})
    # Стабильный порядок: сначала без маркера и с PQ, потом остальные.
    results.sort(key=lambda x: (x.get("error", False),
                                not x.get("pq_supported", False),
                                x.get("has_marker", False),
                                x.get("ip", "")))
    res["ips"] = results

    if not results:
        res["reason"] = "ни один IP не проверен"
        return res

    # ── Детальная проверка: берём «худший» IP, он и определяет вердикт ──
    detail = None
    for r in results:
        if r.get("has_marker"):
            detail = r
            break
    if detail is None:
        detail = results[0]

    if not detail.get("error"):
        d_ip = detail["ip"]
        connect = f"{d_ip}:{port}"
        res["detail_ip"] = d_ip

        # Вывод PQ-пробы уже лежит в detail: check_ip() только что делала её
        # на этом же IP. Повторный вызов стоил бы ещё один RATE_DELAY.
        if OPENSSL_SUPPORTS_PQ:
            pq = detail.get("pq_output") or run_openssl(
                ["s_client", "-connect", connect,
                 "-servername", host, "-groups", "X25519MLKEM768", "-brief"])
        else:
            pq = "SKIPPED"

        res["pq_skipped"] = (pq == "SKIPPED")
        res["pq_ok"] = "CONNECTION ESTABLISHED" in pq
        if res["pq_ok"]:
            res["pq_proto"] = parse_field(pq, "Protocol version")
            res["pq_cipher"] = parse_field(pq, "Ciphersuite")
        elif not res["pq_skipped"]:
            res["pq_reason"] = _first_error_line(pq)

        std = run_openssl(["s_client", "-connect", connect,
                           "-servername", host, "-brief"])
        res["std_ok"] = "CONNECTION ESTABLISHED" in std
        if res["std_ok"]:
            res["std_proto"] = parse_field(std, "Protocol version")
            res["std_cipher"] = parse_field(std, "Ciphersuite")
            res["std_temp"] = parse_field(std, "Peer Temp Key")
            res["std_cert"] = parse_field(std, "Peer certificate")
            res["std_sig"] = parse_field(std, "Signature type")
            res["std_hash"] = parse_field(std, "Hash used")
            res["std_verify"] = parse_field(std, "Verification")
            res["cert_cn"] = _cert_cn(res["std_cert"] or "")
        else:
            res["std_reason"] = _first_error_line(std)

        if want_cert and verbose >= 2:
            full = run_openssl_full(["s_client", "-connect", connect,
                                     "-servername", host])
            res["cert"] = extract_cert_details(full)

    return res


# ── Совместимость со старым API (используется main.sh) ────────
def check_one(domain):
    """Возвращает готовый текстовый отчёт по одной цели."""
    result = check_domain(domain)
    return "\n".join(render_domain(domain, result, verbose=2))


def run_batch(targets, show_table=True, show_details=True):
    """Проверка списка целей с таблицей и итогом. Возвращает список summary.

    Цели проверяются ПАРАЛЛЕЛЬНО (пул потоков), а IP внутри каждой цели —
    своим пулом. Общий throttle по openssl сериализует сами вызовы, поэтому
    ускорение даёт перекрытие ожидания сети и DNS-резолва, а не запуск
    сотни openssl разом.
    """
    results_by_target = {}
    order = list(targets)

    def _one(t):
        try:
            return t, check_domain(t)
        except Exception as e:
            return t, {"target": t, "host": t, "port": "443", "ips": [],
                       "ips_raw": [], "reason": f"ошибка: {e}", "cert_cn": ""}

    max_targets = max(1, min(len(order), 4))
    if len(order) == 1:
        results_by_target[order[0]] = _one(order[0])[1]
    else:
        with ThreadPoolExecutor(max_workers=max_targets) as ex:
            futures = [ex.submit(_one, t) for t in order]
            for fut in as_completed(futures):
                try:
                    t, r = fut.result()
                except KeyboardInterrupt:
                    print(f"\n{YELLOW}Прервано пользователем{NC}")
                    break
                results_by_target[t] = r

    summaries = []
    results = []
    for t in order:
        r = results_by_target.get(t)
        if r is None:
            continue
        results.append((t, r))
        summaries.append(summarize(t, r))

    if show_table:
        print("")
        for ln in render_table(summaries):
            print(ln)

    # --quiet: одна строка итога. Без неё режим печатал вообще ничего,
    # хотя в --help обещан «только итог одной строкой».
    if not show_table and not show_details:
        bad = sum(1 for s in summaries if s["verdict"] in ("danger", "partial"))
        unknown = sum(1 for s in summaries if s["verdict"] in ("fail", "unknown"))
        print(f"ИТОГ: проверено {len(summaries)}, риск {bad}, без вердикта {unknown}")

    if show_details:
        for t, r in results:
            for ln in render_domain(t, r, verbose=VERBOSE):
                print(ln)

    # Итог ещё раз в самом конце — чтобы точно не пролистнули.
    if show_table and summaries:
        bad = [s for s in summaries if s["verdict"] in ("danger", "partial")]
        unknown = [s for s in summaries if s["verdict"] in ("fail", "unknown")]
        print("")
        print(f"{BOLD}═══════════════════════════════════════{NC}")
        if bad:
            print(f"{RED}{BOLD}  РИСК ЕСТЬ: {len(bad)} из {len(summaries)} доменов опасны для iOS{NC}")
            for s in bad:
                print(f"{RED}    ✗ {s['label_name']}{NC}")
            if unknown:
                print(f"{YELLOW}  Без вердикта: {', '.join(s['label_name'] for s in unknown)}{NC}")
        elif unknown:
            print(f"{YELLOW}{BOLD}  БЕЗ ВЕРДИКТА: {len(unknown)} из {len(summaries)}{NC}")
            for s in unknown:
                print(f"{YELLOW}    ? {s['label_name']}{NC}")
        else:
            print(f"{GREEN}{BOLD}  РИСКА НЕТ: все {len(summaries)} доменов безопасны{NC}")
        print(f"{BOLD}═══════════════════════════════════════{NC}")

    return summaries


def _print_banner():
    print("")
    print(f"  {BOLD}{CYAN}🔍 ПРОВЕРКА ПРОКСИ, ДОМЕНА, IP НА PQ-БЕЗОПАСНОСТЬ {VERSION}{NC}")
    print(f"  {DIM}═════════════════════════════════════════════════{NC}")
    print("")
    if not OPENSSL_HAS_PQ:
        if os.path.isfile(OPENSSL_BIN) and os.access(OPENSSL_BIN, os.X_OK):
            try:
                _v = subprocess.run([OPENSSL_BIN, "version"], capture_output=True,
                                    text=True, timeout=5).stdout.strip()
            except (subprocess.SubprocessError, OSError):
                _v = "не запустился"
            print(f"  {YELLOW}{BOLD}⚠️  {OPENSSL_BIN} ({_v}){NC}")
            print(f"  {YELLOW}    не поддерживает {REQUIRED_GROUP}. Результат PQ-проверки{NC}")
            print(f"  {YELLOW}    будет НЕДОСТОВЕРЕН — нужен OpenSSL >= 3.5.{NC}")
            print(f"  {YELLOW}    Свой путь: {_OPENSSL_ENV}=/path/to/openssl{NC}")
        else:
            print(f"  {RED}{BOLD}❌ OpenSSL не найден: {OPENSSL_BIN}{NC}")
            print(f"  {RED}    Проверка TLS/PQ невозможна. Укажите путь: {_OPENSSL_ENV}=/path/to/openssl{NC}")
        print("")
    else:
        print(f"  {DIM}OpenSSL: {OPENSSL_BIN}{NC}")
        print("")
    print("  Как читать результат:")
    print(f"  {RED}{BOLD}ПЛОХОЙ{NC} — домен нельзя использовать, iOS будет блокироваться")
    print(f"  {GREEN}{BOLD}ХОРОШИЙ{NC} — домен безопасен, можно ставить")
    print("")


def _cli_usage():
    print("")
    print(f"  {BOLD}Использование:{NC}")
    print(f"    python3 proxy_checker.py                     интерактивный режим")
    print(f"    python3 proxy_checker.py ozon.ru rutube.ru   проверка списка доменов")
    print(f"    python3 proxy_checker.py --table a.ru b.ru   только таблица, без отчётов")
    print(f"    python3 proxy_checker.py --quiet a.ru b.ru   только итог одной строкой")
    print("")
    print(f"  {BOLD}В интерактивном режиме можно вводить несколько доменов через пробел.{NC}")
    print(f"  {BOLD}Код возврата:{NC} 0 — всё хорошо, 1 — есть риск блокировки, 2 — не проверить")
    print("")


def main():
    args = sys.argv[1:]
    show_table = True
    show_details = True

    # Разбор флагов
    rest = []
    for a in args:
        if a in ("--table", "-t"):
            show_details = False
        elif a in ("--quiet", "-q"):
            show_table = False
            show_details = False
        elif a in ("--full", "-f"):
            global VERBOSE
            VERBOSE = 2
        elif a in ("-h", "--help"):
            _cli_usage()
            sys.exit(0)
        else:
            rest.append(a)

    # ── Пакетный режим ────────────────────────────────────
    if rest:
        targets = split_inputs(rest)
        if not targets:
            _cli_usage()
            sys.exit(2)
        summaries = run_batch(targets, show_table=show_table,
                              show_details=show_details)
        if not summaries:
            sys.exit(2)
        codes = {s["verdict"] for s in summaries}
        if codes & {"danger", "partial"}:
            sys.exit(1)
        if codes & {"fail", "unknown"}:
            sys.exit(2)
        sys.exit(0)

    # ── Интерактивный режим ───────────────────────────────
    if not sys.stdin.isatty():
        print_warning("Нет терминала для интерактивного режима — передайте цели аргументами")
        _cli_usage()
        sys.exit(2)

    while True:
        os.system('clear 2>/dev/null || true' if os.name == 'posix' else 'cls')
        _print_banner()
        print("  Введите домен, IP:port или ссылку на прокси для проверки")
        print(f"  {BOLD}  Можно несколько сразу — через пробел или запятую{NC}")
        print(f"  {DIM}Примеры:{NC}")
        print(f"  {DIM}  • ozon.ru{NC}")
        print(f"  {DIM}  • rutube.ru youtube.com vk.com{NC}")
        print(f"  {DIM}  • 203.0.113.10:443{NC}")
        print(f"  {DIM}  • tg://proxy?server=203.0.113.10&port=443&secret=...{NC}")
        print(f"  {NC}{BOLD}  • 0, n или q — назад в меню{NC}")
        print("")

        try:
            proxy_input = input(f"  {NC}{BOLD}Ввод: {NC}").strip()
        except (EOFError, KeyboardInterrupt):
            print("")
            print_info("Выход.")
            sys.exit(0)

        if proxy_input in ('0', 'n', 'N', 'q', 'Q'):
            print("")
            print_info("Возврат в главное меню...")
            sys.exit(0)

        if not proxy_input:
            print_warning("Введите что-нибудь")
            continue

        targets = split_inputs([proxy_input])
        if not targets:
            print_warning("Не удалось разобрать ввод")
            continue

        try:
            run_batch(targets, show_table=(len(targets) > 1), show_details=True)
        except KeyboardInterrupt:
            print("")
            print_warning("Прервано")

        print("")
        try:
            continue_input = input(f"  {GRAY}Нажмите Enter или 0 для выхода...{NC}").strip()
        except (EOFError, KeyboardInterrupt):
            print("")
            print_info("Выход.")
            sys.exit(0)
        if continue_input in ['0', 'n', 'N', 'q', 'Q']:
            print("")
            print_info("Возврат в главное меню...")
            sys.exit(0)


if __name__ == "__main__":
    main()
