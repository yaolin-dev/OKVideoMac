# DMG Release Process

OKVideoMac 0.4.0（Build 94）的正式用户下载格式固定为
`OKVideoMac-0.4.0.dmg`。ZIP 仅为内部归档，不是 GitHub Release 的主下载。

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

无凭据时允许执行 Developer ID signed RC DMG 验证，但不得宣称 Apple 公证、
staple 或 Gatekeeper 已完成。凭据只通过 Keychain profile 提供，不进入脚本、
仓库、日志或发布资产。

```sh
export DEVELOPER_ID_APPLICATION='Developer ID Application: Name (TEAMID)'
export OKVIDEOMAC_NOTARY_PROFILE='okvideomac-notary'
OKVideoMac/macOS/OKVideoMac/Scripts/package-app.sh \
  --mode distribution \
  --notarize
```

## RC 与正式发布边界

分支上的 RC DMG 仅用于确认流水线。PR 以 Merge Commit 合入 `main` 后，必须从
该 exact merge commit 重新构建 App、DMG、source release、SBOM 和 checksums，
完成公证与安装 smoke test 后才允许创建 `v0.4.0`。不得把分支 RC DMG 直接
复用为正式发布资产。
