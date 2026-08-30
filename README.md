# Автоматическая установка MTProto-прокси

Небольшое дополнение к проекту
[MTPROTO_FIX_By_MEKO](https://github.com/Mekotofeuka/MTPROTO_FIX_By_MEKO).

Скрипт устанавливает Telemt с SYN-фиксом MEKO V3 и выбирает случайный
свободный порт. Порт 443 не используется и не изменяется.

Поддерживаются Ubuntu 24.x–26.x, x86_64 и arm64.

## Установка

```bash
curl -fsSL https://raw.githubusercontent.com/icelol/MTPROTO_FIX_By_MEKO/main/install-random-port.sh | sudo bash
```

После успешной установки выводится готовая ссылка для Telegram:

```text
tg://proxy?server=IP&port=PORT&secret=SECRET
```

Повторный запуск возвращает действующую ссылку без изменения порта и секрета.

Оригинальный проект и правила MEKO:
[Mekotofeuka/MTPROTO_FIX_By_MEKO](https://github.com/Mekotofeuka/MTPROTO_FIX_By_MEKO).
