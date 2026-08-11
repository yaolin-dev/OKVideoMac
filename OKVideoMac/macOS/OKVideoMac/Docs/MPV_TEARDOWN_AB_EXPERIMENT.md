# libmpv stop() 与完整销毁 A/B 实验报告

## 摘要

- 实验日期：2026-08-11
- Release：OKVideoMac 0.3.39（arm64）
- 测试对象：同一部 4K H.265 点播视频；A、B 两组均连续播放/关闭 5 轮
- A 组：`warmStop`，关闭播放器时保留 libmpv client 与 render context
- B 组：`fullDestroy`，关闭播放器时释放 render context、销毁 libmpv client，下次播放完整重建
- 冷启动稳定内存：A 组 165 MB，B 组 166 MB

核心结果：第 5 轮关闭 60 秒后，`warmStop` 为 701 MB，`fullDestroy` 为 196 MB，完整销毁自然回收约 **505 MB**。五轮关闭 60 秒均值分别为 685.0 MB 和 195.4 MB，均值差 **489.6 MB**。

第二轮以后 click-to-first-frame 的均值，`warmStop` 为 1867.8 ms，`fullDestroy` 为 1559.0 ms。本轮未测到完整销毁导致的可复现起播损失；相反 B 组均值快 308.8 ms，但首帧时间受网络、恢复历史记录和媒体加载波动主导，不能解释为销毁带来的性能收益。可直接归因于 B 模式的 client 重建耗时为 52–69 ms，均值约 59 ms。

## 1. 当前生命周期与所有权

```text
AppEnvironment
└─ PlayerLifecycleController（长期持有，选择 warmStop / fullDestroy）
   └─ MPVPlayerClient（当前播放器实例）
      ├─ mpv_handle / event loop / observers
      └─ RootView 读取 renderPlayer
         └─ MPVRenderView / MPVOpenGLView（SwiftUI/AppKit surface）
            ├─ mpv_render_context
            └─ NSOpenGLContext / framebuffer / render callback
```

- `AppEnvironment` 创建并持有 `PlayerLifecycleController`。
- controller 持有当前 `MPVPlayerClient`；`MPVPlayerClient` 创建、初始化并销毁 `mpv_handle`，管理 event loop、属性观察和异步命令。
- `RootView` 只在 controller 提供 `renderPlayer` 时挂载渲染 surface，并以 `renderOwnerID` 作为 SwiftUI identity；重建 client 会生成新 ID，避免复用旧 surface。
- `MPVOpenGLView` 创建 `mpv_render_context`，并负责先停止 render callback、断开 Swift 指针，再释放 native render context 和 OpenGL 资源。
- `warmStop` 仅执行 stop/reset，保留 client 和 render context。
- `fullDestroy` 的顺序为：拒绝新操作 → stop → 主线程同步通知 surface 拆除 callback/render context → 等待 surface 脱离 → 串行队列停止 event loop 并销毁 `mpv_handle` → 清空 Swift 引用。
- event/render 日志都带 `playerID` 与 `requestID`；快速切换时可区分旧实例与新实例，防止旧回调污染新状态。

未发现由 Swift 强引用形成的长期 retain cycle。实验中真正暴露的风险来自 AppKit 在 surface 拆除后仍可能安排最后一次 `draw(_:)`，详见“稳定性发现”。

## 2. A/B 原始数据

内存单位为 MB；Startup 为当轮 click → first visible frame。`Next Startup` 是该轮关闭后下一轮的起播时间。

| Round | Mode | Startup | Playing Memory | Close +5s | Close +30s | Close +60s | Next Startup |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | warmStop | 1418 ms | 969 | 684 | 662 | 662 | 1782 ms |
| 2 | warmStop | 1782 ms | 972 | 693 | 671 | 671 | 1886 ms |
| 3 | warmStop | 1886 ms | 1040 | 708 | 686 | 686 | 1532 ms |
| 4 | warmStop | 1532 ms | 1103 | 727 | 705 | 705 | 2271 ms |
| 5 | warmStop | 2271 ms | 1052 | 723 | 701 | 701 | — |
| 1 | fullDestroy | 3495 ms | 858 | 196 | 190 | 190 | 1056 ms |
| 2 | fullDestroy | 1056 ms | 727 | 189 | 181 | 181 | 1097 ms |
| 3 | fullDestroy | 1097 ms | 742 | 214 | 208 | 208 | 2868 ms |
| 4 | fullDestroy | 2868 ms | 817 | 208 | 202 | 202 | 1215 ms |
| 5 | fullDestroy | 1215 ms | 795 | 206 | 196 | 196 | — |

