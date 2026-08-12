# OKVideoMac Hardened Runtime Phase 2 Implementation

- 实施日期：2026-08-12
- 验证平台：Apple Silicon、macOS 14.8.8、Xcode 16.2
- 目标分发：Developer ID Application + Hardened Runtime + Notarization
- 当前测试产物：0.3.39 (60)，arm64，本地 ad-hoc Hardened Runtime

## 1. Final Status

**评级：Ready with Remaining P1**

Phase 2 已经建立可审计的发布基础：

- Debug 与 Release 不再共用宽松 entitlement；
- 正式主 App entitlement 是空的最小权限集；
- Node/V8 单独获得且只获得 `com.apple.security.cs.allow-jit`；
- `package-app.sh` 明确区分 `local` 与 `distribution`；
- distribution 只接受显式 `Developer ID Application`，逐项由内到外签名，
  使用 Hardened Runtime 与 secure timestamp，不使用 `--deep` 创建签名，也不会在
  最后用 ad-hoc 覆盖；
- 完整验证会检查 28 个 Mach-O 的签名、Team ID、Runtime Flag、架构和 entitlement
  边界；
- 可选 `--notarize` 会通过 notarytool keychain profile 提交、等待、staple，并要求
  Gatekeeper 验收通过。

本机钥匙串当前返回 `0 valid identities found`，且没有 notarization credentials。
因此本轮**没有**生成 Developer ID 实物签名，没有验证同 Team ID 下 Library
Validation 的正式加载，也没有执行 Apple notarization。当前产物是用于本机验证的
ad-hoc Hardened Runtime 包，不是可对外分发的 Developer ID 包。

结论：代码库已经具备 Developer ID + Hardened Runtime + Notarization 的发布链，
但只有在提供真实证书和公证凭据后，才能把状态提升为 `Ready`。

## 2. Files Changed

| 文件 | 修改内容 | 原因 |
| --- | --- | --- |
| `project.yml` | Debug/Release 分别引用开发/发布 entitlement；内嵌阶段不再提前 ad-hoc 签 QuickJS/Node | 防止宽松权限进入 Release，并把签名延后到完整 inventory 形成后 |
| `OKVideoMac.xcodeproj/project.pbxproj` | 同步上述实际 Xcode 配置 | 保证当前工程与 XcodeGen 源配置一致 |
| `Supporting/OKVideoMac.dev.entitlements` | 仅包含开发态 `disable-library-validation`，并写明禁止用于分发 | 支持无 Team ID 的本地 Hardened Runtime smoke |
| `Supporting/OKVideoMac.release.entitlements` | 空 entitlement | 正式主 App 保持最小权限并启用 Library Validation |
| `Supporting/NodeHelper.entitlements` | 仅包含 `allow-jit` | 满足 Node 22/V8 的实测 JIT 需求，不扩大主 App 权限 |
| `Supporting/OKVideoMac.entitlements` | 删除 | 消除 Debug/Release 共用宽松文件的误用入口 |
| `Scripts/package-app.sh` | 新增 local/distribution/notarize 模式；显式 nested signing；正式身份硬校验 | 修复最终 ad-hoc 重签覆盖 Runtime Flag/entitlement 的 P0 问题 |
| `Scripts/verify-release-signing.sh` | 新增完整只读验签和 Mach-O inventory | 自动阻止权限泄漏、Team ID 不一致、ad-hoc 混入和非 arm64 对象 |
| `Scripts/smoke-hardened-runtime.sh` | 新增 QuickJS、MPV/FFmpeg、Node/V8、App 启动 smoke | 验证真实加载/初始化，而不是只检查 `otool` |
| `Docs/HARDENED_RUNTIME_PHASE2_IMPLEMENTATION.md` | 本实施与验证报告 | 留存真实证据、未验证项和 Phase 3 风险 |

本轮没有修改播放器、Spider、直播、点播、UI、Android Bridge 协议、缓存或性能业务
逻辑。

## 3. Entitlement Matrix

### 3.1 正式 distribution 策略

| Component | Hardened Runtime | allow-jit | disable-library-validation | unsigned executable memory |
| --- | ---: | ---: | ---: | ---: |
| OKVideoMac | YES | NO | NO | NO |
| Node | YES | YES | NO | NO |
| libmpv / FFmpeg / QuickJS / bundled dylib | YES, signed | N/A | N/A | N/A |

`get-task-allow` 同样被正式验签脚本禁止。主 App 也禁止 `allow-jit`，Node 禁止
`disable-library-validation` 与 `allow-unsigned-executable-memory`。

### 3.2 本机实际验证产物

| Component | Signature | Team ID | Runtime | Entitlement |
| --- | --- | --- | ---: | --- |
| OKVideoMac | ad-hoc | not set | YES | development-only `disable-library-validation` |
| Node 22.23.0 | ad-hoc | not set | YES | only `allow-jit` |
| 26 bundled dylib | ad-hoc | not set | YES | none |

