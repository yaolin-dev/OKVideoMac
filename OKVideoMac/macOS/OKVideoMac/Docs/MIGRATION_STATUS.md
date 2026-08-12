# OKVideoMac Migration Status

> 文档类型：历史迁移记录。本文保留项目早期无完整 Xcode 环境时的
> 实现和验证状态，不代表当前版本。当前事实以仓库根目录 `README.md`
> 和 `Docs/COMPATIBILITY.md` 为准。

## 当前可运行版本

无。源码已建立，但当前机器缺少完整 Xcode，Command Line Tools 的 Swift
编译器与 SDK 模块也不匹配，不能声明构建或测试通过。

## 已实现但未构建验证

- XcodeGen macOS App 工程定义和 macOS 12/13 导航兼容层；
- 已用 XcodeGen 2.38.0 真实生成并提交 `OKVideoMac.xcodeproj`；
- 配置 URL、本地文件、粘贴文本模型与加载流程；
- 未知 JSON 字段、多类型 `ext` 和递归重复 JSON key 检测；
- URLSession HTTP 客户端、重试、重定向、Header/Cookie 和脱敏；
- type 0/1/4 标准站点、分类、筛选、详情、搜索和线路/分集解析；
- 多站错误隔离、取消、站内去重和跨站同名同年聚合；
- SQLite 配置、收藏、历史、设置、权限收紧、损坏隔离恢复和 v1 迁移；
- 可观察播放解析状态机、type 1 JSON 和 type 0 WKWebView 解析；
- M3U、TXT、JSON、XMLTV、gzip、EPG 缓存和直播收藏；
- WKWebView 嗅探实现；
- SwiftUI 配置、首页、分类、搜索、详情、收藏、历史、直播和设置界面；
- libmpv C ABI 桥、动态 Swift Client、事件流、结构化 Header/命令传递、
  `NSOpenGLView` Render API 和播放器控制界面；
- 海报内存/磁盘缓存；
- 构建、依赖、许可证、打包和验证脚本。

## 部分实现

- libmpv：Client/Render C 桥、Swift 动态加载层、播放器状态与 UI、构建/打包
  脚本已实现，C 桥已对 v0.41.0 头文件通过语法检查；尚未实际构建 dylib、
  语义编译 Swift、链接或播放。
- QuickJS：固定源码、C ABI 桥、64 MiB 限制、超时 interrupt handler、受控
  HTTP 回调、Swift 动态载入层和 type 3 Provider 已实现。原生桥 smoke test
  已通过；完整 Swift/App 集成仍未用 Xcode 构建。
- Web 嗅探：代码已写，未在真实 WKWebView 页面验证。
- 自动换源：状态机、JSON/Web 嗅探、最多 8 次去重尝试、下一线路和 libmpv
  初始加载失败回送已串联；播放已经开始后的中途断流自动重试尚未验证。

## 未实现

- Java JAR/DEX Spider；
- Python Spider；
- TVBus、ForceTech、DLNA、DRM、弹幕、自动更新；
- Developer ID、公证和 Universal Binary。

## 实际验证

- `swift test`：未运行成功，工具报告 `XCTest not available`。
- `swift build`：未运行成功，工具报告 Swift 5.7.2 编译器与 5.7.1 SDK 模块不兼容。
- Swift 语法解析：通过 `swiftc -frontend -parse`。
- libmpv C 桥：使用 v0.41.0 官方头文件通过 `clang -Wall -Wextra -Werror
  -fsyntax-only`；未链接。
- XcodeGen 2.38.0：工程生成通过。
- QuickJS 2025-09-13-2：源码 SHA-256 校验、arm64 构建、动态桥链接和 C smoke
  test 通过；测试覆盖 Promise、Base64、受控请求和无限循环中断。
- Xcode build/test：未运行，完整 Xcode 缺失。
- App 手工启动、播放、打包：未验证。

## 下一门禁

安装并选择完整 Xcode 14.2，先修复所有语义编译错误并运行核心与 App 测试，
然后构建 libmpv/桥接 dylib，修复可能的 Swift 语义编译问题，完成 QuickJS
Swift 集成与手工播放验收。
