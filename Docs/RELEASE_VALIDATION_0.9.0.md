# OKVideoMac 0.9.0（Build 155）正式发布验证记录

日期：2026-10-26。[GitHub v0.9.0](https://github.com/yaolin-dev/OKVideoMac/releases/tag/v0.9.0) 已公开、非 Draft、非 Prerelease、latest；Release ID `424196178`。

## 固定身份与本轮范围

- Release commit `4a69c5905cbb1717f86c84e7ac7f6b9d56956cdb`，annotated tag `v0.9.0` 固定该提交。基于 GitHub main `ebf47d7223f1983ffab73f2057b7f53e0c951c20` 整理后续开源提交和本地 Build 154 修改，正常快进／原子推送；没有使用商业工作树、本地验收 DMG、force push 或重写旧标签。
- App **0.9.0（155）**；用户指定版本 0.9.0，Build 从 154 顺序递增。Android Bridge **0.3.50（62）**。Apple Silicon arm64，最低编译目标 macOS 12.0；构建／测试机 macOS 14.8.9、Xcode 16.2／SDK 15.2。用户报告本轮候选在 macOS 27.0.1 实机正常，未将其描述为本机重新测量。
- 设置操作进度／取消／错误反馈，默认原详情及有条件自动 TMDB、紧凑选择器，DASH／B 站恢复，直播预览、弹幕缩放、Android 启动阶段、截断提示、分类身份崩溃防护与原始崩溃身份保留；详见[发布说明](RELEASE_NOTES_0.9.0.md)与[失败审查](RELEASE_READINESS_0.9.0.md)。
- 使用现有 `package-app.sh --mode distribution --notarize --crash-config FILE` 从干净 main 准确提交重新构建。复用 Developer ID、Keychain 公证 profile、稳定更新通道和公开客户端配置；仓库外私有配置仅作为打包输入。未提交证书、密码、管理令牌、公证凭据、临时文件、测试／构建产物，也未改变用户崩溃上传授权。

## 验证结果

| 项目 | 结果 |
| --- | --- |
| Release App XCTest | 1602 个唯一用例：1582 通过、20 条件跳过、0 未解决失败；完整套件加最终受影响窗口 26 项复验，未冒充单轮全绿 |
| Core／Persistence：原发布轮次（Debug） | 1204 通过、29 条件跳过、0 失败；原文误标为 Release，已按原始日志纠正 |
| Core／Persistence：发布后补验（Release） | 2026-10-26 对与 v0.9.0 完全相同的核心源码显式执行 `swift test --configuration release`；1233 项中 1204 通过、29 条件跳过、0 失败 |
| Node／Android Release 单测 | Node 55、Android 45 通过，0 失败 |
| SourceAudit／原生验收启动器 | 51 通过、0 跳过、0 失败 |
| 崩溃发布配置／符号归档 | 配置 15 项通过；符号归档 7 项检查通过 |
| 源码／许可证／SBOM | 构建前 1088 个源码文件敏感信息检查 CLEAN；最终源码归档、完整 App 与发布资产扫描及版本／文档门禁通过 |
| Developer ID／Hardened Runtime | 38 个精确批准 Mach-O 镜像，arm64／最低目标／依赖闭包／entitlements／strict deep 签名通过；`Developer ID Application: Yao Lin (KGG363ABK9)` |
| Apple Notarization | **Accepted** `433a4265-e3e9-4711-b25f-e82d9775ed03`；独立 info 与 Apple log 同为 Accepted，issues 为 null |
| Staple／Gatekeeper | DMG、独立及安装 App ticket 验证通过；DMG、盘内及安装 App 为 `Notarized Developer ID`；DMG `hdiutil verify` 通过 |
| Hardened Runtime 运行 | QuickJS、MPV／FFmpeg、Node／V8 JIT、隔离数据下 5 秒 App 检查通过；脚本 SIGTERM 结束不充当正常退出证据 |
| 最终签名产物播放 | 10 项真实原生 DASH／既有播放验证通过，包含视频／音频解码、seek、headers、Range、redirect 及终止失败路径 |
| 安装及真实身份启动 | 文件字节／链接／权限一致，签名／ticket／Gatekeeper／bundle 通过；About 显示 0.9.0（155），同一 PID 主窗口观察 30.0093 秒，原生 Cmd-Q 正常退出后无残留主程序 |
| 草稿／公开下载 | 全部 16 项、338566542 字节；本地、GitHub digest／大小、鉴权草稿下载与匿名公开下载 SHA-256 一致 |
| 稳定更新与最终下载 DMG | latest feed 字节、155／0.9.0／不可变下载 URL、XML 签名和最终下载 DMG EdDSA 签名通过；下载 DMG 再次通过 codesign、staple、Gatekeeper 与磁盘完整性检查 |

主窗口观察采用 clock 工具返回的 30.0093 秒实际等待及前后 UI／同一 PID 证据，不是启动耗时基准。桌面入口指向本地 `Applications/OKVideoMac-0.9.0-build155.app`，旧 Build 154 和桌面入口备份保留。未重新配置用户 SDK／AVD 或启用自动更新。

2026-10-26 测试记录更正：原 Core／Persistence 日志首行是 `Building for debugging...`，因此原发布时只能证明 Debug 测试通过。上表分别保留原始证据与发布后的 Release 补验，不将补验倒记为发布前完成。补验使用 Xcode 16.2／Swift 6.0.3，日志明确显示 `Building for production...` 与 `release` 构建路径；逐项 XCTest 结果和最终汇总一致，日志 SHA-256 为 `d56bc3f23fd9a1fb264453065143ff08ffc41e03bd1bf222e772958c52da69f2`。正式 App 的 Release 构建、签名和公证由其他独立验证记录证明；tag 与已发布资产保持不变。

## 失败处理与不变性

- 海报整卡 tooltip 的旧期望改为与“仅截断标题提示”一致，同时保留标题无障碍及原布局断言；独立截断／短文本／复用／缩放回归仍通过。
- 合成夹具补齐为 40 秒 H.264／HEVC／AAC／PCM 和 20 秒长 GOP，保持原帧率、定位、节目边界、最后请求与结束断言。搜索焦点夹具显式激活自己的窗口，原 keyWindow／边栏／编辑器断言全部复验通过。
- 原生启动器因旧 App 运行而拒绝时，正常退出旧 App 后原规则下 51 项通过。失败轮次保留；没有以跳过、放宽断言或移除保护替代修复。
- 草稿直连大文件下载缓慢后，仅对本次下载使用机器已有代理，保留已验证文件；未修改系统代理、重复创建 Release 或覆盖上传资产。
- v0.8.7 的 tag 对象及提交、Release ID、全部 16 项资产 ID／大小／digest 保持不变。本次 tag 与 16 项签名资产、构建时源码／notes 快照保持不可变；发布后的文档提交只记录事实。内部 ZIP 与本地符号归档不上传到公开 Release。

## 已知边界与未解决问题

- macOS 12.5.1 历史 SwiftUI sheet 崩溃缺少同系统测试机与具体弹窗复现证据，本轮不宣称修复；没有扩大其他系统／硬件的运行保证。
- 20 项 App 与 29 项 Core 条件跳过依赖真实隔离 Android 生命周期／AVD、外部 Node Contract B／Xtream／TMDB 服务、公网或显式长时／资源／XMLTV 实验等条件，未计为通过。没有声称新的完整 Sparkle 更新安装周期、长期功耗／泄漏普查、蓝牙／耳机或真实外部来源全量覆盖。
- TMDB 及播放取决于凭据、API／图片网络与来源服务端；原详情及原片源入口保留。画中画仍使用动态检测的私有系统接口。
- 最终主程序及两项 helper 的 UUID／dSYM 匹配，本地归档已备份；第三方符号覆盖缺口保持显式记录。用户撤销的 Sentry Build 140 登记／文件上传没有执行，本轮也未上传新 dSYM 或重做后台合成解析。
- 当前没有阻塞本次测试、签名、公证、安装或正式公开发布的未解决失败；既有原生来源／可复现性例外继续按 source index、provenance 和 notices 记录。

## 公开资产 SHA-256

| 文件 | SHA-256 |
| --- | --- |
| `OKVideoMac-0.9.0-AndroidDexBridge-release.apk` | `813c5ebec3dacfa55e95f4d8460167b6d869569418f33ab8e27a106053d63b10` |
| `OKVideoMac-0.9.0-build155-SHA256SUMS` | `95f348aeb80cf74254d6496ef163ab8aeeee70f9948bab85275b868c84a253a9` |
| `OKVideoMac-0.9.0-build155-SOURCE_RELEASE_INDEX.json` | `aea1961afb170a9a06691c9d1b98d6aee86a0983dbdcb48b230f4d62599c1901` |
| `OKVideoMac-0.9.0-build155-SOURCE_RELEASE_MANIFEST.json` | `9f50e945c7c7d8e6d97bd136fdf2e4e398ed99ad97e93edfdce91c6be23ac546` |
| `OKVideoMac-0.9.0-build155-licenses.tar.gz` | `ef0988d14f2a9f9cd164fe0b75d23187afdf970a4c34387eef5c0f465df1c92e` |
| `OKVideoMac-0.9.0-build155-source.tar.gz` | `8b1fb2c5732da648fc8642e21e00feb393d6631daaa1e0780bad955072b92615` |
| `OKVideoMac-0.9.0-build155-third-party-source.tar.gz` | `c2fd072e51bda6095acbefcab8573d501fe682be7c328b385c39090aad38757e` |
| `OKVideoMac-0.9.0.dmg` | `e4aae1e3adb038ac48ff0a7228fab1c828977e1d23317fdbad85df8224dbc013` |
| `OKVideoMac-0.9.0.dmg.sha256` | `5a67162f69a6362e085186fabe87b0c1bf0c5bac08832946a67cee76511601a7` |
| `OKVideoMac-Android.cdx.json` | `fa3b34c8abd59127f6324d0e612debcc5838522f704fafff3e9da8ac381c7314` |
| `OKVideoMac-Android.spdx.json` | `9728a0ef0c88d9bd949aafe9bafb4cb9519b7d509428d8dd36a2000220be7546` |
| `OKVideoMac-macOS.cdx.json` | `fc09113fdb721e541e3e50f9b8cb93bd4ff85de57568deb4345c27a2a2890dce` |
| `OKVideoMac-macOS.spdx.json` | `0d8bdfed09b3f65136655361fa07b4685b797b74eadedb9df67e01b1817f3509` |
| `RELEASE_NOTES_0.9.0.md` | `6e7bd90af2bc3f894a699469a29fa775734709367d4f91a5f3143088dcb12a0c` |
| `THIRD_PARTY_NOTICES.md` | `c5b385a16136518897c984ab1904c95fea245c72c8a2e68bf2c1893bf75168d6` |
| `appcast.xml` | `fd39e1cd31155927cc735dfa2593f1dab17670ff2cfb8d6af3c6b409e511d52d` |
