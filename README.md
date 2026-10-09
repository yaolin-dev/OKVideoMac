# OKVideoMac

The current release candidate is **0.8.4 (Build 137)**, prepared for formal release. It removes the AppKit toolbar
write-back associated with the reported 0.8.3 startup crash while preserving the native
sidebar. The user confirmed successful testing on macOS 27.0.1 on 2026-10-09.
The final package is rebuilt from a clean main commit and must pass the distribution
gates before publication. See [release notes](Docs/RELEASE_NOTES_0.8.4.md) and
[readiness](Docs/RELEASE_READINESS_0.8.4.md). Stable downloads below remain 0.8.3 until publication.

English | [简体中文](README_zh-CN.md)

**A native macOS IPTV/VOD player for Apple Silicon with Xtream, M3U/XMLTV,
selected TVBox/CatVod/CatPaw-style providers, and libmpv playback.**

[![Latest release](https://img.shields.io/github/v/release/yaolin-dev/OKVideoMac?display_name=tag&sort=semver)](https://github.com/yaolin-dev/OKVideoMac/releases/latest)
![macOS 12+](https://img.shields.io/badge/macOS-12%2B-000000?logo=apple&logoColor=white)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-arm64-000000?logo=apple&logoColor=white)
[![GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue)](LICENSE)

Built with Swift and SwiftUI/AppKit. Android is an optional compatibility layer
for selected Java/Dex providers.

The latest stable release is **0.8.3 (Build 136)**, Developer ID signed and Apple-notarized.

**Native macOS · Xtream · IPTV/VOD · M3U/XMLTV · libmpv · Multi-provider Search · QuickJS/Node Spiders**

## Download

### [Download the latest stable release →](https://github.com/yaolin-dev/OKVideoMac/releases/latest)

**0.8.3 (Build 136)** · macOS 12.0+ · Apple Silicon (`arm64`) only.

Download the Developer ID signed and Apple-notarized [v0.8.3 DMG](https://github.com/yaolin-dev/OKVideoMac/releases/download/v0.8.3/OKVideoMac-0.8.3.dmg). Stapling, Gatekeeper, final DMG and fresh-install smoke checks passed.

Open the DMG and drag `OKVideoMac.app` to Applications. You do not need to disable Gatekeeper or SIP. Checksums, release notes, source archives, SBOMs and notices accompany the release.

> OKVideoMac is a player and provider client. It does not include third-party video sources, accounts, cookies, parsing services or DRM keys.

## New in 0.8.3

- Remove the primary sidebar divider slot while preserving separate native sidebar, detail and titlebar materials.
- Keep the sidebar toggle attached to the window across navigation and synchronize the first frames of appearance changes.
- Restore native gray search controls, blue symbols and readable localized hints.
- Report missing Android Bridge APKs accurately and reject incomplete Release builds.

Versions 0.8.1 and 0.8.2 on the stable channel can check for this update. Automatic checks require consent; downloading and installation require confirmation. Version 0.8.0 and local test-feed builds need a manual install. See [release notes](Docs/RELEASE_NOTES_0.8.3.md), [verified release](Docs/RELEASE_VALIDATION_0.8.3.md) and [automatic updates](Docs/AUTOMATIC_UPDATES.md).

## Earlier 0.8.2 changes

- Back up private AVD data and its compatibility fingerprint together.
- Recover matching original data after rebuild failure or interruption; retain backups and failed new data.
- Freeze the selected image, preflight AVD-volume space and preserve terminal errors.

See the [0.8.2 release notes](Docs/RELEASE_NOTES_0.8.2.md) for the historical changes.

## Earlier 0.8.1 changes

- Fix Bluetooth audio-device-change crashes after failed CoreAudio initialization.
- Add optional daily update checks with Sparkle 2.10.0; users confirm downloading and installation. Playback-aware prompts and exclusive restart ownership protect active playback and shutdown.
- Restore previous/next controls and autoplay when a different episode has duplicate uploads. Ambiguous adjacent resources require a manual choice.
- Publish a signed stable update feed and require an exact 34-executable bundle inventory.

See the [0.8.1 release notes](Docs/RELEASE_NOTES_0.8.1.md) for the historical changes.

## Earlier 0.8.0 changes from 0.7.3

- **Selected TVBox configuration and authorization:** cancellable configuration
  cards, owned Android dialogs/web pages, and one same-episode retry after
  confirmed native authorization. Unsupported login protocols remain outside scope.
- **CatPaw search and details:** bounded 30-second search caching, reuse of an
  identical active search, timely partial results, and detail requests that survive
  Node cache writes. Search concurrency remains 20.
- **Player controls and seeking:** responsive controls independent of full-screen
  video transforms, complete progress previews/tooltips at viewport edges, and
  seek recovery based on the current mpv request's events.
- **Automatic episode continuation:** unambiguous numbered video files can follow
  episode numbers across different prefixes while preserving season/version;
  history restoration prepares the queue before advancing, and replay reloads media.
- **Android Runtime recovery:** owned emulators recover after private ADB binding
  changes; exporting diagnostics does not start ADB. Bridge is now 0.3.48 (60).

The formal 0.8.0 release is available. See the
[0.8.0 release notes](Docs/RELEASE_NOTES_0.8.0.md) for the before/after comparison,
[release validation](Docs/RELEASE_VALIDATION_0.8.0.md) for distribution checks, and
[readiness record](Docs/RELEASE_READINESS_0.8.0.md) for regression coverage.

## New in 0.7.3

- **Native Full Guide:** browse bounded XMLTV and Native Xtream programme data
  with date navigation, Now repositioning, virtualized channel rows and programme
  details.
- **Native danmaku:** load source-provided XML/JSON comments, import Bilibili XML,
  select a matching episode, calibrate timing and render through a display-synced
  AppKit overlay.
- **History and Favorites:** source-aware native lists, safer resume and deletion,
  accurate progress, migration of older records and portable backup schema v4.
- **Browsing and playback reliability:** resumable category/search pagination,
  bounded detail caching, stronger async ownership, remembered volume, proxy-aware
  Native Xtream media, smoother full-screen transitions and full-screen recovery.
- **Interface polish:** consistent native hover and selection across poster, live,
  History and Favorites views; populated rows keep separators while empty space
  stays clean.

These features were released in 0.7.3 and are not new in 0.8.0. See the
[0.7.3 release notes](Docs/RELEASE_NOTES_0.7.3.md) for their scope and limitations.

## New in 0.6.1

- **Android storage categories:** view managed components, installation cache,
  Android user data and backups separately, with an estimate for the selected removal.
- **Safe managed-component uninstall:** remove recognized Android components managed
  by OKVideoMac after its Android session has been confirmed stopped.
- **Keep your Android data:** user data and login state, backing/encryption files,
  Android home, private ADB identity, user-data backups and runtime selection stay.
  External SDK files are never uninstall targets. Reinstall managed components later
  when needed; a separate Android user-data deletion action is not offered.
- **Recovery and documentation:** interrupted maintenance can be resumed; English
  and Chinese project descriptions now give existing Native Xtream equal visibility.

Native Xtream was introduced in 0.6.0, including authentication, Movies, Series,
Movie/Series search and Basic Live. The 0.6.1 release did not yet include Xtream
EPG, catch-up/timeshift or `direct_source`. See the
[0.6.1 release notes](Docs/RELEASE_NOTES_0.6.1.md).

## Screenshots

<p align="center">
  <img src="Docs/Media/v0.6.1/en/home.jpg" alt="OKVideoMac Browse screen in English" width="100%">
</p>

<table>
  <tr>
    <td width="33%"><img src="Docs/Media/v0.6.1/en/search.jpg" alt="Multi-provider search in English"><br><sub>Multi-provider search</sub></td>
    <td width="33%"><img src="Docs/Media/v0.6.1/en/series-detail.jpg" alt="Series detail and episode navigation in English"><br><sub>Detail and episode navigation</sub></td>
    <td width="33%"><img src="Docs/Media/v0.6.1/en/live-channels.jpg" alt="Live TV channel browser in English"><br><sub>Live channel browser</sub></td>
  </tr>
</table>

<table>
  <tr>
    <td width="50%"><img src="Docs/Media/v0.6.1/en/vod-playback.jpg" alt="VOD playback in English"><br><sub>VOD playback</sub></td>
    <td width="50%"><img src="Docs/Media/v0.6.1/en/live-playback.jpg" alt="Live TV playback in English"><br><sub>Live TV playback</sub></td>
  </tr>
</table>

These 0.6.1 captures use the English interface and fictional scenic demo data;
they contain no third-party catalogue, account, credential or private URL. See
the [screenshot manifest](Docs/Media/v0.6.1/README.md) for the complete bilingual
file map and image-processing notes.

## Why OKVideoMac

- **Native Mac experience.** A SwiftUI/AppKit interface designed for Apple
  Silicon, with native windows, sheets, keyboard behavior, accessibility, and
  macOS navigation—not a repackaged mobile interface.
- **libmpv playback.** VOD and live playback use libmpv/FFmpeg, with seeking,
  tracks, subtitles, playback speed, screenshots, fullscreen, and bounded
  fallback between available lines.
- **Flexible provider runtimes.** Native Xtream and CMS JSON plus selected TVBox/CatVod
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
| Live TV and programme guide | Supported | M3U/TXT/JSON import, XMLTV and Native Xtream short EPG/Full Guide |
| Native Xtream | Supported | Authentication, Movies, Series, search, Basic Live and short EPG; server differences apply |
| Native CMS JSON | Supported | Home, category, filter, detail, search, and play handoff |
| QuickJS Spider | Selected | Compatible scripts matching the implemented API |
| Node Spider | Selected | CatVod/CatPaw-style video-interface subset |
| Java/Dex `csp_` Spider | Experimental | Requires Managed Runtime or a confirmed External SDK |
| Managed Android Runtime | Available | Recommended Android mode; installed only when needed |
| Managed component storage / uninstall | Available | Categorized usage; preserves user data and external SDKs |
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

Android Compatibility can show categorized storage usage and safely uninstall
Android components managed by OKVideoMac when they are no longer needed. Android
user data and login state, private ADB identity, user-data backups, runtime selection,
and external Android SDKs are preserved. The confirmation shows estimated reclaim
based on the recognized installation; it does not promise a fixed amount of space.
See [Android storage and uninstall](Docs/ANDROID_MANAGED_UNINSTALL.md).

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
| Native Xtream | Supported | Authentication, Movies, Series, search, Basic Live and short EPG; no catch-up/timeshift or `direct_source` |
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

The 0.8.3 / Build 136 DMG passed Release packaging, Developer ID / Hardened Runtime, Apple Accepted, stapling, Gatekeeper and installation smoke under the [existing release process](Docs/DMG_RELEASE_PROCESS.md). Tag `v0.8.3` pins `2d00518dbdf0eba6f91c60483d522fd10e7bee3d`. All 16 public asset digests and anonymous downloads match the verified files. Post-publication documentation preserves signed assets, source snapshots and tags. See [verification](Docs/RELEASE_VALIDATION_0.8.3.md) and [source release process](Docs/SOURCE_RELEASE_PROCESS.md).

## Documentation

- [0.8.3 release notes](Docs/RELEASE_NOTES_0.8.3.md)
- [0.8.3 release verification](Docs/RELEASE_VALIDATION_0.8.3.md)
- [Automatic updates](Docs/AUTOMATIC_UPDATES.md)

- [Detailed project documentation](OKVideoMac/README.md)
- [Compatibility guide](OKVideoMac/macOS/OKVideoMac/Docs/COMPATIBILITY.md)
- [Android Bridge Setup](OKVideoMac/macOS/OKVideoMac/Docs/ANDROID_BRIDGE_SETUP.md)
- [Build from source](OKVideoMac/macOS/OKVideoMac/Docs/BUILDING.md)
- [Architecture](OKVideoMac/macOS/OKVideoMac/Docs/ARCHITECTURE.md)
- [Android storage and uninstall](Docs/ANDROID_MANAGED_UNINSTALL.md)
- [0.8.0 release notes](Docs/RELEASE_NOTES_0.8.0.md)
- [0.8.0 release validation](Docs/RELEASE_VALIDATION_0.8.0.md)
- [0.8.0 readiness and Git preparation](Docs/RELEASE_PREPARATION_0.8.0.md)
- [0.7.3 release notes](Docs/RELEASE_NOTES_0.7.3.md)
- [0.6.1 release notes](Docs/RELEASE_NOTES_0.6.1.md)
- [Changelog](CHANGELOG.md)
- [Security policy](SECURITY.md)

## License

OKVideoMac is distributed under the [GNU General Public License v3.0](LICENSE).
Third-party components remain subject to their respective licenses and notices.
