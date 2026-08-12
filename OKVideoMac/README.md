# OK影视 Mac

`OKVideoMac` 是一个面向 Apple Silicon Mac 的原生 Swift/SwiftUI 媒体客户端，
目标是兼容 FongMi/TV 的公开配置协议与主要业务流程。

项目不内置影视源、账号、Cookie、解析地址或 DRM 密钥。用户应只导入
自己有权使用的配置和媒体。

## 当前状态

- 当前版本：0.3.41（Build 62）
- 最低系统：macOS 12.0
- 支持架构：Apple Silicon / arm64
- 应用技术：SwiftUI + AppKit + libmpv
- Spider 运行时：QuickJS、Node.js、Android Java/DEX Bridge
- 本地发布：可构建、可打包，并使用 Hardened Runtime 与 ad-hoc 签名验证
- 对外分发：流程已实现，但尚未完成 Developer ID、Notarization 和
  Gatekeeper 实物验收

2026-08-12 在 0.3.41（Build 62）工作树上最近验证：

- macOS App 单元测试 152 项全部通过；
- arm64 Release 构建和 Android Release Bridge 构建通过；
- Release 包中 28 个 Mach-O 对象的架构、最低系统、依赖闭包和签名检查通过；
- 本地 Hardened Runtime 包体验证和 ZIP/SHA-256 归档生成通过。

功能级别的当前结论与证据见
[`macOS/OKVideoMac/Docs/COMPATIBILITY.md`](macOS/OKVideoMac/Docs/COMPATIBILITY.md)。

## 主要能力

- 远程 URL、本地文件和粘贴 JSON 配置；
- 首页、分类、筛选、详情、多站搜索、收藏和历史；
- M3U/TXT/JSON 直播列表与 XMLTV EPG；
- libmpv 点播/直播、Seek、音量、倍速、音轨、字幕、截图和全屏；
- QuickJS、Node.js 和 Android Java/DEX 兼容路径；
- SQLite 持久化、图片内存/磁盘缓存和播放进度恢复；
- 初始解析/加载失败时的解析器去重尝试和自动换线。

## 已知限制

- 目前只交付 arm64，不支持 Intel Mac/Universal Binary；
- Web 嗅探、Spider 和自动换源会受具体上游实现影响，不能保证所有配置等价；
- Node 远程 bundle 仍是高权限子进程，只应加载可信配置；
- Android Java/DEX 路径依赖本机 Android SDK/Emulator 环境；
- 正式 Developer ID 签名、公证和干净机 Gatekeeper 验收尚未完成；
- 不实施 DRM 绕过、TVBus 或 ForceTech 私有引擎。

## 快速验证

从仓库根目录执行：

```bash
OKVideoMac/macOS/OKVideoMac/Scripts/check-doc-status.sh

DEVELOPER_DIR=/Volumes/XcodeDev/Xcode.app/Contents/Developer \
  swift test \
  --package-path OKVideoMac/macOS/OKVideoMac/Packages/OKVideoKit

xcodebuild \
  -project OKVideoMac/macOS/OKVideoMac/OKVideoMac.xcodeproj \
  -scheme OKVideoMac \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  test
```

## Release 打包

本地验证包：

```bash
OKVideoMac/macOS/OKVideoMac/Scripts/package-app.sh --mode local
```

Developer ID 分发与公证：

```bash
export DEVELOPER_ID_APPLICATION='Developer ID Application: …'
export OKVIDEOMAC_NOTARY_PROFILE='okvideomac-notary'
OKVideoMac/macOS/OKVideoMac/Scripts/package-app.sh \
  --mode distribution \
  --notarize
```

构建环境、依赖和故障排查见
[`macOS/OKVideoMac/Docs/BUILDING.md`](macOS/OKVideoMac/Docs/BUILDING.md)。

## 上游

协议审计固定在 FongMi/TV `fongmi` 分支提交
`5fdff00a602dc56e8ba756174daef20edab024f2`。参考源码不会参与 macOS 构建。

## 许可证

本项目采用 GNU General Public License Version 3。完整条款见 `LICENSE`，
上游来源与本项目修改声明见 `NOTICE.md`。
