# OK影视 Mac

`OKVideoMac` 是一个面向 Apple Silicon Mac 的原生 Swift/SwiftUI 媒体客户端，目标是兼容 FongMi/TV 的公开配置协议与主要业务流程。

项目不内置影视源、账号、Cookie、解析地址或 DRM 密钥。用户应只导入自己有权使用的配置和媒体。

## 当前状态

- 最低系统：macOS 12.0
- 当前架构：arm64
- 当前版本：0.1.0
- 核心包：`macOS/OKVideoMac/Packages/OKVideoKit`
- App 工程定义：`macOS/OKVideoMac/project.yml`

当前机器只有 Command Line Tools。核心包设计为使用 `swift test` 验证；但本机
Swift 编译器与 SDK 模块版本不匹配，当前尚未成功构建。完整 App 构建和启动
需要兼容 macOS Monterey 的完整 Xcode。

## 快速验证

```bash
swift test --package-path OKVideoMac/macOS/OKVideoMac/Packages/OKVideoKit
```

完整构建说明见 `macOS/OKVideoMac/Docs/BUILDING.md`。

## 上游

协议审计固定在 FongMi/TV `fongmi` 分支提交
`5fdff00a602dc56e8ba756174daef20edab024f2`。参考源码不会参与 macOS 构建。

## 许可证

本项目采用 GNU General Public License Version 3。完整条款见 `LICENSE`，
上游来源与本项目修改声明见 `NOTICE.md`。
