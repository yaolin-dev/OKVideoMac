# OKVideoMac 0.8.4（Build 137）正式发布验证记录

日期：2026-10-09。GitHub Release：[v0.8.4](https://github.com/yaolin-dev/OKVideoMac/releases/tag/v0.8.4)，非 Draft、非 Prerelease、latest。

## 不可变身份与修改

- exact release commit：`58e83d0aa29c7a7ffa9a00b15011875678395481`；从干净 main 经现有 `package-app.sh --mode distribution --notarize` 重新构建，annotated tag `v0.8.4` 固定同一提交。
- 生产修复提交：`af00614d622fc9cde89bdba21e707a8ef070813c`；移除 `window.toolbar` KVO 同步回写，让 SwiftUI 独占浏览窗口工具栏管理，首页加载/无配置状态提供真实标题。
- 保留侧栏附件生命周期、左右独立材质、零宽分隔、原生搜索与主题同步；View 层分支保持 macOS 12 API 兼容。
- App 0.8.4（137）；Android Bridge 0.3.48（60）；原生依赖未升级。商业工作树未修改。
- 构建时 source index 实际记录 arm64、最低 macOS 12.0、Xcode 16.2 / SDK 15.2。构建主机 macOS 14.8.9。
- 分支候选作为历史证据保留；正式 App、DMG、源码和 SBOM 全部重新生成。发布后文档不会移动 tag、修改或重签已发布资产。

## 测试与实机反馈

| 项目 | 本轮结果 |
| --- | --- |
| main Release 测试构建 | 通过 |
| App 定向 XCTest | 48 通过、0 失败、0 跳过 |
| 覆盖 | 真实 WindowGroup 启动/菜单切换/新建窗口、空态/有效/损坏配置恢复、搜索工具栏归属、附件移窗/唯一性/收放、主题/材质/边界/提示、键盘归属、详情及全屏恢复 |
| Android Bridge Release | 现有 assembleRelease 流程通过，版本不变；未重新执行历史 JVM 全套测试 |
| 盘内与安装副本 smoke | QuickJS、MPV/FFmpeg、Node/V8 Hardened Runtime 及 App 启动通过 |
| 正式 App 延长启动 | 隔离数据库三轮 60/15/15 秒持续运行，无工具栏异常/提前退出；测试进程按脚本 SIGTERM 结束，不将该步骤记为正常 AppKit 退出 |
| macOS 27.0.1 | 用户于 2026-10-09 确认“实机测试过了，没问题”；未提供逐项日志，记录为用户实机反馈 |
| 公开资产 | 16 项本地 SHA-256、GitHub digest、匿名下载逐项一致 |

本轮没有把 0.8.3 的完整 App/Kit/Android 测试数字当作重跑结果。候选曾执行正常退出验证；正式延长启动记录与候选证据分别保留。GitHub Draft 初次按 Tag 查询返回 404，随后通过 Release 列表确认唯一 Draft 身份，改按其 Release ID 校验资产后继续；未重复创建或提前公开。

首次文档检查发现发布准备措辞不符合既有元数据标签，已修正文档标签并复验通过；检查脚本未放宽。正式 package-app.sh 已完成 main 构建、签名、Apple Accepted、staple 和 Gatekeeper，首次在生成 appcast 时因配置引用的临时 Sparkle 归档已清理而停止。恢复官方锁定 2.10.0 归档并核验 SHA-256 后，使用原有 create_update_feed.py、create-source-release.sh、敏感信息扫描和 App materialization 步骤完成收尾，全部复验通过；未改门禁、未改已 Accepted 的 DMG 字节，失败日志保留。

测试日志的 SwiftUI “Publishing changes from within view updates” 警告在 0.8.3 同类侧栏测试中已存在，本轮新覆盖也能触发；未将警告或条件跳过当作通过。没有测试失败项遗留。

## 签名、公证和最终产物

- Developer ID Application: Yao Lin (KGG363ABK9)；34 个 Mach-O 的 inventory、arm64、secure timestamp、Hardened Runtime、entitlements、动态依赖闭包和 codesign deep/strict 验证通过。
- Apple Notarization **Accepted**，submission `3ac3de16-0c86-4166-b8bf-b81b4c9fa61e`；新提交独立核验，Apple log 无 issues。
- 最终 DMG staple、stapler validate、codesign、Gatekeeper 通过；只读挂载确认两项布局、App 版本/Build、source index、APK 和 bundle/SBOM。
- 从最终 DMG 复制安装 App，比较文件字节/链接/可执行位后单独 staple，重新验证签名及 Gatekeeper；DMG SHA-256 保持不变。桌面入口已更新到验证过的正式 Release。
- 稳定 feed / 公钥与 0.8.3 一致，Build 137 高于 136；appcast 的固定 DMG URL、长度与 EdDSA 匹配。公开 latest feed 字节和签名通过，匿名下载 DMG 再次通过 staple/Gatekeeper/布局验证。
- 既有敏感信息扫描和对应源码、许可证、APK、四份 SBOM、index/manifest/checksums 绑定检查通过。ZIP 保持内部身份载体，不上传。
- 沿用既有安全时间戳策略，先做 Developer ID 探针，再仅为 `timestamp.apple.com` 临时加入代理旁路；打包和安装验证完成后均原样恢复原列表。未关闭安全校验或改变公证门禁。公证等待期间 Apple history 确认新提交为 In Progress，最终取得 Accepted。

## 公开文件 SHA-256

| 文件 | SHA-256 |
| --- | --- |
| `OKVideoMac-0.8.4-AndroidDexBridge-release.apk` | `19fdb27d8f800479a8e430842bdf464a702579c2b0eec69e1d73ac768c29d112` |
| `OKVideoMac-0.8.4-build137-SHA256SUMS` | `bae435f32f2a8b65f7079f9ff16794554e9272641fab082336496d57cfc40383` |
| `OKVideoMac-0.8.4-build137-SOURCE_RELEASE_INDEX.json` | `793a1cc04e0063fe6327d4d062a60a06a21d8979a18938304f6897674414e8e3` |
| `OKVideoMac-0.8.4-build137-SOURCE_RELEASE_MANIFEST.json` | `3f8616dae3a2aee633629db85513a10c710d36b1cde53de15381ad95d7c15efe` |
| `OKVideoMac-0.8.4-build137-licenses.tar.gz` | `df3bf684fbf0a4c71111b6c8173dd9c8be921e695f28d78d23bc0289c232627b` |
| `OKVideoMac-0.8.4-build137-source.tar.gz` | `02a319295e5b44e83facf8573adc6940838f2408141a4c6443de5351cc9ff169` |
| `OKVideoMac-0.8.4-build137-third-party-source.tar.gz` | `bf5e870d8dee7afc568313fa73a43e55dde21a05d458451324fab5db8b6eeee5` |
| `OKVideoMac-0.8.4.dmg` | `7cfc00634a4d2159f5ed8342d02fbdf19fa6ebb06be16fbe08c81ea082d184c9` |
| `OKVideoMac-0.8.4.dmg.sha256` | `626df7e8a7baca3794e65698ef2829656099a48cd2054daf8e19af9587de4eeb` |
| `OKVideoMac-Android.cdx.json` | `51fae555283e66261cc191a4977778972fc897daf02dac2512df01fbbcb98769` |
| `OKVideoMac-Android.spdx.json` | `ea2b29557cee9f079ad4e38e9cbe6b288d697124439aeaef746781b5d9bd4cb0` |
| `OKVideoMac-macOS.cdx.json` | `53183ce44249b0f3e6d67cabec7b28fa008f9ba1e51d1f0520f649808d4e85c4` |
| `OKVideoMac-macOS.spdx.json` | `e180951edbe49b6e56191755d45c3ebddb12fb12d46f139efa296cf17b176e59` |
| `RELEASE_NOTES_0.8.4.md` | `35d9306183d0e2be45dfb9f12ca027973c064ee5b419e9f6c07b3d366de223c4` |
| `THIRD_PARTY_NOTICES.md` | `6058f7104e4d539c0aeec20aa08bc0a14b991fe9ac1dce8fc86a063558d8b444` |
| `appcast.xml` | `e4181a3b89dba552a91a6c9b06d647c8956e571e7cb28671e6d2fda69b68958b` |

## 文档和覆盖边界

README 英文/中文、应用 README、CHANGELOG、发布说明、就绪与本验证记录、DMG/源码流程、自动更新、兼容性和性能文档已同步。GitHub 构建时发布说明及对应源码快照保留原字节。

- 原报告证明 App 启动崩溃，未证明整台 Mac 重启；本轮修复工具栏管理路径，用户确认受影响系统正常。
- 未新增 macOS 12 实机测试、完整第三方源/云盘/真实蓝牙矩阵、24 小时更新周期或更新安装端到端测试，也没有新增性能保证。
- 既有 Swift/SwiftUI 及 Android 构建诊断保留，测试警告未作无关重构；原始 zlib 归档和历史 MacPorts clang 输入等 native provenance 例外继续记录，未宣称完全可复现。
- 本机 HTTP 代理的 Apple 时间戳响应问题仍需使用完整响应的网络路径；代理软件未修改，临时系统旁路已恢复。
- 无已知阻塞本次正式发布的问题。
