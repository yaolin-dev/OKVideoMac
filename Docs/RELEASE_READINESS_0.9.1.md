# OKVideoMac 0.9.1（Build 179）发布就绪记录

2026-11-01：本轮正在按现有正式发布流程收尾。版本沿用 0.9.1 / Build 179；本轮整理未改变播放器实现，不额外提升版本。

## 发布门禁

- 从最新 origin/main 整合本轮开源改动，排除商业化代码、私有配置、运行数据、测试和构建输出。
- 执行完整 Core/Persistence Debug/Release、Node、离线审计/静态检查、Android Release JVM、App 关键流程、原生桌面和真实媒体流程。
- 从准确、干净的 main 提交运行 package-app.sh distribution，使用既有 Developer ID、Hardened Runtime、Keychain 公证 profile 和仓库外私有客户端配置。
- Apple 状态必须 Accepted；staple 并验证最终 DMG/App、Gatekeeper、签名闭包、安装、源码包、SBOM、更新清单及 SHA-256。
- 所有门禁通过后才推送正式分支、创建 v0.9.1 和公开 GitHub Release；验证草稿及公开下载字节。

本次重新执行的测试结果和正式验证状态将在 RELEASE_VALIDATION_0.9.1.md 记录；当前文件不预先声明公证或发布成功。旧候选的测试报告不替代本次发布门禁。

实现与用户可见变化见 RELEASE_NOTES_0.9.1.md、CHANGELOG.md；缓存与性能边界见 OKVideoMac/macOS/OKVideoMac/Docs/PERFORMANCE.md。第三方网盘长时速度、HDR/4K60 及最低支持系统的历史问题不作超出证据的保证。
