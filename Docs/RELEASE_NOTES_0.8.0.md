# OKVideoMac 0.8.0（Build 130）Release Notes

0.8.0 改进部分 TVBox Java/Dex 配置与登录交互、CatPaw 搜索与详情、播放器控件和
自动连播，并修复私有 Android Runtime 在 ADB 绑定变化后的恢复。
本说明以已发布的 `v0.7.3`（Build 129，提交
`55ffa9d55faced404b20034d7cfe5bcfbc1be581`）为对比基线。

## 与 0.7.3 的主要区别

| 场景 | 0.7.3 的行为或问题 | 0.8.0 的变化 |
| --- | --- | --- |
| TVBox 配置卡片 | 部分配置详情会按普通影片处理；无窗口或延迟弹窗的操作可能持续等待 | 识别支持的配置 Provider；卡片显示准备进度与取消；有实际原生交互时才打开交互页，无窗口动作可完成 |
| 播放时要求登录 | Spider 可能先返回错误、随后才显示登录窗口，当前播放请求不能可靠继续 | 保留同一次播放与原生登录交互；确认后最多重新解析一次同一集，只有有效媒体结果才继续 |
| CatPaw 详情 | Node 配置缓存写入造成 revision 变化，可能替换 Provider 并打断详情 | 区分缓存写入与配置语义变化；缓存失效不取消当前页面请求，真实来源变化仍要求重试 |
| 重复与慢站搜索 | 相同搜索可能重启；末批结果的合并更新可能等待下一次响应 | 有界短期缓存、同一搜索复用、Node 站点次序调整及定时发布结果；所有选中的可执行站点仍会尝试第一页 |
| 文件名连播 | `ZIYA 22.mkv` 等无明确“第 X 集”标记的文件名不能可靠组成连播队列 | 同季同版本列表中依据唯一集号建立顺序，支持前缀变化、倒序和已建立序列中的缺集 |
| 播放结束与重播 | 历史恢复未取回完整列表时可能提前判定无下一集；结束后直接恢复播放可能停在末帧 | 自动切集等待列表恢复；结束面板说明队列状态并允许重载；重播创建新的媒体请求 |
| 拖动进度条 | 长关键帧间隔媒体已恢复播放，仍可能显示加载或等待 Seek 超时 | 使用当前 Seek 的 mpv 完成/恢复事件确认结果，允许有效关键帧落点偏差；拖至确认片尾时遵循自动连播设置 |
| 全屏与鼠标提示 | 全屏过渡可能连控件一起缩放；边缘时间预览或提示被裁切，悬浮状态可能滞留 | 视频/字幕/弹幕一起变换，控件独立布局；按实际鼠标位置处理预览，并限制提示在视口内 |
| Android Runtime | 私有 ADB 端口变化后，已拥有的模拟器可能被误判；诊断采集会触发 ADB 操作 | 分开核验进程所有权与 ADB 绑定；有界恢复旧会话，诊断导出使用已记录观察值 |

Full Guide、原生弹幕、历史/收藏来源身份、便携备份 v4 和 Native Xtream 短 EPG
已在 0.7.3 发布。本次没有新增这些功能，也没有更改备份 schema。

## TVBox 配置与授权

- 支持的 `csp_PanConfig` / `csp_Guard` 配置交互与普通影片详情分开处理。
  准备阶段可取消；重复点击、切换卡片、离开分类或切换来源后，旧操作不能重新接管界面。
- 原生窗口延迟出现时保留当前操作；无交互窗口的动作及时结束。完成后只刷新仍在显示的
  原分类及筛选，不重复执行配置动作，也不把用户带回已经离开的页面。
- 支持从交互说明文字提供网页链接；明确点击的配置卡片与 Provider 返回地址一致时，
  可进入 Android 配置 WebView，使用返回、刷新、关闭和页面表单/JavaScript 对话框。
  网页交接绑定本次交互与 Provider/JAR，过期或无交互身份的请求被拒绝。
- 播放授权绑定原始影片、集数、线路与 Provider。原生扫码/登录窗口晚于播放返回出现时，
  仍可确认并继续同一请求；关闭窗口不代表账号有效，重新解析失败时不会循环重试。
