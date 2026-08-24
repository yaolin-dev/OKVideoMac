# OKVideoMac

OKVideoMac 是面向 Apple Silicon Mac 的原生视频与直播客户端。源兼容性主要取决于
配置格式、站点类型和运行时，而不是简单以 TVBox、FongMi、MiraPlay 或 CatPawOpen
等生态名称判断。当前版本为 **0.3.53（Build 78）**，支持 **arm64**，最低系统为
**macOS 12.0**。

项目不内置内容源、账号、Cookie、DRM key 或私人服务配置。请只导入你有权使用
且信任的配置、脚本和媒体。

## 当前版本

- 当前版本：0.3.53（Build 78）
- 最低系统：macOS 12.0
- 支持架构：Apple Silicon / arm64
- 播放历史按点播配置源分组；切换同一配置内的站点不会隐藏历史，历史项仍保留
  实际站点身份用于准确恢复播放
- 网盘登录状态按 Provider 与账号类型持久化；切换配置源只取消当前二维码交互，
  不会清除已经确认的登录状态，也不会存储 Cookie 或 Token
- 发行验证：391 项 Xcode 测试通过（另有 2 项按设计跳过；1 项 MPV Bridge
  完整性检查由正式 Bundle 验证覆盖），127 项 OKVideoKit 测试通过，arm64 Release
  与 Android Release Bridge 构建通过；正式 Release packaging 已验证 28 个
  Mach-O 的架构、部署目标、依赖闭包、签名和 Hardened Runtime
- 对外分发：Build 65 已完成 Developer ID signing、Apple notarization、staple
  和 Gatekeeper 实物验收

## 安装

正式公开版本发布后：

1. 只从本仓库官方 GitHub Releases 页面下载 0.3.41 对应的 macOS arm64 发布包；
2. 打开 `OKVideoMac-0.3.41-macOS-arm64.dmg`；
3. 将 `OKVideoMac.app` 移入 `/Applications`；
4. 从 Applications 或 Finder 正常启动。

不要使用来源不明或无法与本仓库发布哈希对应的第三方二进制。

### Gatekeeper 与 macOS 安全

0.3.41（Build 65）正式 DMG 已使用 Developer ID Application: Yao Lin
（KGG363ABK9）签名，启用 Hardened Runtime，并通过 Apple notarization、staple
和 Gatekeeper 验证。安装和运行不需要关闭任何 macOS 安全机制。

如果 macOS 阻止首次打开已从官方 Release 下载的包，可先在 Finder 中按住
Control 点击（或右键点击）App，再选择 **打开**。也可前往 **系统设置 →
隐私与安全性**，核对 App 来源后选择 **仍要打开**。

不要全局关闭 Gatekeeper、关闭 SIP、删除系统级 quarantine policy、修改系统
安全数据库或使用其他绕过 Apple 安全机制的方法。

请只使用本仓库 GitHub Releases 页面提供的正式 DMG，并核对 Release 页面公布的
SHA-256；本地开发包或来源不明的副本不属于正式发行 artifact。

## 源兼容性与 Android Compatibility Mode

| 源 / 运行时 | 状态 | 说明 |
| --- | --- | --- |
| Native CMS JSON | ✅ Supported | 原生 Provider 路径 |
| CMS XML API 响应 | ◐ Partial | 已覆盖核心响应映射；具体源行为可能不同 |
| FongMi 风格 JSON 配置 | ◐ Supported with limitations | 部分字段仅解析或保留，并未进入功能执行链 |
| FongMi 图片/Base64 包装 JSON | ✅ Supported | 识别单层指定格式的包装 |
| QuickJS Spider | ◐ Selected | 仅限符合当前接口的部分 CatVod/FongMi 风格脚本 |
| CatVod/CatPaw 风格 Node `.js.md5` | ◐ Selected | 仅限使用当前受支持 Node 视频接口的源 |
| Java/Dex `csp_` Spider | 🧪 Experimental | 需要可选 Android Bridge |
| M3U / TXT / JSON 直播 | ✅ Supported | 通过独立直播源导入器使用 |
| XMLTV EPG | ✅ Supported | 包括 M3U `tvg-url` 指向的 gzip XMLTV |
| JSON / Web 解析 | ◐ Partial | 当前只执行有限的解析器类型和路径 |

