# Compatibility

- 对照版本：0.3.50（Build 75）
- 最近更新：2026-08-24
- 当前交付目标：Apple Silicon / arm64 / macOS 12.0+

## 概述

OKVideoMac 的兼容性主要取决于源格式、站点类型、运行时、API 结构、解析方式和
媒体行为，而不是简单以 TVBox、FongMi、MiraPlay 或 CatPawOpen 等生态名称判断。
能够使用某个生态中的部分源，不表示实现了该生态的完整协议或支持其中所有源。

本页区分配置能否被解析、Provider/Spider 是否能执行，以及最终媒体能否由 libmpv
播放。配置字段能被解析或无损保留，不自动代表相应功能已经接入执行链。

## 状态定义

- `Supported`：主要调用链已经实现，并有自动化、静态调用链或实机验证证据。
- `Partial`：核心路径存在，但部分操作、字段或源类型仍缺失。
- `Selected`：只兼容符合当前已实现接口的部分脚本或源，不代表整个生态。
- `Experimental`：实现存在，但外部真实样本、运行环境或长期稳定性覆盖有限。
- `Unsupported`：当前执行链不支持；即使字段能被读取，也不会执行该能力。
- `Untested`：代码路径存在，但缺少足以作公开保证的验证。
- `Not Applicable`：项目明确不提供该能力。

`Supported` 不表示任意第三方影视源都会永久可用；它只表示客户端对应路径有
可重复的验证证据。

## 配置格式

| 配置载体 | 状态 | 说明 |
| --- | --- | --- |
| URL JSON | Supported | 远程配置只接受 HTTP/HTTPS；包含规范化、取消、重试和失败隔离 |
| 本地文件 / Finder 打开 | Supported | 只读取用户选择或 Finder 传入的配置 |
| 粘贴 JSON | Supported | 包含同事件同步、大小、重复 JSON key 和未知字段处理 |
| FongMi 图片/Base64 包装 JSON | Supported | 只识别指定 marker 后的一层 Base64，解码结果必须是 JSON 对象 |
| 通用 Base64 配置 | Unsupported | 不递归解码，不接受任意嵌套 Base64 或 Base64 XML |
| 通用 XML 配置文件 | Unsupported | XML 仅用于部分 CMS API 响应和 XMLTV EPG，不是配置载体 |
| Node `.js.md5` 配置入口 | Selected | 仅用于受支持的 CatVod/CatPaw 风格 Node 视频 bundle |

配置模型可以读取 `sites`、`parses`、`lives`、`headers`、`flags`、`proxy`、
`doh`、`rules`、`hosts`、`ads`、`danmaku` 等字段，并保留未知字段。实际功能支持
应以以下运行时和限制表为准，不能从“字段可读取”推导为“功能已支持”。

## 点播源

| 能力 | 状态 | 证据与限制 |
| --- | --- | --- |
| Native CMS JSON，type 1 | Supported | 首页、分类、筛选、详情和搜索映射有自动化测试；播放仍受媒体端影响 |
| Native CMS XML API 响应，type 0 | Partial | 核心 class/list 响应映射有测试；详情、搜索等覆盖窄于 JSON 路径 |
| Native type 4 | Partial | 分类筛选使用 URL-safe Base64 JSON 参数；不代表通用 Base64 API |
| Headers 网络规则 | Supported | host 匹配、Header/Cookie 合并和日志脱敏已接入 |

## Spider 运行时

### Native

Native Provider 处理 type 0、1、4，不依赖 QuickJS、Node 或 Android。它实现首页、
分类、详情、搜索和播放地址交接；不同 CMS 的非标准字段和响应仍可能导致不兼容。

### QuickJS

状态：`Selected`

type 3 站点在解析到 HTTP(S) `.js` 脚本时进入 QuickJS。当前 Provider 映射
`init`、`home`、`homeVod`、`category`、`detail`、`search`、`play` 和 `action`，
并提供 selected CatVod/FongMi 风格的 HTTP、Base64、URL 与模块辅助接口。
这不是浏览器、Node 或任意 TVBox JavaScript 的完整兼容层。

