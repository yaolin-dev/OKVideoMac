# OKVideoMac 0.9.1（Build 182）发布就绪记录

2026-11-01：功能与版本保持 0.9.1 / Build 182。本轮 App 222 项、媒体 9 项及原生验收已通过。此前远端构建失败的根因是 CI 下载脚本仅提取 XcodeGen 可执行文件，遗漏 SettingPresets，导致产品名、模块依赖和测试宿主链接设置缺失；前期只核对工具版本号未覆盖这一安装差异。

现已从同一 SHA-256 锁定的官方 ZIP 保留完整工具布局，并在编译前验证测试宿主设置。51 项工具/CI 测试通过；完整官方工具生成的整个项目与已验证的本地项目逐字节一致，缺资源版本会被提前拒绝。先在候选分支运行现有 GitHub CI，成功后才执行正式发布流程。仅 CI 工具与文档变化，不额外递增 App Build；发布包仍须按现有脚本 clean build 并重新绑定最终提交的源码索引、签名和公证。此前候选均未创建正式 Tag/Release。

## 发布门禁

- 从最新 origin/main 整合本轮开源改动，排除商业化代码、私有配置、运行数据、测试和构建输出。
- 执行完整 Core/Persistence Debug/Release、Node、离线审计/静态检查、Android Release JVM、App 关键流程、原生桌面和真实媒体流程。
- 从准确、干净的 main 提交运行 package-app.sh distribution，使用既有 Developer ID、Hardened Runtime、Keychain 公证 profile 和仓库外私有客户端配置。
- Apple 状态必须 Accepted；staple 并验证最终 DMG/App、Gatekeeper、签名闭包、安装、源码包、SBOM、更新清单及 SHA-256。
- 所有门禁通过后才推送正式分支、创建 v0.9.1 和公开 GitHub Release；验证草稿及公开下载字节。

本次重新执行的测试结果和正式验证状态将在 RELEASE_VALIDATION_0.9.1.md 记录；当前文件不预先声明公证或发布成功。旧候选的测试报告不替代本次发布门禁。

实现与用户可见变化见 RELEASE_NOTES_0.9.1.md、CHANGELOG.md；缓存与性能边界见 OKVideoMac/macOS/OKVideoMac/Docs/PERFORMANCE.md。第三方网盘长时速度、HDR/4K60 及最低支持系统的历史问题不作超出证据的保证。
