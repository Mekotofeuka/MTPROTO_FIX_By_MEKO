# Информация о форке

Upstream-проект: [Mekotofeuka/MTPROTO_FIX_By_MEKO](https://github.com/Mekotofeuka/MTPROTO_FIX_By_MEKO).

Эта ветка основана непосредственно на `upstream/main` и сохраняет историю,
авторство, исходные файлы и лицензию MEKO. Собственные изменения находятся в
отдельных файлах:

- `install-random-port.sh` — неинтерактивная установка на случайном порту;
- `README-AUTO-RU.md` — документация дополнения;
- `THIRD_PARTY_NOTICES.md` — сведения об исходных проектах;
- `.github/workflows/random-port-shellcheck.yml` — проверка дополнения.

Оригинальный `install.sh` и остальные файлы upstream не заменяются.

## Настройка upstream после клонирования форка

```bash
git remote add upstream https://github.com/Mekotofeuka/MTPROTO_FIX_By_MEKO.git
git fetch upstream
```

## Получение обновлений оригинального проекта

Рабочие изменения дополнения рекомендуется вести в отдельной feature-ветке:

```bash
git fetch upstream
git rebase upstream/main
```

При конфликтах нельзя удалять уведомления об авторских правах или заменять
лицензию оригинального проекта.