两次用于重现/修复 UI 与生命周期问题的 B 模式播放（2057 ms、1116 ms）未计入正式五轮数据。

## 3. 内存收益

| 指标 | warmStop | fullDestroy | 差值 |
| :--- | ---: | ---: | ---: |
| 第 5 轮关闭 +60s | 701 MB | 196 MB | **505 MB** |
| 五轮关闭 +60s 均值 | 685.0 MB | 195.4 MB | **489.6 MB** |
| 末轮 footprint | 702.2 MB | 195.8 MB | 506.4 MB |
| live malloc | 287,203 KB | 37,514 KB | 249,689 KB（约 243.8 MiB） |
| heap all zones | 294,095,600 B | 38,413,456 B | 255,682,144 B（约 243.8 MiB） |
| 无类型 native allocation | 265,497,792 B | 15,825,584 B | 249,672,208 B（约 238.1 MiB） |

B 组关闭后基本回到冷启动附近：末轮 196 MB，相对 166 MB 冷启动仅高约 30 MB。A 组虽然没有继续无限阶梯增长，但稳定平台仍在约 685–701 MB。

## 4. 被释放的 native memory

以下为末轮关闭稳定后的近似 VM 类别；数值来自同一测量方法。

| VM 类别 | warmStop | fullDestroy | 约释放量 |
| :--- | ---: | ---: | ---: |
| MALLOC_MEDIUM | 261 MB | 23 MB | 238 MB |
| MALLOC_SMALL | 142 MB | 51 MB | 91 MB |
| MALLOC_LARGE | 12 MB | 0.016 MB | 12 MB |
| IOSurface | 117 MB | 52 MB | 65 MB |
| IOAccelerator | 57 MB | 2.203 MB | 54.8 MB |
| VM_ALLOCATE | 约 7.36 MB | 约 4.72 MB | 约 2.6 MB |

结论是回收并非来自单一 cache：主要是 FFmpeg/libmpv 所在的 native malloc 高水位，同时 render context 销毁也释放了大量 IOSurface 和 IOAccelerator 显存映射。原来约 265 MB 的无类型 native allocation 在 B 组降到约 16 MB，证明 `mpv_handle` 生命周期是高水位驻留的主要边界。

## 5. 起播性能

| 指标 | warmStop | fullDestroy | B - A |
| :--- | ---: | ---: | ---: |
| 全五轮 click → first frame 均值 | 1777.8 ms | 1946.2 ms | +168.4 ms |
| 第二轮以后均值（主要指标） | 1867.8 ms | 1559.0 ms | **-308.8 ms** |
| 第二轮以后中位数 | 1834 ms | 1156 ms | **-678 ms** |
| 第二轮以后 T0 → T1 client ready 均值 | 284.3 ms | 276.3 ms | -8.0 ms |
| B 模式显式 native client 重建 | — | 52–69 ms，均值约 59 ms | — |

按实验要求应重点比较第二次及以后的播放：本轮没有观察到 `fullDestroy` 破坏“秒开”。B3→B4 的 2868 ms 和两组其他波动说明媒体加载/网络噪声远大于约 59 ms 的 client 重建本身。因此不能声称 B 模式能加速，只能得出：**在这五轮样本中，没有测到可复现的额外首帧延迟；可归因的重建成本约 59 ms。**

## 6. heap / leaks

| 指标 | warmStop | fullDestroy |
| :--- | ---: | ---: |
| heap all zones | 294,095,600 B | 38,413,456 B |
| 无类型 native allocation | 265,497,792 B | 15,825,584 B |
| leaks | 0 项 / 0 B | 0 项 / 0 B |

`leaks` 报告 0 项，但系统同时提示目标进程受限制、只能读取只读内存，因此该项只能作为辅助证据，不应视为绝对无泄漏证明。更可靠的交叉证据是 footprint、vmmap 和 heap 在 B 组一致回落。

## 7. 稳定性发现与修复

### 7.1 AppKit 最后一帧 draw 竞态

首个 B1 暴露了真实崩溃：`EXC_BREAKPOINT / SIGTRAP`，主线程位于 `MPVOpenGLView.draw(_:)`。render context 已释放后，AppKit 仍投递了一次最后的 layer draw；旧的 nil fallback 在没有 current CGContext 时调用 AppKit 绘制 API而触发异常。

