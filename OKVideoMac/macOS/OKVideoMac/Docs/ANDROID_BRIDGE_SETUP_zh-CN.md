# Android Bridge 设置

[English](ANDROID_BRIDGE_SETUP.md)

Android Bridge 是 OKVideoMac 为部分 Java/Dex `csp_` Provider 提供的可选兼容
运行时。它不是播放器、Native Provider、QuickJS、Node、直播或 XMLTV 的基础依赖。
本文对应 OKVideoMac 0.4.0（Build 94）的当前实现；Bridge 的存在不代表任意
Java/Dex `csp_` Spider 都能兼容。

## 我需要安装 Android 吗？

| 使用场景 | 是否需要 Android |
| --- | --- |
| Native Provider，包括 CMS JSON/XML 响应路径 | 否 |
| FongMi image/Base64 包装 JSON 配置 | 否 |
| QuickJS Spider | 否 |
| Node `.js.md5` Spider | 否 |
| M3U、TXT、JSON 直播和 XMLTV | 否 |
| 普通 libmpv 播放 | 否 |
| 受支持的 Java/Dex `csp_` Spider | 是 |

仅当站点被分派到 Java/Dex Provider 时才会启动 Android Bridge。配置能够被读取，
不代表它一定需要 Android；具体取决于站点的 `type`、`api`、脚本和 Java/Dex 包引用。

## 需要安装什么？

| 组件 | 是否需要 | OKVideoMac 如何识别 | 用户操作 |
| --- | --- | --- | --- |
| Android Studio | 否 | 不检测 IDE | 推荐使用其 SDK Manager 安装下列组件，也可使用官方命令行工具 |
| Android SDK 根目录 | 是 | 按下文顺序查找，或在 App 中手工选择 | 准备一个完整 SDK 目录 |
| Android SDK Platform-Tools / `adb` | 是 | 要求 `<SDK>/platform-tools/adb` 可执行 | 在 SDK Manager 的 **SDK Tools** 中安装 |
| Android Emulator | 是 | 要求 `<SDK>/emulator/emulator` 可执行 | 在 **SDK Tools** 中安装 |
| Android SDK Command-line Tools | 干净安装时需要 | 查找 `cmdline-tools/latest/bin/avdmanager`，再查找其他版本目录 | 在 **SDK Tools** 中安装最新稳定版 |
| Android system image | 是 | 只识别带 `package.xml` 的 `arm64-v8a` image | 安装 API 24 或更高版本的 ARM 64 v8a image |
| AVD | 是，由 App 管理 | 专用名称固定为 `OKVideoMac_Runtime` | 不要手工创建；OKVideoMac 自动创建 |
| Bridge APK | 是，已随 App 提供 | `Contents/Resources/AndroidDexBridge-release.apk` | 无需下载或手工安装 |
| `sdkmanager` | 不是运行时命令 | OKVideoMac 不调用它 | 仅在选择命令行安装 SDK 组件时使用 |

Bridge APK 的 `minSdk` 为 24。运行时代码不锁定单一 API level；它从已安装的
`arm64-v8a` images 中选择 API level 最高的一个，同一 API level 下优先
`google_apis`，其次 `default`，然后是其他 variant。Google Play image 不是硬性
要求，`x86_64` image 不会被当前实现选用。

## 推荐安装流程

