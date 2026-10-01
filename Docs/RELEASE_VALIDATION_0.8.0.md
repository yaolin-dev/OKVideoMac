# OKVideoMac 0.8.0（Build 130）正式发布验证记录

日期：2026-10-01

GitHub Release：[v0.8.0](https://github.com/yaolin-dev/OKVideoMac/releases/tag/v0.8.0)

## 不可变发布身份

- exact release commit：`b049b381db52b5bbbeec9cf58bf54a5bd50a4f39`，干净 `main` 构建。
- annotated tag：`v0.8.0`，peeled commit 与上述提交一致。
- App：0.8.0（Build 130）；Android Dex Bridge：0.3.48（60）。
- Developer ID：`Developer ID Application: Yao Lin (KGG363ABK9)`。
- 证书 SHA-256：`9f91435785a01a77a1db1d968ef542723fda1bb8a1a864b5bbf74c500ac5810d`，
  与独立下载并核验的 0.7.3 正式 DMG 证书一致。
- Apple notarization：`Accepted` / `Ready for distribution`；Submission：`bc1f6ef5-5d19-4888-91f9-dbf5737d865d`。
- 最终 DMG SHA-256：`f082a380ffb1d2d059f228e0b6f0d7b59424f80edff57e81230d2efe6496b97a`。

实现、测试和版本文档在 `d46422b` 提交；`b049b38` 合入远端 0.7.3 发布后文档收尾，
保留旧验证记录。正式 main 的 360 个实现、测试和工程输入与最终本地验收快照逐文件一致。
所有正式门禁通过后才创建 tag；发布后文档补录不移动 tag、不重写历史、不重签资产。
构建时的 Release Notes、source index 和对应源码继续保留该 exact commit 的快照。

## 自动回归与覆盖边界

| 门禁 | 实际结果 |
| --- | --- |
| macOS 可重复全量套件 | 1,211 项：1,199 通过、12 条件跳过、0 失败；4 项真实 Emulator opt-in 单独排除 |
| libmpv 长 GOP 真实媒体 | 单独 1 项通过，覆盖暂停/连续 Seek、旧事件/超时与片尾 EOF |
| OKVideoKit | 1,036 项：1,014 通过、22 条件跳过、0 失败 |
| AndroidRuntimeKit | 57 项：56 通过、1 在线安装跳过、0 失败 |
| Node / CatPaw / Quark | 47 通过、0 失败 |
| SourceAudit | 合并后重跑 24 项：17 通过、7 条件跳过、0 失败 |
| Android Bridge | 34 JVM 测试通过；lint 0 error、9 warning；正式 assembleRelease/APK 签名通过 |
| 文档/元数据/工程 | 版本、Build、JSON/plist、Shell、XcodeGen 2.38.0、whitespace、本地文档链接通过 |

App/Core/Runtime/Node/JVM 结果来自本轮发布准备，正式构建使用相同已核验输入。
SourceAudit 在合并后再次执行。条件跳过不计为通过；真实长 GOP 用例另行显式执行。
API 35 instrumentation 的前序 96 项和配置 20 项结果仅作为同轮冻结源码证据，发布时
没有再启动模拟器。保留前序一次 10 秒 HTTP SocketTimeout 与随后未改源码重跑通过的记录。
AGP 8.7.3 与 OkHttp/Kotlin metadata 的既有诊断和 9 条 lint warning 没有屏蔽。
确定性授权回归不代表真实账号已完成登录并取得媒体。
详细模块对照、测试来源与限制见 [就绪记录](RELEASE_READINESS_0.8.0.md)。

## 正式分发与全新安装

从上述干净提交执行 `package-app.sh --mode distribution --notarize`，完整通过：

- Release / arm64 / macOS 12.0 构建，29 个 Mach-O，全部嵌套签名、secure timestamp、
  Hardened Runtime、entitlements、动态依赖闭包与 bundle 验证。
- 四份 SPDX/CycloneDX SBOM 记录 29 个 Mach-O 和 170 个 Maven module；
  APK、source index、对应源码归档、manifest、统一 SHA256SUMS 和敏感信息扫描通过。
- 最终 UDZO DMG 只含 `OKVideoMac.app` 与 `Applications -> /Applications`；
  只读挂载核对版本/Build、签名、source index 和 APK identity 通过。
- Apple notarization `Accepted`，日志 `Ready for distribution`、无 issues；
  DMG Staple、stapler validate、DMG 与盘内 App Gatekeeper 通过。
- 从最终 DMG 复制到全新安装目录后，bundle/deep codesign、Gatekeeper、QuickJS、
  MPV/FFmpeg、Node/V8 JIT 与 App 启动 smoke 通过。smoke 使用隔离应用数据目录，
  保留原用户 HOME 和签名环境，不使用或改写现有播放数据。
- 通过核验的正式 App 安装到新的用户 Applications 目录，桌面入口指向该副本；
  安装副本与 DMG 内容逐文件一致，原本地验收版本保留用于回退。

首次签名身份检查在工具沙箱内返回 0 个身份；旧 0.7.3 发布日志记录了同类假阴性。
在获准的宿主上下文复核后，现有身份、公证 profile 和签名预检均通过，无需密码输入。
本轮没有导入证书、新建凭据、改变默认钥匙串或 search list；未将环境检查结果误记为
产品或公证失败。

## GitHub 发布与公开资产

Release 标题为 `OKVideoMac 0.8.0 (Build 130)`，非 Draft、非 Prerelease，设置为 latest。
公开资产共 15 个，以下 SHA-256 与本地发布输入、GitHub 服务端 digest 逐文件一致；
15 个资产另行从 GitHub 下载后全部通过本地哈希复核。内部 ZIP 不上传。

| 资产 | SHA-256 |
| --- | --- |
| `OKVideoMac-0.8.0-AndroidDexBridge-release.apk` | `8f7260a3ddc9461dde82fea9cd8f323639259feca432e46b1e6533fc6364dbef` |
| `OKVideoMac-0.8.0-build130-SHA256SUMS` | `84803d7c52f9e88911b62809b0dce44542cbc464dd68bac38d4d36990e43f0b3` |
| `OKVideoMac-0.8.0-build130-SOURCE_RELEASE_INDEX.json` | `e3ec8d3c68bd3f38dd49d1528665b09f94cf3018e43ec5b60d13bc58087000b4` |
| `OKVideoMac-0.8.0-build130-SOURCE_RELEASE_MANIFEST.json` | `a2e005fc32ea153f2618098a10d08f21ca28c3e7daa5688c9f1b2e4ceac7b23c` |
| `OKVideoMac-0.8.0-build130-licenses.tar.gz` | `1df3fd10462e1edf90bed5912f774a0e12782363c9b33cb95ecdb3a9670b5615` |
| `OKVideoMac-0.8.0-build130-source.tar.gz` | `05e12556b7165b65df9620c423d8623830d941a574230a40ecabd707c84fe9d8` |
| `OKVideoMac-0.8.0-build130-third-party-source.tar.gz` | `da718adbdbce9b2e297499c05c24257fa09503ad6033b3599d61c221cecd5da1` |
| `OKVideoMac-0.8.0.dmg` | `f082a380ffb1d2d059f228e0b6f0d7b59424f80edff57e81230d2efe6496b97a` |
| `OKVideoMac-0.8.0.dmg.sha256` | `9e5537e81c8f65a02b19d63c9f03c98e0c4c2334bc7aefab323ffe5893f593e0` |
| `OKVideoMac-Android.cdx.json` | `2d014aca1df98fb23cfb7c670765c24064095714c1621bcce0c603e82371c224` |
| `OKVideoMac-Android.spdx.json` | `fe67908bf9b203014b07c869cb92ec44d94c81ec009a4efbe42e214e48101eb7` |
| `OKVideoMac-macOS.cdx.json` | `e828f885540a44013ad0f8bac0e89710929f107b9625f99a79954a564825767e` |
| `OKVideoMac-macOS.spdx.json` | `3b00c281230bee643cca55b1ec030803824da20437cf86379dbea74f651a0116` |
| `RELEASE_NOTES_0.8.0.md` | `3131b9e2e52f69c8cac3f08dd1918d16bd59713d472853323789f97f14f319ff` |
| `THIRD_PARTY_NOTICES.md` | `324a49846b451d0b54abe86e274ab067cb38a0206aac99d9f8a10da368fa978e` |

版本号、tag 目标、发布正文、最新 Release、main README/CHANGELOG/Notes 和文档链接完成
远端核验；0.7.3 的 Release 正文、资产身份与 digest 未改变。对应源码及下载资产由统一
SHA256SUMS、source index 和 manifest 绑定到发布提交。

## 已知限制

- 仅 Apple Silicon / arm64、macOS 12.0+；真实 Android Runtime E2E 证据仍只覆盖
  前序一台 M1 / macOS 14.8.8，不能当成其他 macOS 的 Runtime 设备矩阵。
- QuickJS、Node、Java/Dex、配置授权、网页嗅探、网盘、弹幕和文件名连播都是已实现子集；
  不支持 TVBox/FongMi 顶层 lives、Native Xtream catch-up/timeshift/direct_source、
  parser type 2/3/4 或 DRM。
- 性能资源边界与自动回归不替代长期播放、Instruments、多显示器及刷新率验收，
  不承诺固定搜索加速比例或任意媒体的 Seek 性能。
- 对应源码记录沿用明确的 native provenance 例外（原始 zlib distfile、历史 clang 输入等），
  发布未升级依赖或将这些历史缺口表述为完全可重现。

没有已知发布阻塞问题。

---

## English verification summary

OKVideoMac 0.8.0 (Build 130), with Android Bridge 0.3.48 (60), was built from
clean main commit `b049b381db52b5bbbeec9cf58bf54a5bd50a4f39` and pinned by `v0.8.0`.
Developer ID signing, secure timestamps, Hardened Runtime, Apple notarization,
stapling, Gatekeeper and fresh-installation runtime smoke passed. Submission:
`bc1f6ef5-5d19-4888-91f9-dbf5737d865d`. Final DMG SHA-256:
`f082a380ffb1d2d059f228e0b6f0d7b59424f80edff57e81230d2efe6496b97a`. All 15 public assets match local hashes,
GitHub service digests and independently downloaded bytes. README, changelog,
notes and links were checked after publication. Old releases and immutable
build-time source/notes snapshots remain unchanged. Conditional skips, prior
instrumentation and provider/device limitations retain their stated scope.
