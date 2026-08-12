# OKVideoMac 第三方许可证、版权归属与开源发布合规审计

> 审计日期：2026-08-13（Asia/Shanghai）
> 审计类型：只读、开源前技术合规审计
> 总体评级：**Blocked**
> 说明：本报告是基于许可证文本、源码、构建记录和二进制的技术审计，不构成法律意见。标为 **Needs legal review** 的事项应由合格律师最终确认。

## 0. Executive Summary

### 0.1 结论

当前状态**不适合直接宣称 Open Source Ready，也不适合原样继续公开分发签名 `.app`**。项目选择 GPLv3 路线在许可证兼容性上是可行的，但发布材料尚未履行实际二进制对应的 NOTICE、许可证文本、对应源码和来源追溯义务。

关键事实：

- 当前 Release App 实际包含 **28 个 arm64 Mach-O**，而不是仅依赖系统库。
- `libmpv` 是 **GPL-2.0-or-later 路径**，不是 LGPL-compatible 路径。实际 Meson `config.h` 同时显示 `FULLCONFIG` 含 `gpl` 且 `HAVE_GPL 1`。
- mpv v0.41.0 由项目自行构建，并应用了仓库内补丁；分发时必须提供该构建对应的修改后源码、构建信息和 GPL 告知。
- FFmpeg 是 **7.1.4**，实际配置未出现 `--enable-gpl`、`--enable-version3`、`--enable-nonfree`，也未启用 x264、x265、libfdk-aac、OpenSSL 或 GnuTLS；当前证据支持其走 **LGPL-2.1-or-later** 路径。
- FFmpeg、libass、HarfBuzz 等若干 `/opt/local` 输入未能在当前 MacPorts registry 中建立完整包来源链；Node 又来自非标准的 `node@22-direct` 路径。版本可识别，但精确源码、构建配方和输入校验链不完整，属于发布前必须解决的 provenance 问题。
- App 内嵌 `AndroidDexBridge-release.apk`。其中 `catvod` 目录是从 FongMi/TV GPL-3.0 源码直接复制并修改的，不是单纯“观察行为后独立实现”。现有 `NOTICE.md` 声称“不构建、打包或重打包 Android upstream source tree”，与实际发布物冲突。
- APK 合并了 Apache-2.0、MIT、MPL-1.1、Bouncy Castle License 等 Maven 依赖，但实际 APK 只保留了一个 AndroidX Apache 许可证文件，缺少完整第三方告知。
- App Bundle 只携带项目 GPL、mpv、QuickJS 和 Node 的部分法律文件；FFmpeg 及其动态依赖链的许可证/版权告知基本缺失。
- 未发现 AGPL、SSPL、Commons Clause、BSL、PolyForm 或 non-commercial 依赖进入当前发布物。
- App 图标只有二进制资源和提交历史，没有作者、授权或来源记录；在公开仓库及二进制发布前必须补齐权利证明或替换。
- 当前仓库没有 SPDX/CycloneDX SBOM。

### 0.2 当前能否公开 GitHub

**有明确阻断项。** 代码许可证方向可行，但现有 NOTICE 有事实错误，FongMi 复制/修改来源及 Gradle/Maven 第三方材料不完整，资源权利链和部分二进制来源不明。修复这些 P0 后，全仓库采用 GPL-3.0-only 是当前最稳妥路线；若权利人明确授予“或任何以后版本”，才可改称 GPL-3.0-or-later。

### 0.3 当前能否发布 Developer ID `.app`

**不能按现有材料原样发布。** GitHub 源码公开并不会自动替代 `.app` 内或同一下载页面上的第三方告知、对应源码链接、修改说明和 LGPL/GPL 源码提供义务。

本次实际审计样本是 ad-hoc Hardened Runtime Release：`Signature=adhoc`、`TeamIdentifier=not set`。它通过本地严格签名验证，但并不是 Developer ID 样本。Developer ID、notarization 和 Library Validation 对 LGPL 可替换性的实际影响还需要在最终发行样本上复核。

### 0.4 最大 P0

1. 为 GPL mpv 修改构建和 GPL FongMi/catvod APK提供精确 corresponding source、修改说明和获取路径。
2. 修正与实际发布物相矛盾的 `NOTICE.md` 和过期的 `THIRD_PARTY_LICENSES.md`。
3. 为 FFmpeg/native dylib 链、Node 和 APK Maven 依赖建立可复验来源、版本、许可证、NOTICE 与源码链。
4. 补齐 App/APK 中缺失的许可证与版权告知，包括 FFmpeg/IJG、FreeType、libjpeg-turbo、Apache NOTICE/MIT/MPL 等。
5. 解决 App 图标来源与授权未知问题。

## 1. Audit Scope

### 1.1 审计对象

- Git 基线：`c0c145896a78749bc811d2af98621518fb58902c`
- 基线提交时间：`2026-08-13T00:21:57+08:00`
- Release App：`/Volumes/XcodeDev/OKVideoMacBuild/Artifacts/OKVideoMac.app`
- App 版本：`0.3.41 (62)`
- App 时间：`2026-08-13 00:18:38 +0800`
- ZIP：`OKVideoMac-0.3.41-macOS-arm64.zip`
- ZIP SHA-256：`1766571be4edf27ec8c4930b1724a642f99131a0bed74c852496f132f7759147`
- ZIP 内校验文件与实际 SHA-256 一致。
- 主程序 SHA-256：`82e99c4d10843ceca459a154e64bf21392f9182fdc68406f0d1008707723deeb`

审计期间工作区持续出现多项本报告未产生的未提交 Swift/测试改动。它们不涉及本报告发现的依赖声明或打包脚本；本报告不修改、不归因、不覆盖这些用户改动。Release App 生成时间略早于当前 HEAD，因此结论同时以实际 App、其构建缓存和当前构建脚本交叉验证，不能把 HEAD 本身当作该 ZIP 的可重复构建证明。

### 1.2 检查范围

- SwiftPM 清单、XcodeGen 配置、Xcode 工程、Gradle 配置、构建/打包/签名脚本；
- 仓库内 vendored/copied source、补丁、Gradle wrapper、资源和许可证文件；
- Release App 的全部 Mach-O、`otool -L`、architecture、签名、entitlements、strings 和资源；
- mpv Meson 构建缓存、FFmpeg 嵌入配置串、Node `process.versions`；
- APK 内容、Gradle runtime dependency tree、Maven POM/JAR 内法律文件；
- 许可证兼容性、二进制分发、修改源码、NOTICE、资源版权和 SBOM 状态。

### 1.3 限制

- 没有可供审计的 Developer ID + notarized 最终样本；只验证了本地 ad-hoc Hardened Runtime Release。
- 没有为 `/opt/local` 中所有库找到同一构建批次的源码归档、完整 build log 和校验和。
- 未对每个 Mach-O 做反汇编级来源鉴定；版本以二进制字符串、ABI、headers、pkg-config 和本地 registry 交叉判断。
- 版权法上的“衍生作品/组合作品”判断属于法律问题；动态链接不是自动免责或自动传播的简单开关。

## 2. Release Binary Inventory

实际 App 共 28 个 Mach-O，全部为 arm64。系统 framework/Swift runtime 是操作系统提供的 System Libraries，不在下面作为随 App 分发的第三方二进制列出。

