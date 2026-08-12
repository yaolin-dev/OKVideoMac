# OKVideoMac Hardened Runtime 发布兼容性预审计

- 审计日期：2026-08-12
- 审计对象：当前工作区与由 `Scripts/package-app.sh` 重新生成的 0.3.39 (60) Release 包
- 审计平台：Apple Silicon、macOS 14.8.8、Xcode 16.2
- 目标分发：Mac App Store 外，未来使用 Developer ID Application + Hardened Runtime + Notarization
- 本轮性质：只读架构/产物审计；未修改业务代码、默认签名、entitlements、播放器或 Spider 行为

## 1. Executive Summary

### 结论：Needs Work

如果“今天开启 Hardened Runtime”指直接使用当前 ad-hoc 流水线并移除宽松
entitlement，OKVideoMac 的全部核心路径**不会**完整运行：

1. ad-hoc Hardened Runtime 宿主会因 Library Validation 拒绝同为 ad-hoc、没有
   Team ID 的 bundled dylib，QuickJS 和 libmpv smoke 均复现了
   `mapping process and mapped file ... have different Team IDs`；
2. bundled Node 22.23.0/V8 在 Hardened Runtime 且没有 JIT entitlement 时以
   `SIGTRAP` 退出，崩溃栈位于 `pthread_jit_write_protect_np`；
3. 当前打包脚本最终执行的手工 ad-hoc 签名没有传入 `--options runtime` 或
   entitlements，因此交付 `.app` 实际上根本没有启用 Hardened Runtime。

但这不是“架构已经被迫关闭 Hardened Runtime”的结论。相反，当前大部分架构
具有良好的迁移条件：

- QuickJS 是解释器，不是 JIT；不需要 `allow-jit` 或
  `allow-unsigned-executable-memory`；
- libmpv、FFmpeg、QuickJS 和其余 native dependency 都随 App 携带，最终包的
  install name/rpath 已改成 `@rpath`/`@loader_path`，可以由同一 Developer ID
  从内到外重新签名；
- 没有证据表明正式 Developer ID Release 必须关闭 Library Validation；
- Android Bridge 在外部 Android Emulator 子进程中执行 DEX/Android ELF，
  没有把 Android native code 注入 OKVideoMac 进程；
- 没有发现主 App 依赖 `DYLD_*`、RWX memory、下载 Mach-O 后 `dlopen`，或运行时
  生成 macOS executable 的实现。

真正需要现在守住的边界是 Node 与未来 native/JVM 插件：

- bundled Node 是独立子进程。如果保留 V8 JIT，应只给 **Node executable**
  `com.apple.security.cs.allow-jit`，而不是给主 App；也可评估 `--jitless`，本次
  最小测试已证明它可在零例外下启动，但尚未验证完整 Node bundle 的兼容性和性能；
- 当前下载的 Node bundle 是完整权限的远程 JavaScript。Node 默认仍可加载
  `.node` native addon、访问文件和启动子进程。当前缓存样本没有发现 native
  addon/`child_process`，但架构上尚未禁止。未来若允许远程脚本下载未签名
  `.node` 并加载，就会把 Node 推向 `disable-library-validation`，这是从现在开始
  应禁止的设计；
- Android Bridge 当前依赖用户磁盘上的 ADB/Android Emulator。它们是 subprocess
  问题，不是主进程 Library Validation 问题，但当前实机工具的签名验证失败，
  正式分发前必须形成可重复、可验证的安装/版本策略。

### 最直接的回答

> 当前代码没有形成“主 App 必须关闭 Hardened Runtime 才能正常工作”的硬性
> 架构依赖。当前确实存在三个发布阻塞：打包脚本丢失 runtime/entitlements、
> ad-hoc 环境无法代表同 Team ID Library Validation、Node/V8 需要单独处理 JIT。
> 前两项是签名流水线问题，第三项可用仅限 Node 的 `allow-jit` 或 `--jitless`
> 解决。QuickJS、libmpv/FFmpeg 本身没有要求宽松 executable-memory 权限。

## 2. 当前真实状态

### 2.1 Xcode Build Settings

通过 `xcodebuild -showBuildSettings` 读取到：

| Setting | Debug | Release | 说明 |
| --- | --- | --- | --- |
| `ARCHS` | `arm64` | `arm64` | 当前只发布 Apple Silicon |
| `ONLY_ACTIVE_ARCH` | `YES` | `YES` | 项目全局设置 |
| `CODE_SIGN_STYLE` | `Automatic` | `Automatic` | 没有 Development Team |
| `CODE_SIGN_IDENTITY` | `-` | `-` | 当前解析为 ad-hoc |
| `DEVELOPMENT_TEAM` | 未设置 | 未设置 | 无 Team ID |
| `CODE_SIGN_ENTITLEMENTS` | `Supporting/OKVideoMac.entitlements` | 同左 | Debug/Release 共用 |
| `CODE_SIGN_INJECT_BASE_ENTITLEMENTS` | `YES` | `YES` | Xcode 默认值 |
| `ENABLE_HARDENED_RUNTIME` | `NO` | `YES` | 配置间存在差异 |
| `ENABLE_APP_SANDBOX` | `NO` | `NO` | 未开启 App Sandbox |
| `OTHER_CODE_SIGN_FLAGS` | 未设置 | 未设置 | 没有手工 `--options=runtime` |
| `LD_RUNPATH_SEARCH_PATHS` | `@executable_path/../Frameworks` | 同左 | Bundle 内依赖解析 |