本地例外不代表正式发布策略；它只补偿 ad-hoc 签名没有 Team ID 的事实。

## 4. Signing Chain

签名顺序为：叶子 dylib → 上层 dylib/bridge → Node → 主 executable → `.app`。
`codesign --deep` 只用于最终只读验证。

以下是最终本机验证包的真实 inventory。28 个对象均为 arm64、ad-hoc、
`TeamIdentifier=not set`、Runtime Flag=YES；distribution 模式会把每一项替换为同一
Developer ID/Team ID，否则验证失败。

| Path | Architecture | Signature | Team ID | Hardened Runtime | Entitlement |
| --- | --- | --- | --- | ---: | --- |
| `Contents/MacOS/OKVideoMac` | arm64 | ad-hoc | not set | YES | dev: disable Library Validation |
| `Contents/Resources/NodeRuntime/node` | arm64 | ad-hoc | not set | YES | allow-jit |
| `Contents/Frameworks/libOKMPVBridge.dylib` | arm64 | ad-hoc | not set | YES | none |
| `Contents/Frameworks/libOKQuickJS.dylib` | arm64 | ad-hoc | not set | YES | none |
| `Contents/Frameworks/libmpv.dylib` | arm64 | ad-hoc | not set | YES | none |
| `Contents/Frameworks/libavcodec.61.dylib` | arm64 | ad-hoc | not set | YES | none |
| `Contents/Frameworks/libavfilter.10.dylib` | arm64 | ad-hoc | not set | YES | none |
| `Contents/Frameworks/libavformat.61.dylib` | arm64 | ad-hoc | not set | YES | none |
| `Contents/Frameworks/libavutil.59.dylib` | arm64 | ad-hoc | not set | YES | none |
| `Contents/Frameworks/libswresample.5.dylib` | arm64 | ad-hoc | not set | YES | none |
| `Contents/Frameworks/libswscale.8.dylib` | arm64 | ad-hoc | not set | YES | none |
| `Contents/Frameworks/libass.9.dylib` | arm64 | ad-hoc | not set | YES | none |
| `Contents/Frameworks/libplacebo.360.dylib` | arm64 | ad-hoc | not set | YES | none |
| `Contents/Frameworks/libbrotlicommon.1.dylib` | arm64 | ad-hoc | not set | YES | none |
| `Contents/Frameworks/libbrotlidec.1.dylib` | arm64 | ad-hoc | not set | YES | none |
| `Contents/Frameworks/libbz2.1.0.dylib` | arm64 | ad-hoc | not set | YES | none |
| `Contents/Frameworks/libc++.1.0.dylib` | arm64 | ad-hoc | not set | YES | none |
| `Contents/Frameworks/libc++abi.1.dylib` | arm64 | ad-hoc | not set | YES | none |
| `Contents/Frameworks/libfreetype.6.dylib` | arm64 | ad-hoc | not set | YES | none |
| `Contents/Frameworks/libfribidi.0.dylib` | arm64 | ad-hoc | not set | YES | none |
| `Contents/Frameworks/libharfbuzz.0.dylib` | arm64 | ad-hoc | not set | YES | none |
| `Contents/Frameworks/libiconv.2.dylib` | arm64 | ad-hoc | not set | YES | none |
| `Contents/Frameworks/libjpeg.8.dylib` | arm64 | ad-hoc | not set | YES | none |
| `Contents/Frameworks/liblcms2.2.dylib` | arm64 | ad-hoc | not set | YES | none |
| `Contents/Frameworks/liblzma.5.dylib` | arm64 | ad-hoc | not set | YES | none |
| `Contents/Frameworks/libpng16.16.dylib` | arm64 | ad-hoc | not set | YES | none |
| `Contents/Frameworks/libsqlite3.dylib` | arm64 | ad-hoc | not set | YES | none |
| `Contents/Frameworks/libz.1.dylib` | arm64 | ad-hoc | not set | YES | none |

## 5. Validation Results

| Validation | Result | Evidence |
| --- | --- | --- |
| Shell syntax | PASS | `bash -n` passed for packaging, verification and smoke scripts |
| Entitlement plist syntax | PASS | all three files passed `plutil -lint` |
| Missing Developer ID fail-closed | PASS | distribution mode stopped before build with exit 2 |
| Android Release bridge build | PASS | Gradle Release build completed |
| Xcode Release build | PASS | `** BUILD SUCCEEDED **` |
| Bundle functional verification | PASS | existing `verify-bundle.sh` passed |
| Strict signature | PASS | `codesign --verify --deep --strict --verbose=4` |
| Mach-O inventory | PASS | 28/28 signed, arm64-only, Runtime Flag present |
| Main App entitlement boundary | PASS | no JIT/unsigned-memory/get-task-allow; local-only LV exception present |
| Node entitlement boundary | PASS | allow-jit present; no LV/unsigned-memory/get-task-allow |
| QuickJS smoke | PASS | `QuickJS bridge smoke test passed (2025-09-13-2)` |
| MPV/FFmpeg initialization smoke | PASS | `OKMPVBridge smoke passed (client API 2.5, event size 64)` |
| Node/V8 smoke | PASS | exit 0; Node 22.23.0, V8 12.4; no SIGTRAP |
| Release App startup | PASS | process remained alive for 5 seconds, then test terminated it |
| macOS unit tests | PASS | complete `xcodebuild test` exited 0 |
| Developer ID signature | NOT TESTED | no valid signing identity in current keychain |
| Same-Team Library Validation | NOT TESTED | requires a real Developer ID identity |
| `spctl --assess` on local artifact | FAIL / expected | ad-hoc artifact returned Code Signing subsystem error |
| Notarization | NOT TESTED | notarization step not executed because credentials are unavailable |
| Staple / post-notary Gatekeeper | NOT TESTED | requires accepted notarization submission |

