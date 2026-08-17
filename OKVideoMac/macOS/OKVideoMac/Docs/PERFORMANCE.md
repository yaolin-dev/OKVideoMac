# Performance

- 文档类型：当前性能基线与待验证项
- 对照版本：0.3.41（Build 65）
- 最近更新：2026-08-17

## 已设置的资源边界

- 配置 5 MiB；
- 站点响应 16 MiB；
- 海报 10 MiB，内存缓存约 128 MiB / 300 项；
- 直播列表 32 MiB；
- XMLTV 解压后 64 MiB；
- 多站搜索并发 4；
- 播放解析最多 8 次去重尝试；
- QuickJS 64 MiB / 10 秒，C smoke test 已验证无限循环中断。

## 播放器生命周期基线

0.3.39 的 libmpv A/B 实验已完成，详细原始数据见
[`MPV_TEARDOWN_AB_EXPERIMENT.md`](MPV_TEARDOWN_AB_EXPERIMENT.md)。

- `warmStop` 五轮关闭 60 秒的内存均值为 685.0 MB；
- `fullDestroy` 五轮关闭 60 秒的内存均值为 195.4 MB；
- 末轮稳定差值约 505 MB，主要来自 native malloc、IOSurface 和
  IOAccelerator 高水位回收；
- 完整重建 libmpv client 的可归因开销为 52–69 ms，均值约 59 ms；
- 正式五轮和 8 类极端生命周期场景未再出现销毁竞态崩溃。

该实验样本量较小，且首帧时间受网络、媒体和历史恢复影响，因此不用它
宣称 `fullDestroy` 必然提升起播速度。当前结论只是：它明显降低退出播放后的
内存高水位，未观察到可复现的二次起播退化。

## 当前构建与测试基线

2026-08-15 在 0.3.41（Build 63）集成工作树上：

- Xcode 集成测试 198 项通过，OKVideoKit 独立测试 94 项通过；
- arm64 Release 与 Android Release Bridge 构建通过；
- 包体仍须由当前 commit 的最终本地 packaging gate 重新验证 28 个 Mach-O
  对象的架构、最低系统、依赖和签名。

这些结果证明功能和发布门禁可运行，不等价于 Instruments 性能基线。

## 仍待完成的性能验收

- 冷启动与首次可交互时间；
- 海报网格长时滚动、内存缓存和磁盘缓存命中率；
- 多站搜索的并发峰值、取消延迟和慢站隔离；
- 大型直播列表与大体积 XMLTV 的展开和内存峰值；
- WebView、QuickJS、Node 和 Android Bridge 的反复创建/销毁；
- 不同编码、分辨率、全屏、多显示器和睡眠/唤醒下的播放 soak；
- Main Thread Checker、Leaks、Allocations、Time Profiler、Network 和 Energy Log；
- macOS 12 最低系统与当前 macOS 的对照数据。
