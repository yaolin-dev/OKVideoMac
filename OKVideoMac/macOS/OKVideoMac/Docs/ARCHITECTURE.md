# Architecture

## 模块

- `OKVideoCore`：配置、网络协议、站点 DTO/领域模型、搜索、播放解析状态机、
  Spider 接口、直播和 XMLTV。
- `OKVideoPersistence`：SQLite 连接、迁移和 Repository。
- `OKVideoMac`：SwiftUI/AppKit、文件选择、WKWebView 和运行时依赖装配。
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

## 安全边界

- 网络客户端默认只接受 HTTP/HTTPS。
- 本地配置只能由文件选择或 Finder 打开进入。
- WebView 使用非持久化数据存储，消息桥只有媒体候选上报。
- 日志对 Authorization、Cookie、Token、密码和敏感 Query 脱敏。
- 原始配置只保存一份离线副本；Application Support 目录权限为当前用户独占。
- Spider 不获得本地文件和 Shell API。
