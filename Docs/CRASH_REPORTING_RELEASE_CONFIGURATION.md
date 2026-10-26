# 崩溃上报的源码与正式包配置

公开源码保留捕获、过滤、恢复、授权、上传、重试与清理的完整实现，`OKVIDEOMAC_CRASH_REPORT_DSN` 默认为空。普通源码或 local 构建只保留本机报告，界面显示服务未配置。

官方 distribution 打包必须提供仓库外的、当前用户拥有且仅属主可读的普通配置文件（建议 `chmod 600`）。文件只允许一个 `SENTRY_DSN` 键；值必须是无 secret/password/query/fragment 的公开 HTTPS DSN。禁止把管理令牌或符号上传凭据放在该文件中。

```sh
Scripts/package-app.sh --mode distribution --notarize --crash-config /absolute/private/path/app.env
```

同时按既有流程设置 Developer ID 身份、公证 Keychain profile 和发布更新通道。配置在 Xcode 构建完成后写入临时 App 的 Info.plist，再完成资源、签名、公证与最终 DMG 验证；不会修改 project.yml、Xcode 工程或源码快照。配置值不出现在打包命令行和日志里；只出现配置文件路径。源码归档门禁检查实际 DSN 未进入归档，敏感信息扫描另外拦截 Sentry 管理令牌。

DSN 会随官方 App 分发，因此可以从安装包读取。它只用于提交事件，不是读取报告或管理账号的密钥。应使用独立生产客户端 key、后台限流和过滤，避免垃圾事件消耗配额。[Sentry 官方说明](https://www.sentry.help/en/articles/13964341-my-dsn-key-is-publicly-visible-is-this-a-security-vulnerability)。

后台管理令牌保存在构建机的私有配置，仅用于指定项目的版本登记与 dSYM 上传。上传时不附带源码包或 source bundle。最终 App/helper UUID 必须与上传的 dSYM 一致；第三方符号缺口继续公开记录。启用服务不意味着所有第三方镜像均可解析源码行。

客户端仍默认不上传。用户同意后才启动独立上传进程，发送字段白名单中的诊断数据；关闭授权会停止上传并清理本地待发送报告与缓存，已发送报告不能从本机撤回。接收配置不会更改用户授权选择。版本更新前后的既有授权继续按用户原选择执行。

新版本使用新的 build、tag、签名包与更新清单，既有已发布资产不覆盖。测试使用隔离状态与合成报告，生产报告和实际用户配置不作为验收输入。

## 发布诊断与符号归档

正式 `package-app.sh` 保留最终 App／helper 的独立符号归档及 `verified-package.json`，校验 dSYM 与最终二进制 UUID。报告使用事件发生时的原始版本与 build，不按上传时安装的版本覆盖。

现有正式打包流程不会自动向 Sentry 登记版本或上传符号。后台符号上传属于另行授权的运维操作；若执行，只上传精确匹配的 DWARF，不附带源码包，等待处理完成并核对 debug ID 后才可声明后台解析通过。本地归档、CLI 接收与实际事件符号化分别记录，第三方缺失符号和旧事件回填不视为已解决。
