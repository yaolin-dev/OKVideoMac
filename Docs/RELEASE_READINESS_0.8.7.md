# OKVideoMac 0.8.7（Build 140）发布就绪记录

日期：2026-10-17。状态：正式发布、桌面安装和16项公开资产核验完成；见[正式验证](RELEASE_VALIDATION_0.8.7.md)。

版本按现有规则从 0.8.6 / 139 递增为 0.8.7 / 140；Android Bridge 0.3.48 / 60 和依赖锁定版本保持。检查范围包括远程 main 之后的播放信息、直播回放提交，以及当前未提交的 TVBox／Xtream、画中画、启动／播放器、夸克历史和历史／详情修复。商业工作树不参与。

## 发布门禁

1. 检查实际 Git 改动、文档、工程版本与敏感信息，运行完整 Release 回归及相关 Core/Persistence/SourceAudit 检查。
2. 现有正式脚本要求干净 Git commit。通过源码／测试后，形成本地 main 候选提交，从其准确源码运行 `package-app.sh --mode distribution --notarize --crash-config FILE`；凭据只复用现有 Keychain 与仓库外私有文件。
3. 严格要求 Apple Accepted，完成 staple、codesign、Gatekeeper、DMG 布局／盘内 App、安装和最终源码／SBOM／checksum 校验。
4. 只有全部必要检查通过后才向 origin/main 推送、创建对应 Tag／非预发布 Release 并上传最终固定产物；随后核验公开资产哈希和 stable feed。

本轮实际结果将在验证完成后补录。尚未运行的检查不得写成通过。条件性外部服务／真实设备用例按原门禁和实际原因记录，不能用跳过替代失败修复。

## 本地源码与 Release 测试通过检查点

- 全量 Release XCTest：1352 通过、0 失败、15 项原有条件跳过，共 1367。启用合成 H.264、HEVC、PCM、本地／HTTP Range、长 GOP 夹具，覆盖原生画中画、媒体替换、首帧／跳转、节目结束与 SwiftUI surface 重挂载；历史／详情回归通过。
- Release Core／Persistence：1067 通过、0 失败、22 项原有条件跳过，共 1089。条件跳过仍包括显式 XMLTV 内存／loopback 实验、外部 Node Contract B、真实 Android 生命周期和公网／30 分钟验收，不计为通过。
- SourceAudit：42 通过、0 失败、0 跳过；旧版经正常退出后重跑原生启动器测试，保留其进程互斥保护。崩溃发布配置／隐私回归：15 通过。
- 文档／版本一致性、diff whitespace 和 994 个待发布源码文件的敏感信息检查通过；仓库外的私有配置、证书、凭据、媒体夹具、构建和测试产物不进入源码。
- 首轮发现的浅色标题栏亮缝已用连续原生标题栏材质修复，原像素断言通过。主题测试改为根据请求主题确定期望值，保留最初三帧检查；长 GOP 夹具明确设置真实窗口尺寸、前置显示和直接本地传输，原首帧／跳转／EOF 断言通过。发布工具的旧 34 镜像计数更新为现有精确清单 36，保留缺失／替换拒绝测试。

本检查点只确认源码和测试。下一阶段先形成本地候选提交并 fast-forward 到 main，以满足现有正式流水线的干净 main 要求；未向 GitHub 推送或创建 Tag／Release。正式签名、公证、staple、Gatekeeper 和安装结果完成后另行补录。

## 最终发布检查点

干净 main 的 release commit `8208c1ea6db514cb35bbd32bbed8a15ade06cb03` 已按正式脚本构建。Developer ID／Hardened Runtime、Apple Accepted、公证日志无 issues、DMG 与安装 App staple、Gatekeeper、源码／SBOM／校验和、安装字节及链接核验、可见窗口和正常退出全部通过。

`main` 与 annotated tag `v0.8.7` 已推送；正式非预发布 Release 为 latest。16项资产均在公开前从 Draft 下载核对，公开后匿名下载 SHA-256／GitHub digest 再次核验；stable feed XML／DMG EdDSA 和 latest 字节通过。v0.8.5／v0.8.6 的标签与资产身份保持。

以上较早检查点保留其当时状态，不代表最终仍有失败。条件跳过与未重测范围仍不计为通过；完整结果及哈希见正式验证记录。