| Binary | Architecture | Role | Depends On（随包主要依赖） | Origin | License |
| --- | --- | --- | --- | --- | --- |
| `Contents/MacOS/OKVideoMac` | arm64 | 主程序 | `libsqlite3.dylib`；系统 zlib/Apple frameworks | 项目源码 | GPL-3.0-only（按当前根 LICENSE） |
| `Contents/Resources/NodeRuntime/node` | arm64 | 独立 Node runtime，通过 `Process` 启动 | 无随包 dylib；依赖静态内置，另用系统 framework | `/opt/homebrew/opt/node@22-direct/bin/node` | Node MIT + bundled third-party licenses |
| `Frameworks/libOKMPVBridge.dylib` | arm64 | 项目 C bridge | mpv、FFmpeg avformat/avcodec/avutil | 项目源码 | GPL-3.0-only；组合受 mpv GPL 影响 |
| `Frameworks/libOKQuickJS.dylib` | arm64 | QuickJS C bridge + `force_load` QuickJS static archive | 无随包 dylib | 项目脚本 + QuickJS source | 项目 GPL-3.0-only + QuickJS MIT |
| `Frameworks/libmpv.dylib` | arm64 | 播放器 | libass、FFmpeg、libplacebo、lcms2、zlib、jpeg | mpv v0.41.0 自编译并补丁 | GPL-2.0-or-later |
| `Frameworks/libavcodec.61.dylib` | arm64 | 编解码 | swresample、avutil、lzma、zlib、iconv | `/opt/local` | LGPL-2.1-or-later build |
| `Frameworks/libavfilter.10.dylib` | arm64 | 滤镜 | FFmpeg 全链、bz2、zlib、lzma、iconv | `/opt/local` | LGPL-2.1-or-later build |
| `Frameworks/libavformat.61.dylib` | arm64 | 封装/网络 | avcodec、swresample、avutil、bz2、zlib、lzma、iconv | `/opt/local` | LGPL-2.1-or-later build |
| `Frameworks/libavutil.59.dylib` | arm64 | FFmpeg utility | iconv | `/opt/local` | LGPL-2.1-or-later build |
| `Frameworks/libswresample.5.dylib` | arm64 | 音频重采样 | avutil、iconv | `/opt/local` | LGPL-2.1-or-later build |
| `Frameworks/libswscale.8.dylib` | arm64 | 图像缩放 | avutil、iconv | `/opt/local` | LGPL-2.1-or-later build |
| `Frameworks/libass.9.dylib` | arm64 | ASS 字幕 | iconv、FreeType、FriBidi、HarfBuzz | `/opt/local`, 0.17.5 | ISC |
| `Frameworks/libplacebo.360.dylib` | arm64 | GPU rendering | lcms2、libc++ | MacPorts 7.360.1 | LGPL-2.1-or-later |
| `Frameworks/libfreetype.6.dylib` | arm64 | 字体渲染 | zlib、bz2、libpng、Brotli | MacPorts 2.14.3 | FTL 或 GPL-2.0-only；本发布选择 FTL |
| `Frameworks/libharfbuzz.0.dylib` | arm64 | 字形塑形 | FreeType | `/opt/local`, 14.2.1 | Old MIT |
| `Frameworks/libfribidi.0.dylib` | arm64 | 双向文字 | 无随包依赖 | MacPorts 1.0.16 | LGPL-2.1-or-later |
| `Frameworks/libbrotlidec.1.dylib` | arm64 | Brotli decode | brotlicommon | MacPorts 1.2.0 | MIT |
| `Frameworks/libbrotlicommon.1.dylib` | arm64 | Brotli common | 无 | MacPorts 1.2.0 | MIT |
| `Frameworks/liblcms2.2.dylib` | arm64 | 色彩管理 | 无 | MacPorts 2.19.x | MIT |
| `Frameworks/libpng16.16.dylib` | arm64 | PNG | zlib | MacPorts 1.6.58 | libpng-2.0 |
| `Frameworks/libjpeg.8.dylib` | arm64 | JPEG | 无 | MacPorts libjpeg-turbo 3.2.0 | IJG + BSD-3-Clause + zlib notices |
| `Frameworks/liblzma.5.dylib` | arm64 | XZ/LZMA | 无 | MacPorts 5.8.3 | 0BSD（liblzma） |
| `Frameworks/libsqlite3.dylib` | arm64 | 数据库 | system zlib | MacPorts 3.53.4 | Public Domain |
| `Frameworks/libiconv.2.dylib` | arm64 | 字符集转换 | 无 | MacPorts GNU libiconv 1.18 | LGPL-2.1-or-later |
| `Frameworks/libbz2.1.0.dylib` | arm64 | bzip2 | 无 | MacPorts 1.0.8 | bzip2-1.0.6 license |
| `Frameworks/libz.1.dylib` | arm64 | zlib | 无 | MacPorts 1.3.2 | Zlib |
| `Frameworks/libc++.1.0.dylib` | arm64 | C++ runtime | libc++abi | MacPorts 11.1.0 | NCSA/UIUC（该 MacPorts 版本记录） |
| `Frameworks/libc++abi.1.dylib` | arm64 | C++ ABI runtime | 无 | MacPorts 11.1.0 | NCSA/UIUC（该 MacPorts 版本记录） |

没有发现 `.framework`、`.xcframework` 或额外 helper Mach-O。`AndroidDexBridge-release.apk` 不是 Mach-O，但属于最终 App 的重大第三方聚合发布物，见第 10 节。

## 3. Dependency Graph

```text
OKVideoMac executable
├── libsqlite3.dylib
├── dlopen(libOKMPVBridge.dylib)
│   └── libmpv.dylib [GPL]
│       ├── FFmpeg 7.1.4 dylibs [LGPL build]
│       ├── libass → FreeType / FriBidi / HarfBuzz / iconv
│       ├── libplacebo → lcms2 / libc++
│       └── zlib / libjpeg-turbo
├── dlopen(libOKQuickJS.dylib)
│   └── QuickJS source statically force-loaded [MIT]
├── Process(NodeRuntime/node)
│   └── Node 22.23.0 built-in dependencies [mostly permissive]
└── installs/runs AndroidDexBridge-release.apk in private emulator
    ├── copied+modified FongMi/TV catvod source [GPL-3.0]
    └── Maven runtime graph [Apache-2.0/MIT/MPL-1.1/Bouncy Castle/etc.]
```

打包脚本从 `/opt/local`、`/opt/homebrew` 或 `/usr/local` 递归复制每个非系统动态依赖，并把 install name 改为 `@rpath`（`package-app.sh:225-254`）。因此源码清单之外的递归 dylib 也是项目实际主动分发的组件。

### 3.1 Consolidated dependency matrix

这是最终发布物的主矩阵；第 2 节逐 Mach-O 展开 native binary，第 10 节逐 APK dependency family 展开 Android 组件。

