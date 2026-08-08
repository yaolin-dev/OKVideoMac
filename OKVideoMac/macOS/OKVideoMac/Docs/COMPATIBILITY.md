# Compatibility

状态只使用 `Supported`、`Partial`、`Experimental`、`Not Implemented` 和
`Not Applicable`。在自动化或手工测试通过前不标记 `Supported`。

| 能力 | 状态 | 说明 |
| --- | --- | --- |
| 配置 URL | Experimental | 已实现，未构建测试 |
| 本地配置 | Experimental | 已实现，未构建测试 |
| 粘贴配置 | Experimental | 已实现，未构建测试 |
| sites | Experimental | 模型和校验已实现 |
| parses | Experimental | type 0 WKWebView 与 type 1 JSON 执行器已接入 |
| lives | Experimental | 模型和 UI 已实现 |
| headers 网络规则 | Experimental | host 匹配和请求 Header 合并已接入 |
| hosts / DoH / proxy | Partial | 配置可无损解析；URLSession 执行策略未接入 |
| 标准 XML 站点 type 0 | Experimental | 解析器已实现 |
| 标准 JSON 站点 type 1 | Experimental | 解析器已实现 |
| Base64 JSON 站点 type 4 | Experimental | 参数编码已实现 |
| JavaScript Spider | Partial | QuickJS C 桥 smoke test 通过；Swift/App 未经 Xcode 构建 |
| Java JAR/DEX Spider | Not Implemented | MVP 排除 |
| Python Spider | Not Implemented | MVP 排除 |
| WebView Sniffer | Experimental | 代码已实现，未运行验证 |
| M3U | Experimental | 解析代码和测试已写 |
| TXT Live | Experimental | 解析代码和测试已写 |
| JSON Live | Experimental | 解析代码和测试已写 |
| XMLTV EPG | Experimental | XML/gzip、6 小时缓存和当前/下一节目已写 |
| libmpv | Partial | C/Swift Client 与 OpenGL Render 源码已写，C 语法检查通过，未构建/链接/播放 |
| 媒体 Header | Partial | 使用结构化 node array 传入 libmpv，未运行验证 |
| 外挂字幕 | Partial | 播放窗口和 sub-add 命令已接入，未运行验证 |
| 自动换源 | Experimental | 直链/JSON/Web/下一线路与播放器初始加载错误回退已接入，未运行验证 |
| DLNA | Not Implemented | MVP 排除 |
| 本地 HTTP API | Not Implemented | MVP 排除 |
| TVBus | Not Implemented | 私有 P2P |
| ForceTech | Not Implemented | 私有引擎 |
| DRM | Not Implemented | 不实施绕过 |
