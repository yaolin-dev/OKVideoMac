# Architecture

## 模块

- `OKVideoCore`：配置、网络协议、站点 DTO/领域模型、搜索、播放解析状态机、
  Spider 接口、直播和 XMLTV。
- `OKVideoPersistence`：SQLite 连接、迁移和 Repository。
- `OKVideoMac`：SwiftUI/AppKit、文件选择、WKWebView 和运行时依赖装配。
- `AndroidRuntimeKit`：Managed Runtime Catalog、检测、下载、事务安装、Generation、
  Purity、修复与诊断；不拥有 Emulator Session。
- `Vendor/Build`：由脚本产生的 QuickJS、libmpv 和临时源码，不提交。

## 数据流

```text
URL / file / pasted JSON
  -> size and scheme policy
  -> FongMiConfiguration + unknown JSONValue fields
  -> validation
  -> SQLite last-known-good configuration
  -> SiteProvider
  -> upstream DTO
  -> Video domain model
  -> AppState @MainActor
  -> SwiftUI
```

播放使用独立路径：

```text
PlayEpisode
  -> SiteProvider.player
  -> PlaybackResolver AsyncStream
  -> direct / JSON parser / WebSniffer
  -> ResolvedMedia
  -> PlayerClient serial command/event queue
  -> libOKMPVBridge
  -> libmpv Client API
  -> mpv Render API
  -> NSOpenGLView
```

UI 不持有 URLSession、SQL、JavaScript Context 或 mpv handle。所有这些依赖均由
协议隔离。数据库通过 actor 串行化；站点和解析器失败作为值传给 UI，不吞掉。
OpenGL Render Context 由 `MPVOpenGLView` 创建和销毁，普通 mpv 命令不会在
Render 回调或 OpenGL 绘制线程执行。

## Android Runtime 边界

Android 安装与 Emulator Session 是两套独立状态机：

```text
Dex / Settings
  -> AndroidRuntimeModeCoordinator
     -> Managed: AndroidRuntimeKit installation / validated Generation
     -> External: exact user-confirmed SDK / split capability validation
  -> AndroidDexBridgeRuntime Session
     -> private ADB / owned AVD / Emulator / Bridge
```

`AndroidRuntime/runtime-selection.json` 以版本化、原子方式保存 mode 和 SDK identity。
迁移优先级为：保留显式 mode；其次使用完整验证可用的 Managed Generation；
再次迁移历史上由 OKVideoMac 明确保存的 External SDK；否则默认 Managed。
`PATH`、`ANDROID_HOME`、Homebrew 和 Android Studio 自动发现不参与模式决策。

Managed 和 External 执行路径互相隔离。External 校验把已有 AVD 启动能力与需要
Java / `avdmanager` 的创建修复能力分开。切换 mode 前必须停止 Session。共用 App
私有 AVD 受 Runtime 来源和 identity、API、ABI、system image package/tag、AVD
schema 及 Emulator 兼容指纹保护；不兼容时 fail closed，不静默删除 userdata。

安装 single-flight 与 Session 启动 single-flight 独立。原有 Session 继续负责 private
ADB 高位端口与 keypair、进程 ownership、GPU fallback、offline recovery、Bridge
健康和安全关闭。

## App 退出生命周期

AppKit 只有一个 termination flight。用户确认退出后，所有可见 App 窗口先同步
`orderOut`，然后 Player、历史、Node 和 Android cleanup 在后台并发完成，最后回复
AppKit 终止。因此 UI 离开屏幕与 Runtime 清理完成已解耦。

Android 关闭依次优先 `adb emu kill` 和完整 graceful window，并且只在 PID、出生
identity、AVD 和 private ADB 所有权严格验证后才进入有界 `SIGTERM`、最后
`SIGKILL` 兜底。重复退出不会启动第二个 cleanup；非 OKVideoMac 拥有的 Emulator、
AVD 和 ADB server 不在清理范围。

## 安全边界

- 网络客户端默认只接受 HTTP/HTTPS。
- 本地配置只能由文件选择或 Finder 打开进入。
- WebView 使用非持久化数据存储，消息桥只有媒体候选上报。
- 日志对 Authorization、Cookie、Token、密码和敏感 Query 脱敏。
- 原始配置只保存一份离线副本；Application Support 目录权限为当前用户独占。
- Spider 不获得本地文件和 Shell API。
