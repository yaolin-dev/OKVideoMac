# OKVideoMac

当前发布候选为 **0.8.1（Build 134）**，包含自动更新、分集导航与 CoreAudio 生命周期修复；正式发布须完成签名、公证和全部发布门禁。见[自动更新说明](Docs/AUTOMATIC_UPDATES.md)。

[English](README.md) | 简体中文

**面向 Apple Silicon 的原生 macOS IPTV/点播播放器，支持 Xtream、M3U/XMLTV、
部分 TVBox/CatVod/CatPaw 风格 Provider，以及 libmpv 播放。**

[![最新版本](https://img.shields.io/github/v/release/yaolin-dev/OKVideoMac?display_name=tag&sort=semver)](https://github.com/yaolin-dev/OKVideoMac/releases/latest)
![macOS 12+](https://img.shields.io/badge/macOS-12%2B-000000?logo=apple&logoColor=white)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-arm64-000000?logo=apple&logoColor=white)
[![GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue)](LICENSE)

使用 Swift 和 SwiftUI/AppKit 构建。Android 是部分 Java/Dex Provider 按需使用的
可选兼容层。

最新稳定版本为 **0.8.0（Build 130）**，已完成 Developer ID 签名和 Apple 公证。

**原生 macOS · Xtream · IPTV/点播 · M3U/XMLTV · libmpv · 多 Provider 搜索 ·
QuickJS/Node Spider**

## 下载

### [下载最新稳定版本 →](https://github.com/yaolin-dev/OKVideoMac/releases/latest)

最新稳定版本为 **0.8.0（Build 130）** · macOS 12.0+ · 仅支持 Apple Silicon
（`arm64`）。该版本改进部分 TVBox 配置与授权、CatPaw 搜索与详情、播放器控件、
定位和自动连播，以及 Android Runtime 恢复。

下载已完成 Developer ID 签名和 Apple 公证的
[v0.8.0 DMG](https://github.com/yaolin-dev/OKVideoMac/releases/tag/v0.8.0)。
本版本已通过 Staple、Gatekeeper 评估和安装 smoke test。

打开 DMG，将 `OKVideoMac.app` 拖入“应用程序”即可。无需关闭 Gatekeeper 或 SIP。
每个 Release 同时提供校验和、发布说明、对应源码、SBOM 与第三方声明。

> OKVideoMac 是播放器与 Provider 客户端，不内置第三方影视源、账号、Cookie、
> 解析服务或 DRM 密钥。

## 0.8.0 新增与改进：相对 0.7.3 的变化

- **部分 TVBox 配置与授权：** 配置卡片可取消，原生对话框/网页按当前交互管理；
  确认原生授权后最多重新解析一次同一集，不推测未知登录协议。
- **CatPaw 搜索与详情：** 30 秒有界搜索缓存、相同进行中搜索复用、及时显示部分结果；
  Node 缓存写入不再打断详情。搜索并发上限仍为 20。
- **播放器控件与定位：** 控件按窗口布局，与全屏视频动画分开；边缘时间预览与提示完整
  显示，Seek 由当前 mpv 请求的完成事件确认。
- **自动连播：** 在同季同版本、序号明确的列表中，文件名前缀变化也可按集号连播；
  历史续播等待列表恢复再切集，结束后重播重新加载媒体。
- **Android Runtime 恢复：** 私有 ADB 绑定变化后恢复自有模拟器，诊断导出不启动 ADB；
  Bridge 更新为 0.3.48（60）。

0.8.0 正式版已发布。前后行为对照见
[0.8.0 发布说明](Docs/RELEASE_NOTES_0.8.0.md)，验证见
[正式发布验证](Docs/RELEASE_VALIDATION_0.8.0.md)，回归范围与文件清单见
[发布准备记录](Docs/RELEASE_PREPARATION_0.8.0.md)。

## 0.7.3 新增内容

- **原生完整节目单：** 支持有界加载 XMLTV 与 Native Xtream 节目数据，提供日期导航、
  回到当前时刻、虚拟化频道行和节目详情。
- **原生弹幕：** 支持源提供的 XML/JSON 弹幕、Bilibili XML 导入、本集匹配、候选选择、
  时间校准及与屏幕刷新同步的 AppKit 覆盖层。
- **历史与收藏：** 原生来源感知列表，更安全的续播、删除和进度记录；迁移旧记录，
  便携备份升级到 v4。
- **浏览与播放稳定性：** 分类/搜索续页、详情缓存和异步所有权更加明确；记忆音量，
  Native Xtream 媒体遵循系统代理；改进全屏动画及无法退出全屏时的恢复。
- **界面统一：** 点播、直播、历史和收藏统一原生悬浮与选中反馈；有内容的列表保留
  行分割线，空白区域不再出现网格线。

这些能力已在 0.7.3 发布，不属于 0.8.0 新增功能。范围与限制见
[0.7.3 发布说明](Docs/RELEASE_NOTES_0.7.3.md)。

## 0.6.1 新增内容

- **Android 分类存储统计：** 分别查看托管组件、安装缓存、Android 用户数据与备份，
  并在删除确认中查看本次操作预计释放的空间。
- **安全卸载托管组件：** 在确认本应用的 Android 会话已经停止后，移除可识别的
  OKVideoMac 托管 Android 组件。
- **保留 Android 数据：** 用户数据、登录状态、backing/encryption 文件、Android home、
  私有 ADB 身份、用户数据备份和运行模式选择均保留。External SDK 永远不是卸载目标。
  需要时可重新安装托管组件；当前不提供独立的 Android 用户数据删除入口。
- **恢复与文档：** 中断的维护事务可以继续处理；中英文项目介绍同步突出已有的 Native Xtream。

Native Xtream 已在 0.6.0 引入，包括认证、Movies、Series、电影/剧集搜索和 Basic Live。
0.6.1 当时尚未支持 Xtream EPG、回看/时移与 `direct_source`。详见
[0.6.1 发布说明](Docs/RELEASE_NOTES_0.6.1.md)。

## 软件截图

<p align="center">
  <img src="Docs/Media/v0.6.1/zh-CN/home.jpg" alt="OKVideoMac 中文点播首页" width="100%">
</p>

<table>
  <tr>
    <td width="33%"><img src="Docs/Media/v0.6.1/zh-CN/search.jpg" alt="中文多 Provider 搜索"><br><sub>多 Provider 搜索</sub></td>
    <td width="33%"><img src="Docs/Media/v0.6.1/zh-CN/series-detail.jpg" alt="中文详情与选集导航"><br><sub>详情与选集导航</sub></td>
    <td width="33%"><img src="Docs/Media/v0.6.1/zh-CN/live-channels.jpg" alt="中文直播频道浏览"><br><sub>直播频道浏览</sub></td>
  </tr>
</table>

<table>
  <tr>
    <td width="50%"><img src="Docs/Media/v0.6.1/zh-CN/vod-playback.jpg" alt="中文点播播放器"><br><sub>点播播放</sub></td>
    <td width="50%"><img src="Docs/Media/v0.6.1/zh-CN/live-playback.jpg" alt="中文直播播放器"><br><sub>直播播放</sub></td>
  </tr>
</table>

这些 0.6.1 截图使用简体中文界面和虚构风景演示数据，不包含第三方片库、
账号、凭据或私人 URL。中英文完整文件对照与图像处理说明见
[截图清单](Docs/Media/v0.6.1/README.md)。

## 为什么选择 OKVideoMac

- **原生 Mac 体验。** 采用 SwiftUI/AppKit，为 Apple Silicon 设计，使用原生窗口、
  Sheet、键盘交互、辅助功能和 macOS 导航，而不是重新包装移动端界面。
- **libmpv 播放。** 点播与直播基于 libmpv/FFmpeg，支持 Seek、音轨、字幕、倍速、
  截图、全屏，以及在可用线路间进行有界回退。
- **灵活的 Provider 运行时。** 支持 Native Xtream、CMS JSON，以及部分 TVBox/CatVod 风格
  QuickJS、CatVod/CatPaw 风格 Node 和 Java/Dex `csp_` Spider；兼容边界明确，
  不宣称覆盖整个生态。
- **搜索与资料库。** 多 Provider 隔离搜索、详情、收藏、历史、进度恢复和长剧集
  分段浏览。
- **macOS 直播体验。** 可导入 M3U、TXT、JSON 频道列表，支持多线路和 XMLTV EPG，
  不需要 Android。
- **托管 Android Runtime。** 只有兼容的 Java/Dex Spider 真正需要 Android 时，
  App 才会安装和管理固定环境；高级用户也可明确选择兼容的 External SDK。
- **可核验的正式发布。** 公开 DMG 经过 Developer ID 签名、Apple 公证、Staple 与
  Gatekeeper 验证，并随附哈希及对应源码/SBOM 材料。

## 兼容性速览

| 能力 | 状态 | 说明 |
| --- | --- | --- |
| 原生 macOS 界面 | 支持 | SwiftUI/AppKit，不是 Android UI 套壳 |
| Apple Silicon | 支持 | `arm64`，macOS 12.0 或更高版本 |
| 点播与 libmpv 播放 | 支持 | 实际媒体行为仍取决于源和服务器 |
| 直播与节目单 | 支持 | M3U/TXT/JSON 导入、XMLTV 与 Native Xtream 短 EPG/完整节目单 |
| Native Xtream | 支持 | 账号认证、Movies、Series、搜索、Basic Live 与短 EPG；不同服务端仍有差异 |
| Native CMS JSON | 支持 | 首页、分类、筛选、详情、搜索与播放地址交接 |
| QuickJS Spider | 部分兼容 | 符合当前接口的 selected scripts |
| Node Spider | 部分兼容 | CatVod/CatPaw 风格视频接口子集 |
| Java/Dex `csp_` Spider | 实验性 | 需要 Managed Runtime 或已确认的 External SDK |
| Managed Android Runtime | 可用 | 推荐 Android 模式，仅在需要时安装 |
| 托管组件存储 / 卸载 | 可用 | 分类统计，保留用户数据和外部 SDK |
| External Android SDK | 可用 | 高级用户明确选择，不从 `PATH` 自动切换 |
| Intel Mac | 不支持 | 不提供 Intel 或 Universal Binary 正式包 |

兼容性取决于源格式、运行时、API 结构、解析要求和媒体行为，而不是只看生态名称。
准确边界见[完整兼容性指南](OKVideoMac/macOS/OKVideoMac/Docs/COMPATIBILITY.md)。

## Android Runtime：可选、按需启用

OKVideoMac 的绝大部分功能**不需要 Android**。Native Provider、QuickJS/Node
Spider、直播、XMLTV、搜索与普通播放都直接在 macOS 上运行。

只有部分 Java/Dex `csp_` Android Spider 会使用可选 Android Bridge：

- **Managed Runtime（推荐）：** 第一次真实 Dex 请求出现时，OKVideoMac 先征得
  确认，再把锁定版本的 JRE/Android 组件下载到私有 Application Support 目录，
  校验后自动继续原请求。普通用户无需 Android Studio、Homebrew ADB、系统 Java、
  `ANDROID_HOME` 或手工创建 AVD。
- **External SDK（高级）：** 已有兼容 SDK 的用户可在设置中选择、验证并确认。
  Android Studio、Homebrew、`PATH` 或环境变量不会让 App 静默改变模式。

Android 兼容功能支持查看分类存储占用，并可安全卸载由 OKVideoMac 管理的 Android 组件。
默认保留 Android 用户数据、登录状态、私有 ADB 身份、用户数据备份、运行模式选择及外部 SDK。
确认框根据实际可识别的安装内容估算释放空间，不承诺固定容量。
详见 [Android 存储与卸载](Docs/ANDROID_MANAGED_UNINSTALL.md)。

Managed 安装事务与 Emulator Session 生命周期互相独立。存储、修复、许可证和当前
实机验证边界见 [Android Bridge 设置](OKVideoMac/macOS/OKVideoMac/Docs/ANDROID_BRIDGE_SETUP_zh-CN.md)。

## 快速开始

1. [下载最新稳定版 DMG](https://github.com/yaolin-dev/OKVideoMac/releases/latest)，
   打开后将 App 移入“应用程序”。
2. 启动 OKVideoMac，添加你有权使用的 Provider 配置或直播列表。
3. 浏览、搜索、打开详情，或导入 M3U/TXT/JSON 直播源。
4. 如果所选 Java/Dex Provider 需要 Android，按 App 内提示安装 Managed Runtime；
   其他 Provider 和直播路径不需要 Android 配置。

## Provider / Spider 支持

| 源 / 运行时 | 级别 | 当前范围 |
| --- | --- | --- |
| Native Xtream | 支持 | 账号认证、Movies、Series、搜索、Basic Live 与短 EPG；不支持回看/时移或 `direct_source` |
| Native CMS JSON | 支持 | 主要 Provider 路径 |
| CMS XML / Native type 4 | 部分支持 | 覆盖窄于 CMS JSON |
| TVBox/CatVod 风格 QuickJS | 部分兼容 | `home`、`category`、`detail`、`search`、`play` 与部分辅助接口 |
| CatVod/CatPaw 风格 Node `.js.md5` | 部分兼容 | 已实现的视频接口子集，不是完整 CatPawOpen 协议 |
| Java/Dex Android `csp_` | 实验性 | 通过可选 Bridge 调用部分 CatVod 风格方法 |
| M3U / TXT / JSON 直播 | 支持 | 独立直播导入器；TVBox 顶层 `lives` 尚未接入 |
| XMLTV EPG | 支持 | 远程 HTTP(S)、gzip、缓存与频道匹配 |
| Parser type 0 / 1 | 部分支持 / 支持 | WKWebView 嗅探 / JSON 解析 |
| Parser type 2 / 3 / 4 | 不支持 | 字段可以解析，但没有完整执行路径 |

OKVideoMac 实现的是部分 TVBox、CatVod、CatPaw 风格接口，不是这些项目的官方
客户端，也不保证所有公开或私有 Provider 都能使用。

## 隐私与内容来源

- 不内置影视片库、IPTV 服务、Provider 账号、Cookie、解析服务或 DRM 密钥。
- 由你选择有权访问的配置、脚本、播放列表和媒体。远程 Node bundle 具备较高执行
  权限，只应加载可信来源。
- 日志和诊断按设计会脱敏凭据与私人路径，但公开 Issue 前仍应人工检查内容。
- OKVideoMac 不提供 DRM 绕过；请只用于你获准访问的内容与服务。

## 系统要求

- macOS 12.0 Monterey 或更高版本；
- Apple Silicon（`arm64`），不支持 Intel Mac；
- 远程 Provider/媒体需要网络；选择 Managed Runtime 时也需要联网下载；
- 只有安装可选 Managed Android Runtime 时，才需要为相关大文件预留磁盘空间。

## 常见问题

### 这是 macOS 上的 TVBox 吗？

OKVideoMac 是独立开发的原生 macOS TVBox 风格 Provider 客户端，不是 TVBox 官方
App，也不是 Android 套壳。它实现部分兼容配置和 Spider 路径；寻找“Mac TVBox”
或“TVBox for Mac”的用户应先看兼容表，不要默认某个具体源一定可用。

### OKVideoMac 自带影视源或直播源吗？

不带。它是播放器与 Provider 客户端；配置和播放列表需由用户在有权访问的前提下
提供。App 不内置第三方片库、账号、Cookie、解析服务或 DRM 密钥。

### 需要安装 Android Studio 或 Android SDK 吗？

正常使用不需要，Managed Runtime 也不需要。只有部分 Java/Dex Android Spider
需要 Android 时，OKVideoMac 才会在你确认后下载并管理环境；External SDK 只是
可选的高级模式。

### 为什么 Java/Dex `csp_` Spider 需要 Android？

这类 Provider 包含 Android 字节码。OKVideoMac 通过私有 Android Bridge 运行已
支持的子集；Native、QuickJS、Node、直播和 XMLTV 路径都不使用它。

### 支持 CatVod macOS、CatPaw macOS 或 TVBox Provider 吗？

支持部分 CatVod/FongMi 风格 QuickJS API 和部分 CatVod/CatPaw 风格 Node 视频
接口；Java/Dex 仍为实验性。不能据此理解为完整兼容 TVBox、CatVod、CatPaw 或
CatPawOpen 生态。

### Intel Mac 可以运行吗？

不可以。当前正式版只面向 Apple Silicon；App 和可选 Android Runtime 都没有以
Intel 或 Universal Binary 组合发布。

## 已知限制

- Java/Dex 兼容仍为 Experimental。Managed API 35 Profile 已在一台
  M1 / macOS 14.8.8 上完成 Emulator/Bridge/Dex 实机 E2E；macOS 12、13、15 的
  Managed Emulator E2E 尚未验证。
- QuickJS、Node、网盘和网页嗅探只覆盖已实现接口，上游变化可能需要后续适配。
- TVBox/FongMi 顶层 `lives`、catchup/timeshift、parser type 2/3/4 与 DRM 不受支持。
- 最终播放仍取决于 libmpv、codec、Header/Cookie、媒体服务器和所选 Provider。
- 大型旧数据库可能造成一次性启动停顿。

## 开发与架构

仓库将核心模型/网络、SQLite 持久化、macOS UI、原生播放桥、Provider Runtime、
Managed Runtime 安装与 Android Emulator Session 分开；安装和 Session 生命周期是
彼此独立的状态机。

- [从源码构建](OKVideoMac/macOS/OKVideoMac/Docs/BUILDING.md)
- [架构说明](OKVideoMac/macOS/OKVideoMac/Docs/ARCHITECTURE.md)
- [兼容性证据](OKVideoMac/macOS/OKVideoMac/Docs/COMPATIBILITY.md)
- [参与贡献](CONTRIBUTING.md)

正式 Release 必须使用仓库受控脚本和 fail-closed 门禁；本地 Debug 编译不是公开
发布产物。

## 发布完整性

0.8.0 / Build 130 DMG 已按 [DMG 发布流程](Docs/DMG_RELEASE_PROCESS.md)通过 Release
打包、Developer ID 签名、Apple 公证（`Accepted`）、Staple、Gatekeeper 和安装 smoke test。
Tag `v0.8.0` 固定发布提交 `b049b381db52b5bbbeec9cf58bf54a5bd50a4f39`，下载随附对应
源码归档、SBOM 和校验和。文档状态更新不改变历史签名资产或其源码快照。详见
[0.8.0 正式发布验证](Docs/RELEASE_VALIDATION_0.8.0.md)与[源码发布流程](Docs/SOURCE_RELEASE_PROCESS.md)。

## 文档

- [详细项目文档](OKVideoMac/README.md)
- [兼容性指南](OKVideoMac/macOS/OKVideoMac/Docs/COMPATIBILITY.md)
- [Android Bridge 设置](OKVideoMac/macOS/OKVideoMac/Docs/ANDROID_BRIDGE_SETUP_zh-CN.md)
- [从源码构建](OKVideoMac/macOS/OKVideoMac/Docs/BUILDING.md)
- [架构说明](OKVideoMac/macOS/OKVideoMac/Docs/ARCHITECTURE.md)
- [Android 存储与卸载](Docs/ANDROID_MANAGED_UNINSTALL.md)
- [0.8.0 发布说明](Docs/RELEASE_NOTES_0.8.0.md)
- [0.8.0 正式发布验证](Docs/RELEASE_VALIDATION_0.8.0.md)
- [0.8.0 发布准备与 Git 建议](Docs/RELEASE_PREPARATION_0.8.0.md)
- [0.7.3 发布说明](Docs/RELEASE_NOTES_0.7.3.md)
- [0.6.1 发布说明](Docs/RELEASE_NOTES_0.6.1.md)
- [更新日志](CHANGELOG.md)
- [安全政策](SECURITY.md)

## 许可证

OKVideoMac 依据 [GNU General Public License v3.0](LICENSE) 发布。第三方组件仍受
各自许可证和声明约束。
