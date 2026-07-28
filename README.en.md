<div align="center">

# MEKO | VPN and MTProto proxy manager - Installer, Launcher and fixer

<a href="https://t.me/meko_mtprotofix">
<img width="300" height="300" alt="logo" src="https://github.com/user-attachments/assets/8decca32-f96a-4b00-9e6c-1bf16bf94d33" />

---
[![Latest Release](https://img.shields.io/github/v/release/Mekotofeuka/MTPROTO_FIX_By_MEKO?color=neon)](https://github.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/releases/latest) [![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE) [![Stars](https://img.shields.io/github/stars/Mekotofeuka/MTPROTO_FIX_By_MEKO?style=social)](https://github.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/stargazers) [![Forks](https://img.shields.io/github/forks/Mekotofeuka/MTPROTO_FIX_By_MEKO?style=social)](https://github.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/network/members) [![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](https://github.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/pulls)
[![Telegram](https://telegram-badge.vercel.app/api/telegram-badge?channelId=@meko_mtprotofix)](https://t.me/meko_mtprotofix)

</div>

<p align="center">
  · <a href="#quick-start">Install in 1️⃣ click</a> · <a href="#how-the-fix-works">How it works🔧</a> · <a href="https://github.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/blob/main/data/dictionary.md">Documentation & Dictionary for dummies</a> ·
<p align="center">
  · <a href="#possible-issues-why-might-it-not-work">FAQ❓</a> 
  
</p>

<div align="center">
  
**Full‑fledged Manager for VPN and proxies**:

Fixes Telegram MTProto proxies and **allows convenient** work with **TELEMT, MTG and MTPROTO.ZIG**, supporting most necessary commands:
Install, update, rollback, configure, edit configs, view logs, install and work with panels, get connection link – **without typing any commands**.
Also performs all needed functions for VPN panels/nodes.

⭐️ _One of our fixes [old V2 version](https://github.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/blob/main/data/dictionary.md#Термины-связанные-с-фиксом) has already been adopted by TELEMT and Mtproto zig_ ⭐️

_MEKO currently uses the [more accurate V3 version](https://github.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/blob/main/data/dictionary.md#Термины-связанные-с-фиксом)_
</div>

---

<div align="center">
👇 Having trouble? Chat with us – we'll help 👇
</div>
<p align="center">
  <a href="https://t.me/meko_mtprotofix">
    <img src="https://github.com/user-attachments/assets/4a2a1ee5-cd30-4714-9a8b-0d02dc8cae1d" width="350" height="130"/>
  </a>
</p>
<div align="center">
☝️P.s. there's also a series based on the fix ☝️
</div>



**The script solves in 1 click** the problem that appeared since June 4, **when Telegram client cannot connect to MTProto proxy server**. The fix is applied server‑side – clients don't need to install or change anything on their devices.

**Symptoms of this issue**: 
- Connection may hang, take a long time to establish, or fail the initial TCP handshake, followed by a **2‑minute** client access block after first connection.
- "Infinite update" on iOS,
- Media not loading – videos/photos/GIFs/voice messages/stickers.

**Tested on: Telemt 3.4.25, MTProto.zig 1.9.0, Mtg 2.2.8, Erlang mtproto proxy, MTProtoProxy, JSMTProxy**

This script is for servers with MTProto proxies; it fixes slow initial TCP client connections or complete failure (cannot connect to proxy). **Advantages**:
- Fast connection even with many clients and devices on one IP (Wi‑Fi)
- **Single port for all devices: iOS/Android/macOS/Desktop**, etc.
- **Media** loads at full speed
- Correctly detects and applies rules for different devices with **100% accuracy**
- **Installs in one click** with 2 modes: "standard installation" with configurable settings, and "automatic" installation that tells you what it will do and after confirmation does everything for you.

<div align="center">
<img width="300" height="300" alt="image" src="https://github.com/user-attachments/assets/be92a44d-5040-4592-8eda-644d4b182439" />
<img width="300" height="300" alt="image" src="https://github.com/user-attachments/assets/75abab6b-0419-477c-bab3-7dca9694357e" />
<img width="300" height="300" alt="image" src="https://github.com/user-attachments/assets/63b88f4b-3d63-48a2-97a4-0f1b67e96307" />
<img width="300" height="300" alt="image" src="https://github.com/user-attachments/assets/93bf6fbd-db3f-4f93-adb2-0c68c912fcfe" />
<img width="300" height="300" alt="image" src="https://github.com/user-attachments/assets/3296a6c6-c097-4e5a-bd05-7c9f64154f79" />
<img width="300" height="300" alt="image" src="https://github.com/user-attachments/assets/8f07e4ea-3a99-43a4-8232-ad7f7ece634e" />
<img width="300" height="300" alt="image" src="https://github.com/user-attachments/assets/b385ebfd-496c-4fa8-8a95-dff36c3304bd" />
<img width="300" height="300" alt="image" src="https://github.com/user-attachments/assets/f6fa1001-99c3-4ef2-bc52-e678b1c91529" />
</div>

## Quick start:

**Attention, this script is paid; price: 1 ⭐ on the repository**

1. **Install/update our script**:
<pre><code>curl -fsSL https://raw.githubusercontent.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/main/install.sh | sudo bash</code></pre>
2. **Install standard Telemt**, or "**MTPROTO.zig**" or **MTG**
   > (all proxies can be installed via our script menu; you don't need to install them beforehand on the server, and order doesn't matter – proxy first or fix first)
4. Apply the fix to your proxy by pressing **[1] Install SYN FIX** in the main menu
5. **Disable built‑in MSS and SYN** from Telemt config by pressing **[5]** (if it was previously added to the config)
6. Check **SNI** via button **[7]** in menu, or via bot **@Sni_checker_bot** – you must select a domain that shows: 🟢 **Marker: NO**. Otherwise, iOS users will experience problems.
7. If you use SelfSteal, ensure your server has **OpenSSL 3.5** or higher – otherwise, similar iOS issues will occur. If you can't install **OpenSSL 3.5+**, then use any popular domain that shows "🟢 **Marker: NO**" instead of SelfSteal. Alternative solutions are described in the [documentation](https://github.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/blob/main/data/dictionary.md).
8. Done.

- **Additional**:
Button **3** performs basic server optimisation for proxies – in tests it showed better performance: faster, more stable, less resource‑intensive.

**Open menu**:
<pre><code>mekopr</code></pre>

# How the fix works:

Applies a set of rules to the server that splits devices into two types – **ios** and **non‑ios** – and applies different limits to each.

- **Layer 1** – Checks if the device is iOS or not.
  - **If yes** – keeps the device on layer 1 and applies rules specific to iOS.
  - **If no** – moves to layer 2 and applies layer‑2 rules for all non‑iOS devices, limiting SYN to 1 packet per 1.1 sec.

**More detailed description**

- Fixes dead connection issues on **iOS/Android**
  - Problem: mobile client goes to background, socket doesn't close cleanly, so the server holds a dead connection; when the client returns, it hangs on that dead socket.
  - The script makes dead connections break within minutes instead of hours. The client immediately sees "socket dead" on return and reconnects without hanging.

- Fixes **TCP** handshake being cut
  - The script limits incoming SYN frequency to 1 packet per 1.1 sec per **IP**, because the technical means limit TCP connections only if they exceed 1 per second.

- **iOS separately**
  - iOS has different connection patterns compared to Android and Desktop. Mixing them under one limit interferes with each other. Splitting by port is a workaround but clumsy. Our fix separates these clients based on iOS fingerprint, so clients of any device can sit on the same port without extra hassle.

- **54/minute** (not 1 packet per sec)
  - The **iptables** module **hashlimit** does not support milliseconds. 54/minute = 0.9 packets per second per connection (i.e., 1 packet per 1.1 sec). The extra 100 ms reserve eliminates errors caused by instant Reject, which otherwise leads to a 2‑minute block of your device connecting to the MTProto server.

- **REJECT** instead of **DROP**
  - **DROP** simply terminates the client connection without notification, causing timeouts (3‑5 sec) → retries with longer pauses → higher latency. **REJECT** with RST, on the other hand, immediately gives the client a reset response, so the client retries without waiting, resulting in much faster Telegram connection.

- **MSS** is simply unnecessary for this build, so the script includes a function to disable it. If you keep any MSS rule or config setting limiting SYN, media and download speed will be poor – so it's recommended to comment/remove such settings before applying the fix.

**If nothing is clear – go read** <a href="https://github.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/blob/main/data/dictionary.md">Dictionary for dummies</a>, where all terms are explained in plain language along with complete documentation.

## Possible issues ("why might it not work?")

- The port/IP/subnet may have been **blocked** earlier and need to be changed (e.g., a proxy not working on **443** may work fine on **9443**). In that case, no fix will help.
- When using **v2** fix, which identifies device by **TTL + Length**, connecting from **iOS** – the connection may pass through load balancers, increasing **TTL** above the limit, so the script misidentifies the device as desktop/Android instead of iPhone, resulting in a block – in that case **you must use v3 fix**.
- When using the fix without **MSS**, **you must ensure that the domain used for Fake TLS supports X25519 MLKEM768** – you can check this **via the built‑in domain checker** or **via bot: @Sni_checker_bot**. **If the chosen domain does not support it – after an iOS connection attempt you'll get a block and the connection will fail.**
- **If you use SelfSteal instead of a foreign domain**, ensure that your nginx was compiled with OpenSSL 3.5 – **otherwise periodic iOS connection issues will occur**. For proper SelfSteal operation, install **nginx** built with **3.5** or upgrade **OpenSSL** on your server to **3.5** and rebuild **nginx**.
    - Alternative 1: use **caddy**.
    - Alternative 2: enable **MSS**, but then media will load **very slowly**.
- If you enabled **MSS** because your domain doesn't support **X25519MLKEM768** and you can't use another one, and media load slowly – that's expected. MSS reduces packet size, directly affecting download speed.

## ⭐ Support the project

**MEKO Launcher** – created in free time for the community.

**You can support the project by giving a ⭐ to this repository (top‑right corner of this page).**

If you find this project useful and wish to support development, you can send donations to the following crypto wallets:

[<img width="150" height="150" alt="image" src="https://github.com/user-attachments/assets/b910c839-ec45-486d-b7f0-05da8de41b74" />](https://t.me/send?start=IVlaFvgWdkxH)

USDT TRC20 ``` TGmBaRYmQwSyC6sRaumaMf9CbEuVAk4Eff ``` 

USDT BEP20 ```0x2AF1581aA7b696Ca28C70B5D29756Da3ca577D65``` 

TON(GRAM) ``` UQDdT8vtR5DmbwzNvMUiNQnwxlbkFq4ypE2_UzIm6bQ88DbU ``` 

BTC ``` bc1qqfkknfrhhufq6dm7cczmdtjkgv56ma3gnz0utk ``` 

SOL SPL ``` Gn7w3EBkZqPjPDcbkTaxspip42TuhoGqaaEqHAxhG9V1 ``` 

You can also support me by using my service:

[<img width="150" height="150" alt="projectmeko_bot" src="https://github.com/user-attachments/assets/8db41a95-79f2-40d6-9777-50b6ffb6fa48" />](https://t.me/projectmeko_bot)

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
- [@Andycar](https://github.com/Andycar)
- https://github.com/Liafanx/MTproxy-reanimation – similar tool, special thanks for marker detection
- https://assyoucandy.github.io/telemt-server-guide/telemt-keepalive-guide.html
- https://h1de0x.github.io/telemt-tune/

## Original repositories
- Telemt https://github.com/telemt/telemt
- MTG https://github.com/9seconds/mtg
- Mtproto.zig https://github.com/sleep3r/mtproto.zig
- telemt_panel https://github.com/amirotin/telemt_panel
- 3x-ui-pro https://github.com/mozaroc/3x-ui-pro
- remnawave-installer https://github.com/xxphantom/remnawave-installer

> *This is an independent informational review.*
>
> *This post is not an advertisement for VPN, proxy, etc. All material is provided for informational purposes only, and only for citizens of countries where such information is legal – at least for scientific purposes. If you are not allowed to read this – close this page immediately!*
>
> *The author has no intention, does not urge, encourage or justify the use of VPN, proxy or any other software under any circumstances.*
>
> *Responsibility for any reading, usage and operation lies with the user.*
>
> *Disclaimer: the author is not responsible for the actions of third parties and does not encourage illegal use of VPN/proxy or other software.*
>
> *The author is not responsible for the accuracy, completeness or reliability of the published data. All coincidences are accidental. All information is provided "as is" and may not correspond to reality.*
>
> *Use in accordance with local laws.*
>
> *Use VPN and proxy only for lawful purposes: in particular – to ensure your online security and secure remote access, and in no case use this technology to circumvent blocks.*
>
> *The project is non‑commercial, free; all presented "payment" information was found randomly somewhere on the Internet, copied "as is" for demonstration of a possible example and does not belong to the author.*
>
> *Following the advice of the popular repository from Igareck – close this page, delete all VPN, proxy from your computer, install MAX and Yandex on all devices so that it "catches" even in the parking lot, and use only those Internet resources allowed by your ISP, you get the idea.*
