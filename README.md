# OKVideoMac

OKVideoMac is a native macOS client for configurable video providers and live
streams, with a SwiftUI interface and libmpv-based playback. The first public
release targets Apple Silicon Macs running macOS 12 or later.

## Highlights

- Native macOS navigation, search, history, favorites, and playback UI
- Configurable video providers and M3U, M3U8, TXT, or JSON live-source lists
- libmpv playback for on-demand video and live streams
- Partial QuickJS compatibility and experimental Node compatibility
- An optional Android Bridge for selected Java/Dex `csp_` providers

Compatibility depends on the provider implementation. See the
[compatibility guide](OKVideoMac/macOS/OKVideoMac/Docs/COMPATIBILITY.md) for
the current support boundaries.

## Requirements

- macOS 12 or later
- Apple Silicon (`arm64`)

Android is not required for ordinary native, QuickJS, Node, or live-stream
paths. It is only used by the optional Java/Dex compatibility layer.

## Download and install

Download the official DMG from
[GitHub Releases](https://github.com/yaolin-dev/OKVideoMac/releases), open it, and
drag `OKVideoMac.app` into Applications. Official release builds are signed
with Developer ID and notarized by Apple.

## Content and configuration

OKVideoMac does not include third-party video sources, accounts, cookies,
parsing addresses, or DRM keys. Use only configurations and content that you
are authorized to access.

## Documentation

- [Detailed project documentation](OKVideoMac/README.md)
- [Build from source](OKVideoMac/macOS/OKVideoMac/Docs/BUILDING.md)
- [Contributing](CONTRIBUTING.md)
- [Security policy](SECURITY.md)

Please report reproducible problems through
[GitHub Issues](https://github.com/yaolin-dev/OKVideoMac/issues), and
remove private URLs, credentials, cookies, and personal data from reports.

## License

OKVideoMac is distributed under the [GNU General Public License v3.0](LICENSE).
Third-party components remain subject to their respective licenses and notices.
