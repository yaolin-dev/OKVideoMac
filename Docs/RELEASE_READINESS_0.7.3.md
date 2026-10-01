# OKVideoMac 0.7.3（Build 129）发布就绪记录

日期：2026-09-27

> 本文是创建 exact release commit 前冻结的发布前审计快照，保留当时的分支、工作区
> 和候选结论，不随发布后事实改写。0.7.3 已正式发布；签名、公证、Tag、GitHub
> Release、最终资产与安装结果见[最终验证记录](RELEASE_VALIDATION_0.7.3.md)。

## 基线与候选

- 最近一次正式 GitHub Release / Tag：`v0.6.1`，Build 101，提交
  `25155f52fb8c416f3245c9a829a93175dec9857b`。
- 当前分支：`codex/ux-10a1-fixes`；审计开始时 HEAD 为
  `1f8f458`（`docs: complete EPG 10A release validation`）。
- 候选版本：0.7.3；Build Number：129；目标 tag：`v0.7.3`。
- `v0.6.1..HEAD` 有 12 个提交，覆盖 EPG 数据协调、XMLTV/Xtream Full Guide、
  虚拟化绘制、性能回归与发布文档。HEAD 之后的工作区还包含弹幕、浏览、历史、
  收藏、播放、Quark 与 Android Provider 生命周期等尚未提交改动。

## 实际变更范围

- 新增有界 Full Guide：XMLTV 全局代际与 Native Xtream short EPG 按需加载统一进入
  可见频道/时间窗 demand；频道行与节目绘制虚拟化。
- 新增原生弹幕获取、XML/JSON 解析、候选匹配、稳定绑定、时间校准和显示刷新同步渲染。
- 重做分类/搜索续页、详情缓存和异步请求所有权，减少旧页面或迟到回调覆盖当前状态。
- 历史与收藏改为来源感知的原生列表，修复恢复身份、进度所有权、删除重建和旧数据迁移；
  便携备份更新为 v4。
- 播放器加入共享音量/静音记忆、媒体资源语义、Native Xtream 系统代理、全屏比例与
  过渡恢复，并修复直播/海报图片复用崩溃。
- Android Dex Bridge 更新到 0.3.45（57），补充 Provider 生命周期、媒体代际和
  Dex/JAR 校验缓存；Quark 授权、转存和媒体错误分类收紧请求所有权。

## 仓库与文档审计

- 版本元数据已统一到 0.7.3（Build 129）：`project.yml`、Xcode project、native lock
  与第三方声明一致；Android Bridge 保持自身版本 0.3.45（57）。
- 未发现源代码中的 `TODO`、`FIXME`、`HACK`、编译期 `#warning` 或待实现占位。
- 大体积本地截图、性能记录、验收日志、冻结源码和临时审计报告已由 `.gitignore`
  排除；实现所需的新源码和回归测试仍保留为待提交文件。
- 已修复 DemoSource 文档指向未纳入仓库的本地 0.6.1 资产包链接。
- README、中文 README、Changelog、0.7.3 Release Notes、详细项目说明、兼容性、
  架构、性能、DMG/对应源码发布流程和文档状态门禁已同步；未正式发布的
  0.7.0–0.7.2 迭代不再被描述为独立公开版本。

## 验证结果

| 门禁 | 结果 |
| --- | --- |
| Git diff whitespace / 文档与版本一致性 / plist、JSON、Shell 静态检查 | 通过；XcodeGen 2.38.0 重生成检查无差异 |
| Node / CatPaw / Quark tests | 47 项通过，0 失败 |
| SourceAudit tests | 24 项中 17 项通过、7 项按设计跳过，0 失败 |
| AndroidRuntimeKit full test suite | 57 项中 56 项通过、1 项在线安装门禁按设计跳过，0 失败 |
| OKVideoKit full test suite | 1029 项中 1007 项通过、22 项性能/网络实验按设计跳过，0 失败 |
| macOS Xcode repeatable full test suite | 1154 项中 1143 项通过、11 项按设计跳过，0 失败；另有 3 项针对性回归与两个独立进程音频状态用例通过 |
| Android Dex Bridge unit tests / lint / Release assemble | 34 项 JVM 测试通过；lint、assembleRelease 与签名 APK 构建通过 |
| 0.7.3（Build 129）本地 Release package 与 bundle verification | 通过；Release build、29 个 Mach-O、ZIP/DMG 解包、源码归档、SBOM、哈希和本地签名复核通过 |
| 验证包桌面替换与安装副本复核 | 收口完成后只安装最终复验通过的 Release；安装结果由本轮发布前报告记录 |

macOS 的可重复全量套件显式排除了 4 项需要真实 Emulator 生命周期的 opt-in
用例；其中应用终止清理用例已在单独针对性运行中通过。Android lint 仍会输出
OkHttp 5.1.0 的 Kotlin 2.2 metadata 与 AGP 8.7.3 lint analyzer 支持 Kotlin 2.0
之间的非阻塞诊断，但最终结果为 0 error、6 warning，没有隐藏或降级失败。

第一轮本地候选包从冻结源码快照完成，源码清单 SHA-256 为
`54a0f05d010fde7f16f9f26b6afa75075198cbbb486ef436a22fd32f8d97e04f`。本记录写入后
再从完整工作区重新冻结并执行一次相同门禁，避免用文档更新前的包作为最终安装副本。

## 已知限制

- Apple Silicon（`arm64`）与 macOS 12.0 或更高版本；不提供 Intel/Universal 包。
- Native Xtream catch-up/timeshift 与 `direct_source`、TVBox/FongMi 顶层 `lives`、
  parser type 2/3/4 和 DRM 不受支持。
- QuickJS、Node、Java/Dex、网页嗅探、网盘和弹幕服务只覆盖已实现子集，仍受上游变化影响。
- Managed Android Runtime 的真实 E2E 证据仍只覆盖一台 M1 / macOS 14.8.8。
- 当前收口不会把宿主自动测试冒充为所有真实 Provider、媒体、显示器、刷新率与网络环境的
  实机矩阵；用户仍需对自己的来源和播放场景做验收。

## 发布判定

代码、文档、自动测试和本地 Release 包门禁已经达到可提交状态；当前工作区尚未提交，
因此还不能创建正式 Tag 或发布 GitHub Release。本次收口不会上传资产或执行远程发布。
正式公开资产必须在改动提交并进入 exact release commit 后，
从干净工作区重新执行 Developer ID 签名、Apple 公证、Staple、Gatekeeper、DMG 安装 smoke、
对应源码/SBOM/哈希绑定，再由维护者确认创建 Tag 与 GitHub Release。
