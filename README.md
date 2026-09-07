# OKVideoMac

English | [简体中文](README_zh-CN.md)

**A native macOS video and live-TV client for Apple Silicon, with selected
TVBox-, CatVod-, and CatPaw-style providers, QuickJS and Node Spider runtimes,
and optional managed Android support.**

[![Latest release](https://img.shields.io/github/v/release/yaolin-dev/OKVideoMac?display_name=tag&sort=semver)](https://github.com/yaolin-dev/OKVideoMac/releases/latest)
![macOS 12+](https://img.shields.io/badge/macOS-12%2B-000000?logo=apple&logoColor=white)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-arm64-000000?logo=apple&logoColor=white)
[![GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue)](LICENSE)

Built with Swift, SwiftUI/AppKit, and libmpv—not an Android UI wrapper.

**Native macOS · VOD and live TV · libmpv playback · Multi-provider search ·
QuickJS/Node Spiders · Optional Java/Dex compatibility**

## Download

### [Download the latest stable release →](https://github.com/yaolin-dev/OKVideoMac/releases/latest)

The current release is **0.5.0 (Build 99)** · macOS 12.0+ · Apple Silicon
(`arm64`) only · Developer ID signed · Apple notarized and stapled.

Open the DMG and drag `OKVideoMac.app` to Applications. You do not need to
disable Gatekeeper or SIP. Checksums, release notes, source archives, SBOMs,
and notices are published with each release.

> OKVideoMac is a player and provider client. It does not include third-party
> video sources, accounts, cookies, parsing services, or DRM keys.

## Screenshots

<p align="center">
  <img src="Docs/Media/v0.4.0/home.png" alt="OKVideoMac native macOS home screen" width="100%">
</p>

<table>
  <tr>
    <td width="33%"><img src="Docs/Media/v0.4.0/search.png" alt="Multi-provider search"><br><sub>Multi-provider search</sub></td>
    <td width="33%"><img src="Docs/Media/v0.4.0/series-detail.png" alt="Series detail and episode navigation"><br><sub>Detail and long-series navigation</sub></td>
    <td width="33%"><img src="Docs/Media/v0.4.0/live-channels.png" alt="Live TV channel browser"><br><sub>Live channel browser</sub></td>
  </tr>
</table>

These are real Release-app captures made with the repository's original demo
source—no third-party catalogue, account, or private URL is shown. See the
[screenshot manifest](Docs/Media/v0.4.0/README.md) and
[demo source](Docs/DemoSource/README.md). The full set also includes
[VOD playback](Docs/Media/v0.4.0/vod-playback.png),
[live playback](Docs/Media/v0.4.0/live-playback.png), and
[settings](Docs/Media/v0.4.0/settings.png).

## Why OKVideoMac

- **Native Mac experience.** A SwiftUI/AppKit interface designed for Apple
  Silicon, with native windows, sheets, keyboard behavior, accessibility, and
  macOS navigation—not a repackaged mobile interface.
- **libmpv playback.** VOD and live playback use libmpv/FFmpeg, with seeking,
  tracks, subtitles, playback speed, screenshots, fullscreen, and bounded
  fallback between available lines.
- **Flexible provider runtimes.** Native CMS JSON plus selected TVBox/CatVod
  QuickJS, CatVod/CatPaw-style Node, and Java/Dex `csp_` Spider paths. The
  compatibility boundary is explicit rather than advertised as universal.
- **Search and library.** Isolated multi-provider search, details, favorites,
  history, progress restoration, and long-series episode navigation.
- **Live TV on macOS.** Import M3U, TXT, or JSON channel lists, use multiple
  lines, and load XMLTV EPG data without Android.
- **Managed Android Runtime.** When a supported Java/Dex Spider really needs
  Android, the app can install and manage its own pinned environment. Advanced
  users may explicitly choose a compatible External SDK instead.
- **Release engineering.** Public DMGs are Developer ID signed, notarized,
  stapled, checked by Gatekeeper, and accompanied by hashes and source/SBOM
  material.

## Compatibility at a glance

| Capability | Status | Notes |
| --- | --- | --- |
| Native macOS UI | Supported | SwiftUI/AppKit; no Android UI shell |
| Apple Silicon | Supported | `arm64`, macOS 12.0 or later |
| VOD and libmpv playback | Supported | Media behavior still depends on the source/server |
| Live TV and XMLTV EPG | Supported | M3U, TXT, and JSON import paths |
| Native CMS JSON | Supported | Home, category, filter, detail, search, and play handoff |
| QuickJS Spider | Selected | Compatible scripts matching the implemented API |
| Node Spider | Selected | CatVod/CatPaw-style video-interface subset |
| Java/Dex `csp_` Spider | Experimental | Requires Managed Runtime or a confirmed External SDK |
| Managed Android Runtime | Available | Recommended Android mode; installed only when needed |
| External Android SDK | Available | Explicit advanced-user choice; never auto-selected from `PATH` |
| Intel Mac | Not supported | No Intel or Universal Binary release is provided |

Compatibility depends on the source format, runtime, API shape, parsing
requirements, and media behavior—not only on an ecosystem name. See the
[full compatibility guide](OKVideoMac/macOS/OKVideoMac/Docs/COMPATIBILITY.md).

## Android Runtime: optional and on demand

Most of OKVideoMac does **not** need Android. Native providers, QuickJS and
Node Spiders, live TV, XMLTV, search, and ordinary playback run directly on
macOS.

Only selected Java/Dex `csp_` Android Spider sources use the optional Android
Bridge:

- **Managed Runtime (recommended):** on the first real Dex request, OKVideoMac
  asks for confirmation, downloads the pinned JRE/Android components into its
  private Application Support directory, verifies them, and resumes the
  request. No Android Studio, Homebrew ADB, system Java, `ANDROID_HOME`, or
  manually created AVD is required.
- **External SDK (advanced):** users who already have a compatible Android SDK
  can select and confirm it in Settings. OKVideoMac does not silently switch
  modes because Android Studio, Homebrew, `PATH`, or environment variables
  expose another SDK.

Managed installation is transactional and separate from Emulator session
management. Full behavior, storage, repair, licensing, and current real-machine
validation limits are documented in [Android Bridge Setup](OKVideoMac/macOS/OKVideoMac/Docs/ANDROID_BRIDGE_SETUP.md).

## Quick start

1. [Download the latest stable DMG](https://github.com/yaolin-dev/OKVideoMac/releases/latest),
   open it, and move the app to Applications.
2. Launch OKVideoMac and add a provider configuration or live playlist that
   you are authorized to use.
3. Browse, search, open a detail page, or import an M3U/TXT/JSON live list.
4. If a selected Java/Dex provider needs Android, follow the in-app Managed
   Runtime prompt. Other provider and live paths need no Android setup.

## Provider and Spider support

| Source / runtime | Level | Current scope |
| --- | --- | --- |
| Native CMS JSON | Supported | Main provider path |
| CMS XML / native type 4 | Partial | Narrower coverage than CMS JSON |
| TVBox/CatVod-style QuickJS | Selected | `home`, `category`, `detail`, `search`, `play`, and selected helpers |
| CatVod/CatPaw-style Node `.js.md5` | Selected | Supported video-interface subset; not the complete CatPawOpen protocol |
| Java/Dex Android `csp_` | Experimental | Selected CatVod-style methods through the optional Bridge |
| M3U / TXT / JSON live lists | Supported | Dedicated live importer; top-level TVBox `lives` is not wired to it |
| XMLTV EPG | Supported | Remote HTTP(S), gzip, cache, and channel matching |
| Parser type 0 / 1 | Partial / Supported | WKWebView sniffing / JSON parsing |
| Parser types 2 / 3 / 4 | Unsupported | Fields may parse, but there is no complete execution path |

OKVideoMac implements selected TVBox-, CatVod-, and CatPaw-style interfaces;
it is not an official client for those projects and does not promise that every
public or private provider will work.

## Privacy and content sources

- No video catalogue, IPTV service, provider account, cookie, parser service,
  or DRM key is bundled.
- You choose the configurations, scripts, playlists, and media you are
  authorized to access. Remote Node bundles have broad execution capability;
  load only sources you trust.
- Logs and diagnostics are designed to redact credentials and private paths,
  but issue reports should still be reviewed before publication.
- OKVideoMac does not implement DRM bypass. Please use the project only with
  content and services you are permitted to access.

## System requirements

- macOS 12.0 Monterey or later;
- Apple Silicon (`arm64`); Intel Macs are not supported;
- network access for remote providers/media and, if selected, Managed Runtime
  installation;
- sufficient free disk space only when the optional Managed Android Runtime is
  installed.

## FAQ

### Is this TVBox for macOS?

OKVideoMac is an independent, native macOS TVBox-style provider client—not an
official TVBox app and not an Android wrapper. It implements selected compatible
configuration and Spider paths, so people looking for a TVBox for Mac should
check the compatibility table before assuming a particular source will work.

### Does OKVideoMac include video or live-TV sources?

No. It is a player/provider client. You supply configurations and playlists
that you are authorized to use; no third-party catalogue, account, cookie,
parsing service, or DRM key is bundled.

### Do I need Android Studio or an Android SDK?

Not for normal use, and not for Managed Runtime. If a selected Java/Dex
Android Spider needs Android, OKVideoMac can download and manage the required
environment after you confirm. External SDK remains an optional advanced mode.

### Why does a Java/Dex `csp_` Spider need Android?

That provider contains Android bytecode. OKVideoMac runs the supported subset
through a private Android Bridge; Native, QuickJS, Node, live-TV, and XMLTV
paths do not use it.

### Does it support CatVod macOS or CatPaw macOS providers?

It supports selected CatVod/FongMi-style QuickJS APIs and a selected
CatVod/CatPaw-style Node video subset. Java/Dex support is Experimental. It is
not complete TVBox, CatVod, CatPaw, or CatPawOpen ecosystem compatibility.

### Does it run on Intel Macs?

No. Current releases target Apple Silicon only; the app and optional Android
Runtime are not shipped as an Intel or Universal Binary stack.

## Known limitations

- Java/Dex compatibility remains Experimental. The Managed API 35 profile has
  real Emulator/Bridge/Dex E2E evidence on one M1 / macOS 14.8.8 host; Managed
  Emulator E2E on macOS 12, 13, and 15 remains unverified.
- QuickJS, Node, cloud, and web-sniffing paths cover selected interfaces and
  may need updates when upstream implementations change.
- Top-level TVBox/FongMi `lives`, catchup/timeshift, parser types 2/3/4, and DRM
  are not supported.
- Playback ultimately depends on libmpv, codecs, headers/cookies, the media
  server, and the selected provider.
- A large legacy database may cause a one-time startup pause.

## Development and architecture

The repository separates core models/networking, SQLite persistence, macOS UI,
native playback bridges, provider runtimes, Managed Runtime installation, and
Android Emulator sessions. Installation and session lifecycle are deliberately
separate state machines.

- [Build from source](OKVideoMac/macOS/OKVideoMac/Docs/BUILDING.md)
- [Architecture](OKVideoMac/macOS/OKVideoMac/Docs/ARCHITECTURE.md)
- [Compatibility evidence](OKVideoMac/macOS/OKVideoMac/Docs/COMPATIBILITY.md)
- [Contributing](CONTRIBUTING.md)

Release builds require the repository's controlled scripts and fail-closed
checks; a local Debug compile is not a public release artifact.

## Release integrity

The public **0.5.0 (Build 99)** assets are built from tag `v0.5.0`. The signed,
notarized, and stapled DMG is published with a SHA-256 checksum, corresponding
source, SBOMs, notices, and release manifests. See the
[0.5.0 release notes](Docs/RELEASE_NOTES_0.5.0.md),
[source release process](Docs/SOURCE_RELEASE_PROCESS.md), and
[DMG release process](Docs/DMG_RELEASE_PROCESS.md).

## Documentation

- [Detailed project documentation](OKVideoMac/README.md)
- [Compatibility guide](OKVideoMac/macOS/OKVideoMac/Docs/COMPATIBILITY.md)
- [Android Bridge Setup](OKVideoMac/macOS/OKVideoMac/Docs/ANDROID_BRIDGE_SETUP.md)
- [Build from source](OKVideoMac/macOS/OKVideoMac/Docs/BUILDING.md)
- [Architecture](OKVideoMac/macOS/OKVideoMac/Docs/ARCHITECTURE.md)
- [Changelog](CHANGELOG.md)
- [Security policy](SECURITY.md)

## License

OKVideoMac is distributed under the [GNU General Public License v3.0](LICENSE).
Third-party components remain subject to their respective licenses and notices.
