# OKVideoMac 0.8.3（Build 136）Release Notes

修复主侧栏与内容之间的白缝、切换菜单时按钮闪动，以及浅深色切换短暂错色。

- 主分栏使用 AppKit NSSplitViewController / sidebar item，自定义公开分隔接口使分隔槽宽度为零；左侧原生半透明 sidebar、右侧内容和 titlebar 仍是独立材质。
- 侧栏开关由窗口持有的原生标题栏附件承载，菜单切换不再反复拆装按钮；支持折叠和展开。
- 子 NSHostingController 继承实时窗口外观，搜索框与源列表同步 vibrant 外观；保留原生灰色搜索框、蓝色系统图标及可读提示文字。
- Android Bridge APK 缺失准确报告资源错误，Release 构建直接拦截缺失资源；保留严格身份验证及用户数据。

正式版本沿用稳定 HTTPS 更新源与原有 Sparkle 公钥。0.8.1/0.8.2 稳定通道可检查更新；0.8.0 或本地测试源版本需手动安装。自动检查需授权，下载和安装需确认。Android Bridge 仍为 0.3.48（60），native 库未升级。仅支持 Apple Silicon / arm64、macOS 12.0+。

构建时说明记录发布准备；只有 Developer ID / Hardened Runtime、Apple Accepted、staple、Gatekeeper、最终 DMG 与安装验证全部通过才发布。发布后实际结果见同版本正式验证记录，源码、许可证、四份 SBOM、校验和及签名 appcast 随附。现有 zlib 原始归档、历史 clang 输入等 native provenance 例外保留。

AppKit 整窗像素与几何回归不等同 Mission Control 的人工合成验收；本轮不宣称完整第三方站点、云盘账号、真实蓝牙硬件或完整更新安装流程均已测试。

English: removes the primary sidebar divider slot while keeping independent native sidebar and detail materials; stabilizes the window-owned sidebar toggle, synchronizes appearance changes, restores readable native search hints, and fails Release builds with a missing Android Bridge APK. Bridge/native dependencies and existing data boundaries are unchanged.

发布后补录：正式 v0.8.3 已公开，Apple notarization Accepted（`105f049e-55f9-4c61-b365-e5dab1ab3f9f`），staple、Gatekeeper、安装及 16 个资产验证通过；见[正式验证](RELEASE_VALIDATION_0.8.3.md)。GitHub 资产中的构建时说明快照保留原字节。
