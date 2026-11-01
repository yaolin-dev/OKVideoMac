# OKVideoMac 0.9.1（Build 182）正式发布验证记录

2026-11-01。[GitHub v0.9.1](https://github.com/yaolin-dev/OKVideoMac/releases/tag/v0.9.1) 已公开、非 Draft、非 Prerelease，并设为 latest。

- Release/tag 准确提交：`e9acb58a0017dc9989de3bc4347d0c0ffd39be6c`。从最新 main 整合本轮开源改动，使用干净 main 的独立克隆执行现有 distribution 流程；未复用本地验收 DMG。
- 功能版本保留 0.9.1 / Build 182；Android Bridge 0.3.54（66）。本机 macOS 14.8.9、Xcode 16.2；arm64、最低目标 macOS 12.0。
- 本次提交不包含商业化工作树、证书、口令、API 管理令牌、公证凭据、用户数据或测试／构建输出。正式客户端配置仅从仓库外属主私有文件注入，用户上传授权与代理软件设置未变。

## 本轮验证

| 项目 | 结果 |
| --- | --- |
| Core/Persistence Debug、Release | 各 1,261 项：1,232 通过、29 项按原有精确规则跳过、0 失败；未增加跳过名单；Build 182 未改变这些组件的输入，保留本轮同输入报告并由远端 CI 再验 |
| App 关键流程 | 最终同轮 222 项通过，0 失败、0 跳过，包含全部 14 项原生桌面门禁 |
| 真实 App/HTTP/libmpv 媒体 | 9 项通过；拖动、像素、独立解码帧、网络路由、恢复与关闭 |
| Node / Android Release JVM | 72 / 65 项通过，0 跳过；实际固定 CatPaw 源包 HTTP 客户端额外验证通过 |
| 离线／静态 | CI 验证器 51、SourceAudit 52、崩溃配置 15、符号门禁 7；静态与敏感扫描通过 |
| Developer ID / Hardened Runtime | 38 个精确批准 Mach-O 镜像、依赖闭包、entitlements 与 strict deep 签名通过；Team KGG363ABK9 |
| Apple Notarization | **Accepted** `73ea0575-e9a1-4dc2-84b6-86962f0543ce`；独立 info 与 Apple 日志再次确认 Accepted，issues 为空 |
| Staple / Gatekeeper / DMG | DMG、独立及安装 App ticket 校验通过；DMG、盘内及安装 App 通过 Gatekeeper；hdiutil 完整性通过 |
| 最终运行库／符号 | QuickJS、MPV/FFmpeg、Node/V8、隔离启动与 10 项原生 DASH/既有播放验证通过；最终 dSYM UUID 匹配 |
| 实际桌面安装 | 字节、链接、权限及签名校验通过；About 为 0.9.1（182），主界面加载，Bridge ok/0.3.54；同一 PID 观察 30.012 秒，原生 Cmd-Q 正常退出 |
| GitHub CI | [Run 41312795609](https://github.com/yaolin-dev/OKVideoMac/actions/runs/41312795609) 对准确发布提交成功 |
| 资产下载 | 全部 16 项、339125383 字节，本地／GitHub digest／鉴权草稿下载／匿名公开下载 SHA-256 一致 |
| 稳定更新 | latest feed 字节、版本、不可变 DMG URL、XML 和下载 DMG EdDSA 签名，以及下载 DMG 签名／staple／Gatekeeper 再验证通过 |

实际观察时长取 clock 工具返回值，结合前后 UI 和精确 PID 核验；跨执行环境的 Python monotonic 值未作为观察时长。该观察不是启动速度基准。

## 失败处理与范围

- 179–182 的远端测试失败均被拦截，未创建 Tag/Release。根因是 CI 只提取 XcodeGen 可执行文件，遗漏 SettingPresets；版本号相同不能证明工具安装一致。前期的缓存诊断不完整。
- 最终保留 SHA-256 锁定的完整 bin/share 布局；新增资源缺失、搬移和生成宿主检查。完整官方工具生成项目与已测试项目逐字节一致，51 项 CI 校验通过，并先在候选分支跑通现有远端 CI 后才重做正式发布。App 实现和 Build 182 保持不变，按既有强制 clean build 流程重新绑定源码、签名和公证。
- 全新本地构建也拦住了重复链接宿主静态 Package 时的 Xcode target 解析问题；最终只提供 CZlib/CSQLite 搜索路径，保留宿主链接方式。冷构建 222 项与媒体 9 项随后通过。
- 离线启动隔离测试检测到用户重新打开正式 App 后按保护规则失败；用户正常退出后完整重跑通过，未删除保护或跳过用例。
- 保留首次失败日志；修正历史引用版本断言和新鲜 archive/short EPG 缓存假设，同时增加缓存独立性检查。
- 取消测试先等待取消信号，消除任务可能在 cancel 前完成的调度竞态。
- 原生面板采用仅测试编译启用的透明几何标记定位真实控件并发送鼠标事件；桌面焦点阻断在用户解锁后完整复验，不计为通过或跳过。
- 完成后的像素断言以 250 ms 有界等待接收 SwiftUI 下一帧；位置误差限制及等待阶段检查未放宽。独立原生位置和解码帧仍核对。
- 媒体测试副本改在隔离构建目录签名，避开 File Provider 的 Finder 元数据；APK 工具超时保留原报告并重跑完整逻辑组。未弱化签名、公证或测试完成判定。
- 公开后的文档提交遇到 GitHub macOS 14 计划停机，Mac 任务未启动即取消，未计为通过。[官方公告](https://github.com/actions/runner-images/issues/13518)说明该镜像于 2026-11-02 退役。后续 main 的 CI 改用仍包含 Xcode 16.2 的 macOS 15 arm64 镜像，并隔离 App/Core 旧宿主缓存；发布提交已成功的 CI、App 实现、版本、tag 和公证产物保持不变。迁移后的独立 CI 状态见 [CI 指南](CI.md)及工作流运行记录，不以旧结果代替。
- 第三方真实网盘长时表现、HDR/4K60、macOS 12.5.1 历史 SwiftUI 弹窗及第三方符号／native provenance 边界继续保留。Android 依赖既有 Kotlin lint 元数据诊断仍被记录；Release 构建与 JVM 测试实际成功。不宣称新增完整 Sparkle 更新安装周期。

## 不可变公开资产

源码与 SHA256SUMS 绑定构建时准确提交；内部 ZIP 不作为用户下载。后续发布文档提交不改写 tag、签名、公证产物、源包或签名更新说明。

| 文件 | SHA-256 |
| --- | --- |
| `OKVideoMac-0.9.1-build182-source.tar.gz` | `2ef1753d98c720fba06762d0a6c57d1e2f6e9968e78d7c5b92211ea0cf3c8e8b` |
| `OKVideoMac-0.9.1-build182-third-party-source.tar.gz` | `662eb9246da03852f2c9118df6dd8b7c76c0511ca78819f556351ec70a642cb3` |
| `OKVideoMac-0.9.1-build182-licenses.tar.gz` | `9b9a121453d19a2f655b4010621b587cc1fac3468b2a2d9ec04ad952c0e3109c` |
| `OKVideoMac-0.9.1-build182-SOURCE_RELEASE_INDEX.json` | `358b22c2b3a6aeb7762a02f1804e32968c4d17335ef46ee6f5073558c2f3665e` |
| `OKVideoMac-0.9.1-build182-SOURCE_RELEASE_MANIFEST.json` | `0c25f36234516b4afbd38922ecdf003ff685ad65909ab02f2cfbbe62d9d59660` |
| `OKVideoMac-0.9.1-build182-SHA256SUMS` | `41712b0c12318ed82a851a58155ff56f268691a07408360ed3c44e779363203c` |
| `OKVideoMac-0.9.1.dmg` | `4f751e26ed97e36444733202edd68817f66a9b4b424cc7e2266ddb2831626780` |
| `OKVideoMac-0.9.1.dmg.sha256` | `36b794989d10e2c6512ae9f5cf766c941bdd46316c9269729c06a615628958a3` |
| `OKVideoMac-0.9.1-AndroidDexBridge-release.apk` | `c127d048d678310b9468bddff12a0463af1ad64b3fa491ce6962bf7395442e1e` |
| `THIRD_PARTY_NOTICES.md` | `1432422d6400490ef4fa82ffd32bd955e5e535a5d0a2d89e0ea4a453d6e4c00f` |
| `RELEASE_NOTES_0.9.1.md` | `6c2a1c3aca59f8c4f489c40b656be0106226964770bdf6b5f5d72145651703a3` |
| `appcast.xml` | `69a24407ffe748e17e8d0ffbfb053aea4acad384d50819c72906a82b2411c5cd` |
| `OKVideoMac-macOS.spdx.json` | `278a1f2e9bfae991e86ad9ec6e9fb37a88be18ecaf9f47a5fa74cb4d53db0aac` |
| `OKVideoMac-macOS.cdx.json` | `89b7c7bb897168a4fe5235c2a703034d1fbb7ef0cedcce44984f99688e8ffbe1` |
| `OKVideoMac-Android.spdx.json` | `298db1d58e121c9e9b0bf97d48fbb3116e5dbfa91e1f996116e7d5d1300c9683` |
| `OKVideoMac-Android.cdx.json` | `dc24eb7eac6fdcf7e89dcca603a194256ba1eee8fc9654de8b2bd9eb3369cf0f` |
