# OKVideoMac 0.8.2（Build 135）Release Notes

修复 Android 兼容模块“备份并重建”后的 system-image 不匹配和失败恢复问题。

- 将专用 AVD、INI、兼容性指纹及关联记录一起备份，避免新镜像被残留的旧指纹拒绝。
- 重建失败或应用中断后恢复匹配的旧数据，保留未完成的新数据供恢复，不删除用户数据。
- 重建期间固定所选镜像，检查 AVD 所在磁盘空间，并在设置页正确保留失败状态。
- 保留严格的 SDK、镜像、ABI、Emulator 身份校验和私有 ADB 密钥；Android Bridge 与第三方运行库未升级。

更新前请退出正在使用的 Android 内容。已有旧版备份应继续保留；恢复旧环境时必须匹配原 SDK 与 system image，不能直接删除不匹配指纹。磁盘空间不足时应先释放足够空间，重建不会释放旧备份的占用。云盘账号等登录状态仍需人工确认。

0.8.1 稳定通道用户可通过应用内“检查更新”升级；0.8.0 或本地测试更新源版本需手动安装正式 DMG。仅支持 Apple Silicon / arm64、macOS 12.0+。

验证与发布结果见同版本正式验证记录。构建时说明仅记录发布准备；Apple Accepted、staple、Gatekeeper 和最终资产核验全部通过后才公开发布。源码、许可证、SBOM、校验和与签名 appcast 随发布提供。现有 zlib 原始归档、历史 clang 输入等 native provenance 例外继续明确记录。

English: fixes stale system-image fingerprints after private AVD rebuilds, adds recoverable rebuild transactions and disk-space checks, and preserves terminal error states. Existing strict compatibility checks remain. Android Bridge and native libraries are unchanged. Existing backups are retained; cloud-account login state requires manual verification. Supports Apple Silicon and macOS 12.0+.
