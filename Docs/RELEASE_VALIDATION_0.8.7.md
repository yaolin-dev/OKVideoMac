# OKVideoMac 0.8.7（Build 140）正式发布验证记录

日期：2026-10-17。[GitHub v0.8.7](https://github.com/yaolin-dev/OKVideoMac/releases/tag/v0.8.7) 已公开、非 Draft、非 Prerelease、latest。桌面正式版已安装并重新打开。

## 固定身份与本轮范围

- Release commit `8208c1ea6db514cb35bbd32bbed8a15ade06cb03` 从干净 main 通过现有 `package-app.sh --mode distribution --notarize --crash-config FILE` 构建；annotated tag `v0.8.7` 固定该提交。没有使用商业工作树或本地验收 DMG 充当正式构建。
- App **0.8.7（140）**；Android Bridge **0.3.48（60）**，依赖版本保持。Apple Silicon arm64，最低编译目标 macOS 12.0；构建／测试机 macOS 14.8.9、Xcode 16.2／SDK 15.2。没有据此扩大其他系统或硬件的运行保证。
- 本轮收尾包含回放与日期 EPG／Native Xtream 归档、原生画中画、播放信息、启动／播放器控制栏，以及历史选中、详情保留、夸克历史身份和标题栏材质修复。见[发布说明](RELEASE_NOTES_0.8.7.md)。
- 复用现有 Developer ID、Keychain 公证 profile、稳定更新通道和公开客户端接收配置。私有配置仅在仓库外属主专用文件中使用；源码／源码归档服务地址留空。未提交证书、密码、管理令牌或测试／构建产物，未改变用户的崩溃上传授权。

## 验证结果

| 项目 | 结果 |
| --- | --- |
| 全量 Release App XCTest | 1352 通过、0 失败、15 条件跳过；共1367 |
| Release Core／Persistence | 1067 通过、0 失败、22 条件跳过；共1089 |
| SourceAudit／原生启动器 | 42 通过、0 失败、0 跳过 |
| 崩溃发布配置／隐私回归 | 15 通过、0 失败 |
| 源码与文档 | 构建前994个源码文件敏感信息检查 CLEAN，版本／文档／diff whitespace 通过；最终源码归档与完整 App／发布资产扫描通过 |
| Developer ID／Hardened Runtime | 36个精确批准 Mach-O 镜像、架构／最低目标／依赖闭包／entitlements／strict deep 签名通过，Team `KGG363ABK9` |
| Apple Notarization | **Accepted** `7fdc4022-c334-4d22-b702-a71103687b49`；独立 info 与 Apple log 复核 Accepted，issues 为 null |
| Staple／Gatekeeper | 最终DMG及独立／安装App的 ticket 验证通过；DMG、盘内App及安装App均为 `Notarized Developer ID`；DMG `hdiutil verify` 通过 |
| Hardened Runtime 运行 | QuickJS、MPV／FFmpeg、Node／V8 JIT通过；现有脚本的5秒App检查使用隔离测试数据目录，SIGTERM结束，不充当正常退出证据 |
| 安装与正式身份启动 | 安装文件字节、链接和执行权限一致，独立签名／ticket／Gatekeeper／bundle通过；实际用户配置下主窗口持续可见32.018秒，Cmd-Q正常退出后无残留主程序，并重新打开供用户使用 |
| 公开资产与稳定更新 | 16项资产在Draft下载核验后公开，公开后匿名下载SHA-256／GitHub digest一致；latest feed字节、XML与最终下载DMG EdDSA签名通过 |

窗口观察时长包含 CUA 调度时间，不是启动耗时基准。桌面入口指向 `Applications/OKVideoMac-0.8.7-build140.app`；旧App目标及 `Desktop/OKVideoMac-backups` 内入口备份保留。未重新配置用户 SDK／AVD 或启用自动更新。

## 初轮失败与实际处理

初轮完整测试发现浅色标题栏分区亮线，修复为只覆盖标题栏的连续原生材质，保留不拦截正文点击的行为和原像素断言。主题夹具根据请求主题确定期望值，保留最初三帧检查；长GOP夹具明确真实窗口尺寸、前置呈现和直接本地传输，首帧、播放／暂停、连续跳转、片尾和退出原断言全部通过。原失败记录保留，没有用跳过或放宽断言替代修复。

SourceAudit的旧镜像计数由34对齐现有精确清单36，仍拒绝缺失、额外和同数量替换。原生启动器在旧App运行时按保护规则拒绝；正常退出旧版后42项全部复验通过，保护未移除。本次正式打包一次完整成功；Apple等待期间只读检查过代理，未修改系统代理，也未重传、重签或绕过Accepted门禁。GitHub草稿按tag查询404后改用同一Release ID核验；资产直连下载缓慢，改为仅对本次下载使用现有代理，保留哈希已通过的文件，没有重复创建或覆盖上传资产。

## 不变性与未扩大的范围

- v0.8.5／v0.8.6 的release ID、16项资产ID／大小／digest和tag对象保持；新文档不改变本次tag、签名资产或构建时源码／notes快照。内部ZIP不作为公开资产。
- 15项App条件跳过仍包括真实隔离Android生命周期／AVD、外部Node Contract B、公网渲染和显式30分钟／资源门禁；22项Core跳过为显式XMLTV loopback／内存／可行性实验。没有把这些项目计为通过。
- 本轮未重测其他Mac／macOS12／27、蓝牙／耳机、长期睡眠／功耗、完整泄漏普查或Sparkle完整更新安装周期。服务端回放取决于账号、保留期、时区及EPG覆盖。画中画使用动态检查的私有系统接口，不保证所有系统版本。
- 最终App／helper匹配的本地符号归档已生成并由流水线核验；本轮未上传新dSYM或重做后台合成事件解析，第三方符号缺口不视为已解决。现有原生来源／可复现性例外继续按source index、provenance及notices记录。
- 当前没有阻塞本次测试、签名、公证、安装或公开发布的未解决失败。

## 公开资产 SHA-256

| 文件 | SHA-256 |
| --- | --- |
| `OKVideoMac-0.8.7-AndroidDexBridge-release.apk` | `08d8d8dfdb704baac6ef83c5d392f1642ff3c25baf84cc539fce0c4d9e165b9c` |
| `OKVideoMac-0.8.7-build140-SHA256SUMS` | `bf8767089611ede49ac70468eda62a904481dd879b930334d87e8b146146dba4` |
| `OKVideoMac-0.8.7-build140-SOURCE_RELEASE_INDEX.json` | `aa9abb53cad9c364b602c3c8cb0c709a798ac13d0e3e31d85ee960630142135e` |
| `OKVideoMac-0.8.7-build140-SOURCE_RELEASE_MANIFEST.json` | `c805251b98c7c42fd73ca54dd394369552a9eb23a7c4bb3cde075c6f11bef9d2` |
| `OKVideoMac-0.8.7-build140-licenses.tar.gz` | `bc9d51216dd30251bac1bc315b8d0f3b42f584fedfdc2f4b051562231fb46197` |
| `OKVideoMac-0.8.7-build140-source.tar.gz` | `fa66ec398398932850da9979a18114ad861eef015b94306f79b87bdb766e121e` |
| `OKVideoMac-0.8.7-build140-third-party-source.tar.gz` | `7fff1e4263bd487d50a0071a968a64d065d2a8b761c4b093cdd08feda6f2f076` |
| `OKVideoMac-0.8.7.dmg` | `c7edf4f13db98098d5872e3bed04a611ef42c58e53167e46e9a4551fb5d34204` |
| `OKVideoMac-0.8.7.dmg.sha256` | `fcfca4db7451bff5229a078e3f3fe9a5dfc497913ca4ae6f2698ee5403cbbb89` |
| `OKVideoMac-Android.cdx.json` | `e7275844b02c1fa9c0ecaae1b50a5285489dc58c15666c7473f421706099822a` |
| `OKVideoMac-Android.spdx.json` | `c7bd676fdff5a4b61918296b38d58c0d77e38ca7477abcf3299d8b89508ac953` |
| `OKVideoMac-macOS.cdx.json` | `3ec7e8bf90e90d643bef8b7bbd60f63c76338d9a8ac5e8f51bcb62e2e360a53f` |
| `OKVideoMac-macOS.spdx.json` | `17be9244e91aaa747acef2e5617fa0cb8e16ad4a995696305156c5294d4ce7b7` |
| `RELEASE_NOTES_0.8.7.md` | `a43b3834a07cb43eb22bfb69c00e9df272428830f1668c6494fadaeea085e89e` |
| `THIRD_PARTY_NOTICES.md` | `738eba9127b512044cb36071be8755302e0df64b32c697c2bc2962a97cd15c58` |
| `appcast.xml` | `649f8e7a6fdfc775221a15819ad09fa46b75aa1681894a67bb15d50a25abd4f9` |
