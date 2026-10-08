# OKVideoMac 0.8.2（Build 135）正式发布验证记录

日期：2026-10-08。GitHub Release：[v0.8.2](https://github.com/yaolin-dev/OKVideoMac/releases/tag/v0.8.2)，非 Draft、非 Prerelease、latest。

## 不可变身份与修改

- exact release commit：`42be0560a168a949d7f7b61e1c3837a8b4aab189`，从干净 main 执行正式打包；annotated tag v0.8.2 固定同一提交。
- App 0.8.2（135）；Android Dex Bridge 0.3.48（60），native 运行库均未升级。
- 根因：旧“备份并重建”遗漏 compatibility 指纹，新镜像可被旧 system-image 指纹拒绝，失败缺少整体回滚和终态清理。增加 AVD/INI/指纹/关联记录事务备份、失败和中断恢复、镜像固定、AVD 卷空间检查及进度任务终态处理；SDK/image/ABI/Emulator 身份校验未放宽。
- 25 个实现、回归、版本和文档文件在发布提交内；仅开源工作树修改。历史 0.8.1 验证文档的本机路径改为 ~/Applications 表述，历史结果与资产不变。
- 发布后文档状态补录不移动 tag，不重签或修改 DMG、appcast、源码包及构建时说明快照。

## 本次自动回归

| 项目 | 结果 |
| --- | --- |
| Release App XCTest | 1,242 项：1,225 通过、17 条件跳过、0 失败 |
| OKVideoKit | 1,036 项：1,014 通过、22 条件跳过、0 失败 |
| AndroidRuntimeKit | 68 项：67 通过、1 在线安装跳过、0 失败 |
| SourceAudit | 32 项全部通过，含独立签名 launcher fixture |
| Node / CatPaw / Quark | 47 项通过 |
| Android Bridge JVM / lint | 34 测试通过；0 error、8 个既有 warnings |
| 新隔离 Emulator | default→google_apis 重建、Bridge、停止、再次启动通过；旧备份与新指纹正确，0 残留进程/私有监听/锁/未完成事务 |
| 最终 DMG / 安装副本 smoke | QuickJS、MPV/FFmpeg、Node/V8 和 App 启动通过 |
| 发布资产 | 16 个本地 SHA-256、GitHub digest、匿名下载字节全部一致 |
| 旧版更新检测 | 正式 0.8.1（134）原 App 的原生检查更新窗口实际检测到 0.8.2（135） |

11 个事务测试覆盖移动失败、回滚失败再恢复、中断、损坏记录、缺少原文件、无旧指纹及互斥；App 回归包含 50 轮重建/恢复。首次 launcher fixture 编译漏 -parse-as-library，修正编译命令后 32 项全部重跑通过。草稿按 tag 查询返回 404 后按已存在 draft ID 继续上传，未创建重复草稿。公开下载首次因本机代理端口变化中断，重新读取既有代理配置后补齐下载并完成同一验证。原始记录保留，没有删除测试或降低断言。

条件跳过不计通过；真实隔离 Emulator 另行实际执行。旧版 native 检查更新证明 feed/版本兼容，不宣称执行过完整 24 小时定时周期或本次 Sparkle 下载替换安装全流程。

## 签名、公证与最终产物

- Developer ID：Developer ID Application: Yao Lin (KGG363ABK9)；34 个 Mach-O 精确 inventory、secure timestamp、Hardened Runtime、entitlements、动态依赖、codesign deep/strict 全部通过。
- Apple notarization **Accepted**，submission `a086cfe3-5803-45e1-b37b-b31889724c9d`；Apple log 无 issues。
- 最终 DMG staple / stapler validate / codesign 通过；DMG 与盘内 App、全新安装 App 的 Gatekeeper 均为 Notarized Developer ID。
- 只读挂载 DMG，版本、Build、source index、APK 身份、bundle/SBOM 校验通过。安装副本与盘内 App、打包 App 的文件字节、符号链接和可执行位一致。
- 公证后生成 signed appcast，使用 0.8.1 相同公钥；版本 135 > 134，enclosure 固定 v0.8.2/OKVideoMac-0.8.2.dmg，长度和 EdDSA 签名匹配。生成和验证前后 DMG 哈希不变。
- 公开 latest appcast 实际为 0.8.2（135），与固定版本文件字节一致。公开下载 DMG 再次通过签名、staple、Gatekeeper。
- 桌面入口指向 ~/Applications/OKVideoMac-Release082-build135/OKVideoMac.app；此前本地候选保留。
- libmpv UUID 仍为 342C8BC5-C6E1-374D-A04E-9AE9BEDE7800，包内库来源验证通过。
- 对应源码/许可证/四份 SBOM/170 Maven modules、APK、index/manifest/checksums 与敏感信息扫描全部通过；ZIP 保留为内部身份载体，不上传。

## 公开文件 SHA-256

| 文件 | SHA-256 |
| --- | --- |
| `OKVideoMac-0.8.2-AndroidDexBridge-release.apk` | `19fdb27d8f800479a8e430842bdf464a702579c2b0eec69e1d73ac768c29d112` |
| `OKVideoMac-0.8.2-build135-SHA256SUMS` | `bb90615459dbdcbdeaa40d009d1bbdfd0b0c0a7143dc79b2bf926fb1f832fdab` |
| `OKVideoMac-0.8.2-build135-SOURCE_RELEASE_INDEX.json` | `a7404859e8e25fce6c291a337712e960d8ada3dff29af2e3695fc77dc774b491` |
| `OKVideoMac-0.8.2-build135-SOURCE_RELEASE_MANIFEST.json` | `011c4264db5083485a2d73b70c21cfcab0136daf6ad074b8f55fb9efbed82514` |
| `OKVideoMac-0.8.2-build135-licenses.tar.gz` | `d3931918aa88e380517d97489fd510d18ceb11c981935ecddaaa3d2e305537c3` |
| `OKVideoMac-0.8.2-build135-source.tar.gz` | `9078bb1205da6e4497be422545fa73e93c23893d0d3d58ff26e80a7aff0d39f8` |
| `OKVideoMac-0.8.2-build135-third-party-source.tar.gz` | `9ccf0462a4eecc6a825ab833214d719b471eccb7efb37797e5c9d5602aabe488` |
| `OKVideoMac-0.8.2.dmg` | `65e214a912f7f764ce731e84cdd82adc3561bfab681896e3cbbf7b03db1428f3` |
| `OKVideoMac-0.8.2.dmg.sha256` | `03e0362006e93b3a393361e8ba03bb05cbaa81775427e6b0a03566565d755e1d` |
| `OKVideoMac-Android.cdx.json` | `98406d83ef24646f0a63b7fe9b6737c73d924e6595ccd7a8147c8f6df2a6cbe4` |
| `OKVideoMac-Android.spdx.json` | `ac7860821f8a98645aa0d7f7e590df1ebc9474aa5a3198ae777393173e703ec3` |
| `OKVideoMac-macOS.cdx.json` | `4e7355571cc694fe5ed1fa7270aa11816b7478a5d0d4765308d60d1fe6626f4a` |
| `OKVideoMac-macOS.spdx.json` | `48b4f1c92aa652ea2ba03044968756e08481558f053ba2ff3a4bec97a5eebae3` |
| `RELEASE_NOTES_0.8.2.md` | `6007dd70513f2b659c0c4518b7e9a50afd480a84e4e0f70e0f6668f57bc8b204` |
| `THIRD_PARTY_NOTICES.md` | `7718fdc11ce29fdbdf6cc06331b36034ab6733dc63cf3b3b45dd99495057e3b4` |
| `appcast.xml` | `065c6aee834fd5aa6ff4defbb2c5e18b51b2fe7ff1704b455f9dae8d2242fd5d` |

## 文档与更新路径

README 英文/中文、应用 README、CHANGELOG、发布/源码/SBOM 流程、构建、兼容性、性能、就绪、验证及自动更新说明同步到本版。历史 0.8.1 更新功能说明保留为历史，下载和当前版本链接指向 0.8.2。0.8.0 没有 Sparkle，本地测试源不能自动转入正式稳定源，仍需手动安装正式版。

## 已知限制

- 云盘账号人工登录、完整真实提供方矩阵：NOT_TESTED。此前恢复的原始备份保留，数据文件恢复和 Emulator 就绪不等同云盘登录验收。
- 真实蓝牙硬件本轮未重跑；NOT_TESTED：AirPods 连接、摘下/断开 AirPods、蓝牙设备重连、系统输出设备切换、人工听音。此前用户反馈不冒充本次自动结果。
- 只支持 Apple Silicon / arm64、macOS 12.0+；条件跳过和既有 lint warnings 保留原样。
- 原始 zlib distfile、历史 clang 输入等 native provenance 例外继续明确记录，未宣称全部第三方输入完全可复现。
- 本轮没有已知正式发布阻塞问题；定时完整周期与本版更新安装端到端未另行执行。