- 配置型登录路由仅用于可核验的 `[realm](auth)` 协议及同配置、同 JAR 的匹配配置站点。
  不凭 Cookie 错误文字、站点名称或任意 HTML 猜测账号类型与登录入口。
- Android Dex Bridge 从 **0.3.45（57）** 更新为 **0.3.48（60）**。
  Java/Dex `csp_` 兼容性仍为 Experimental，不代表支持所有 TVBox 登录或配置流程。

## 搜索与详情

- CatPaw 搜索结果只缓存于内存，30 秒有效，最多 64 条缓存/5,000 个结果；单页超过
  200 条或空结果不进入该缓存。配置、账号和 runtime endpoint 变化会使相应缓存失效。
- 同一个进行中的 Node 搜索，在关键词、来源上下文和范围均相同时复用当前请求。
  Node 站点按照近期成功响应耗时调整尝试次序，不删减已选站点，也不改变其他 Provider 次序。
- 首批结果立即发布，后续合并更新由 120 ms 定时器推进；已有结果时可显示部分站点仍在搜索。
  多站搜索与共享 Node runtime 的全局并发上限仍为 20，聚合搜索仍每站只取第一页。
- Node 缓存保存通知与实际配置修改分开处理。缓存更新可清除可复用详情，不中断页面正在
  等待的详情；真实 Provider 变化保留当前详情路径并提示重试，授权身份不再随缓存 revision 改变。

## 播放器与自动连播

- 标题、音量、时间、工具按钮和中央播放控制按窗口宽度布局；小窗口可收紧或分行，
  大窗口与全屏保持正常控件尺寸。全屏动画中视频、字幕和弹幕维持相同变换，控件与面板独立。
- 进度条预览与 Seek 使用相同坐标；左右边缘完整显示时间。拖动结束、失去焦点、切换视频、
  窗口尺寸变化和全屏切换时清理旧悬浮。提示延迟出现，按实际宽度限制在视口内，遵循减少动态效果设置。
- Seek 完成必须属于当前定位请求；快速连续定位时旧事件不能结束新请求的加载状态。
  在确认到达片尾后可以自动切集，提前断流仍不触发自动切集。
- 连播列表按集号、季与版本组织。比如同一列表中的 `ZIYA 22.mkv`、`另一前缀 23.mkv`、
  `第三前缀 24.mkv` 可以按 22 → 23 → 24 播放；容量、分辨率、编码、帧率和年份标记
  不直接当作集号。没有系列证据的文件列表至少需要三个连续且唯一的集号才能推断；
  有明确系列证据时可使用两项以上的唯一编号列表。明确季集标记沿用季集顺序，合并集区间
  不确定时不猜测后续资源。
- 已建立序列可跨过未上传的集数；重复集号、多个冲突数字、无法核验的资源仍保持保守处理。
  版本不明确时不随意跨版本；花絮等非正片与音频/字幕资源不进入自动连播队列。
  列表级推断仅用于当前展示与播放队列，不凭它新增可信历史/收藏身份。
  自动连播开关允许切集，但不能让歧义或未准备好的列表自动成为可靠队列。
- 历史续播等待完整列表恢复后再判断下一集；列表尚未准备好或未完整加载时，结束面板给出状态
  或重新加载入口。没有可确认的后续资源时不会显示可点击的下一集。
- 中英文界面同步增加上述配置、搜索、结束状态与提示文字。

## Android Runtime 恢复

- 将私有模拟器进程所有权与私有 ADB daemon/端口绑定分开核验。绑定丢失或变化时，
  在确认进程仍属于本应用后有界退役并恢复，避免对同一 AVD 再启动第二个模拟器。
- 停止会话保留原记录的 ADB 绑定；端口占用探测失败不再当作空闲端口。
  无法确认所有权时保留现场，不关闭 Android Studio 或其他模拟器。
- 诊断导出使用生命周期已采集的观察值，注明缓存观察及记录/当前端口，避免为收集错误报告
  再启动 ADB 或改变失败现场。此修复包含 `v0.7.3` 之后已提交的 `5780acd`。

## 版本、验证与发布状态

- 正式版本 **0.8.0（Build 130）**，Android Dex Bridge **0.3.48（60）**。
  最低 macOS 12.0，仅 Apple Silicon / arm64；版本和构建信息保持同步。