`project.yml` 与生成的 `project.pbxproj` 对 Debug/Release 的 Hardened Runtime
设置一致。App Sandbox 未开启是当前 Developer ID 外部分发模型的合法选择，不能
据此判断 Hardened Runtime 不兼容。

### 2.2 entitlements 源文件

当前 `Supporting/OKVideoMac.entitlements` 只有：

```xml
<key>com.apple.security.cs.disable-library-validation</key>
<true/>
```

文件注释说明它用于没有 Team ID 的本地/ad-hoc Hardened Runtime 构建。这个解释
与本次最小实验一致，但该文件同时用于 Release，容易让临时兼容例外进入未来正式
Developer ID 包。正式发布前应拆分本地测试与正式 entitlements，且正式配置默认
不包含此项。

### 2.3 打包脚本与最终产物的差异

`Scripts/package-app.sh`：

1. 以 Release 配置执行 Xcode build；
2. 同时强制 `CODE_SIGNING_ALLOWED=NO`，所以 Xcode 不会把 Release 的 runtime
   option 或 `CODE_SIGN_ENTITLEMENTS` 签进 App；
3. 完成依赖复制与 install-name 重写后，对 28 个 Mach-O 执行
   `codesign --force --sign - --timestamp=none`；
4. 没有 `--options runtime`，主 App 没有 `--entitlements`，Node 也没有独立
   entitlements。

对重新打包的 `.app` 执行实际检查得到：

```text
Signature=adhoc
TeamIdentifier=not set
CodeDirectory flags=0x2(adhoc)
Hardened Runtime flag=不存在
codesign -d --entitlements :- = 空
designated requirement = cdhash requirement
codesign --verify --deep --strict = 通过
```

因此当前真实交付状态是：**Release 编译优化 + 普通 ad-hoc 签名，不是 Hardened
Runtime Release**。源文件中的 `disable-library-validation` 也没有进入打包产物。

### 2.4 架构和 native dependency 概况

- Mach-O 总数：28；
- 主 executable：1；
- bundled helper executable：Node 1；
- `Contents/Frameworks` dylib：26；
- 全部 Mach-O 包含 arm64；项目验证脚本确认部署目标不高于 macOS 12.0；
- APK 是数据资源，包含 `classes.dex`、`classes2.dex`，当前 Bridge APK 本身无 `.so`；
- 最终 Mach-O dependency/rpath 中没有 `/opt/homebrew`、`/opt/local`、
  `/usr/local` 或 `/Users` 绝对路径；
- `codesign --verify --deep --strict` 和 `Scripts/verify-bundle.sh` 均通过。

## 3. QuickJS / JavaScript Runtime 审计

### 3.1 当前 QuickJS 构建

- 版本：QuickJS `2025-09-13-2`；
- 架构：arm64；
- `build-quickjs.sh` 以 `-O2 -fPIC` 构建 `libquickjs.a`，再链接
  `libOKQuickJS.dylib`；
- Swift 使用 `dlopen(Bundle.main/Contents/Frameworks/libOKQuickJS.dylib)`；
- Spider 源码由 `JS_Eval` 解析/编译成 QuickJS 内部 bytecode 并由解释器执行；
- HTTP/HTTPS 模块通过 Swift host callback 下载为 UTF-8 JavaScript 文本，再交给
  `JS_Eval`；不是 native module。

对实际 QuickJS 源码、桥接代码和二进制搜索：

| 项目 | 结果 |
| --- | --- |
| JIT compiler | 无 |
| 动态生成机器码 | 无 |
| `mmap(PROT_EXEC)` | 无 |
| `MAP_JIT` | 无 |
| `mprotect(... PROT_EXEC ...)` | 无 |
| `pthread_jit_write_protect_np` | 无 |
| `vm_protect` | 无 |
| RWX / unsigned executable memory | 无 |

结论：**当前 QuickJS 是 interpreter。** JavaScript 被编译成引擎 bytecode 不等于
生成可执行机器码，也不要求 executable memory。

### 3.2 QuickJS entitlement 结论

> 当前 QuickJS 不需要 `com.apple.security.cs.allow-jit`。

> 当前 QuickJS 不需要
> `com.apple.security.cs.allow-unsigned-executable-memory`。

在最小 Hardened Runtime smoke 中，QuickJS 的失败发生在 dyld 加载桥接 dylib
之前，错误是 ad-hoc Team ID/Library Validation，不是 executable memory 拒绝。
使用仅用于 ad-hoc 对照的 `disable-library-validation` 后，原 smoke 测试通过。

### 3.3 dormant QuickJS libc loader

构建脚本使用 `-Wl,-force_load,libquickjs.a`，实际 archive 包含
`quickjs-libc.o`。因此最终 dylib 中存在：

