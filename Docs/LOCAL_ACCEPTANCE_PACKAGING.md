# 未提交源码的本地 Release 验收入口

适用于维护者明确授权的本地验收，不是正式发布入口。

```sh
bash OKVideoMac/macOS/OKVideoMac/Scripts/package-local-acceptance.sh
```

沿用标准构建机的 `DEVELOPER_DIR`、`OKVIDEOMAC_BUILD_ROOT`、`OKVIDEOMAC_NODE_RUNTIME` 和锁定第三方源码缓存配置。`OKVIDEOMAC_SOURCE_RELEASE_OFFLINE=1` 可要求只使用已校验缓存。

## 行为与边界

1. 在 `/private/tmp` 创建全新的独立验收目录，不覆盖旧产物。
2. 捕获当前 Git 已跟踪文件（包括未提交修改、排除已删除项、AGENTS.md 和不参与构建的 Docs/DemoSource），以及 App/Helpers/SourceAudit 代码根目录下非忽略的新文件，并明确纳入关键流程回归入口、清单及其验证测试（Tools/CI 中的三个指定文件）。不会将未跟踪的个人 Docs、DemoSource 数据或工作区缓存一并打包。不要把私有数据存放在构建代码目录。
3. 要求处于非 main 的具名开发分支；捕获前后再次检查 Git 身份和输入内容。快照没有 `.git`，不创建 Git commit、不修改原索引或分支。`LOCAL_ACCEPTANCE_SNAPSHOT.json` 保存相对路径、字节摘要、可执行位、完整清单摘要、branch、baselineHEAD、version/build、捕获时间、纳入的 tracked modifications/untracked source；`gitCommitBound=false`、`acceptanceOnly=true`、`publicReleaseEligible=false`，`git_commit` 明确为空。base HEAD 仅作参考，不被宣称为当前源码。仓库/worktree 绝对路径另存为快照旁的 `Source-PRIVATE-PROVENANCE.json`（0600），通过清单 SHA-256 绑定；不进入 App、DMG 或源码归档，以维持绝对路径敏感扫描门禁。
4. 从快照重新构建 APK 与 macOS Release。构建前后重新核对源码清单，源码字节/执行位或未记录输入发生改变即拒绝继续；构建产物不进入源码归档。
5. 复用 `package-app.sh` 的原生依赖处理、法律材料、锁定第三方源码校验、SBOM、APK/DEX 检查、敏感信息扫描、Hardened Runtime 本地 ad-hoc 签名和 bundle 校验。
6. ZIP 解包和本地 DMG 挂载后再次验证 bundle/签名；核对内嵌 source index 和 APK，与外部源码索引逐字节一致。源码归档 SHA-256 记录于内嵌索引；索引明确标记 LOCAL ACCEPTANCE ONLY。DMG 仅用于人工验收，记录于外部 release artifact 清单不表示公开发布。
7. 最终独立 App 仅在前述门禁通过后复制出来，并再次验证。任何失败均不能作为可交付候选。

该入口生成本地验收 DMG，但没有 notarization、安装、Desktop 替换、上传、版本号修改、tag 或公告。产物保留在独立临时目录，供人工体验。临时目录可能被系统清理，可单独保存已验证 DMG/ZIP；私有 provenance 含本机路径，不应公开上传。不要将裸 App 放进可能自动附加 Finder 元数据的同步目录后仍假定签名有效。

默认 `package-app.sh`（不带本地快照 opt-in）以及正式 distribution 流程仍要求 clean worktree/commit。`--local-acceptance` 只能处理有效捕获的快照，且拒绝 distribution/notarization；不能用它给正式发布绕过 clean-worktree 门禁。

## 工程测试

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover \
  -s Tools/SourceAudit -p 'test_local_acceptance.py' -v
bash -n OKVideoMac/macOS/OKVideoMac/Scripts/package-app.sh \
  OKVideoMac/macOS/OKVideoMac/Scripts/package-local-acceptance.sh
git diff --check
```

测试不创建任何 commit，覆盖独立快照、篡改拒绝、路径和 symlink 保护、归档确定性、输入范围、正式 clean-worktree 门禁和 local-only 限制。
