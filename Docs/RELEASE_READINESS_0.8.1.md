# OKVideoMac 0.8.1（Build 134）发布就绪记录

状态：正式发布候选；最终签名、公证、staple、安装及 GitHub 状态以正式验证记录为准。

## 本轮范围

- 原样回移 mpv #18383 两个提交；保留故障测试证明必要的 AudioUnit 清理与部分监听注册失败清理。
- Sparkle 2.10.0 授权后每日检查、手动检查、播放期间延后提示；下载和安装由用户确认。更新安装与普通重启互斥，等待实际异步清理。
- 修复其他集存在重复上传时当前集导航被整条禁用；相邻集歧义需手动选择，自动连播不任意选择。
- 34 个 Mach-O 使用精确批准路径集合；正式包拒绝测试更新源，公证后生成签名 appcast 并绑定最终 DMG。
- 保持 0.8.1；正式配置由本地 Build 133 递增为 134。Android Bridge 保持 0.3.48（60）。

## 当前源码重新执行的验证

| 验证 | 结果 |
| --- | --- |
| Release App XCTest | 1,234 项，1,218 通过、16 条件跳过、0 失败 |
| OKVideoKit | 1,036 项，1,014 通过、22 条件跳过、0 失败 |
| AndroidRuntimeKit | 57 项，56 通过、1 在线安装跳过、0 失败 |
| 长 GOP 原生播放/暂停/连续 Seek/片尾 | 两项定向回归实际运行通过，无跳过 |
| 跨进程音量持久化 | writer/reader 独立进程分别通过 |
| Node/CatPaw/Quark | 47 项全部通过 |
| Android Bridge | 签名 APK 构建及 34 JVM 测试通过，lint 0 error、8 warnings；保留既有 warning/metadata 诊断 |
| SourceAudit | 32 项全部通过，包含独立 launcher 的 7 项及新增 appcast 门禁 |
| CoreAudio 故障注入 | 实际编译源码的 3,200 个场景通过 ASan/UBSan；残留 AudioUnit/监听器为 0 |

首次全量 App 运行有 4 项失败：3 项截图证据输出目录未创建、1 项测试宿主缺少签名 APK。补齐现有测试前置条件后完整重跑通过，未改断言或排除这些项目。Android lint 首次缺少 SDK 环境；使用现有构建脚本相同 SDK/JDK 配置重跑通过。

App 条件跳过包括需独立进程、长 GOP/窗口真实渲染、专用 EPG fixture、真实 Runtime/提供方/公网输入的项目。独立执行的项目另记，未运行的条件项目不计通过。前序 8 个真实 Sparkle 安装场景与 Build 133 原生分集演练作为历史证据保留，不混作本次新产物的结果。

## 硬件与发布边界

用户已反馈蓝牙耳机测试正常；本轮没有逐项重新执行真实硬件验证。AirPods 连接、摘下/断开、蓝牙重连、系统输出切换、人工听音逐项仍为 NOT_TESTED。

Apple 公证预检曾返回协议 HTTP 403；用户处理协议后，原 OKVideoMac-Notary profile 已恢复查询历史记录。此前 0.8.0 Accepted 身份一致，未重新导入证书、未更换公证凭据。正式产物必须重新取得 Accepted；历史状态不替代本次公证。
