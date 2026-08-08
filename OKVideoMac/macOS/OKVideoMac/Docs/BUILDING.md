# Building OKVideoMac

## 当前已知环境状态

2026-07-29 检查结果：

- macOS 12.7.6 arm64；
- Swift 5.7.2；
- 只有 Command Line Tools，没有完整 Xcode；
- CLT 编译器和 SDK Swift 模块版本不匹配；
- XCTest 不可用；
- Homebrew 存在，但当前 Homebrew 6.0.2 在 Monterey 上安装源码公式时出现
  公式 DSL 兼容错误；
- 因此本机原生依赖改由 MacPorts `/opt/local` 提供；
- MacPorts 本体位于系统盘 `/opt/local`，不是移动硬盘；当前仅安装 MacPorts
  本体，ports 数量为 0；
- XcodeGen 未安装到 PATH，但已用官方 2.38.0 二进制成功生成工程；
- Meson、Ninja、mpv/libmpv 和 FFmpeg/libass 开发包不存在；
- QuickJS 2025-09-13-2 已成功构建并通过原生桥 smoke test。

因此当前仓库中的测试和 App 尚未在本机成功编译。安装完整 Xcode 14.2 后必须
重新执行以下全部门禁。

## 前置条件

1. 安装完整 Xcode 14.2，并选择其 Developer 目录：

   ```bash
   ./Scripts/mount-xcode-dev.sh
   sudo xcode-select -s /Volumes/XcodeDev/Xcode.app/Contents/Developer
   ```

   本机将 Xcode 放在 T7 Shield 内的 APFS 稀疏卷
   `/Volumes/T7 Shield/XcodeDev.sparsebundle`。不要把 Xcode.app 直接放在
   exFAT 文件系统上；重启或重新连接移动硬盘后，先运行挂载脚本。

2. Xcode 验证完成后，安装最小开发期工具：XcodeGen 2.38+、Meson、Ninja、
   pkg-config、FFmpeg 和 libass。Monterey 本机仅使用 MacPorts：

   ```bash
   sudo /opt/local/bin/port install meson ninja pkgconfig ffmpeg7 libass
   ```

   `bootstrap.sh` 和 `build-libmpv.sh` 固定使用 `/opt/local/bin` 和
   MacPorts 的 pkg-config 搜索路径，并拒绝解析到 `/opt/homebrew` 的
   FFmpeg/libass。
3. 构建 libmpv 时需要 FFmpeg、libass 及 mpv Meson 检测到的依赖。这些只允许
   作为构建期依赖；最终 `.app` 必须携带完整 dylib 闭包。

## 工程和测试

```bash
cd OKVideoMac/macOS/OKVideoMac
./Scripts/bootstrap.sh
swift test \
  --package-path Packages/OKVideoKit \
  --scratch-path /Volumes/XcodeDev/OKVideoMacBuild/SwiftPM
xcodebuild \
  -project OKVideoMac.xcodeproj \
  -scheme OKVideoMac \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /Volumes/XcodeDev/OKVideoMacBuild/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
xcodebuild \
  -project OKVideoMac.xcodeproj \
  -scheme OKVideoMac \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /Volumes/XcodeDev/OKVideoMacBuild/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  test
```

脚本在 `/Volumes/XcodeDev` 已挂载时默认设置
`OKVIDEOMAC_BUILD_ROOT=/Volumes/XcodeDev/OKVideoMacBuild`。下载缓存、第三方
源码、原生构建目录、DerivedData 和最终 `Artifacts` 都放在该目录；只有
MacPorts 本体、头文件和动态库位于系统盘 `/opt/local`。

## 原生依赖

```bash
./Scripts/build-quickjs.sh
./Scripts/build-libmpv.sh
```

脚本固定 QuickJS 2025-09-13-2 和 mpv v0.41.0，并验证源码 SHA-256。
QuickJS 脚本会同时构建 `libOKQuickJS.dylib` 并运行 C smoke test。
libmpv 脚本会构建 `libmpv.dylib` 和 `libOKMPVBridge.dylib`。Xcode 工程在
这些文件存在时把它们和许可证复制到 App。当前机器尚未执行 libmpv 构建；
即使依赖脚本成功，仍须完成 App 构建与真实播放门禁。

## 打包

```bash
./Scripts/package-app.sh
```

打包脚本会：

- Release clean build；
- 把 libmpv、mpv/QuickJS 桥和非系统 dylib 复制到 `Contents/Frameworks`；
- 改写 install name 为 `@rpath`；
- 逐个 ad-hoc 签名；
- 拒绝 Homebrew、MacPorts、`/usr/local` 和 `/Users/...` 绝对依赖；
- 拒绝非 arm64、桥接未指向 `@rpath/libmpv.dylib` 或无效签名；
- 输出可分发 zip 和对应 SHA-256。

App 通过运行时桥接载入 libmpv，因此主可执行文件不直接链接 mpv；验证脚本
检查 `libOKMPVBridge.dylib` 的链接和整个 dylib 闭包。依赖或完整 Xcode 缺失
时，打包会按设计失败。
