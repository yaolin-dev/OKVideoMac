# OKVideoMac documentation demo source

This loopback-only source exists solely to make the OKVideoMac documentation
safe, reproducible and independent of third-party catalogs. It is not bundled
into the app, does not become a default source, and does not contact any public
service.

It is external demo data served over `127.0.0.1`; capturing these screenshots
does not copy files into, re-sign, or otherwise modify the notarized
`OKVideoMac.app`. The published v0.4.0 DMG and its hash-bound release assets
remain immutable.

Every title, name, studio, synopsis, poster and live-channel identity is
fictional. The checked-in landscape artwork and video were created specifically
for this repository; they contain no people, real film or television imagery,
logos, station marks or recognizable intellectual property.

## Run

From the repository root:

```bash
python3 Docs/DemoSource/demo_server.py
```

The server binds to `127.0.0.1:9480` and prints two URLs:

- VOD configuration: `http://127.0.0.1:9480/config.json`
- Live playlist: `http://127.0.0.1:9480/live.m3u`

Import those URLs in the final Release app through **Settings → VOD
Configurations** and **Settings → Live Sources**. Stop the server with
Control-C. The fixtures are documentation inputs, not general-purpose test or
streaming services.

## Rebuild checked-in media

On macOS with Xcode Command Line Tools and Pillow installed:

```bash
Docs/DemoSource/build_demo_assets.sh
```

The script creates 24 poster treatments, eight dedicated 16:9 live-channel
banners and a silent 128-second H.264 landscape video at 1280×720. Its repeated
scenic sequence is long enough for stable VOD and live-player capture;
intermediate frames are deleted and excluded from Git.

## Coverage

- 24 VOD entries across film, series, animation, documentary, children and
  technology categories.
- Long-form episode lists of 12, 50 and 120 episodes.
- Search matches for `光`, `城市`, `星`, `蓝` and `计划`.
- Eight fictional channels in news, sports, nature, music, children and demo
  groups.
- Standard type-1 JSON home, category, search, detail and direct-media
  playback responses.
- HTTP byte ranges and a long repeated scenic sequence for repeatable local
  player screenshots.

See [`catalog.json`](catalog.json) for the complete fictional metadata and
[`../Media/v0.4.0/README.md`](../Media/v0.4.0/README.md) for screenshot
provenance.
