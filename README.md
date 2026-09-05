# OKVideoMac

English | [简体中文](README_zh-CN.md)

OKVideoMac is a native video and live-TV client for Apple Silicon Macs. It
provides configurable video providers, live sources, search, detail, favorites,
history, and libmpv playback. It does not bundle third-party content sources,
accounts, cookies, parsing services, or DRM keys.

The current release is **0.4.0 (Build 94)** for macOS 12 or later on Apple
Silicon (`arm64`). Download the Developer ID-signed, Apple-notarized, and stapled
DMG from the [v0.4.0 release](https://github.com/yaolin-dev/OKVideoMac/releases/tag/v0.4.0).

## 0.4.0 Highlights

Compared with 0.3.41, 0.4.0 is a major update across the complete experience:
a more native macOS UI, strict request isolation for search and detail, more
reliable playback and live switching, broader Spider runtime coverage, and a
release chain that maps the DMG, source, SBOMs, and notices to one exact Git
commit.

### Source Compatibility

- Native CMS JSON remains the most complete provider path; CMS XML and type 4
  have narrower, partial coverage.
- Selected TVBox/FongMi-style QuickJS scripts and CatVod/CatPaw-style Node video
  interfaces have broader support. This is not universal ecosystem compatibility.
- The optional Android Bridge supports selected Java/Dex `csp_` providers with
  stronger AVD ownership, APK version, and signature checks. Native, QuickJS,
  Node, Live, and XMLTV paths do not require Android.

### Search & Detail

- Aggregated searches isolate concurrent sources by session. Stopping a search
  preserves completed results, and late callbacks cannot overwrite a newer run.
- Back, Escape, and Command-[ share one layered action: stop an active search
  first, then return to the page from which it was opened.
- Detail requests retain configuration, site, and request identity so rapidly
  changing selections cannot be replaced by an older response.
- Long series use paged episode navigation; 120-episode and multi-line fixtures
  are part of the release validation set.

### Playback & Live TV

- Player opening, teardown, window restoration, buffering feedback, seeking,
  and natural end-of-file auto-advance are more reliable.
- Playback attempts, line switching, and automatic retries have generation
  isolation, preventing stale work from reclaiming the current player.
- Live channel lists, grouping, multi-line sources, XMLTV EPG, channel switching,
  and return navigation have been hardened.
- M3U, TXT, and JSON live lists can be imported directly; HLS is supported as a
  channel media format.

### Cloud & Authorization

- Missing or expired cloud credentials open the matching authorization page;
  successful authorization safely retries the original playback once.
- Authorization uses a real macOS window sheet with system dimming, focus,
  Escape, keyboard, and accessibility behavior.
- Quark reuses an existing transfer workspace after cookie rotation or rescanning
  by binding it to stable account identity and rediscovering invalid ledger FIDs.
- Cleanup remains limited to the exact receipt-recorded `savedFID`; it never
  scans or clears an entire cloud folder.

### Native macOS Experience

- Home, search, detail, playback, live, and settings were refined with clearer
  hierarchy, native toolbar placement, and immediate status feedback.
- Configuration and authorization moved from a custom full-window overlay to a
  system sheet, making the background consistently dimmed and non-interactive.
- Search Back remains visible during high-frequency progress updates. Controls
  and transitions use system interaction semantics and respect Reduce Motion.

### History, Backup & Safety

- Favorites, history, and playback restoration retain their originating
  configuration and site identity, avoiding cross-configuration mix-ups.
- Portable configuration and history backup/restore validate imported data and
  avoid overwriting newer active state.
- Remote Node bundles retain source/version/SHA-256 trust rules. Logs and release
  gates scan for cookies, tokens, private URLs, and machine-specific paths.

### Release & Open Source

- The user download is an Apple-notarized and stapled DMG containing only
  `OKVideoMac.app` and an Applications link. ZIP remains the verified internal
  binary identity/archive carrier.
- The DMG, ZIP, Source Release, four SPDX/CycloneDX SBOMs, notices, and Android
  Bridge APK are bound by an outer manifest and `SHA256SUMS` to one exact commit.
- Release gates verify 28 arm64 Mach-O files, minimum macOS, dependency closure,
  nested signing, Hardened Runtime, Gatekeeper, and binary/source mapping.

## The real 0.4.0 interface

Every image below was captured from the final 0.4.0 (Build 94) Release app using
the reproducible, original demo source and scenic media in this repository. No
real film, IPTV service, account, or private URL appears. Both READMEs share
this one screenshot set.

### Home

![0.4.0 Home](Docs/Media/v0.4.0/home.png)

### Search

![0.4.0 Search results](Docs/Media/v0.4.0/search.png)

### Detail

![0.4.0 long-series detail](Docs/Media/v0.4.0/series-detail.png)

### VOD playback

![0.4.0 VOD player with native controls](Docs/Media/v0.4.0/vod-playback.png)

### Live channels

![0.4.0 Live channel banners](Docs/Media/v0.4.0/live-channels.png)

### Live playback

![0.4.0 Live player with native controls](Docs/Media/v0.4.0/live-playback.png)

### Settings

![0.4.0 Settings](Docs/Media/v0.4.0/settings.png)

See the [Demo Source](Docs/DemoSource/README.md) and
[screenshot manifest](Docs/Media/v0.4.0/README.md) for generation, provenance,
and capture details.

## Compatibility overview

Compatibility is determined by source format, runtime, API shape, parsing
requirements, and media behavior—not by an ecosystem brand.

| Source / runtime | Status | Notes |
| --- | --- | --- |
| Native CMS JSON | Supported | Home, categories, filters, detail, search, and play handoff |
| CMS XML / Native type 4 | Partial | Coverage is narrower than JSON |
| QuickJS Spider | Selected | Selected CatVod/FongMi-style scripts matching the current API |
| Node `.js.md5` | Selected | Compatible CatVod/CatPaw-style video-interface subset |
| Java/Dex `csp_` | Experimental | Requires an external Android environment and optional Bridge |
| M3U / TXT / JSON Live | Supported | Imported through the dedicated Live importer |
| XMLTV EPG | Supported | Android is not required |
| Top-level `lives`, parser types 2/3/4 | Unsupported | Some fields parse, but no complete execution path exists |

Read the [compatibility guide](OKVideoMac/macOS/OKVideoMac/Docs/COMPATIBILITY.md)
for precise boundaries.

## Download and install

Requirements:

- macOS 12.0 or later;
- Apple Silicon (`arm64`);
- only Java/Dex `csp_` sources need an external Android SDK, ADB, Emulator, and
  arm64 system image.

Download `OKVideoMac-0.4.0.dmg`, open it, and drag `OKVideoMac.app` to
Applications. The official image is notarized by Apple; do not disable
Gatekeeper or SIP.

## Binary and source identity

The 0.4.0 (Build 94) release assets are bound to Git commit
`f93d74fed86e3e2ffcfa4888c521a10f8e3e86f3` and tag `v0.4.0`:

| Artifact | SHA-256 |
| --- | --- |
| `OKVideoMac-0.4.0.dmg` | `60b2eebc607be9cc21c8207c913b09544546f5b6b843db801873651ceaf427ea` |
| `OKVideoMac-0.4.0-build94-source.tar.gz` | `eb7c8a812d9a54907f99d8656198b7227bfe19b1b29836953e768d4fe858a8f3` |

The DMG passed Apple notarization, staple, `stapler validate`, and Gatekeeper;
its notarization submission ID is `d9db5bae-1ae9-4d0d-9e63-3ca378235e6a`.
The source set carries four SBOMs and the required notices. Two native provenance
exceptions remain explicitly disclosed rather than overstated: the exact zlib
archive is unavailable, and historical MacPorts libc++/libc++abi inputs could
not be recovered.

## Known limitations

- Apple Silicon only; no Intel or Universal Binary build is provided.
- The Java/Dex Bridge is Experimental and depends on an external Android setup.
- QuickJS, Node, cloud, and web-sniffing paths implement selected interfaces;
  upstream changes can require compatibility updates.
- Top-level TVBox/FongMi `lives`, catchup/timeshift, parser types 2/3/4, and DRM
  are not supported.
- A large legacy database can cause a one-time startup pause. TMDB metadata
  enhancement is deferred to a later release.

## Documentation and security

- [0.4.0 release notes](Docs/RELEASE_NOTES_0.4.0.md)
- [Detailed project documentation](OKVideoMac/README.md)
- [Compatibility guide](OKVideoMac/macOS/OKVideoMac/Docs/COMPATIBILITY.md)
- [Android Bridge Setup](OKVideoMac/macOS/OKVideoMac/Docs/ANDROID_BRIDGE_SETUP.md)
- [Build from source](OKVideoMac/macOS/OKVideoMac/Docs/BUILDING.md)
- [Source release process](Docs/SOURCE_RELEASE_PROCESS.md)
- [DMG release process](Docs/DMG_RELEASE_PROCESS.md)
- [Changelog](CHANGELOG.md)
- [Security policy](SECURITY.md)

Use only configurations and content you are authorized to access. Remove private
URLs, cookies, tokens, accounts, and personal data from issue reports. Report
security concerns privately as described in the [security policy](SECURITY.md).

## License

OKVideoMac is distributed under the [GNU General Public License v3.0](LICENSE).
Third-party components remain subject to their respective licenses and notices.
