# OKVideoMac 0.8.2（Build 135）发布就绪记录

日期：2026-10-08。状态：已完成正式发布；Apple 分发门禁、公开资产与旧版更新检测通过。

基线：开源 main `bec6206`（0.8.1 / Build 134）。商业隔离目录未修改。

## 已验证

- 原实现的正式 XCTest 出现预期 3 个失败断言：旧指纹残留、备份缺少指纹；修复后同一用例通过。
- 11 项事务测试覆盖逐次移动失败、恢复再失败、中断续恢复、缺少指纹、损坏记录及互斥。
- AndroidRuntimeKit 全套 68 项：67 通过，1 在线安装条件跳过，0 失败。
- Release App 全套 1,242 项：1,225 通过，17 条件跳过，0 失败；包括 50 轮重建/恢复以及镜像/SDK/ABI/Emulator 严格拒绝与准入前恢复。
- 真实隔离 Emulator 用例另行执行通过：default 首次启动及 Bridge → 重建 google_apis 及 Bridge → 停止、再次启动、停止；无未完成事务、AVD 锁或 Emulator 残留。
- 本机原备份按文件 SHA-256 复制核验后恢复；原备份及私有 ADB 密钥元数据未变，失败现场另行保留。实际用户云盘登录需人工确认。

## 本次正式发布前重新验证

- 当前源代码 Release App：1,242 项，1,225 通过、17 条件跳过、0 失败。
- OKVideoKit：1,036 项，1,014 通过、22 条件跳过、0 失败。
- AndroidRuntimeKit：68 项，67 通过、1 在线安装条件跳过、0 失败。
- SourceAudit 32 项全部通过，含显式构建并签名的独立 launcher fixture；Node 47 项通过。
- Android Bridge 34 JVM 测试通过，Release lint 0 error、8 个既有 warnings。
- 新隔离 Emulator 实际完成 default→google_apis、Bridge、停止与再次启动，旧备份指纹与新指纹分别正确，退出后无进程、私有端口、AVD 锁或未完成事务。
- 25 个待提交文件敏感信息及本机路径扫描通过；git diff --check、版本与文档门禁通过。
- launcher fixture 首次编译命令遗漏 -parse-as-library，修正命令后全部 32 项重跑通过，原失败记录保留；测试断言没有改变。

## 交付门禁

本地候选的 captured local acceptance、Developer ID / Hardened Runtime 和 Android 启动、停止、重启验证仅作为前置证据。本次正式产物从干净 main exact commit `42be0560a168a949d7f7b61e1c3837a8b4aab189` 经现有 `package-app.sh --mode distribution --notarize` 重新构建，没有复用本地候选二进制。

Developer ID、Hardened Runtime、Apple Accepted、staple、Gatekeeper、最终 DMG / 安装 smoke、签名 appcast 和对应源码绑定全部通过后，才推送 main 与固定同一提交的 tag v0.8.2、公开 16 个资产。公开下载文件逐项 SHA-256 验证通过；未修改的正式 0.8.1 App 已实际检测到 0.8.2。桌面 App 已指向正式公证版本。

完整实际结果见 [正式验证记录](RELEASE_VALIDATION_0.8.2.md)。发布后文档补录不移动 tag，不改写签名资产或构建时源码与说明快照。

原始失败日志保留：首轮事务名称验证不匹配与 App 错误分类遗漏已修复后重跑，未删除测试或降低断言。真实硬件/云盘账号/完整第三方站点矩阵不在本轮自动通过范围。
