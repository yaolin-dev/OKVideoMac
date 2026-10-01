# OKVideoMac 0.8.0（Build 130）发布准备记录

日期：2026-10-01

## 基线与版本建议

比较范围是 `v0.7.3`（Build 129，`55ffa9d55faced404b20034d7cfe5bcfbc1be581`）
到当前完整工作区。包含标签之后已提交的 `5780acd` 与尚未提交的新文件；单独
`git diff HEAD` 或不含 untracked 的 diff 不足以覆盖本次 Release。

应用采用 **0.8.0（Build 130）**：新增部分 TVBox 配置/原生授权能力，同时修改
搜索、详情、播放器与运行时多个模块，适合 minor 更新；Build 从 129 递增一次。
Android Bridge 独立采用 **0.3.48（60）**，签名身份与依赖锁保持。
0.8.0 当前是发布候选，最近已公证公开下载仍为 0.7.3。

## 功能与模块对照

| 模块 | 本次审查重点 | 对应说明与验证 |
| --- | --- | --- |
| Android Bridge | 配置/普通详情分流、延迟/静默窗口、网页/表单代理作用域、原集授权最多重试一次、取消清理 | BridgeProtocolTest、TVBoxConfigurationTest；34 JVM 与 lint，本轮源码对照前序 96 项 instrumentation |
| macOS 配置交互 | 可取消准备、重复点击、切换卡片/分类/来源的旧回调、只回读仍可见原分类 | AppState、RootView、HomeView 及 App 回归 |
| Node / CatPaw | profile identity 与 cache revision、页面详情所有权、短期缓存与失效、全部选中站点搜索、定时发布末批 | DetailLoadingTests、App/Node 回归，缓存资源边界记入 PERFORMANCE |
| 播放器界面 | 视口布局、长时长/小窗口、时间预览/提示边界、鼠标与焦点清理、全屏独立控件 | PlayerInteractionTests、FullscreenCompositionTests、App 全量 |
| Seek 与结束流程 | mpv 事件归属、关键帧偏差、快速 Seek、确认片尾/提前断流、结束重播 | 真实长 GOP 用例与 EOF/队列回归 |
| 集数与历史续播 | 不同前缀、倒序、缺集、重复号、季/版本、音频/字幕/花絮、等待完整列表 | PlaybackResourceSemanticsTests、PlayerEpisodeContinuationTests；列表推断不升级持久身份 |
| 私有 Android Runtime | 进程 ownership 与 ADB binding、端口探测失败、原绑定停止、有界恢复、不启动 ADB 的诊断 | 已提交 5780acd；App 模拟生命周期和 AndroidRuntimeKit 全量 |
| 本地化与发布 | 中英文新状态、版本/Build/APK contract、文档、构建、源码/SBOM/哈希 | String Catalog、check-doc-status、Release 包门禁 |

用户可见的 0.7.3 前后行为、识别规则与限制见 [Release Notes](RELEASE_NOTES_0.8.0.md)。
实际执行结果与历史证据区分见 [发布就绪记录](RELEASE_READINESS_0.8.0.md)。
没有把 0.7.3 已发布的 Full Guide、弹幕、来源感知的历史/收藏、备份 v4 重复列为新增。

## Release 需要提交的文件

以下清单包含相对 v0.7.3 的已有文件变更与新增源码/测试/文档。已经包含在 5780acd
的文件只需提交当前未提交差异，保留该已有提交；不重复 cherry-pick 或重写历史。

### Android 配置、授权与测试

