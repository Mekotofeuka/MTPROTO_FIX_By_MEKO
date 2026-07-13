<div align="center">


# MEKO | MTProto Installer, Launcher and fixer
# Терминология

<a href="https://t.me/meko_mtprotofix">
<img width="300" height="300" alt="Без имени-1" src="https://github.com/user-attachments/assets/8decca32-f96a-4b00-9e6c-1bf16bf94d33" />


---
[![Latest Release](https://img.shields.io/github/v/release/Mekotofeuka/MTPROTO_FIX_By_MEKO?color=neon)](https://github.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/releases/latest) [![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE) [![Stars](https://img.shields.io/github/stars/Mekotofeuka/MTPROTO_FIX_By_MEKO?style=social)](https://github.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/stargazers) [![Forks](https://img.shields.io/github/forks/Mekotofeuka/MTPROTO_FIX_By_MEKO?style=social)](https://github.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/network/members) [![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](https://github.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/pulls)
[![Telegram](https://telegram-badge.vercel.app/api/telegram-badge?channelId=@meko_mtprotofix)](https://t.me/meko_mtprotofix)

</div>

<p align="center">
  · <a href="#Быстрый-старт">Установка в 1 клик</a> · <a href="#Как-работает-фикс">Как работает то?</a> · <a href="https://github.com/Mekotofeuka/MTPROTO_FIX_By_MEKO">Вернуться на главну страницу</a> · <a href="https://github.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/blob/main/README_eng.md">English</a> ·
<p align="center">
  · <a href="#Возможные-проблемыпочему-у-меня-может-не-работать">Решение проблем(если не работает ios - прочитай этот пункт!)</a> 
  
</p>

## Основные понятия для чайников

**MTProto** — протокол, используемый Telegram для шифрованного обмена данными между клиентом и сервером.

**MTProto-прокси** — сервер-посредник, который принимает подключения от пользователей и перенаправляет их к серверам Telegram.

**Telemt, MTG, MTProto.zig и тд.** — разные реализации MTProto-прокси на разных языках (Rust, Go, Zig). Все выполняют одну задачу — поднимают прокси для Telegram.

**SYN** — первый пакет в TCP-рукопожатии (трёхэтапное установление соединения). Именно его анализируют системы ограничений трафика.

**MSS (Maximum Segment Size)** — максимальный размер сегмента данных в TCP-пакете. Урезание MSS может быть использовано для починки прокси, но замедляет загрузку медиа.

**Fake TLS** — маскировка прокси-трафика под обычный HTTPS (TLS).

**SelfSteal** — метод, при котором для Fake TLS используется SSL-сертификат реального сайта, подставленный на свой сервер.

**MiddleProxy** — режим работы прокси, при котором он не подключается напрямую к Telegram, а использует промежуточный прокси-сервер. Полезно для серверов в РФ с ограниченным доступом к Telegram.

---

## Термины, связанные с фиксом

**Фикс V1** — Разделение клиентов по портам: на один порт пускаются все устройства с SYN-лимитом 1/сек через DROP, на другой порт — iOS с урезанием MSS.

**Фикс V2** — один порт для всех устройств. iOS определяется по TTL+Length, применяется REJECT вместо DROP, SYN-лимит увеличен до 1.1/сек, отключен MSS.

**Фикс V3** — как **V2**, но iOS определяется по полному отпечатку TCP-пакета (через u32/mangle) вместо TTL+Length. Более точное определение.

**SYN FIX / SYN Limit** — ограничение количества входящих SYN-пакетов с одного IP в секунду.

**REJECT vs DROP** — REJECT мгновенно сообщает клиенту об обрыве соединения (клиент сразу переподключается), DROP просто молча обрывает (клиент ждёт таймаут 3-5 секунд). REJECT быстрее.

**hashlimit** — модуль iptables для ограничения частоты пакетов с возможностью задания лимита в минуту (54/мин = 1.1/сек).

**TTL (Time To Live)** — поле в IP-пакете, указывающее, сколько узлов он может пройти. У iOS и Android/Desktop различается, используется для определения типа устройства.

**u32 (фильтр)** — модуль iptables, позволяющий анализировать произвольные байты в пакете. Используется для определения iOS по отпечатку.

**mangle** — таблица iptables для изменения свойств пакетов (например, маркировки). Используется в V3 для маркировки iOS-пакетов.

**Постквантовый алгоритм X25519 MLKEM768** — современный гибридный алгоритм шифрования, который должен поддерживаться доменом для корректной работы iOS-клиентов с Fake TLS.

**Маркер / SNI-валидность** — проверка, поддерживает ли домен постквантовый алгоритм. Если не поддерживает — iOS-клиенты не смогут подключиться без MSS.

**OpenSSL 3.5+** — версия библиотеки шифрования, необходимая для корректной работы SelfSteal с постквантовой криптографией.

---

## Инструменты и термины проекта

**MEKO Launcher** — Единый лаунчер для управления всеми прокси (Telemt, MTG, MTProto.zig), панелями, установки фикса, настройки и обновления.

**Панель Telemt** — веб-интерфейс (от amirotin) для управления Telemt-сервером: просмотр статуса, пользователей, логов.

**SNI (Server Name Indication)** — расширение TLS, указывающее домен, к которому клиент пытается подключиться.

**Проверка SNI** — функция в проекте, проверяющая домен на поддержку постквантового алгоритма (через бота @Sni_checker_bot или встроенный чекер).

**Caddy** — веб-сервер с автоматическим SSL, альтернатива nginx для SelfSteal (не требует OpenSSL 3.5 на сервере).

**Комбайн** — неофициальный термин в сообществе для проекта, объединяющего несколько прокси и инструментов в одном меню.

---

## Процессы

**TCP-рукопожатие (TCP handshake)** — трёхэтапный процесс установления TCP-соединения (SYN -> SYN-ACK -> ACK).

· <a href="https://github.com/Mekotofeuka/MTPROTO_FIX_By_MEKO">Вернуться на главну страницу</a> ·

**Мёртвое соединение** — Сокет, который сервер держит открытым, но клиент уже не активен (например, при сворачивании приложения). Фикс обрывает такие соединения за 2 минуты вместо нескольких часов простоя.

**Ретраи (Retries)** — повторные попытки подключения после неудачного соединения. REJECT ускоряет их, ускоряя подключение.
