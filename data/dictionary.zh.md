<div align="center">

# MEKO | MTProto 安装、启动与修复工具
# 术语 / 文档

<a href="https://t.me/meko_mtprotofix">
<img width="300" height="300" alt="logo" src="https://github.com/user-attachments/assets/8decca32-f96a-4b00-9e6c-1bf16bf94d33" />
</a>

---
[![最新发布](https://img.shields.io/github/v/release/Mekotofeuka/MTPROTO_FIX_By_MEKO?color=neon)](https://github.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/releases/latest) [![许可证: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE) [![Stars](https://img.shields.io/github/stars/Mekotofeuka/MTPROTO_FIX_By_MEKO?style=social)](https://github.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/stargazers) [![Forks](https://img.shields.io/github/forks/Mekotofeuka/MTPROTO_FIX_By_MEKO?style=social)](https://github.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/network/members) [![PRs 欢迎](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](https://github.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/pulls)
[![Telegram](https://telegram-badge.vercel.app/api/telegram-badge?channelId=@meko_mtprotofix)](https://t.me/meko_mtprotofix)

</div>

<p align="center">
  · <a href="#快速开始">一键安装</a> · <a href="#工作原理">工作原理？</a> · <a href="https://github.com/Mekotofeuka/MTPROTO_FIX_By_MEKO">返回主页</a> · <a href="https://github.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/blob/main/README.md">Русский</a> · <a href="https://github.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/blob/main/README.en.md">English</a> ·
</p>

<p align="center">
  · <a href="#故障排除如果ios不工作请阅读此项">故障排除（如果 iOS 不工作，请阅读此项！）</a> 
</p>

## 目录

- <a href="#给小白的基本概念">给小白的基本概念</a>
- <a href="#修复相关术语">修复相关术语</a>
- <a href="#项目工具与术语">项目工具与术语</a>
- <a href="#进程">进程</a>
- <a href="#后量子加密及其作用">后量子加密及其作用</a>
- <a href="#实用建议">实用建议</a>

## 给小白的基本概念

**MTProto** — Telegram 用于客户端与服务器之间加密数据交换的协议。

**MTProto 代理** — 一个中间服务器，接受用户连接并将其转发到 Telegram 服务器。

**Telemt、MTG、MTProto.zig 等** — 不同语言（Rust、Go、Zig）实现的 MTProto 代理。它们都做同一件事——搭建 Telegram 代理。

**SYN** — **TCP** 三次握手（建立连接的三步过程）中的第一个数据包。

**MSS（最大分段大小）** — TCP 数据包中数据段的最大大小。减小 MSS 可用于修复代理，但会降低媒体加载速度。

**TLS（传输层安全协议）** — 加密协议，确保客户端与服务器之间数据传输的安全。用于 **HTTPS**，防止窃听和篡改。

**Fake TLS（伪 TLS）** — 将代理流量伪装成普通 **HTTPS**（**TLS**）流量。

**SelfSteal（自我窃取）** — 一种方法，将真实网站的 SSL 证书复制到自己的服务器上，用于 Fake TLS。

**MiddleProxy（中间代理）** — 代理的一种工作模式，它不直接连接到 Telegram，而是使用一个中间代理服务器。

---

## 修复相关术语

**IPTables** — Linux 内核中用于管理 Netfilter 防火墙的标准接口。管理员可以定义规则集来过滤、修改和重定向网络数据包。规则按链组织，链按用途分组到表中。

**NFTables** — Linux 内核 Netfilter 子系统中的现代框架，旨在取代旧的 iptables、ip6tables、arptables 和 ebtables 工具。它提供了更灵活、高效、性能更优的数据包过滤、NAT 和其他流量操作方式。与 iptables 不同，nftables 对 IPv4 和 IPv6 使用统一语法，没有预定义的表和链，且性能更高。
_启动器允许在服务器上使用 **iptables** 或 **nftables** 中的任意一种来应用规则，安装时会简要说明可用的选项。_

**修复 V1** — 按端口分离客户端：一个端口允许所有设备，SYN 限制为 1/秒，使用 DROP；另一个端口允许 iOS，并减小 MSS。

**修复 V2（旧版 MEKO 修复）** — 所有设备共用同一端口。通过 TTL+Length 识别 iOS，使用 REJECT 代替 DROP，SYN 限制提高到 1 包/1.1 秒，禁用 MSS。_（**Telemt** 已将该版本的修复整合到自己的项目中。截至 7 月 15 日，他们对它稍作修改，去掉了 TTL 检测，只保留 Length 检测；是否已发布——撰写时未验证。）_

**修复 V3** — 与 **V2** 相同，但 iOS 的识别不再使用 TTL+Length，而是通过完整的 TCP 数据包指纹（通过 u32/mangle）。识别更精确——我们之所以这样做，是因为路径上的负载均衡器可能导致 TTL+Length 检测器误判设备类型，将其送入错误的规则集，从而导致连接该网络的设备被封锁 2 分钟。经过数十次甚至数百次测试，**V3 在 100% 的情况下都能正确识别，而 V2 会根据运营商和地区出现偶发性故障。**
**V3 的规则集**通过 **u32** 检查从 **IP 头**偏移 **32 字节**开始的若干 **TCP 片段**（每个 **4 字节**）。

**修复 V4（Zapret2 MTProto fix by CHKRON）** — 使用数据包操纵器 **nfqws2**（zapret2）的服务端绕过方案。与 V1–V3 限制 SYN 包不同，V4 **主动干预 TCP 握手**：
- 在 SYN+ACK 中压缩 TCP 窗口（`window=1400`），在空 ACK 中压缩（`window=10`），迫使客户端分片 ClientHello；
- 将第一个数据包（ClientHello）分成 **3 段**，将中间段以 **损坏的校验和（badsum）** 发送；
- 客户端重传损坏段 → 连接正常建立。
**iOS 客户端**通过 TCP 指纹识别，跳过干扰（与 **V3** 相同）。
需要安装 **zapret2**（_从 GitHub bol-van/zapret2 自动下载_）。
_默认使用 V3 并推荐安装，因为 **V4** 并非适用于所有人的通用方法，目前处于 **测试和完善阶段**。_

<img width="512" height="261" alt="image" src="https://github.com/user-attachments/assets/00faed12-15ec-4239-a60a-1ccbecd37978" />

<img width="512" height="342" alt="image" src="https://github.com/user-attachments/assets/7fb66f83-1209-4dc9-8a31-827989d65110" />

<img width="512" height="320" alt="image" src="https://github.com/user-attachments/assets/2fbb73f5-475c-460a-85fb-937f6586286f" />

修复的图形化描述（点击图片查看全屏）：
<img width="512" height="890" alt="mermaid" src="https://github.com/user-attachments/assets/bbb2321c-e286-4934-bbe4-46f36ac03836" />

_完整的 IPTABLES、NFTABLES 规则和 zapret2 设置见 [rules.sh](https://github.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/blob/main/data/rules.sh)。_

**SYN FIX / SYN Limit** — 限制每个 IP 每秒入站 SYN 包的数量。

**REJECT 与 DROP** — REJECT 立即通知客户端连接已中断（客户端立即重连），DROP 则默默丢弃（客户端等待 3-5 秒超时）。REJECT 更快。

**hashlimit** — iptables 中用于限制数据包频率的模块。

**TTL（生存时间）** — IP 包中的一个字段，表示它可以经过多少跳。iOS 与 Android/Desktop 的 TTL 不同，用于识别设备类型。

**u32（过滤器）** — iptables 的一个模块，允许分析数据包中的任意字节。在 V3 中用于通过指纹识别 iOS。

**mangle** — iptables 中用于修改数据包属性（如标记）的表。在 V3 中用于标记 iOS 包。

**后量子算法 X25519 MLKEM768** — 一种现代混合加密算法，域名必须支持它，iOS 客户端才能正常使用 Fake TLS。

**标记 / SNI 有效性** — 检查域名是否支持后量子算法。如果不支持，iOS 客户端在没有 MSS 的情况下将无法连接。

**OpenSSL 3.5+** — 加密库的版本，SelfSteal 要正常使用后量子加密必须依赖此版本。

**JA4 / JA4T** — 基于 ClientHello 生成的 TLS 客户端指纹。可以在不解密流量的情况下识别设备类型（iOS/Android/Desktop）和使用的软件（浏览器、Telegram 等）。

**JA3S** — 基于 ServerHello 生成的 TLS 服务器指纹。显示服务器支持的加密算法和密钥组。

**JA4（客户端）与 JA3S（服务器）的匹配** 可发现客户端请求与服务器响应之间的不匹配。

**TLS 握手** — 客户端与服务器之间建立安全连接的过程。包括 ClientHello（客户端提议加密参数）和 ServerHello（服务器选择合适参数）。

**Zapret2** — 一组网络数据包操作工具（**nfqws2**、**tpws**）及其 **Lua** 脚本，可修改 **TCP** 流。

**nfqws2** — 后台程序，从 NFQUEUE（netfilter）拦截数据包，并对其应用 **Lua** 脚本（**disorder**、**badsum**、修改窗口大小等）。

**NFQUEUE** — Linux 内核中的一种机制，允许用户态程序处理由 **nftables**/**iptables** 规则放入队列的数据包。

**out-range** — zapret2 的一个参数，决定哪些出站服务器数据包会被 **Lua** 脚本处理（按包号、字节、序列等）。

**split len** — 使用 **V4** 时，将第一个客户端数据包分片的大小。

**badsum** — 发送带有错误 **TCP** 校验和的数据包。

**disorder** — 一种方法，将 **数据包** 或其片段以乱序（打乱）发送。

**ClientHello** — 客户端在建立 **TLS** 连接时发送给服务器的第一个数据包。

**数据包** — 在网络上传输的数据块。在 TCP/IP 上下文中，包含头部（IP、TCP）和有效载荷（数据）。

---

## 项目工具与术语

**MEKO Launcher** — 统一的启动器，用于管理所有代理（Telemt、MTG、MTProto.zig）、面板、安装修复、配置和更新。

**Telemt 面板** — 一个 Web 界面（由 amirotin 开发），用于管理 Telemt 服务器：查看状态、用户、日志。

**SNI（服务器名称指示）** — TLS 扩展，指示客户端要连接的域名。

**SNI 检查** — 项目中的一项功能，用于检查域名是否支持后量子算法（通过机器人 @Sni_checker_bot 或内置检查器）。

**Nginx** — 高性能 Web 服务器、反向代理、负载均衡器和 HTTP 缓存。在 MTProto 代理的上下文中，它与 **SelfSteal** 配合，将代理伪装成合法的 HTTPS 网站。为了与现代 **iOS** 客户端（需要后量子算法 **X25519MLKEM768**）正常协作，**nginx** 必须使用 **OpenSSL 3.5+** 编译。否则，域名将无法通过 **SNI** 检查，**iOS** 设备将 **无法** 连接到代理。

**Caddy** — 支持自动 SSL 的 Web 服务器，是 nginx 在 SelfSteal 场景下的替代方案（它开箱即用地支持混合加密，无需在服务器上安装 OpenSSL 3.5）。

**组合包** — 社区中对将多个代理和工具集成于一个菜单的项目的非正式称呼。

---

## 进程

**TCP 握手** — 建立 TCP 连接的三步过程（SYN → SYN‑ACK → ACK）。

**死连接** — 服务器保持打开但客户端已不再活跃（例如应用被切到后台）的套接字。修复可使此类连接在 2 分钟内断开，而非闲置数小时。

**重试** — 连接失败后的重试。REJECT 加速了重试，从而加快连接建立。

---

## 代理与现代客户端协作的技术细节

### 后量子加密及其作用

现代 **TLS** 连接基于 **X25519** 密钥交换算法。很长一段时间它都是标准，但随着量子计算的发展，需要更抗量子攻击的算法。为此开发了后量子算法 **ML‑KEM**。

为了确保新旧系统兼容，创建了混合算法 **X25519MLKEM768**，结合了经典 **X25519** 与后量子 **ML‑KEM**。现代客户端（包括 **iOS** 和浏览器）默认会提议使用它。

然而，并非所有服务器都能处理这种请求。这取决于所用库的版本：

- **OpenSSL 低于 3.5** 以及基于它编译的 **nginx** 不 **支持** **X25519MLKEM768**。
- 结果，服务器只能使用经典 **X25519** 响应。
- 现代客户端（**iOS**、浏览器）期望服务器响应混合算法 **X25519MLKEM768**。如果你的 **nginx** 是基于 **OpenSSL 低于 3.5** 编译的，它物理上 **无法** 响应这种请求，因为不理解新格式。于是服务器仅以经典 **X25519** 回复，导致客户端期望与服务器响应之间不匹配。
- **SNI** 检查通过机器人 **@Sni_checker_bot** 或内置检查器执行（检查器需要运行它的服务器上有 **OpenSSL 3.5**）。

要与现代客户端正常配合，有以下几种方案：

- 使用 **Caddy** – 它开箱即用地支持混合加密。
- 安装 **OpenSSL 3.5+** 并重新编译 nginx。
- 使用 **预编译好的 nginx 二进制文件**，已包含 OpenSSL 3.5 支持。
- 使用 **公共域名**，该域名已支持后量子算法（此时代理会代理其响应）。

### 实用建议

1. **如果使用 nginx 做 SelfSteal** – 确保服务器安装了 OpenSSL 3.5+ 并且/或者 nginx 已使用它编译。

2. **nginx 的替代方案** – 使用 Caddy，它开箱即用地支持混合加密。

3. **如果代理在 iOS 上不工作** – 域名不支持后量子算法，服务器仅通过 X25519 响应。请通过检查器检查域名。如果使用 SelfSteal，请确保 OpenSSL 3.5+ 已安装且/或 nginx 基于它编译。

4. **如果域名不支持混合加密但你非用它不可** – 启用 MSS（减小数据包大小），但请注意这会显著降低媒体加载速度。

<a>
<img width="512" height="384" alt="image" src="https://github.com/user-attachments/assets/4932063e-4dd3-4ec8-a2f1-a63c2f77500c" />
</a>

- 以下是一些常见域名，仅供参考。请注意，同一域名可能同时出现在两个列表中，因为对混合加密的支持取决于该域名对应的具体 IP 地址。要正常使用，必须选择 **所有** IP 地址都支持混合加密的域名。（_附注：不要像 AI 建议的那样使用 Cloudflare 的域名——那是个坏主意！所有域名仅供了解。_）：

  ❌ rutube.ru, vk.com, github.com, habr.com, yandex.ru, steamcommunity.com, amazon.com, microsoft.com, amazonaws.com, mail.ru, dzen.ru, linkedin.com, live.com, office.com, amazon.com, azure.com, bing.com, github.com, fastly.net, netflix.com, sharepoint.com, skype.com, gandi.net, cloud.microsoft, yahoo.com, msn.com, tiktok.com, roblox.com, spotify.com, adobe.com, ntp.org, myfritz.net, qq.com, baidu.com, nginx.org, windows.com, yandex.net, tiktokv.com, mozilla.org, nic.ru, opera.com, samsung.com, sentry.io

  ✅ cloudflare.com, rutube.ru, my.aeza.ru, wb.ru, ozon.ru, steamcommunity.com, youtube.com, apple.com, openai.com, anthropic.com, meta.com, facebook.com, x.com, wikipedia.org, stackoverflow.com, rust-lang.org, crates.io, docs.rs, instagram.com, fbcdn.net, twitter.com, googletagmanager.com, whatsapp.net, doubleclick.net, googleusercontent.com, appsflyersdk.com, wordpress.org, digicert.com, youtu.be, pinterest.com, goo.gl, x.com, whatsapp.com, icloud.com, googlesyndication.com, cloudflare.net, googledomains.com, wa.me, chatgpt.com, vimeo.com, zoom.us, workers.dev, cloudflare-dns.com, wordpress.com, reddit.com,

# 如何在俄罗斯直接从服务器运行代理，并使用有效的 MiddleProxy（适用于使用“赞助频道”的用户）

本手册介绍一种方法，可以直接在限制访问 Telegram ME/DC 服务器的服务器上运行代理。适用于 Android/iOS/Desktop。
1. 安装 MEKO 脚本。
2. 安装 MTPROTO ZIG。
3. 通过按钮 **1** 应用修复。
4. 连接到代理并使用。

---

本材料仅供教育和研究用途。作者不对将本信息用于违反俄罗斯联邦及其他国家法律的行为负责。与代理服务器和网络工具设置相关的所有操作必须由用户自行执行，并遵守现行法规。本项目旨在研究网络协议原理、系统管理和提高数字素养。任何商业或非预期用途均由用户自行承担责任。您在此看到的所有内容都是出于对网络的好奇和理解欲望而写，而非为了规避禁令。所有与真实代理服务器的雷同纯属巧合。您懂的。MEKO 并不鼓励任何人违反任何规定。只有知识。只有硬核。

此致，MEKO。并且，不，我还没有被通缉（目前还没有）。

· <a href="https://github.com/Mekotofeuka/MTPROTO_FIX_By_MEKO">返回主页</a> ·
