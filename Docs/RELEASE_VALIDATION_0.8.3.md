# OKVideoMac 0.8.3（Build 136）正式发布验证记录

日期：2026-10-09。GitHub Release：[v0.8.3](https://github.com/yaolin-dev/OKVideoMac/releases/tag/v0.8.3)，非 Draft、非 Prerelease、latest。

## 不可变身份与本轮修改

- exact release commit：`2d00518dbdf0eba6f91c60483d522fd10e7bee3d`；从干净 main 经现有 `package-app.sh --mode distribution --notarize` 重新构建，annotated tag v0.8.3 固定同一提交。
- App 0.8.3（136）；Android Bridge 0.3.48（60），native 库未升级。
- 公开 AppKit 分栏接口实现零宽分隔；左右保持独立原生材质，页面背景保留顶部安全区。稳定窗口持有的侧栏按钮，恢复原生搜索外观和提示，子 host 实时继承窗口主题。
- APK 缺失显式归类为资源错误，Release embed phase 缺失资源失败；不重置用户数据、登录、私钥或备份。
- 商业工作树保留原状。发布后仅补录文档，不移动 tag、不重签或修改 DMG、appcast、源码包和构建时说明快照。

## 本次回归

合计 2,426 通过、40 条件跳过、0 失败。条件跳过不计为通过。

| 项目 | 结果 |
| --- | --- |
| Release App XCTest | 1,249 项：1,232 通过、17 条件跳过、0 失败 |
| OKVideoKit | 1,036 项：1,014 通过、22 条件跳过、0 失败 |
| AndroidRuntimeKit | 68 项：67 通过、1 条件跳过、0 失败 |
| SourceAudit / Node | 32 / 47 项全部通过；含独立签名 launcher fixture |
| Android Bridge JVM / lint | 34 测试通过；App 0 error / 8 warnings，catvod 0 error / 3 warnings（既有） |
| 实际 App Android | 当前 Release 测试 App 的真实 SDK 启动、Bridge ready、adbEmuKill 关闭及 App 退出通过；私有 ADB 监听已关闭 |
| Release 资源门禁 | 真实 embed phase 缺失 APK 返回 1；正常正式包包含校验通过的 APK |
| 最终 DMG / 安装 smoke | QuickJS、MPV/FFmpeg、Node/V8 与 App 启动通过 |
| 公开资产 | 16 个本地 SHA-256、GitHub digest 与匿名下载逐项一致 |

侧栏回归覆盖浅深色、三种宽度、五个导航页的整窗标题栏边界像素、两栏边界相等（0.001 pt）、独立材质、按钮持续挂载和坐标稳定、折叠展开、搜索提示像素对比及主题最初三个绘制帧。

首轮发现先前误改的播放器恢复预期，恢复原始不透明标题栏断言；第二轮进程夹具在 1 秒就绪等待处超时，改为最多 5 秒并增加诊断，保留全部身份断言。实际 Android 报告已成功后，测试入口在 actor 内调用 AppKit 退出阻塞异步清理，独立对照确认主派发队列也会阻塞，最终改为 RunLoop 定时回调请求退出并重新验证。原始失败日志保留；没有删除失败用例或放宽生产身份检查。条件跳过不计通过。测试模式入口不进入正式二进制。

## 时间戳代理故障与恢复

首次正式打包因 Apple 时间戳服务不可用而停止，未发布或安装失败包。实际 RFC 3161 请求确认：当前 HTTP 代理截断响应，直连和 SOCKS 返回完整响应。仅临时为 `timestamp.apple.com` 加入活动网络服务的代理例外，Developer ID 探针随即通过；正式流程按原有 secure timestamp 策略重跑，完成后原样恢复代理例外。未关闭时间戳、改用第三方时间戳服务器或降低签名、公证门禁。

## 签名、公证及最终产物

- Developer ID Application: Yao Lin (KGG363ABK9)，34 个 Mach-O 精确 inventory、secure timestamp、Hardened Runtime、entitlements、嵌套签名、动态依赖与 codesign deep/strict 全部通过。
- Apple notarization **Accepted**，submission `105f049e-55f9-4c61-b365-e5dab1ab3f9f`；Apple log 无 issues。
- 最终 DMG staple、stapler validate、codesign 通过；DMG、盘内 App 与全新安装 App 的 Gatekeeper 均为 Notarized Developer ID。
- 只读挂载 DMG，精确两项布局、App 版本/Build、source index、APK、bundle/SBOM 验证通过；打包、盘内与安装副本的文件字节、链接和可执行位一致。
- 正式包稳定更新配置通过；最终 appcast 使用既有公钥，版本 136 高于旧稳定版，URL 固定 v0.8.3/OKVideoMac-0.8.3.dmg，长度、EdDSA 与最终 DMG 匹配。公开 latest feed 字节一致；公开下载 DMG 再次通过 staple/Gatekeeper。未宣称本轮重新执行旧版原生更新窗口或完整安装全流程。
- 桌面入口指向 ~/Applications/OKVideoMac-Release083-build136/OKVideoMac.app；安装的是最终已验证 Release。
- 对应源码、许可证、APK、四份 SBOM、index/manifest/checksums 与最终敏感信息扫描通过。ZIP 仅为内部身份载体，不上传。

## 公开文件 SHA-256

| 文件 | SHA-256 |
| --- | --- |
| `OKVideoMac-0.8.3-AndroidDexBridge-release.apk` | `19fdb27d8f800479a8e430842bdf464a702579c2b0eec69e1d73ac768c29d112` |
| `OKVideoMac-0.8.3-build136-SHA256SUMS` | `c9e00de71265c637834f9ea2d656cf2edab05a1f859e53187b984c9b5aac2c3a` |
| `OKVideoMac-0.8.3-build136-SOURCE_RELEASE_INDEX.json` | `990585e611a9c51484cc443ae953aeb76941710022a9ba2681e8068be32098bf` |
| `OKVideoMac-0.8.3-build136-SOURCE_RELEASE_MANIFEST.json` | `887dc44787ee6e27913505113a74f587d4ba87b419ecec4cc386ac21ccda636c` |
| `OKVideoMac-0.8.3-build136-licenses.tar.gz` | `cf4f040ba1aa21aab998e44fd323b1ef840882b450c4b51cbd6f3f3040ce1ce3` |
| `OKVideoMac-0.8.3-build136-source.tar.gz` | `ccda78636e2bb6032ba22d8cbf5c44853253950385cd3ad1643deedab240bb00` |
| `OKVideoMac-0.8.3-build136-third-party-source.tar.gz` | `5c07f057fae47dc180bb6e2073493738e598912ba88c7f09f8b37908d811642b` |
| `OKVideoMac-0.8.3.dmg` | `4f5352fc717c7e514d7840ae4ce5394eb309291b309d6df97ea67f0b23bc3697` |
| `OKVideoMac-0.8.3.dmg.sha256` | `5bfee89a95045814a63074b2c7553dd773edf50b7be34bd8ae9c02bb46e4069b` |
| `OKVideoMac-Android.cdx.json` | `4cab628840d4430bd7fe73c192451a9ad7a2712390f0018617771b24e0c0f596` |
| `OKVideoMac-Android.spdx.json` | `be37b7645ef891c1bb77ffba167ded5e5b52b0837c32e6f31e07785595798c43` |
| `OKVideoMac-macOS.cdx.json` | `782230fc649891e5dcf3d573c4a573f5cae2edf502f00f6bd7c30d0842c6bd62` |
| `OKVideoMac-macOS.spdx.json` | `1974be9b9f21b7a8f30e6c4baf94f50cf7656f0e2549429d02813fa7bc52bdc2` |
| `RELEASE_NOTES_0.8.3.md` | `d1a811828d6b4babafaa12bf5b580913828868a3e6434e299503f363f2abc5dd` |
| `THIRD_PARTY_NOTICES.md` | `8556a0ed2ab0fef4ffecc43580f48518521b10298a4674f01738d923144b0c98` |
| `appcast.xml` | `ad6f39061cd1edec7b18d08da47d72edf9a5024d36f4c42f0b1d0b5accbf1717` |

## 文档与覆盖边界

README 英文/中文、应用 README、CHANGELOG、技术记录、Android 资源说明、构建、兼容性、性能、发布/源码/SBOM 流程、自动更新、就绪和本验证记录已同步。历史发布结果与资产保留。

- Mission Control 人工合成、云盘账号、完整真实第三方站点矩阵、真实蓝牙硬件和人工听音：本轮未自动验收。AppKit cacheDisplay 不等同 Mission Control 实景合成。
- 完整 24 小时自动更新周期和更新下载替换安装端到端：未另行执行。
- 仅支持 Apple Silicon / arm64、macOS 12.0+；既有 Swift/SwiftUI 与 Android lint warnings 保留，未当作错误隐藏。
- 原始 zlib distfile、历史 clang 输入等 native provenance 例外继续记录；未宣称全部输入完全可复现。
- 本机现有 HTTP 代理对 Apple 时间戳响应的截断问题未修改代理软件；签名及验收通过临时域名直连完成，原代理配置已恢复。后续签名仍需使用完整响应的网络路径。
- 无已知正式发布阻塞问题。
