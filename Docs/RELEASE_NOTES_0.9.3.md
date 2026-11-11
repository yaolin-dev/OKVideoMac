# OKVideoMac 0.9.3（Build 204）Release Notes

- 点播按返回结果的解析要求选择通用解析器，保留上游错误原因。待解析网页提供配置和原网页入口。旧接口误标的直链须先取得媒体字节证据。
- Node 和 Android Java/Dex 的静态 DASH 播放可在传输提前中止时有界续传，验证字节区间和资源身份，再按实际解码进度继续。Android Bridge 为 0.3.59（71）。
- 详情页在首次载入、重试、空结果和延迟补齐季资料时保留线路、分集及文件名区域的位置。
- 直播节目摘要和播放器面板使用窗口内毛玻璃。选台支持收藏、本次会话最近播放及来源分组，并保留分组滚动位置。
- 滚动弹幕随媒体时间连续运动，适应暂停、缓冲、倍速、跳转、全屏和 Retina 变化。
- 兼容 Apple Silicon（arm64）和 macOS 12.0 或更高版本。源站封禁、不可用媒体及缺失的第三方解析服务仍由上游和用户配置决定。

## English

Playback preparation respects parser requirements, preserves upstream errors and verifies media bytes before treating an ambiguous URL as playable. Static DASH recovery in Node and Android Java/Dex validates byte ranges and stream identity before resuming. Detail shelves retain their layout while loading. Live playback gains grouped channel selection and a consistent panel design. Scrolling danmaku follows media time across buffering, seeks, fullscreen and display changes.

Requires Apple Silicon and macOS 12.0 or later. Android Bridge 0.3.59 (71) is bundled for optional Java/Dex providers.
