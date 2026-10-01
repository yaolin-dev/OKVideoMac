# OKVideoMac 0.8.0（Build 130）发布就绪记录

日期：2026-10-01

## 对比基线与范围

- 已发布基线：`v0.7.3` / Build 129 / 提交
  `55ffa9d55faced404b20034d7cfe5bcfbc1be581`，2026-09-27 发布。
  [GitHub Release](https://github.com/yaolin-dev/OKVideoMac/releases/tag/v0.7.3)
  记录了 Developer ID、公证、Staple、Gatekeeper、安装 smoke 及资产哈希。
- 当前分支：`codex/tvbox-configuration-interactions`；审计开始时 HEAD：
  `5780acd5ec7124e0d761ec9e0284805a1fa5168a`。
  基线后的已提交 ADB 恢复修复与全部未提交源码均纳入检查，不以 HEAD 单独作为变更基线。
- 应用候选：0.8.0（Build 130）；Android Bridge：0.3.48（60），原为 0.3.45（57）。
  新配置/授权能力与多个交互模块变化采用 minor 版本；Build 在 129 基础上递增。
- 模块覆盖：Android 配置/授权/代理/窗口所有权，macOS 卡片/分类/授权路由，Node
  runtime/Profile 通知、搜索/详情缓存与异步所有权，播放器布局/全屏/Seek/结束流程，
  资源语义与连播队列，ADB 生命周期与诊断，中英文文案、版本和发布流程。
- Full Guide、弹幕、历史/收藏来源身份与备份 v4 属于 0.7.3 已发布能力；本次不改数据库
  迁移或备份 schema，不升级 native/Maven 依赖，不把历史测试重写为本轮结果。

具体前后行为见 [Release Notes](RELEASE_NOTES_0.8.0.md)。完整文件分组与提交建议见
[发布准备记录](RELEASE_PREPARATION_0.8.0.md)。

## 本轮重新执行的验证

宿主：Apple Silicon，macOS 14.8.9，Xcode 16.2 / macOS SDK 15.2。
测试使用隔离 Bundle ID 的 Debug host；它仅用于测试，交付另行使用 Release 包。

| 门禁 | 实际结果 |
| --- | --- |
| macOS 可重复全量套件 | 1,211 项：1,199 通过、12 条件跳过、0 失败；排除 4 项真实 Emulator 生命周期 opt-in 用例 |
| libmpv 长 GOP 真实媒体回归 | 单独 1 项通过：播放/暂停定位、快速连续 Seek、旧超时不再触发、定位到末尾只产生一次有效 EOF |
| OKVideoKit 全量 | 1,036 项：1,014 通过、22 性能/网络实验跳过、0 失败 |
| AndroidRuntimeKit 全量 | 57 项：56 通过、1 在线安装门禁跳过、0 失败 |
| Node / CatPaw / Quark | 47 项通过、0 失败 |
| SourceAudit | 24 项：17 通过、7 条件跳过、0 失败 |
| Android Bridge Release unit / lint | 34 项 JVM 测试通过；lint 0 error、9 warning，Gradle 成功 |
| 文档版本、结构与 XcodeGen 2.38.0 | 版本一致性、JSON/plist、文档本地链接与 whitespace 通过；官方 2.38.0 重生成后工程一致 |
| 0.8.0（130）本地 Release package | 首轮通过：Release / arm64 / macOS 12.0、29 Mach-O、APK、签名、SBOM、ZIP/DMG、源码归档与资产扫描；补录后完整工作区复验通过才安装 |

12 项 App 条件跳过包含外部网络/资源和默认未设置长 GOP fixture 等门禁；真实长 GOP
用例已另外显式执行通过。四项 Emulator opt-in 仍需独立生命周期验收，不算默认全量覆盖。
Android lint 保留原生窗口反射、启用配置页 JavaScript 等警告，未通过关闭检查掩盖；
既有 OkHttp 5.1.0/Kotlin 2.2 与 AGP 8.7.3 lint analyzer Kotlin 2.0 metadata 诊断仍会输出，
最终 Gradle/lint 结果成功。确定性授权测试不等于真实账号已登录并取得媒体。

## 前序证据与本轮边界

- 同一轮功能实现的 API 35 Android instrumentation：全套 96 项通过，另行配置交互
  20 项通过。对照该验收冻结快照的 Android Java/Gradle/lock 共 58 个文件，与当前
  工作区逐文件一致。本次发布准备没有再启动模拟器重跑这套测试。
- 前序 95 项测试的一次播放授权失败用例出现 10 秒 HTTP SocketTimeout，原因未完全
  隔离；同一用例单独通过、未改代码的全套重跑通过，最终 96 项通过。保留此不稳定性记录。
- 前序真实来源确认了从原播放请求进入原生登录、延迟配置二维码保持当前 owner、静默
  清理动作及时完成与取消后窗口清理。没有使用真实账号完成登录后播放，没有验收所有
  第三方配置网页或按钮。
- 0.7.3 的公开分发签名、公证及旧版本生命周期测试是历史证据，不转记为 0.8.0 已完成。

## 元数据与文档

- `project.yml` 与 Xcode project 同步 MARKETING_VERSION 0.8.0、CURRENT_PROJECT_VERSION
  130；Info.plist 保持引用这两个共享设置。
- native lock 的 release 标识、Third-Party Notices 与发布资产命名同步；Bridge 使用自身
  0.3.48/60 版本，签名证书与依赖锁不变。
- 英中 README、详细说明、CHANGELOG、Release Notes、兼容性、架构、性能、构建、Bridge
  说明、DMG/源码/SBOM 流程同步。纠正旧文档将最新公开版标为 0.6.1 的状态；0.7.3
  发布前记录保留历史身份，公开验证据 GitHub Release 补录。

## 发布判定与剩余门禁

本轮代码、文档、自动回归和首轮本地 Release 包门禁均通过，具备提交前评审条件。
首轮冻结源码清单 SHA-256：
`5087ab73650dd87f790a39bff97a7c839612b179bee115c0a07fbe7f41c8802f`。
本记录补录后重新冻结完整工作区并执行相同包门禁，让最终包包含完整发布文档；最终快照
身份以该包的 `LOCAL_ACCEPTANCE_SNAPSHOT.json` 为准，不把首轮指纹当作最终副本指纹。
桌面安装只使用最终验证通过的 Release，复制后再核对包体、签名和文件清单，再原子替换
桌面入口并保留前一副本；Debug、失败包与未验证副本不进入交付。

本次准备不创建 commit、Tag、PR 或 GitHub Release。本地 ad-hoc Release 验收通过
不等于 Developer ID 分发或 Apple 公证通过。

正式公开 0.8.0 仍需把已审核改动提交并进入最终干净 release commit，重新执行 Developer ID
签名、Apple 公证、Staple、Gatekeeper、DMG 安装 smoke、对应源码/SBOM/哈希绑定，再创建
`v0.8.0` 并一并发布资产。未发布前最近已公证公开版本仍为 0.7.3。

Apple Silicon / arm64 / macOS 12.0+ 边界保持；QuickJS、Node、Java/Dex、配置授权与
文件名推断均为已实现子集。未完成的设备/显示器/网络/长期运行矩阵不由自动测试结果替代。
