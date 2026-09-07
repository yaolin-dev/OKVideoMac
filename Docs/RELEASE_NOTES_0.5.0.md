# OKVideoMac 0.5.0（Build 99）Release Notes

发布日期：2026-09-07

正式 Tag：`v0.5.0`

平台：Apple Silicon / arm64 / macOS 12.0+

0.5.0 让 Android 兼容环境从单一、易受本机环境影响的路径，升级为可明确选择、
可安全迁移、并且互相隔离的 Managed Runtime 与 External SDK 两种模式。

## Android 环境现在有两种方式

### Managed Runtime（推荐）

适合普通用户。第一次真正使用 Java/Dex `csp_` 源时，OKVideoMac 会先暂停
当前请求，由用户确认许可后下载固定版本的 JRE、Android 工具、Emulator 和
API 35 Google APIs arm64 镜像。所有大文件存放在 OKVideoMac 私有目录，不进入
App 包体。

下载支持续传，组件使用 SHA-256、来源 host、archive layout 和尺寸门禁校验。
新 Runtime 在 staging 中完整验证后才以不可变 Generation 原子启用；失败或取消
不会损坏已有 Runtime 或 AVD userdata。

### External SDK（高级）

适合已经配置 Android SDK 的老用户和高级用户。可在设置中选择 SDK，查看
“可启动”与“可创建/修复”两类能力，再明确确认使用。已有兼容 AVD 时，
仅缺少 Java 或 `avdmanager` 不会错误阻止启动，只影响新建或修复能力。

从旧版升级时，只有历史上由 OKVideoMac 明确保存的 SDK 配置才会进入一次性
External 迁移。`PATH`、`ANDROID_HOME`、Homebrew 或 Android Studio 不会让 App 静默
切换环境。

## 环境隔离与 AVD 安全

- Managed 模式只使用已验证 Generation；External 模式只使用用户明确确认的 SDK。
- External 模式不触发 Managed installer，Managed 模式不读取或启动 External 工具。
- Runtime 选择以版本化的 `runtime-selection.json` 原子保存；失败或取消不会留下
  半切换状态。
- App 私有 AVD 使用 Runtime 来源、identity、API、ABI、system image、schema 和
  Emulator 兼容指纹。不兼容时 fail closed，不静默删除或重建 userdata。
- private ADB、私有 keypair、专用 Android home、ownership、Emulator 启动
  single-flight、GPU fallback 和 stale runtime 恢复继续由原有 Session 生命周期管理。

## 退出体验

使用 Android 兼容模块后退出 OKVideoMac，可见窗口现在会快速离开屏幕，避免用户
把 Emulator 安全退出时间感知为 App 卡住。后台仍优先执行 `adb emu kill` 并保留
完整 graceful window；严格验证 ownership 后才会进入有界的 `SIGTERM` / `SIGKILL`
兜底。该流程不会关闭 Android Studio、其他 AVD 或用户的 ADB server。

## 其他改进

- 改善 ADB `offline` / missing transport 的等待、诊断、目标 reconnect 与有界 GPU fallback。
- 为 API 24–29 私有无窗口 Runtime 保留旧 Guest ADB 认证兼容路径。
- 采用 AppKit 原生 Source List 与 Sidebar 材质；搜索中 Esc 先清除非空关键字，空框再次
  Esc 才退出搜索。

## 下载

本版仅支持 Apple Silicon Mac，需要 macOS 12.0 或更高版本。请从 `v0.5.0` GitHub
Release 下载经 Developer ID 签名、Apple 公证并已 Staple 的
`OKVideoMac-0.5.0.dmg`，并使用同名 `.sha256` 文件核对。

## 已知验证边界

- Java/Dex 兼容仍为 Selected/Experimental 子集，不保证任意 TVBox/FongMi Spider。
- Managed API 35 Runtime 已在 Apple M1 / macOS 14.8.8 跑通 Emulator、private ADB、
  Bridge、Dex 和第二次复用链路。
- 本轮因没有第二台全新物理 Mac，未重新执行完全空白机器上的 Managed Runtime
  在线首次下载安装 E2E；这不应记为 PASS。
- macOS 12、13 和 15 尚无 Managed Emulator 实机 E2E；App deployment target 不等于
  Android Guest/HVF/gfxstream 实机验证。

OKVideoMac 不内置影视源、账号、Cookie、解析服务或 DRM 密钥。请只使用你有权
访问的配置与内容。

---

# OKVideoMac 0.5.0 (Build 99) Release Notes

Release date: 2026-09-07
Tag: `v0.5.0`
Platform: Apple Silicon / arm64 / macOS 12.0+

Android compatibility now provides two explicit modes. **Managed Runtime** is
the recommended default and can transactionally install a pinned JRE, Android
toolchain, Emulator, and API 35 Google APIs arm64 image into private
Application Support storage. **External SDK** lets existing and advanced users
explicitly retain a compatible SDK without triggering Managed installation.

The versioned `runtime-selection.json` is committed atomically. Environment
variables, Homebrew, and Android Studio never silently change the selected
mode. Managed and External execution are isolated, while private ADB, AVD
ownership, Emulator startup single-flight, GPU fallback, and stale recovery
remain under the existing Session lifecycle. A strict compatibility fingerprint
fails closed without silently deleting AVD userdata.

App Quit now withdraws visible windows promptly while the owned Android Runtime
continues safe cleanup in the background. The full healthy `adb emu kill` grace
period is preserved; bounded signals remain last-resort fallbacks after strict
ownership verification. Unrelated Emulators and ADB servers are never targeted.

This release also improves ADB offline/missing-transport recovery, retains the
private API 24–29 guest-auth compatibility path, adopts an AppKit-native sidebar,
and matches the App Store two-step Escape behavior in search.

Download the Developer ID-signed, Apple-notarized, and stapled
`OKVideoMac-0.5.0.dmg` from the `v0.5.0` GitHub Release and verify it with the
accompanying `.sha256` file.

Managed API 35 has real Emulator/Bridge/Dex lifecycle evidence on Apple M1 /
macOS 14.8.8. This release did not rerun first-time online installation on a
second completely clean physical Mac, and macOS 12, 13, and 15 Managed Emulator
E2E remain unverified. Java/Dex compatibility remains Selected/Experimental.
