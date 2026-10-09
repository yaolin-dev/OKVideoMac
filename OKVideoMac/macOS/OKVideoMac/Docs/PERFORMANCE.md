# Performance

- 文档类型：当前性能基线与待验证项
- 对照版本：0.8.4（Build 137）
- 最近更新：2026-10-09
- 0.8.3 为当前正式版本；本轮未新增性能测量或性能保证。发布门禁见[正式验证](../../../../Docs/RELEASE_VALIDATION_0.8.3.md)。

## 0.8.4 工具栏修复

本轮仅修复工具栏归属与首页空态标题，无新增性能测量或性能保证。
本机窗口回归及用户确认的 macOS 27.0.1 实机反馈见[发布就绪记录](../../../../Docs/RELEASE_READINESS_0.8.4.md)。实机反馈不作为性能测量。

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
- Full Guide 最多维护 48 个活跃频道行，只请求当前视口附近 1–2 个 12 小时
  时间片；Xtream demand 限制请求数与并发，并使用 5 分钟短期缓存。

## 0.8.0 搜索与交互变化

- CatPaw 搜索内存缓存 TTL 为 30 秒，最多 64 条/5,000 项；超过 200 项的单页和空结果
  不入缓存。配置/账号/endpoint 语义变化与手动刷新使其失效，旧代际不能回填新缓存。
- 近期 Node 响应耗时用于调整 Node 尝试次序，耗时记录最多 512 个 owner、有效 30 分钟；
  不裁掉慢站，全部已选可执行站点仍尝试第一页，非 Node Provider 次序保持。
- 首个搜索快照立即发布，后续通过 120 ms trailing timer 合并，末批结果不依赖后续响应。
  相同进行中搜索按关键词、上下文和范围复用。URLSession 单 host 连接上限同步为 20。
- Node 缓存 revision 不再当作配置语义变化；缓存通知清理可复用结果，不取消当前详情。
- 播放器视频/字幕/弹幕与控件布局分离；鼠标进度预览使用实际位置和视口坐标，工具提示
  按测量宽度限位。Seek readiness 使用当前 mpv 完成事件，不因有效关键帧偏差持续等待。
- 配置卡片准备默认 90 秒有界等待，可取消；只在真实原生交互出现后打开交互页。
  配置网页与登录等待属于已进入用户交互后的流程，不把这 90 秒当作整个登录的固定期限。
- 上述机制由回归测试覆盖；没有新增统一搜索加速百分比或 Instruments 长时测量结论。

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

## 弹幕与节目单渲染边界

- 弹幕动画由 `CVDisplayLink` 驱动；播放器媒体时钟以最新可信快照为锚点连续推进，
  重复或轻微回退的进度事件不会让文字倒退；暂停、缓存、Seek 和换片分别重置状态；
- 每条弹幕文字先渲染为可复用位图，逐帧只更新合成位置，减少 Core Text 重排；
  lane 调度和屏幕外回收仍受覆盖层大小及密度限制；
- Full Guide 使用固定时间几何和 AppKit 按需绘制，频道行、时间轴和节目区域独立裁剪；
  刷新保留可验证的时间/频道锚点，避免重建完整节目视图树；
- 这些边界改善主线程负载与视觉连续性，不等同于所有分辨率、刷新率和弹幕密度
  组合已经完成 Instruments 长时测量。

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

## 0.8.0 发布验证

0.8.0（Build 130）的全量测试、静态检查和本地 Release 包验证结果记录在
[`RELEASE_READINESS_0.8.0.md`](../../../../Docs/RELEASE_READINESS_0.8.0.md)；
正式分发、安装 smoke 与资产核验见
[`RELEASE_VALIDATION_0.8.0.md`](../../../../Docs/RELEASE_VALIDATION_0.8.0.md)。
自动化通过只证明相应合同和发布门禁可运行，不等价于 Instruments 性能基线。
0.3.41（Build 63）的 198 项 Xcode / 94 项 OKVideoKit 结果仅是历史记录，不再作为
当前发布状态。

## 仍待完成的性能验收

- 冷启动与首次可交互时间；
- 海报网格长时滚动、内存缓存和磁盘缓存命中率；
- 多站搜索的并发峰值、取消延迟和慢站隔离；
- 大型直播列表与大体积 XMLTV 的展开和内存峰值；
- WebView、QuickJS、Node 和 Android Bridge 的反复创建/销毁；
- 不同编码、分辨率、全屏、多显示器和睡眠/唤醒下的播放 soak；
- Main Thread Checker、Leaks、Allocations、Time Profiler、Network 和 Energy Log；
- macOS 12 最低系统与当前 macOS 的对照数据。

## 0.6.0 播放加载边界

Native Xtream Live 的最长加载期限为 60 秒，普通 VOD 的 30 秒与导入 Live 的 8 秒保持不变。备用 HLS 准备采用独立 10 秒总时限，耗时从该次播放预算扣除。成功的首次加载没有额外清单请求。复杂 HLS 的初始化时间和缓存吞吐是不同指标，不能把起播前 0 KB/s 解释为未建立连接。

0.8.3 已正式发布，更新通道验收见[自动更新说明](../../../../Docs/AUTOMATIC_UPDATES.md)。既有兼容性与性能记录不代表本轮已重新测试全部媒体或硬件；本轮范围与结果见[正式验证](../../../../Docs/RELEASE_VALIDATION_0.8.3.md)。