修复后的拆除顺序是：先关闭 render callback gate、取消 `needsDisplay`，将 Swift `renderContext` 置空，再销毁 native context；`draw(_:)` 在 context 为空时直接返回。修复提交为 `8b64577`。修复后正式 B 组五轮及八项极端测试均未再崩溃。

### 7.2 启动状态提示重叠

完整销毁后，下一次 client 重建的短窗口里 `embeddedPlayer == nil`。原 UI 同时显示“内嵌播放器不可用”和“正在恢复历史记录”，文字发生重叠。现已在正常播放状态 overlay 存在时隐藏永久不可用占位，并增加策略单测。该修复只影响瞬态呈现，不改变 A/B 内存变量。

### 7.3 快速切换

10 次快速切集由同一个活跃 player 承接，最终请求正常出首帧，关闭时只销毁一次。被后续请求覆盖的早期 load 可持续 5–6.6 秒，后期请求约 1.3–2.3 秒；未出现旧实例回调新实例、double free、黑屏或声音残留。该现象更像被取消/覆盖的媒体加载时延，仍值得在长期 soak 中持续观察。

## 8. B 模式极端生命周期测试

| # | 场景 | 结果 |
| ---: | :--- | :--- |
| 1 | 打开视频后立刻关闭 | 通过；重建 70 ms，销毁 58 ms，无崩溃 |
| 2 | 打开 A → 立即关闭 → 打开 B | 通过；两个独立 player ID，旧实例先销毁 |
| 3 | 连续快速切换 10 次 | 通过；最终请求正常播放，关闭时单次销毁 |
| 4 | seek 后立即关闭 | 通过；无 callback 野指针或声音残留 |
| 5 | 直播播放后关闭 | 通过；Video/Audio 负载退出，无残留 |
| 6 | 点播 → 直播 → 点播 | 通过；三次独立实例均正确创建/销毁 |
| 7 | 播放时后台 → 前台 | 通过；同一 client 恢复播放并正确销毁 |
| 8 | 销毁过程中退出 App | 通过；销毁约 9 ms 完成后进程退出，无重复销毁 |

## 9. 风险与建议

本轮不做正式架构切换。数据支持把“退出时完整销毁”作为下一阶段的领先候选：它能稳定自然回收约 0.5 GB，且五轮中未观测到可复现的二次起播损失；显式重建成本约 59 ms。

但 B1 确实暴露过一次 OpenGL/AppKit teardown 竞态，说明这条路径比 warmStop 更敏感。建议保留 `PlayerTeardownMode` 开关，先用修复版做更长时间的 canary/soak，覆盖窗口缩放、全屏切换、睡眠唤醒、不同编码和错误媒体源，再决定正式策略。基于当前数据的优先顺序是：

1. 候选 A：每次退出立即 destroy。内存收益最大，当前未测得可复现秒开损失。
2. 若 soak 发现快速重开体验或生命周期风险，再退到 B：退出后短暂 warm、延迟 destroy。
3. 仅在 memory pressure 时销毁会长期保留约 0.5 GB 高水位，不符合本轮观察到的收益，优先级低于前两项。
4. 主动清理部分 cache 不是本轮变量，且无法解释 render/allocator 的全部驻留，需另立实验。

实验完成时，代码默认仍为 `warmStop`，因此该轮结果没有直接替换正式逻辑。

## 10. 可复现性说明

- 未调用 `malloc_trim`、purge 或其他强制内存回收 API。
- 未调整视频 cache、demux、图片缓存、URLSession、SwiftUI 页面缓存或 OpenGL/Metal 架构。
- 每轮均使用正常 UI 播放和关闭，并在 +5/+30/+60 秒采样。
- 所有生命周期日志带时间戳、mode、player ID、request ID，并记录 T0–T4。
- Release 包构建、签名及 bundle 校验通过；测试套件通过。

## 11. 后续落地状态

根据本报告的实测结果，后续实现将 `fullDestroy` 提升为正式默认关闭策略；集数切换、清晰度切换等播放器内部操作仍复用当前实例。`warmStop` 没有删除，可通过 UserDefaults `player.teardownMode=warmStop` 或环境变量 `OKVIDEOMAC_PLAYER_TEARDOWN_MODE=warmStop` 快速回退。
