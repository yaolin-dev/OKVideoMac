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

正式打包后使用 `Scripts/upload-crash-symbols.py --app APP --archive ARCHIVE --config PRIVATE_SYMBOLS_ENV --cli SENTRY_CLI --receipt RECEIPT.json` 执行已授权的符号上传。脚本先重新验证最终 App 和归档 UUID/hash，只上传匹配的 DWARF，禁止 source bundle，并等待服务端处理完成。私有配置仅包含 SENTRY_ORG、SENTRY_PROJECT、SENTRY_AUTH_TOKEN，须位于仓库外且仅属主可读。未取得成功 receipt 不声明后台符号已就绪。本地归档、CLI 接收与实际事件符号化分别记录，第三方缺失符号和旧事件回填不视为已解决。

## Build 205 诊断字段

诊断记录在原有信号、线程、模块与版本信息之外，保留 PLCrashReporter 提供的 Objective-C 异常名称、脱敏后的原因和首次抛出栈。Sentry 的 exception 栈使用首次抛出栈，threads 仍保存最终终止现场；没有原始异常或原始栈时明确标记不可用，不用终止栈冒充首次抛出。原因字符串限长 2048 字符，移除 URL、路径、邮箱、凭据、引号内值和对象地址；完整原文仅留在本机原生报告。

原生报告 customData 在启用崩溃处理器前一次性写入版本和随机会话标识，运行期间保持不变。最近 32 条诊断操作以本机原子快照保存，恢复时只读取原报告对应的会话，重启后不会混入新会话。PLCrashReporter 1.12.2 的 customData setter 会释放旧缓冲区，因此不用于运行期间的动态操作记录；快照写入途中崩溃仍可读取上一次完整记录。快照仅属主可读，最多 3 份、7 天，关闭上报执行清理时一并清除。仅允许固定枚举的页面、详情、搜索、播放状态、输入类别和窗口事件；不读输入文字、片名、地址、控件文本或稳定用户标识。操作序列是排查线索，不把最后一条状态变化自动判定为根因。观察器不发布业务状态、不触发布局、不拦截或修改输入。

模块先按所有栈地址匹配，再应用 4096 项上限，优先保留被引用模块和 App 模块，同时记录省略数量。原生输入仍限 1 MiB，JSON 记录上限为 4 MiB，以容纳地址的文本编码；上传进程另有 8 KiB 的配置包余量。

原生报告在转换前保存到诊断目录 native-archive，仅属主可读，最多 3 份、7 天，不传入上传进程。转换失败保留原生备份；备份失败不清理或覆盖唯一原文件。关闭上报并执行清理时同时清除该归档。测试入口只存在于独立的 Swift Package 测试产品，不链接进正式 App。