| Component | Version/Commit | Upstream | In Repo | In App Bundle | Link/Usage | License | Modified | Required Notice | Source Obligation | Risk |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| OKVideoMac / OKVideoKit | HEAD `c0c1458…` | project | source | executable | compiled source | GPL-3.0-only | project code | GPL/copyright | complete corresponding source for binary | SOURCE REQUIRED |
| mpv/libmpv | v0.41.0; archive SHA fixed | mpv-player/mpv | build script + patch | dylib | dynamic through custom bridge | GPL-2.0-or-later build | Yes | GPL, copyright, changes | exact modified corresponding source | GPL IMPACT / SOURCE REQUIRED |
| FFmpeg family | 7.1.4; ABI versions in §5 | ffmpeg.org | No source; build input external | 6 dylibs | dynamic | LGPL-2.1-or-later build | Unable to verify | LGPL/copyright/IJG/build config | exact source and modifications | SOURCE REQUIRED / UNKNOWN |
| Node.js | 22.23.0 | nodejs.org | no source; copy rule | executable | separate process/localhost | MIT + bundled licenses | Unable to verify; re-signed | Node distribution LICENSE | exact source/build provenance strongly required | UNKNOWN |
| QuickJS | 2025-09-13-2 | bellard.org | build script + bridge | static code in bridge dylib | `force_load` archive | MIT | No upstream patch found | MIT copyright/license | no copyleft source duty | OK |
| libass | 0.17.5 | libass/libass | No source | dylib | dynamic via mpv | ISC | Unable to verify | ISC copyright/license | source provenance | NOTICE REQUIRED / UNKNOWN |
| libplacebo | 7.360.1 | VideoLAN/libplacebo | No source | dylib | dynamic via mpv | LGPL-2.1-or-later | Unable to verify | LGPL/copyright | exact source/modifications | SOURCE REQUIRED |
| FreeType | 2.14.3 | freetype.org | No source | dylib | dynamic via libass | FTL selected | Unable to verify | FTL + FreeType credit | source record | NOTICE REQUIRED |
| HarfBuzz | 14.2.1 | harfbuzz/harfbuzz | No source | dylib | dynamic | Old MIT | Unable to verify | COPYING/copyright | source provenance | NOTICE REQUIRED / UNKNOWN |
| FriBidi | 1.0.16 | fribidi/fribidi | No source | dylib | dynamic | LGPL-2.1-or-later | Unable to verify | LGPL/copyright | exact source/modifications | SOURCE REQUIRED |
| Brotli | 1.2.0 | google/brotli | No source | 2 dylibs | dynamic | MIT | Unable to verify | MIT copyright/license | source record | NOTICE REQUIRED |
| Little CMS 2 | 2.19.1 (pkg-config `2.19`) | mm2/Little-CMS | No source | dylib | dynamic | MIT | Unable to verify | MIT copyright/license | source record | NOTICE REQUIRED |
| libpng | 1.6.58 | libpng.org | No source | dylib | dynamic | libpng-2.0 | Unable to verify | complete libpng notice | source record | NOTICE REQUIRED |
| libjpeg-turbo | 3.2.0 | libjpeg-turbo | No source | dylib | dynamic | IJG + BSD-3-Clause + zlib | Unable to verify | complete LICENSE + IJG credit | source record | NOTICE REQUIRED |
| XZ/liblzma | 5.8.3 | tukaani.org/xz | No source | dylib | dynamic | 0BSD for liblzma | Unable to verify | 0BSD notice | source record | NOTICE REQUIRED |
| SQLite | 3.53.4 | sqlite.org | system target only | dylib | dynamic | Public Domain | Unable to verify | attribution recommended | source provenance | OK / PROVENANCE |
| GNU libiconv | 1.18 | GNU | No source | dylib | dynamic | LGPL-2.1-or-later | Unable to verify | LGPL/copyright | exact source/modifications | SOURCE REQUIRED |
| bzip2 / zlib | 1.0.8 / 1.3.2 | sourceware / zlib.net | No source | dylibs | dynamic | bzip2 / Zlib | Unable to verify | copyright/licenses | source record | NOTICE REQUIRED |
| libc++ / libc++abi | 11.1.0 | LLVM/MacPorts | No source | dylibs | dynamic | NCSA/UIUC for package version | Unable to verify | copyright/license | exact source record | NOTICE REQUIRED |
| FongMi/TV catvod | `5fdff00a…` + local patch | FongMi/TV | copied source | APK | compiled DEX, separate emulator process | GPL-3.0 | Yes | GPL/copyright/change notice | exact complete source/build | GPL IMPACT / SOURCE REQUIRED |
| Android Maven runtime graph | versions in §10.2 | AndroidX/Google/Square/etc. | Gradle declarations only | APK | merged DEX/resources | Apache-2.0/MIT/MPL-1.1/BC/custom | No evidence | complete per-artifact notices | MPL covered source; source links | NOTICE/SOURCE REQUIRED |
| stax / xpp3 | 1.2.0 / 1.1.3.3 | legacy Codehaus/xpp3 | No | APK | transitive XML code | **UNKNOWN** | No evidence | verify exact licenses | verify source rights | HIGH RISK |
| App icon | current asset catalog | **UNKNOWN** | binary assets | icns/Assets.car | visual resource | **UNKNOWN** | Unknown | author/license/permission | rights proof or replacement | HIGH RISK |

## 4. mpv/libmpv Audit

### 4.1 来源、版本和修改

- 版本/tag：mpv `v0.41.0`
- 上游：<https://github.com/mpv-player/mpv/releases/tag/v0.41.0>
- 源码 URL：`https://github.com/mpv-player/mpv/archive/refs/tags/v0.41.0.tar.gz`
- 固定 SHA-256：`ee21092a5ee427353392360929dc64645c54479aefdb5babc5cfbb5fad626209`
- 脚本证据：`OKVideoMac/macOS/OKVideoMac/Scripts/build-libmpv.sh:11-16,56-69`
- 项目补丁：`Patches/mpv-0.41.0-coreaudio-without-cocoa.patch`
- 补丁内容：把 `osdep/utils-mac.c` 从 Cocoa feature 条件中移到所有 Darwin build，属于对 GPL 上游构建源码的修改。
- 最终 `libmpv.dylib` SHA-256：`6f2f7f53ed3ec1309ae6cef869dd8a83bb4bfff09ad9d61a87f6e2f5778b0cd4`

### 4.2 实际许可证模式

**结论：GPL-2.0-or-later build，不是 LGPL-compatible build。**

证据：

1. 脚本未传 `-Dgpl=false`（`build-libmpv.sh:72-94`）。
2. 实际构建缓存 `/Volumes/XcodeDev/OKVideoMacBuild/Source/mpv-0.41.0-build/config.h` 显示：
   - `FULLCONFIG` 包含 `gpl`；
   - `#define HAVE_GPL 1`。
3. mpv 官方说明默认 GPLv2-or-later，只有 `-Dgpl=false` 才走 LGPLv2.1-or-later：<https://github.com/mpv-player/mpv#license--copyright>。

App 同时打包 `mpv-GPL-2.0-or-later.txt` 与 `mpv-LGPL-2.1-or-later.txt`，但没有说明哪个模式实际生效，容易产生误导；实际模式应只按 `HAVE_GPL 1` 判断。

### 4.3 链接与 GPL 影响

主程序用 `dlopen` 加载 `libOKMPVBridge.dylib`，bridge 再动态链接 `libmpv.dylib`。动态链接本身不会自动消除 GPL 风险。该 bridge 专为 libmpv C API 编写并随单一 App 一起发布；按 mpv 的 GPL 路径，对“主 App 可闭源”的主张风险很高。当前项目整体 GPL-3.0-only 可与 mpv 的 GPL-2.0-or-later 选择 GPLv3 后兼容。

**Needs legal review：**最终“单一组合程序”的法律认定。技术上不应在没有律师意见和上游许可例外的情况下把当前 App 宣称为 MIT/Apache/闭源可自由分发。

### 4.4 对应源码义务

当前仓库有下载脚本和补丁，但没有把本次发布对应的完整修改后源码归档与二进制放在同一可持续下载位置。发布前应：

- 保存精确上游源码归档及其 SHA-256；
- 保存/发布补丁、实际 Meson 参数和构建脚本；
- 提供构建该二进制所需的完整 corresponding source；
- 在 App 和下载页醒目说明 GPL、版权和源码获取方式；
- 对每个二进制版本长期保留对应源码。仅指向“上游最新版”不够。

## 5. FFmpeg Audit

### 5.1 实际版本

- FFmpeg：`7.1.4`
- libavcodec：`61.19.101`
- libavformat：`61.7.102`
- libavutil：`59.39.100`
- libavfilter：`10.5.100`
- libswscale：`8.3.100`
- libswresample：`5.3.100`

### 5.2 实际配置证据

以下配置串直接从最终 `libavutil.59.dylib` 提取，而不是根据 formula 推测：

```text
--prefix=/opt/local --libdir=/opt/local/lib --incdir=/opt/local/include
--pkgconfigdir=/opt/local/lib/pkgconfig --arch=arm64 --target-os=darwin
--cc=/usr/bin/clang --cxx=/usr/bin/clang++
--pkg-config=/opt/local/bin/pkg-config --enable-shared --disable-static
--enable-pic --disable-programs --disable-doc --disable-debug
--disable-avdevice --disable-autodetect --enable-network
--enable-securetransport --enable-videotoolbox --enable-audiotoolbox
--enable-zlib --enable-bzlib --enable-iconv --enable-lzma
--enable-pthreads --disable-sdl2
--extra-cflags='-O2 -arch arm64 -mmacosx-version-min=12.0 -I/opt/local/include'
--extra-cxxflags='-O2 -arch arm64 -mmacosx-version-min=12.0 -I/opt/local/include'
--extra-ldflags='-arch arm64 -mmacosx-version-min=12.0 -L/opt/local/lib'
--extra-libs=-liconv
```