- `OKVideoMac/Helpers/AndroidDexBridge/README.md`
- `OKVideoMac/Helpers/AndroidDexBridge/app/build.gradle`
- `OKVideoMac/Helpers/AndroidDexBridge/app/src/androidTest/java/com/okvideomac/dexbridge/BridgeProtocolTest.java`
- 新增：`OKVideoMac/Helpers/AndroidDexBridge/app/src/androidTest/java/com/okvideomac/dexbridge/TVBoxConfigurationTest.java`
- `OKVideoMac/Helpers/AndroidDexBridge/app/src/main/java/com/okvideomac/dexbridge/BridgeActionActivity.java`
- `OKVideoMac/Helpers/AndroidDexBridge/app/src/main/java/com/okvideomac/dexbridge/BridgeActivity.java`
- 新增：`OKVideoMac/Helpers/AndroidDexBridge/app/src/main/java/com/okvideomac/dexbridge/BridgeConfigurationProxy.java`
- 新增：`OKVideoMac/Helpers/AndroidDexBridge/app/src/main/java/com/okvideomac/dexbridge/BridgeConfigurationWebView.java`
- `OKVideoMac/Helpers/AndroidDexBridge/app/src/main/java/com/okvideomac/dexbridge/BridgeDialogWindowTracker.java`
- `OKVideoMac/Helpers/AndroidDexBridge/app/src/main/java/com/okvideomac/dexbridge/BridgeInteractionRegistry.java`
- 新增：`OKVideoMac/Helpers/AndroidDexBridge/app/src/main/java/com/okvideomac/dexbridge/BridgePlaybackAuthorization.java`
- `OKVideoMac/Helpers/AndroidDexBridge/app/src/main/java/com/okvideomac/dexbridge/BridgeProviderOwnerRegistry.java`
- `OKVideoMac/Helpers/AndroidDexBridge/app/src/main/java/com/okvideomac/dexbridge/BridgeServer.java`
- `OKVideoMac/Helpers/AndroidDexBridge/app/src/main/java/com/okvideomac/dexbridge/DexSpiderRegistry.java`
- `OKVideoMac/Helpers/AndroidDexBridge/app/src/main/java/com/okvideomac/dexbridge/FongMiCompatProxyServer.java`
- 新增：`OKVideoMac/Helpers/AndroidDexBridge/app/src/main/java/com/okvideomac/dexbridge/TVBoxAuthorizationRoute.java`

### macOS 应用、运行时、播放器与测试

- `OKVideoMac/macOS/OKVideoMac/App/AppEnvironment.swift`
- `OKVideoMac/macOS/OKVideoMac/App/AppState.swift`
- `OKVideoMac/macOS/OKVideoMac/App/OKVideoMacApp.swift`
- `OKVideoMac/macOS/OKVideoMac/App/RootView.swift`
- `OKVideoMac/macOS/OKVideoMac/Engines/Spider/JavaScriptSpiderSiteProvider.swift`
- `OKVideoMac/macOS/OKVideoMac/Engines/Spider/NodeBundleRuntimeService.swift`
- `OKVideoMac/macOS/OKVideoMac/Engines/Spider/NodeHTTPSpiderSiteProvider.swift`
- `OKVideoMac/macOS/OKVideoMac/Features/Home/HomeView.swift`
- `OKVideoMac/macOS/OKVideoMac/Features/Player/PlayerView.swift`
- `OKVideoMac/macOS/OKVideoMac/Features/Search/SearchBrowseState.swift`
- `OKVideoMac/macOS/OKVideoMac/Packages/OKVideoKit/Sources/OKVideoCore/Player/PlayerClient.swift`
- `OKVideoMac/macOS/OKVideoMac/Packages/OKVideoKit/Sources/OKVideoCore/Site/PlaybackResourceSemantics.swift`
- `OKVideoMac/macOS/OKVideoMac/Packages/OKVideoKit/Tests/OKVideoCoreTests/PlaybackResourceSemanticsTests.swift`
- `OKVideoMac/macOS/OKVideoMac/Player/MPVPlayerClient.swift`
- `OKVideoMac/macOS/OKVideoMac/Player/MPVRenderView.swift`
- `OKVideoMac/macOS/OKVideoMac/Resources/Localizable.xcstrings`
- `OKVideoMac/macOS/OKVideoMac/Tests/DetailLoadingTests.swift`
- `OKVideoMac/macOS/OKVideoMac/Tests/FullscreenCompositionTests.swift`
- `OKVideoMac/macOS/OKVideoMac/Tests/OKVideoMacTests.swift`
- 新增：`OKVideoMac/macOS/OKVideoMac/Tests/PlayerInteractionTests.swift`

### 版本与构建元数据

- `OKVideoMac/THIRD_PARTY_NOTICES.md`
- `OKVideoMac/macOS/OKVideoMac/OKVideoMac.xcodeproj/project.pbxproj`
- `OKVideoMac/macOS/OKVideoMac/project.yml`
- `ThirdParty/native-lock.json`

### 项目与发布文档

