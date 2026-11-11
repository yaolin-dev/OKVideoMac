# OKVideoMac 0.9.3（Build 204）正式发布验证记录

[GitHub Release](https://github.com/yaolin-dev/OKVideoMac/releases/tag/v0.9.3) 使用版本标签 `v0.9.3` 和准确构建提交 `5b3c2206fd77af20a1a207b0219846928a27e1a7`。Android Bridge 为 0.3.59（71），App 目标为 Apple Silicon、macOS 12.0 及以上。

| 验证 | 结果 |
| --- | --- |
| Core Release | 1249 通过，29 项按项目既有条件跳过，0 失败 |
| App Release | 181 通过，0 失败或跳过 |
| 真实媒体 | 15 通过，0 失败或跳过 |
| Node、Android JVM | 79、85 项通过 |
| 托管 CI | [准确构建提交](https://github.com/yaolin-dev/OKVideoMac/actions/runs/43029952922)的七项任务成功，机器报告一致 |
| Developer ID | App 和 DMG 验签通过，App 的 Hardened Runtime 和嵌套签名通过 |
| Apple Notarization | **Accepted**，提交 `14a18c38-c176-4507-9a7f-a79944e49c7b` |
| 票据和安装 | DMG staple、Gatekeeper、只读挂载、完整性及独立 App 复制、staple、验签和启动测试通过 |
| 发布 | 16 项资产的本地、GitHub 及匿名下载字节数与 SHA-256 一致，下载 DMG 与签名 appcast 再验通过 |

首轮桌面测试因 macOS 锁屏无法取得焦点而失败。解锁后重跑相同 Release 测试宿主和完整测试组。Android AGP 记录 Kotlin 依赖元数据兼容性诊断，JVM 验证通过。实测环境为发布主机，最低部署版本通过包检查。第三方来源的可用性依赖上游及解析配置。

源码包中的 1,208 个文件与准确构建提交的 Git blob 逐一匹配。草稿大文件直连下载速度异常，经本机既有代理重新下载并核对全部 SHA-256 后公开。公开版本再次完成匿名下载和 latest 更新源校验。

| 文件 | SHA-256 |
| --- | --- |
| `OKVideoMac-0.9.3-AndroidDexBridge-release.apk` | `7e0c2f71fbeafe8637230972859726c35264fdae56e8b81d757a0ea341f55763` |
| `OKVideoMac-0.9.3-build204-SHA256SUMS` | `2388999d1f58c3ffec97a6bd472314d5ed72c54dd71f8a986b6ab2e9b38d4205` |
| `OKVideoMac-0.9.3-build204-SOURCE_RELEASE_INDEX.json` | `25ee06e0774cc6f56cd4c3d41d1edee1a3251db390384f1fd45e42d6d135f2cf` |
| `OKVideoMac-0.9.3-build204-SOURCE_RELEASE_MANIFEST.json` | `f12a0e51e263193b3062f923470f04ed9d046ad94494ff5dbb494bda4781ea90` |
| `OKVideoMac-0.9.3-build204-licenses.tar.gz` | `88d146d8fa5f54639f7cb5b64f75b6c7a6a40fa8b0c9fef7c4ee7c5de22cca08` |
| `OKVideoMac-0.9.3-build204-source.tar.gz` | `3471bc5bab083b2a92c19a01f3bee9cddbc5663d34b075d153b57c432d54c161` |
| `OKVideoMac-0.9.3-build204-third-party-source.tar.gz` | `ec6c1a1426b7fa35bcd56894c82e0002579a5d129bbe25b5c5a2aea89ff052e6` |
| `OKVideoMac-0.9.3.dmg` | `3656ac54490df7cd6778022e3f7bd7b454b86b49fcbb4598abe5578588807181` |
| `OKVideoMac-0.9.3.dmg.sha256` | `63306f9801cba05783fe80a7cf8d65608eadfc573daf6a6576c03d425a53014f` |
| `OKVideoMac-Android.cdx.json` | `67f9184004e859906304acf9482e0b4daeccb15cc3d92657ffc8cc164fa6598e` |
| `OKVideoMac-Android.spdx.json` | `92992e89a90911d163d0e8a936c37a69f18df21aa832665c7b222d70b3c605a1` |
| `OKVideoMac-macOS.cdx.json` | `57bdb61fcea6ec48996e8efd18e0b17d6b90150b23b5050170b3726dfadbfa10` |
| `OKVideoMac-macOS.spdx.json` | `955d9bbda9e5a63f6ce3dc3cfdf68b08f576e7d30b7e06cd092b2030333d0055` |
| `RELEASE_NOTES_0.9.3.md` | `2bb0656bb2ae1c138269f81250ab3ce689080735aa67f19fd37b996857950aee` |
| `THIRD_PARTY_NOTICES.md` | `4ea8160c6de3155cb47504d61bca1cb8d9f631fc4c02e1bedd317f04cfd0c087` |
| `appcast.xml` | `61e4aa71853c58c39323c49a9043586b29ab6b1857a407d72c72c1c14dd425dc` |