- `js_module_loader`；
- `dlopen` / `dlsym`；
- `std`/`os` module 相关文件、进程 API 实现符号。

当前 `OKQuickJSBridge.c` 没有初始化 `std`/`os` module，并以
`JS_SetModuleLoaderFunc(... host_module_loader ...)` 替换 module loader；暴露给
Spider 的 API 也是固定的网络、日志、delay 和解析适配器。因此远程 Spider
JavaScript 当前无法从 JS 调用这段 native loader。

这不是当前 P0，但属于 P2 硬化项：未来可只链接 QuickJS core objects，或加入 CI
检查，阻止 `js_module_loader`/`execve`/`popen` 等不需要的符号重新暴露。更重要的
开发边界是：不要调用 `js_init_module_std/os`，不要把 upstream
`js_module_loader` 接回不可信 Spider。

## 4. libmpv / FFmpeg 审计

### 4.1 构建特征

当前 libmpv 0.41.0 构建显式设置：

```text
cplayer=false
libmpv=true
javascript=disabled
lua=disabled
cplugins=disabled
vapoursynth=disabled
libavdevice=disabled
plain-gl=enabled
gl=enabled
videotoolbox-gl=disabled
coreaudio=enabled
```

这显著降低了“播放器自行加载第三方插件/脚本/外部 codec”的风险。FFmpeg 以
dylib 链嵌入，不存在 App 运行时启动 `ffmpeg` executable 的路径。VideoToolbox、
CoreMedia、AVFoundation、AudioToolbox、CoreAudio 等是 Apple 系统 framework。

### 4.2 最终依赖链

关键链路：

```text
OKVideoMac
  dlopen -> libOKMPVBridge.dylib
    @rpath -> libmpv.dylib
      @rpath -> libavcodec/libavformat/libavfilter/libavutil
                libswresample/libswscale/libass/libplacebo/... dylib
      system   -> AVFoundation/CoreMedia/CoreAudio/AudioToolbox/...
```

`package-app.sh` 会递归复制 MacPorts/Homebrew/local dependency，将 install name
改成 `@rpath/<basename>`，删除外部 absolute rpath，然后从叶子依赖向宿主重签。
重新打包后的实际 dependency/rpath 扫描没有发现开发机绝对路径。

`MPVRenderView` 另以绝对系统路径加载：

```text
/System/Library/Frameworks/OpenGL.framework/OpenGL
```

这是系统 framework（分类 B），不是用户 dylib。libplacebo/freetype 等通用库本身
带有 `dlopen` 能力或系统图形探测字符串，但当前播放器配置没有开启 C plugin、
Vulkan、Lua、JavaScript 或 VapourSynth 插件路径，也没有观察到 App 指定外部
codec/plugin 目录。

### 4.3 Library Validation 回答

1. **今天的 ad-hoc Hardened Runtime 测试会阻止加载。** 已复现 QuickJS 与
   libmpv bridge 被拒绝，因为主 executable 和 dylib 都没有可匹配的 Team ID。
2. **正式 Developer ID Release 不应沿用这个结论。** Apple 的 Library
   Validation 允许 Apple 签名或与宿主同 Team ID 的 library。当前所有 26 个
   dylib 都能在 bundle 完成重写后统一由同一 Developer ID 重新签名。
3. **当前没有证据表明必须关闭 Library Validation。** 正式签名时应先对全部
   embedded dylib 使用同一 Developer ID 签名，再以最小 entitlement 验证。
4. 只有在未来加载其他开发者签名或未签名的外部 native plugin 时，才会出现
   `disable-library-validation` 的真实需求；当前应明确禁止这种扩展方式。

Apple 对 Library Validation 的定义是：Hardened Runtime 默认只允许 Apple 或
同 Team ID 的 library；`disable-library-validation` 是为加载第三方开发者插件
准备的例外。参见 [Disable Library Validation Entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-library-validation)。

## 5. 动态加载分类

| 行为 | 分类 | 当前路径 | 结论 |
| --- | --- | --- | --- |
| Swift `dlopen(libOKMPVBridge.dylib)` | A | App `Frameworks` | 低风险；同 Team ID 重签 |
| Swift `dlopen(libOKQuickJS.dylib)` | A | App `Frameworks` | 低风险；同 Team ID 重签 |
| dyld 加载 libmpv/FFmpeg 依赖链 | A | App `Frameworks` | 低风险；全部纳入 inventory |
| `dlopen` OpenGL | B | `/System/Library/Frameworks` | 系统 framework |
| 主 App 加载用户 dylib | C | 未发现 | 当前不支持 |
| 主 App 下载后 `dlopen` | D | 未发现 | 必须继续禁止 |
| 主 App 生成 dylib/executable | E | 未发现 | 必须继续禁止 |
| QuickJS libc native loader | 潜在 C/D | 二进制中存在但当前不可达 | P2，防止未来接通 |
| Node `.node` addon | 潜在 C/D，位于 Node 子进程 | Node 能力未禁止；当前样本未使用 | P1 设计边界 |

