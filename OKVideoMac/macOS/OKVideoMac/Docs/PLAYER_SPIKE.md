# libmpv Player Spike

> 文档类型：历史原型记录。本文的“仍未执行”保留当时的原始门禁，
> 不代表当前播放器状态。当前能力见 `Docs/COMPATIBILITY.md`，实测
> 生命周期数据见 `Docs/MPV_TEARDOWN_AB_EXPERIMENT.md`。

## 决策

正式方向为 `mpv_render_context` + `NSOpenGLView`，不用外部 mpv 窗口，也不把
`wid` 作为最终实现。Render API 允许 SwiftUI 控制层独立覆盖，并避免 macOS
父子窗口嵌入的焦点和生命周期问题。

## 已落地源码

- `Native/MPVBridge` 封装 Client API、属性观察、结构化命令数组和 OpenGL
  Render API；Swift 不直接依赖 mpv 头文件。
- `MPVLibrary` 只从 App 自身的 `Contents/Frameworks` 动态载入桥接 dylib，并
  在启动时校验事件结构 ABI。
- `MPVPlayerClient` 使用专用串行队列轮询事件和执行命令；Render API 只在
  `NSOpenGLView` 的 OpenGL 上下文线程调用。
- Render 回调只派发 `needsDisplay`，不在回调中调用任何 mpv API。
- 媒体 Header 使用 `MPV_FORMAT_NODE_ARRAY` 传递，命令使用参数数组；不拼接
  mpv 命令字符串。
- 播放窗口支持播放/暂停、Seek、音量、静音、倍速、上下集、外挂字幕、截图、
  音轨/字幕轨、延迟、画面比例、硬解、全屏和续播状态回写。
- `load` 会等待 `FILE_LOADED` 或 30 秒超时；初始加载错误会回送解析状态机，
  继续当前线路的其他解析器或下一线路。
- `build-libmpv.sh` 在构建 v0.41.0 后同时生成 arm64/macOS 12
  `libOKMPVBridge.dylib`；打包与验证脚本检查桥接到 `@rpath/libmpv.dylib`
  的依赖闭包。

## 仍未执行

当前机器没有完整 Xcode、Meson、Ninja 或 libmpv，以下项目均未验证：

- v0.41.0 在 Xcode 14.2/macOS 12 SDK 上构建；
- Swift Client/Render 源码的语义编译和实际链接；
- Render Context OpenGL 初始化；
- VideoToolbox 硬解；
- 全屏、多显示器和 Retina backing scale；
- 睡眠/唤醒与音频设备切换；
- 反复创建/销毁泄漏；
- dylib 闭包和 Hardened Runtime。

`Native/MPVBridge` 已用 mpv v0.41.0 官方头文件通过 `clang -fsyntax-only`
检查，但这不等价于链接或运行验证。只有上述实测完成后，兼容矩阵才能把
libmpv 从 `Partial` 提升。

## 验收记录模板

| 项目 | 命令/操作 | 结果 |
| --- | --- | --- |
| 本地视频 | 待执行 | 未验证 |
| 公开 HLS | 待执行 | 未验证 |
| 暂停/Seek | 待执行 | 未验证 |
| 全屏 | 待执行 | 未验证 |
| 20 次进入退出 | 待执行 | 未验证 |
| 无 Homebrew 运行 | 待执行 | 未验证 |
