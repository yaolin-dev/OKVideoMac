# OKVideoMac 0.4.1（Build 95）Release Notes

发布日期：2026-09-06

正式 Tag：`v0.4.1`

平台：Apple Silicon / arm64 / macOS 12.0+

这个版本主要提升 TVBox / Java Spider Android Runtime 的稳定性和生命周期管理。

## 修复

- 修复部分情况下 OKVideoMac 自己启动的 Android Runtime 被误判为其他 Emulator
  的问题。
- 修复 App 重启后无法安全复用已有 Runtime 的问题。
- 支持自动接管 OKVideoMac 自己启动且仍然健康或仍在启动中的 Emulator。
- 修复并发请求可能重复触发 Runtime 启动的问题。
- 改善 Emulator 启动过程中 ADB 尚未就绪、offline 或暂时缺少目标设备时的等待、
  恢复和诊断。
- 优化 App 正常退出时 Android Runtime 的自动关闭。
- 改善 App 异常退出后下一次启动对残留 Runtime 的自动接管和恢复。
- 加强 Runtime ownership 校验，避免影响 Android Studio 或用户其他 AVD。

## 稳定性

- Android Runtime 启动采用进程级 single-flight 管理。
- 已有健康 Runtime 可以直接复用，无需重复启动。
- 增强 stale metadata、私有 AVD lock 和端口冲突检测。
- 增强 Runtime shutdown 安全校验，并防止退出过程中被迟到请求重新启动。

## 下载

适用于 Apple Silicon Mac，要求 macOS 12 或更高版本。请从 `v0.4.1` GitHub
Release 下载经过 Developer ID 签名、Apple 公证并已 Staple 的
`OKVideoMac-0.4.1.dmg`，并使用一同发布的 `.sha256` 文件核对下载。

OKVideoMac 不内置影视源、账号、Cookie、解析服务或 DRM 密钥。请只使用你有权
访问的配置与内容。

## 已知限制

- 不支持 Intel / x86_64 / Universal Binary。
- Java/Dex 兼容仍为 Experimental，需要外部 Android SDK、ADB、Emulator 和兼容
  的 arm64 system image。
- 第三方 Spider、网页和网盘接口可能独立变化。

---

# OKVideoMac 0.4.1 (Build 95) Release Notes

Release date: 2026-09-06

Tag: `v0.4.1`

Platform: Apple Silicon / arm64 / macOS 12.0+

This release focuses on Android Runtime lifecycle reliability for selected
TVBox and Java Spider compatibility paths.

## Fixes

- Fixed cases where an OKVideoMac-managed Android Runtime was mistaken for an
  unrelated Emulator.
- Fixed App restarts failing to safely reuse an existing private Runtime.
- Healthy or still-booting Emulators started by OKVideoMac can now be adopted
  instead of launched again.
- Fixed concurrent requests potentially triggering duplicate Runtime startup.
- Improved waiting, recovery, and diagnostics while ADB is starting, offline,
  or temporarily missing the expected Emulator transport.
- The private Android Runtime is now closed automatically during normal App
  termination.
- Improved recovery of a Runtime left behind after a crash or forced exit.
- Strengthened ownership validation so Android Studio and other user AVDs are
  not affected by OKVideoMac cleanup.

## Stability

- Android Runtime startup now uses process-wide single-flight coordination.
- A healthy existing Runtime can be reused without another launch.
- Stale metadata, private AVD lock, and port-conflict handling are more robust.
- Shutdown validation prevents late requests from restarting the Runtime while
  the App is terminating.

## Download

For Apple Silicon Macs running macOS 12 or later. Download the Developer
ID-signed, Apple-notarized, and stapled `OKVideoMac-0.4.1.dmg` from the
`v0.4.1` GitHub Release and verify it with the accompanying `.sha256` file.

OKVideoMac does not bundle content sources, accounts, cookies, parsing
services, or DRM keys. Use only configurations and content you are authorized
to access.

## Known limitations

- Intel / x86_64 and Universal Binary builds are not provided.
- Java/Dex compatibility remains Experimental and requires an external Android
  SDK, ADB, Emulator, and compatible arm64 system image.
- Third-party Spider, web, and cloud interfaces can change independently.