实际兼容性取决于源格式、站点类型、运行时、API 结构、解析方式及媒体行为。
能够使用部分 TVBox、FongMi、MiraPlay 或 CatPawOpen 生态中的源，并不代表对这些
生态实现完整兼容。OKVideoMac 实现了部分 FongMi 配置约定及 CatVod Spider 接口，
并支持部分 TVBox 风格的配置格式和 Spider 运行时。详细矩阵见
[`macOS/OKVideoMac/Docs/COMPATIBILITY.md`](macOS/OKVideoMac/Docs/COMPATIBILITY.md)。

### Native Mode

OKVideoMac 的启动和主要 Native Mode 功能**不要求安装 Android SDK 或
Emulator**。已由当前实现和 Phase 4 证据确认的 Native 能力包括：

- Native CMS JSON、部分 CMS XML API 响应和指定的 FongMi 图片/Base64 包装 JSON；
- M3U、TXT、JSON 直播源和 XMLTV；
- QuickJS Spider 路径；
- Node Spider 路径；
- 原生 libmpv 点播与直播播放；
- 首页、分类、筛选、详情、搜索、收藏、历史和播放进度恢复。

普通 Native、QuickJS、Node、直播和 XMLTV 源均不需要 Android。不同外部配置或
Spider 的实际兼容性仍取决于其实现，不保证任意上游都等价。

### Android Compatibility Mode（Experimental / Advanced Compatibility）

Android 支持是可选的。Android Bridge 只是针对部分 Java/Dex `csp_` Spider 的
**可选兼容运行时**，不是 OKVideoMac 的基础运行依赖。Native Provider、QuickJS、
Node、直播源、XMLTV 和普通播放均不经过 Android Bridge。

需要该兼容层时，用户需准备 Android SDK、Platform-Tools（`adb`）、Android
Emulator、Command-line Tools（`avdmanager`）和已安装的 `arm64-v8a` system
image。Android Studio 本体不是运行时依赖，但通过 Android Studio 的 SDK Manager
安装这些组件是最简单的推荐方式。

OKVideoMac 会自行创建并启动名为 `OKVideoMac_Runtime` 的专用无窗口 AVD；不需要
手工创建 AVD，也不使用真实 Android 设备或用户已有的普通 AVD。正式 App 已内置
`AndroidDexBridge-release.apk`，启动时会通过 `adb install -r` 自动安装或更新，
用户不需要下载或手工安装 APK。

安装后可前往 **设置 → 高级 → Android 兼容模块**，点击 **检查**；若未自动找到
SDK，可点击 **选择 SDK…** 并选择包含 `platform-tools` 和 `emulator` 的 SDK 根目录。
显示“已就绪 — Java/Dex 站点可正常使用”即表示启动成功。完整安装、发现顺序与故障
排查见 [Android Bridge 设置（中文）](macOS/OKVideoMac/Docs/ANDROID_BRIDGE_SETUP_zh-CN.md)
或 [Android Bridge Setup (English)](macOS/OKVideoMac/Docs/ANDROID_BRIDGE_SETUP.md)。

## 主要能力

- 远程 URL、本地文件和粘贴 JSON 配置；
- 首页、分类、筛选、详情、多站搜索、收藏和历史；
- M3U/TXT/JSON 直播列表与 XMLTV EPG；
- libmpv 点播/直播、Seek、音量、倍速、音轨、字幕、截图和全屏；
- QuickJS、Node.js 和可选 Android Java/DEX 兼容路径；
- SQLite 持久化、图片内存/磁盘缓存和播放进度恢复；
- 初始解析/加载失败时的解析器去重尝试和自动换线。

功能级别状态与证据见
[`macOS/OKVideoMac/Docs/COMPATIBILITY.md`](macOS/OKVideoMac/Docs/COMPATIBILITY.md)。

## 首次发布的已知限制与风险

- 当前只交付 arm64，不支持 Intel Mac/Universal Binary；
- Android compatibility 仍需要外部 SDK/ADB/Emulator、已安装的 arm64 system
  image 和命令行工具；本版本不自动下载这些组件；
- HDR、AV1、字幕组合和广泛性能/长时间运行矩阵尚未全部覆盖；
- 外部 Spider 兼容范围是开放的，Web 嗅探和自动换源也受上游实现影响；
- Node bundles/scripts 以高权限子进程执行，只应使用可信、可核验的来源；
- juniversalchardet 保留用于兼容性，其状态为 **Documented License
  Interpretation Risk**；**Independent Legal Review: NOT PERFORMED**；
- 项目不实施 DRM 绕过、TVBus 或 ForceTech 私有引擎。

