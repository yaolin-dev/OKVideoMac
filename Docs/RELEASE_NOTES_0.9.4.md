# OKVideoMac 0.9.4（Build 208）Release Notes

## 播放

- 隔离音量偏好，拖动时即时调节，手势结束后保存最终值，避免详情页频繁刷新造成播放卡顿。
- 合并快速的字幕和音轨切换，跳过重复选择，过滤已结束播放会话的回调。

内置音轨切换时，音频设备或解码器可能因轨道格式变化短暂重建。

## 崩溃诊断

- 用户启用崩溃上报后，提供可用的 Objective-C 原始异常信息、首次抛出栈和有限的脱敏操作类型。

操作记录只包含固定类型，例如打开详情、开始播放、窗口缩放，不包含输入文字、片名或媒体地址。崩溃上报默认关闭。见[诊断配置与字段](CRASH_REPORTING_RELEASE_CONFIGURATION.md)。

适用于 Apple Silicon（arm64），最低 macOS 12.0。可选 Android Bridge 版本为 0.3.59（71）。安装时打开 DMG，将 OKVideoMac 拖入 Applications。

## English

- Keep playback responsive when dragging volume by isolating audio preferences and saving the final value after the gesture.
- Coalesce rapid subtitle and audio track changes, skip duplicate selections, and discard callbacks for retired playback sessions.
- With crash reporting enabled, include available original Objective-C exception details, the first throw stack, and a bounded sequence of sanitized operation types.

Requires Apple Silicon and macOS 12.0 or later. Includes optional Android Bridge 0.3.59 (71). Open the DMG and drag OKVideoMac to Applications.
