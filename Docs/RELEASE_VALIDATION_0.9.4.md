# OKVideoMac 0.9.4（Build 208）正式发布验证记录

[GitHub Release](https://github.com/yaolin-dev/OKVideoMac/releases/tag/v0.9.4) 的标签 `v0.9.4` 指向构建提交 `89455caa1e59fe8f798798b84374420fe0c65112`。此版本适用于 Apple Silicon 与 macOS 12.0 及以上，内含 Android Bridge 0.3.59（71）。

| 验证 | 结果 |
| --- | --- |
| Core Release | 1249 通过，29 项按既有规则跳过，0 失败 |
| App Release | 181 项通过，0 失败或跳过 |
| 定向回归 | 20 项通过，覆盖音量、字幕及音轨切换和崩溃操作记录 |
| 真实媒体 | 15 项使用 208 正式包原生库通过，0 失败或跳过 |
| Node、Android JVM | 分别通过 79 和 85 项 |
| 崩溃诊断 | 8 项单元测试、3 类本机上传夹具通过，3 个正式包 dSYM 已由 Sentry 处理 |
| 托管 CI | [准确构建提交](https://github.com/yaolin-dev/OKVideoMac/actions/runs/43438529734)的 7 个任务成功，机器报告与提交一致 |
| Developer ID | App 和 DMG 验签通过，38 个 Mach-O 的 Hardened Runtime 和嵌套签名通过 |
| Apple Notarization | **Accepted**，提交 `8415bf39-debc-429a-b4f0-70cf2dfc366f` |
| 票据和安装 | DMG 和独立复制的 App 分别 staple，Gatekeeper、只读挂载、完整性及启动测试通过 |
| 公开下载 | 16 项资产的本地、GitHub 及匿名下载 SHA-256 一致，下载的 DMG 和签名 appcast 复验通过 |

本机媒体回归覆盖合成源与项目既有夹具。Android AGP 仍报告 Kotlin 依赖元数据兼容性诊断，JVM 验证和签名 APK 构建通过。

| 文件 | SHA-256 |
| --- | --- |
| `OKVideoMac-0.9.4-AndroidDexBridge-release.apk` | `4b50bdc4e8fb19c78cac55af1acf1702d899e7ed5dc28efc3240d186a8f9c3a3` |
| `OKVideoMac-0.9.4-build208-SHA256SUMS` | `36f52b8c5bb8fc4c3250bfcaadc541ee3e4facbca88ef2a7c6443fe99f6f90d5` |
| `OKVideoMac-0.9.4-build208-SOURCE_RELEASE_INDEX.json` | `f789384c4e17a71e7b271df1fa4e54a784c931ba143dba52a919d15054ab7c69` |
| `OKVideoMac-0.9.4-build208-SOURCE_RELEASE_MANIFEST.json` | `34d2c4d71d0787c077f9a78796b314c75f3fff1871594446d8c6f33b23ea4f6b` |
| `OKVideoMac-0.9.4-build208-licenses.tar.gz` | `9f542f7b0a1db7abe1336d55e4958857c978ee0e538603a120cff43ec2558222` |
| `OKVideoMac-0.9.4-build208-source.tar.gz` | `50acc581ca9d06e19bba20a58318148ba319432c078d31d8bfc53349ea6a2acb` |
| `OKVideoMac-0.9.4-build208-third-party-source.tar.gz` | `342d199af31027a10a45d1dd032464046cb91bb62261e18872d1a7dd80d29af5` |
| `OKVideoMac-0.9.4.dmg` | `2d2ffd84375495c3ce9af815dae2f768b0ea50ece7247ea99b48af9cf4c80813` |
| `OKVideoMac-0.9.4.dmg.sha256` | `f6cdac4b763c112ca881ca3542f7c314d1674ce3c0f2717b1f0e235a300e7cc4` |
| `OKVideoMac-Android.cdx.json` | `752e5edfe979485eaad5dee75e72a446d17b7b27554b8448fb6e9597d3b098f8` |
| `OKVideoMac-Android.spdx.json` | `27a013cffc5d31277f28d963426cdf3ca847c6cf5e103c35c30bc668a97ee05f` |
| `OKVideoMac-macOS.cdx.json` | `914759cc86027e912274e4894d6cc9e06555133a142f14aca71a77d2453647af` |
| `OKVideoMac-macOS.spdx.json` | `fb3cdcefadb710d3d855114c7ab6a6463ee63e7b78cacc2ab6be29fd00ca77e5` |
| `RELEASE_NOTES_0.9.4.md` | `41999e7484e3970a20521213e7386211722aac22400d8f57637f7fc1e8143e36` |
| `THIRD_PARTY_NOTICES.md` | `4096a6a73e88bfc9fa0b93b385ccb0574d85e0ac0aadb993b1e01e2423d12ac9` |
| `appcast.xml` | `4f657337ac29bd2af174240498d337a967084fff9e047fc86ac4992b2e467b34` |
