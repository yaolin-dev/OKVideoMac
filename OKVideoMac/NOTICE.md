# Source and Modification Notice

OK影视 Mac (`OKVideoMac`) is an independent native macOS implementation.

The configuration formats and observable application behavior were studied
from FongMi/TV, authored and maintained by FongMi and contributors:

- Repository: https://github.com/FongMi/TV
- Audited branch: `fongmi`
- Audited commit: `5fdff00a602dc56e8ba756174daef20edab024f2`
- Upstream license at that commit: GNU General Public License Version 3

This distribution does not build, bundle, or repackage the Android upstream
source tree. The Swift, SwiftUI, AppKit, SQLite, networking, parsing, player
integration, and packaging code in this repository is a new macOS
implementation. It intentionally omits Android-specific Java/Dex plugins,
Python plugins, TVBus, ForceTech, DLNA, DRM bypass, danmaku, and bundled media
sources.

The application is not affiliated with or endorsed by the FongMi/TV project.
It does not include service credentials, media catalogs, parsing endpoints,
accounts, cookies, tokens, or DRM keys.