- [GitHub Release v0.8.0](https://github.com/yaolin-dev/OKVideoMac/releases/tag/v0.8.0)
  提供正式 DMG、APK、对应源码、四份 SBOM、许可证、声明、清单与校验文件，共 15 个公开资产。
  ZIP 仅作内部二进制身份归档，不作为公开下载。
- exact release commit：`b049b381db52b5bbbeec9cf58bf54a5bd50a4f39`；`v0.8.0` 固定此提交。
  Release / arm64 构建、29 个 Mach-O 的 Developer ID / Hardened Runtime / secure timestamp、
  动态依赖闭包、App/DMG 签名与源码绑定均通过。
- Apple notarization：**Accepted**，Submission：`bc1f6ef5-5d19-4888-91f9-dbf5737d865d`。
  DMG Staple、stapler validate、DMG/盘内 App Gatekeeper 与全新安装 smoke 均通过。
- 最终 DMG SHA-256：`f082a380ffb1d2d059f228e0b6f0d7b59424f80edff57e81230d2efe6496b97a`。
- 自动回归及跳过项见 [发布就绪记录](RELEASE_READINESS_0.8.0.md)；
  正式分发与资产核验见 [发布验证记录](RELEASE_VALIDATION_0.8.0.md)；
  模块/文件清单见 [发布准备记录](RELEASE_PREPARATION_0.8.0.md)。
- 随资产提供的 Release Notes 和源码归档保留 exact release commit 的构建时快照。
  GitHub Release 页面及 main 文档补录最终分发状态，不移动 tag 或改写已签名资产。

## 已知限制

- QuickJS、Node、Java/Dex、网页嗅探、网盘与配置授权只覆盖已实现子集；实际可用性取决于
  Provider、服务器、媒体格式、账号和网络，不保证任意文件名或登录页面都能自动处理。
- TVBox/FongMi 顶层 `lives`、Native Xtream catch-up/timeshift / `direct_source`、
  parser type 2/3/4 和 DRM 仍不受支持。
- Managed Android Runtime 真实 E2E 证据仍只覆盖一台 M1 / macOS 14.8.8；
  App deployment target 不代表其他系统、显示器、刷新率和真实来源都已完成实机验收。
- 性能改动有资源边界与回归证据，不宣称固定搜索加速比例或所有媒体都能快速 Seek。
  项目不内置内容源、账号、Cookie、解析服务或 DRM 密钥。

---

# OKVideoMac 0.8.0 (Build 130)

Compared with the published v0.7.3 (Build 129), this release adds selected
TVBox Java/Dex configuration and native authorization interactions, bounded
CatPaw search reuse, and more reliable detail ownership. Configuration work is
cancellable; confirmed playback authorization can retry the same episode once.
Unsupported or ambiguous login protocols are not inferred from error text.

Player controls adapt to window width independently of full-screen video
transforms. Progress previews and tooltips stay inside the viewport. Seek readiness
uses owned mpv events, replay reloads the media, and automatic continuation waits
for restored episode lists. Numbered video filenames can form a queue across
different prefixes when the same-season/version sequence is unambiguous; inferred
list semantics do not become trusted persistent resource identities.

Android Bridge is 0.3.48 (60), up from 0.3.45 (57). Owned emulator recovery now
distinguishes process ownership from ADB binding changes, and diagnostics use
recorded observations without starting ADB. Full Guide, danmaku, source-aware
History/Favorites and backup schema v4 were already shipped in 0.7.3.

Apple Silicon and macOS 12.0 or later remain required. Provider compatibility
remains bounded. The search changes do not promise a fixed speedup. The official
0.8.0 DMG passed Developer ID signing, Apple notarization, stapling, Gatekeeper
and fresh-installation runtime smoke checks. Tag `v0.8.0` pins commit
`b049b381db52b5bbbeec9cf58bf54a5bd50a4f39`. The final DMG SHA-256 is
`f082a380ffb1d2d059f228e0b6f0d7b59424f80edff57e81230d2efe6496b97a`. The release includes 15 public assets;
source and asset notes retain their immutable build-time snapshots. See the
readiness and release validation records for actual test coverage and limitations.
