<div align="center">

# MEKO | MTProto Installer, Launcher and fixer
# Terminology / Documentation

<a href="https://t.me/meko_mtprotofix">
<img width="300" height="300" alt="logo" src="https://github.com/user-attachments/assets/8decca32-f96a-4b00-9e6c-1bf16bf94d33" />
</a>

---
[![Latest Release](https://img.shields.io/github/v/release/Mekotofeuka/MTPROTO_FIX_By_MEKO?color=neon)](https://github.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/releases/latest) [![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE) [![Stars](https://img.shields.io/github/stars/Mekotofeuka/MTPROTO_FIX_By_MEKO?style=social)](https://github.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/stargazers) [![Forks](https://img.shields.io/github/forks/Mekotofeuka/MTPROTO_FIX_By_MEKO?style=social)](https://github.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/network/members) [![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](https://github.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/pulls)
[![Telegram](https://telegram-badge.vercel.app/api/telegram-badge?channelId=@meko_mtprotofix)](https://t.me/meko_mtprotofix)

</div>

<p align="center">
  · <a href="#quick-start">Install in 1 click</a> · <a href="#how-it-works">How does it work?</a> · <a href="https://github.com/Mekotofeuka/MTPROTO_FIX_By_MEKO">Back to main page</a> · <a href="https://github.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/blob/main/README.md">Русский</a> · <a href="https://github.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/blob/main/README.zh.md">中文</a> ·
</p>

<p align="center">
  · <a href="#troubleshooting-ios-issues-read-this">Troubleshooting (if iOS does not work – read this!)</a> 
</p>

## Table of Contents

- <a href="#basic-concepts-for-dummies">Basic concepts for dummies</a>
- <a href="#terms-related-to-the-fix">Terms related to the fix</a>
- <a href="#project-tools-and-terms">Project tools and terms</a>
- <a href="#processes">Processes</a>
- <a href="#post-quantum-encryption-and-its-role">Post‑quantum encryption and its role</a>
- <a href="#practical-recommendations">Practical recommendations</a>

## Basic concepts for dummies

**MTProto** — the protocol used by Telegram for encrypted data exchange between client and server.

**MTProto proxy** — an intermediary server that accepts connections from users and forwards them to Telegram servers.

**Telemt, MTG, MTProto.zig, etc.** — different implementations of MTProto proxies in various languages (Rust, Go, Zig). All do the same job — run a proxy for Telegram.

**SYN** — the first packet in the **TCP** three‑way handshake.

**MSS (Maximum Segment Size)** — the maximum size of data segment in a TCP packet. Reducing MSS may be used to fix the proxy but slows down media loading.

**TLS (Transport Layer Security)** — encryption protocol that ensures secure data transfer between client and server. Used for **HTTPS**, protects against eavesdropping and tampering.

**Fake TLS** — masking proxy traffic as regular **HTTPS** (**TLS**).

**SelfSteal** — a method where the SSL certificate of a real website is used for Fake TLS on your own server.

**MiddleProxy** — a proxy mode where it does not connect directly to Telegram but uses an intermediate proxy server.

---

## Terms related to the fix

**IPTables** — a utility that serves as the standard interface for managing the Netfilter firewall in the Linux kernel. It allows administrators to define sets of rules for filtering, modifying, and redirecting network packets. Rules are organised into chains, grouped into tables by purpose.

**NFTables** — a modern framework within the Linux kernel’s Netfilter subsystem, designed to replace the legacy iptables, ip6tables, arptables, and ebtables tools. It provides a more flexible, efficient, and performant way to filter packets, perform NAT, and other traffic manipulations. Unlike iptables, nftables uses a unified syntax for IPv4 and IPv6, has no predefined tables and chains, and achieves higher performance.
_The launcher allows using either suitable option for applying rules on the server – both **iptables** and **nftables** – and briefly describes available options during installation._

**Fix V1** — client separation by ports: one port allows all devices with a SYN limit of 1/sec via DROP, another port allows iOS with MSS reduction.

**Fix V2 (Old MEKO FIX)** — a single port for all devices. iOS is detected by TTL+Length, REJECT is used instead of DROP, SYN limit increased to 1 packet per 1.1 sec, MSS disabled. _(**Telemt** incorporated our fix of this version. As of 15.07, they slightly modified it by removing TTL tracking and keeping only Length detection; whether they released it – not checked at the time of writing.)_

**Fix V3** — same as **V2**, but iOS is detected by the full TCP packet fingerprint (via u32/mangle) instead of TTL+Length. More accurate detection – we made it because load balancers along the path could cause the TTL+Length detector to misidentify a device, sending it to the wrong rule set, resulting in a 2‑minute ban on the network from which the device connected. Tested on dozens and hundreds of tests – **V3 works in 100% of cases, V2 shows occasional failures depending on operators and regions.**
The **rule set** of **V3** checks several TCP fragments (**4 bytes each**) via **u32** starting at an offset of **32 bytes** from the beginning of the **IP header**.

**Fix V4 (Zapret2 MTProto fix by CHKRON)** — server‑side bypass using the packet manipulator **nfqws2** (zapret2). Unlike V1–V3 which limit SYN packets, V4 **actively interferes with the TCP handshake**:  
- reduces TCP window in SYN+ACK (`window=1400`) and in empty ACK (`window=10`), forcing the client to fragment ClientHello;  
- splits the first data packet (ClientHello) into **3 parts**, sending the middle part with a **corrupted checksum (badsum)**;  
- the client retransmits the broken part → the connection establishes normally.  
**iOS clients** are identified by TCP fingerprint and are passed without interference (as in **V3**).  
Requires **zapret2** installation (_automatically downloaded from GitHub bol-van/zapret2_).  
_V3 is used by default and recommended, as **V4** is **not** a universal method that works for everyone and is at the **testing and refinement stage**._

<img width="512" height="261" alt="image" src="https://github.com/user-attachments/assets/00faed12-15ec-4239-a60a-1ccbecd37978" />

<img width="512" height="342" alt="image" src="https://github.com/user-attachments/assets/7fb66f83-1209-4dc9-8a31-827989d65110" />

<img width="512" height="320" alt="image" src="https://github.com/user-attachments/assets/2fbb73f5-475c-460a-85fb-937f6586286f" />

Graphical description of the fix (click the image to view full screen):
<img width="512" height="890" alt="mermaid" src="https://github.com/user-attachments/assets/bbb2321c-e286-4934-bbe4-46f36ac03836" />

_Full IPTABLES, NFTABLES rules and zapret2 settings are defined in [rules.sh](https://github.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/blob/main/data/rules.sh)._

**SYN FIX / SYN Limit** — limiting the number of incoming SYN packets per second from a single IP.

**REJECT vs DROP** — REJECT immediately notifies the client of a connection abort (client reconnects instantly), DROP silently drops (client waits for a timeout of 3‑5 seconds). REJECT is faster.

**hashlimit** — an iptables module for packet rate limiting.

**TTL (Time To Live)** — a field in the IP packet indicating how many hops it can traverse. Differs between iOS and Android/Desktop, used for device type detection.

**u32 (filter)** — an iptables module that allows analysing arbitrary bytes in a packet. Used in V3 to detect iOS by fingerprint.

**mangle** — an iptables table for modifying packet properties (e.g., marking). Used in V3 to mark iOS packets.

**Post‑quantum algorithm X25519 MLKEM768** — a modern hybrid encryption algorithm that a domain must support for iOS clients to work correctly with Fake TLS.

**Marker / SNI validity** — a check whether the domain supports the post‑quantum algorithm. If it does not, iOS clients will not be able to connect without MSS.

**OpenSSL 3.5+** — the encryption library version required for SelfSteal to work correctly with post‑quantum cryptography.

**JA4 / JA4T** — TLS client fingerprint derived from its ClientHello. Allows identifying the device type (iOS/Android/Desktop) and the software used (browser, Telegram, etc.) without decrypting traffic.

**JA3S** — TLS server fingerprint derived from its ServerHello. Shows which encryption algorithms and key groups the server supports.

**Matching JA4 (client) with JA3S (server)** allows detecting mismatches between what the client requests and what the server responds.

**TLS handshake** — the process of establishing a secure connection between client and server. Includes exchanging ClientHello (client proposes encryption parameters) and ServerHello (server selects the suitable ones).

**Zapret2** — a set of utilities for network packet manipulation (**nfqws2**, **tpws**) with **Lua** scripts, allowing modification of **TCP** streams.

**nfqws2** — a background program that intercepts packets from NFQUEUE (netfilter) and applies **Lua** scripts (**disorder**, **badsum**, window size modification) to them.

**NFQUEUE** — a mechanism in the **Linux** kernel that allows user‑space programs to process packets that have been queued from **nftables**/**iptables** rules.

**out‑range** — a zapret2 parameter that defines which outgoing server packets are processed by the **Lua** script (by packet number, bytes, sequence, etc.).

**split len** — the size of each part into which the first client **data** packet is split when using **V4**.

**badsum** — sending a packet with an incorrect **TCP** checksum.

**disorder** — a method where **packets** or their fragments are sent out of order (shuffled).

**ClientHello** — the first packet the client sends to the server when establishing a **TLS** connection.

**Packet** — a block of data transmitted over the network. In the TCP/IP context, it contains headers (IP, TCP) and payload (data).

---

## Project tools and terms

**MEKO Launcher** — a unified launcher for managing all proxies (Telemt, MTG, MTProto.zig), panels, installing the fix, configuration, and updates.

**Telemt Panel** — a web interface (by amirotin) for managing the Telemt server: status viewing, users, logs.

**SNI (Server Name Indication)** — a TLS extension indicating the domain the client is trying to connect to.

**SNI Check** — a function in the project that checks a domain for post‑quantum algorithm support (via the bot @Sni_checker_bot or built‑in checker).

**Nginx** — a high‑performance web server, reverse proxy, load balancer, and HTTP cache. In the context of MTProto proxies, it is used with **SelfSteal** to disguise the proxy as a legitimate HTTPS site. To work correctly with modern **iOS** clients that require the post‑quantum **X25519MLKEM768** algorithm, **nginx** must be compiled with **OpenSSL 3.5+**. Otherwise, the domain will not pass the **SNI** check and **iOS** devices will **not** be able to connect to the proxy.

**Caddy** — a web server with automatic SSL, an alternative to nginx for SelfSteal (does not require OpenSSL 3.5 on the server because it supports hybrid encryption out of the box).

**Combo** — an informal term in the community for a project that combines several proxies and tools in one menu.

---

## Processes

**TCP handshake** — a three‑step process to establish a TCP connection (SYN → SYN‑ACK → ACK).

**Dead connection** — a socket that the server keeps open while the client is no longer active (e.g., after minimising the app). The fix breaks such connections within 2 minutes instead of hours of idle.

**Retries** — repeated connection attempts after a failed connection. REJECT accelerates them, speeding up the connection.

---

## Technical aspects of proxy operation with modern clients

### Post‑quantum encryption and its role

Modern **TLS** connections are based on the **X25519** key exchange algorithm. For a long time it was the standard, but with the development of quantum computing, more resilient algorithms became necessary. For this purpose, the post‑quantum algorithm **ML‑KEM** was developed.

To ensure compatibility between old and new systems, a **hybrid algorithm X25519MLKEM768** was created, combining classical **X25519** and post‑quantum **ML‑KEM**. Modern clients (including **iOS** and browsers) offer it by default.

However, not all servers can handle such a request. This depends on the version of the libraries used:

- **OpenSSL below 3.5** and **nginx** built on it do **not** support **X25519MLKEM768**.
- As a result, the server can only respond using the classic **X25519**.
- Modern clients (**iOS**, browsers) expect a response with the hybrid **X25519MLKEM768**. If your **nginx** is built on **OpenSSL** below **3.5**, it physically **cannot** respond to such a request because it does not understand the new format. Consequently, the server replies only with classic **X25519**, creating a mismatch between client expectation and server response.
- **SNI** checking is performed via the bot **@Sni_checker_bot** or the built‑in checker (which requires **OpenSSL 3.5** on the server where the check is executed).

For correct operation with modern clients, there are several solutions:

- Use **Caddy** – it supports hybrid encryption out of the box.
- Install **OpenSSL 3.5+** and rebuild nginx with it.
- Use a **pre‑built nginx binary** that already includes OpenSSL 3.5 support.
- Use a **public domain** that already supports the post‑quantum algorithm (in that case, the proxy will proxy its response).

### Practical recommendations

1. **If using nginx** for SelfSteal – ensure your server has OpenSSL 3.5+ and/or nginx was compiled with its support.

2. **Alternative to nginx** – use Caddy, which works with hybrid encryption out of the box.

3. **If the proxy does not work on iOS** – the domain does not support the post‑quantum algorithm, and the server responds via X25519. Check the domain via the checker. If using SelfSteal, ensure OpenSSL 3.5+ is present and/or nginx is built with it.

4. **If the domain does not support hybrid encryption but you must use it** – enable MSS (reduce packet size), but note that this will significantly slow media loading.

<a>
<img width="512" height="384" alt="image" src="https://github.com/user-attachments/assets/4932063e-4dd3-4ec8-a2f1-a63c2f77500c" />
</a>

- Below are some popular domains for reference. Note that the same domain may appear in both lists because support for hybrid encryption depends on the specific IP address of the server behind the domain. For correct operation, you must use domains where **all** IP addresses support hybrid encryption. (_P.S. Do not use a Cloudflare domain as AI suggests – that is a bad idea! All domains are for reference only._):

  ❌ rutube.ru, vk.com, github.com, habr.com, yandex.ru, steamcommunity.com, amazon.com, microsoft.com, amazonaws.com, mail.ru, dzen.ru, linkedin.com, live.com, office.com, amazon.com, azure.com, bing.com, github.com, fastly.net, netflix.com, sharepoint.com, skype.com, gandi.net, cloud.microsoft, yahoo.com, msn.com, tiktok.com, roblox.com, spotify.com, adobe.com, ntp.org, myfritz.net, qq.com, baidu.com, nginx.org, windows.com, yandex.net, tiktokv.com, mozilla.org, nic.ru, opera.com, samsung.com, sentry.io

  ✅ cloudflare.com, rutube.ru, my.aeza.ru, wb.ru, ozon.ru, steamcommunity.com, youtube.com, apple.com, openai.com, anthropic.com, meta.com, facebook.com, x.com, wikipedia.org, stackoverflow.com, rust-lang.org, crates.io, docs.rs, instagram.com, fbcdn.net, twitter.com, googletagmanager.com, whatsapp.net, doubleclick.net, googleusercontent.com, appsflyersdk.com, wordpress.org, digicert.com, youtu.be, pinterest.com, goo.gl, x.com, whatsapp.com, icloud.com, googlesyndication.com, cloudflare.net, googledomains.com, wa.me, chatgpt.com, vimeo.com, zoom.us, workers.dev, cloudflare-dns.com, wordpress.com, reddit.com,

# How to run a proxy from Russia directly with a working MiddleProxy (useful for those using a "sponsor channel")

This manual describes a method to run a proxy directly on a server that has restricted access to Telegram’s ME/DC servers. Works with Android/iOS/Desktop.
1. Install the MEKO script.
2. Install MTPROTO ZIG.
3. Apply the fix via button **1**.
4. Connect to the proxy and use it.

---

This material is provided for educational and research purposes only. The author is not responsible for the use of this information for purposes contrary to the laws of the Russian Federation and other countries. All actions related to setting up proxy servers and network tools must be performed by the user independently, taking into account current regulations. The project is created to study the principles of network protocols, system administration, and to improve digital literacy. Any commercial or unintended use is at the user’s discretion. Everything you see here is written out of curiosity and a desire to understand networks, not to circumvent prohibitions. All coincidences with real proxy servers are accidental. You get the idea. MEKO does not urge anyone to violate anything. Only knowledge. Only hardcore.

With respect, MEKO. And no, I am not wanted (yet).

· <a href="https://github.com/Mekotofeuka/MTPROTO_FIX_By_MEKO">Back to main page</a> ·
