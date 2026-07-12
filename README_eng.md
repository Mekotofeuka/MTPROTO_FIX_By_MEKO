<div align="center">


# MEKO | MTProto Installer, Launcher and fixer

<a href="https://t.me/meko_mtprotofix">
<img width="300" height="300" alt="Без имени-1" src="https://github.com/user-attachments/assets/8decca32-f96a-4b00-9e6c-1bf16bf94d33" />


---
[![Latest Release](https://img.shields.io/github/v/release/Mekotofeuka/MTPROTO_FIX_By_MEKO?color=neon)](https://github.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/releases/latest) [![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE) [![Stars](https://img.shields.io/github/stars/Mekotofeuka/MTPROTO_FIX_By_MEKO?style=social)](https://github.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/stargazers) [![Forks](https://img.shields.io/github/forks/Mekotofeuka/MTPROTO_FIX_By_MEKO?style=social)](https://github.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/network/members) [![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](https://github.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/pulls)

</div>

<p align="center">
  · <a href="#Quick-Start">One‑Click Installation</a> · <a href="#How-the-fix-works">How does it work?</a> · <a href="#Possible-problems-why-might-it-not-work-for-me">Troubleshooting</a> ·
</p>

<div align="center">
  
**A full‑fledged proxy toolkit**:

**Allows you to conveniently work with **TELEMT, MTG and MTPROTO.ZIG** in just a few clicks**, supporting most of the necessary commands for interaction:
Installation, update, rollback, configuration, editing configs, viewing logs, getting a connection link without typing any commands.

⭐️One of our fixes for the old version has already been adopted by TELEMT and Mtproto zig⭐️
  
</div>

---

<div align="center">
👇 Having issues? Write in chat – we'll help 👇
</div>
<p align="center">
  <a href="https://t.me/meko_mtprotofix">
    <img src="https://github.com/user-attachments/assets/4a2a1ee5-cd30-4714-9a8b-0d02dc8cae1d" width="350" height="130"/>
  </a>
</p>
<div align="center">
☝️P.s. there is also a series based on the fix there ☝️
</div>



**Helps to solve in one click the problem** that appeared on June 4, **when the Telegram client cannot connect to the MTProto proxy server**. The fix is made for the server side – clients do not need to install or change anything.

**Symptoms**: The connection may hang, take a long time to establish, or fail during the initial TCP stage, with further blocking of client access to the server for 2 minutes after the first connection attempt.

 **Tested on: Telemt 3.4.18 and 3.4.23, MTProto.zig 1.9.0, Mtg 2.2.8, MTProtoProxy, JSMTProxy**

This script is used for servers running MTPROTO (telemt, mtproto zig, etc.). It fixes the problem of slow initial TCP client connections. Unlike earlier community fixes that used SYN limits, it has **several advantages**:
- Fast connection in <3‑8 sec (original SYN limit: >10‑20 sec) even with a large number of users.
- **One port for iOS/Android/macOS/Desktop** etc.
- Media loads almost at the previous speed.
- **Installs in one click**.
<div align="center">
<img width="550" height="400" alt="image" src="https://github.com/user-attachments/assets/69290da8-c3b3-4961-b584-46a0450159d2" />
<img width="400" height="400" alt="image" src="https://github.com/user-attachments/assets/3296a6c6-c097-4e5a-bd05-7c9f64154f79" />
<img width="400" height="400" alt="image" src="https://github.com/user-attachments/assets/8f07e4ea-3a99-43a4-8232-ad7f7ece634e" />


</div>

## Quick Start:

**Attention, this script is paid – price: 1 ⭐ on the repository**

1. **Install/update our script**:
```Bash
curl -fsSL https://raw.githubusercontent.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/main/install.sh | sudo bash
```
2. **Install standard Telemt** version 3.4.22 or 3.4.18 and below, or as an **alternative** you can install "**MTPROTO.zig**"
   > (all proxies can be installed through our script menu; you don't need to install them on the server beforehand)
4. Apply our fix to the proxy by pressing **[1] Install SYN FIX** in the main menu.
5. **Disable built‑in MSS and SYN** from the Telemt config by pressing **[5]** (if it was already added to the Telemt config on the server earlier).
6. Check SNI via button **[7]** in the menu, or through the bot @Sni_checker_bot. You need to choose a domain that shows: 🟢 Marker: NO. Otherwise, iOS users will experience problems.
7. If you are using SelfSteal, make sure OpenSSL 3.5 or higher is installed on the server; otherwise iOS users will similarly have issues. If you cannot install OpenSSL 3.5 or higher, use any popular domain instead of SelfSteal that returns "🟢 Marker: NO."
8. Done.

- **Additional**:
Button **3** performs basic server optimisation for proxies – in several tests it performed better (faster, more stable, less resource‑intensive).

**Open the menu**:
```Bash
mekopr
```

# How the fix works:

Applies a set of rules to the server that divides devices into two types – **iOS** and **non‑iOS** – and applies a different limit to each.
- Layer 1 – Checks whether the device is iOS or not.
  - If yes – Keep the device on the first layer and apply rules specifically for iOS.
  - If no – Move to the second layer and apply rules of the second layer for all other devices.

**More detailed description**
- Fixes the dead connection problem for iOS/Android
  - Problem: The mobile client is minimised, after which the socket is not closed cleanly, so the server holds a dead connection, and upon returning the client gets stuck on the dead socket.
  - The script makes the dead connection break within a couple of minutes instead of several hours. When the client returns from the background, it immediately sees "socket dead" and reconnects without freezing.
- Fixes the TCP handshake problem that is cut off by traffic‑shaping tools
  - The script limits the incoming SYN frequency to 1.1/sec per IP, because traffic‑shaping tools limit TCP connections only if they exceed 1 per second.
- iOS separately
  - iOS has different connection patterns compared to Android and Desktop. In one limit they interfere with each other. Port separation is a solution, but a kludge. Our fix separates these clients based on the iOS fingerprint, so clients of any device can sit on one port without extra hassle.
- 54/minute (instead of 1 sec)
  - The iptables hashlimit module does not support milliseconds. 54/minute = 1.1 sec per connection. A margin of 100 ms is needed to eliminate the error that occurs with an immediate Reject, which leads to a 2‑minute block of connection from your device to the MTProto server.
- REJECT instead of DROP
  - DROP just kills the client connection without notifying it, causing timeouts (3‑5 sec) → retries with longer pauses → higher latency. REJECT with RST, on the other hand, immediately responds to the client that the connection is broken, so the client tries to reconnect without waiting, making the connection to Telegram much faster.
- MSS is simply not needed for this build, so the script includes a function to disable it. If you leave a rule or config setting with MSS or another SYN limiting option, media and speed will still be reduced, so it is recommended to comment out/delete them from the server before applying the fix.

- Symbols for understanding in the community:
  - older versions without labels, before port‑based separation
  - V1 fix (community and reanimation) – client separation by ports – all devices on one port with a SYN limit of 1/sec via DROP, iOS on another port
  - V2 fix – using one port with a two‑layer rule, SYN limit with DROP replaced by Reject, removal of disadvantageous MSS, increase of delay from 1 to 1.1 sec, separation of users by their TTL + Length to determine who is iOS and who is another device, for iOS – accept, for the rest – accept once per 1.1 sec, otherwise – reject
  - V3 fix – refinement of V2, replacing the TTL+Length detector with detection by iOS device fingerprint via u32 and also marking with mangle, otherwise the rule remains generally the same.


# How to set up a proxy from Russia directly, with working MiddleProxy (useful for those using a "sponsor channel")

This manual describes a way to run a proxy directly on a server that has restricted access to Telegram ME/DC servers. Works with Android/iOS/Desktop.
1. Install MTPROTO ZIG
```Bash
curl -fsSL https://raw.githubusercontent.com/sleep3r/mtproto.zig/main/deploy/bootstrap.sh | sudo bash
```
```Bash
sudo mtbuddy install --port 443 --domain rutube.ru --no-tcpmss --middle-proxy --yes
```
2. Install the MEKO script
```Bash
curl -fsSL https://raw.githubusercontent.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/main/install.sh | sudo bash
```
3. Skip the Telemt info, the script menu opens, press **1** and press y
4. Connect to the proxy and use it.

## Possible problems ("why might it not work for me?")

- Perhaps the port/IP/subnet has already been blocked before and you need to replace them (often a proxy that does not work on 443 works fine on 9443, for example).
- When using the V2 fix, which identifies the device by TTL+Length, when connecting from iOS, the connection from your device to the server may pass through several load balancers, increasing the TTL beyond the specified limit – this happens quite often, causing the script to identify the device as desktop/Android instead of iPhone. In that case, you need to use the V3 fix.
- When using any other fix or the V3 variant, which identifies iOS by its full fingerprint (byte order) or a fix identifying devices by TTL+Length (instead of limiting MSS, which cuts packets and worsens media loading), you need to make sure that the domain used for Fake TLS supports the post‑quantum hybrid key exchange algorithm that combines a classic elliptic curve. You can check this using the built‑in domain check function (works on OS with OpenSSL 3.5 or higher) or via the bot: @Sni_checker_bot by sending it the domain. If the chosen domain does not support this – with a very high probability, after an iOS connection attempt you will get blocked and the connection will fail.
  - A list of popular domains that do and do not support this algorithm:

  ❌ rutube.ru, vk.com, github.com, habr.com, yandex.ru, steamcommunity.com, amazon.com, microsoft.com, amazonaws.com, mail.ru, dzen.ru, linkedin.com, live.com, office.com, amazon.com, azure.com, bing.com, github.com, fastly.net, netflix.com, sharepoint.com, skype.com, gandi.net, cloud.microsoft, yahoo.com, msn.com, tiktok.com, roblox.com, spotify.com, adobe.com, ntp.org, myfritz.net, qq.com, baidu.com, nginx.org, windows.com, yandex.net, tiktokv.com, mozilla.org, nic.ru, opera.com, samsung.com, sentry.io

  ✅ cloudflare.com, rutube.ru, my.aeza.ru, wb.ru, ozon.ru, steamcommunity.com, youtube.com, apple.com, openai.com, anthropic.com, meta.com, facebook.com, x.com, wikipedia.org, stackoverflow.com, rust-lang.org, crates.io, docs.rs, instagram.com, fbcdn.net, twitter.com, googletagmanager.com, whatsapp.net, doubleclick.net, googleusercontent.com, appsflyersdk.com, wordpress.org, digicert.com, youtu.be, pinterest.com, goo.gl, x.com, whatsapp.com, icloud.com, googlesyndication.com, cloudflare.net, googledomains.com, wa.me, chatgpt.com, vimeo.com, zoom.us, workers.dev, cloudflare-dns.com, wordpress.com, reddit.com,

- If you are using the SelfSteal variant instead of a popular domain, make sure that your nginx was compiled with OpenSSL 3.5 (if you built it on your server, check which version you have installed), otherwise you will experience intermittent iOS connection issues. For SelfSteal to work correctly, install nginx built with 3.5 or update OpenSSL on your server to 3.5 and rebuild nginx.
    - Alternative 1: use Caddy.
    - Alternative 2: use MSS, but then media will not load properly.

## ⭐ Support the project

**MEKO fix** – created in free time for the community.  
Your support will help us conduct further tests ;)

**You can support the project by giving ⭐ to this repository (top right of this page)**

💰 **Cryptocurrency:**  

[<img width="300" height="300" alt="image" src="https://github.com/user-attachments/assets/b910c839-ec45-486d-b7f0-05da8de41b74" />
](https://t.me/send?start=IVlaFvgWdkxH)

from **0.1 USDT**

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

You can also support me by using my service:

[<img width="300" height="300" alt="MEKO bot" src="https://github.com/user-attachments/assets/8db41a95-79f2-40d6-9777-50b6ffb6fa48" />](https://t.me/projectmeko_bot)


dalink.to/mekome



<a href="https://www.star-history.com/?type=date&repos=Mekotofeuka%2FMTPROTO_FIX_By_MEKO">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=Mekotofeuka/MTPROTO_FIX_By_MEKO&type=date&theme=dark&legend=top-left&sealed_token=7QCqNRNApwLOeL40L6S8sUAHUyTcivBId5b6sO3nVG4PMXG411eamYd49VpVN2Ha4cmAbIyMdeE3IKDUAyimSorKjMDcAf9Ryrh0nLzEpBQILeuxKQLZlg" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=Mekotofeuka/MTPROTO_FIX_By_MEKO&type=date&legend=top-left&sealed_token=7QCqNRNApwLOeL40L6S8sUAHUyTcivBId5b6sO3nVG4PMXG411eamYd49VpVN2Ha4cmAbIyMdeE3IKDUAyimSorKjMDcAf9Ryrh0nLzEpBQILeuxKQLZlg" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=Mekotofeuka/MTPROTO_FIX_By_MEKO&type=date&legend=top-left&sealed_token=7QCqNRNApwLOeL40L6S8sUAHUyTcivBId5b6sO3nVG4PMXG411eamYd49VpVN2Ha4cmAbIyMdeE3IKDUAyimSorKjMDcAf9Ryrh0nLzEpBQILeuxKQLZlg" />
 </picture>
</a>




## Special thanks for contributions:
[![Contributors](https://contrib.rocks/image?repo=Mekotofeuka/MTPROTO_FIX_By_MEKO)](https://github.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/graphs/contributors)
- [@CryZFix](https://github.com/CryZFix/)
- [@Bxhost](https://github.com/bxhost)
- [@Liafanx](https://github.com/Liafanx)
- https://github.com/Liafanx/MTproxy-reanimation – a similar tool, special thanks for the marker detection
- https://assyoucandy.github.io/telemt-server-guide/telemt-keepalive-guide.html
- https://h1de0x.github.io/telemt-tune/

## Original proxy repositories
- Telemt https://github.com/telemt/telemt
- Mtproto.zig https://github.com/sleep3r/mtproto.zig
