# DMG Release Process

OKVideoMac 0.5.0（Build 99）的正式用户下载格式固定为
`OKVideoMac-0.5.0.dmg`。ZIP 仅为内部归档，不是 GitHub Release 的主下载。

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
允许创建 `v0.5.0`。不得把分支预发布 DMG 直接复用为正式发布资产。

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
