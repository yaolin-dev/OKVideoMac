# OKVideoMac 0.8.4（Build 137）Release Notes

状态：候选，未正式发布。基于 0.8.3（136），不改变最低 macOS 12.0 / Apple Silicon 要求。

## 修复范围

- 移除主窗口 `window.toolbar` KVO 监听中的同步备用工具栏回写，让 SwiftUI 管理页面工具栏的创建、更换与移除。
- 首页加载和无配置状态也声明真实标题；片源、筛选、刷新等操作仍要求有效配置。搜索与详情保留各自工具栏。
- 保留左右独立原生材质、零宽分隔、固定标题栏侧栏按钮、原生搜索外观及主题同步。
- 为 macOS 12 在 View 层切换完整工具栏声明，不使用 macOS 13 才提供的条件 ToolbarContent API。

## 崩溃证据与限制

0.8.3（136）在 macOS 27.0.1 / Apple Silicon 的报告显示，启动约八秒后，
SwiftUI `AppKitWindowController.updateToolbarIfNeeded` 移除 KVO 观察者时抛出异常并 SIGABRT。
隔离实验验证了原代码会在 SwiftUI 更新期间同步回写工具栏。本轮移除该干扰路径，
但报告未含完整异常原因，本机 macOS 14.8.9 通过不能替代原系统上的因果验证。
单份 App 崩溃报告不证明整台 Mac 重启或存在无限自动重启机制。

## 验收与发布

见[候选就绪记录](RELEASE_READINESS_0.8.4.md)。候选包用于实机复测。
只有受影响系统与现有正式发布门禁全部通过后，才创建正式 tag / GitHub Release。
本次不更改用户配置、播放器、Android Runtime 或更新器行为。
