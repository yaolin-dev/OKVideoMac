# FongMi/TV 上游分析

## 审计基线

- 仓库：`https://github.com/FongMi/TV`
- 分支：`fongmi`
- 提交：`5fdff00a602dc56e8ba756174daef20edab024f2`
- 审计日期：2026-07-29
- 上游版本：`5.5.6`
- 许可证：GNU GPL Version 3

重点阅读范围：

- `README.md`
- `docs/CONFIG.md`
- `docs/SPIDER.md`
- `docs/LIVE.md`
- `docs/LOCAL.md`
- `app/src/main/java/com/fongmi/android/tv/api/SiteApi.java`
- `app/src/main/java/com/fongmi/android/tv/api/config/VodConfig.java`
- `app/src/main/java/com/fongmi/android/tv/player/parse/ParseJob.java`
- `app/src/main/java/com/fongmi/android/tv/api/parser/LiveParser.java`
- `catvod/.../crawler/Spider.java`
- `quickjs/.../crawler/Spider.java`

## 配置结构

当前 Vod 顶层字段：

| 字段 | 语义 |
| --- | --- |
| `spider` | 全局 Spider JAR/资源引用 |
| `wallpaper`、`logo`、`notice` | 外观和公告 |
| `sites` | 点播站点 |
| `parses` | 播放解析器 |
| `lives` | 直播来源 |
| `doh`、`proxy`、`rules`、`headers`、`hosts`、`ads` | 网络规则 |
| `flags` | 平台/解析标识 |
| `danmaku` | 弹幕 API |

`sites` 当前代码字段包括：

`key`、`name`、`api`、`ext`、`jar`、`click`、`playUrl`、`type`、
`hide`、`indexs`、`timeout`、`searchable`、`changeable`、`quickSearch`、
`categories`、`header`、`style`。

上游 Java 模型会把 `ext` 规整成字符串，但实际配置生态中可出现字符串、对象和数组。
macOS 模型因此使用递归 `JSONValue` 保存原类型，并保存未知字段。

网络字段按当前 Java bean 建模：`proxy` 使用 `name/hosts/urls`，`headers`
使用单个 `host` 与可变 JSON `header`，`rules` 使用
`name/hosts/regex/script/exclude`，`doh` 使用 `name/url/ips`。

站点类型：

| type | 调用方式 | macOS MVP |
| --- | --- | --- |
| 0 | HTTP XML，`ac=videolist` | 已实现，未构建验证 |
| 1 | HTTP JSON，筛选参数为 `f=` | 已实现，未构建验证 |
| 3 | Java/JS/Python Spider | Java/Python 拒绝；QuickJS 原生桥已 smoke test，App 未验证 |
| 4 | HTTP JSON，筛选参数为 URL-safe Base64 `ext=` | 已实现，未构建验证 |

解析器字段为 `name`、`type`、`url`、`ext.flag`、`ext.header`。类型含：

- 0：WKWebView 嗅探；
- 1：JSON API；
- 2：由 JAR 扩展处理；
- 3：由 JAR 聚合处理；
- 4：并行尝试 type 0/1。

macOS MVP 直接实现 type 0/1；2/3 依赖 Android JAR 运行时，不宣称支持；4
由原生状态机完成，不调用 JAR。

## Spider 接口

CatVod 抽象方法与 QuickJS 映射：

| CatVod 方法 | QuickJS 名称 |
| --- | --- |
| `init(context, ext)` | `init(ext)` |
| `homeContent(filter)` | `home(filter)` |
| `homeVideoContent()` | `homeVod()` |
| `categoryContent(tid, pg, filter, extend)` | `category(...)` |
| `detailContent(ids)` | `detail(id)` |
| `searchContent(key, quick[, pg])` | `search(...)` |
| `playerContent(flag, id, vipFlags)` | `play(...)` |
| `liveContent(url)` | `live(url)` |
| `proxy(params)` | `proxy(...)` |
| `action(action)` | `action(action)` |
| `manualVideoCheck()` | `sniffer()` |
| `isVideoFormat(url)` | `isVideo(url)` |
| `destroy()` | `destroy()` |

