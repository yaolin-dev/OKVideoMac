# Third-Party Licenses

| 组件 | 固定版本/基线 | 许可证 | 用途 | 当前状态 |
| --- | --- | --- | --- | --- |
| FongMi/TV | `5fdff00` | GPL-3.0 | 协议和行为参考 | 已审计，不参与构建 |
| mpv | v0.41.0 | GPL-2.0-or-later 默认构建 | 播放器 | 未构建/未链接 |
| FFmpeg | 构建期解析版本 | LGPL/GPL 取决于选项 | libmpv 编解码 | 未构建 |
| libass | 构建期解析版本 | ISC | 字幕 | 未构建 |
| QuickJS | 2025-09-13-2 | MIT | JavaScript Spider | arm64 原生桥已构建；App 未验证 |
| SQLite | macOS 系统库 | Public Domain | 持久化 | 代码已接入 |
| zlib | macOS 系统库 | zlib License | gzip XMLTV | 代码已接入 |

发布前必须把最终构建解析出的完整依赖版本和许可证文本写入应用资源和发布包。
