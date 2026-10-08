# OKVideoMac 0.8.1（Build 134）正式发布验证记录

日期：2026-10-08

GitHub Release：[v0.8.1](https://github.com/yaolin-dev/OKVideoMac/releases/tag/v0.8.1)

## 不可变发布身份

- exact release commit：`4b18f10134a88a6b7d66e6f8e293fdbd01da86f2`，干净 `main` 构建；annotated tag `v0.8.1` 固定同一提交。
- App：0.8.1（Build 134）；Android Dex Bridge：0.3.48（60），未升级。
- Developer ID：`Developer ID Application: Yao Lin (KGG363ABK9)`。
- 证书 SHA-256：`9f91435785a01a77a1db1d968ef542723fda1bb8a1a864b5bbf74c500ac5810d`，与 0.8.0 正式签名身份一致。
- Apple notarization：`Accepted` / `Ready for distribution`，无 issues；Submission：`fad950f0-a03f-465a-812a-d4f232d635f5`。
- 最终 DMG SHA-256：`cd03a46b6f9a6e5bb75c70478e530c4713989f8fd0d9b46c1d80657a563a6922`。

本轮实现、测试、版本及构建文档在上述发布提交内。发布后补录公开状态的文档提交不移动 tag，不重签或改写 DMG、签名 appcast、发布资产和构建时对应源码/说明快照。

## 本轮修改

- 实际旧 mpv 源码、构建输入及二进制缺少 #18383 两项修复。原样回移 `af067b5ea8e5fe396ebd9d3f895e51a7e75b3c09` 与 `c5d391adba7bd024954d0df1e0405f5749f4d4ca`，并保留故障测试证明必要的失败 AudioUnit/部分监听注册清理。修复初始化失败后 hotplug 回调访问已释放 ao/log；没有重新设计 CoreAudio 或改动 Swift 播放器生命周期。
- Sparkle 2.10.0：授权后每日自动检查、菜单与设置手动检查；下载和安装需确认。启动、播放、全屏和模态交互期间延后自动提示；安装与普通语言切换重启互斥，等待实际异步清理。
- 分集导航以当前相邻集的唯一性判断可用性，其他集重复上传不再禁用整条线路；相邻集有歧义时手动选择，自动连播不任意挑选。
- 正式构建拒绝测试更新源；签名 appcast 绑定最终公证 DMG；34 个 Mach-O 按批准的精确路径集合核验，未知可执行文件仍失败。

## 自动回归及覆盖边界

| 门禁 | 本次实际结果 |
| --- | --- |
| Release App XCTest | 1,234 项：1,218 通过、16 条件跳过、0 失败 |
| OKVideoKit | 1,036 项：1,014 通过、22 条件跳过、0 失败 |
| AndroidRuntimeKit | 57 项：56 通过、1 在线安装跳过、0 失败 |
| 长 GOP 原生播放/暂停/连续 Seek/片尾 | 2 项定向回归实际运行通过，无跳过 |
| 跨进程音量持久化 | writer/reader 独立进程各 1 项通过 |
| Node / CatPaw / Quark | 47 项通过 |
| Android Bridge | 正式签名 APK 构建、34 JVM 测试通过；lint 0 error、8 warnings |
| SourceAudit | 32 项全部通过，包括独立 launcher 的 7 项和稳定更新源/appcast 门禁 |
| 实际 CoreAudio 源码故障注入 | ASan/UBSan 3,200 场景通过，残留 AudioUnit/监听器均为 0 |
| 最终 DMG libmpv | 280 轮：60 播放/暂停/继续/seek/换片/销毁、200 枚举/创建/销毁、20 无效设备初始化失败 |
| 最终 DMG libmpv 泄漏检查 | 另行 280 轮，`leaks` 明确报告 0 leaks / 0 total leaked bytes；线程 7 → 7 |
| Hardened Runtime smoke | 最终 DMG 与全新安装副本的 QuickJS、MPV/FFmpeg、Node/V8、App 5 秒启动通过 |
| 文档及来源 | 版本/Build、32 个修改脚本或元数据的语法、来源与许可证、敏感信息扫描通过 |

首次 App 全量运行的 4 项失败来自 3 个证据输出目录未创建及测试宿主缺少签名 APK；补齐现有前置条件后完整重跑通过，未降低断言或排除这些用例。Android 首次 lint 缺少 SDK 环境，使用现有 SDK/JDK 配置重跑通过。原始失败记录保留。

条件跳过不计通过：真实提供方/公网/Runtime、专用 EPG 与窗口渲染等测试仍受环境限制。长 GOP 和跨进程音量用例按既有 opt-in 入口另行实际执行。此前 8 个真实 Sparkle 安装场景与 Build 133 分集演练为历史证据，不计为 Build 134 重跑。Android 既有 Kotlin metadata 诊断及 lint warnings 未屏蔽。

正常最终 DMG 运行 RSS 55.77 → 78.46 MB，线程 7 → 7；单独泄漏诊断 RSS 61.59 → 83.64 MB，线程 7 → 7。第一次 Hardened Runtime helper 的 leaks 输出缺少明确汇总，未仅凭退出码计通过；另行对诊断 helper 签名后执行并核对明确零泄漏汇总，发布 App/库未改签。短时检查不能替代长期播放和 Instruments 验收。

## 签名、公证、更新清单与安装

从干净发布提交执行 `package-app.sh --mode distribution --notarize`，全部通过：

- Release / arm64 / macOS 12.0；34 个嵌套 Mach-O 的 Developer ID、secure timestamp、Hardened Runtime、entitlements、动态依赖闭包和精确 inventory 校验。
- 四份 SPDX/CycloneDX SBOM、170 个 Maven module、APK/source index identity、对应源码/许可证归档、manifest/checksums 和敏感信息扫描。
- 最终 UDZO DMG 只含 App 与 `Applications -> /Applications`；只读挂载身份、签名和内嵌来源索引核验。
- 本次 Apple `Accepted`、DMG Staple/stapler validate、DMG 与盘内 App 的 Gatekeeper `Notarized Developer ID`。
- 固定的官方 Sparkle 工具生成并验证 signed appcast 和 EdDSA DMG 签名；生成前后最终 DMG 哈希相同。Keychain 保存更新私钥，未导出或提交。
- 稳定更新源：`https://github.com/yaolin-dev/OKVideoMac/releases/latest/download/appcast.xml`；enclosure 固定 `v0.8.1/OKVideoMac-0.8.1.dmg`。
- 从最终 DMG 复制全新安装副本，文件/符号链接清单与 DMG 和已打包 App 一致；安装签名、Gatekeeper、Hardened Runtime 启动验证通过。
- 桌面入口指向 `~/Applications/OKVideoMac-Release081-build134/OKVideoMac.app`；旧本地 App 保留。
- 实际最终 DMG runtime 加载包内 `Contents/Frameworks/libmpv.dylib`；UUID `342C8BC5-C6E1-374D-A04E-9AE9BEDE7800`。安装副本同库字节一致。

Apple 预检曾因团队协议返回 HTTP 403。用户本人完成协议后，复用原 Developer ID 和 `OKVideoMac-Notary` 获得本次 Accepted；未更换公证凭据或导入证书。Sparkle 签名工具的系统 Keychain 授权由用户完成；私钥未进入仓库、日志或发布包。

## GitHub 发布与公开资产

`main` 与 annotated `v0.8.1` 推送成功。Release 标题 `OKVideoMac 0.8.1 (Build 134)`，非 Draft、非 Prerelease，设为 latest。公开 16 个文件，内部 ZIP 不上传；外层源校验清单保留其内部身份载体哈希。

16 个资产与本地 SHA-256、GitHub 服务端 digest 及独立下载字节全部一致；公开 latest appcast 和固定 DMG URL 另行下载、哈希及签名核验通过。公开下载 DMG 的 stapler/Gatekeeper 再次通过。命令行初次未沿用 macOS 已启用的 HTTPS 代理而直连超时；复用用户现有本机代理后匿名 URL 与下载回验通过，未更改系统网络设置。

| 资产 | SHA-256 |
| --- | --- |
| `OKVideoMac-0.8.1-AndroidDexBridge-release.apk` | `19fdb27d8f800479a8e430842bdf464a702579c2b0eec69e1d73ac768c29d112` |
| `OKVideoMac-0.8.1-build134-SHA256SUMS` | `0712ab0b503267f7a280f50326246c321f7a08dd61066080eec230669046446a` |
| `OKVideoMac-0.8.1-build134-SOURCE_RELEASE_INDEX.json` | `2532e752dc3eff3600280d160f7f1606156ec3a2f99c87f93b7db699fc6fc860` |
| `OKVideoMac-0.8.1-build134-SOURCE_RELEASE_MANIFEST.json` | `8b5d2779bc47c50d2d406bce0cdb59774d2081543b8f0602bdbfce4ba43930c0` |
| `OKVideoMac-0.8.1-build134-licenses.tar.gz` | `8017eef0f62c91cd6fb5317f052fdb4b3d2cf7a5defe1b291a158e67b225452c` |
| `OKVideoMac-0.8.1-build134-source.tar.gz` | `5892b62bca155b0bcd744ed82d524afabfb08fde37bc886e0a725a22b6b19879` |
| `OKVideoMac-0.8.1-build134-third-party-source.tar.gz` | `465616e03813f8f32d99af73c5ff01ef8a203962100cb0ca7d3e008364e2db6b` |
| `OKVideoMac-0.8.1.dmg` | `cd03a46b6f9a6e5bb75c70478e530c4713989f8fd0d9b46c1d80657a563a6922` |
| `OKVideoMac-0.8.1.dmg.sha256` | `d240f11d36dbda368adeeed0466496c272719f43d65591fe97c3a82d08c6b308` |
| `OKVideoMac-Android.cdx.json` | `7ee88b028b48d4fe09269ab4efc7fcec544490227635cd1f6deb5c1a756977bb` |
| `OKVideoMac-Android.spdx.json` | `8fcdd4cd322725ead908b01bfdcbc62fa242c2daac88e2e24698222ad1e68a9e` |
| `OKVideoMac-macOS.cdx.json` | `8ba918fc546c29df96f5bb8c65918f962ab131f066564978f9058cee649eec0f` |
| `OKVideoMac-macOS.spdx.json` | `b05d3d7c4481857acb7556cdc2083dfe0c52b63520853c7b22d07b8f5e9ce9f2` |
| `RELEASE_NOTES_0.8.1.md` | `77107d86067a8c8d43e1aad6b6eb3d89d0cc0c63f27525bf1ce99cc701c60eb9` |
| `THIRD_PARTY_NOTICES.md` | `75ec6d8578fcef9da385bffbfc0bef695965d6a49858e988a32c35846e4b8c47` |
| `appcast.xml` | `283700059b0cf407b15064585596942427d77185722807409f5d15cbd5635b24` |

README 英文/中文、应用 README、CHANGELOG、发布/源码/SBOM 流程、就绪与正式验证记录更新到本版；历史记录保持其原版本身份。发布说明与自动更新链接均指向相应版本文档，远端 main 和 Release 链接已核验。

## 已知限制

- 用户已反馈蓝牙耳机测试正常，本轮没有逐项重新执行真实硬件验证。**NOT_TESTED**：AirPods 连接、摘下/断开 AirPods、蓝牙设备重连、系统输出设备切换、人工听音。
- 仅 Apple Silicon / arm64、macOS 12.0+。真实设备/提供方矩阵和自动更新端到端覆盖保留上述实际范围。
- 0.8.0 没有本版更新功能；本地测试源版本也不能自动转入稳定源，需手动安装 0.8.1 后使用稳定更新通道。
- 原始 zlib distfile、历史 clang 输入等 native provenance 例外继续明确记录，不能宣称全部第三方输入完全可复现。
- 无已知正式发布阻塞问题；条件跳过、8 个 Android lint warnings 和硬件验收边界不隐去。

## English verification summary

OKVideoMac 0.8.1 (Build 134) is pinned by v0.8.1 to the clean release commit above. Developer ID, Hardened Runtime, Accepted notarization, stapling, Gatekeeper, exact 34-executable inventory, source/SBOM checks, final DMG and fresh-installation smoke passed. All 16 public assets match local hashes, GitHub digests and downloaded bytes. The signed stable feed binds the immutable DMG. README and related links reflect the published release without changing tagged source or signed assets. Conditional skips and real hardware limits remain explicit.
