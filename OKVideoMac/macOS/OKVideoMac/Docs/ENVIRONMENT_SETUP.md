# 本机开发环境记录

更新时间：2026-07-30  
主机：macOS 12.7.6、Apple Silicon（arm64）

## 当前结论

- Xcode 14.2 已安装在 `/path/to/Xcode.app`，许可、首次启动组件和
  Command Line Tools 均已完成初始化。
- MacPorts 2.12.5 安装在系统盘 `/opt/local`。MacPorts **没有**安装在移动
  硬盘。
- MacPorts ports 树是移动盘上的官方 Git 仓库工作树，唯一远端为
  `https://github.com/macports/macports-ports.git`。
- libmpv 0.41.0 已在移动盘构建为 arm64、最低 macOS 12，并通过桥接库冒烟
  测试。
- Swift Package 的 41 个测试、Xcode Debug App 构建和 Xcode App 测试
  Target 均已通过。
- Debug App 已嵌入 `libmpv.dylib` 和 `libOKMPVBridge.dylib`，但此阶段的
  libmpv 仍引用 `/opt/local` 依赖。递归收集依赖、改写 `@rpath` 和独立移动
  启动属于发布打包门禁，不能把当前 Debug App 标记为“独立分发包”。

## 路径边界

| 内容 | 实际路径 | 所在磁盘 |
|---|---|---|
| MacPorts 本体、ports、头文件、动态库 | `/opt/local` | 系统盘 |
| Xcode 14.2 | `/path/to/Xcode.app` | T7 Shield 内的 APFS 稀疏卷 |
| 下载、第三方源码、原生构建 | `/path/to/OKVideoMacBuild` | T7 Shield 内的 APFS 稀疏卷 |
| App DerivedData | `/path/to/OKVideoMacBuild/DerivedData` | T7 Shield 内的 APFS 稀疏卷 |
| Xcode 测试 DerivedData | `/path/to/OKVideoMacBuild/DerivedData-Test` | T7 Shield 内的 APFS 稀疏卷 |
| SwiftPM scratch | `/path/to/OKVideoMacBuild/SwiftPM` | T7 Shield 内的 APFS 稀疏卷 |
| 最终发布产物（预留） | `/path/to/OKVideoMacBuild/Artifacts` | T7 Shield 内的 APFS 稀疏卷 |

外置卷来自：

```text
/path/to/XcodeDev.sparsebundle
```

外置盘断开后，Xcode、ports 源码树和构建目录不可用；`/opt/local` 仍位于系统
盘，但不能据此误报为一套可构建环境。

## Xcode 14.2

安装文件：

```text
/path/to/OKVideoMacBuild/Downloads/Xcode_14.2.xip
SHA-256 686b9d53ca49e50d563bc0104b1e8b4f7ccfe80064a6d689965fb819bf8efe72
```

选择与验证结果：

```text
$ xcode-select -p
/path/to/Xcode.app/Contents/Developer

$ xcodebuild -version
Xcode 14.2
Build version 14C18

$ xcrun --show-sdk-path
/path/to/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk

$ clang --version
Apple clang version 14.0.0 (clang-1400.0.29.202)
Target: arm64-apple-darwin21.6.0
InstalledDir: /path/to/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin
```

`xcodebuild -checkFirstLaunchStatus` 返回 0，Xcode GUI 已成功启动。
`codesign --verify --deep --strict` 对 Xcode 验证成功。`spctl --assess` 在本机
长时间无返回后被终止，因此不把 Gatekeeper `spctl` 结果记录为通过。

## MacPorts 来源审计

MacPorts 版本：

```text
Version: 2.12.5
```

当前 `/opt/local/etc/macports/sources.conf`：

```text
# Official MacPorts ports tree. This working tree has the sole origin:
# https://github.com/macports/macports-ports.git
file:///path/to/OKVideoMacBuild/Source/macports-ports [nosync,default]
```

工作树审计：

```text
路径    /path/to/OKVideoMacBuild/Source/macports-ports
origin  https://github.com/macports/macports-ports.git
提交    85ec43c0fa38208bc783906fbddbb1158a867d3b
索引    41464 个 Portfile，0 个失败
```

原始文件保留在：

```text
/opt/local/etc/macports/sources.conf.okvideomac-backup
SHA-256 2643e432d8828994320452459d24697056067b8c65f6d4f447c14ff9bb3ff96b

/opt/local/etc/macports/macports.conf.okvideomac-backup
SHA-256 2e83ac75bf400f96d989d2e1a4c39f531fcf370bde9363a8183d516fa27423b8
```

当前二进制归档主机策略：

```text
host_blacklist  mirror.sjtu.edu.cn
preferred_hosts packages.macports.org *.packages.macports.org
```

`sources.conf` 的 ports 树始终只使用官方 GitHub 仓库。需要保留一项审计
说明：最初安装 Meson/Ninja/pkg-config 时，MacPorts 在主机策略收紧前曾自动
从 `mirror.sjtu.edu.cn` 下载部分由 MacPorts 签名的二进制归档；它不是
`sources.conf` 的 ports 源。发现后已加入黑名单，后续安装只使用
`packages.macports.org`。不得把这段历史描述成“从未访问第三方归档镜像”。

## 实际安装的软件包

MacPorts registry 中共有 **42** 个 active ports，其中 **10** 个是显式请求：

```text
autoconf @2.73_0
automake @1.18.1_0
freetype @2.14.3_0
fribidi @1.0.16_0
libplacebo @7.360.1_0+opengl
libtool @2.5.4_0
m4 @1.4.21_0
meson @1.11.2_0
ninja @1.13.2_1
pkgconfig @0.29.2_0
```

