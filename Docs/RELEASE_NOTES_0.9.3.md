# OKVideoMac 0.9.3（Build 207）Release Notes

Build 207 为尚未公开发布的本地候选：音量偏好迁移到独立存储域，拖动时即时更新内存与播放器，松手、关闭或退出时保存最终值，避免共享 UserDefaults 通知牵动详情页。字幕与内置音轨按类型合并待执行选择；在原生队列、界面回写和数据库事务边界校验播放会话与选择代次，字幕状态改为局部观察。保留既有布局、音量命令合并与渲染线程。Build 206 的真实拖动卡顿已由用户确认仍存在；本候选的自动化及实机验收结果以 output/track-switch-207/Verification 为准，不宣称既有崩溃根因或完整媒体矩阵已解决。

## 已发布 Build 204 的功能范围

- 点播按返回结果的解析要求选择通用解析器，保留上游错误原因。待解析网页提供配置和原网页入口。旧接口误标的直链须先取得媒体字节证据。
- Node 和 Android Java/Dex 的静态 DASH 播放可在传输提前中止时有界续传，验证字节区间和资源身份，再按实际解码进度继续。Android Bridge 为 0.3.59（71）。
- 详情页在首次载入、重试、空结果和延迟补齐季资料时保留线路、分集及文件名区域的位置。
- 直播节目摘要和播放器面板使用窗口内毛玻璃。选台支持收藏、本次会话最近播放及来源分组，并保留分组滚动位置。
- 滚动弹幕随媒体时间连续运动，适应暂停、缓冲、倍速、跳转、全屏和 Retina 变化。
- 兼容 Apple Silicon（arm64）和 macOS 12.0 或更高版本。源站封禁、不可用媒体及缺失的第三方解析服务仍由上游和用户配置决定。

## English

Playback preparation respects parser requirements, preserves upstream errors and verifies media bytes before treating an ambiguous URL as playable. Static DASH recovery in Node and Android Java/Dex validates byte ranges and stream identity before resuming. Detail shelves retain their layout while loading. Live playback gains grouped channel selection and a consistent panel design. Scrolling danmaku follows media time across buffering, seeks, fullscreen and display changes.

Requires Apple Silicon and macOS 12.0 or later. Android Bridge 0.3.59 (71) is bundled for optional Java/Dex providers.
