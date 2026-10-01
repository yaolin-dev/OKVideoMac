# DMG Release Process

OKVideoMac 0.8.0（Build 130）的正式用户下载格式固定为
`OKVideoMac-0.8.0.dmg`。ZIP 仅为内部归档，不是 GitHub Release 的主下载。

0.8.0（Build 130）已完成下方正式流水线并公开发布。Tag `v0.8.0` 固定
`b049b381db52b5bbbeec9cf58bf54a5bd50a4f39`；Apple notarization `Accepted`，Submission：
`bc1f6ef5-5d19-4888-91f9-dbf5737d865d`。最终 DMG SHA-256：
`f082a380ffb1d2d059f228e0b6f0d7b59424f80edff57e81230d2efe6496b97a`。
详见 [0.8.0 正式验证记录](RELEASE_VALIDATION_0.8.0.md)。

## 0.7.3 / Build 129 已完成验证

Tag `v0.7.3` 固定提交 `55ffa9d55faced404b20034d7cfe5bcfbc1be581`。
Developer ID、Apple notarization `Accepted`、Staple、Gatekeeper 与安装 smoke 均已完成。
Submission：`133c1043-d3b8-429a-b502-6dc586de6ab9`。最终 DMG SHA-256：
`9cf6c79f9c6d4a8bc7e37e72612e3debc98ca22ffffc3e5e9084c61efe42dbfc`。
此状态据 [GitHub Release](https://github.com/yaolin-dev/OKVideoMac/releases/tag/v0.7.3) 补录。

## 0.6.1 / Build 101 已完成验证 / Verified release

Tag `v0.6.1` 固定提交 `25155f52fb8c416f3245c9a829a93175dec9857b`。正式 DMG 已通过
Developer ID、Apple notarization `Accepted`、Staple、Gatekeeper 与安装 smoke。
Submission：`6da1497c-d7c2-4e0f-b19c-3498e244ffa2`。
最终 DMG SHA-256：`3fcaa402e434298a9fa224c9c4d8f3530be71278c4f0d99629dad40cc6a619f5`。
详细结果见 [0.6.1 验证记录](RELEASE_VALIDATION_0.6.1.md)。

The 0.6.1 DMG passed Developer ID signing, Apple notarization, stapling, Gatekeeper
and installation smoke tests. The tag pins the release commit above. Later documentation
updates preserve the signed binary, tag and build-time source/notes snapshots.

## 复用现有凭据 / Reuse existing credentials

先只读核对既有 Developer ID 和 `OKVideoMac-Notary`。工具沙箱内查询可能返回假阴性；
在判断凭据缺失或要求重新输入前，须在获准的宿主上下文复核。0.7.3 与 0.8.0 的正式
发布均直接复用已可用的同一签名身份与公证 profile，未重新导入证书或修改钥匙串。
只有确认缺少可用签名身份、确需从备份导入时，才执行下方临时专用钥匙串流程。

Check the existing identity/profile in the authorized host context before importing
anything; sandbox-only checks can return false negatives. The 0.7.3 and 0.8.0
releases reused the available signing identity and notary profile. The temporary
keychain procedure below applies only when a certificate backup must be imported.

## 临时专用钥匙串 / Temporary dedicated keychain

1. 只读核对既有证书备份与此前发布证书身份，保存原 keychain search list 和 default。
2. 在临时目录创建本次发布专用 keychain，使用随机密码，不改变默认 keychain。
3. 将既有 `.p12` 仅导入该临时 keychain；通过本机安全界面取得密码，禁止放入聊天、
   命令参数、脚本、日志或仓库。核对 Developer ID Application 身份和证书指纹。
4. 仅对该 keychain 配置 codesign 所需的 key partition access。本次签名如需把它加入
   search list，保留其他条目并设置成功、失败及中断均执行的清理。
5. 复用 `OKVideoMac-Notary`；不重新创建证书或 notary credentials，不向
   login/default/system 导入证书或私钥。按下方 distribution 流程完成所有门禁。
6. 结束时恢复原 search list、删除临时 keychain，并复核 default 与 search list。
   清理失败必须明确报告，不能宣称已恢复完成。

Import the existing signing certificate only into a temporary dedicated keychain.
Capture the original search list/default first, use local secure password entry,
verify certificate identity, and grant codesign partition access only there. Keep
the default keychain unchanged. If the temporary keychain is added to the search
list, restore the original list on success, failure or interruption, delete the
temporary keychain and verify cleanup. Reuse `OKVideoMac-Notary`; do not create
certificates/profiles or import into login/default/system keychains.

Apple 时间戳服务的明确瞬时错误允许有上限重试；不得移除 `--timestamp` 或忽略签名错误。
Bounded retries may handle explicit transient timestamp-service failures; timestamp
requirements and all other signing errors must remain enforced.

## Pipeline

`OKVideoMac/macOS/OKVideoMac/Scripts/package-app.sh` 必须从干净 Git commit
执行，并按固定顺序完成：

1. Release / arm64 / macOS 12.0 构建；
2. 复制并规范化全部嵌套 Mach-O 与 Android Bridge APK；
3. 从内到外进行 Developer ID signing，并验证 Hardened Runtime、entitlements、
   架构、deployment target 和动态依赖闭包；
4. 生成并嵌入 source-side index、许可证、provenance 和四份 SBOM；
5. 创建只含 `OKVideoMac.app` 与 `Applications -> /Applications` 的 UDZO DMG；
6. 使用同一 Developer ID Application identity 签名 DMG；
7. 只读挂载 DMG，验证布局、版本、Build、App 签名和内嵌 source index；
8. 使用 `notarytool` 提交最终 DMG，并要求结果严格为 `Accepted`；
9. staple DMG、执行 `stapler validate`，再验证 DMG 与盘内 App 的 Gatekeeper；
10. 保留现有 ZIP 内嵌 source index / APK 的 identity 校验，把 ZIP 作为内部
    archive carrier；再将最终 DMG、源码归档、SBOM、notices、APK 和 manifest
    通过外层哈希绑定进统一 SHA256SUMS。

无凭据时允许执行 Developer ID signed 预发布 DMG 验证，但不得宣称 Apple 公证、
staple 或 Gatekeeper 已完成。凭据只通过 Keychain profile 提供，不进入脚本、
仓库、日志或发布资产。

```sh
export DEVELOPER_ID_APPLICATION='Developer ID Application: Name (TEAMID)'
export OKVIDEOMAC_NOTARY_PROFILE='OKVideoMac-Notary'
OKVideoMac/macOS/OKVideoMac/Scripts/package-app.sh \
  --mode distribution \
  --notarize
```

## 预发布与正式发布边界

分支上的预发布 DMG 仅用于确认流水线。开发分支以不重写历史的 merge 或可审计的
fast-forward 进入 `main` 后，必须从 `main` 的 exact release commit 重新构建
App、DMG、source release、SBOM 和 checksums，完成公证与安装 smoke test 后才
允许创建 `v0.8.0`。不得把分支预发布 DMG 直接复用为正式发布资产。

## 0.4.0 历史正式发布记录

- exact commit：`f93d74fed86e3e2ffcfa4888c521a10f8e3e86f3`
- tag：`v0.4.0`
- DMG：`OKVideoMac-0.4.0.dmg`
- DMG SHA-256：`60b2eebc607be9cc21c8207c913b09544546f5b6b843db801873651ceaf427ea`
- notarytool profile：`OKVideoMac-Notary`
- notarization submission：`d9db5bae-1ae9-4d0d-9e63-3ca378235e6a`
- 结果：`Accepted`；staple、`stapler validate`、盘内 App Gatekeeper 与干净安装
  smoke test 均通过

该资产已作为非 Draft、非 Prerelease 的 GitHub Release 发布。后续文档 commit
不会重写、重签或重新公证这份不可变的 0.4.0 DMG。
