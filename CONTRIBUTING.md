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

仓库没有在本文件中承诺特定 CI 必过项；maintainer 会根据变更风险要求补充验证。
发布包仍必须遵循 `Docs/SOURCE_RELEASE_PROCESS.md` 和仓库 release scripts 的
fail-closed 检查。