- `CHANGELOG.md`
- `Docs/DMG_RELEASE_PROCESS.md`
- `Docs/RELEASE_NOTES_0.7.3.md`
- 新增：`Docs/RELEASE_NOTES_0.8.0.md`
- 新增：`Docs/RELEASE_PREPARATION_0.8.0.md`
- `Docs/RELEASE_READINESS_0.7.3.md`
- 新增：`Docs/RELEASE_READINESS_0.8.0.md`
- `Docs/SBOM_RELEASE_PROCESS.md`
- `Docs/SOURCE_RELEASE_PROCESS.md`
- `OKVideoMac/README.md`
- `OKVideoMac/macOS/OKVideoMac/Docs/ARCHITECTURE.md`
- `OKVideoMac/macOS/OKVideoMac/Docs/BUILDING.md`
- `OKVideoMac/macOS/OKVideoMac/Docs/COMPATIBILITY.md`
- `OKVideoMac/macOS/OKVideoMac/Docs/PERFORMANCE.md`
- `README.md`
- `README_zh-CN.md`

## Git 提交建议

这次 AppState、播放器队列与 Android 交互存在跨模块依赖。建议将实现、测试和版本文档
作为同一 Release 准备提交，便于在该完整状态重现验证。推荐标题：

```text
release: prepare OKVideoMac 0.8.0 (build 130)
```

提交正文可写：

```text
Add scoped TVBox configuration and native authorization interactions.
Improve CatPaw search/detail ownership and player controls, seek and continuation.
Include owned-emulator ADB recovery since v0.7.3; synchronize release metadata/docs.
Record full regression results and local Release validation; distribution pending.
```

如果评审需要拆分，先提交实现与回归测试，再提交版本/文档；Xcode project 同时包含
新测试登记与版本号，需要 `git add -p` 按 hunk 拆分。不要按模块整文件反复覆盖 AppState，
也不要把一个依赖尚未提交新类型的中间状态当成 release commit。

从仓库根目录检查并按上面的精确清单暂存；不要将本地源码快照、测试日志、私有配置、
凭据、DerivedData、构建 App/APK/DMG 或临时 XcodeGen 工具提交到源码仓库：

```sh
git status --short
git diff --check
git diff v0.7.3 --stat
git ls-files --others --exclude-standard
# git add -- <按清单核对的文件；新源码和测试也须暂存>
git diff --cached --check
git diff --cached --stat
# 复核暂存内容后：
git commit -m 'release: prepare OKVideoMac 0.8.0 (build 130)'
```

上述命令是提交建议，本次准备未自动创建 commit、推送或发布。

## 正式发布资产与顺序

目标 Tag：`v0.8.0`。建议 Release 标题：`OKVideoMac 0.8.0 (Build 130)`，正文使用
`Docs/RELEASE_NOTES_0.8.0.md`，完成后填写实际正式验证记录。

1. 复核上述实现/测试/文档并提交，以可审计 merge 或 fast-forward 进入 main。
2. 从最终干净 release commit 重新执行 `Scripts/package-app.sh --mode distribution --notarize`，
   使用已有 Developer ID 和专用临时 keychain 流程。完成签名、公证、Staple、Gatekeeper、
   DMG 安装及 QuickJS/MPV/Node/App smoke；本地 ad-hoc 包不直接作为正式资产。
3. 核对版本/Build/Bridge、对应源码、SBOM 与最终 DMG 的 manifest/哈希全部属于同一 commit。
4. 所有正式门禁通过后才创建 v0.8.0，并发布完整资产；内部 ZIP 不上传。

公开文件沿用 0.7.3 的 15 项结构：

```text
OKVideoMac-0.8.0.dmg
OKVideoMac-0.8.0.dmg.sha256
OKVideoMac-0.8.0-AndroidDexBridge-release.apk
OKVideoMac-0.8.0-build130-source.tar.gz
OKVideoMac-0.8.0-build130-third-party-source.tar.gz
OKVideoMac-0.8.0-build130-licenses.tar.gz
OKVideoMac-0.8.0-build130-SOURCE_RELEASE_INDEX.json
OKVideoMac-0.8.0-build130-SOURCE_RELEASE_MANIFEST.json
OKVideoMac-0.8.0-build130-SHA256SUMS
OKVideoMac-macOS.spdx.json
OKVideoMac-macOS.cdx.json
OKVideoMac-Android.spdx.json
OKVideoMac-Android.cdx.json
RELEASE_NOTES_0.8.0.md
THIRD_PARTY_NOTICES.md
```

生成和验证方式见 [DMG 流程](DMG_RELEASE_PROCESS.md)、
[对应源码流程](SOURCE_RELEASE_PROCESS.md)与 [SBOM 流程](SBOM_RELEASE_PROCESS.md)。
旧版本签名资产、Tag、原构建时源码与发布说明保持不可变；仓库中的历史状态更正不重写
GitHub Release 已发布资产。