### 5.3 GPL/nonfree 结论

- 未出现 `--enable-gpl`。
- 未出现 `--enable-version3`。
- 未出现 `--enable-nonfree`。
- 未出现 `--enable-libx264`、`--enable-libx265`、`--enable-libfdk-aac`、`--enable-openssl`、`--enable-gnutls`。
- `otool -L` 也未发现 x264、x265、fdk-aac、OpenSSL、GnuTLS、dav1d、libsmbclient、libarchive、rubberband、shaderc 或 Vulkan loader dylib。

因此，**当前 FFmpeg 本身是 LGPL-2.1-or-later build；没有证据表明启用了 GPL 或 nonfree 组件。** 官方判定规则：<https://ffmpeg.org/doxygen/trunk/md_LICENSE.html>；官方二进制合规清单：<https://ffmpeg.org/legal.html>。

### 5.4 缺口

- App 未携带 FFmpeg LGPL 文本、版权告知、源码链接或构建配置说明。
- FFmpeg 官方合规清单要求二进制发布说明 FFmpeg 使用、提供精确源码/修改和配置；还要求保留来自 IJG 的 credit。
- 未找到本次 `/opt/local` FFmpeg 构建的源码归档、源码 SHA、build log 或本项目内可重复脚本。当前二进制能证明 license mode，但不能证明 source provenance/未修改状态。
- 所有 FFmpeg 库都是动态库，没有 LGPL 静态 relinking/object-files 义务；仍要允许替换、保留告知并提供相应源码。Developer ID/Library Validation 下的可替换流程需要实际验证和文档化。

风险：**SOURCE REQUIRED / UNKNOWN PROVENANCE / NEEDS LEGAL REVIEW**。

## 6. Node.js Audit

- 精确版本：Node.js `22.23.0`，官方发布：<https://nodejs.org/en/blog/release/v22.23.0>。
- 最终 binary SHA-256：`60df37880c72f74c789d0857c2729f42256e7ae944c9a5055162da97e54adc3e`。
- 来源路径：`/opt/homebrew/opt/node@22-direct/bin/node`（`project.yml:114-127`）。
- 使用方式：作为独立 executable 由 Foundation `Process` 启动，经 localhost/IPC 与 App 通信；不是链接进主 Mach-O。
- `node_shared=false`，Node 内部依赖静态内置。
- App 携带的 `Node.js-LICENSE.txt` 与该安装根目录的 LICENSE 完全一致，包含 Node MIT 及 Node distribution 的第三方告知。
- App 仅复制 `node` executable 和 LICENSE；没有 npm CLI、没有仓库或 App 内 `node_modules`、没有 `package.json`/lockfile runtime dependency。

二进制报告的内置版本包括：V8 `12.4.254.21-node.56`、OpenSSL `3.5.7`、libuv `1.51.0`、ICU `78.2`、nghttp2 `1.69.0`、SQLite `3.51.3`、undici `6.27.0`、zlib `1.3.1-e00f703`、zstd `1.5.7`、simdjson `4.5.0`、simdutf `6.4.2`、c-ares `1.34.6` 等；法律文本由 Node LICENSE 统一覆盖。

未发现 AGPL/SSPL。Node LICENSE 中出现的 GPL-with-exception 内容主要是上游 distribution 内部分源文件/构建文件告知，不等于当前 Node executable 变成 GPL。

缺口：`node@22-direct` 是非标准安装名称，仓库未固定官方 tarball SHA、该 binary 的来源配方或是否本地 patch。版本和 LICENSE 已知，但 provenance **UNRESOLVED**。发布前应固定官方/自建来源、校验和、构建配方和源码归档。

## 7. QuickJS Audit

- 版本：`2025-09-13-2`，源码内 `VERSION` 为 `2025-09-13`。
- 上游：<https://bellard.org/quickjs/>。
- 源码归档：`quickjs-2025-09-13-2.tar.xz`。
- SHA-256：`996c6b5018fc955ad4d06426d0e9cb713685a00c825aa5c0418bd53f7df8b0b4`，与脚本固定值一致。
- 许可证：MIT，Copyright Fabrice Bellard and Charlie Gordon。
- 链接：先生成 `libquickjs.a`，再由 linker `-force_load` 静态并入 `libOKQuickJS.dylib`。
- 最终 bridge SHA-256：`e1dc2d48b5972e8e6d346e5f6e20da9d5e3d701163450c73f06a2d58a2141414`。
- 未发现上游 QuickJS patch；自有 bridge 源码与上游区分清楚。
- App 已携带完整 MIT LICENSE，静态并入不产生 GPL/LGPL relinking 义务。

风险：**OK**，但仍应在统一 third-party notices 中列出版本、版权和静态使用方式。

## 8. Other Native Libraries

| Component | Version | License | Entry form | Required action | Risk |
| --- | --- | --- | --- | --- | --- |
| libass | 0.17.5 | ISC | dynamic | 保留版权/ISC 文本；固定来源 | NOTICE REQUIRED / UNKNOWN |
| libplacebo | 7.360.1 | LGPL-2.1-or-later | dynamic | LGPL 文本、源码、修改/替换说明 | SOURCE REQUIRED |
| FreeType | 2.14.3 | FTL 或 GPL-2.0-only | dynamic | 明确选择 FTL；在文档中显示 FreeType credit 与 FTL | NOTICE REQUIRED |
| HarfBuzz | 14.2.1 | Old MIT | dynamic | 保留 COPYING/copyright；固定来源 | NOTICE REQUIRED / UNKNOWN |
| FriBidi | 1.0.16 | LGPL-2.1-or-later | dynamic | LGPL 文本、源码/替换说明 | SOURCE REQUIRED |
| Brotli | 1.2.0 | MIT | dynamic | MIT notice | NOTICE REQUIRED |
| Little CMS 2 | 2.19.x | MIT | dynamic | MIT notice，固定精确 patch version | NOTICE REQUIRED |
| libpng | 1.6.58 | libpng-2.0 | dynamic | 完整 libpng notice | NOTICE REQUIRED |
| libjpeg-turbo | 3.2.0 | IJG + BSD-3-Clause + zlib notices | dynamic | 全部 LICENSE，且显示 IJG credit | NOTICE REQUIRED |
| liblzma/XZ | 5.8.3 | 0BSD（liblzma） | dynamic | 0BSD notice/source record | NOTICE REQUIRED |
| SQLite | 3.53.4 | Public Domain | dynamic | 来源/版本记录；建议保留 blessing | OK |
| GNU libiconv | 1.18 | LGPL-2.1-or-later | dynamic | LGPL 文本、源码/替换说明 | SOURCE REQUIRED |
| bzip2 | 1.0.8 | bzip2 license | dynamic | 版权与免责声明 | NOTICE REQUIRED |
| zlib | 1.3.2 | Zlib | dynamic | zlib notice | NOTICE REQUIRED |
| libc++ / libc++abi | 11.1.0 | NCSA/UIUC | dynamic | 完整版权/许可证；保存 exact source | NOTICE REQUIRED |

许可证确认优先依据相应版本源码中的 LICENSE/COPYING。官方参考入口包括 FreeType <https://freetype.org/license.html>、SQLite <https://www.sqlite.org/copyright.html>、zlib <https://www.zlib.net/zlib_license.html>、GNU libiconv <https://www.gnu.org/software/libiconv/>、libjpeg-turbo 3.2.0 <https://github.com/libjpeg-turbo/libjpeg-turbo/blob/3.2.0/LICENSE.md>。

没有发现 OpenSSL/GnuTLS dylib；Node 内部的 OpenSSL 由 Node LICENSE 和 Node source distribution 处理。

## 9. Swift Packages

唯一 Swift package 是本地 `OKVideoKit`：