`proxy`、`sniffer`、`isVideo` 虽有相关接口定义，但当前没有完整 Provider dispatch，
不得视为完整支持。

### Node `.js.md5`

状态：`Selected`

远程 URL 以 `.js.md5` 结尾时，OKVideoMac 使用 App 内置 Node 加载 bundle，调用其
`start`/`stop`，连接动态 `127.0.0.1` HTTP endpoint，并读取 `/health` 和 `/config`。
视频站点通过 `/spider/<key>/<method>` 形状调用 `home`、`category`、`detail`、
`search` 和 `play`。根级 `sites` 和 `video.sites` 均可归一化；冷启动和并发调用
共享 runtime readiness。

这是受支持 CatVod/CatPaw 风格 Node 视频接口的一个兼容子集，不表示支持任意 Node
Spider、完整 CatPawOpen 应用协议或其他内容模块。远程 bundle 具有 Node 完整能力，
只应加载可信配置。

### Android / Dex

状态：`Experimental`

type 3、`api` 以 `csp_` 开头且存在 jar 引用时，Provider 可通过 Android Bridge 加载
`com.github.catvod.spider.<name>`，并调用 CatVod 风格的 `homeContent`、
`categoryContent`、`detailContent`、`searchContent`、`playerContent` 等方法。

该路径使用专用 AVD、动态 serial 和所有权校验。用户仍需准备外部 Android SDK、
ADB、Emulator 和 arm64 system image；Bridge APK 已随正式 App 提供并由运行时
自动安装。它只适用于受支持的 `csp_` Java/Dex Spider；普通 Native、QuickJS、
Node、直播和 XMLTV 源不需要 Android。

### 其他运行时

| Runtime | 状态 | 说明 |
| --- | --- | --- |
| Python Spider | Unsupported | 当前不提供 Python 运行时 |
| WebView Sniffer | Partial | parser type 0 使用 WKWebView 嗅探，具体网页行为依赖站点 |

## 直播源

独立直播源导入器支持 M3U、TXT 和 JSON 列表。M3U 支持常见 `#EXTINF`、
`group-title`、`tvg-name`、`tvg-id`、`tvg-logo`、User-Agent、Referer、Origin 和
自定义 header；TXT 和 JSON 也支持分组及多线路的对应子集。

| 能力 | 状态 | 说明 |
| --- | --- | --- |
| M3U 频道列表 | Supported | 通过独立直播源导入器使用 |
| TXT 频道列表 | Supported | 支持 `#genre#` 分组和多线路格式 |
| JSON Live 列表 | Supported | 顶层为直播分组数组，不是点播配置 JSON |
| HLS `.m3u8` 媒体 URL | Supported | 作为频道媒体地址播放；HLS segment manifest 不是频道列表 |
| TVBox/FongMi 配置顶层 `lives` | Unsupported | 字段可以解析和保存，但尚未接入独立直播源导入器 |
| catchup / timeshift | Unsupported | 当前未实现 |

## EPG

XMLTV EPG 可由 M3U 的 `tvg-url` / `url-tvg` 指定，支持远程 HTTP/HTTPS、gzip、
缓存和按 `tvg-id`、`tvg-name`、频道名匹配。当前主要消费频道名称和节目开始、结束、
标题；这不等同于通用 XML 配置支持。TXT/JSON 直播列表当前没有对应的 playlist-level
EPG URL 执行链。

## 播放解析

| 路径 | 状态 | 说明 |
| --- | --- | --- |
| direct URL / `parse=0` | Supported | HTTP、HTTPS 和受控 file URL 交给 libmpv |
| parser type 1 | Supported | JSON parser，读取媒体 URL 和允许的 Header |
| parser type 0 | Partial | WKWebView 媒体嗅探，行为依赖具体网页 |
| parser type 2 | Unsupported | 配置可读取，但 PlaybackResolver 不执行 |
| parser type 3 | Unsupported | 配置可读取，但 PlaybackResolver 不执行 |
| parser type 4 | Unsupported | 配置可读取，但 PlaybackResolver 不执行 |
| `parse:<name>` / `json:<url>` | Supported | 显式选择已支持的解析路径 |

