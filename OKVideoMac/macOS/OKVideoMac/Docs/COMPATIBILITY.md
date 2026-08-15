# Compatibility

- 对照版本：0.3.41（Build 63）
- 最近更新：2026-08-15
- 当前交付目标：Apple Silicon / arm64 / macOS 12.0+

## 状态定义

- `Supported`：实现完整，且已有自动化或实机验证证据。
- `Partial`：主路径可用，但仍有已知协议、编码或场景缺口。
- `Experimental`：已接入，但上游兼容面、长时稳定性或安全边界尚未充分验证。
- `Not Implemented`：尚未实现或明确不在当前范围。
- `Not Applicable`：项目明确不提供该能力。

`Supported` 不表示任意第三方影视源都会永久可用；它只表示客户端对应路径有
可重复的验证证据。

## 用户功能

| 能力 | 状态 | 证据与限制 |
| --- | --- | --- |
| 配置 URL | Supported | 规范化、加载、取消、原子持久化与失败隔离有自动化测试 |
| 本地配置和 Finder 打开 | Supported | 只接受用户选择或 Finder 传入的本地文件 |
| 粘贴内容配置 | Supported | 同事件粘贴同步、大小限制、重复 key 与未知字段处理有测试 |
| 首页、分类、筛选和详情 | Supported | 完整 App 测试和 Release 构建通过 |
| 多站搜索、去重和排序 | Supported | 并发、错误隔离、稳定标识和聚合规则有测试 |
| 收藏、历史和播放进度 | Supported | SQLite 迁移、恢复与归属隔离有测试 |
| M3U / TXT / JSON 直播解析 | Supported | 解析器和边界条件有 OKVideoCore 测试 |
| XMLTV / gzip / EPG 缓存 | Supported | 解压限制、解析、缓存和当前/下一节目有测试 |
| 弹幕 | Not Implemented | 配置字段可保留，尚未接入播放层 |
| 自动更新 | Not Implemented | 尚无版本检查、下载和可恢复安装流程 |

## 站点与 Spider 协议

| 能力 | 状态 | 证据与限制 |
| --- | --- | --- |
| `sites` / `parses` / `lives` 配置模型 | Supported | 解析、未知字段保留和校验有自动化测试 |
| 标准 XML 站点 type 0 | Supported | 列表、详情和播放响应解码有 fixture 测试 |
| 标准 JSON 站点 type 1 | Supported | 字段归一化和异常响应有 fixture 测试 |
| Base64 JSON 站点 type 4 | Partial | 参数编码和主路径已实现，不保证所有私有扩展等价 |
| Headers 网络规则 | Supported | host 匹配、Header/Cookie 合并和日志脱敏已接入 |
| `hosts` / DoH / proxy | Partial | 配置可无损解析，但 URLSession 执行策略尚未完整对齐上游 |
| QuickJS JavaScript Spider | Partial | C/Swift/App 路径可构建且 smoke test 通过；上游 bundle 兼容面仍需持续样本验证 |
| Node.js Spider | Experimental | Release 仅使用 App 内置 Node；冷启动与并发调用共享 readiness，保留上游 MD5，并对远程 bundle 增加 SHA-256、最终 URL 与缓存执行前校验；远程 bundle 仍具有 Node 完整能力 |
| Android Java/DEX Spider | Experimental | Release APK 可构建和验证；使用专用 AVD、动态 serial 和所有权校验，不操作用户 Emulator；仍依赖已安装的外部 Android SDK/ADB/Emulator 与 arm64 system image |
| Python Spider | Not Implemented | 当前不提供 Python 运行时 |
| WebView Sniffer | Experimental | WKWebView 嗅探和候选媒体上报已接入，但网页行为依赖具体站点 |

### 远程 Node bundle 信任规则

- HTTPS bundle 可沿用现有 `.js.md5` 地址；下载后仍保存并复验内部 SHA-256。
- 如果 MD5 文件或可执行脚本重定向后的最终 URL 任一为 HTTP，配置地址必须携带可信 SHA-256：
  `http://example.com/index.js.md5#sha256=<64位十六进制>`。
- 建议同时声明源身份和版本，例如：
  `#sha256=<64位>&source=my-source&version=2026.08.12`。URL、源身份和版本共同参与缓存隔离；版本更新必须提供新内容对应的 hash。
- URL fragment 只用于本地信任判断，不随网络请求发送。缓存文件每次进入执行路径都会重新计算 MD5 和 SHA-256。
- 该规则只约束会由 Node 执行的 `.js.md5` bundle；普通 HTTP 配置、影视 API、M3U8、直播、图片、字幕和 XMLTV 不受影响。

## 播放器

| 能力 | 状态 | 证据与限制 |
| --- | --- | --- |
| libmpv Client / Render API | Supported | arm64/macOS 12 Release 构建、动态依赖闭包、实机播放和生命周期实验通过 |
| 点播、直播和基本控制 | Supported | 播放/暂停、Seek、音量、静音、倍速、切集和全屏已接入 |
| 媒体 Header | Supported | 使用结构化 mpv node array 传递，不拼接命令字符串 |
| 音轨和字幕轨 | Supported | 轨道列表、偏好匹配和切换策略有单元测试 |
| 外挂字幕 | Partial | `sub-add` 路径已接入；仍需扩大字符集、容器和远程字幕样本覆盖 |
| 截图、画面比例和硬解 | Supported | UI 与 mpv 命令已接入，Release 实机播放路径通过 |
| 初始加载失败自动换源 | Supported | 最多 8 次去重尝试、下一解析器/线路和旧请求隔离有测试 |
| 播放中途断流自动恢复 | Partial | 初始加载失败已覆盖，长播中途断流的多源自动恢复尚未完整验证 |
| 退出播放器完整销毁 | Supported | 10 轮 A/B 与 8 类极端生命周期场景通过；保留 `warmStop` 回退开关 |

## 平台与发布

| 能力 | 状态 | 证据与限制 |
| --- | --- | --- |
| Apple Silicon / arm64 | Supported | App 和全部 bundled Mach-O 均在打包时强制验证 arm64 |
| macOS 12.0+ | Supported | Info.plist 和全部 Mach-O `minos` 由包体脚本验证 |
| Intel Mac / Universal Binary | Not Implemented | 当前只交付 arm64 |
| 本地 Hardened Runtime 包 | Supported | ad-hoc 签名，仅主 App 使用开发期 Library Validation 例外 |
| Developer ID 分发 | Partial | 显式 nested-code 签名与权限校验流程已实现，尚无真实证书验收 |
| Notarization / Staple / Gatekeeper | Partial | 脚本路径已实现，尚未用真实发布凭据在干净机验收 |
| App Sandbox | Not Applicable | 当前为 Developer ID 外部分发目标；Sandbox 与 Hardened Runtime 是不同边界 |

## 明确不提供

| 能力 | 状态 | 说明 |
| --- | --- | --- |
| DRM 绕过 | Not Applicable | 项目不提供 DRM 密钥或绕过能力 |
| TVBus / ForceTech | Not Implemented | 私有 P2P/闭源引擎不在当前实现范围 |
| DLNA | Not Implemented | 尚未实现设备发现和投屏流程 |
| 本地公开 HTTP API | Not Implemented | Node 内部回环服务不属于公开对外 API |
