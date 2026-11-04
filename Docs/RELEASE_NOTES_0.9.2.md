# OKVideoMac 0.9.2（Build 197）Release Notes

本版本汇总已交付本地 Build 184–195 的开源修复，以 GitHub 正式 0.9.1（182）为发布对照。Build 197 修复 Android SBOM 的历史版本硬编码，SPDX 聚合包、CycloneDX 文档元数据及 purl 统一读取当前桥接版本，并校验 APK 哈希。

- 按原 Provider 请求入口与稳定文件身份恢复历史，失败时保留进度，并隔离 Java/Dex 源的有界恢复。
- 紧凑点播／直播控制栏与锚定状态、恢复操作，保留原生鼠标命中、悬停音量和画中画行为。
- 统一混合数字文件名、画质标签的分集排序、上下集及 TMDB 剧照映射，保留原资源／历史身份和季上下文。
- 将旧式本地文件分块兼容严格限定于明确选中的 TVBox 阿狸原线路，保留其他线路及请求归属。
- 增加字幕编码识别、按字幕保存的编码／字体选择、内置中文后备字体及脱敏诊断。
- 直播节目紧凑摘要随播放控件共同显隐；季资料异步到达时保留分集列表及滚动位置。

Android Bridge 为 **0.3.58（70）**；最低系统 macOS 12.0，仅 Apple Silicon arm64。
新增 uchardet 字幕检测和 Noto Sans CJK SC 后备字体，保留对应许可证与来源记录。其他锁定依赖沿用既有构建输入。

## Verification scope

- Restore history through the original provider request locator and stable file identity; retain progress on failures and isolate bounded Java/Dex provider recovery.
- Compact VOD/live controls and anchored status/recovery actions; keep native pointer input, hover volume and Picture in Picture behavior.
- Unify episode sorting, adjacent navigation and TMDB artwork for mixed numbered filenames and quality labels; retain original resource/history identities and season context.
- Restrict legacy local-file range compatibility to the explicitly selected Ali original TVBox line; preserve other routes and request ownership.
- Add subtitle encoding detection, per-subtitle encoding/font choices, a bundled CJK fallback font and sanitized diagnostics.
- Show a compact live programme summary with the playback controls, and retain episode lists and scroll position while season metadata arrives.

Source/player behavior still depends on provider, account and network support. Ambiguous file identity, season or edition boundaries require explicit selection. The local-file workaround applies only to the selected Ali original TVBox line. Subtitle preferences stay scoped to the selected subtitle. No new programme/network polling is introduced by the live summary.

历史本地测试记录不转记为本次结果。Release 测试、签名、公证 Accepted、staple、Gatekeeper、最终文件哈希和发布提交将在本轮验证完成后记录。Build 196 曾短暂公开并已撤回，旧产物与证据保留；Build 197 全部门禁通过后，由用户确认本轮 v0.9.2 标签及草稿资产更新。其他既有版本标签和资产保持不可变。

Android SBOM aggregate versions and purls now follow the Bridge source versionName. Both SPDX and CycloneDX must match that version and the exact packaged APK SHA-256; missing or duplicate aggregates fail the release gate.
