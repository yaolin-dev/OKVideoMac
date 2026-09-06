# OKVideoMac Third-Party Notices

This is the authoritative third-party index for OKVideoMac 0.4.2 (Build 98). It
covers executable material actually shipped in the macOS App and its embedded
Android APK. Third-party software remains under its original terms; the
project's `GPL-3.0-only` license does not relicense it.

Exact hashes, build inputs, and evidence grades are in
`Docs/SOURCE_PROVENANCE_MANIFEST.md`. The source-release answer for each binary
is in `Docs/BINARY_SOURCE_MAPPING.md`. License paths below are relative to
`THIRD_PARTY_LICENSES/`.

## Native and process components

| Component | Version | Upstream / copyright | License | Use and linkage | Modified? / source and binary mapping | License file |
| --- | --- | --- | --- | --- | --- | --- |
| mpv / libmpv | v0.41.0 | [mpv-player/mpv v0.41.0](https://github.com/mpv-player/mpv/tree/v0.41.0); mpv authors | `GPL-2.0-or-later` build | Dynamic `Frameworks/libmpv.dylib` through the project bridge | Yes. Official archive plus `macOS/OKVideoMac/Patches/mpv-0.41.0-coreaudio-without-cocoa.patch`; see adjacent change notice | `mpv-GPL-2.0-or-later.txt`, `mpv-Copyright.txt` |
| FFmpeg family | 7.1.4 | [FFmpeg 7.1.4](https://ffmpeg.org/releases/ffmpeg-7.1.4.tar.xz); FFmpeg developers | `LGPL-2.1-or-later` build | Six dynamic `libav*`, `libswresample`, and `libswscale` dylibs | No local source patch found; exact retained source archive exists, but reproducible build recipe remains Phase 2 | `FFmpeg-LGPL-2.1-or-later.txt`, `FFmpeg-LICENSE.md` |
| libass | 0.17.5 | [libass 0.17.5](https://github.com/libass/libass/releases/tag/0.17.5); libass authors | `ISC` | Dynamic `libass.9.dylib` | No local patch found; retained source, build reconstruction partial | `libass-ISC.txt` |
| libplacebo | 7.360.1, MacPorts `+opengl` | [haasn/libplacebo v7.360.1](https://github.com/haasn/libplacebo/archive/refs/tags/v7.360.1.tar.gz); libplacebo authors | `LGPL-2.1-or-later` | Dynamic `libplacebo.360.dylib` | No project patch; MacPorts receipt/Portfile provenance is partial | `libplacebo-LGPL-2.1-or-later.txt` |
| FreeType | 2.14.3 | [FreeType 2.14.3](https://download.savannah.gnu.org/releases/freetype/freetype-2.14.3.tar.xz); FreeType Project | `FTL` selected | Dynamic `libfreetype.6.dylib` | No project patch; MacPorts provenance is partial | `FreeType-FTL.txt` |
| HarfBuzz | 14.2.1 | [HarfBuzz 14.2.1](https://github.com/harfbuzz/harfbuzz/releases/tag/14.2.1); HarfBuzz authors | `MIT` | Dynamic `libharfbuzz.0.dylib` | No local patch found; retained source, build reconstruction partial | `HarfBuzz-MIT.txt` |
| FriBidi | 1.0.16 | [FriBidi v1.0.16](https://github.com/fribidi/fribidi/tree/v1.0.16); FriBidi authors | `LGPL-2.1-or-later` | Dynamic `libfribidi.0.dylib` | No project patch; MacPorts provenance is partial | `FriBidi-LGPL-2.1-or-later.txt` |
| Brotli | 1.2.0 | [google/brotli v1.2.0](https://github.com/google/brotli/tree/v1.2.0); Brotli Authors | `MIT` | Dynamic decoder/common dylibs | No project patch; MacPorts provenance is partial | `Brotli-MIT.txt` |
| Little CMS 2 | 2.19.1 | [Little-CMS 2.19.1](https://github.com/mm2/Little-CMS/releases/tag/lcms2.19.1); Marti Maria | `MIT` | Dynamic `liblcms2.2.dylib` | No project patch; MacPorts provenance is partial | `Little-CMS-2-MIT.txt` |
| libpng | 1.6.58 | [libpng v1.6.58](https://github.com/pnggroup/libpng/tree/v1.6.58); PNG Reference Library authors | `Libpng` | Dynamic `libpng16.16.dylib` | No project patch; MacPorts provenance is partial | `libpng-License.txt` |
| libjpeg-turbo | 3.2.0 | [libjpeg-turbo 3.2.0](https://github.com/libjpeg-turbo/libjpeg-turbo/tree/3.2.0); libjpeg-turbo and IJG authors | `BSD-3-Clause`, IJG, and `Zlib` portions | Dynamic `libjpeg.8.dylib` | No project patch; MacPorts provenance is partial | `libjpeg-turbo-LICENSE.md`, `libjpeg-turbo-README.ijg` |
| XZ / liblzma | 5.8.3 | [XZ Utils v5.8.3](https://github.com/tukaani-project/xz/tree/v5.8.3); XZ Utils authors | `0BSD` for liblzma | Dynamic `liblzma.5.dylib` | No project patch; MacPorts provenance is partial | `XZ-libLZMA-0BSD.txt` |
| SQLite | 3.53.4 | [SQLite 3.53.4 source archive](https://www.sqlite.org/2026/sqlite-autoconf-3530400.tar.gz); SQLite authors | Public Domain | Dynamic bundled `libsqlite3.dylib` | No project patch; MacPorts provenance is partial | `SQLite-Public-Domain.txt` |
| GNU libiconv | 1.18 | [GNU libiconv 1.18](https://ftp.gnu.org/pub/gnu/libiconv/libiconv-1.18.tar.gz); FSF and contributors | `LGPL-2.1-or-later` | Dynamic `libiconv.2.dylib` | No project patch; MacPorts provenance is partial | `GNU-libiconv-LGPL-2.1-or-later.txt` |
| bzip2 | 1.0.8 | [sourceware bzip2 1.0.8](https://sourceware.org/pub/bzip2/bzip2-1.0.8.tar.gz); Julian Seward | bzip2 license | Dynamic `libbz2.1.0.dylib` | No project patch; MacPorts provenance is partial | `bzip2-License.txt` |
| zlib | 1.3.2 | [zlib 1.3.2](https://github.com/madler/zlib/tree/v1.3.2); Jean-loup Gailly and Mark Adler | `Zlib` | Dynamic `libz.1.dylib` | No project patch; receipt identifies the version, but exact source/build chain remains partial | `zlib-License.txt` |
| libc++ / libc++abi | MacPorts 11.1.0 | LLVM Project contributors | `Apache-2.0 WITH LLVM-exception` (with legacy code under the bundled notices) | Dynamic `libc++.1.0.dylib`, `libc++abi.1.dylib` | MacPorts receipt copies from its clang-11 input; that historical build input is incomplete, so provenance is partial | `LLVM-Apache-2.0-WITH-LLVM-exception.txt` |
| QuickJS | 2025-09-13-2 | [bellard.org QuickJS](https://bellard.org/quickjs/); Fabrice Bellard and Charlie Gordon | `MIT` | Static archive force-loaded into dynamic `libOKQuickJS.dylib` | Upstream unmodified; project bridge is separate GPL project code; provenance verified | `QuickJS-MIT.txt` |
| Node.js | 22.23.0 | [official Node.js v22.23.0 distribution](https://nodejs.org/download/release/v22.23.0/); Node.js contributors and bundled authors | `MIT` plus licenses reproduced in the distribution LICENSE | Separate executable process at `Resources/NodeRuntime/node` | Input binary is byte-identical to the official arm64 distribution; package step re-signs it without source modification | `Node.js-LICENSE.txt` |
| OKMPVBridge / OKQuickJS bridge | 0.4.2 project source | OKVideoMac contributors | `GPL-3.0-only` | Project-built dynamic bridges | Project code; maps to the fixed release source commit | Project `LICENSE` |

The FFmpeg 7.1.4 binaries report an LGPL configuration with
`--enable-zlib --enable-bzlib --enable-iconv --enable-lzma` and without
`--enable-gpl`, `--enable-version3`, `--enable-nonfree`, x264, x265,
libfdk-aac, OpenSSL, or GnuTLS. FFmpeg's retained `LICENSE.md` includes its
copyright/source guidance. Per FFmpeg's attribution guidance, this product
uses code from FFmpeg and includes software based in part on the work of the
Independent JPEG Group through libjpeg-turbo.

This product uses the FreeType Project under the FreeType License (`FTL`).

## Embedded Android bridge

`Contents/Resources/AndroidDexBridge-release.apk` is a separate executable
payload. It contains copied and modified FongMi/TV `catvod` source and its full
Gradle `releaseRuntimeClasspath`. The exact artifact/version/license table is
maintained in `Helpers/AndroidDexBridge/THIRD_PARTY_NOTICES.md` and is copied
into the App's `Resources/Legal/AndroidDexBridge/` directory.

The legacy transitive dependency `xpp3:xpp3:1.1.3.3` is explicitly excluded
from the Phase 2 APK because its exact corresponding source could not be
recovered. It is not part of the distributed runtime inventory. See
`Docs/XPP3_1_1_3_3_REMEDIATION.md`.

## Build tooling distributed in source form

The repository tracks the Gradle 8.9 wrapper JAR. The wrapper properties lock
the official Gradle 8.9 binary distribution SHA-256. Gradle is Apache-2.0 and
its distribution NOTICE is retained as `Gradle-NOTICE.txt`. Gradle itself is
build tooling and is not included in the Release App.
