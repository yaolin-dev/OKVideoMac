# Third-Party Licenses in the Release App

This file is a short in-project pointer, not a second inventory. The current
Release App includes third-party executable content, including:

- mpv v0.41.0 built with GPL enabled and a local source patch;
- FFmpeg 7.1.4 built on its `LGPL-2.1-or-later` path;
- Node.js 22.23.0 as a separate bundled process;
- QuickJS 2025-09-13-2 statically force-loaded into the project bridge;
- the complete recursively bundled native dylib dependency chain; and
- `AndroidDexBridge-release.apk`, including copied and modified GPL-3.0-only
  FongMi/TV `catvod` source and its Maven runtime graph.

The authoritative component/version/license/source index is
`OKVideoMac/THIRD_PARTY_NOTICES.md`. License texts are stored in
`OKVideoMac/THIRD_PARTY_LICENSES/`. The APK has a linked, independent inventory
at `OKVideoMac/Helpers/AndroidDexBridge/THIRD_PARTY_NOTICES.md`.

Release packaging copies those materials to
`OKVideoMac.app/Contents/Resources/Legal/`. Third-party components remain under
their own licenses; the project-level `GPL-3.0-only` license does not replace
those terms.