| Component | Version/Commit | Upstream | In Repo | In App | Usage | License | Modified | Risk |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| OKVideoKit | 当前仓库 | 本项目 | Yes | Yes | local Swift package | 项目 GPL-3.0-only | 项目代码 | OK |
| CSQLite system target | build-resolved | sqlite.org/MacPorts | module map | bundled dynamic SQLite | database | Public Domain | No evidence | version/provenance record |
| CZlib system target | build-resolved | zlib | module map | 主程序用系统 zlib；FFmpeg 链另带 MacPorts zlib | compression | Zlib | No evidence | notice for bundled copy |

- `Package.swift` 无 remote package URL。
- 无 `Package.resolved`。
- XcodeGen/Xcode 工程没有 remote package reference。
- 测试 target 仅依赖本地 package，无额外 test-only 第三方包。

## 10. Vendored Source

### 10.1 FongMi/TV `catvod`

- 上游：<https://github.com/FongMi/TV/tree/5fdff00a602dc56e8ba756174daef20edab024f2>
- 固定提交：`5fdff00a602dc56e8ba756174daef20edab024f2`
- 上游许可证：GPL-3.0。
- 仓库路径：`OKVideoMac/Helpers/AndroidDexBridge/catvod/src/main`。
- `Helpers/AndroidDexBridge/README.md:11-12` 明确承认该目录从固定 FongMi revision 复制。
- 与本地忽略的固定上游 checkout 比较：除 manifest 换行外，实质修改是 `com/github/catvod/Proxy.java` 把默认端口 `-1` 改成 `9978` 并加注释。
- 这不是仅研究协议后的 clean-room Swift implementation；它是直接复制并修改的 GPL 源码，并进入 APK。

义务：GPLv3 许可证、上游版权、修改说明/日期、完整对应源码和构建安装信息。当前源码位于仓库有利于履约，但发布页面/App 必须把 APK 与该源码版本明确关联。

严重矛盾：`OKVideoMac/NOTICE.md:13-18` 声称 distribution 不构建或打包 Android upstream source tree，也声称省略 Java/Dex plugins；实际 `project.yml:69-77` 把 APK 复制入 App，APK 又包含上述 catvod。必须在任何发布前修正。

### 10.2 APK Maven runtime 依赖

实际 Gradle runtime graph 的主要精确组件如下。AndroidX/Kotlin 的大量传递模块按同一许可证族合并列出，但 SBOM 应逐 artifact 展开。

| Component | Version/Commit | Upstream | In Repo | In App Bundle | Link/Usage | License | Modified | Required Notice | Source Obligation | Risk |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| FongMi/TV catvod | `5fdff00a…` + local port patch | FongMi/TV | copied source | APK | source compiled to DEX | GPL-3.0 | Yes | GPL/copyright/change notice | exact complete source | GPL IMPACT / SOURCE REQUIRED |
| AndroidX family | annotation 1.9.1; preference 1.2.1; startup 1.2.0; transitive modules | AndroidX | No | APK | merged DEX/resources | Apache-2.0 | No evidence | LICENSE + applicable NOTICE | source link recommended | NOTICE REQUIRED |
| Kotlin/Kotlinx | stdlib 2.2.0; coroutines 1.6.1 | JetBrains | No | APK | transitive | Apache-2.0 | No evidence | license/notice | source link | NOTICE REQUIRED |
| Brotli dec | 0.1.2 | google/brotli | No | APK | merged | MIT | No evidence | MIT notice | None beyond source retention | NOTICE REQUIRED |
| OkHttp family | 5.1.0 | square/okhttp | No | APK | HTTP/DoH/logging | Apache-2.0 | No evidence | license/notice | source link | NOTICE REQUIRED |
| Okio | 3.15.0 | square/okio | No | APK | transitive | Apache-2.0 | No evidence | license/notice | source link | NOTICE REQUIRED |
| Gson | 2.13.1 | google/gson | No | APK | JSON | Apache-2.0 | No evidence | license/notice | source link | NOTICE REQUIRED |
| Guava Android | 33.4.8-android | google/guava | No | APK | utilities | Apache-2.0 | No evidence | license/notice | source link | NOTICE REQUIRED |
| failureaccess/listenablefuture/jspecify/error-prone/j2objc annotations | 1.0.3 / 9999… / 1.0.0 / 2.38.0 / 3.0.0 | Google/jspecify | No | APK | transitive | Apache-2.0-family | No evidence | notices | source links | NOTICE REQUIRED |
| juniversalchardet | 1.0.3 | Google Code archive | No | APK | charset detection | MPL-1.1 | No evidence | MPL 1.1 + covered-file notice | covered source availability | SOURCE REQUIRED / NEEDS LEGAL REVIEW |
| logger | 2.2.0 | orhanobut/logger | No | APK | logging | Apache-2.0 | No evidence | license/notice | source link | NOTICE REQUIRED |
| sardine-android | 0.9 | thegrizzlylabs | No | APK | WebDAV | Apache-2.0 | No evidence | license/notice | source link | NOTICE REQUIRED |
| simple-xml | 2.7.1 | simpleframework | No | APK | XML | Apache-2.0 | No evidence | license/notice | source link | NOTICE REQUIRED |
| stax-api | 1.0.1 | Codehaus | No | APK | XML API | Apache-2.0 | No evidence | license | source link | NOTICE REQUIRED |
| stax | 1.2.0 | Codehaus | No | APK | XML RI | UNKNOWN: POM/JAR lacks license | No evidence | verify upstream license | verify before release | UNKNOWN / HIGH RISK |
| xpp3 | 1.1.3.3 | xpp3 | No | APK | XML parser | UNKNOWN: POM/JAR lacks license | No evidence | verify upstream license | verify before release | UNKNOWN / HIGH RISK |
| smbj | 0.14.0 | hierynomus/smbj | No | APK | SMB | Apache-2.0 | No evidence | license/notice | source link | NOTICE REQUIRED |
| asn-one | 0.6.0 | hierynomus/asn-one | No | APK | ASN.1 | Apache-2.0 | No evidence | license/notice | source link | NOTICE REQUIRED |
| Bouncy Castle provider | 1.79 | bcgit/bc-java | No | APK | crypto, transitive from smbj | Bouncy Castle License (MIT-style) | No evidence | full BC license/copyright | source link | NOTICE REQUIRED |
| mbassador | 1.3.0 | bennidi/mbassador | No | APK | events | MIT | No evidence | MIT notice | None | NOTICE REQUIRED |
| slf4j-api | 2.0.9 | qos-ch/slf4j | No | APK | logging API | MIT | No evidence | MIT notice | None | NOTICE REQUIRED |
| ZXing core | 3.5.3 | zxing/zxing | No | APK | barcode | Apache-2.0 | No evidence | license/notice | source link | NOTICE REQUIRED |

APK SHA-256：`0ef35575005620cccd2a927d31915f3e0b090cf4a877581d5f49007d32a70576`；501 entries，约 18.28 MB。它只保留 `META-INF/androidx/annotation/annotation/LICENSE.txt`，没有 consolidated notices。`stax:1.2.0` 与 `xpp3:1.1.3.3` 的缓存 POM/JAR 没有许可证声明，不能猜测，必须在发布前从对应源码版本确认或替换。

### 10.3 Build-time only

- Android Gradle Plugin `8.7.3`：build-time，Apache-2.0，不进入 APK；仓库仍分发 wrapper/配置时应保留相应版权材料。
- `gradle-wrapper.jar`：tracked build tool binary，未发现同目录 Apache-2.0 LICENSE/NOTICE；应在公开仓库补齐其分发告知并固定 wrapper distribution checksum。
- Xcode/XcodeGen/Meson/Ninja/pkg-config/clang：build-time tools，不随 App 分发。

## 11. JavaScript / npm Dependencies

- 仓库和 App 内均无 `node_modules`。
- 无 npm `package.json`、`package-lock.json`、pnpm/yarn lockfile进入 runtime。
- JS spider/bundle 是运行时用户输入或下载内容，不是仓库固定再分发的 npm dependency。
- QuickJS 是原生 runtime，见第 7 节；Node 内置 JS/第三方告知由 Node LICENSE 覆盖。
- 本次未发现 npm 来源的 GPL、AGPL、LGPL、SSPL 或自定义限制 package。

