# OKVideoMac 0.7.3（Build 129）正式发布验证记录

日期：2026-09-27

GitHub Release：[v0.7.3](https://github.com/yaolin-dev/OKVideoMac/releases/tag/v0.7.3)

## 不可变发布身份

- exact release commit：`55ffa9d55faced404b20034d7cfe5bcfbc1be581`
- annotated tag：`v0.7.3`，peeled commit 与上述提交一致
- 构建版本：0.7.3（Build 129）
- Android Dex Bridge：0.3.45（57）
- Developer ID：`Developer ID Application: Yao Lin (KGG363ABK9)`
- Apple notarization：`Accepted` / `Ready for distribution`
- Submission ID：`133c1043-d3b8-429a-b502-6dc586de6ab9`

Tag 在所有正式分发门禁通过后创建，固定上述提交。本文是发布后的文档收尾；后续
文档提交不会移动 Tag、重签二进制或改写构建时嵌入的源码及 Release Notes 快照。

## 发布前测试与静态检查

| 门禁 | 最终结果 |
| --- | --- |
| Git diff / 文档与版本 / plist / JSON / Shell / XcodeGen 一致性 | 通过 |
| Node / CatPaw / Quark | 47 通过，0 失败 |
| SourceAudit | 17 通过，7 条件跳过，0 失败 |
| AndroidRuntimeKit | 56 通过，1 在线安装门禁跳过，0 失败 |
| OKVideoKit | 1007 通过，22 性能/网络实验跳过，0 失败 |
| macOS App repeatable full suite | 1143 通过，11 条件跳过，0 失败；另有 3 项专项回归和两个独立进程音频状态用例通过 |
| Android Dex Bridge | 34 JVM 测试通过；lint、`assembleRelease` 和 APK 签名通过 |
| 真实终止路径专项 | App termination 清理用例通过 |

SourceAudit 的 7 项、AndroidRuntimeKit 的 1 项、OKVideoKit 的 22 项及 App 的 11 项
均是显式条件门禁，不计为通过。四项需要真实 Emulator 生命周期的 App 用例仍保持
opt-in；本轮没有把历史设备结果冒充为重跑结果。AGP 8.7.3 lint 对 OkHttp 5.1.0
所用 Kotlin 2.2 metadata 输出 6 条非阻塞分析器兼容性 warning，最终为 0 error；
发布没有屏蔽或降级这些诊断。

## 正式分发验证

`package-app.sh --mode distribution --notarize` 从干净的 exact release commit 完整
重跑并通过：

- Release / arm64 / macOS 12.0 构建成功；29 个 Mach-O 均为 arm64。
- App、全部嵌套代码和 DMG 使用同一 Team 的 Developer ID 签名，secure timestamp、
  Hardened Runtime、entitlements、deployment target 和动态依赖闭包通过。
- 生成四份 SPDX/CycloneDX SBOM；macOS 记录 29 个 Mach-O，Android 记录 170 个
  Maven module；敏感信息扫描通过。
- Apple notarization 返回 `Accepted`，日志为 `Ready for distribution` 且无 issues。
- DMG Staple、`stapler validate`、DMG/盘内 App Gatekeeper 均通过，结果为
  `Notarized Developer ID`。
- 最终 DMG 只包含 `OKVideoMac.app` 与 `Applications` 链接；版本、Build、签名、
  嵌入 source index 与 APK identity 全部通过只读挂载复核。
- 从最终 DMG 复制到全新的安装目录后，deep codesign、Gatekeeper、QuickJS、
  MPV/FFmpeg、Node/V8 JIT 和 App 连续运行 smoke 通过。

第一次运行 runtime smoke 时使用了完全隔离的 `HOME`，因此系统 Keychain 中的签名
身份不可见，临时 smoke helper 无法签名。改为保留真实 `HOME`、仅隔离 App 数据目录后
相同 DMG 全部通过；这是测试环境设置问题，不是产品或发布资产失败。

通过验证的公证 App 已安装到
`~/Applications/OKVideoMac-Local/release129-55ffa9d-notarized/OKVideoMac.app`，并由
`~/Desktop/OKVideoMac.app` 指向该副本。安装副本与 DMG smoke 副本的主二进制一致，
版本、签名和 Gatekeeper 复核通过。

## 发布资产与哈希

GitHub Release 共发布 15 个公开资产。内部
`OKVideoMac-0.7.3-macOS-arm64.zip` 继续作为 binary identity/archive carrier，未作为
公开下载上传。GitHub Release 元数据为非 Draft、非 Prerelease，并已成为 latest；
远端 `main` 和 `v0.7.3^{}` 在发布时均指向 exact release commit。公开资产从 GitHub
返回的 15 项服务端 SHA-256 digest 均与本地已验证发布输入逐文件一致。额外下载复核
完成了全部小文件和项目源码归档；其余大文件的重复下载受发布后的瞬时网络中断影响，
不作为替代服务端 digest、上传前统一 `SHA256SUMS` 和本地正式产物校验的发布门禁。

| 资产 | SHA-256 |
| --- | --- |
| `OKVideoMac-0.7.3.dmg` | `9cf6c79f9c6d4a8bc7e37e72612e3debc98ca22ffffc3e5e9084c61efe42dbfc` |
| `OKVideoMac-0.7.3-AndroidDexBridge-release.apk` | `f6531ad60ec6d1d487d374d3045fa907c7b40c86d625fe281e61e001ce72e57a` |
| `OKVideoMac-0.7.3-build129-source.tar.gz` | `be220c995638e51816de857cacfe543d4339df1ae0d57e4d8b862c2161bfd25b` |
| `OKVideoMac-0.7.3-build129-third-party-source.tar.gz` | `54b3030e542f9bf4599a635f3a070ad23367746f8b63304bd5091efcd808b277` |
| `OKVideoMac-0.7.3-build129-licenses.tar.gz` | `96ff41dd6ca596a6e110a76197c5307395a37ed4ec94af2f0d580b54e81bb757` |
| `OKVideoMac-0.7.3-build129-SOURCE_RELEASE_MANIFEST.json` | `a94e8353a90e8c0369490c76d15b34fade0dd284a92f502efcba98fc125e6d16` |
| `OKVideoMac-0.7.3-build129-SHA256SUMS` | `61987d32cb2ae988ddc5c58851ef0003974e7813314628cb1ca6d3973bee8d3e` |

统一 `SHA256SUMS`、source index、manifest、四份 SBOM、许可证、第三方声明和发布说明
均随 Release 提供。Source index 与 manifest 都记录 exact release commit；构建目录内
全部统一哈希校验通过。

## 已知限制

- 只支持 Apple Silicon（`arm64`）与 macOS 12.0 或更高版本。
- Native Xtream catch-up/timeshift 与 `direct_source`、TVBox/FongMi 顶层 `lives`、
  parser type 2/3/4 和 DRM 不受支持。
- QuickJS、Node、Java/Dex、网页嗅探、网盘及弹幕服务只覆盖已实现子集，仍受上游变化影响。
- Managed Android Runtime 的真实 Emulator/Bridge/Dex E2E 证据仍只覆盖 Apple M1 /
  macOS 14.8.8；其他受支持 macOS 版本的 App 构建兼容不等于 Runtime 实机矩阵。
- 性能文档列出的多显示器、不同刷新率、长时播放和 Instruments 对照仍是后续性能验收项。

没有已知发布阻塞问题。

---

## English verification summary

OKVideoMac 0.7.3 (Build 129) was built from clean commit
`55ffa9d55faced404b20034d7cfe5bcfbc1be581`, pinned by `v0.7.3`. The 29 arm64
Mach-O files and final DMG were signed with Developer ID Application: Yao Lin
(KGG363ABK9). Apple notarization was accepted under submission
`133c1043-d3b8-429a-b502-6dc586de6ab9`; stapling, Gatekeeper and a fresh DMG
installation smoke passed. The final DMG SHA-256 is
`9cf6c79f9c6d4a8bc7e37e72612e3debc98ca22ffffc3e5e9084c61efe42dbfc`.
The GitHub Release publishes 15 public assets with corresponding source, SBOMs,
manifests, notices and checksums; the internal ZIP remains unpublished.
