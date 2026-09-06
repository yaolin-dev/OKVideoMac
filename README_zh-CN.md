# OKVideoMac

[English](README.md) | 简体中文

OKVideoMac 是面向 Apple Silicon Mac 的原生视频与直播客户端。它提供可配置的
视频 Provider、直播源、搜索、详情、收藏、历史和基于 libmpv 的播放体验，但不
内置第三方影视源、账号、Cookie、解析服务或 DRM 密钥。

当前热修复候选版本为 **0.4.2（Build 97）**，支持 macOS 12 或更高版本、
Apple Silicon（`arm64`），尚未对外发布。当前公开的 Developer ID 签名、
Apple 公证并已 Staple 版本仍从
[v0.4.1 正式发布页](https://github.com/yaolin-dev/OKVideoMac/releases/tag/v0.4.1)
下载。

## 0.4.2 热修复候选版本

0.4.2 针对冷启动长时间停留在 `emulator-5554 offline` 的 Android Runtime：
把 180 秒 ADB transport 等待与 Android boot 明确分开，使用所选 SDK 的私有
ADB server，宽限期后最多执行一次目标 reconnect，并把 GPU 恢复限制为
host 到 software 的一次回退。两种后端都失败时，设置页可恢复地重建私有
AVD，不影响 Android Studio AVD、默认 ADB server、收藏或历史。

Build 97 为 API 24–29 旧 system image 增加了仅限私有、无窗口
Emulator 的 ADB 认证兼容启动方式；现代镜像仍使用 OKVideoMac 私有
keypair 并保持 Guest ADB 认证。

## 0.4.1 Highlights

0.4.1 重点改善部分 TVBox / Java/Dex Spider 使用的可选 Android 兼容 Runtime。
OKVideoMac 现在能够安全接管上一轮留下的健康私有 Emulator，串行化并发启动请求，
在 ADB 尚未就绪时提供更可靠的恢复，并在 App 正常退出时自动关闭自己的 Runtime，
同时不会影响 Android Studio 或用户其他 AVD。0.4.0 引入的原生界面、播放、搜索、
直播、网盘与发布工程改进继续保留。

### Source Compatibility

- Native CMS JSON 是最完整的 Provider 路径；CMS XML 和 type 4 为有限兼容。
- 扩展符合当前接口的 TVBox/FongMi 风格 QuickJS 脚本与 CatVod/CatPaw 风格
  Node 视频接口；这不等同于支持这些生态的全部源或私有扩展。
- Android Bridge 为部分 Java/Dex `csp_` Provider 提供可选兼容层，并强化了专用
  AVD、运行时所有权、APK 版本和签名校验；普通点播、直播、QuickJS 和 Node 不
  需要 Android。
- 已有健康或仍在启动中的 OKVideoMac 私有 Runtime 会被自动接管；并发请求共享
  同一次启动，正常退出 App 时会自动关闭该 Runtime。

### Search & Detail

- 聚合搜索按 session 隔离并发站点；停止后保留已返回结果，迟到回调不能覆盖新搜索。
- 返回按钮、Esc 与 Command-[ 共享逐层退出逻辑：搜索中先停止，再返回进入前页面。
- 详情请求保留配置、站点与请求身份，快速切换影片时旧结果不会覆盖当前详情。
- 长剧集支持分段浏览，已验证 120 集条目和多线路切换。

### Playback & Live TV

- 改进播放器打开/关闭、窗口恢复、缓冲反馈、Seek 和自然 EOF 自动下一集。
- 播放请求、线路切换和自动重试带有代际隔离，旧任务不能重新接管当前播放器。
- 直播频道列表、分组、多线路、XMLTV EPG、换台与播放器返回路径更稳定。
- M3U、TXT 与 JSON 直播列表可直接导入；HLS 可作为频道媒体播放。

### Cloud & Authorization

- 缺少或失效的网盘凭据会进入对应授权页；授权完成后只安全重试原播放一次。
- 授权窗口使用真正的 macOS Sheet，具备系统级遮罩、焦点、Esc 和辅助功能行为。
- 夸克在 Cookie 自动续期或重新扫码后以稳定账号身份复用已有转存目录；账本丢失或
  FID 失效时会先发现已有目录，再决定是否创建。
- 清理仍严格限定为 receipt 记录的准确 `savedFID`，不会扫描或清空整个网盘目录。

### Native macOS Experience

- 重整首页、搜索、详情、播放、直播和设置界面的层级、工具栏与状态反馈。
- 配置与授权从自绘全屏覆盖层迁移到系统 Sheet，背景窗口统一压暗且不可误触。
- 搜索返回入口固定可见，按钮与页面切换采用系统提供的交互和动画语义，并尊重
  “减少动态效果”辅助功能设置。

### History, Backup & Safety

- 历史、收藏和恢复播放会保留原配置与站点身份，避免切换配置后的串源。
- 支持便携的配置与历史备份/恢复；恢复过程校验格式并避免覆盖较新的活动状态。
- 远程 Node bundle 继续执行来源、版本和 SHA-256 信任规则；日志与发布门禁会扫描
  Cookie、Token、私人 URL 和本机绝对路径。

### Release & Open Source

- 正式下载为只含 `OKVideoMac.app` 和 Applications 链接的 Apple Notarized +
  Stapled DMG；内部 ZIP 继续承担已验证的 binary identity/archive carrier 作用。
- DMG、ZIP、Source Release、四份 SPDX/CycloneDX SBOM、Notices 与 Android Bridge
  APK 由外层 manifest 和 `SHA256SUMS` 绑定到同一个 exact commit。
- Release gate 验证 28 个 arm64 Mach-O、最低系统、动态依赖闭包、嵌套签名、
  Hardened Runtime、Gatekeeper 及源码/二进制映射。

## 0.4.0 真实界面

以下截图均来自最终 0.4.0（Build 94）Release App，使用仓库内可重复生成的原创演示
源与风景媒体；不包含真实影视、IPTV、账号或私人 URL。中英文 README 共用同一套图。

### 首页

![0.4.0 首页](Docs/Media/v0.4.0/home.png)

### 搜索

![0.4.0 搜索结果](Docs/Media/v0.4.0/search.png)

### 详情

![0.4.0 长剧集详情](Docs/Media/v0.4.0/series-detail.png)

### 点播播放器

![0.4.0 点播播放器与原生控件](Docs/Media/v0.4.0/vod-playback.png)

### 直播频道

![0.4.0 直播频道横幅](Docs/Media/v0.4.0/live-channels.png)

### 直播播放器

![0.4.0 直播播放器与原生控件](Docs/Media/v0.4.0/live-playback.png)

### 设置

![0.4.0 设置](Docs/Media/v0.4.0/settings.png)

演示数据、生成方法、资产来源和截图清单见
[Demo Source](Docs/DemoSource/README.md)与[截图清单](Docs/Media/v0.4.0/README.md)。

## 兼容性概览

兼容性取决于源格式、运行时、API 结构、解析要求和媒体行为，而不是生态品牌。

| 源 / 运行时 | 状态 | 说明 |
| --- | --- | --- |
| Native CMS JSON | Supported | 首页、分类、筛选、详情、搜索和播放地址交接 |
| CMS XML / Native type 4 | Partial | 覆盖窄于 JSON 路径 |
| QuickJS Spider | Selected | 符合当前接口的部分 CatVod/FongMi 风格脚本 |
| Node `.js.md5` | Selected | CatVod/CatPaw 风格 Node 视频接口兼容子集 |
| Java/Dex `csp_` | Experimental | 需要外部 Android 环境和可选 Bridge |
| M3U / TXT / JSON 直播 | Supported | 通过独立直播源导入器使用 |
| XMLTV EPG | Supported | 不需要 Android |
| 顶层 `lives`、parser type 2/3/4 | Unsupported | 可解析部分字段，但没有完整执行链 |

完整边界见[兼容性指南](OKVideoMac/macOS/OKVideoMac/Docs/COMPATIBILITY.md)。

## 下载与安装

系统要求：

- macOS 12.0 或更高版本；
- Apple Silicon（`arm64`）；
- 只有 Java/Dex `csp_` 源需要外部 Android SDK、ADB、Emulator 和 arm64 system image。

下载 `OKVideoMac-0.4.1.dmg`，打开后将 `OKVideoMac.app` 拖入 Applications。
正式包已经 Apple 公证，不需要也不应关闭 Gatekeeper 或 SIP。

## 二进制与源码身份

0.4.1（Build 95）资产从 Tag `v0.4.1` 指向的 exact commit 构建。GitHub Release
同时提供 `OKVideoMac-0.4.1.dmg` 与公证、Staple 后重新计算的 `.sha256` 文件。
公开源码以 Git tag 为准；生成的 source index、manifest、SBOM、Notices 与校验和
把二进制绑定到该 commit，避免在 tagged source 中引入循环的二进制哈希。原生
第三方来源仍明确披露两个可复现性例外：zlib 精确归档不可用，以及历史
MacPorts libc++/libc++abi 输入未能恢复；它们不会被误标为可重复构建。

## 已知限制

- 仅支持 Apple Silicon，不提供 Intel 或 Universal Binary。
- Java/Dex Bridge 为 Experimental，依赖外部 Android 环境。
- QuickJS、Node、网盘和网页嗅探只兼容已实现的接口，上游变化可能需要后续适配。
- TVBox/FongMi 顶层 `lives`、catchup/timeshift、parser type 2/3/4 和 DRM 不受支持。
- 大型旧数据库升级可能出现一次性启动停顿；TMDB 元数据增强计划留待后续版本。

## 文档与安全

- [0.4.1 发布说明](Docs/RELEASE_NOTES_0.4.1.md)
- [详细项目文档](OKVideoMac/README.md)
- [兼容性指南](OKVideoMac/macOS/OKVideoMac/Docs/COMPATIBILITY.md)
- [Android Bridge 设置](OKVideoMac/macOS/OKVideoMac/Docs/ANDROID_BRIDGE_SETUP_zh-CN.md)
- [从源码构建](OKVideoMac/macOS/OKVideoMac/Docs/BUILDING.md)
- [源码发布流程](Docs/SOURCE_RELEASE_PROCESS.md)
- [DMG 发布流程](Docs/DMG_RELEASE_PROCESS.md)
- [更新日志](CHANGELOG.md)
- [安全政策](SECURITY.md)

请仅使用你有权访问的配置和内容。报告问题前请移除私人 URL、Cookie、Token、账号
和个人数据；安全问题请按[安全政策](SECURITY.md)私下报告。

## 许可证

OKVideoMac 依据 [GNU General Public License v3.0](LICENSE) 发布。第三方组件仍
分别受其各自许可证和声明约束。
