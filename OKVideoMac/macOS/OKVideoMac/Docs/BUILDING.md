# Building OKVideoMac

## 0.8.0 release candidate verification

The current source candidate is 0.8.0 (Build 130), compared against the published
`v0.7.3` commit. Actual test, static-check and Release package results are in the
[0.8.0 readiness record](../../../../Docs/RELEASE_READINESS_0.8.0.md); module/file
coverage and Git suggestions are in the
[release preparation record](../../../../Docs/RELEASE_PREPARATION_0.8.0.md).

Keep `project.yml` and the committed Xcode project version/build synchronized.
Use XcodeGen 2.38.0 exactly for regeneration comparisons; a newer generator is
not an accepted substitute. `Info.plist` uses the shared version/build settings.
Android Bridge has its own version, currently 0.3.48 (60), and preserves its
pinned Release certificate and locked dependency graph.

Default tests cover the app, OKVideoKit, AndroidRuntimeKit, Node and SourceAudit.
Four real-emulator lifecycle tests are explicit opt-in gates. The real libmpv
long-GOP seek case needs `OKVIDEOMAC_SEEK_FIXTURE` and a visible OpenGL surface;
it is run separately from the default suite. Distinguish prior Android device
instrumentation from tests rerun for this candidate.

AGP 8.7.3 lint prints Kotlin metadata diagnostics for pinned OkHttp 5.1.0/Kotlin
2.2 metadata while its analyzer supports Kotlin 2.0. Record the final lint result
and warnings; do not suppress diagnostics or claim that this verifies every
real-provider/device combination.

For a dirty development branch, `Scripts/package-local-acceptance.sh` freezes
tracked and non-ignored implementation files outside the worktree and calls the
standard `Scripts/package-app.sh`. It verifies a local ad-hoc **Release** package,
never a Debug deliverable; only a verified package may replace the Desktop app.
The snapshot records local acceptance identity, not a public release commit.

Formal publication still requires the final clean release commit, Developer ID
signing, notarization, stapling, Gatekeeper, installation smoke and a complete
source/SBOM/hash asset set. The notarized public download remains 0.7.3.

## 0.6.1 historical release verification

The complete default suite executes 721 App tests (713 passed, 8 conditional
external/Android/renderer gates skipped), 261 OKVideoKit tests (all passed),
57 AndroidRuntimeKit tests (56 passed, 1 online-install gate skipped), and
30 Node/CatPaw/Quark tests (all passed): 1060 passed, 9 skipped, zero failures.
The earlier 98-pass result was a focused uninstall regression, not the full suite.
Android lint succeeds; the JVM unit target has no sources. Dependency Kotlin
metadata diagnostics remain documented and were not suppressed.

The final full App run uses a temporary Debug test host with a unique Bundle
Identifier, original single-instance protection and Chinese system-language
arguments. This avoids the user's running App and matches existing localized
assertions. Explicit English and Chinese localization tests still run. The initial
host-configuration failures, exact skips and final results are recorded in
[0.6.1 validation](../../../../Docs/RELEASE_VALIDATION_0.6.1.md).
This temporary test setup is not the delivered Release bundle.

The historical 0.6.0 validation remains in
[its original record](../../../../Docs/RELEASE_VALIDATION_0.6.0.md).
The 0.6.1 DMG built from `25155f52fb8c416f3245c9a829a93175dec9857b` passed
Developer ID signing, Apple notarization (`Accepted`), stapling, Gatekeeper and
installation smoke tests. Real Emulator uninstall was not repeated. Signing uses
a temporary dedicated keychain as required by the
[DMG release process](../../../../Docs/DMG_RELEASE_PROCESS.md).

Formal distribution uses the existing command below. The default invocation is
local ad-hoc packaging and is not a formal Release substitute:

```sh
DEVELOPER_ID_APPLICATION='<Developer ID identity>' \
OKVIDEOMAC_NOTARY_PROFILE='OKVideoMac-Notary' \
  ./Scripts/package-app.sh --mode distribution --notarize
```

## Historical supported / verified environments

2026-09-07 的 0.5.0（Build 99）正式发布源码门禁基线为：649 项 Xcode
测试中 643 项通过、6 项按设计跳过；36 项 AndroidRuntimeKit 测试中 35 项
通过、1 项真实在线安装测试按设计跳过；173 项 OKVideoKit 测试全部通过。
本版本新增明确的 Managed / External Android Runtime 模式，并将可见窗口退出与
后台 owned Runtime 清理解耦。最终公开产物仍必须从 exact clean release commit
重新执行本文 `package-app.sh` 的 Release、签名、公证、staple、Gatekeeper、
SBOM、源码绑定与 DMG 验证门禁。

Phase 4 在 2026-08-12 已于以下环境完成验证：

