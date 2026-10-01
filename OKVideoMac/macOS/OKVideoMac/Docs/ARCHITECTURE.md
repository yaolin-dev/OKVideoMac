# Architecture

## 模块

- `OKVideoCore`：配置、网络协议、站点 DTO/领域模型、搜索/续页、播放解析状态机、
  Spider 接口、直播、XMLTV 和弹幕匹配/解析。
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

## Native Xtream 与语言

Native Xtream 通过 `XtreamClient` 和无共享 Cookie/URL 凭据缓存的 API session
加载目录，使用 `XtreamSiteProvider` 映射 Movies/Series/Search。账号按 Provider UUID
保存在 Keychain；数据库、历史和备份保存描述符与不透明资源引用，播放前才生成 URL。
Basic Live 使用独立 catalog 与频道引用，恢复只在当前频道格式候选之间进行。

Native Xtream short EPG 以频道和有限时间窗按需加载；XMLTV 使用全局解析代际和
频道映射。`LiveGuideDemandCoordinator` 把两种来源统一为可见频道附近的 demand，
限制活跃行、时间片、请求数和并发。节目数据进入固定时间几何的 AppKit 视口，
日期导航、Now 重定位和刷新都保留经过验证的频道/时间锚点。

`ResolvedMedia.compatibilityPolicy` 默认保持既有行为。Native Live 显式选择独立
mpv 实例的网络策略；跨策略切换先释放旧实例，请求代际约束异步加载、关闭和事件。
受控 HLS master 只在内存中存在，不改变其他 Provider 的媒体解析、代理或超时。

UI 使用 `AppLocalizer` 和 String Catalog，持久化稳定语言值，重启后选定语言 bundle。
翻译不参与站点、频道、影片、历史或搜索会话的身份判定。

## 浏览、资料库与弹幕所有权

分类和搜索续页由 route、query、Provider session 与 continuation 共同标识；详情缓存
还包含配置/站点/影片身份和授权代际。页面卸载只取消自己拥有的任务，不能清理已经
替换它的新页面请求。

历史和收藏把展示字段与稳定资源身份分开保存。恢复播放时重新解析原来源并核验
影片/季集/版本，不使用列表位置推测。删除、完成标记和批量收藏变更在数据库事务中
执行；播放器写入携带 session ownership，旧 session 不能重建已删除项目。便携备份
schema v4 只保存可迁移身份，不保存账号凭据或临时媒体会话。

弹幕数据流与媒体启动解耦：

```text
source declaration / imported XML / configured service
  -> payload normalization and XML/JSON parsing
  -> movie + edition + season/episode candidate matching
  -> stable binding and time calibration
  -> player-authoritative smoothed media clock
  -> display-linked lane scheduler
  -> cached text bitmap composition
```

每次播放请求和媒体代际拥有自己的弹幕加载与绑定。手动选择高于保存/来源/自动匹配；
换片、Seek、暂停和缓存不会复用旧的运动状态。弹幕失败不阻塞视频起播。

## 搜索、配置交互与播放队列（0.8.0）

`NodeConfigurationSemanticIdentity` 比较配置语义时移除站点缓存 revision；实际账号/配置
变化与普通缓存写入分流。授权持久身份用 profile identity，页面拥有自己的详情请求。
`CatPawSearchMemory` 以来源语义与 runtime endpoint 标识 owner，使用内存 TTL、容量和
代际保护；耗时只调整 Node slots 的尝试次序。`SearchSnapshotPublisher` 立即发布首批，
以有界定时器发布末批，离开当前搜索时取消。

配置卡片先有独立、可取消、带期限的准备 owner，实际原生 Android UI 出现后才交接到
交互 owner。完成回读携带原分类/筛选/展示身份，仅仍可见时刷新，不重放 action。
Android 配置 WebView、临时网页代理和原生对话框绑定当前 Provider/JAR 与 interaction；
终态清理窗口、Cookie/代理租约及扫码轮询。播放授权保留原 media owner，只在确认后
最多重试一次原集/线路；`TVBoxAuthorizationRoute` 不把任意 HTML 或错误文字当作协议。

`PlaybackResourceAnalyzer` rulesVersion 4 的列表推断按季/版本建立唯一编号视频序列；
列表推断不进入 `trustedEpisode` 的单资源持久身份。自动切集等待历史完整列表恢复，
并重新核验 session、当前集与 autoplay。Replay 从 ended 创建新的媒体/EOF owner。
Seek 先排空旧 native 事件，再建立新的请求代际；完成/重启信号与缓存状态共同判定 ready。

全屏 transform 只作用于视频、字幕与弹幕 composition；控件、提示、面板和结束状态
挂在独立 sibling overlay。viewport 变化和全屏过渡有独立 owner，旧完成回调不能显示
新过渡的控件。AppKit 进度追踪读取当前 pointer，不消费原输入事件。

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
健康和安全关闭。0.8.0 将进程 ownership 与 ADB binding 分开：旧进程仍有私有 AVD
证明而 binding 已失效时，先有界退役原进程再恢复，不并行启动同一 AVD。停止流程保留
记录的 daemon/端口；监听探测失败是 unknown，不能当作空闲。诊断导出使用缓存观察，
不启动 ADB，不以当前选中端口重写原进程身份。

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
- QuickJS Spider 只获得显式提供的受限辅助 API，不获得本地文件或 Shell API。
- Node bundle 在独立子进程中运行并具有 Node 的文件/进程能力；它属于可信配置边界，
  只应加载用户信任且可核验的 bundle。Android/Dex 代码隔离在私有 Emulator/Bridge。
