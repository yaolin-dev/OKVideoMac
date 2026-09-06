# OKVideoMac

OKVideoMac 是面向 Apple Silicon Mac 的原生视频与直播客户端。源兼容性主要取决于
配置格式、站点类型和运行时，而不是简单以 TVBox、FongMi、MiraPlay 或 CatPawOpen
等生态名称判断。当前代码版本为 **0.4.2（Build 97）** 热修复候选包，支持
**arm64**，最低系统为 **macOS 12.0**；它尚未对外发布。当前公开正式版仍是
0.4.1（Build 95）经 Apple 公证并已 Staple 的 DMG。

项目不内置内容源、账号、Cookie、DRM key 或私人服务配置。请只导入你有权使用
且信任的配置、脚本和媒体。

## 当前版本

- 当前版本：0.4.2（Build 97）
- 最低系统：macOS 12.0
- 支持架构：Apple Silicon / arm64
- 播放历史按点播配置源分组；切换同一配置内的站点不会隐藏历史，历史项仍保留
  实际站点身份用于准确恢复播放
- 网盘登录状态按 Provider 与账号类型持久化；切换配置源只取消当前二维码交互，
  不会清除已经确认的登录状态；凭据不会写入普通配置、历史或便携备份
- Android Bridge 运行时固定 AVD 身份与正式签名；发现旧版 AVD 时可在完整备份和
 复制核验后安全迁移，失败会恢复原运行环境，旧 AVD 始终保持只读
- Xcode：629 total / 625 passed / 4 intentionally skipped / 0 failed
- OKVideoKit：173 passed / 0 failed
- Node / CatPaw / Quark：30 passed / 0 failed
- Android Release assemble 与 lint：通过；Android JVM unit tests：NO-SOURCE
- 正式 Release packaging 会验证 28 个 Mach-O 的架构、部署目标、依赖闭包、
  Developer ID 签名和 Hardened Runtime，并生成 DMG、SBOM 与对应源码集
- 对外分发：0.4.1 Build 95 已完成 Developer ID signing、Apple notarization、
  staple、`stapler validate` 和 Gatekeeper 实物验收

## 0.4.2 Android Runtime 热修复

- ADB transport 等待改为独立的 180 秒单调时钟窗口，再进入原有约 240 秒
  Android guest boot 阶段，冷启动不再在约 60 秒被过早清理。
- 所有 ADB 操作都通过用户选定 SDK 的私有高位端口 server，Emulator 使用同一
  环境；不连接或关闭默认 5037、Homebrew ADB 或 Android Studio ADB。
- 前 20 秒 `offline` 作为 transport 宽限期；之后最多一次目标 reconnect，并保留
  独立诊断记录。
- host GPU 完整超时且 ownership 仍正确时，才会有界回退到 software GPU
  一次；成功后持久化后端，两次失败不自动擦除 userdata。
- 设置页新增可恢复的“修复 Android Runtime”，只备份并重建
  `OKVideoMac_Runtime`，不会改动其他 AVD、普通设置、收藏或历史。
- Build 97 会识别 API 24–29 旧镜像，只对 OKVideoMac 私有无窗口
  Emulator 启用 ADB 认证兼容开关；API 30+ 仍使用私有 keypair 认证。

## 0.4.1 稳定性更新

- 修复 OKVideoMac 自己启动的 Android Runtime 在重启后被误判为外部 Emulator。
- 已有健康或仍在启动中的私有 Runtime 会被自动接管，不会重复启动同一 AVD。
- 并发 Java/Dex 请求共享同一个启动任务；ADB 尚未就绪时的恢复和诊断更明确。
- 正常退出 App 时会自动关闭私有 Runtime；异常退出留下的 Runtime 可在下次启动时
  安全恢复。
- Runtime ownership 和关闭校验不会影响 Android Studio 或用户其他 AVD。

## 0.4.0 大版本变化

- **界面**：首页、搜索、详情、点播、直播和设置重新梳理层级；配置与授权改用
  系统 Window Sheet，按钮、遮罩、焦点和动画遵循原生 macOS 行为。
