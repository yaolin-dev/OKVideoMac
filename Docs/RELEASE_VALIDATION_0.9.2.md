# OKVideoMac 0.9.2（Build 198）正式发布验证记录

2026-11-05，已发布为 [GitHub latest / v0.9.2](https://github.com/yaolin-dev/OKVideoMac/releases/tag/v0.9.2)。所有必要门禁通过；16 项公开文件、latest feed 与最终下载 DMG 均在公开后重新验证。以下结果属于准确 Build 198，不把历史运行转记为本轮结果。

## 版本、源码与发布身份

- macOS App **0.9.2 / Build 198**；Bridge **0.3.58（70）**；macOS 12.0+、Apple Silicon arm64。
- 准确 release commit：`2bee29fa0f33fb2bec2ccfc30c7c2191323140cc`；annotated tag `v0.9.2` 对象 `ceb5aefa702ccde0df2e9e789f0cdf7c6fdc9b14` 固定该提交。
- 真实基线是本机刚完成的 Build 195 源码及未提交修改，结合远端 main，汇总原始资源历史恢复、混合分集排序／上下集／剧照映射、紧凑播放控制、阿狸原线路限定兼容、字幕编码／中文后备字体和直播摘要。商业源码未纳入。
- 本轮发现并修正 Android SBOM 历史聚合版本硬编码，SPDX／CycloneDX aggregate、metadata 和 purl 从 Bridge versionName 生成，严格绑定 APK SHA-256；10 项回归覆盖错误版本／引用／哈希及缺失／重复项。
- Build 198 只在前一候选基础上修正媒体测试夹具的可见窗口前置条件和当前请求异步反馈等待；产品逻辑、断言要求、超时和跳过规则保持。
- 从干净准确 main 提交执行未修改的 `OKVideoMac/macOS/OKVideoMac/Scripts/package-app.sh --mode distribution --notarize --crash-config FILE`。外部私有配置和 Keychain 凭据未入库。发布后的文档提交仅补录结果，不移动标签或重写签名产物／构建时源码及说明快照。
- 匿名下载的项目源码包逐一校对准确提交的 1197 个 Git blob，无内容差异、额外文件或缺失；按现有归档脚本排除 AGENTS.md。最终四份 SBOM 再验通过：38 Mach-O、170 Maven module、2 个静态 crash SDK，Bridge 版本与 APK 哈希一致。

## 测试结果

| 范围 | 实际结果 |
| --- | --- |
| 本地 Core Release | 1266 项：1237 通过、29 项既有明确条件跳过、0 失败 |
| 本地 App Release | 171 项通过：151 logic + 20 desktop；0 失败／跳过 |
| 真实媒体 | 198 媒体预检 15 项及最终 198 包 15 项分别通过，0 失败／跳过 |
| 原生／字幕／字体 | DASH／legacy 10、UTF-8／GB18030／Big5 自动及手动 5、常用中文 6 通过；罕见字观察仍有 1 个缺字 |
| Node／Android | Node 72、强制重跑 Android Release JVM 77 通过；lint 0 错误、9 条既有警告，另有 Kotlin metadata 诊断 |
| 离线与静态 | CI validator 51、SourceAudit 62、crash configuration 15、symbol 7 通过；静态 249 文件通过 |
| 敏感信息 | 候选 1198 文件及修正提交 46 个唯一 Git blob 扫描 CLEAN；最终归档／签名后扫描 CLEAN；文档收尾另行检查 |

[准确提交 CI 41863857063，attempt 3](https://github.com/yaolin-dev/OKVideoMac/actions/runs/41863857063) **七项 job 全部 success**，未改配置、降低断言或放开跳过条件。重新下载机器报告并逐项核对 sourceCommit：Core debug/release 各 1266／1237／29／0，Node 72、Android 77、离线 51／62／15 + symbol 7 + static、App Release 编译及 logic 151／0／0。App 子报告以父报告的准确提交绑定，版本和 Build 同为 0.9.2／198。CI 无分发证书；CI unsigned APK 不作为发布 APK。

## 签名、公证、票据与最终可用性

- Developer ID Application: **Yao Lin (KGG363ABK9)**；精确批准的 **38 个 Mach-O** 全部签名，Hardened Runtime、entitlement、依赖闭包及必要符号门禁通过；严格 deep codesign 通过。
- Apple Notarization **Accepted**：`5f54c532-70f9-4a86-b3f4-1ee90dbdbc06`。本次收尾重新查询 info 和完整 log，状态 Accepted、无 issues；未复用 196／197 的公证结果。
- 依照现有脚本，对公开 **DMG staple 并 validate**。规范 `verify-dmg.sh --mode distribution --source-index FILE --apk FILE --require-gatekeeper DMG` 验证只读挂载、精确布局、App 0.9.2／198、内嵌 source index、准确 APK、38 项签名及盘内 App／DMG Gatekeeper。额外 `hdiutil verify` 完整性检查在规范挂载验证之后执行，全部通过。
- 只读 DMG 内 App 没有额外的独立 staple 文件；这是脚本的外层 DMG 票据流程，不能记作盘内 App 独立 ticket 通过。已实际从最终 DMG 复制 App 到 File Provider 目录之外，另行 staple、validate、严格 codesign 和 Gatekeeper 全部通过；与 Desktop 指向的已安装 Build 198 App 的所有文件、权限及符号链接逐项一致。staple 前唯一差异为独立票据 `Contents/CodeResources`，staple 后完整清单相同。[Apple 的容器公证及 staple 说明](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)支持对分发 DMG 附加票据。
- Desktop 只指向验证通过的 Release 198，旧 195／196 保留；此前安装后 8 秒启动及启动后严格签名通过。本轮公开下载后再次验证安装版本、签名、票据、Gatekeeper 和字节身份；没有用 Debug 交付，也没有宣称人工 AX 界面验收。
- 锁定 Sparkle 2.10.0 工具归档 SHA-256 校验通过；Keychain 公钥匹配签名 App。最终下载 DMG EdDSA、appcast XML 签名、版本／Build／不可变 URL／长度及嵌入说明通过；latest 匿名 feed 与本地签名 feed 字节相同。不据此宣称新一轮完整 Sparkle 更新安装周期。

## 发布、失败处理与证据范围

1. 196 曾短暂公开，匿名 SBOM 下载截断时哈希门禁拦截并恢复草稿；进一步发现旧 SBOM 聚合版本 0.3.14 与真实 0.3.58 不符，按用户指示修复重建。196 持久产物保留。
2. 197 本地签名、公证与基础测试通过，但最终媒体首轮两项全屏 render probe 超时；定向重测通过后完整重测仍有一项异步提示断言失败。未将失败记为通过，197 产物未公开／安装；源码修正后纳入 198。
3. 198 修正夹具后重新完成构建、公证与完整本地验证。CI attempt 1／2 因托管 macOS runner 未被分配而失败；官方 job annotation 与 attempt 3 的完整成功记录保留在远端，没有以基础设施失败冒充测试通过。
4. 用户明确确认将本轮撤回标签从 175d8dd9f 更新为 2bee29fa0。以旧 tag object 的 force-with-lease 更新本轮 annotated tag，替换同一 Release 的 16 项资产；其他版本未改变。首次公开核验时全部匿名文件匹配，但额外磁盘探测之后的挂载出现一次“设备未配置”，当即恢复草稿；相同文件随后规范验证独立通过。只将外部附加 hdiutil 探测移至规范挂载之后，项目脚本和所有检查要求保持。
5. 最终重试公开为 latest，16 项均通过无 Authorization 匿名下载、字节数和 SHA-256；最终下载 DMG 再通过完整规范签名／挂载／Gatekeeper／完整性／更新签名验证，未更改任何资产字节。
6. 收尾复核曾在只读盘内 App 上尝试独立 ticket 校验，返回无独立票据；对照脚本确认外层 DMG 为 staple 载体，再以实际复制 App 独立 staple 验证。另一次额外副本放在 Documents 时被 File Provider 附加 FinderInfo，严格签名门禁拦截；按现有脚本使用临时目录后全部验证通过，未重签或改写发布文件。
7. 本次收尾直连 GitHub 出现匿名连接超时，先恢复草稿并停止该下载运行，再通过用户已有的 Upnet 本地 HTTP 代理重试；未更改系统代理，匿名请求始终无 GitHub Authorization。最终全部文件通过后才计为成功。
8. 部分早期 `/private/tmp` 工作日志已被清理，不能宣称所有原始临时日志仍在。本轮从持久交付文件与远端重新获取 Apple info/log、CI 机器报告、GitHub digest，并重新保存完整签名、挂载、安装副本、公开下载和 feed 验证记录至交付目录旁 `Verification-Build198`。该目录与下载／临时测试产物均不进入 Git。

## 发布文件 SHA-256

16 项文件均与 GitHub service digest、匿名下载和持久交付文件一致。内部 ZIP 不作为公开下载。

| 文件 | SHA-256 |
| --- | --- |
| `OKVideoMac-0.9.2-build198-source.tar.gz` | `5e71a9d2aeb8d92c24475748cea00d094fbde2173ae470b6b05054f7f5b5b2da` |
| `OKVideoMac-0.9.2-build198-third-party-source.tar.gz` | `779e8f6a6cdccdc08f939eddb123ca803e513d528c733c0893d69187f4ee8228` |
| `OKVideoMac-0.9.2-build198-licenses.tar.gz` | `b8fc71327a4f4b83bc374975b7ea3f1fb684e5c4d61fa44d7c5ae0914977e1bd` |
| `OKVideoMac-0.9.2-build198-SOURCE_RELEASE_INDEX.json` | `2a65878471cd3010e8ca1ab5b54bf690f1c37935f999718025ed7e0f6492fb89` |
| `OKVideoMac-0.9.2-build198-SOURCE_RELEASE_MANIFEST.json` | `53c1c07210b0836764f4e9809a92656ff83ef13ffdac21553fd7034228b23349` |
| `OKVideoMac-0.9.2-build198-SHA256SUMS` | `db8826e031696e61a9e67109684a1e3ee05defdfdaf9524dc9203bd0a6a293fb` |
| `OKVideoMac-0.9.2.dmg` | `c16b3b9eae728e9d702e443aabbabc7b6f5a797e7b218e276e4589d90a11166e` |
| `OKVideoMac-0.9.2.dmg.sha256` | `4200abe2c84bee03b00b95b2c50e1255148dd7894f5f53cc9dd055fe1a13a737` |
| `OKVideoMac-0.9.2-AndroidDexBridge-release.apk` | `b5a5897ef59623aea9d7ff05dcafc355e9d2f686fcef7c624279a73cd855c8b5` |
| `THIRD_PARTY_NOTICES.md` | `8816b0bb578f88ea9f00f46cda77c9fefc2feb1b8a1e8db793bb3d8363429490` |
| `RELEASE_NOTES_0.9.2.md` | `c5cc8cd58210629a4bca250a0a66933d68ed7454c5cc47726d7db2d6728f31ed` |
| `appcast.xml` | `fcc3046e732778323864e7667d8f19fb583d22e271fa3ae84e7f00621dba61db` |
| `OKVideoMac-macOS.spdx.json` | `b2490605ba88c28a99420424ce0905b9a3403affc3b6c30565848dbca9a7d6b6` |
| `OKVideoMac-macOS.cdx.json` | `12f8aba780455f9ecb7bb6621c9e65a61c50a037f5d6feeef10742b6324e498c` |
| `OKVideoMac-Android.spdx.json` | `db59f0fb68630df3ae6e4e8e9156b4ba08cf81d97526512956e70a5b6c56579f` |
| `OKVideoMac-Android.cdx.json` | `a27a6b22756639f6fec533d73d47aa41164c87e9276883df36059489a540c3a9` |

## 未解决问题与验证边界

无阻止本次发布的未解决失败。Core 29 项 opt-in／真实服务／资源／worker 条件测试保持原先跳过名单；Android lint 9 条既有警告；罕见字观察仍有 1 个缺字。macOS 12.5.1 历史 SwiftUI sheet 崩溃未在该系统重新证明修复；HDR／4K60／多设备、第三方真实服务长跑与完整 Sparkle 更新安装周期未扩大验证声明。既有 MacPorts libc++／zlib 原生来源重现例外保留，不宣称全部原生字节可重现，也未新增独立法律审查。详见[原生来源历史报告](NATIVE_REPRODUCIBLE_PROVENANCE.md)、[兼容性](../OKVideoMac/macOS/OKVideoMac/Docs/COMPATIBILITY.md)及[性能范围](../OKVideoMac/macOS/OKVideoMac/Docs/PERFORMANCE.md)。
