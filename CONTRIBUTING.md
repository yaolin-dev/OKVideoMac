# Contributing to OKVideoMac

感谢参与 OKVideoMac。请 fork 仓库，从明确命名的分支提交 pull request，并让每个
PR 保持单一、清晰的范围。说明变更目的、验证方式以及已知限制。

## 提交要求

- 不要提交 token、Cookie、账号、私人内容源、用户历史、签名凭据或本机私人配置；
- 保留现有版权、许可证、NOTICE、来源和 provenance 声明；
- 不要静默替换第三方二进制、源码归档、依赖或 lock；相关变更必须说明来源、
  版本、哈希、许可证和构建关系；
- 按变更范围运行相关测试、构建和文档检查，并在 PR 中记录结果；
- 播放器或 runtime 行为变更需要提供针对受影响路径的回归证据；
- 影响许可、对应源码、SBOM 或 provenance 的变更必须同步更新相应记录；
- 不要把未经验证的第三方 artifact 作为可发布二进制提交。

提交到 `main` 的 PR 和 `main` 推送会运行 [CI](.github/workflows/ci.yml)。合入前应确认
`CI required` 及其依赖的 Core Debug/Release、Node、离线审计与静态检查、Android JVM
测试、主 App 无签名 Release 编译全部通过。失败、取消、跳过任务或缺失结果都不能
视为通过。该汇总检查不等于已启用 GitHub 分支保护；本轮没有修改仓库保护规则。

运行方法、工具版本、报告和明确不覆盖的范围见 [CI 指南](Docs/CI.md)。Core 中既有的
条件测试跳过项由测试名和原因白名单约束，不得通过扩大跳过范围掩盖失败。新增测试
会自动发现；更改白名单需解释对应的环境要求，并保留相关的人工验收路径。

维护者仍会按变更风险要求补充实机、播放、兼容性或真实服务验证。CI 的未签名编译
产物仅用于检查，不能安装或发布。发布包必须遵循
[正式发布流程](Docs/SOURCE_RELEASE_PROCESS.md)和仓库 release scripts 的 fail-closed 检查。
