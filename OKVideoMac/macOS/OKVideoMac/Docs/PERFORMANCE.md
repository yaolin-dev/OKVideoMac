# Performance

当前尚无可运行 App，因此没有 Instruments 结果。

实现中已经设置的边界：

- 配置 5 MiB；
- 站点响应 16 MiB；
- 海报 10 MiB，内存缓存约 128 MiB/300 项；
- 直播列表 32 MiB；
- XMLTV 解压后 64 MiB；
- 多站搜索并发 4；
- 播放解析最多 8 次；
- QuickJS 64 MiB/10 秒；C smoke test 已验证 50 ms 无限循环中断。

获得可运行构建后必须记录：

- 冷启动；
- 海报网格滚动；
- 多站搜索；
- 直播大列表和 EPG；
- WebView/Spider 销毁；
- 播放 60 分钟内存趋势；
- 20 次进入退出播放器；
- Main Thread Checker、Leaks、Allocations、Time Profiler 和 Network。