若未来打包固定 spider/bundle，必须把它作为独立第三方内容重新审计，不能沿用本报告的“无 npm package”结论。

## 12. Assets and Non-Code Copyright

### 12.1 可确认内容

- tracked 非文本资源主要是 App icon PNG/icns/asset catalog 与 `gradle-wrapper.jar`。
- 未发现 bundled 商业字体、音频、视频、海报、截图、真实 M3U/XMLTV 内容或第三方 favicon。
- 测试 fixtures 是合成 JSON，无真实媒体。
- UI 使用系统字体和 SF Symbols；未发现额外字体文件。
- mpv 内置的 OSD symbol font/data 属于 mpv corresponding source 范围。
- 未在 tracked 内容中发现 Cookie、token、账号、DRM key 或固定媒体源。

### 12.2 阻断项

App icon 首次出现于历史基线提交，但仓库没有创作者、委托关系、来源 URL 或授权文件。结论为 **UNKNOWN COPYRIGHT / P0**。公开前需要：

1. 原作者/设计方的书面权利与开源/二进制分发授权；或
2. 可验证的自有创作记录；或
3. 替换为权利链清楚的新图标。

代码中的 `https://upload.112114.xyz/logo/` 是运行时外部 logo 服务，不是已打包资源；它不是本轮许可证阻断，但应审查其服务条款、隐私和第三方 Logo 展示政策。

### 12.3 不应进入公开仓库

- 用户配置、Cookie/token、账号数据、缓存海报、下载的 spider/JAR/JS、第三方接口响应和未获授权媒体内容；
- ignored 的 `SourceAuditCache` 及上游工作树不得在未经清理时直接发布；
- 构建缓存和本机绝对路径清单不应作为 source release 的必要内容。

## 13. Copied / Modified Third-Party Code Review

| Component | Type | Evidence | Modification | Publication consequence |
| --- | --- | --- | --- | --- |
| FongMi catvod | direct copied source | README 声明 + 与固定 upstream diff | `Proxy.java` 默认端口及注释 | GPLv3 source/change notice/copyright required |
| mpv | upstream source build | pinned tarball/checksum | Meson Darwin source-selection patch | modified GPL source required |
| FFmpeg | prebuilt/self-built local dylibs | binary config string | Unable to verify | exact source/build provenance required |
| QuickJS | upstream source static inclusion | pinned tarball/checksum | no upstream patch found | MIT notice sufficient |
| Node | copied executable | `project.yml:116-127` | binary re-signed; source patch unknown | preserve Node LICENSE; establish provenance |

仓库中的 Swift 注释和模型大量引用 FongMi 行为/协议。除上述 catvod 目录外，没有通过本轮文本和结构扫描证明 Swift 大段直接复制上游 Java/Kotlin；现有证据更符合兼容协议/行为的独立 Swift 实现。但这不是逐行法证结论；如果作者知道还有直接 port，应主动标注来源。

## 14. License Compatibility Matrix

| Proposed OKVideoMac license | Current combined App | Compatibility conclusion |
| --- | --- | --- |
| MIT | 不可作为整个组合发布的唯一许可证 | 与 MIT/ISC/BSD 等自身兼容，但不能覆盖 mpv GPL 和 catvod GPL；主 App 闭源/MIT 分发存在 GPL 风险 |
| Apache-2.0 | 不可作为整个组合发布的唯一许可证 | Apache-2.0 可进入 GPLv3 组合，但不能取消 GPL；与 GPLv2-only 不兼容，mpv 可选 GPLv3所以可在 GPLv3 总体下共存 |
| GPL-2.0-only | 不建议/不兼容 | FongMi 为 GPL-3.0，Apache-2.0 依赖也不能简单降为 GPLv2-only |
| GPL-2.0-or-later | 仍不够清晰 | 可以为 mpv 选择 GPLv3，但项目还需明确 GPLv3 适用；直接标 GPL-3.0 更稳定 |
| GPL-3.0-only | 当前最稳妥 | 与 mpv GPL-2.0-or-later（选择 v3）、FongMi GPL-3.0、Apache-2.0、MIT/ISC/BSD/FTL 等兼容；第三方仍保留各自许可证 |
| GPL-3.0-or-later | 可行但需权利授权 | 只有所有项目代码权利人确实授予“or later”时才能采用；不能仅凭放入 GPLv3 文本推定 |
| Closed/proprietary | 当前高风险/不建议 | mpv GPL build 及专用 bridge 是主要阻断；APK 的 GPL source 可独立提供，但不能解决主 App 与 libmpv 的组合问题 |

MPL-1.1 的 juniversalchardet 是 file-level copyleft；与 GPLv3 聚合/组合的精确边界及原始三选一许可可能需要查源码头。缓存 POM 只声明 MPL-1.1，因此当前按 MPL-1.1 履约并标 **Needs legal review**。

未发现 AGPL/SSPL/noncommercial/nonredistributable component。FFmpeg 也未启用 nonfree。

## 15. Source Distribution Obligations

### 15.1 GitHub source release

至少应包含：

- 项目准确的 GPL 授权声明和贡献者版权政策；
- FongMi catvod 原版权/许可证、固定 commit、修改说明和可构建源码；
- mpv patch、脚本、精确源码归档 hash 及可重复构建说明；
- Gradle wrapper 和所有 vendored/build binary 的来源及许可证；
- 不把第三方代码误标成项目自有代码；
- 清理本机绝对路径、缓存、用户数据和未授权资源。

### 15.2 `.app` binary release

即使 GitHub 已公开，仍应在 App 或与每个 binary 同一下载页面明确提供：

- GPL/LGPL/MIT/ISC/BSD/Apache/MPL/Bouncy Castle 等全文和版权告知；
- 该二进制精确版本、SHA、来源和实际 build flags；
- 项目主程序、修改 mpv、catvod/APK 的 exact corresponding source 链接；
- FFmpeg、libplacebo、FriBidi、libiconv 等 LGPL 组件的 exact source/修改获取方式；
- MPL-1.1 covered source 获取方式；
- 修改说明与构建/安装信息；
- App 中可访问的 Third-Party Notices 入口或清晰 bundled file；
- 同一 release 对应的持久源码归档，不能只指向滚动分支或最新版。

### 15.3 LGPL 替换与签名

FFmpeg 等 LGPL 组件是独立 dylib，故没有静态链接时提供 object files/relink 脚本的典型额外义务。但是：

- 本地审计 App 的 executable entitlement 含 `disable-library-validation=true`，用户技术上较易替换 dylib并重签；
- Release entitlement 文件为空，Developer ID distribution 预期启用 Library Validation；用户替换 dylib后原签名必然失效；
- 应验证用户能否以 ad-hoc 方式重签整个 App，并把替换/重签步骤写入文档；
- 该做法是否满足 LGPL 对 reverse engineering/replacement 的要求，**Needs legal review**。

## 16. Required Notices

### 16.1 当前 App 已包含

- 项目 `LICENSE`（GPLv3 文本）；
- 当前 `NOTICE.md`（但有关键事实错误）；
- mpv Copyright、GPL 和 LGPL 文本（未说明实际为 GPL）；
- QuickJS MIT；
- Node.js 完整 distribution LICENSE；
- `THIRD_PARTY_LICENSES.md`（但错误写 mpv/FFmpeg “未构建/未链接”）；
- `LEGAL_AND_SECURITY.md`。

### 16.2 当前 App 缺失/不完整

