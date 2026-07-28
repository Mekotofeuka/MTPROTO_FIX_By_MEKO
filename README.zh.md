<div align="center">

# MEKO | VPN 和 MTProto 代理管理器 - 安装、启动与修复工具

<a href="https://t.me/meko_mtprotofix">
<img width="300" height="300" alt="logo" src="https://github.com/user-attachments/assets/8decca32-f96a-4b00-9e6c-1bf16bf94d33" />

---
[![最新发布](https://img.shields.io/github/v/release/Mekotofeuka/MTPROTO_FIX_By_MEKO?color=neon)](https://github.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/releases/latest) [![许可证: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE) [![Stars](https://img.shields.io/github/stars/Mekotofeuka/MTPROTO_FIX_By_MEKO?style=social)](https://github.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/stargazers) [![Forks](https://img.shields.io/github/forks/Mekotofeuka/MTPROTO_FIX_By_MEKO?style=social)](https://github.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/network/members) [![PRs 欢迎](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](https://github.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/pulls)
[![Telegram](https://telegram-badge.vercel.app/api/telegram-badge?channelId=@meko_mtprotofix)](https://t.me/meko_mtprotofix)

</div>

<p align="center">
  · <a href="#快速开始">一键安装</a> · <a href="#修复原理">工作原理🔧</a> · <a href="https://github.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/blob/main/data/dictionary.md">给小白看的文档与词典</a> · <a href="https://github.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/blob/main/README.md">Русский</a> · <a href="https://github.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/blob/main/README.en.md">English</a> ·
<p align="center">
  · <a href="#可能的问题为什么可能不工作">常见问题❓</a> 
  
</p>

<div align="center">
  
**全功能 VPN 与代理管理器**：

修复 Telegram MTProto 代理，并**方便地**管理 **TELEMT、MTG 和 MTPROTO.ZIG**，支持绝大多数常用操作：
安装、更新、回滚、配置、修改配置、查看日志、安装和使用面板、获取连接链接——**无需输入任何命令**。
同时还能完成 VPN 面板/节点所需的所有功能。

⭐️ _我们的某个修复方案 [旧版 V2](https://github.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/blob/main/data/dictionary.md#Термины-связанные-с-фиксом) 已被 TELEMT 和 Mtproto zig 采用_ ⭐️

_MEKO 目前使用 [更精确的 V3 版本](https://github.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/blob/main/data/dictionary.md#Термины-связанные-с-фиксом)_
</div>

---

<div align="center">
👇 遇到问题？来聊天群，我们帮你 👇
</div>
<p align="center">
  <a href="https://t.me/meko_mtprotofix">
    <img src="https://github.com/user-attachments/assets/4a2a1ee5-cd30-4714-9a8b-0d02dc8cae1d" width="350" height="130"/>
  </a>
</p>
<div align="center">
☝️附注：那里还有根据修复方案改编的连续剧 ☝️
</div>



**该脚本一键解决**自 6 月 4 日起出现的问题——**Telegram 客户端无法连接到 MTProto 代理服务器**。修复在服务端完成，客户端无需安装或更改任何设置。

**问题表现**：
- 连接可能卡住、长时间无法建立，或 TCP 初始握手不稳定，首次连接后客户端会被**封锁 2 分钟**。
- iOS 上出现“无限更新”。
- 媒体加载失败——视频/图片/GIF/语音/贴纸无法显示。

**已在以下版本测试通过：Telemt 3.4.25, MTProto.zig 1.9.0, Mtg 2.2.8, Erlang mtproto proxy, MTProtoProxy, JSMTProxy**

本脚本用于 MTProto 代理服务器，修复客户端 TCP 初始连接缓慢或完全无法连接的问题。**优势**：
- 即便同一 IP（Wi-Fi）下设备众多，也能快速连接。
- **单端口支持所有设备：iOS/Android/macOS/Desktop** 等。
- **媒体**加载速度不变。
- 能**100% 准确**识别不同设备并应用相应规则。
- **一键安装**，并提供两种模式：“标准安装”可自定义设置，“自动安装”会告知即将执行的操作，确认后自动完成。

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

## 快速开始：

**注意：本脚本收费，价格：给仓库点一个 ⭐**

1. **安装/更新我们的脚本**：
<pre><code>curl -fsSL https://raw.githubusercontent.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/main/install.sh | sudo bash</code></pre>
2. **安装标准 Telemt**，或 "**MTPROTO.zig**" 或 **MTG**
   > （所有代理均可通过脚本菜单安装，无需提前在服务器上安装，且安装顺序无关紧要——先代理后修复或先修复后代理均可）
4. 在主菜单中按 **[1] 安装 SYN FIX** 应用修复
5. 按 **[5]** 禁用 Telemt 配置中的内置 MSS 和 SYN（如果之前已添加到配置中）
6. 通过菜单中的 **[7]** 按钮或机器人 **@Sni_checker_bot** 检查 **SNI**——必须选择显示 🟢 **标记：无** 的域名，否则 iOS 用户会遇到问题。
7. 如果使用 SelfSteal，请确保服务器安装 **OpenSSL 3.5** 或更高版本——否则同样会出现 iOS 问题。如果无法安装 **OpenSSL 3.5+**，则改用任何显示“🟢 **标记：无**”的流行域名替代 SelfSteal。替代方案详见[文档](https://github.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/blob/main/data/dictionary.md)。
8. 完成。

- **额外功能**：
按钮 **3** 可对服务器进行基础优化，测试表明其性能更佳——更快、更稳定、资源消耗更低。

**打开菜单**：
<pre><code>mekopr</code></pre>

# 修复原理：

为服务器应用一套规则，将设备分为两类——**iOS** 和 **非 iOS**，并对各自应用不同的限制。

- **第一层** – 检查设备是否为 iOS。
  - **若是** – 保留在第一层，应用专门针对 iOS 的规则。
  - **若否** – 转到第二层，应用第二层规则（限制 SYN 为 1 包/1.1 秒）。

**详细说明**

- 修复 **iOS/Android** 的“死连接”问题
  - 问题：移动客户端切到后台，套接字未正常关闭，导致服务器维持死连接；客户端返回时卡在死套接字上。
  - 脚本使死连接在几分钟内断开（而非数小时）。客户端返回时立即发现“套接字已死”，从而无卡顿重连。

- 修复被截断的 **TCP** 握手
  - 脚本限制每个 **IP** 的入站 SYN 频率为 1 包/1.1 秒，因为技术手段仅在每秒超过 1 个连接时才会限制 TCP。

- **单独处理 iOS**
  - iOS 的连接模式与 Android 和 Desktop 不同。混在同一限制下会互相干扰。按端口分离是一种笨办法。我们的修复基于 iOS 指纹进行区分，因此不同设备可共用一个端口而无额外麻烦。

- **54/分钟**（而非 1 包/秒）
  - **iptables** 的 **hashlimit** 模块不支持毫秒。54/分钟 = 0.9 包/秒/连接（即 1 包/1.1 秒）。额外 100 毫秒的余量可消除瞬时 Reject 导致的误差，否则会导致设备连接 MTProto 服务器被封锁 2 分钟。

- 使用 **REJECT** 而非 **DROP**
  - **DROP** 直接中断连接但不通知客户端，导致超时（3-5 秒）→ 更长的重试间隔 → 更高延迟。而带 RST 的 **REJECT** 立即返回重置响应，客户端无需等待即可重试，从而大幅提升 Telegram 连接速度。

- 此构建中 **MSS** 完全没有必要，因此脚本包含禁用功能。如果保留任何 MSS 规则或限制 SYN 的配置，媒体和下载速度会变慢——建议在应用修复前注释/删除此类设置。

**如果还不明白，请阅读** <a href="https://github.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/blob/main/data/dictionary.md">小白词典</a>，其中用通俗语言解释了所有术语及完整文档。

## 可能的问题（“为什么可能不工作？”）

- 端口/IP/子网可能之前已被 **封锁**，需要更换（例如在 **443** 上不工作的代理可能在 **9443** 上正常工作）。这种情况下任何修复都无效。
- 使用 **v2** 修复（通过 **TTL + Length** 识别设备）时，从 **iOS** 连接，流量可能经过负载均衡器，**TTL** 超过设定阈值，导致脚本误判为桌面/Android，从而触发封锁——此时 **必须使用 v3 修复**。
- 不使用 **MSS** 时，**必须确保用于 Fake TLS 的域名支持 X25519 MLKEM768**——可通过**内置域名检查**或 **@Sni_checker_bot** 检测。**若选择的域名不支持，iOS 连接尝试后会立即封锁，连接失败。**
- **若使用 SelfSteal 而非第三方域名**，请确保 nginx 编译时使用了 OpenSSL 3.5——否则会出现周期性 iOS 连接问题。要正常使用 SelfSteal，请安装基于 **3.5** 编译的 **nginx**，或将服务器 **OpenSSL** 升级到 **3.5** 并重新编译 **nginx**。
    - 替代方案1：使用 **caddy**。
    - 替代方案2：启用 **MSS**，但媒体加载会**非常慢**。
- 如果因域名不支持 **X25519MLKEM768** 而不得已启用 **MSS**，且媒体加载缓慢——这是正常现象。MSS 减小了数据包大小，直接影响下载速度。

## ⭐ 支持项目

**MEKO Launcher** —— 利用业余时间为社区创建。

**您可以通过给本仓库点 ⭐（页面右上角）来支持项目。**

如果您认为本项目有用并希望支持开发，可以向以下加密钱包捐赠：

[<img width="150" height="150" alt="image" src="https://github.com/user-attachments/assets/b910c839-ec45-486d-b7f0-05da8de41b74" />](https://t.me/send?start=IVlaFvgWdkxH)

USDT TRC20 ``` TGmBaRYmQwSyC6sRaumaMf9CbEuVAk4Eff ``` 

USDT BEP20 ```0x2AF1581aA7b696Ca28C70B5D29756Da3ca577D65``` 

TON(GRAM) ``` UQDdT8vtR5DmbwzNvMUiNQnwxlbkFq4ypE2_UzIm6bQ88DbU ``` 

BTC ``` bc1qqfkknfrhhufq6dm7cczmdtjkgv56ma3gnz0utk ``` 

SOL SPL ``` Gn7w3EBkZqPjPDcbkTaxspip42TuhoGqaaEqHAxhG9V1 ``` 

您也可以通过使用我的服务来支持我：

[<img width="150" height="150" alt="projectmeko_bot" src="https://github.com/user-attachments/assets/8db41a95-79f2-40d6-9777-50b6ffb6fa48" />](https://t.me/projectmeko_bot)

dalink.to/mekome

<a href="https://www.star-history.com/?type=date&repos=Mekotofeuka%2FMTPROTO_FIX_By_MEKO">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=Mekotofeuka/MTPROTO_FIX_By_MEKO&type=date&theme=dark&legend=top-left&sealed_token=7QCqNRNApwLOeL40L6S8sUAHUyTcivBId5b6sO3nVG4PMXG411eamYd49VpVN2Ha4cmAbIyMdeE3IKDUAyimSorKjMDcAf9Ryrh0nLzEpBQILeuxKQLZlg" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=Mekotofeuka/MTPROTO_FIX_By_MEKO&type=date&legend=top-left&sealed_token=7QCqNRNApwLOeL40L6S8sUAHUyTcivBId5b6sO3nVG4PMXG411eamYd49VpVN2Ha4cmAbIyMdeE3IKDUAyimSorKjMDcAf9Ryrh0nLzEpBQILeuxKQLZlg" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=Mekotofeuka/MTPROTO_FIX_By_MEKO&type=date&legend=top-left&sealed_token=7QCqNRNApwLOeL40L6S8sUAHUyTcivBId5b6sO3nVG4PMXG411eamYd49VpVN2Ha4cmAbIyMdeE3IKDUAyimSorKjMDcAf9Ryrh0nLzEpBQILeuxKQLZlg" />
 </picture>
</a>

## 特别感谢贡献者：
[![贡献者](https://contrib.rocks/image?repo=Mekotofeuka/MTPROTO_FIX_By_MEKO)](https://github.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/graphs/contributors)
- [@CryZFix](https://github.com/CryZFix/)
- [@Bxhost](https://github.com/bxhost)
- [@Liafanx](https://github.com/Liafanx)
- [@Andycar](https://github.com/Andycar)
- https://github.com/Liafanx/MTproxy-reanimation – 功能相似的工具，特别感谢标记检测
- https://assyoucandy.github.io/telemt-server-guide/telemt-keepalive-guide.html
- https://h1de0x.github.io/telemt-tune/

## 原始仓库
- Telemt https://github.com/telemt/telemt
- MTG https://github.com/9seconds/mtg
- Mtproto.zig https://github.com/sleep3r/mtproto.zig
- telemt_panel https://github.com/amirotin/telemt_panel
- 3x-ui-pro https://github.com/mozaroc/3x-ui-pro
- remnawave-installer https://github.com/xxphantom/remnawave-installer

> *本页面为独立信息综述。*
>
> *本文并非 VPN、代理等服务的广告。所有材料仅供信息参考，且仅适用于法律允许阅读此类信息的国家公民，至少用于科研目的。若您不允许阅读此类内容，请立即关闭此页面！*
>
> *作者无意，也不鼓励、支持或辩解在任何情况下使用 VPN、代理或任何其他软件。*
>
> *任何阅读、使用或操作的责任均由用户自行承担。*
>
> *免责声明：作者不对第三方行为负责，也不鼓励非法使用 VPN/代理等软件。*
>
> *作者对发布数据的准确性、完整性和可靠性不承担任何责任。所有雷同纯属巧合。所有信息均“按原样”提供，可能不符合实际情况。*
>
> *请根据当地法律使用。*
>
> *请仅将 VPN 和代理用于合法目的，例如保障您的网络安全和安全远程访问，切勿用于规避封锁。*
>
> *本项目为非商业性免费项目；所有“支付”信息均是在互联网上随机找到的，按原样复制以供示例演示，并不属于作者。*
>
> *按照 Igareck 流行仓库的告诫——请关闭此页面，从电脑中删除所有 VPN 和代理，在所有设备上安装 MAX 和 Yandex，以便即使在停车场也能“抓到”信号，并仅使用互联网服务提供商允许的资源，您懂的。*