上游 QuickJS 每个 Spider 使用单线程 executor 和独立 Context，但依赖 Android
`DexClassLoader` 注入额外函数。macOS 不能照搬该层；必须由受控 Host API 替换。
当前原生桥已验证全局 `spider` 对象、Promise、Base64、URL 编码、延迟、
受控 HTTP 回调、内存限制和 interrupt handler；上游 ES Module loader 与
Dex 注入函数仍需逐样本补齐，因此不得把通用 JavaScript Spider 标为 Supported。

## 点播调用链

1. `homeContent` 取得分类和筛选，随后 `homeVideoContent` 取得推荐。
2. 分类调用传入 `tid`、从 1 开始的页码、filter 开关和键值筛选。
3. 详情以视频 ID 获取完整 `Vod`。
4. `vod_play_from` 与 `vod_play_url` 均以 `$$$` 对齐线路；每条线路内以 `#`
   分集，分集通常为 `名称$URL`。
5. 播放先调用站点 `playerContent`；标准站点直接以分集 URL 形成结果。
6. `parse/jx=0` 且 URL 被识别为媒体时直放，否则进入解析器。

统一响应主要字段：

- 首页：`class`、`filters`；
- 列表：`list`、`pagecount`；
- Vod：`vod_id`、`vod_name`、`vod_pic`、详情字段、`vod_play_from`、
  `vod_play_url`；
- 播放：`url`、`parse`/`jx`、`playUrl`、`header`、`flag`、`jxFrom`、
  `format`、`subs`、`drm`、`position`。

## 解析和失败切换

上游 `ParseJob` 的单次解析选择顺序：

1. 用户强制使用当前选中解析器；
2. `playUrl` 为 `json:` 时构造指定 JSON 解析；
3. `playUrl` 为 `parse:` 时选择具名解析器；
4. 其他 `playUrl` 作为 type 0 前缀；
5. type 4 “超级解析”并行尝试匹配 flag 的 JSON 解析器和一组 WebView 解析器。

原 Android 代码用原子 `done` 保证首个成功结果胜出，超时后取消 executor 和
WebView。macOS 采用 `AsyncStream` 状态机，记录已失败组合、限制 8 次尝试，并让
UI 可观察每一步。MVP 不自动用标题搜索其他站点替换内容，避免错误匹配。

## 直播

格式识别顺序与上游一致：

1. 内容以 `[` 开头：JSON；
2. 包含 `#EXTM3U` 且不含 `#genre#`：M3U；
3. 其他：TXT。

TXT 使用 `名称,#genre#` 分组、`名称,URL` 频道，`#` 分隔备用线路，
`|key=value&...` 携带 Header。

M3U 使用 `#EXTM3U`、`#EXTINF`、`tvg-id`、`tvg-name`、`tvg-chno`、
`tvg-logo`、`group-title`、`http-user-agent`、`#EXTHTTP`、
`#EXTVLCOPT` 和行内 Header。EPG 可由 `tvg-url`/`url-tvg` 指向 XMLTV
或 gzip XMLTV。

## Android 专属与重新设计

- ExoPlayer/Media3、SurfaceView → libmpv Render API + AppKit OpenGL View。
- Room → 系统 SQLite3。
- OkHttp → URLSession。
- DexClassLoader/JAR Spider → MVP 不实现。
- QuickJS Android wrapper → 独立受限 QuickJS C Runtime。
- Chaquopy → MVP 不实现 Python。
- Android WebView → WKWebView 隔离数据存储和白名单消息桥。
- NanoHTTPD、本地文件 API、DLNA、Android Auto → MVP 不实现。
- Widevine/PlayReady、TVBus、ForceTech、JianPian、Thunder 原生库 → 不实现。

## 可无损迁移与不可承诺部分

可直接复现：配置字段、标准 HTTP 站点参数、DTO、播放线路/分集拆分、直播文本
格式、Header 合并、收藏与历史业务规则。

只能逐样本验证：JavaScript Host API、网页嗅探、特殊加密/DOM Spider、解析器
优先级的边缘行为。Java/Dex、Python、私有 P2P 和 DRM 明确不属于 MVP。
