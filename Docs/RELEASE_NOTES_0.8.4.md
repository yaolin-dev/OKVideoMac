# OKVideoMac 0.8.4（Build 137）Release Notes

修复 0.8.3 在部分 macOS 27.0.1 系统启动时出现的工具栏管理崩溃路径。

- 移除主窗口 `window.toolbar` KVO 监听中的同步备用工具栏回写，由 SwiftUI 管理页面工具栏的创建、更换与移除，避免在观察者清理过程中重入。
- 首页加载和无配置状态声明真实标题；片源、筛选、刷新等操作仍要求有效配置，搜索与详情保留各自工具栏。
- 保留左右独立原生材质、零宽分隔、固定标题栏侧栏按钮、原生搜索外观及主题同步。
- 在 View 层切换完整工具栏声明，保持 macOS 12 API 兼容。

原 0.8.3（136）报告显示，SwiftUI 更新工具栏时移除 KVO 观察者抛出异常并 SIGABRT。隔离实验确认原代码会同步回写工具栏，本轮移除该干扰路径。2026-10-09 用户确认 macOS 27.0.1 实机测试正常；该反馈不代替所有机型、源或配置的完整覆盖。原报告证明 App 崩溃，未证明整台 Mac 重启。

本机回归覆盖真实 WindowGroup 启动、配置恢复、菜单/搜索/详情、关窗重开、侧栏生命周期、独立材质及主题同步。仅支持 Apple Silicon / arm64，最低 macOS 12.0。Android Bridge 仍为 0.3.48（60），原生库未升级。

沿用稳定 HTTPS 更新源与既有 Sparkle 公钥。0.8.1–0.8.3 稳定通道可检查更新；自动检查需授权，下载和安装需确认。0.8.0 或本地测试源版本需手动安装。

构建时说明记录正式发布准备。只有从干净 main 重建的 Developer ID / Hardened Runtime、Apple Notarization Accepted、staple、Gatekeeper、最终 DMG 与安装验证全部通过才发布。实际结果在发布后补录；对应源码、许可证、四份 SBOM、校验和及签名 appcast 随附，ZIP 仅作内部身份载体。现有 zlib 原始归档和历史 clang 输入等 native provenance 例外保留。

English: removes synchronous AppKit toolbar write-back during SwiftUI toolbar teardown, supplies a real title for loading/empty home states, and preserves native sidebar appearance and macOS 12 compatibility. The user confirmed successful testing on macOS 27.0.1 before formal release preparation.
