# OKVideoMac 0.4.0 screenshot manifest

These images show the real public OKVideoMac 0.4.0 (Build 94) Release app, not a
mockup or a development build.

## Capture identity

- App: `OKVideoMac.app` installed from the public Apple-notarized and stapled
  `OKVideoMac-0.4.0.dmg`.
- Version: `CFBundleShortVersionString = 0.4.0`.
- Build: `CFBundleVersion = 94`.
- Release tag: `v0.4.0`.
- Exact release commit: `f93d74fed86e3e2ffcfa4888c521a10f8e3e86f3`.
- Capture date: 2026-09-05.
- Interface: final native macOS light appearance.

## Content provenance

The app was connected only to the loopback fixture in
[`../../DemoSource`](../../DemoSource/README.md). All visible titles, people,
studios, channels, posters and video frames are original fictional materials
made for this repository. The screenshots contain no third-party provider,
real film or television artwork, broadcaster mark, credential, account,
Cookie, private URL, log output or local filesystem path.

The source captures came from macOS Computer Use. The checked-in PNGs preserve
the actual app layout and state. A small capture pointer was removed from blank
native surfaces and file metadata was stripped; no application control, text,
content card or window state was composited or redrawn. The exact cleanup is
recorded in `sanitize_screenshots.py`.

## Current screenshots

| File | Real Release state shown |
| --- | --- |
| `home.png` | VOD home with 12 original recommendations and six categories |
| `search.png` | Completed multi-provider search for `光`, including the fixed Back control |
| `series-detail.png` | `极昼信号`, two lines and a genuine 120-episode paged detail view |
| `vod-playback.png` | Original deep-ocean landscape playing with native VOD controls visible |
| `live-channels.png` | Eight fictional channels using dedicated 16:9 banners |
| `live-playback.png` | Original scenic live playback with channel overlay and controls visible |
| `settings.png` | General settings: appearance, window layout, privacy and history retention |

## Replacement map

Both language versions of the README use this single image set:

| Retired 0.3.41 reference | 0.4.0 replacement |
| --- | --- |
| `Docs/Media/v0.3.41/home-hero.png` | `Docs/Media/v0.4.0/home.png` |
| `Docs/Media/v0.3.41/search.png` | `Docs/Media/v0.4.0/search.png` |
| `Docs/Media/v0.3.41/series-detail.png` | `Docs/Media/v0.4.0/series-detail.png` |
| `Docs/Media/v0.3.41/vod-playback.png` | `Docs/Media/v0.4.0/vod-playback.png` |
| `Docs/Media/v0.3.41/live-channels.png` | `Docs/Media/v0.4.0/live-channels.png` |
| `Docs/Media/v0.3.41/live-playback.png` | `Docs/Media/v0.4.0/live-playback.png` |
| No previous current-release image | `Docs/Media/v0.4.0/settings.png` |

The older files remain only as historical release media. Current documentation
must not reference them as the 0.4.0 interface.