Build 62 阶段留存的历史工程准备记录见
[`Docs/ENGINEERING_OPEN_SOURCE_READINESS_PHASE4.md`](../Docs/ENGINEERING_OPEN_SOURCE_READINESS_PHASE4.md)，
同期 juniversalchardet 兼容性审计见
[`Docs/JUNIVERSALCHARDET_ELIMINATION_AUDIT.md`](../Docs/JUNIVERSALCHARDET_ELIMINATION_AUDIT.md)。
这些材料保留为历史工程证据；Build 62/63 均不是当前 Build 65 的发布状态，
Build 64 则保留为上一版不可变公开发布，
也不构成法律意见
或“无风险”保证。

## 报告问题

请使用本仓库的 GitHub issue template，并至少提供：

- OKVideoMac 版本和 build；
- macOS 版本；
- Mac 型号与架构；
- Native Mode 或 Android Compatibility Mode；
- 可重复步骤；
- 预期结果与实际结果；
- 相关且已脱敏的日志；
- 必要时说明 source/provider 类型，但不要提交私人 URL。

不要在 issue 或日志中提交 Cookie、OAuth token、私人内容源 URL、账号密码、
API key、私人媒体历史或其他个人数据。安全敏感问题请遵循
[`SECURITY.md`](../SECURITY.md)。

## Binary ↔ Source 核验

Git tag 指向的 exact release commit 才是项目源码基准；不要把移动的 `main`、
`master` 或 `latest` 当作对应源码。正式 Release 应同时提供并由统一
`SHA256SUMS` 绑定：

- source release index：`OKVideoMac-0.3.41-build65-SOURCE_RELEASE_INDEX.json`；
- binary-to-source mapping：
  [`Docs/BINARY_SOURCE_MAPPING.md`](../Docs/BINARY_SOURCE_MAPPING.md)；
- binary/source manifest：
  `OKVideoMac-0.3.41-build65-SOURCE_RELEASE_MANIFEST.json`；
- hashes：`OKVideoMac-0.3.41-build65-SHA256SUMS`；
- macOS SPDX / CycloneDX：`OKVideoMac-macOS.spdx.json`、
  `OKVideoMac-macOS.cdx.json`；
- Android SPDX / CycloneDX：`OKVideoMac-Android.spdx.json`、
  `OKVideoMac-Android.cdx.json`；
- exact APK：`OKVideoMac-0.3.41-AndroidDexBridge-release.apk`；
- exact project source：`OKVideoMac-0.3.41-build65-source.tar.gz`；
- third-party source package：
  `OKVideoMac-0.3.41-build65-third-party-source.tar.gz`；
- license package：`OKVideoMac-0.3.41-build65-licenses.tar.gz`；
- macOS artifact：`OKVideoMac-0.3.41-macOS-arm64.dmg`。

当前 Build 65 文件清单与生成规则见
[`Docs/SOURCE_RELEASE_PROCESS.md`](../Docs/SOURCE_RELEASE_PROCESS.md)。Build 62/63
发布准备阶段的历史工程状态保留在
[Historical Build 62 Release Readiness Record](../Docs/IMMUTABLE_RELEASE_READINESS.md)。
下载后应对照 Release 页给出的 `SHA256SUMS`，并确认 tag、exact commit、
source index 和 binary-bound manifest 一致。

## 构建与贡献

构建环境、依赖和故障排查见
[`macOS/OKVideoMac/Docs/BUILDING.md`](macOS/OKVideoMac/Docs/BUILDING.md)。
贡献规则见 [`CONTRIBUTING.md`](../CONTRIBUTING.md)。

本地验证包：

```bash
OKVideoMac/macOS/OKVideoMac/Scripts/package-app.sh --mode local
```

Developer ID 分发与公证（只在真实证书和 notary profile 可用时执行）：

```bash
export DEVELOPER_ID_APPLICATION='Developer ID Application: …'
export OKVIDEOMAC_NOTARY_PROFILE='okvideomac-notary'
OKVideoMac/macOS/OKVideoMac/Scripts/package-app.sh \
  --mode distribution \
  --notarize
```

## 上游与许可证

协议审计固定在 FongMi/TV `fongmi` 分支提交
`5fdff00a602dc56e8ba756174daef20edab024f2`。参考源码不会参与 macOS 构建。

本项目采用 GNU General Public License Version 3。完整条款见 `LICENSE`，
上游来源与本项目修改声明见 `NOTICE.md`。