- macOS 14.8.8（23J620），Apple Silicon / arm64；
- Xcode 16.2（16C5032a）；
- Swift 6.0.3（swiftlang-6.0.3.1.10）；
- 0.3.41（Build 62）arm64 Release 构建、152 项 macOS App 单元测试、
  Android Release Bridge 构建和本地 Release packaging 通过；
- 最低部署目标为 macOS 12.0；Xcode 14.2 是较早的 macOS 12 构建基线，
  不是上述 Phase 4 artifact 的实际 builder；
- Android Bridge 构建需要 JDK 17、Gradle wrapper、Android SDK 35 / build-tools
  35；其运行时能力是可选的 Experimental compatibility；
- 原生依赖构建使用 MacPorts `/opt/local` 提供 pkg-config、FFmpeg 7、libass
  等输入，并由仓库 lock、脚本和哈希校验约束。

早期 2026-07-29 环境只有 Command Line Tools，曾因编译器/SDK Swift 模块不
匹配、XCTest 不可用和依赖缺失而无法构建 App。该历史事实已被上述 Phase 4
成功验证取代，不再代表当前源码状态。

2026-08-17 的 0.3.41（Build 65）候选已通过 212 项 Xcode 集成测试、94 项
OKVideoKit 独立测试、arm64 Release 编译和 Android Release Bridge 离线构建。
最终工程候选仍必须从 exact clean commit 重新运行下述
`package-app.sh` Gate；此前 Build 62/63 的 App、ZIP、签名或公证结果不能代替
本次候选验证；Build 64 保留为上一版不可变公开发布。

2026-09-06 的 0.4.1（Build 95）正式发布自动门禁基线为：608 项 Xcode 测试中
604 项通过、4 项按设计跳过，173 项 OKVideoKit 测试通过，30 项 Node / CatPaw /
Quark 测试通过；Android Release assemble 与 lint 通过，JVM unit target 为
`NO-SOURCE`，Android instrumentation 为 70/70。最终 DMG 从 `v0.4.1` 指向的
exact clean commit 构建，并须通过 Developer ID、Apple notarization、staple、
Gatekeeper 和 source/binary 外层哈希绑定后才能公开发布。

## Current reproducibility caveats

2026-08-13 的 fresh audit 遇到 Google Maven TLS handshake termination，且
维护者当时使用的外部开发卷发生 I/O stall，导致该次独立重跑无法
完成。这些是当次网络/存储环境事实，不是源码编译失败。恢复可用网络、Xcode
和已锁定依赖缓存后，应重新运行本文门禁；正式发布仍必须来自 clean worktree
和 `package-app.sh` 的 controlled output。

## 前置条件

1. 安装完整 Xcode（Phase 4 已验证 16.2；较早 macOS 12 基线为 14.2），并选择
   其 Developer 目录。标准安装可直接执行：

   ```bash
   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
   xcodebuild -version
   ```

   如果 Xcode 安装在其他位置，可设置 `DEVELOPER_DIR` 或把实际路径传给
   `xcode-select`。仓库不要求特定卷名或维护者目录。

2. Xcode 验证完成后，安装最小开发期工具：精确 XcodeGen 2.38.0、Meson、Ninja、
   pkg-config、FFmpeg 和 libass。Monterey 本机仅使用 MacPorts：

   ```bash
   sudo /opt/local/bin/port install meson ninja pkgconfig ffmpeg7 libass
   ```

   `bootstrap.sh` 和 `build-libmpv.sh` 固定使用 `/opt/local/bin` 和
   MacPorts 的 pkg-config 搜索路径，并拒绝解析到 `/opt/homebrew` 的
   FFmpeg/libass。
3. 构建 libmpv 时需要 FFmpeg、libass 及 mpv Meson 检测到的依赖。这些只允许
   作为构建期依赖；最终 `.app` 必须携带完整 dylib 闭包。
4. 构建可选 Android Bridge 需要 JDK 17、Android SDK 35/build-tools 35 和
   Gradle wrapper 所需的已锁定 Maven artifacts。Native Mode 启动和使用不要求
   Android SDK 或 Emulator。脚本依次读取 `ANDROID_HOME`、
   `ANDROID_SDK_ROOT` 和标准目录 `$HOME/Library/Android/sdk`；找不到时会
   明确失败。Gradle 默认使用用户自己的标准缓存，设置 `GRADLE_USER_HOME`
   时则尊重该覆盖值。

5. Release 构建嵌入 Node runtime。可设置
   `OKVIDEOMAC_NODE_RUNTIME=/absolute/path/to/node` 明确选择受支持的 Node
   可执行文件；否则脚本从 `PATH` 查找 `node`。找不到时 Release 构建会立即
   失败，而不会生成缺少 Node runtime 的残缺 App。