当前软件不存在一项明确的产品功能，要求把“用户提供的未签名 native code”加载
进 OKVideoMac 主进程。Android DEX/ELF 在 Android guest 内执行，不属于 macOS
主进程 dylib；Node remote bundle 当前是 JavaScript 文本，不是 Mach-O。

## 6. Node JavaScript Runtime

### 6.1 调用链

```text
NodeBundleRuntimeService
  -> 下载 index.js.md5 与 index.js
  -> 以 MD5 校验兼容上游内容，缓存 index.js (0600)
  -> 生成 launcher.js (0600；无 executable bit)
  -> Process.executableURL = bundled NodeRuntime/node
  -> arguments = [launcher.js]
  -> Node/V8 子进程 require(index.js)
  -> 仅通过 127.0.0.1 HTTP 与主 App 交互
```

Node 首选 App 内的 `Contents/Resources/NodeRuntime/node`，如果缺失还会回退到
`/opt/homebrew`、`/opt/local`、`/usr/local` 的外部 Node。正式包验证要求 bundled
Node 存在，所以正式发布路径不应依赖这些回退候选。

### 6.2 executable memory 实验

实际 Node：22.23.0，V8 12.4.254.21-node.56。二进制导入/包含：

- `mmap`、`mprotect`；
- `pthread_jit_write_protect_np`；
- 多个 V8 JIT/ThreadIsolation 符号。

临时复制二进制并以 ad-hoc `--options runtime` 签名后：

| Node 条件 | 结果 |
| --- | --- |
| 无 runtime exception | 退出 133 / `SIGTRAP` |
| 仅 `com.apple.security.cs.allow-jit=true` | 正常执行 JavaScript |
| 无 entitlement + `--jitless` | 正常执行 JavaScript；Node 同时提示禁用 WebAssembly |

无 entitlement 的崩溃报告在主线程显示：

```text
pthread_jit_write_protect_np
v8::internal::ThreadIsolation::Initialize
v8::internal::V8::Initialize
```

因此：

- 若保留当前 V8 JIT，**Node executable** 需要 `allow-jit`；
- 主 OKVideoMac executable 不需要因 Node 而获得 `allow-jit`；
- 没有证据需要 `allow-unsigned-executable-memory`；
- `--jitless` 是最小权限替代方案，但必须对当前 6 MiB bundle 的首页、搜索、播放、
  WebAssembly 依赖和性能做完整回归后才能选用。

