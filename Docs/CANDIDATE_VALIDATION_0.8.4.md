# OKVideoMac 0.8.4（Build 137）候选验证

日期：2026-10-09。此包用于工具栏启动崩溃修复验收，**不是正式 GitHub Release**。

- 构建提交：`af00614d622fc9cde89bdba21e707a8ef070813c`，干净 `codex/native-sidebar-divider` 分支。
- 生产修改：移除 `window.toolbar` KVO 监听及同步补回；SwiftUI 统一管理浏览窗口工具栏；无配置/加载中首页提供真实标题。保留独立材质、零宽分隔、侧栏附件及 macOS 12 API 兼容。
- 回归：macOS 14.8.9 上 48 项通过，0 失败、0 跳过。含真实 WindowGroup、新窗口命令、配置恢复、页面/主题切换及侧栏生命周期。
- 构建：现有 `package-app.sh --mode distribution --notarize`；公开原生依赖与 Android Bridge Release；源码、许可证、SBOM、索引和哈希绑定检查通过。
- 签名：Developer ID Application / Team `KGG363ABK9`；34 个 Mach-O 的签名与 Hardened Runtime 检查通过。
- Apple Notarization：**Accepted**；Submission `9583672a-03d9-4424-9f96-eafd67052ba7`；Apple 日志无 issues。
- 最终 DMG：签名、staple、Gatekeeper、只读挂载和盘内 App 验证通过。
- 安装副本：从最终 DMG 复制并单独 staple，重新验证签名和 Gatekeeper，通过；DMG 内容和 SHA-256 未改动。
- 运行库：盘内和安装副本的 QuickJS、MPV/FFmpeg、Node/V8 Hardened Runtime smoke 通过。
- 实际启动：签名原件用隔离数据库启动三轮（60/15/15 秒），均正常退出码 0；现有用户配置启动后同一进程持续 60 秒，留在运行中供检查。
- 安装：桌面入口已指向验证过的候选 App。
- 更新兼容：稳定 feed / 公钥与 0.8.3 一致，Build 递增；候选 appcast 和 DMG 的更新签名通过。候选 feed 未发布。
- 资产：本地归档 16 项分发文件；内部身份 ZIP 不作为用户安装包。
- GitHub：未 push 正式分支，未创建 `v0.8.4` 或正式 Release。

DMG：`OKVideoMac-0.8.4.dmg`

SHA-256：`5da633b3e3594665034a36956c5ccc55ad1f98b0334576a8776e91db5cc9241e`

## 失败项处理与证据边界

首次签名因 Apple 时间戳服务不可达而停止。只为 `timestamp.apple.com` 临时加入代理旁路，先用签名探针验证，再完整重跑标准打包和最终验证；每次结束均恢复原代理旁路列表。未关闭证书校验、Gatekeeper 或 Hardened Runtime。

首次编译遇到条件 ToolbarContent 的 macOS 13 API 限制，已改为 View 层分支，保留 macOS 12 deployment target；测试初版的共享系统占位项/无障碍观测假设已修正，最终测试无跳过。窗口截图作为已执行的外观检查证据。最终安装后的自动界面观测工具超时，未把该次观测计为视觉验收通过；进程存活验证独立通过。

原报告证明的是 App 启动崩溃；没有证明整机重启或自动重启循环。代码审计与隔离验证支持工具栏回写导致重入的修复方向，但本机没有复现 macOS 27.0.1 的原 SIGABRT，不能据此宣布目标环境问题已消失。

## 正式发布前仍需完成

按发布就绪记录在 macOS 27.0.1 复测旧配置/无配置启动、页面切换、关窗重开、侧栏收放和主题变化。如仍异常，保留新崩溃报告与异常原因。通过后按既有流程合入 main，从干净 exact commit 重新构建、签名、公证并验证最终资产，再创建正式 Tag/Release；分支候选不能直接晋升为正式资产。

本记录在候选构建完成后补录，不修改已签名包、包内源码索引或构建时发布说明。

## 后续状态

2026-10-09 用户确认 macOS 27.0.1 实机测试正常，已授权正式收尾发布。本文的候选包哈希、公证和构建提交仍为历史候选证据；正式版本从 main 重新生成，不复用该候选产物。

正式 [v0.8.4](https://github.com/yaolin-dev/OKVideoMac/releases/tag/v0.8.4) 已从 main 提交 `58e83d0aa29c7a7ffa9a00b15011875678395481` 重建、公证并发布；结果见[正式验证](RELEASE_VALIDATION_0.8.4.md)。候选历史记录及哈希保持不变。
