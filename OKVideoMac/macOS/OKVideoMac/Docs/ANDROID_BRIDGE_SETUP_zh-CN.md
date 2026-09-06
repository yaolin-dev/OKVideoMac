# Android Bridge 设置

[English](ANDROID_BRIDGE_SETUP.md)

Android Bridge 只服务于受支持的 Java/Dex `csp_` Provider。Native、QuickJS、
Node、直播、XMLTV 和普通播放不需要 Android，也不会触发下载。

## 默认安装流程

普通用户不需要 Android Studio、Homebrew、JDK、ADB、SDK Manager 或终端命令。

1. 第一次真正调用 Java/Dex `csp_` 内容时，当前请求暂停。
2. OKVideoMac 显示“Android 兼容组件”，列出真实下载量、所需磁盘空间、安装位置和
   Google Android SDK / Azul Zulu JRE 许可证链接。
3. 许可证不会默认勾选。用户明确同意后才能开始。
4. App 下载固定版本的组件，显示真实字节进度，并依次完成校验、解压、安装、验证
   和启用。
5. 安装和 Managed Environment Purity 全部通过后，原来的内容请求自动继续。

也可以从 **设置 → Android 兼容模块** 主动安装、查看详情、更新、修复或导出诊断。

## 安装内容与位置

App 包内不包含数 GB Runtime。组件按需安装到：

```text
~/Library/Application Support/OKVideoMac/AndroidRuntime/
  Generations/<generation>/{sdk,jre}
  current-runtime.json
  Downloads/
  Staging/
  Backups/
  avd/
  home/.android/
```

当前默认安装 Profile 为 API 35、Google APIs、`arm64-v8a`。JRE、Command-line
Tools、Platform Tools/ADB、Android Platform、Emulator 和 system image 均由
Catalog 固定版本、URL、大小、SHA-256、架构、许可证和 archive layout。

Runtime Generation 是不可变目录；更新先安装并验证新 Generation，再原子切换
`current-runtime.json`。AVD 在 Generation 外单独保存，所以工具升级不会覆盖
userdata。修复只重装受管组件，并保留 AVD、收藏、历史和普通设置。

## 安全与隔离

- 所有 Android/Java 子进程必须来自当前 Managed Generation。
- ADB 使用 OKVideoMac 私有高位端口和私有 keypair。
- AVD 只位于 OKVideoMac 的 `AndroidRuntime/avd`。
- 子进程使用显式构建的 `PATH`、`JAVA_HOME`、`ANDROID_HOME`、
  `ANDROID_SDK_ROOT`、`ANDROID_AVD_HOME`、`ANDROID_USER_HOME`、
  `ANDROID_EMULATOR_HOME` 和 `ADB_VENDOR_KEYS`。
- 一旦存在 Managed Runtime 指针，解析失败会直接报错，不会偷偷退回 Android
  Studio、Homebrew、系统 Java 或用户 shell `PATH`。
- 安装与 Emulator Session 使用两套独立 single-flight：并发安装请求共享一个安装
  事务，并发 Runtime 请求继续共享现有一个 Emulator 启动任务。

Catalog 被当作不可信输入。非 HTTPS、非白名单 host、错误 SHA-256、路径穿越、
绝对路径、重复 ID、异常 archive root、symlink escape 或解压尺寸超限都会在激活前
失败。失败或取消不会修改当前指针；已完成的安全下载可在重试时复用，部分下载支持
HTTP Range 续传。

## 常见问题

### 下载失败

检查网络后重试。可续传的 `.partial` 会保留；错误或超限文件不会被激活。

### 校验失败

该文件会被拒绝，Generation 不会生效，旧 Runtime 和 AVD 保持不变。不要从第三方
来源手工替换文件。

### 磁盘空间不足

安装前会按下载临时空间、两份展开空间和安全余量检查容量。释放空间后重试，无需
删除 AVD。

### Runtime 损坏或不兼容

在设置页选择“修复”。修复使用可恢复备份重新安装 Managed Generation，不会删除
用户其他 AVD、`~/.android/adbkey`、Android Studio SDK、收藏或历史。

### Emulator 或 Bridge 启动失败

安装成功不等于每个第三方 Spider 都兼容。先使用“导出诊断”；报告包含 Runtime
Profile、版本、Purity、ADB/Emulator/Bridge 状态和时间线，但会脱敏用户名路径，
且不包含 Cookie、Token、私人源 URL、播放地址、Spider 内容或 adb private key。

## Legacy / Troubleshooting / Developer Setup

“旧版手动环境…”入口仅用于维护者和历史环境排查。只有在不存在 Managed Runtime
指针时，旧 resolver 才可能读取手工选择的 SDK、`ANDROID_HOME` 或标准 SDK 目录。
它不是普通用户安装路径，也不具备 Managed Runtime 的版本、Purity 和回滚保证。

## 兼容性声明

- App 静态支持：Apple Silicon / arm64，macOS 12.0+。
- Managed API 35 Runtime 实机 E2E：Apple M1、macOS 14.8.8。
- macOS 12、13、15：尚无真实机器 Emulator E2E，不应描述为已实机验证。
- Java/Dex Spider：Selected/Experimental 子集，不保证任意 TVBox/FongMi Spider。

Android SDK/Emulator 的上游条款与信息以
[Android Developers](https://developer.android.com/studio)为准；Zulu JRE 信息以
[Azul](https://www.azul.com/downloads/)为准。