- **搜索与详情**：多站搜索具备 session 隔离；返回、Esc 和 Command-[ 统一为
  “先停止、再返回”；长剧集分页和详情竞态修复避免旧回调覆盖新页面。
- **播放与直播**：改进缓冲、Seek、自然 EOF 自动下一集、窗口重开、线路切换和
  直播换台；旧播放任务不能重新接管当前播放器。
- **运行时**：扩展 Native TVBox/FongMi、selected QuickJS、CatPaw/Node 和可选
  Android Bridge 路径，并明确 Supported/Partial/Selected/Experimental 边界。
- **授权与夸克**：缺少凭据会进入对应授权页；夸克在 Cookie 续期或重新扫码后
  复用稳定账号目录，清理始终只针对 receipt 的准确 `savedFID`。
- **历史与发布**：加入便携配置/历史备份，强化状态所有权；用户 DMG、内部 ZIP、
  Source Release、四份 SBOM 和 Notices 由外层哈希绑定到 exact Git commit。

## 安装

正式版本安装：

1. 只从本仓库 [v0.4.1 GitHub Release](https://github.com/yaolin-dev/OKVideoMac/releases/tag/v0.4.1) 下载 macOS arm64 发布包；
2. 打开 `OKVideoMac-0.4.1.dmg`；
3. 将 `OKVideoMac.app` 移入 `/Applications`；
4. 从 Applications 或 Finder 正常启动。

不要使用来源不明或无法与本仓库发布哈希对应的第三方二进制。

0.4.1（Build 95）的 DMG 与 Source Release 绑定到 tag `v0.4.1` 指向的 exact
commit。最终公证并 Staple 后的 DMG SHA-256 由 GitHub Release 同名 `.sha256`
文件提供。

### Gatekeeper 与 macOS 安全

0.4.1（Build 95）正式 DMG 使用 Developer ID Application: Yao Lin
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
0.4.1 面向用户的变更摘要见
[`Docs/RELEASE_NOTES_0.4.1.md`](../Docs/RELEASE_NOTES_0.4.1.md)。

## 当前已知限制与风险

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
这些材料保留为历史工程证据；Build 62/63/64/65 均不是当前 Build 95 的发布状态，
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

- source release index：`OKVideoMac-0.4.1-build95-SOURCE_RELEASE_INDEX.json`；
- binary-to-source mapping：
  [`Docs/BINARY_SOURCE_MAPPING.md`](../Docs/BINARY_SOURCE_MAPPING.md)；
- binary/source manifest：
  `OKVideoMac-0.4.1-build95-SOURCE_RELEASE_MANIFEST.json`；
- hashes：`OKVideoMac-0.4.1-build95-SHA256SUMS`；
- macOS SPDX / CycloneDX：`OKVideoMac-macOS.spdx.json`、
  `OKVideoMac-macOS.cdx.json`；
- Android SPDX / CycloneDX：`OKVideoMac-Android.spdx.json`、
  `OKVideoMac-Android.cdx.json`；
- exact APK：`OKVideoMac-0.4.1-AndroidDexBridge-release.apk`；
- exact project source：`OKVideoMac-0.4.1-build95-source.tar.gz`；
- third-party source package：
  `OKVideoMac-0.4.1-build95-third-party-source.tar.gz`；
- license package：`OKVideoMac-0.4.1-build95-licenses.tar.gz`；
- macOS artifact：`OKVideoMac-0.4.1.dmg`。

0.4.1 Build 95 文件清单与生成规则见
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
export OKVIDEOMAC_NOTARY_PROFILE='OKVideoMac-Notary'
OKVideoMac/macOS/OKVideoMac/Scripts/package-app.sh \
  --mode distribution \
  --notarize
```

## 上游与许可证

协议审计固定在 FongMi/TV `fongmi` 分支提交
`5fdff00a602dc56e8ba756174daef20edab024f2`。参考源码不会参与 macOS 构建。

本项目采用 GNU General Public License Version 3。完整条款见 `LICENSE`，
上游来源与本项目修改声明见 `NOTICE.md`。
