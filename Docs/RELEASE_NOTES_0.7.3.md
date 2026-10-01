# OKVideoMac 0.7.3（Build 129）Release Notes

0.7.3 是一次覆盖直播节目单、弹幕、浏览、历史、收藏和播放器稳定性的完整更新。
它不内置任何内容源、账号、Cookie、解析服务或 DRM 密钥。

## 用户可见变化

- **完整节目单：** XMLTV 与 Native Xtream 直播都可进入原生 Full Guide。节目单支持
  日期导航、回到当前时刻、固定时间比例、频道分页、虚拟化绘制、当前节目进度和
  底部详情；短 EPG 也可直接显示在 Native Xtream 频道上。
- **弹幕：** 播放器可读取源提供的 XML/JSON 弹幕、导入 Bilibili XML，或通过已配置
  服务搜索并选择匹配条目。绑定按影片、版本、季集和来源隔离，支持时间校准。
- **历史与收藏：** 两个页面改用原生来源感知列表。续播会核验稳定媒体身份，进度、
  删除、完成标记和批量操作使用事务保护；旧数据会迁移，便携备份更新为 v4。
- **浏览与详情：** 分类、搜索和长剧集列表支持可靠续页；详情结果有界缓存，失败时
  保留已有内容并允许重试。旧请求、迟到回调或离开的页面不会覆盖当前内容。
- **播放器体验：** 点播与直播共享音量/静音记忆；Native Xtream 媒体遵循当前系统
  HTTP/HTTPS 代理。全屏动画保持视频比例，并在系统遗漏过渡完成回调时恢复可退出状态。
- **原生界面：** 点播、直播、历史和收藏统一悬浮、选中和键盘反馈。滚动时悬浮会
  暂停，停稳后按当前鼠标位置恢复；有内容的历史/收藏行保留分割线，空白区不画网格。

## 性能与稳定性

- 弹幕由显示刷新驱动，复用单条文字位图，并使用平滑的播放器媒体时钟。暂停、缓存、
  定位和切集分别同步，减少抖动、跳变和旧弹幕串入新剧集。
- Full Guide 只维护可见频道和有限时间窗，并限制 Xtream 请求数、并发和缓存生命周期；
  大型节目单不会一次创建全部行与节目视图。
- 图片加载、详情缓存、分类续页和多站搜索使用明确的任务所有权及资源上限，减少快速
  导航、滚动或切换来源时的重复工作和过期状态回写。
- 修复直播共用台标预加载崩溃、全屏无法退出、历史误匹配、删除记录被迟到写入重建、
  网盘媒体错误误判为账号失效，以及 Quark 转存生命周期中的竞态。

## 兼容性变化

- Native Xtream 支持认证、Movies、Series、搜索、Basic Live 和短 EPG；完整节目单在
  服务端提供 EPG 数据时可用。回看/时移和 `direct_source` 仍不受支持。
- Android Dex Bridge 更新为 0.3.45（57），增加 Provider 生命周期/媒体代际隔离和
  已验证 Dex/JAR 缓存。Java/Dex `csp_` 兼容仍为 Experimental。
- 源提供弹幕与 Bilibili XML 导入受支持；第三方弹幕搜索只有在用户配置服务后才使用，
  Native Xtream 不会默认把影片标题发送给第三方。
- 继续只支持 Apple Silicon（`arm64`）与 macOS 12.0 或更高版本。

## 已知限制

- TVBox/FongMi 顶层 `lives`、catch-up/timeshift、parser type 2/3/4 和 DRM 不受支持。
- QuickJS、Node、Java/Dex、网页嗅探及网盘接口只覆盖已实现子集，上游变化可能需要适配。
- Managed Android Runtime 的真实 Emulator/Bridge/Dex E2E 证据仍只覆盖一台
  Apple M1 / macOS 14.8.8；macOS 12、13、15 的 App 构建兼容不等于 Runtime 实机验证。
- 实际播放和节目单/弹幕可用性仍取决于所选 Provider、服务器、媒体格式及网络环境。

## 发布验证

- Tag `v0.7.3` 固定 exact release commit `55ffa9d55faced404b20034d7cfe5bcfbc1be581`。
- App 与 DMG 使用 `Developer ID Application: Yao Lin (KGG363ABK9)` 签名；29 个 Mach-O 均为 arm64，并通过 Hardened Runtime、嵌套签名和依赖闭包检查。
- Apple notarization：`Accepted` / `Ready for distribution`，Submission ID `133c1043-d3b8-429a-b502-6dc586de6ab9`，无 issues。
- DMG 已通过 Staple、`stapler validate`、DMG/盘内/安装 App Gatekeeper，以及 QuickJS、MPV/FFmpeg、Node/V8 和 App 启动 smoke。
- 最终 DMG SHA-256：`9cf6c79f9c6d4a8bc7e37e72612e3debc98ca22ffffc3e5e9084c61efe42dbfc`。
- 15 个公开资产包含 DMG、独立校验和、对应源码、第三方源码、许可证、Android Bridge APK、四份 SBOM、manifest、统一 SHA-256、发布说明和第三方声明；内部 ZIP 不公开上传。


以上结果据 [v0.7.3 GitHub Release](https://github.com/yaolin-dev/OKVideoMac/releases/tag/v0.7.3)
补录；原构建时源码与发布资产不变。发布前验收保留在
[0.7.3 发布就绪记录](RELEASE_READINESS_0.7.3.md)。

---

# OKVideoMac 0.7.3 (Build 129)

This release adds a bounded native Full Guide for XMLTV and Native Xtream,
native danmaku with source/XML/service matching, source-aware History and
Favorites, reliable browse pagination and detail caching, remembered audio
preferences, proxy-aware Xtream media, and stronger full-screen recovery.

Danmaku motion now follows the display refresh and reuses rendered text bitmaps.
Guide rows and time windows are virtualized and bounded. Request ownership across
browsing, playback, cloud authorization and Android providers prevents stale work
from replacing a newer page or media session.

Native Xtream supports authentication, Movies, Series, search, Basic Live and
short EPG. Catch-up/timeshift and `direct_source` remain unsupported. Apple Silicon
and macOS 12.0 or later are required. Version 0.7.3 was published on 2026-09-27
with Developer ID signing, Apple notarization (`Accepted`), stapling, Gatekeeper
and installation smoke verified; see the linked GitHub release. This status update
does not alter the immutable build-time notes or assets.