构建中存在既有 Swift Sendable、OpenGL deprecated 和 build-phase output warning；它们
不是本轮签名链失败，也没有通过修改业务代码掩盖。

## 6. Remaining Risks

### P1 — 真实 Developer ID 与 notarization 尚未执行

必须在有证书的环境执行：

```bash
export DEVELOPER_ID_APPLICATION='Developer ID Application: …'
export OKVIDEOMAC_NOTARY_PROFILE='okvideomac-notary'
Scripts/package-app.sh --mode distribution --notarize
```

该流程会要求 secure timestamp、同 Team ID、无 ad-hoc nested object、最小主 App
entitlement、Node-only JIT、notary 接受、staple 与 Gatekeeper 通过。正式执行前不能
宣称 Developer ID/Notarization 已完成。

### P1 — Node 远程代码能力边界

- A（当前代码能力）：主 App 启动 bundled Node 子进程，launcher 对下载后的
  `bundlePath` 执行 `require()`；Node 仍具有完整 `fs`、网络、native addon 与
  `child_process` 理论能力。代码还保留 `/opt/homebrew`、`/opt/local`、
  `/usr/local` 外部 Node 回退。
- B（当前内置样本）：预审计缓存样本未发现 `child_process`、`process.dlopen`、
  `execFile`、`spawnSync` 或 native addon；本轮仓库复查也未发现业务代码主动调用
  这些 Node API。
- C（远程脚本理论能力）：未来远程 bundle 可以尝试下载 `.node`、Mach-O/dylib，
  或启动子进程。当前没有 OS sandbox/permission model 阻止它。

本轮没有为安全而破坏 Spider 兼容性，也没有给 Node 增加 Library Validation 或
unsigned executable memory 例外。

### P1 — Android ADB/Emulator 供应链

- 运行时代码固定依赖 `/Volumes/XcodeDev/AndroidSDK` 与
  `/Volumes/XcodeDev/AndroidAVD`，不依赖普通 PATH，但不是可分发安装策略；
- 更高优先级的 compatibility ADB 位于用户可写的 Application Support，入口是未签名
  zsh wrapper，可被同一用户替换；
- wrapper 指向 `adb-macos14`。它声明 Google Team `EQHXZ8M8AV` 与 Runtime Flag，
  但 strict verify 报 `invalid signature (code or signature have been modified)`；
- SDK `platform-tools/adb` 与 `emulator/emulator` 也声明该 Team，但当前 strict verify
  同样失败；
- Android DEX/JNI/ELF 仍在 Emulator 子进程/guest 边界，不是主 App Library
  Validation 的理由。

风险等级维持 P1。本轮未重写 Android Bridge、SDK、DEX、JNI 或 Spider 行为。

### P2 — Helper 布局

Node 仍位于 `Contents/Resources/NodeRuntime/node`。验证脚本已经显式识别并验签，但
长期应迁移到 `Contents/Helpers` 或独立 XPC service，以形成更标准的 nested-code
与能力边界。

## 7. Recommended Phase 3

1. 在隔离的发布钥匙串中安装 Developer ID Application，执行一次完整
   distribution + notarize + staple + Gatekeeper 验收，并在干净账户/无开发工具机器
   复测 QuickJS、MPV、Node 与完整播放路径。
2. 给远程 Node bundle 建立发布方签名或 pinned SHA-256 信任链，评估
   `--no-addons`、Node permission model 与独立 XPC；明确禁止远程 native addon、
   Mach-O/dylib 下载执行和任意子进程。
3. 移除正式包中的外部 Node fallback，并把 Node 移入标准 Helpers/XPC 布局。
4. 为 ADB/Emulator 制定固定版本、来源、hash、签名验证和安装流程；停止优先执行
   用户可写且未签名的 wrapper。
5. 收窄 QuickJS `-force_load` 带入的 dormant libc loader/进程符号，或至少增加符号
   denylist 回归，防止未来向不可信 Spider 暴露 native loader。

只有第 1 项完成后，Final Status 才应从 `Ready with Remaining P1` 升级为 `Ready`。