Apple 明确区分：`allow-jit` 允许使用 `MAP_JIT` 创建 JIT memory，而
`allow-unsigned-executable-memory` 是绕过 `MAP_JIT` 限制的更宽松 legacy 例外。
参见 [Hardened Runtime](https://developer.apple.com/documentation/security/hardened-runtime)。

### 6.3 远程 Node bundle 风险

当前下载校验是远端提供的 MD5；只有带账号密码的 HTTP 地址会升级成 HTTPS。
MD5 可以检测偶发损坏/满足上游协议，但不是发布方签名或可信内容认证。

当前缓存样本（SHA-256
`c0b64921bb919b58161cd485e9233238d19ed01634f6db5b8a86f9a36eb44322`）中未发现：

```text
child_process
process.dlopen
execFile / execSync / spawnSync
ffi-napi / node-gyp
```

但 Node 启动参数没有 `--no-addons`，也没有 permission model 或 OS service sandbox。
远程 bundle 在能力上仍可访问 `fs`、网络、`child_process`，并可尝试下载/加载
`.node` native addon。若允许这一方向扩大，未来可能迫使 Node executable 关闭
Library Validation，或让下载后的 executable 逃离当前审计边界。

发布前建议按优先顺序评估：

1. 明确禁止 remote bundle 使用 native addon，并以 `--no-addons`/自动测试落实；
2. 以 HTTPS + pinned SHA-256/发布方签名替代“同源 MD5 即可信”；
3. 将 Node 放入独立 helper/XPC 进程并限制文件、网络和子进程能力；
4. Node 使用独立 entitlements，只给 `allow-jit` 或改用 `--jitless`；
5. 不给 Node `disable-library-validation` 来兼容远程 `.node`。

## 7. Android Bridge 审计

### 7.1 清晰调用链

```text
OKVideoMac 主进程
  -> AndroidDexBridgeRuntime.ensureReady()
  -> Process: 外部 Android Emulator
  -> Process: 外部 adb（大量短命令）
  -> adb install App bundle 内 AndroidDexBridge-release.apk
  -> adb shell am start BridgeActivity
  -> adb forward host loopback ports -> Android guest loopback ports
  -> macOS URLSession -> http://127.0.0.1:19978
  -> Android Bridge app
  -> 下载/校验远程 jar/dex
  -> Android DexClassLoader 加载 classes.dex
  -> 可能在 Android guest 内加载 Android ELF/JNI `.so`
```

结论：Android Bridge 是**独立外部 subprocess + Android guest runtime**，不是向
OKVideoMac 进程加载 native code。Android 内的 `DexClassLoader`、`System.load`、
文件 executable permission 和 `chmod 777` 均发生在模拟器/Android 文件系统，
不申请 macOS 主进程 executable memory，也不触发主 App Library Validation。

### 7.2 macOS 侧 executable 来源

| Executable | 来源 | Bundle 内 | 当前签名状态 | Hardened Runtime 风险 |
| --- | --- | --- | --- | --- |
| `NodeRuntime/node` | 构建机 Node 22 direct | 是 | ad-hoc，无 runtime | Node 自身需 `allow-jit` 或 `--jitless` |
| compatibility `adb` wrapper | 用户 Application Support | 否 | unsigned zsh script | subprocess；Gatekeeper/来源可重复性风险 |
| `adb-macos14` | 用户 Application Support | 否 | 声明 Google Team，但 `codesign --verify` 失败 | P1 外部工具完整性 |
| Android SDK `adb` | `/Volumes/XcodeDev/AndroidSDK` | 否 | 声明 Google Team/runtime，但实际验证失败 | P1 外部工具完整性 |
| Android Emulator | `/Volumes/XcodeDev/AndroidSDK` | 否 | 声明 Google Team/runtime，但实际验证失败 | P1，且有自身 dylib/helper 链 |
| `/bin/zsh` | Apple 系统（由 wrapper shebang 间接启动） | 否 | Apple 系统代码 | Hardened Runtime 允许 subprocess |

主 App 不直接启动 macOS `java`，不启动 `ffmpeg` executable，不调用 Python、Node
包管理器、`osascript` 或 `/bin/sh`。ADB wrapper 间接使用 `/bin/zsh`。开发期的
Gradle/Java、curl、make、meson、ninja、clang、codesign、install_name_tool、ditto
等不属于 App 运行时。

Hardened Runtime 本身通常不禁止父进程启动外部 executable，也不会把父进程
entitlements 自动授予子进程。这里的主要问题是 Gatekeeper、quarantine、工具
完整性和正式产品的可安装性，而不是 App Sandbox（当前也未启用）。

### 7.3 未来边界

- 保持 Android/JNI/ELF 在 emulator 或独立受控 service 内，禁止注入主进程；
- 不从任意用户路径选择 adb/emulator 后静默执行；需要版本、hash、签名与来源检查；
- 如果未来把 Android 工具嵌入 App，则其全部 Mach-O、dylib/helper 都成为 nested
  code，必须 Developer ID 签名、Hardened Runtime 检查和 notarization；
- 不要把 L4 Android ELF/JNI 插件直接移植为主 App 的未签名 macOS dylib；
- 计划中的 JVM XPC service 应坚持包能力扫描，禁止 native/JNI 或只允许同 Team
  ID、随 App 固定发布的 native library。

## 8. DYLD、环境变量和临时 executable

全仓产品代码没有发现：

```text
DYLD_LIBRARY_PATH
DYLD_FRAMEWORK_PATH
DYLD_INSERT_LIBRARIES
DYLD_FALLBACK_LIBRARY_PATH
com.apple.security.cs.allow-dyld-environment-variables
```

主 App 的加载依赖由 LC_RPATH 与 bundle layout 决定，不依赖用户 shell 环境。
Node 与 Emulator subprocess 复制父进程 environment 并覆盖少量业务变量，但没有
主动设置 `DYLD_*`。Hardened Runtime 正式包不应允许 DYLD 注入。

运行时生成/下载内容：

| 内容 | 权限/执行方式 | 是否 macOS native code |
| --- | --- | --- |
| Node `index.js` | 0600，由 bundled Node 解释/JIT | 否 |
| Node `launcher.js` | 0600，无 executable bit | 否 |
| QuickJS module source | 内存字符串，由 QuickJS 解释 | 否 |
| Android jar/dex | Android guest `DexClassLoader` | 否（macOS 视角） |
| Android ELF/JNI | Android guest 内加载 | 否（不是 Mach-O） |
| 下载 Mach-O/dylib | 未发现 | 不适用 |
| 临时 macOS executable | 未发现 | 不适用 |

## 9. Bundle nested-code inventory

```text
OKVideoMac.app
└── Contents
    ├── MacOS
    │   └── OKVideoMac                         # 主 executable
    ├── Frameworks                            # 26 个 arm64 dylib
    │   ├── libOKMPVBridge.dylib
    │   ├── libOKQuickJS.dylib
    │   ├── libmpv.dylib
    │   ├── libavcodec.61.dylib
    │   ├── libavfilter.10.dylib
    │   ├── libavformat.61.dylib
    │   ├── libavutil.59.dylib
    │   ├── libswresample.5.dylib
    │   ├── libswscale.8.dylib
    │   ├── libass.9.dylib
    │   ├── libplacebo.360.dylib
    │   ├── libbrotlicommon.1.dylib
    │   ├── libbrotlidec.1.dylib
    │   ├── libbz2.1.0.dylib
    │   ├── libc++.1.0.dylib
    │   ├── libc++abi.1.dylib
    │   ├── libfreetype.6.dylib
    │   ├── libfribidi.0.dylib
    │   ├── libharfbuzz.0.dylib
    │   ├── libiconv.2.dylib
    │   ├── libjpeg.8.dylib
    │   ├── liblcms2.2.dylib
    │   ├── liblzma.5.dylib
    │   ├── libpng16.16.dylib
    │   ├── libsqlite3.dylib
    │   └── libz.1.dylib
    └── Resources
        ├── NodeRuntime/node                   # helper executable
        └── AndroidDexBridge-release.apk       # data/APK，不是 Mach-O
```

未来 Developer ID 签名时需要重新签名：

1. 全部 26 个 dylib；
2. Node helper executable（使用 Node 专属 entitlements）；
3. 主 OKVideoMac executable/App bundle（最后签名）；
4. 如果以后新增 framework、XPC、helper 或嵌入 Android tools，也必须加入显式
   inventory，不能依赖 `codesign --deep` 代替正确的由内到外签名。

Node executable 目前放在 `Contents/Resources`。它能通过当前 deep verification，
但 Resources 通常是数据位置，不是 nested executable 的标准位置。正式签名前应
评估迁到 `Contents/Helpers`、`Contents/MacOS` 或独立 XPC service，并让验证脚本
显式检查它的 runtime flag、entitlements、Team ID 和 designated requirement。

Apple 也建议复杂产品逐项签 nested code，而不是用 `codesign --deep` 签名，因为
不同 executable 可能需要不同 entitlements。参见
[Creating distribution-signed code for macOS](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/)。

## 10. Runtime 风险矩阵

| 模块 | 技术 | Hardened Runtime 风险 | entitlement 结论 | 等级 |
| --- | --- | --- | --- | --- |
| 主 App | Swift/AppKit/SwiftUI | 当前打包产物未启用 runtime | 正式最小化；不需 JIT | P1 |
| QuickJS | in-process interpreter dylib | ad-hoc LV 测试失败；无 exec memory | 无 JIT/unsigned-memory | P0（当前 ad-hoc 测试）/P3（同 Team ID 后） |
| QuickJS libc loader | dormant native loader | 未来接通会加载外部 native module | 不应用 disable LV 掩盖 | P2 |
| libmpv | in-process dylib | ad-hoc LV 测试失败 | 同 Team ID，目标不需 disable LV | P0（当前 ad-hoc 测试）/P3（同 Team ID 后） |
| FFmpeg | bundled dylib chain | 需全部同 Team ID 重签 | 无 JIT/unsigned-memory | P1 流水线 |
| OpenGL | Apple system framework | deprecated，但 HR 允许 | 无 | P3 |
| VideoToolbox | Apple system framework | 无特有 HR 风险 | 无 | P3 |
| Node/V8 | bundled subprocess | JIT 在零例外下 SIGTRAP | Node only: allow-jit 或 jitless | P0 |
| remote Node bundle | downloaded JS | 可扩展到 addon/subprocess，当前未封边 | 不应启用 disable LV/unsigned-memory | P1 |
| Android Bridge | external emulator/ADB subprocess | 外部工具签名/来源不稳定 | 主 App 无特殊 entitlement | P1 |
| Android DEX/ELF | guest runtime | 不进入 macOS 主进程 | 不适用 | P3（HR）/P1（供应链） |
| SQLite | bundled dylib | App 启动即需通过 LV | 同 Team ID 重签 | P1 流水线 |

## 11. Hardened Runtime entitlement 建议

### 11.1 逐项结论

| Entitlement | 当前是否需要 | 原因 | 正式 Release 是否应存在 |
| --- | --- | --- | --- |
| `com.apple.security.cs.allow-jit` | 主 App: No；Node: Yes（若保持 JIT） | QuickJS 无 JIT；V8 实测需要 | 只在 Node: Yes，或 jitless 后 No |
| `com.apple.security.cs.allow-unsigned-executable-memory` | No | 未发现 legacy RWX/非 `MAP_JIT` 需求 | No |
| `com.apple.security.cs.disable-library-validation` | ad-hoc HR 测试: Yes；Developer ID 目标: No | ad-hoc 无 Team ID；正式可同 Team ID 重签 | 默认 No |
| `com.apple.security.cs.allow-dyld-environment-variables` | No | 无 `DYLD_*` 依赖 | No |
| `com.apple.security.get-task-allow` | No | 无调试器/附加进程需求；实际产物也没有 | No |

### 11.2 必须

- 如果正式 Node 使用 V8 JIT，只给 Node executable `allow-jit`；
- 每个 executable 使用独立、最小 entitlements；
- 主 App、Node、全部 dylib 使用同一 Developer ID，Node/主 App开启 runtime；
- Release 保证 `get-task-allow` 不存在。

### 11.3 可能需要

- Node `allow-jit`：取决于最终选择 JIT 还是经过完整验证的 `--jitless`；
- 当前没有其他“可能需要”的宽松 runtime exception。

### 11.4 明确不建议启用

- 主 App `allow-jit`；
- 任意进程 `allow-unsigned-executable-memory`；
- 正式主 App `disable-library-validation`；
- 为 Node remote native addon 启用 `disable-library-validation`；
- `allow-dyld-environment-variables`；
- Release `get-task-allow`；
- `disable-executable-page-protection`。

## 12. 发布阻塞等级

### P0 — 发布阻塞

1. **Node/V8 JIT 未签独立 entitlement。** 一旦 Node 开启 Hardened Runtime，当前
   启动方式在 V8 初始化时 `SIGTRAP`。发布前必须选择 Node-only `allow-jit` 或
   完整验证 `--jitless`。
2. **当前 ad-hoc 最小 Hardened Runtime 无法通过 Library Validation。**
   QuickJS/libmpv smoke 已复现；主 App还直接链接 bundled sqlite3，同一问题也会
   影响 App dyld 启动。不能把这个实验失败误解为需要永久关闭 LV；真正的验收必须
   用同一 Developer ID 重签全部 nested code。
3. **打包产物没有 runtime flag。** `ENABLE_HARDENED_RUNTIME=YES` 被
   `CODE_SIGNING_ALLOWED=NO` + 最终普通 ad-hoc 重签抵消。正式流水线必须改成显式
   Developer ID + `--options runtime` + 分 executable entitlements。

### P1 — 高风险

1. `disable-library-validation` 位于 Debug/Release 共用 entitlement 文件，未来很
   容易误入正式包。
2. remote Node bundle 目前具有完整 Node 能力，尚未禁止 native addon 或
   subprocess；继续扩大后会显著增加 HR 与供应链迁移成本。
3. Android Bridge 依赖 bundle 外的 ADB/Emulator；本机实际 `codesign --verify`
   对 adb、adb-macos14、emulator 均失败。虽然不是主进程 HR 限制，但会成为正式
   分发、Gatekeeper、支持和可重复性问题。
4. 26 个 dylib 与 Node 目前都只做 ad-hoc 签名；正式“同 Team ID 能通过 LV”的
   判断还没有 Developer ID 实物验证。
5. package verification 只检查签名有效/arm64/minOS/绝对路径，没有断言 runtime
   flag、Team ID、timestamp、entitlements allowlist 或 nested code 标准位置。

### P2 — 应改进

1. Node helper 位于 `Contents/Resources`，应评估标准 helper/XPC 位置。
2. QuickJS `-force_load` 把当前不需要的 libc native loader/进程能力链接进 dylib；
   建议收窄链接面或加 symbol denylist。
3. Node 的 package-manager 外部 fallback 应在正式包路径中禁用或只作为明确的
   开发诊断选项。
4. Node bundle 的 MD5 只能做兼容/损坏检测，发布信任应使用 HTTPS + SHA-256
   allowlist/签名。
5. libplacebo/freetype 等通用库保留通用 `dlopen` 能力；应以每次依赖升级后的
   runtime loader/inventory 测试防止新插件路径进入。

### P3 — 无需现在处理

1. App Sandbox 关闭；Developer ID 外部分发不要求开启，和 HR 是不同机制。
2. OpenGL/NSOpenGLView 已 deprecated，但不是 Hardened Runtime blocker。
3. Developer ID certificate、secure timestamp、notarization、staple、Gatekeeper
   是正式发布阶段配置，本轮不实施。
4. TCC 使用说明、quarantine/Gatekeeper 验收应在正式发布测试矩阵中完成，不应
   与 Library Validation 混为一谈。

## 13. 当前就应该遵守的开发边界

### 可以继续做

- 使用当前 QuickJS interpreter 执行 JavaScript/bytecode；
- 从 HTTP/HTTPS 获取 JavaScript source，经固定 host API 解释执行；
- 使用 App bundle 内固定版本、可递归盘点、可同 Team ID 签名的 dylib/framework；
- 继续使用 `@rpath`、`@loader_path`、`@executable_path` 的 bundle 内相对布局；
- 使用 Apple system frameworks，如 OpenGL、VideoToolbox、AVFoundation；
- 把高风险 Android/JVM/Node 能力放在独立 subprocess/XPC 边界；
- bundled helper executable 由 App 发布方固定版本、签名、notarize；
- Android DEX/ELF 继续留在 Android guest，不进入主 App；
- 为不同 executable 配置不同最小 entitlements；
- 在每次 native dependency 升级后做 Mach-O、install name、rpath、Team ID、
  runtime flag 和 entitlement inventory。

### 从今天开始不要做

- 不要让 Spider/插件向 OKVideoMac 主进程注入任意用户 dylib、`.bundle` 或 `.so`；
- 不要下载 Mach-O/`.node`/dylib 后 `dlopen`；
- 不要给 Node remote bundle 开放 native addon 作为兼容路径；
- 不要把 QuickJS 改成 JIT，除非先提交明确的隔离、entitlement 和回归设计；
- 不要使用 RWX、非 `MAP_JIT` executable memory 或动态生成 unsigned native code；
- 不要依赖 `DYLD_INSERT_LIBRARIES`、`DYLD_LIBRARY_PATH` 或用户 shell 环境注入；
- 不要用 `disable-library-validation` 掩盖 nested code 未同 Team ID 签名；
- 不要用 `allow-unsigned-executable-memory` 掩盖 legacy runtime 实现；
- 不要把 Android ELF/JNI 改名/转换后直接塞进 macOS 主进程；
- 不要从未经 hash/签名/版本校验的任意用户路径启动 adb、emulator、java 或其他
  native runtime；
- 不要只使用 `codesign --deep` 代替显式的 nested-code 签名清单；
- 不要让 Release 带 `get-task-allow`。

## 14. 临时 Hardened Runtime 验证记录

本轮没有修改 Xcode project/xcconfig。实验全部在 `/tmp` 复制品中进行：

1. 将实际 26 个 dylib 复制后以 ad-hoc `--options runtime` 重签；
2. 新建并签名 QuickJS 与 MPV smoke host，不带 entitlement；
3. 两者都被 Library Validation 以空 Team ID 不匹配拒绝；
4. 仅作为原因对照，给 smoke host 使用当前
   `disable-library-validation` 后：
   - QuickJS bridge smoke passed；
   - OKMPVBridge smoke passed，且成功加载完整 FFmpeg/libass/libplacebo 链；
5. Node 分别验证零例外、Node-only `allow-jit`、`--jitless`，结果见第 6 节；
6. 读取 `amfid`/kernel/syspolicyd 日志，确认 dylib 拒绝原因是 Library
   Validation；Node 崩溃报告确认发生在 `pthread_jit_write_protect_np`。

没有使用宽松 entitlement 把实验结果包装成“正式可发布”。由于本轮禁止配置
Developer ID，无法完成“同 Team ID + Library Validation 开启”的最终实物验证；
也因此没有把 ad-hoc 对照 App 当成正式 Hardened Runtime 验收包。

本轮重新运行 `Scripts/package-app.sh` 的结果：

```text
Android Release bridge build: passed
Xcode Release build: passed
Bundle verification: passed
codesign --verify --deep --strict: passed
Archive generation: passed
最终签名: ad-hoc，非 Hardened Runtime
```

首页、配置、搜索、QuickJS Spider、点播、直播、字幕、seek、fullDestroy、重新播放、
Android Bridge 的完整交互回归没有在临时 HR App 上宣称完成。原因是当前没有
Developer ID，最小 ad-hoc HR App 在 dyld/Library Validation 阶段已经与正式签名
模型不同。正式证书可用后应按下一节 checklist 做一次完整回归和系统日志检查。

## 15. 正式发布时待做事项

```text
[ ] 加入 Apple Developer Program
[ ] 取得 Developer ID Application certificate
[ ] 为主 App、Node helper、全部 nested code 建立显式签名顺序
[ ] 主 App 与 Node 开启 Hardened Runtime / --options runtime
[ ] 拆分主 App 与 Node entitlements
[ ] 主 App 使用最小 entitlement；默认启用 Library Validation
[ ] Node 选择 allow-jit 或经完整回归的 --jitless
[ ] 确认不含 allow-unsigned-executable-memory
[ ] 确认不含 allow-dyld-environment-variables
[ ] 确认不含 get-task-allow
[ ] 正式 entitlements 不含 disable-library-validation
[ ] 26 个 dylib 与主 App 使用相同 Team ID
[ ] 处理 Node helper 的标准 bundle 位置
[ ] 明确 Android SDK/ADB/Emulator 的安装、hash、签名与版本策略
[ ] codesign -dvvv 检查每个 Mach-O 的 runtime flag/TeamIdentifier/timestamp
[ ] codesign -d --entitlements :- 检查主 App 与每个 executable
[ ] codesign --verify --deep --strict --verbose=4
[ ] 验证所有 install name/rpath 无开发机绝对路径
[ ] 运行最小 Library Validation，不添加 disable-library-validation
[ ] 完整回归首页、配置、搜索、QuickJS Spider
[ ] 完整回归点播、直播、libmpv、FFmpeg、字幕、seek、fullDestroy、重新播放
[ ] 完整回归 Node bundle，含 JIT/jitless 性能与 WebAssembly 兼容性
[ ] 完整回归 Android Bridge 与外部工具 Gatekeeper 行为
[ ] 检查 amfid/syspolicyd/taskgated/kernel/dyld 日志
[ ] 使用 notarytool 提交 Notarization
[ ] 检查完整 notary log，不忽略 warning
[ ] staple ticket
[ ] spctl/Gatekeeper 验证
[ ] 在干净用户账户和无开发工具机器验证
[ ] 在 macOS 12 最低系统与当前 macOS 分别验证
```

Apple 当前要求 notarization 的 macOS App/command-line targets 开启 Hardened
Runtime，并明确要求不要在提交软件中保留 `get-task-allow=true`。参见
[Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
与 [Resolving common notarization issues](https://developer.apple.com/documentation/security/resolving-common-notarization-issues)。

## 16. 最终判断

当前最值得保留的架构选择是：QuickJS 解释执行、固定 bundle dylib、Android/Dex
subprocess 隔离、Node 独立 executable。最需要现在收紧的是：remote Node bundle
不得扩展到 native addon/任意 subprocess，未来 JVM/XPC 不得加载用户未签名 native
plugin，所有 native dependency 必须保持可枚举、可重签、同 Team ID。

只要守住这些边界，未来迁移的主要工作是可控的签名与发布流水线建设，而不是
重写 QuickJS、播放器或 Android Bridge 架构。当前没有证据支持给主 App 增加 JIT、
unsigned executable memory、DYLD 或 disable-library-validation 例外。
