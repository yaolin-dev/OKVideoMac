# OKVideoMac

English | [简体中文](README_zh-CN.md)

OKVideoMac is a native macOS client for configurable video providers and live
streams, with a SwiftUI interface and libmpv-based playback. The current public
release is **0.3.41 (Build 65)** for Apple Silicon Macs running macOS 12 or
later.

The upcoming release candidate is **0.4.0 (Build 94)**. It remains Apple
Silicon-only and requires macOS 12 or later. Its final public DMG and source
set will be rebuilt from the exact merge commit after RC approval; the current
0.3.41 download remains the public release until then.

## Highlights

- Native macOS navigation, search, history, favorites, and playback UI
- Configurable video providers and M3U, TXT, or JSON live-source lists
- libmpv playback for on-demand video and live streams
- Selected QuickJS and CatVod/CatPaw-style Node video interfaces
- An optional Android Bridge for selected Java/Dex `csp_` providers
- Structured cloud authorization recovery, safer Quark transfer-folder reuse,
  and native macOS configuration sheets in the 0.4.0 candidate

Compatibility is determined primarily by source format, site type, runtime,
API schema, parsing requirements, and media behavior—not by an ecosystem
brand. Support for selected sources used by TVBox, FongMi, MiraPlay, or
CatPawOpen does not imply universal compatibility with those ecosystems.

| Source / runtime | Status | Notes |
| --- | --- | --- |
| Native CMS JSON | Supported | Native provider path |
| CMS XML responses | Partial | Coverage is narrower than the JSON path |
| QuickJS Spider | Selected | Selected CatVod/FongMi-style scripts |
| Node `.js.md5` | Selected | Compatible CatVod/CatPaw-style video-interface subset |
| Java/Dex `csp_` | Experimental | Requires the optional Android Bridge |
| M3U / TXT / JSON Live | Supported | Imported through the dedicated Live importer |
| XMLTV EPG | Supported | Android is not required |

See the [compatibility guide](OKVideoMac/macOS/OKVideoMac/Docs/COMPATIBILITY.md)
for configuration formats, runtime dispatch, parser limits, and ecosystem
boundaries.

## Requirements

- macOS 12 or later
- Apple Silicon (`arm64`)

Android is not required for Native providers, QuickJS, Node `.js.md5`,
M3U/TXT/JSON Live, XMLTV, or normal playback. It is required only for supported
Java/Dex `csp_` providers.

Android Studio is the recommended installation interface, but it is not a
runtime dependency. When the optional Bridge is needed, OKVideoMac creates its
dedicated `OKVideoMac_Runtime` AVD and installs the bundled Bridge APK
automatically; users should not create the AVD or install the APK manually.
See [Android Bridge Setup](OKVideoMac/macOS/OKVideoMac/Docs/ANDROID_BRIDGE_SETUP.md).

## Screenshots

![Home](Docs/Media/v0.3.41/home-hero.png)

![Search](Docs/Media/v0.3.41/search.png)

![Series detail](Docs/Media/v0.3.41/series-detail.png)

![VOD playback](Docs/Media/v0.3.41/vod-playback.png)

![Live channels](Docs/Media/v0.3.41/live-channels.png)

![Live playback](Docs/Media/v0.3.41/live-playback.png)

All screenshots use locally generated demo media. No third-party video source
or real IPTV content is bundled with the project or shown in these images.

## Download and install

Download the official DMG from
[GitHub Releases](https://github.com/yaolin-dev/OKVideoMac/releases), open it, and
drag `OKVideoMac.app` into Applications. The current
`OKVideoMac-0.3.41-macOS-arm64.dmg` contains 0.3.41 (Build 65), signed with
Developer ID and notarized by Apple. Do not disable Gatekeeper or SIP to
install the official build.

## Binary and source identity

The current v0.3.41 binary and corresponding-source set are Build 65. The source
archives, index, manifest, licenses, checksums, SBOMs, and binary-bound records
are tied to the exact `v0.3.41-build65` release commit. See the
[source release process](Docs/SOURCE_RELEASE_PROCESS.md) for the current
Build 65 asset set.

Builds 62 and 63 were earlier pre-publication candidates, and Build 64 remains
the prior immutable public release. Build 62 findings
remain available as a
[Historical Build 62 Release Readiness Record](Docs/IMMUTABLE_RELEASE_READINESS.md).
Those historical candidate records are not the current v0.3.41 release state.

For 0.4.0, `package-app.sh` creates a Developer ID-signed DMG containing only
`OKVideoMac.app` and `Applications -> /Applications`, then binds that DMG,
SBOMs, notices, and corresponding-source archives to one exact clean Git
commit. Apple notarization, staple, Gatekeeper, tag, and public upload remain
separate release gates and must not be claimed before they run successfully.

## Content and configuration

OKVideoMac does not include third-party video sources, accounts, cookies,
parsing addresses, or DRM keys. Use only configurations and content that you
are authorized to access.

## Documentation

- [Detailed project documentation](OKVideoMac/README.md)
- [Compatibility guide](OKVideoMac/macOS/OKVideoMac/Docs/COMPATIBILITY.md)
- [Android Bridge Setup](OKVideoMac/macOS/OKVideoMac/Docs/ANDROID_BRIDGE_SETUP.md)
- [Build from source](OKVideoMac/macOS/OKVideoMac/Docs/BUILDING.md)
- [Source release process](Docs/SOURCE_RELEASE_PROCESS.md)
- [0.4.0 release notes](Docs/RELEASE_NOTES_0.4.0.md)
- [Changelog](CHANGELOG.md)
- [Contributing](CONTRIBUTING.md)
- [Security policy](SECURITY.md)

Please report reproducible problems through
[GitHub Issues](https://github.com/yaolin-dev/OKVideoMac/issues), and
remove private URLs, credentials, cookies, and personal data from reports.

## License

OKVideoMac is distributed under the [GNU General Public License v3.0](LICENSE).
Third-party components remain subject to their respective licenses and notices.
