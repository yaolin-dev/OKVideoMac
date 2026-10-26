# OKVideoMac 0.9.0（Build 155）发布就绪记录

日期：2026-10-26。基于 GitHub main `ebf47d7223f1983ffab73f2057b7f53e0c951c20`，整理开源分支后续提交与 Build 154 的待提交修复。商业化工作目录不参与发布。Android Bridge 0.3.50（62）。

用户已确认本轮候选在 macOS 27.0.1 实机正常；本机为 macOS 14.8.9／Xcode 16.2。版本按用户指定提升为 0.9.0，Build 从已使用的 154 顺序递增为 155。

本轮已完成正式发布：Release App XCTest、Core／Persistence、Android／Node、源码发布门禁、Developer ID／Hardened Runtime、Apple Accepted、staple、Gatekeeper、安装及全部 16 项公开资产核验通过。准确提交、Apple submission、资产 SHA-256 与已知边界见[正式验证记录](RELEASE_VALIDATION_0.9.0.md)。下文保留测试阶段的失败审查与验证范围。

现有 package-app.sh 要求准确的干净 Git 提交。代码测试通过后先建立本地 main 提交 `4a69c5905cbb1717f86c84e7ac7f6b9d56956cdb`，再从该提交完成 distribution／notarize 流水线。全部正式产物验证通过后快进推送 main 与 annotated tag `v0.9.0`，草稿 16 项下载核对通过后公开 Release；后续公开下载与更新源验证亦通过。

必须保留失败轮次，修复相关问题后复验；不使用本地 acceptance 包代替正式构建。凭据复用现有 Keychain 与仓库外属主专用配置，符号和测试产物存放于发布工作区外层。

已知边界：macOS 12.5.1 历史 SwiftUI sheet 崩溃尚待同系统定位；可选外部服务／真实 Android 生命周期／长期资源实验按实际执行情况记录，不计为已通过。

## 本轮失败审查

- 旧海报测试仍要求整卡提示，与本轮“仅截断标题提示”的已实现行为冲突。保留备注、来源和布局断言，改为检查整卡无提示及标题无障碍文本；截断／短标题／复用／缩放的专门测试同时复验。
- 合成播放夹具补齐为 40 秒的 H.264／HEVC／AAC／PCM，保持原帧率与节目边界断言。长 GOP 夹具使用符合原定位边界的 20 秒关键帧间距；没有放宽定位、末次请求或播放结束断言。
- 搜索快捷键测试必须取得其自己的窗口焦点；补齐前台激活和同步，保留真实 keyWindow、边栏与编辑器断言。
- 原生验收启动器在旧正式实例运行时按保护规则拒绝。正常退出旧版后，51 项 SourceAudit／启动器测试全部通过，没有改动拒绝规则。
- 崩溃符号文档按现有脚本校正：正式流程验证本地归档，不增加未经既有流程要求的 Sentry 上传步骤。

## 本轮代码验证结果

- 完整 Release App 用例共 1602 项，最终 1582 通过、20 条件跳过；焦点夹具修正后相关 26 项复验通过，未保留失败项。
- Core／Persistence：1204 通过、29 条件跳过；Node 55、Android Release 单测 45、SourceAudit／原生启动器 51、崩溃发布配置 15 项通过。
- 实际播放验证启用本地及 HTTP Range、H.264／HEVC／PCM、画中画、节目边界、媒体替换、长 GOP 和连续定位；外部来源、真实 Android 生命周期及长时资源门禁的条件跳过保持独立列明。
