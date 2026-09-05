# OKVideoMac 0.4.0（Build 94）Release Notes

状态：Release Candidate。当前公开版本仍为 0.3.41；以下内容将在 0.4.0 通过
最终公证与发布门禁后生效。

## 主要变化

- 扩展 Native TVBox/FongMi、selected QuickJS、CatPawOpen/Node 和可选
  Java/Dex 源的兼容性；Android Bridge 仍是实验性的可选兼容层。
- 搜索请求与详情请求使用更严格的 session ownership，停止搜索、返回、Esc 和
  Command-[ 行为一致，迟到回调不会覆盖新页面。
- 改进播放器窗口、缓冲提示、Seek、自然 EOF 自动下一集和重新打开流程的稳定性。
- 改进配置切换、历史恢复、收藏以及便携配置/历史备份。
- 配置与授权界面使用原生 macOS Sheet，遵循系统焦点、键盘和辅助功能行为。
- 网盘缺少凭据时进入准确授权流程；授权成功后安全恢复原播放请求。
- 夸克账号在 Cookie 更新或重新授权后复用既有工作目录，临时文件清理仍只依据
  receipt 记录的准确 `savedFID`。

## 系统要求

- Apple Silicon Mac（`arm64`）；
- macOS 12.0 或更高版本；
- Java/Dex 源另需外部 Android SDK、ADB、Emulator 与 arm64 system image。

## 已知限制

- 不支持 Intel / x86_64 / Universal Binary；
- Java/Dex 兼容仍为 Experimental；
- 第三方 Spider 与云盘接口可能因上游变化而需要后续适配；
- TMDB metadata/detail enhancement 延期到未来版本；
- 大型旧数据库升级可能出现一次性启动停顿。

正式发布说明只有在最终 DMG 的 Developer ID 签名、Apple Notarization
`Accepted`、staple、Gatekeeper、干净安装和 source/binary exact-commit 绑定
全部验证后，才会标记为正式发布。
