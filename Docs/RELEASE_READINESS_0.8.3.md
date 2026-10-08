# OKVideoMac 0.8.3（Build 136）发布就绪记录

日期：2026-10-09。状态：正式发布完成；回归、Apple 分发门禁及 16 个公开资产核验通过。

基线：公开 main `3529d05`（0.8.2 / Build 135）。仅在公开隔离工作树修改，商业工作树保留原状。范围见[发布说明](RELEASE_NOTES_0.8.3.md)和[侧栏技术记录](SIDEBAR_DIVIDER_FIX_20261008.md)。

当前实现回归覆盖零宽分隔、左右独立材质、五个导航页标题栏像素、按钮对象和坐标稳定、折叠展开、搜索外观/提示对比、主题最初帧，以及 APK 资源错误分类。此前预览定向回归 27 项通过，实际 App Android 启动与停止通过；这些不替代本次正式构建门禁。

按现有规则先验证代码并固定本地发布提交，再从干净 main exact commit 执行 `package-app.sh --mode distribution --notarize`。只有签名、Apple Accepted、staple、Gatekeeper、最终 DMG/安装 smoke、source/SBOM 绑定和签名 appcast 全部通过，才推送 main/tag 并公开 16 个资产。发布后补录实际结果，不移动 tag 或修改已签名产物与源码快照。

条件跳过不计通过；Mission Control 人工合成、云盘账号、真实硬件与完整站点矩阵不冒充自动结果。既有 native provenance 例外保留。

## 当前回归进展

- OKVideoKit：1,036 项，1,014 通过、22 条件跳过；AndroidRuntimeKit：68 项，67 通过、1 条件跳过，均 0 失败。
- SourceAudit：32 项全部通过，含独立签名 launcher fixture；Node：47 项全部通过。
- Android Bridge JVM：34 项全部通过；Release lint：App 0 error / 8 warnings、catvod 0 error / 3 warnings，均为既有 warnings。
- 缺失 APK 的真实 Release embed phase 明确返回 1；待提交文件敏感信息扫描干净。
- App 首轮暴露先前误改的播放器恢复断言，已恢复原始不透明标题栏预期。第二轮在 Android 进程夹具的 1 秒就绪等待处超时；改为最多 5 秒并保留同一就绪标记、进程存活和全部生产身份断言，超时附带明确诊断。最终全套 1,249 项：1,232 通过、17 条件跳过、0 失败。原始失败日志保留，未删除失败用例或放宽身份验证。

## 固定发布提交前验证

当前代码最终全套 App 回归再次通过：1,249 项，1,232 通过、17 条件跳过、0 失败。当前 Release 测试 App 通过真实 SDK 启动、Bridge ready、adbEmuKill 关闭和应用退出；专用 ADB 监听已关闭。

临时验收入口先在 actor、后在主派发队列请求退出时，都阻塞了 AppKit 嵌套退出循环中的异步清理。独立最小 AppKit 对照证明 RunLoop 定时回调可正确退出；测试入口采用该方案后实际复验通过，不改生产退出流程。该入口仅在性能测试编译条件和显式验收环境变量下可用，正常发布包不包含它。失败日志与采样保留在本地，不进入发布资产。

本次预提交测试、文档门禁、diff 检查、敏感信息扫描通过。正式分发结果见下方及同版本正式验证记录；构建时准备说明保留在不可变源码包中。

## 正式发布结果

干净 main exact commit `2d00518dbdf0eba6f91c60483d522fd10e7bee3d` 已按既有流程重新构建；Apple Accepted（`105f049e-55f9-4c61-b365-e5dab1ab3f9f`）、staple、Gatekeeper、安装 smoke、源码绑定与签名 appcast 全部通过。实际 App Android 启动/Bridge/关闭与验收入口退出复验通过。main 与固定 tag v0.8.3 已推送，16 个资产公开下载逐项 SHA-256 一致，桌面入口已更新。首次时间戳签名失败确认为 HTTP 代理截断 Apple 响应；临时仅直连时间戳域名后按原策略重跑成功，代理配置已恢复。详见[完整验证](RELEASE_VALIDATION_0.8.3.md)。发布后文档不改变 tag 或签名资产。