- FFmpeg LGPL、copyright、source/build flags、IJG credit；
- libass ISC；libplacebo/FriBidi/libiconv LGPL；
- FreeType FTL 和 product credit；
- HarfBuzz、Brotli、lcms2、libpng、libjpeg-turbo、XZ/liblzma、bzip2、zlib、libc++/libc++abi notices；
- libjpeg-turbo/IJG 明示语句；
- APK 的 GPL FongMi/catvod 告知和 source link；
- AndroidX/Kotlin/OkHttp/Okio/Gson/Guava/Android Gradle 等 Apache-2.0 license/NOTICE；
- Brotli/mbassador/slf4j 等 MIT；
- juniversalchardet MPL-1.1；Bouncy Castle License；
- stax 1.2.0 和 xpp3 1.1.3.3 的待确认许可证；
- 对每个修改第三方组件的 change notice；
- App icon 权利说明。

结论：**存在大量必须补齐的 LICENSE/NOTICE；当前 App Bundle 不合格。**

## 17. Open-Source License Options for OKVideoMac

### 17.1 方案 A：全部开源

当前最稳妥方案是：

- 项目原创代码采用 **GPL-3.0-only**；
- 每个第三方目录/组件继续保留原许可证和版权；
- 文档说明 mpv 的 GPL-2.0-or-later 在本组合中按 GPLv3 使用；
- FongMi catvod 保持 GPL-3.0；
- Apache-2.0/MIT/ISC/BSD/FTL/LGPL/MPL 组件分别履约。

如果所有原创代码权利人愿意授予未来版本，可考虑 GPL-3.0-or-later；当前只有 GPLv3 正文不足以证明该额外授权。

### 17.2 MIT/Apache 作为主许可证

可以把真正独立且不与 GPL 组合分发的子库单独 MIT/Apache 授权，但不能用它们覆盖整个现有 App。对全仓库/全 App 仅放 MIT 或 Apache LICENSE 会制造错误授权表象。

## 18. Partial-Open-Source Feasibility

只开源 `OKVideoKit`、App 层闭源，在**当前依赖结构下不稳妥**：

- OKVideoKit 本身没有 remote SPM 依赖，可独立重新授权的前提是所有权利人同意；
- 但最终闭源 App 仍通过专用 bridge 与 GPL build 的 libmpv 组成发布物；开源 OKVideoKit 不会履行或消除主 App 的 GPL 风险；
- 内嵌 GPLv3 APK 可以作为独立程序通过进程/模拟器通信，但仍必须开源 APK 对应源码；它不解决 libmpv 问题。

如果未来要走部分开源/闭源 App 路线，技术前提至少是重新评估 mpv 的 `-Dgpl=false` LGPL-compatible build、全部 FFmpeg/native flags 和 LGPL 替换机制；这属于依赖/构建变更，不在本轮审计执行范围。**Needs legal review**。

## 19. Closed-Source Binary Feasibility

当前完全闭源 + 免费或商业 binary：**不建议，存在明确 GPL 阻断风险。** 收费与否不改变 GPL/LGPL 义务。

要实现闭源路线通常需要：

1. 不再分发当前 GPL build 的 libmpv，或获得额外商业许可；
2. 若使用 mpv LGPL-compatible build，证明所有 feature/dependency 均满足 LGPL-compatible 条件；
3. 继续为 FFmpeg/native LGPL 库履行 notice/source/replacement；
4. 将 GPL APK 作为明确独立程序并公开其完整对应源码，或替换其 GPL 代码；
5. 由律师审查进程边界、bridge、签名和 reverse-engineering 条款。

这不是简单地把仓库设为 private 或只公开一个 package 就能完成。

## 20. P0 / P1 / P2 Findings

### P0 — 开源/二进制发布前必须解决

1. **GPL mpv source chain**：为 v0.41.0 + 本地 patch + 实际 flags 保存并发布 exact corresponding source、许可证、版权、修改说明和构建说明。
2. **FongMi/catvod GPL chain**：明确直接复制/修改事实，保留版权/GPL，发布 APK exact source 和改动记录。
3. **纠正虚假/过期法律文档**：`NOTICE.md` 不得继续声称未打包 Android upstream；`THIRD_PARTY_LICENSES.md` 不得继续称 mpv/FFmpeg 未构建。
4. **补齐 App native notices/source**：FFmpeg 及所有 bundled dylib 的许可证、版权、source/build 信息；含 IJG 和 FreeType 特定 credit。
5. **补齐 APK notices**：Apache/MIT/MPL/Bouncy Castle 等所有 runtime artifacts；当前 APK 仅一个 AndroidX license 不够。
6. **未知 binary provenance**：为 FFmpeg、libass、HarfBuzz、Node `node@22-direct` 等建立 exact source/archive SHA/build recipe/log。无法建立来源的 binary 不得发布。
7. **未知许可证**：确认 `stax:1.2.0` 和 `xpp3:1.1.3.3` 对应源码版本许可证，不能根据相邻项目或文件名猜测。
8. **MPL source**：为 juniversalchardet 1.0.3 保留 MPL 1.1、covered source 获取方式，并做 GPLv3 组合法律复核。
9. **App icon rights**：取得可审计授权/创作证明或替换。
10. **下载页/App source mapping**：每个 binary release 应与固定源码、patch、SBOM、notices 一一对应。

### P1 — 强烈建议开源前解决

1. 生成逐文件/逐 artifact 的 SPDX 或 CycloneDX SBOM，分别覆盖 macOS App 和 APK。
2. 建立 `THIRD_PARTY_NOTICES.md`、`THIRD_PARTY_LICENSES/`、`Docs/BUILDING.md` 和 `Docs/OPEN_SOURCE_COMPLIANCE.md`。
3. 在干净环境重建 final Developer ID sample，保存编译器、MacPorts ports、source SHA、build log、codesign/notarization evidence。
4. 验证 LGPL dylib replacement + ad-hoc re-sign 流程并文档化；请律师复核。
5. 为 Gradle wrapper 增加许可证、distribution SHA 和版本来源记录。
6. 明确项目 copyright ownership、贡献者协议/DCO 策略和项目授权是 `GPL-3.0-only` 还是 `-or-later`。
7. 对所有 release artifact 生成 checksums、notices archive 和 source archive，设定保留期限。
8. 清理 tracked absolute local paths 和发布元数据中的机器特定路径。

### P2 — 可持续完善

1. CI 中自动扫描 SPDX expressions、许可证变更、未知二进制和新增资源。
2. 接入 GitHub Dependency Review、Dependabot 与 license allow/deny policy。
3. 为源码加适当 SPDX headers，避免覆盖第三方原 header。
4. CI 自动比较 App Mach-O inventory、`otool` graph 与 SBOM，防止递归复制带入新库。
5. APK 用 license aggregation task 生成 notices，并测试关键许可证文件确实进入发布物。

## 21. Recommended Remediation Plan

### 阶段 1：冻结并建立材料链

1. 冻结 0.3.41 合规基线；保存 ZIP、App、每个 Mach-O/APK SHA-256。
2. 对所有外部输入建立 lock manifest：source URL、tag/commit、archive SHA、license、build flags、patch、output SHA。
3. 无法证明来源的 FFmpeg/native/Node binary 重新从已固定源码构建，或取得可验证 distribution provenance；不要沿用不可追溯文件。

### 阶段 2：修正事实和 notices

1. 重写 NOTICE，准确区分独立 Swift 实现与直接复制的 GPL catvod。
2. 生成完整 third-party matrix 和许可证目录；App 内提供可访问入口。
3. 为 APK 生成 consolidated notices，并保留 MPL/Apache/Bouncy Castle 等全文。
4. 补齐 mpv/FFmpeg/IJG/FreeType/source links 和修改告知。

### 阶段 3：对应源码与重现

1. 为项目、mpv patch、catvod/APK、LGPL/MPL 组件发布 exact source bundle。
2. 写干净环境构建说明，保存实际配置输出，而不只保存期望参数。
3. 生成双层 SBOM：macOS bundle Mach-O SBOM + APK Maven artifact SBOM。

### 阶段 4：发行验证

1. 用 Developer ID distribution 模式重建；验证签名、notarization、Gatekeeper、所有 notices 和 source URLs。
2. 验证 LGPL 替换/重签技术路径。
3. 律师复核 GPL bridge/组合边界、MPL-1.1 和拟采用的项目 license grant。
4. 只有 P0 全部关闭、source-notice-binary 可一一映射后，标记 `Open Source Ready`。

