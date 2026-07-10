<div align="center">
  
# MTPROTO FIX By MEKO 

<img width="300" height="300" alt="Без имени-1" src="https://github.com/user-attachments/assets/8decca32-f96a-4b00-9e6c-1bf16bf94d33" />


---
[![Latest Release](https://img.shields.io/github/v/release/Mekotofeuka/MTPROTO_FIX_By_MEKO?color=neon)](https://github.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/releases/latest) [![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE) [![Stars](https://img.shields.io/github/stars/Mekotofeuka/MTPROTO_FIX_By_MEKO?style=social)](https://github.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/stargazers) [![Forks](https://img.shields.io/github/forks/Mekotofeuka/MTPROTO_FIX_By_MEKO?style=social)](https://github.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/network/members) [![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](https://github.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/pulls)

</div>

<p align="center">
  · <a href="#Быстрый-старт">Установка в 1 клик</a> · <a href="#Как-работает-фикс">Как работает то?</a> · <a href="#Возможные-проблемыпочему-у-меня-может-не-работать">Решение проблем</a> ·
</p>

<div align="center">
  
**Полноценный комбайн для работы с прокси**:

**Позволяет удобно в пару кликов** работать с **TELEMT и MTPROTO.ZIG**, поддерживая большинство необходимых команд для взаимодействия:
Установка, обновление, откат, настройка, изменение конфигов, просмотр логов без ввода каких-либо команд.

⭐️Один из наших старых фиксов взял себе в использование TELEMT⭐️
  
</div>

---

<div align="center">
👇 Проблема? Пиши в чат - подскажем 👇
</div>
<p align="center">
  <a href="https://t.me/meko_mtprotofix">
    <img src="https://github.com/user-attachments/assets/4a2a1ee5-cd30-4714-9a8b-0d02dc8cae1d" width="350" height="130"/>
  </a>
</p>
<div align="center">
☝️P.s. там же сериал по мотивам фикса ☝️
</div>



**Помогает решить в 1 клик проблему**, которая появилась с 4 июня, **когда telegram клиент не может подключиться к mtproto прокси-серверу**. Фикс сделан для серверной стороны и клиентам не нужно ничего ставить/менять

**Признаки**: Подключение может зависать, долго устанавливаться или нестабильно проходить начальный TCP-этап, с дальнейшей блокировкой доступа клиента к серверу на 2 минуты после первого подключения.

 **Проверен на: Telemt 3.4.18 и 3.4.22, MTProto.zig 1.9.0, Mtg, MTProtoProxy, JSMTProxy**

Данный скрипт используется для серверов с MTPROTO - (telemt,mtproto zig и тд.), фиксит проблему долгого первичного TCP-подключения клиентов, в отличие от созданных и популярных в сообществе ранее фиксов с SYN limit **имеет ряд преимуществ**:
- Быстрое подключение за <3-8 сек. (Оригинальный SYN Limit: >10-20сек.) даже при большом количестве юзеров
- **Один порт для Ios/Android/Macos/Desktop** etc.
- Медиа грузят практически с прежней скоростью
-  **Ставится в один клик**
<div align="center">
<img width="550" height="400" alt="image" src="https://github.com/user-attachments/assets/4268e1aa-7941-4676-9f80-13fd2f3b4803" />
<img width="400" height="400" alt="image" src="https://github.com/user-attachments/assets/3296a6c6-c097-4e5a-bd05-7c9f64154f79" />
<img width="400" height="400" alt="image" src="https://github.com/user-attachments/assets/64dd8fe0-c8ee-4b6d-8ee8-b02782f556cd" />

</div>

## Быстрый старт:

**Внимание, данный скрипт платный, цена: 1 ⭐ на репозиторий**

1. **Установить/обновить наш скрипт**:
```Bash
curl -fsSL https://raw.githubusercontent.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/main/install.sh | sudo bash
```
2. **Установить стандартный Telemt** версии 3.4.22 или 3.4.18 и ниже, также **альтернативой** вы можете поставить "**MTPROTO.zig**"
   > (все прокси можно поставить через меню нашего скрипта, ставить их заранее на сервер не обязательно)
4. Применить наш фикс к прокси нажав **[1] Установить SYN FIX** в главном меню
5. **Отключить встроенные MSS и SYN** из конфига телемт нажав **[5]** (если он уже был добавлен в конфиг телемт на сервер ранее)
6. Проверьте SNI через кнопку **[7]** меню, либо через бота @Sni_checker_bot, необходимо подобрать такой домен, который покажет: 🟢 Маркер: НЕТ. В ином случае будут наблюдаться проблемы у пользователей с ios.
7. Если вы используете селфстил, убедитесь что на сервере стоит OpenSSL 3.5 и выше, в противном случае аналогично будут наблюдаться проблемы у пользователей с ios. Если нет возможности поставить OpenSSL 3.5 и выше, тогда воспользуйтесь вместо селфстила любым популярным доменом, который выдаст "🟢 Маркер: НЕТ."
8. Готово.

- **Дополнительно**:
Кнопка **3** выполнит базовую оптимизацию сервера под прокси, в ряде тестов она показала себя лучше - быстрее, стабильнее, менее ресурсозатратно.

**Открыть меню**:
```Bash
mekopr
```

# Как работает фикс:

Применяет к серверу набор правил, который разделяет устройства на 2 вида - **ios** и **не ios** и применяет к каждому свой лимит
- 1 слой - Проверяет является ли устройство ios или нет. 
  - Если да - Оставляем устройство на первом слое и применяем к нему правила конкретно для ios.
  - Если нет - Переходим на второй слой и применяем к нему правила второго слоя для всех устройств.

**Более подробное описание**
- Решает проблему мёртвого соединения Ios/android
  - Проблема: мобильный клиент сворачивается, после чего сокет не закрывается чисто, из-за чего сервер держит мёртвое соединение и при возврате клиент зависает на умершем сокете.
  - Скрипт делает так, чтобы мёртвый коннект рвался за пару минут, вместо нескольких часов. Клиент при возврате из фона сразу видит "сокет мёртв" и переподключается без зависания.
- Решает проблему TCP-рукопожатия, которое режется с помощью технических средств ограничения траффика
  - Скрипт ограничивает частоту входящих SYN на 1.1/сек. с одного IP, так как тех. средства ограничивают TCP соединение только если их >1 в секунду.
- iOS отдельно
  - У iOS в отличии от Android и Desktop разные паттерны подключений. В одном лимите они мешают друг другу. Разделение на порты конечно решение, но костыльное. Наш фикс производит разделение этих клиентов по ios отпечатку,исходя из чего с одного порта могут сидеть клиенты любых устройств без лишней мороки
- 54/minute (а не 1 сек)
  - В iptables модуль hashlimit не поддерживает миллисекунды. 54/минута = 1.1 сек на соединение. Запас в 100 мс нужен, чтобы исключить погрешность возникающую при мгновенном Reject, которая приводит к блокировке подключения с вашего устройства к серверу с mtproto на 2 минуты
- REJECT вместо DROP
  - DROP просто обрывает соединение клиента, не сообщая ему об этом, из-за чего происходят таймауты (3-5 сек) -> ретраи с бОльшими паузами -> бОльшая задержка. REJECT с RST же в свою очередь обрывая соединение даёт мгновенный ответ клиенту об обрыве из-за чего он(клиент) пробует переподключаться без ожидания, из-за чего подключение к telegram происходит куда быстрее
- В MSS просто нет необходимости для данного билда, поэтому в скрипте добавлена функция его отключения. Если вы оставите у себя правило, либо настройку в конфиге с MSS или другим вариантом SYN ограничения, то медиа и скорость так и будут урезаны, так что их рекомендуется закомментировать/удалить с сервера до применения фикса. 

- Условные обозначения для понимания в сообществе:
  - версии старее без обозначений, до вариации разделения по портам
  - V1 фикс(сообщества и реаниматора) - разделение клиентов по портам - все устройства на один порт с SYN лимитом на 1 в сек., через Drop, ios - на другой порт
  - V2 фикс - Использование одного порта с двухэтажным правилом, SYN лимит с заменой DROP на Reject, удаление использования невыгодного MSS, увеличение задержки с 1 на 1.1 сек, разделение пользователей по их TTL + Length, для понимания кто есть ios, а кто - другое устройство для применения к ним соответствующих правил, для ios - accept, для остальных - accept раз в 1.1 сек, иначе - reject
  - V3 фикс - Доработка фикса v2, с заменой определителя с TTL и Length на определение по отпечатку ios устройства, через u32 а также маркирования с помощью mangle, в остальном в целом правило осталось то же.


# Как сделать прокси из РФ напрямую, с работающим MiddleProxy(полезно для тех, кто использует "канал спонсор")

В данном мануале описан способ для запуска прокси напрямую на сервере, доступ с которого к ME/DC серверам телеграм ограничен. Работает с android/ios/desktop
1. Ставим MTPROTO ZIG
```Bash
curl -fsSL https://raw.githubusercontent.com/sleep3r/mtproto.zig/main/deploy/bootstrap.sh | sudo bash
```
```Bash
sudo mtbuddy install --port 443 --domain rutube.ru --no-tcpmss --middle-proxy --yes
```
2. Ставим скрипт MEKO
```Bash
curl -fsSL https://raw.githubusercontent.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/main/install.sh | sudo bash
```
3. Пропускаем информацию про Telemt, открывается меню скрипта, жмём **1** и жмём y
4. Подключаемся к прокси и пользуемся

## Возможные проблемы("почему у меня может не работать?")

- Возможно порт/айпи/подсеть уже были заблокированы ранее и необходимо их заменить(часто не работающий на 443 прокси спокойно работает на 9443 к примеру.)
- При использовании фикса v2, который определяет устройство по TTL + Length подключаясь с ios, соединение проходя от вашего устройства до сервера может пройти через ряд балансировщиков, TTL становится больше указанного лимита, что встречается нередко, из-за чего скрипт в итоге и определяет устройство как десктоп/андроид, а не айфон, в таком случае необходимо использовать фикс v3.
- При использовании любого другого фикса или же v3 варианта, который определяет ios по его полному отпечатку(порядку байтов) или фикса определяющего устройства по TTL+Length, а не лимитируя MSS(разрезая пакеты, что приводит к ухудшении загрузки медиа), необходимо убедиться в том, что домен, используемый для Fake TLS имеет поддержку постквантового гибридного алгоритма обмена ключами, сочетающего классическую эллиптическую кривую, проверить это вы можете с помощью встроенной функции чека домена(работает на ос с OpenSSL 3.5 и выше) либо через бота: @Sni_checker_bot отправив ему домен. Если выбранный домен этого не поддерживает - с огромной вероятностью после попытки подключения с ios прилетит блокировка и подключение не удастся.
  - Ряд популярных доменов, которые имееют и не имееют поддержку данного алгоритма:

  ❌ rutube.ru, vk.com, github.com, habr.com, yandex.ru, steamcommunity.com, amazon.com, microsoft.com, amazonaws.com, mail.ru, dzen.ru, linkedin.com, live.com, office.com, amazon.com, azure.com, bing.com, github.com, fastly.net, netflix.com, sharepoint.com, skype.com, gandi.net, cloud.microsoft, yahoo.com, msn.com, tiktok.com, roblox.com, spotify.com, adobe.com, ntp.org, myfritz.net, qq.com, baidu.com, nginx.org, windows.com, yandex.net, tiktokv.com, mozilla.org, nic.ru, opera.com, samsung.com, sentry.io

  ✅ cloudflare.com, rutube.ru, my.aeza.ru, wb.ru, ozon.ru, steamcommunity.com, youtube.com, apple.com, openai.com, anthropic.com, meta.com, facebook.com, x.com, wikipedia.org, stackoverflow.com, rust-lang.org, crates.io, docs.rs, instagram.com, fbcdn.net, twitter.com, googletagmanager.com, whatsapp.net, doubleclick.net, googleusercontent.com, appsflyersdk.com, wordpress.org, digicert.com, youtu.be, pinterest.com, goo.gl, x.com, whatsapp.com, icloud.com, googlesyndication.com, cloudflare.net, googledomains.com, wa.me, chatgpt.com, vimeo.com, zoom.us, workers.dev, cloudflare-dns.com, wordpress.com, reddit.com, 

## ⭐ Поддержать проект

**MEKO fix** — создан в свободное время для сообщества.  
Ваша поддержка поможет проводить дальнейшие тесты;)

**Вы можете поддержать проект, поставив ⭐ этому репозиторию (сверху справа этой страницы)**

💰 **Криптовалюта:**  

[<img width="300" height="300" alt="image" src="https://github.com/user-attachments/assets/b910c839-ec45-486d-b7f0-05da8de41b74" />
](https://t.me/send?start=IVlaFvgWdkxH)

от **0.1 USDT**

USDT TRC20
```Bash
TGmBaRYmQwSyC6sRaumaMf9CbEuVAk4Eff
```
USDT BEP20
```Bash
0x2AF1581aA7b696Ca28C70B5D29756Da3ca577D65
```

TON(GRAM)
```Bash
UQDdT8vtR5DmbwzNvMUiNQnwxlbkFq4ypE2_UzIm6bQ88DbU
```

BTC
```Bash
bc1qqfkknfrhhufq6dm7cczmdtjkgv56ma3gnz0utk
```

SOL SPL
```Bash
Gn7w3EBkZqPjPDcbkTaxspip42TuhoGqaaEqHAxhG9V1
```

СБП

<img width="300" height="300" alt="dalink-qr-code" src="https://github.com/user-attachments/assets/5ec29f8c-8926-4df1-b031-d4ef768b0cb2" />

https://dalink.to/mekome



Также вы можете поддержать меня, воспользовавшись моим сервисом:

[<img width="300" height="300" alt="MEKO bot" src="https://github.com/user-attachments/assets/8db41a95-79f2-40d6-9777-50b6ffb6fa48" />](https://t.me/projectmeko_bot)



<a href="https://star-history.com/#Mekotofeuka/MTPROTO_FIX_By_MEKO&Date"> 
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=Mekotofeuka/MTPROTO_FIX_By_MEKO&type=Date&theme=dark" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=Mekotofeuka/MTPROTO_FIX_By_MEKO&type=Date" />
   <img alt="Stars History" src="https://api.star-history.com/svg?repos=Mekotofeuka/MTPROTO_FIX_By_MEKO&type=Date" />
 </picture>
</a>




## Отдельное спасибо за вклад в разработку:
[![Contributors](https://contrib.rocks/image?repo=Mekotofeuka/MTPROTO_FIX_By_MEKO)](https://github.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/graphs/contributors)
- [@CryZFix](https://github.com/CryZFix/)
- [@Bxhost](https://github.com/bxhost)
- [@Liafanx](https://github.com/Liafanx)
- https://github.com/Liafanx/MTproxy-reanimation - схожий по функционалу инструмент, отдельное спасибо за определение маркера
- https://assyoucandy.github.io/telemt-server-guide/telemt-keepalive-guide.html
- https://h1de0x.github.io/telemt-tune/

## Оригинальные репозитории прокси
- Telemt https://github.com/telemt/telemt
- Mtproto.zig https://github.com/sleep3r/mtproto.zig