1. 确认你确实要使用 Java/Dex `csp_` Provider。其他源可以完全跳过本页。
2. 按 [Android 官方说明](https://developer.android.com/studio/install.html)安装并
   首次启动 Android Studio。Android Studio 是推荐的安装界面，不是 OKVideoMac
   的运行时依赖。
3. 在 Android Studio 中打开 **Tools → SDK Manager**：
   - 在 **SDK Tools** 安装 **Android SDK Platform-Tools**、**Android Emulator**
     和 **Android SDK Command-line Tools (latest)**；
   - 在 **SDK Platforms** 勾选 **Show Package Details**，安装一个 API 24 或更高
     版本的 **ARM 64 v8a System Image**；
   - 记下窗口顶部显示的 **Android SDK Location**。
4. 打开 OKVideoMac 的 **设置 → 高级 → Android 兼容模块**，点击 **检查**。
5. 如果显示“未找到完整 Android SDK”，点击 **选择 SDK…**，选择第 3 步记录的
   SDK 根目录。该目录下必须直接存在 `platform-tools` 和 `emulator`。
6. 点击 **启动**，或直接进入需要 Java/Dex 的站点。首次启动会自动创建专用 AVD、
   启动无窗口 Emulator、安装随包 APK 并建立端口映射，可能需要 1–4 分钟。
7. 当状态显示 **已就绪 — Java/Dex 站点可正常使用** 时，安装验证完成。

无需在 Android Studio 的 Device Manager 中创建 AVD，也无需连接 Android 手机。

## OKVideoMac 如何查找 SDK

运行时按以下顺序选择第一个同时包含可执行 `platform-tools/adb` 和
`emulator/emulator` 的 SDK 根目录：

1. `~/Library/Application Support/OKVideoMac/AndroidRuntime/sdk`（预留的 App
   托管位置；当前版本不会自动下载 SDK 到这里）；
2. 在 **设置 → 高级 → Android 兼容模块 → 选择 SDK…** 中保存的目录；
3. 启动 OKVideoMac 进程时可见的 `ANDROID_HOME`；
4. 启动进程时可见的 `ANDROID_SDK_ROOT`；
5. `~/Library/Android/sdk`；
6. 从 `PATH` 中以 `platform-tools`、`emulator` 或
   `cmdline-tools/<version>/bin` 结尾的条目反推的 SDK 根目录。

这不是 `which adb` 搜索：即使 `adb` 单独出现在 `PATH` 中，只有能从该 PATH 条目
反推出同时包含 `adb` 和 Emulator 的 SDK 根目录时才有效。Finder 启动的 App 也
不一定继承交互式 shell 的环境变量，因此 **选择 SDK…** 是最确定的方法。

## App 管理的 Android 环境

OKVideoMac 不使用用户已有的普通 AVD。它把 `ANDROID_AVD_HOME` 指向：

```text
~/Library/Application Support/OKVideoMac/AndroidRuntime/avd
```

然后通过 `avdmanager create avd` 自动创建 `OKVideoMac_Runtime`，并以无窗口、无
音频、无快照及硬件加速模式启动。它只连接自己启动并验证过的
`emulator-<console-port>`，不支持用真实 Android 设备替代。

Swift 运行时通过指定 serial 的 `adb` 完成设备与 AVD 身份检查、等待开机、
`adb install -r`、Activity 启动和 loopback 端口转发。APK 在 Emulator 内绑定
`127.0.0.1:9978`；Mac 端主要通过 `127.0.0.1:19978` 的 HTTP 接口调用 Bridge，
Bridge 再通过 `DexClassLoader` 加载 `com.github.catvod.spider.<csp_ 后缀>` 并把
JSON 结果返回 Swift Provider。

**停止**只会在 PID、AVD、serial 和进程命令全部匹配运行记录后关闭专用 Emulator；
校验失败时会拒绝操作，避免误停用户的其他 Emulator。

## 高级用户：不用 Android Studio

当前运行时支持标准 Android SDK 目录，不要求 Android Studio 本体。可按照
[Android 官方 `sdkmanager` 文档](https://developer.android.com/tools/sdkmanager)
安装 Platform-Tools、Emulator、Command-line Tools 和符合上述条件的
`arm64-v8a` system image，然后用 **选择 SDK…** 指向该 SDK 根目录。

OKVideoMac 不会调用 `sdkmanager`、接受 SDK license、下载或升级 SDK 组件，也不会
自动修复不完整的 SDK。请只从 Android 官方渠道取得这些组件。

如需只读检查，可在 Terminal 将 `SDK_ROOT` 替换为实际 SDK 根目录：

```bash
test -x "$SDK_ROOT/platform-tools/adb"
test -x "$SDK_ROOT/emulator/emulator"
test -x "$SDK_ROOT/cmdline-tools/latest/bin/avdmanager"
"$SDK_ROOT/platform-tools/adb" version
"$SDK_ROOT/emulator/emulator" -version
find "$SDK_ROOT/system-images" -path '*/arm64-v8a/package.xml' -print
```

`avdmanager` 也可以位于 `cmdline-tools/<version>/bin`。不要把默认
`emulator -list-avds` 的空结果当作故障：OKVideoMac 的专用 AVD 位于独立的
`ANDROID_AVD_HOME`，不会出现在默认用户 AVD 列表中。

## 故障排查

### 未找到完整 Android SDK

SDK 根目录必须同时包含可执行的 `platform-tools/adb` 和 `emulator/emulator`。
在 **设置 → 高级 → Android 兼容模块** 点击 **选择 SDK…**，直接选择 SDK 根目录，
不要选择 `platform-tools` 或 `emulator` 子目录。

### 找不到 `adb`

在 Android Studio 的 SDK Manager 中安装 **Android SDK Platform-Tools**。当前实现
不接受只有真实设备驱动、`fastboot` 或独立脚本而没有上述固定目录结构的环境。

### 缺少 Emulator 或 Emulator 启动失败

安装 **Android Emulator**，并确认其架构适用于 Apple Silicon。运行时使用
`-accel on`；主机必须能够提供 Android Emulator 所需的硬件虚拟化。OKVideoMac
当前只检查文件是否可执行，不会预先验证 Emulator 版本或宿主 CPU 功能，因此
工具存在但无法启动时，错误会在点击 **启动** 后显示。

### 缺少 Command-line Tools（`avdmanager`）

安装 **Android SDK Command-line Tools (latest)**。已有完整专用 AVD 时运行时可以
继续复用它，但干净安装必须用 `avdmanager` 自动创建 AVD。

### 缺少 arm64 Android system image

安装 API 24 或更高版本的 **ARM 64 v8a System Image**。只有 `x86_64` image 不足以
通过当前检查。本版本不会自动下载 image。

### AVD 记录不完整或实例所有权无法确认

运行时会停止并保留记录，且不会操作无法确认归属的 Emulator。先在设置页点击
**检查**；对于正常归属的已启动实例，可尝试 **修复**，它会重建端口映射并重新
安装随包 APK。不要使用 `killall`、`adb kill-server`、删除其他 AVD 或 wipe data
作为常规排查手段。若仍失败，请导出脱敏诊断并提交 issue。

当前 UI 没有“删除并重建专用 AVD”按钮；专用 AVD 目录损坏时需要维护者进一步
诊断，而不是让普通用户手工删除目录。

### Bridge APK 无法启动

正式 App 应包含 `Contents/Resources/AndroidDexBridge-release.apk`。用户不应手工
安装 APK。先点击 **修复**；若提示 App 包缺少 APK，请重新安装官方完整 App，而
不是从第三方下载 APK。

### Native 源正常，Java/Dex Provider 失败

这通常只表示可选 Android 兼容运行时未就绪，不代表 OKVideoMac、libmpv、
QuickJS、Node 或直播功能失效。返回设置页查看 Android 兼容模块的具体状态。

### 如何停止或禁用

状态为“已就绪”时，可在 **设置 → 高级 → Android 兼容模块** 点击 **停止**。当前
版本没有永久禁用开关；再次进入需要 Java/Dex 的站点时会自动准备运行时。完全不
使用 Java/Dex `csp_` Provider 即不会触发它。

退出 OKVideoMac 时不会强制关闭专用 Emulator。如不希望它继续占用资源，请在退出
前点击 **停止**。

## 当前平台范围

0.4.0 公开构建目标是 Apple Silicon / arm64，运行时也只选择 `arm64-v8a`
system image。当前实现不选择 `x86_64` image，因此本文不承诺 Intel Mac 的
Android Bridge 支持，也不需要 Rosetta。

Android SDK 与 Emulator 的安装和硬件要求以 Android 官方文档为准：

- [Install Android Studio](https://developer.android.com/studio/install.html)
- [SDK Manager](https://developer.android.com/studio/intro/update.html#sdk-manager)
- [Configure Emulator acceleration](https://developer.android.com/studio/run/emulator-acceleration)
