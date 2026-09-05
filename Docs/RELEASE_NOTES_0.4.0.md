# OKVideoMac 0.4.0（Build 94）Release Notes

发布日期：2026-09-05

正式 Tag：`v0.4.0`

平台：Apple Silicon / arm64 / macOS 12.0+

相比 0.3.41，0.4.0 不只是版本号升级。它重整了从导入配置、搜索、详情、播放到
授权恢复和发布验证的整条链路，并把用户可见体验进一步收敛到原生 macOS 行为。

## Native macOS Experience

- 首页、搜索、详情、点播、直播和设置拥有更清晰的层级、工具栏和状态反馈。
- 配置与网盘授权使用真正的 macOS Window Sheet；父窗口由系统统一压暗并禁止误触，
  焦点、Esc、键盘和辅助功能行为也由系统接管。
- 搜索页返回按钮固定可见，并与 Esc、Command-[ 使用相同的逐层退出规则。
- 界面交互优先采用系统动画与控件语义，并尊重“减少动态效果”。

## Search & Detail

- 聚合搜索按 session 隔离多个站点；取消搜索后保留已经返回的内容。
- 搜索中第一次返回会立即停止，第二次返回进入搜索前页面；迟到结果不会让搜索复活。
- 详情加载绑定配置、站点、影片和请求代际，快速切换时旧回调不能覆盖新页面。
- 长剧集采用分段浏览，已覆盖 120 集、多线路与历史恢复。

## Playback & Live TV

- 改进播放器窗口打开、关闭、重开、布局恢复和完整销毁。
- 缓冲状态、Seek 确认、自然 EOF 自动下一集和失败重试更可靠。
- 点播线路与直播换台具备旧请求隔离，已切走的任务不能重新接管播放器。
- M3U、TXT、JSON 直播导入及 XMLTV EPG 继续作为无需 Android 的原生能力。

## Source Compatibility

- Native CMS JSON：Supported；CMS XML 与 Native type 4：Partial。
- 符合当前接口的部分 QuickJS 和 CatVod/FongMi 风格脚本：Selected。
- CatVod/CatPaw 风格 Node 视频接口兼容子集：Selected。
- Java/Dex `csp_`：Experimental，需要外部 Android 环境和可选 Android Bridge。
- Android Bridge 强化了专用 AVD、运行时所有权、APK 版本与签名契约。

这些状态描述具体接口覆盖，不代表兼容 TVBox、FongMi、CatPawOpen 或其他生态的
全部配置和源。

## Cloud & Authorization

- 缺失或失效凭据会打开准确的网盘授权界面，而不是显示通用播放器错误。
- 授权成功后只自动重试原播放一次；用户取消、切换影片或切换账号后会丢弃旧回调。
- 夸克使用稳定账号身份绑定转存账本，不再把会轮换的完整 Cookie 当作账号主键。
- 账本缺失、FID 失效或并发创建冲突时，会先发现并复用已有目录。
- 清理仍只删除 receipt 记录的准确 `savedFID`；不会清空、重命名或合并整个云端目录。

## History, Backup & Safety

- 收藏、历史和播放恢复保留原配置与站点身份，减少切换配置后的串源。
- 配置与历史支持便携备份/恢复，导入会验证数据格式和状态所有权。
- 远程 Node bundle 继续要求来源、版本与 SHA-256 信任信息；日志和发布门禁会检查
  Cookie、Token、私人 URL 与本机路径泄漏。

## Release & Open Source

- 用户正式下载为 `OKVideoMac-0.4.0.dmg`，内容只有 `OKVideoMac.app` 与
  Applications 链接。
- DMG 使用 Developer ID 与 secure timestamp 签名，Apple notarization 状态为
  `Accepted`，并通过 staple、`stapler validate` 和 Gatekeeper。
- 内部 ZIP 继续承担 binary verification/archive carrier，不替代用户 DMG。
- DMG、ZIP、对应源码、四份 SPDX/CycloneDX SBOM、Notices 和 Android Bridge APK
  由 manifest 与 `SHA256SUMS` 绑定到 exact commit。
- 发布门禁验证 28 个 arm64 Mach-O。自动化基线为：Xcode 584 项中 582 通过、2 项
  按设计跳过；OKVideoKit 173 项、Node 30 项、Android instrumentation 70/70；
  Android Release assemble 与 lint 通过。

## 下载与验证

请从 [v0.4.0 正式发布页](https://github.com/yaolin-dev/OKVideoMac/releases/tag/v0.4.0)
下载 DMG，打开后将 App 拖入 Applications。不要关闭 Gatekeeper 或 SIP。

| 发布身份 | 值 |
| --- | --- |
| Version / Build | `0.4.0 (94)` |
| Exact commit | `f93d74fed86e3e2ffcfa4888c521a10f8e3e86f3` |
| DMG SHA-256 | `60b2eebc607be9cc21c8207c913b09544546f5b6b843db801873651ceaf427ea` |
| Source SHA-256 | `eb7c8a812d9a54907f99d8656198b7227bfe19b1b29836953e768d4fe858a8f3` |
| Notarization submission | `d9db5bae-1ae9-4d0d-9e63-3ca378235e6a` |

## 已知限制

- 不支持 Intel / x86_64 / Universal Binary。
- Java/Dex 兼容仍为 Experimental，并依赖外部 Android SDK、ADB、Emulator 与
  arm64 system image。
- 第三方 Spider、网页和网盘接口可能独立变化，无法保证任意源长期可用。
- TVBox/FongMi 顶层 `lives`、catchup/timeshift、parser type 2/3/4 和 DRM 不支持。
- TMDB metadata/detail enhancement 延期到未来版本。
- 大型旧数据库升级可能出现一次性启动停顿。
- 原生第三方可复现性仍明确保留 zlib 精确归档不可用，以及历史 MacPorts
  libc++/libc++abi 输入未恢复两项披露。