其余 **32** 个是上述 ports 的依赖。没有安装 MacPorts 的完整 ffmpeg7
依赖树，因为干跑检查显示它会引入大量与 MVP 无关的组件。

为维持最小媒体闭包，以下三个固定源码构建安装到了 MacPorts 前缀
`/opt/local`，但它们**不是** MacPorts registry 中的 ports：

| 组件 | 版本 | 源码 SHA-256 |
|---|---:|---|
| HarfBuzz | 14.2.1 | `a54a5d8e9380a41fbb762ce367bcbf7704792dfca0d93f1bbca86c5a57902e0e` |
| libass | 0.17.5 | `fa286fc9ee1ba3b932703a3df7b8474d01dc8abe29ec69b6fa68781dc4bf7acc` |
| FFmpeg | 7.1.4 | `71f4aac3573ed9060489cb62526a6c7dda815ae10993789611acd7be9fa9fbf4` |

FFmpeg 是共享库、无命令行程序的最小构建，保留点播/直播所需网络、HLS、
HTTPS、常用容器/编码及 VideoToolbox。当前 pkg-config 版本：

```text
harfbuzz      14.2.1
libass        0.17.5
libavcodec    61.19.101
libavfilter   10.5.100
libavformat   61.7.102
libavutil     59.39.100
libswresample 5.3.100
libswscale    8.3.100
libplacebo    7.360.1
```

## libmpv 0.41.0

源码归档：

```text
/path/to/OKVideoMacBuild/Downloads/mpv-v0.41.0.tar.gz
SHA-256 ee21092a5ee427353392360929dc64645c54479aefdb5babc5cfbb5fad626209
```

构建脚本：

```text
Scripts/build-libmpv.sh
```

构建脚本固定：

- `DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer`
- arm64、`MACOSX_DEPLOYMENT_TARGET=12.0`
- `cplayer=false`、`libmpv=true`
- Cocoa 外壳关闭，使用 plain OpenGL Render API
- CoreAudio、AVFoundation、FFmpeg、libass、libplacebo 启用
- `PKG_CONFIG_LIBDIR=/opt/local/lib/pkgconfig:/opt/local/share/pkgconfig`
- 每个原生依赖的 `pcfiledir` 必须位于 `/opt/local`
- 编译或链接参数出现 `/opt/homebrew` 时立即失败

mpv 0.41.0 在关闭 Cocoa、保留 CoreAudio/AVFoundation 时漏编译
`osdep/utils-mac.c`。项目补丁：

```text
Patches/mpv-0.41.0-coreaudio-without-cocoa.patch
```

只把该源文件移到 Darwin 公共源列表，未修改播放器行为。

已验证产物：

```text
/path/to/OKVideoMacBuild/libmpv/lib/libmpv.2.dylib
/path/to/OKVideoMacBuild/libmpv/lib/libOKMPVBridge.dylib
```

两者均为 arm64、最低 macOS 12；桥接测试输出：

```text
OKMPVBridge smoke passed (client API 2.5, event size 64)
```

开发态 `libmpv` 的 `otool -L` 引用 `/opt/local` 是预期结果。检查未发现
`/opt/homebrew`。发布打包时必须递归复制所有非系统 dylib 并改写为
`@rpath`，之后再次执行 `otool -L` 门禁。

## 磁盘与安装数量

以下为实际测量值。APFS 的可用空间会受快照、可清除空间和 XIP 删除影响，
所以应保留快照值，不用前后差值反推每个文件的大小。

| 快照 | 系统盘可用 | `/opt/local` 占用 | XcodeDev 可用 | 外置构建目录占用 | MacPorts ports |
|---|---:|---:|---:|---:|---:|
| 初始审计 | 约 24 GiB | 253 MiB | 约 49 GiB | 12 KiB | 0 |
| ports 索引后、安装依赖前 | 约 25.0 GiB | 278.5 MiB | 约 29.6 GiB | 7.45 GiB | 0 |
| 首批 25 个 ports 后 | 约 24.7 GiB | 516.2 MiB | 约 29.6 GiB | 7.45 GiB | 25 |
| 最终环境审计 | 约 25.4 GiB | 575.1 MiB | 约 28.8 GiB | 8.30 GiB | 42 |

最终时：

```text
/path/to/Xcode.app               约 12.38 GiB
/path/to/OKVideoMacBuild         约 8.30 GiB
/opt/local                                约 575 MiB（系统盘）
```

系统盘上的原始 Safari XIP 在与移动盘副本哈希一致后已删除，释放约
7.1 GiB；移动盘中的固定归档仍保留。

## 构建与测试门禁

已执行并通过：

```bash
swift test \
  --package-path Packages/OKVideoKit \
  --scratch-path /path/to/OKVideoMacBuild/SwiftPM
# 41 tests, 0 failures

xcodebuild \
  -project OKVideoMac.xcodeproj \
  -scheme OKVideoMac \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /path/to/OKVideoMacBuild/DerivedData \
  build

xcodebuild \
  -project OKVideoMac.xcodeproj \
  -scheme OKVideoMac \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /path/to/OKVideoMacBuild/DerivedData-Test \
  test
```

Debug App：

```text
/path/to/OKVideoMacBuild/DerivedData/Build/Products/Debug/OKVideoMac.app
```

主程序、libmpv 和桥接库均为 arm64，主程序最低系统版本为 12.0。
`codesign --verify --deep --strict` 通过，当前是本机 Debug ad-hoc 签名。
通过 Finder/LaunchServices 启动后，主进程保持运行，没有在初始化阶段退出。

`NSOpenGLView` 的弃用告警是当前播放器 spike 选择 OpenGL Render API 的已知
结果，不等于构建失败。后续若切换 Metal Render API，应单独做播放器 ADR 和
回归验证。
