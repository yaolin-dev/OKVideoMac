# 主侧栏与外观修复（0.8.3 / Build 136）

基线为公开 main `3529d05`（0.8.2 / 135）。修复限于主浏览分栏；设置内部可调分栏继续保留。

## 原因

旧补边 CALayer 使用不透明 textBackgroundColor，在独立材质边界形成白带。去除它后，NavigationSplitView 底层仍保留 1 pt 分隔槽；页面白色背景默认延伸至顶部安全区，标题栏边界仍显白。页面工具栏变更时拆装侧栏按钮造成闪动。跨 NSHostingController 复制整个环境又固定了旧 colorScheme，使材质与内容在主题切换时不同步。搜索提示的默认 vibrant 颜色与灰底过近，形成近乎不可见的文字。

## Apple 官方依据

- https://developer.apple.com/videos/play/wwdc2020/10104/ ：NSSplitViewController、sidebar 类型的 NSSplitViewItem 和 fullSizeContentView 提供原生全高侧栏。
- https://developer.apple.com/documentation/appkit/nssplitviewitem/init(sidebarwithviewcontroller:) ：sidebar item 自动提供半透明材质和折叠行为。
- https://developer.apple.com/documentation/appkit/nsvisualeffectview ：系统源列表等控件自动提供材质，无需额外包裹背景。
- https://developer.apple.com/documentation/appkit/nssplitview/dividerthickness ：允许通过 NSSplitView 子类自定义分隔宽度。
- https://developer.apple.com/documentation/appkit/nssplitview/drawdivider(in:) ：允许自定义分隔绘制。

补充官方接口：
- https://developer.apple.com/documentation/appkit/nstitlebaraccessoryviewcontroller ：原生标题栏附件；SDK 指明 left 附件放在交通灯右侧。
- https://developer.apple.com/documentation/swiftui/view/background(_:ignoressafeareaedges:) ：background 默认忽略全部安全区。
- https://developer.apple.com/documentation/appkit/nsappearance/name-swift.struct/vibrantlight ：侧栏材质上的原生控件外观；NSAppearance.h 允许用于 NSVisualEffectView 及其后代容器。
- https://developer.apple.com/documentation/appkit/nsimage/symbolconfiguration-swift.class/init(palettecolors:) ：系统符号原生调色板。
- https://developer.apple.com/documentation/appkit/nsview/viewdidchangeeffectiveappearance() ：AppKit 外观变化回调，用于同步原生控件。
- https://developer.apple.com/documentation/swiftui/environmentvalues/colorscheme ：SwiftUI 的颜色方案环境，由各 host 的实时窗口外观提供。

本机 SDK 的 NSSplitViewController.h 要求自定义 splitView 在 view 加载前设置，并禁止更换受管理 split view 的 delegate / 操作其子视图。实现遵循这一限制，没有替换 SwiftUI 私有对象类型或代理。

## 实现

使用自有 NSSplitViewController、原生 sidebar NSSplitViewItem 和两个稳定 NSHostingController。公开 NSSplitView 子类同时覆写 dividerThickness 为 0 和 drawDivider，不插入遮挡层、不修改私有视图或受管理 delegate。侧栏固定 220 pt、允许 full-height layout，保持 .sidebar / behindWindow；右侧独立 .titlebar / withinWindow，各页面背景保留顶部安全区。

窗口持有 NSTitlebarAccessoryViewController 的原生 NSButton，调用系统 toggleSidebar；Auto Layout 固定垂直居中，附件宽度取实际侧栏边界。页面保留自己的工具栏，空工具栏实例复用。

只桥接应用所需环境，系统显示特征由子 host 的实时窗口提供。侧栏容器 appearance=nil，viewDidChangeEffectiveAppearance 同步搜索框/源列表的 vibrantLight / vibrantDark。搜索保留 NSSearchField 原生背景、焦点、搜索与清除按钮；提示采用动态 secondaryLabelColor，SF Symbols 使用动态 systemBlue 调色板。

## Android 资源检查

预览包缺少 APK 时，旧启动阶段将通用资源错误误归类为 ADB 端口映射失败。现在显式抛出 installingBridge / bridgeAPKMissing，并在真正配置映射前才进入 configuringPortForward。Xcode Release embed phase 缺少 APK 必须失败。性能测试专用 App 启动入口仅在 OKVIDEO_PERFORMANCE_TEST 且显式环境变量开启时使用，不进入正常发布产物。用户 AVD、登录、私钥和备份不重置。

## 验证边界

回归检查两栏边界相等（0.001 pt）、左右材质独立、全高标题栏、五页整窗边界像素、按钮持续挂载和坐标、收放、蓝色符号、搜索提示实际像素对比及主题最初三个绘制帧。此前预览定向 27 项通过，实际 App Android 启动/停止通过。

普通 cacheDisplay 不能证明 Mission Control 合成状态；此前用户截图揭示了早期修复遗漏，不能把早期测试通过冒充最终人工验收。正式回归与签名、公证、分发和发布结果见 [0.8.3 就绪记录](RELEASE_READINESS_0.8.3.md)及发布后验证记录。
