# Legal and Security

- 项目以 FongMi/TV 的 GPL-3.0 协议和业务行为作为兼容参考，保留来源与修改说明。
- 不内置未经授权的影视源、配置、解析服务、账号、Cookie、Token 或 DRM 密钥。
- 测试只使用本地生成、保留域名 `example.invalid` 和明确授权的公开媒体。
- 不实现 DRM 绕过、付费验证绕过、凭据收集或远程 Shell。
- QuickJS Host API 不提供文件和进程访问；网络必须经过应用 HTTP 策略。
- WKWebView 使用非持久化存储，拦截危险 Scheme，消息桥仅接收媒体候选 URL。
- 配置可能包含用户主动提供的敏感 Header。离线副本不可避免地保存原始配置，
  但应用不复制这些字段到历史表，日志和诊断包必须脱敏。
- App Sandbox 在非 App Store MVP 中关闭；这不是安全保证。所有输入验证仍必须
  在应用层执行。