### 建议建立的文件

- 保留并澄清 `LICENSE`；
- 新建 `THIRD_PARTY_NOTICES.md`；
- 新建 `THIRD_PARTY_LICENSES/`；
- 保留本报告 `Docs/THIRD_PARTY_LICENSE_AUDIT.md`；
- 新建 `Docs/BUILDING.md`；
- 新建 `Docs/OPEN_SOURCE_COMPLIANCE.md`；
- 保留/完善 `SECURITY.md`；
- 发行时生成 `SBOM.spdx.json` 和/或 `bom.cdx.json`。

## 22. Evidence / Commands Used

以下均为只读检查；本轮没有重新编译或改动业务代码/依赖/App Bundle。

```bash
git status --short
git rev-parse HEAD
git show -s --format='%cI %s' HEAD
rg --files
rg -n 'license|copyright|GPL|LGPL|AGPL|SSPL|NOTICE|FongMi|TVBox|ZyFun' ...
find OKVideoMac -type f ...

find OKVideoMac.app/Contents -type f ...
file <each file>
lipo -archs <each Mach-O>
otool -L <each Mach-O>
otool -l <each Mach-O>
strings <FFmpeg/mpv/Node binaries>
codesign -dvvv OKVideoMac.app
codesign -d --entitlements :- <executables>
codesign --verify --deep --strict OKVideoMac.app
shasum -a 256 <artifacts and key binaries>

rg 'HAVE_GPL|FULLCONFIG|CONFIGURATION' \
  /Volumes/XcodeDev/OKVideoMacBuild/Source/mpv-0.41.0-build/config.h
strings OKVideoMac.app/Contents/Frameworks/libavutil.59.dylib
OKVideoMac.app/Contents/Resources/NodeRuntime/node -p \
  'JSON.stringify(process.versions,null,2)'

./gradlew :app:dependencies --configuration releaseRuntimeClasspath
unzip -l AndroidDexBridge-release.apk
unzip -l <Maven JAR>
diff -qr Helpers/AndroidDexBridge/catvod/src/main \
  Reference/FongMiTV/catvod/src/main
```

关键仓库证据：

- `OKVideoMac/macOS/OKVideoMac/Scripts/build-libmpv.sh:11-16,38-52,56-101`
- `OKVideoMac/macOS/OKVideoMac/Patches/mpv-0.41.0-coreaudio-without-cocoa.patch:1-20`
- `OKVideoMac/macOS/OKVideoMac/Scripts/package-app.sh:157-205,225-284`
- `OKVideoMac/macOS/OKVideoMac/project.yml:35-42,69-128,141-146`
- `OKVideoMac/macOS/OKVideoMac/Packages/OKVideoKit/Package.swift:5-45`
- `OKVideoMac/Helpers/AndroidDexBridge/catvod/build.gradle:20-35`
- `OKVideoMac/Helpers/AndroidDexBridge/app/build.gradle:5-53`
- `OKVideoMac/Helpers/AndroidDexBridge/catvod/src/main/java/com/github/catvod/Proxy.java:5-22`
- `OKVideoMac/NOTICE.md:3-18`
- `OKVideoMac/macOS/OKVideoMac/Docs/THIRD_PARTY_LICENSES.md:3-13`

官方上游许可证参考：mpv <https://github.com/mpv-player/mpv#license--copyright>、FFmpeg <https://ffmpeg.org/doxygen/trunk/md_LICENSE.html>、Node 22.23.0 <https://nodejs.org/download/release/v22.23.0/>、QuickJS <https://bellard.org/quickjs/>、FongMi/TV 固定提交 <https://github.com/FongMi/TV/tree/5fdff00a602dc56e8ba756174daef20edab024f2>。

## Appendix A — 12 个最终问题的明确回答

1. **现在公开整个 GitHub 仓库是否有明确阻断项？**
   **有。** NOTICE 与事实冲突、FongMi/catvod GPL 来源和修改告知不完整、Gradle/Maven notices 缺失、两个 Maven artifact 许可证未确认、图标权利未知、若干 binary provenance 不完整。项目采用 GPL-3.0-only 的方向本身可兼容当前已知依赖。

2. **继续发布 Developer ID `.app` 必须履行什么？**
   为项目/GPL mpv/GPL APK提供 exact corresponding source 和修改说明；为 FFmpeg/native LGPL/MPL 提供精确源码、许可证、替换/重签信息；在 App/下载页保留所有第三方版权、LICENSE/NOTICE、build flags、版本和 source mapping；对签名/notarized 最终样本重新验证。

3. **libmpv 是 GPL 还是 LGPL-compatible？证据？**
   **GPL-2.0-or-later build。** 实际 Meson `config.h` 的 `FULLCONFIG` 含 `gpl`，并有 `#define HAVE_GPL 1`；脚本也未传 `-Dgpl=false`。

4. **FFmpeg 是否启用 GPL 或 nonfree？**
   **没有。** 最终 binary 内配置串无 `--enable-gpl`/`--enable-version3`/`--enable-nonfree`，也无 x264/x265/fdk/OpenSSL/GnuTLS flags 或 dylib。当前 FFmpeg 是 LGPL-2.1-or-later build。

5. **最终 App 是否有 GPL、AGPL、SSPL 或未知许可证 binary？**
   有 GPL：`libmpv.dylib`（GPL-2.0-or-later）和内嵌 APK（因 copied/modified catvod，GPL-3.0）。未发现 AGPL/SSPL。未知项包括 APK 中 `stax:1.2.0`、`xpp3:1.1.3.3` 的许可证，以及 FFmpeg/libass/HarfBuzz/Node 等 binary 的不完整来源链。

6. **哪些组件要求 corresponding/modified source？**
   项目 GPL 主程序、修改的 mpv、修改的 FongMi/catvod/Android bridge APK；FFmpeg、libplacebo、FriBidi、libiconv 等 LGPL 对应源码；juniversalchardet MPL-1.1 covered source。精确范围需结合最终 source bundle 和法律复核。

7. **App Bundle 是否缺必须保留的 LICENSE/NOTICE？**
   **是，大量缺失。** FFmpeg/native dylib 链、IJG/FreeType、APK Apache/MIT/MPL/Bouncy Castle 等都未完整保留；现有两份说明还与实际构建不符。

8. **App 主体闭源是否允许？**
   **当前不应认为允许。** GPL build 的 libmpv 与专用 bridge/主 App 形成高风险组合；动态链接不能自动免责。Needs legal review。

9. **只开源 OKVideoKit、App 层闭源是否允许？**
   **不能解决当前问题。** OKVideoKit 可独立讨论授权，但闭源 App 仍分发 GPL libmpv 和 GPL APK，义务不消失。

10. **全部开源最稳妥的主许可证？为什么？**
    **GPL-3.0-only。** 它能与 mpv GPL-2.0-or-later（选 v3）、FongMi GPL-3.0、Apache-2.0 和 permissive dependencies 共存，并与当前根 LICENSE 的最保守解释一致。只有获得全部原创权利人的“or later”授权后才建议 GPL-3.0-or-later。

11. **真正必须修的 P0？**
    GPL source chain、FongMi/catvod 归属和修改说明、修正错误 NOTICE、补齐 App/APK notices、确认 stax/xpp3 许可证、固定所有 binary provenance/build recipe、履行 LGPL/MPL source 义务、解决 App icon 权利、建立每个 binary 与 source 的发行映射。

12. **什么条件下达到 Open Source Ready？**
    所有 P0 关闭；干净源码能重建逐 hash 可追溯的 App/APK；每个第三方组件有精确版本/来源/license/link mode/修改记录；App 与下载页包含完整 notices 和持久 source links；GPL/LGPL/MPL source 与替换要求已履行；资源权利清楚；最终 Developer ID/notarized 样本通过签名、bundle、SBOM 和人工法律复核。
