# Source, Copyright, and Modification Notice

OK影视 Mac (`OKVideoMac`) is an independent native macOS implementation. Code
owned by this project is licensed under `GPL-3.0-only`; third-party material
retains its original license and copyright.

## Independent macOS implementation

Much of the Swift, SwiftUI, AppKit, SQLite, networking, parsing, player
integration, and packaging code independently implements macOS behavior and
interoperable protocols. FongMi/TV behavior and configuration formats were
studied at commit `5fdff00a602dc56e8ba756174daef20edab024f2`. The project is
not affiliated with or endorsed by FongMi/TV.

## Copied and modified FongMi/TV source

The preceding statement does **not** apply to the Android bridge's `catvod`
tree. `Helpers/AndroidDexBridge/catvod` is source copied from
`FongMi/TV:catvod/src/main` at the fixed commit above and then modified here.
It is compiled into `AndroidDexBridge-release.apk`, which is distributed in
the macOS App bundle.

- Upstream: <https://github.com/FongMi/TV/tree/5fdff00a602dc56e8ba756174daef20edab024f2>
- Upstream and local license: `GPL-3.0-only`
- Modified file: `catvod/src/main/java/com/github/catvod/net/Proxy.java`
- Change: the default proxy port changed from `-1` to `9978`, with an
  explanatory local comment; the manifest also contains a non-substantive
  final-newline difference.
- Complete change record: `Helpers/AndroidDexBridge/FONGMI_CATVOD_CHANGES.md`
- APK dependency inventory: `Helpers/AndroidDexBridge/THIRD_PARTY_NOTICES.md`

This is copied and modified upstream source, not merely a reference or a
clean-room implementation. Upstream copyright notices and GPL terms remain.

## Other third-party software

The Release App also distributes a GPL-enabled mpv build, an LGPL FFmpeg
build, Node.js, QuickJS, native dependency dylibs, and the Android bridge's
runtime dependencies. The authoritative consolidated index is
`THIRD_PARTY_NOTICES.md`; exact texts are in `THIRD_PARTY_LICENSES/`.
Corresponding-source and provenance status are recorded in
`Docs/BINARY_SOURCE_MAPPING.md` and `Docs/SOURCE_PROVENANCE_MANIFEST.md`.

The application does not include service credentials, media catalogs,
accounts, cookies, tokens, DRM keys, or bundled media sources.
