# OKVideoMac 0.4.2（Build 97）Release Notes

候选构建日期：2026-09-06

发布状态：本地热修复候选包，尚未创建 Tag 或 GitHub Release

平台：Apple Silicon / arm64 / macOS 12.0+

0.4.2 针对用户机器上 Android Runtime 冷启动长期停留在
`emulator-5554 offline` 的故障链进行热修复。

## 已确定修复

- ADB transport 使用独立的 180 秒单调时钟窗口；只有 serial 进入
  `device` 后才进入原有约 240 秒的 Android guest boot 等待。
- 前 20 秒 `offline` 不做恢复操作；宽限期后最多针对目标 serial
  reconnect 一次，其时间、返回码、输出与前后状态独立持久化。
- 所有 OKVideoMac ADB 调用都显式使用所选 SDK 及私有高位端口；
  Emulator 继承同一路由。不连接、重启或关闭默认 5037 server。
- 只在 host GPU Emulator 存活、ownership 始终正确且完整 180 秒
  仍为 offline 时，才会安全停止自有实例并以 software GPU 重试一次。
- 成功 GPU backend 会写入私有 Runtime profile。两种后端都失败时
  返回需要修复的明确状态，不自动 wipe userdata。
- 设置页新增“修复 Android Runtime”。它会在明确停止自有 Emulator
  后，把专用 AVD、companion `.ini` 和有限元数据移到可恢复备份，
  然后只使用用户已选 SDK 中已存在的兼容 arm64 image 重建。
- Build 97 修复 API 24 旧镜像无法通过现代 boot property 接收新生成
  私有 ADB 公钥的闭环缺口。仅 API 24–29 的 OKVideoMac 私有无窗口
  Emulator 使用官方 `-skip-adb-auth` 兼容开关；API 30+ 认证路径不变。
- 诊断现在记录 ADB 认证模式、实际是否启用兼容开关及选择原因。

## 边界与已知限制

- 重建专用 AVD 会重置 Android Runtime 内部状态，部分授权可能需重新登录；
  OKVideoMac 普通设置、收藏和历史不受影响。
- 用户日志已排除 GPU、旧 userdata、私有 ADB server 和 keypair 文件
  错误；API 24 Guest 未获得该公钥是已定位的失败机制。
- 本机没有 API 24 / Emulator 37.1.11 环境，未为此测试下载、删除或
  修改任何 SDK。`-skip-adb-auth` 在该精确用户组合上的恢复效果
  仍需受影响用户安装 Build 97 后验证。

## 验证

- macOS Xcode：629 total / 625 passed / 4 intentionally skipped / 0 failed。
- 10 路并发启动仍共享一个 process-wide startup task；即使进入 GPU
  fallback，也只有一条 workflow。
- 单元/fake process 覆盖 90 秒 offline 后恢复、宽限期、有界 reconnect、
  private ADB、GPU fallback 与 AVD repair isolation。
- 本机 API 35 私有 ADB A/B 可从 `offline` 转为 `device`，且 Build 97
  不会对 API 30+ 添加兼容开关；本机未安装 API 24 镜像。

---

# OKVideoMac 0.4.2 (Build 97) Release Notes

Candidate date: 2026-09-06

Status: local hotfix candidate; no tag or GitHub Release has been created

Platform: Apple Silicon / arm64 / macOS 12.0+

This hotfix separates ADB transport from Android boot, isolates OKVideoMac on
a private selected-SDK ADB server, allows one delayed targeted reconnect, and
bounds recovery to one host-to-software GPU fallback. If both backends fail,
Settings can rebuild only the private AVD after moving it to a recoverable
backup. No user Android Studio AVD, global ADB server, SDK, favorite, history,
or normal setting is modified.

The user evidence rules out GPU selection, stale userdata, private ADB server
selection, and malformed private key files. Build 97 adds the Emulator's
official `-skip-adb-auth` compatibility option only for the private headless
API 24–29 runtime; modern API 30+ images retain isolated private-key
authentication. The affected API 24 machine is still required to validate the
recovery result.
