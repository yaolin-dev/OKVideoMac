# OKVideoMac 0.3.41 (62) Binary → Source Mapping

This document answers which fixed source corresponds to each binary distributed
in OKVideoMac 0.3.41 (62). It does not claim that a public source-release URL
already exists. Where publication or reproducible-build evidence is missing,
the status remains explicit.

The project-code baseline is Git commit
`c0c145896a78749bc811d2af98621518fb58902c`. The Phase 1 compliance commit adds
only legal resources and legal packaging/verification. A formal source release
must archive the project commit plus all referenced third-party source inputs;
using a moving `main`, `master`, or `latest` URL is not acceptable.

| Distributed binary / content | Fixed corresponding source | Changes / build relationship | Release source status |
| --- | --- | --- | --- |
| `Contents/MacOS/OKVideoMac` | project commit `c0c145896a78749bc811d2af98621518fb58902c`, plus the Phase 1 legal-only commit | Xcode Release arm64 build | Fixed locally; public release tag/archive pending |
| OKVideoKit code linked into the executable | `macOS/OKVideoMac/Packages/OKVideoKit` at the same project commit | project source, `GPL-3.0-only` | Fixed locally; public archive pending |
| `libOKMPVBridge.dylib` | `macOS/OKVideoMac/Bridges/OKMPVBridge` and build script at the same project commit | project bridge dynamically linked to the patched mpv build | Fixed locally; public archive pending |
| `libmpv.dylib` | [mpv v0.41.0 archive](https://github.com/mpv-player/mpv/archive/refs/tags/v0.41.0.tar.gz), SHA `ee21092a5ee427353392360929dc64645c54479aefdb5babc5cfbb5fad626209`, plus `Patches/mpv-0.41.0-coreaudio-without-cocoa.patch`, SHA `f57fa49d8916d3ffc3834bb3f2a53b041c0113984bbd9f3ef6b68257b3c0af9f` | GPL-enabled Meson build; modified source | Exact inputs mapped and retained; combined corresponding-source release archive pending |
| FFmpeg six-dylib family | [FFmpeg 7.1.4 archive](https://ffmpeg.org/releases/ffmpeg-7.1.4.tar.xz), SHA `71f4aac3573ed9060489cb62526a6c7dda815ae10993789611acd7be9fa9fbf4` | LGPL configuration is recoverable from binaries; complete replay script/log is not retained | `PARTIAL`; publish exact archive/config and create reproducible recipe in Phase 2 |
| `libass.9.dylib` | [libass 0.17.5 archive](https://github.com/libass/libass/releases/download/0.17.5/libass-0.17.5.tar.xz), SHA `fa286fc9ee1ba3b932703a3df7b8474d01dc8abe29ec69b6fa68781dc4bf7acc` | retained source matches version; complete binary replay not proven | `PARTIAL` |
| `libharfbuzz.0.dylib` | [HarfBuzz 14.2.1 archive](https://github.com/harfbuzz/harfbuzz/releases/download/14.2.1/harfbuzz-14.2.1.tar.xz), SHA `a54a5d8e9380a41fbb762ce367bcbf7704792dfca0d93f1bbca86c5a57902e0e` | retained source matches version; complete binary replay not proven | `PARTIAL` |
| libplacebo, FreeType, FriBidi, Brotli, Little CMS, libpng, libjpeg-turbo, XZ/liblzma, SQLite, GNU libiconv, bzip2, zlib, libc++ and libc++abi dylibs | exact versions and Portfile source checksums in `SOURCE_PROVENANCE_MANIFEST.md`; retained MacPorts receipts/Portfiles | recursively copied dynamic inputs; full build batch/log not retained | `PARTIAL`; Phase 2 must create a locked native dependency build and source bundle |
| `libOKQuickJS.dylib` | project bridge at fixed commit plus [QuickJS 2025-09-13-2](https://bellard.org/quickjs/quickjs-2025-09-13-2.tar.xz), SHA `996c6b5018fc955ad4d06426d0e9cb713685a00c825aa5c0418bd53f7df8b0b4` | unmodified QuickJS archive is force-loaded statically into project bridge | Exact inputs mapped; public release archive pending |
| `Contents/Resources/NodeRuntime/node` | [official Node 22.23.0 darwin-arm64 archive](https://nodejs.org/download/release/v22.23.0/node-v22.23.0-darwin-arm64.tar.gz), SHA `e0f383a215dd3093de6d2c74f87056dc2306a2e09ad494cbffdba28f89046f56`; [source archive](https://nodejs.org/download/release/v22.23.0/node-v22.23.0.tar.gz), SHA `61fd42cd1c3ff04a849f5ad5d08c58b111831944b5b94bc90fc623eab41418a2` | copied official binary is re-signed with project entitlements; no source patch | `VERIFIED`; mirror/reference the fixed source archive in release materials |
| `AndroidDexBridge-release.apk` project code | `Helpers/AndroidDexBridge` at the fixed project commit | Gradle 8.9 Release APK | Fixed locally; complete APK corresponding-source bundle pending |
| APK FongMi/TV `catvod` | [FongMi/TV commit `5fdff00a…`, `catvod/src/main`](https://github.com/FongMi/TV/tree/5fdff00a602dc56e8ba756174daef20edab024f2/catvod/src/main), plus local `Helpers/AndroidDexBridge/catvod` | copied and modified; exact diff recorded in `FONGMI_CATVOD_CHANGES.md` | Exact original and local modified source mapped; release archive pending |
| APK Maven runtime artifacts | exact coordinates in `Helpers/AndroidDexBridge/THIRD_PARTY_NOTICES.md` and Gradle dependency caches | compiled/dexed into APK | `xpp3:1.1.3.3` is excluded after exact source recovery failed; remaining source set is handled by the Phase 2 source bundle |
| APK `juniversalchardet:1.0.3` MPL-covered code | exact Maven coordinate and corresponding source for 1.0.3 | dexed into APK | MPL covered-source publication must be included in Phase 2 source bundle |

## Release maintainer rule

Before publishing a binary, create an immutable source archive/tag for the
project and retain or mirror each fixed source archive above. The release page
must point to that immutable material. If a binary hash, version, patch, build
flag, or APK dependency changes, update this mapping and the provenance
manifest before packaging. A generic upstream homepage is attribution, not a
corresponding-source answer.