最终播放依赖 libmpv、系统可用 codec、媒体服务器、Headers/Cookies 和源本身行为。
OKVideoMac 不提供 DRM 绕过。

## 生态兼容性

### TVBox

OKVideoMac 支持部分 TVBox 风格的配置格式和 Spider 运行时，但各能力等级不同：

- 常见 JSON 配置和 Native CMS JSON：支持；
- CMS XML 响应和 type 4：部分支持；
- QuickJS：仅 selected scripts；
- `csp_` Java/Dex：实验性，且需要 Android Bridge；
- 独立 M3U/TXT/JSON 直播导入：支持；
- 配置顶层 `lives`：未接入直播导入器；
- parser type 0/1：分别为 Partial/Supported；type 2/3/4 不执行。

因此不应将 OKVideoMac 描述为“TVBox compatible”或“支持所有 TVBox 源”。

### FongMi

OKVideoMac 实现了部分 FongMi 配置约定及 CatVod Spider 接口，包括识别指定的
图片/Base64 包装 JSON、selected QuickJS 接口和可选 `csp_` Java/Dex 路径。
并非所有 FongMi 字段都有功能执行链，也不保证所有 FongMi 源或私有扩展可用。

### MiraPlay 源兼容性

部分同时被 MiraPlay 使用的源也可以在 OKVideoMac 中工作，这是因为双方能够消费
相同的 CatVod/CatPaw 风格 Node 视频源格式。该现象属于共享底层源格式兼容，
并不代表 OKVideoMac 支持、兼容或实现了 MiraPlay 专用协议。

### CatPaw / CatPawOpen

OKVideoMac 实现了 CatVod/CatPaw 风格 Node 视频接口的兼容子集，包括 bundle
`start`/`stop` 模型、loopback HTTP runtime、`/config`、`video.sites` 和
`/spider/<key>/<method>` 的 home/category/detail/search/play 路径。

当前不应视为完整 CatPawOpen client，原因包括：

- 未实现 CatPawOpen 的 read、comic、music、pan 内容模块；
- 没有对完整官方 CatPawOpen corpus 作兼容保证；
- 公开 CatPawOpen 实现中的 `/check` 与当前 Node runtime 要求的 `/health` 存在差异；
- 这里只确认视频接口子集，不提供协议级完整兼容保证。

## Parsed-only 字段

| 字段 | 当前结论 |
| --- | --- |
| 顶层 `flags` | 可解析；不作为通用解析器选择器。解析器匹配使用 `parse.ext.flag` |
| `proxy` / `doh` / `rules` / `hosts` / `ads` | 可解析或保留；没有确认到完整功能执行链 |
| `ijk` | 作为未知字段保留，不表示支持上游 IJK 配置语义 |
| `danmaku` | 可保留或由 Node 配置归一化；尚未接入播放层 |
| 未知字段 | 可以 round-trip；不得据此推导功能支持 |

## 已知限制

- TVBox/FongMi 顶层 `lives` 尚未接入独立 Live importer；
- parser type 2、3、4 可解析但不会执行；
- 顶层 `flags` 不作为通用解析器选择器；
- `proxy/doh/rules/hosts/ads` 没有确认到完整执行链；
- QuickJS `proxy/sniffer/isVideo` 没有完整 Provider dispatch；
- CatPawOpen read/comic/music/pan 未实现，`/check` 与当前 `/health` 行为不同；
- Android Bridge 仅为受支持的 `csp_` Java/Dex 源所需，并依赖外部 Android 环境；
- XML CMS 自动化覆盖窄于 JSON CMS；
- 不支持 catchup/timeshift 或 DRM；
- 实际播放仍取决于 libmpv、codec、服务器和媒体行为。

## 测试覆盖

当前兼容性结论来自自动化测试、静态调用链确认和 Maintainer 实际源验证，覆盖：

- Native CMS JSON 的首页、分类、详情、搜索与播放地址映射；
- CMS XML 核心 class/list 映射；
- FongMi 包装配置和 type 4 参数编码；
- QuickJS 方法与参数映射；
- Node `video.sites` 归一化和视频 home route；
- Android Bridge 方法/代理映射；
- M3U/TXT/JSON 直播解析；
- XMLTV/gzip/缓存；
- direct、JSON parser、Web sniff 和 fallback 播放解析。

