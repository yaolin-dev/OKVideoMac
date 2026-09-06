# Performance

- 文档类型：当前性能基线与待验证项
- 对照版本：0.4.2（Build 97）
- 最近更新：2026-09-01

## 已设置的资源边界

- 配置 5 MiB；
- 站点响应 16 MiB；
- 海报 10 MiB，内存缓存约 128 MiB / 300 项；
- 直播列表 32 MiB；
- XMLTV 解压后 64 MiB；
- 多站搜索全局并发 20；共享同一 Node runtime 的站点并发 20，聚合搜索每站只取第一页；
- 播放解析最多 8 次去重尝试；
- Android/Dex 远程媒体由 libmpv 直连 CDN 并直接处理 Range；Bridge 仅保留给
  Android loopback 媒体，避免模拟器二次转发造成起播、拖动和长连接回退；
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

## 播放期间的界面更新边界

- mpv 时间线仍以最多 10 Hz 更新播放器控件，但通过独立的
  `PlayerSnapshotState` 发布，不再触发浏览窗口的全局 `AppState` 更新；
- 首页和直播只挂载当前可见的界面树，直播会话状态由父级保留，不再使用
  `opacity(0)` 常驻不可见频道网格；
- 搜索结果聚合和直播台标解析按完整输入缓存，避免无关状态刷新时重复排序或
  执行正则归一化；
- 回归测试明确要求播放器时间线更新不会发送 `AppState.objectWillChange`。

## 播放渲染与缓存边界

- libmpv 的 VideoToolbox–OpenGL IOSurface 互操作已启用，允许支持的编码直接把
  VideoToolbox 输出交给 OpenGL，而不必固定走 `videotoolbox-copy`；
- libmpv render context 默认启用 advanced control，并在窗口遮挡、最小化或
  render surface 不可见时消费更新但跳过实际绘制；
- 远程播放默认使用 60 秒前向缓存、128 MiB demuxer 上限和 32 MiB 回看上限，
  避免长时间播放让缓存无界增长；
- 播放开始后会在 2 秒和 15 秒记录硬解模式、视频格式、估算帧率、缓存时长和
  丢帧计数，便于区分网络、解码和渲染问题；
- `OKVIDEOMAC_MPV_PERFORMANCE_PROFILE=legacy` 可恢复旧缓存行为，
  `OKVIDEOMAC_MPV_RENDER_CONTROL=legacy` 可关闭 advanced render control，
  两个回滚开关相互独立。

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