面向最终用户的 Managed Android Runtime 与 Android Bridge 的“构建 APK”前置条件
不同：用户不需要上述 JDK 或 Android SDK。App 在第一次真实 Dex 调用时，根据
`Packages/AndroidRuntimeKit/.../RuntimeCandidateMatrix.json` 下载固定 API 35
Profile 到自己的 Application Support 目录。开发者本机的 Java、Android Studio、
Homebrew ADB 或 SDK 不能代替 Managed Purity 门禁。

## 工程和测试

```bash
cd OKVideoMac/macOS/OKVideoMac
export OKVIDEOMAC_BUILD_ROOT="${OKVIDEOMAC_BUILD_ROOT:-$PWD/Vendor/Build}"
./Scripts/bootstrap.sh
swift test \
  --package-path Packages/OKVideoKit \
  --scratch-path "$OKVIDEOMAC_BUILD_ROOT/SwiftPM"
xcodebuild \
  -project OKVideoMac.xcodeproj \
  -scheme OKVideoMac \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$OKVIDEOMAC_BUILD_ROOT/DerivedData" \
  CODE_SIGNING_ALLOWED=NO \
  build
xcodebuild \
  -project OKVideoMac.xcodeproj \
  -scheme OKVideoMac \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$OKVIDEOMAC_BUILD_ROOT/DerivedData" \
  CODE_SIGNING_ALLOWED=NO \
  test
```

AndroidRuntimeKit 的普通测试（真实下载测试按设计跳过）：

```bash
swift test --package-path Packages/AndroidRuntimeKit
```

发布验证可在隔离的 `/tmp` Application Support 目录执行一次真实 Profile 安装：

```bash
OKVIDEOMAC_MANAGED_RUNTIME_E2E_SUPPORT=/tmp/okvideomac-runtime-e2e \
  swift test --package-path Packages/AndroidRuntimeKit \
  --filter LiveManagedRuntimeE2ETests/testProductionCatalogInstallsIntoAnEmptyManagedRoot
```

该测试会下载约 2.44 GB 并展开约 5.7 GB。它不得指向真实用户的
`~/Library/Application Support/OKVideoMac`。随后使用 `android-runtime-matrix`
对该 Generation 的 `sdk`/`jre` 运行现有完整 Emulator、private ADB、Bridge、Dex
和二次复用链路。普通 CI 不运行真实 Emulator E2E，也不得把编译通过表述为实机验证。

`OKVIDEOMAC_BUILD_ROOT` 未设置时默认使用仓库内的 `Vendor/Build`。如需把下载
缓存、第三方源码、原生构建目录、DerivedData 和 `Artifacts` 放到其他磁盘，
请在运行脚本前显式导出该变量。MacPorts 本体、头文件和动态库仍位于
`/opt/local`。

## 原生依赖

```bash
./Scripts/build-quickjs.sh
./Scripts/build-libmpv.sh
```

脚本固定 QuickJS 2025-09-13-2 和 mpv v0.41.0，并验证源码 SHA-256。
QuickJS 脚本会同时构建 `libOKQuickJS.dylib` 并运行 C smoke test。
libmpv 脚本会构建 `libmpv.dylib` 和 `libOKMPVBridge.dylib`。Xcode 工程在
这些文件存在时把它们和许可证复制到 App。早期环境尚未执行 libmpv 构建的记录
属于历史状态；Phase 4 已完成稳定 native 候选构建、ABI/capability 核验与
Release packaging。新的发布 commit 仍须重新运行 package gate，不能仅复用
历史结论替代最终 artifact 验证。

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
- 从精确 Git commit 生成 project/third-party/license 源码归档；
- 把 source-side index 放入 App legal payload；
- 输出内部 zip、标准 `OKVideoMac-VERSION.dmg`、外部 binary/source manifest、
  四份 SBOM、第三方声明和统一 SHA-256；
- DMG 只包含 `OKVideoMac.app` 与 `Applications -> /Applications`，并在只读挂载
  后重新验证布局、App 版本、签名和 source index；
- `distribution --notarize` 只向 Apple 提交最终 DMG，要求状态为 `Accepted`，
  再 staple、验证 ticket 与 Gatekeeper。

源码发行缓存默认位于
`$OKVIDEOMAC_BUILD_ROOT/Downloads/SourceRelease`，产物位于
`$OKVIDEOMAC_BUILD_ROOT/Artifacts/SourceRelease`。缓存预填后可设置
`OKVIDEOMAC_SOURCE_RELEASE_OFFLINE=1` 强制离线校验。正式打包要求干净工作树；
详见仓库根目录 `Docs/SOURCE_RELEASE_PROCESS.md`。
DMG 的签名、公证和验证顺序见 `Docs/DMG_RELEASE_PROCESS.md`。

App 通过运行时桥接载入 libmpv，因此主可执行文件不直接链接 mpv；验证脚本
检查 `libOKMPVBridge.dylib` 的链接和整个 dylib 闭包。依赖或完整 Xcode 缺失
时，打包会按设计失败。