项目没有声称已经测试完整公开 TVBox、FongMi、MiraPlay 或 CatPawOpen 源 corpus。

## 远程 Node bundle 信任规则

- HTTPS bundle 可沿用现有 `.js.md5` 地址；下载后仍保存并复验内部 SHA-256。
- 如果 MD5 文件或可执行脚本重定向后的最终 URL 任一为 HTTP，配置地址必须携带可信 SHA-256：
  `http://example.com/index.js.md5#sha256=<64位十六进制>`。
- 建议同时声明源身份和版本，例如：
  `#sha256=<64位>&source=my-source&version=2026.08.12`。URL、源身份和版本共同参与缓存隔离；版本更新必须提供新内容对应的 hash。
- URL fragment 只用于本地信任判断，不随网络请求发送。缓存文件每次进入执行路径都会重新计算 MD5 和 SHA-256。
- 该规则只约束会由 Node 执行的 `.js.md5` bundle；普通 HTTP 配置、影视 API、M3U8、直播、图片、字幕和 XMLTV 不受影响。

## 播放器

| 能力 | 状态 | 证据与限制 |
| --- | --- | --- |
| libmpv Client / Render API | Supported | arm64/macOS 12 Release 构建、动态依赖闭包、实机播放和生命周期实验通过 |
| 点播、直播和基本控制 | Supported | 播放/暂停、Seek、音量、静音、倍速、切集和全屏已接入 |
| 媒体 Header | Supported | 使用结构化 mpv node array 传递，不拼接命令字符串 |
| 音轨和字幕轨 | Supported | 轨道列表、偏好匹配和切换策略有单元测试 |
| 外挂字幕 | Partial | `sub-add` 路径已接入；仍需扩大字符集、容器和远程字幕样本覆盖 |
| 截图、画面比例和硬解 | Supported | UI 与 mpv 命令已接入，Release 实机播放路径通过 |
| 初始加载失败自动换源 | Supported | 最多 8 次去重尝试、下一解析器/线路和旧请求隔离有测试 |
| 播放中途断流自动恢复 | Partial | 初始加载失败已覆盖，长播中途断流的多源自动恢复尚未完整验证 |
| 退出播放器完整销毁 | Supported | 10 轮 A/B 与 8 类极端生命周期场景通过；保留 `warmStop` 回退开关 |

## 平台与发布

| 能力 | 状态 | 证据与限制 |
| --- | --- | --- |
| Apple Silicon / arm64 | Supported | App 和全部 bundled Mach-O 均在打包时强制验证 arm64 |
| macOS 12.0+ | Supported | Info.plist 和全部 Mach-O `minos` 由包体脚本验证 |
| Intel Mac / Universal Binary | Unsupported | 当前只交付 arm64 |
| 本地 Hardened Runtime 包 | Supported | ad-hoc 签名，仅主 App 使用开发期 Library Validation 例外 |
| Developer ID 分发 | Supported | 0.3.41（Build 65）正式 DMG 已使用 Developer ID Application 签名，Hardened Runtime、secure timestamp 与权限边界验证通过 |
| Notarization / Staple / Gatekeeper | Supported | 0.3.41（Build 65）App 与 DMG 的 Apple notarization、staple 和 Gatekeeper 验证通过 |
| App Sandbox | Not Applicable | 当前为 Developer ID 外部分发目标；Sandbox 与 Hardened Runtime 是不同边界 |

## 明确不提供

| 能力 | 状态 | 说明 |
| --- | --- | --- |
| DRM 绕过 | Not Applicable | 项目不提供 DRM 密钥或绕过能力 |
| TVBus / ForceTech | Unsupported | 私有 P2P/闭源引擎不在当前实现范围 |
| DLNA | Unsupported | 尚未实现设备发现和投屏流程 |
| 本地公开 HTTP API | Unsupported | Node 内部回环服务不属于公开对外 API |
