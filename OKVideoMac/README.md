# OKVideoMac

OKVideoMac 是面向 Apple Silicon Mac 的原生视频与直播客户端，兼容
FongMi/TV 的公开配置协议与主要业务流程。当前版本为 **0.3.41（Build 63）**，
支持 **arm64**，最低系统为 **macOS 12.0**。

项目不内置内容源、账号、Cookie、DRM key 或私人服务配置。请只导入你有权使用
且信任的配置、脚本和媒体。

## 当前版本

- 当前版本：0.3.41（Build 63）
- 最低系统：macOS 12.0
- 支持架构：Apple Silicon / arm64
- 发行验证：198 项 Xcode 集成测试和 94 项 OKVideoKit 测试通过，arm64 Release
  与 Android Release Bridge 构建通过；正式 Release packaging 已验证 28 个
  Mach-O 的架构、部署目标、依赖闭包、签名和 Hardened Runtime
- 对外分发：Build 63 已完成 Developer ID signing、Apple notarization、staple
  和 Gatekeeper 实物验收

## 安装

正式公开版本发布后：

1. 只从本仓库官方 GitHub Releases 页面下载 0.3.41 对应的 macOS arm64 发布包；
2. 打开 `OKVideoMac-0.3.41-macOS-arm64.dmg`；
3. 将 `OKVideoMac.app` 移入 `/Applications`；
4. 从 Applications 或 Finder 正常启动。

不要使用来源不明或无法与本仓库发布哈希对应的第三方二进制。

### Gatekeeper 与 macOS 安全

0.3.41（Build 63）正式 DMG 已使用 Developer ID Application: Yao Lin
（KGG363ABK9）签名，启用 Hardened Runtime，并通过 Apple notarization、staple
和 Gatekeeper 验证。安装和运行不需要关闭任何 macOS 安全机制。

如果 macOS 阻止首次打开已从官方 Release 下载的包，可先在 Finder 中按住
Control 点击（或右键点击）App，再选择 **打开**。也可前往 **系统设置 →
隐私与安全性**，核对 App 来源后选择 **仍要打开**。

不要全局关闭 Gatekeeper、关闭 SIP、删除系统级 quarantine policy、修改系统
安全数据库或使用其他绕过 Apple 安全机制的方法。

请只使用本仓库 GitHub Releases 页面提供的正式 DMG，并核对 Release 页面公布的
SHA-256；本地开发包或来源不明的副本不属于正式发行 artifact。

## Native Mode 与 Android Compatibility Mode

### Native Mode

OKVideoMac 的启动和主要 Native Mode 功能**不要求安装 Android SDK 或
Emulator**。已由当前实现和 Phase 4 证据确认的 Native 能力包括：

- 标准 XML、JSON 和 Base64 配置/数据路径；
- M3U、TXT、JSON 直播源和 XMLTV；
- QuickJS Spider 路径；
- Node Spider 路径；
- 原生 libmpv 点播与直播播放；
- 首页、分类、筛选、详情、搜索、收藏、历史和播放进度恢复。

不同外部配置或 Spider 的实际兼容性仍取决于其实现，不保证任意上游都等价。

### Android Compatibility Mode（Experimental / Advanced Compatibility）

随包提供的 Android APK 是针对部分 Java/Dex `csp_` Spider 的**可选兼容层**。
只有这类兼容能力需要外部 Android SDK、`adb`、Emulator 或兼容 Android
runtime。Android Bridge 是 optional compatibility infrastructure，而不是
OKVideoMac 的启动 prerequisite。

当前实现为 OKVideoMac 使用独立的 App Support AVD，并验证每次启动的 PID、
AVD、动态 serial 与 console port 后才允许执行 `adb` 安装、forward 或停止操作。
它会优先使用 App 托管或用户明确选择的 SDK，再兼容 `ANDROID_HOME`、
`ANDROID_SDK_ROOT`、默认 SDK 目录与 PATH。第一阶段不会自动下载 SDK 或 system
image；缺少已安装的 arm64 system image 或命令行工具时只报告缺项。这不影响
不使用该兼容层的 Native Mode。

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

完整工程状态见
[`Docs/ENGINEERING_OPEN_SOURCE_READINESS_PHASE4.md`](../Docs/ENGINEERING_OPEN_SOURCE_READINESS_PHASE4.md)，
juniversalchardet 结论见
[`Docs/JUNIVERSALCHARDET_ELIMINATION_AUDIT.md`](../Docs/JUNIVERSALCHARDET_ELIMINATION_AUDIT.md)。
这些材料是工程证据，不构成法律意见或“无风险”保证。

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

- source release index：`OKVideoMac-0.3.41-build63-SOURCE_RELEASE_INDEX.json`；
- binary-to-source mapping：
  [`Docs/BINARY_SOURCE_MAPPING.md`](../Docs/BINARY_SOURCE_MAPPING.md)；
- binary/source manifest：
  `OKVideoMac-0.3.41-build63-SOURCE_RELEASE_MANIFEST.json`；
- hashes：`OKVideoMac-0.3.41-build63-SHA256SUMS`；
- macOS SPDX / CycloneDX：`OKVideoMac-macOS.spdx.json`、
  `OKVideoMac-macOS.cdx.json`；
- Android SPDX / CycloneDX：`OKVideoMac-Android.spdx.json`、
  `OKVideoMac-Android.cdx.json`；
- exact APK：`OKVideoMac-0.3.41-AndroidDexBridge-release.apk`；
- exact project source：`OKVideoMac-0.3.41-build63-source.tar.gz`；
- third-party source package：
  `OKVideoMac-0.3.41-build63-third-party-source.tar.gz`；
- license package：`OKVideoMac-0.3.41-build63-licenses.tar.gz`；
- macOS artifact：`OKVideoMac-0.3.41-macOS-arm64.dmg`。

文件清单与生成规则见
[`Docs/SOURCE_RELEASE_PROCESS.md`](../Docs/SOURCE_RELEASE_PROCESS.md) 和
[`Docs/IMMUTABLE_RELEASE_READINESS.md`](../Docs/IMMUTABLE_RELEASE_READINESS.md)。
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
