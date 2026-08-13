# Phase 4 Candidate vs Stable ABI and Capability Comparison

Date: 2026-08-13

Comparison command: `Scripts/compare-native-candidate.sh`

Result: **STATIC ABI AND ENUMERATED FFMPEG CAPABILITIES PASS FOR ALL EIGHT
MEDIA-CORE REPLACEMENT CANDIDATES**

## ABI Results

All stable and candidate objects are arm64 with macOS 12.0 minimum deployment.
Install-name compatibility/current versions match after applying the same
packaging normalization used by `package-app.sh` (`libmpv.2.dylib` becomes
`@rpath/libmpv.dylib`). Exported symbols were sorted and compared exactly.

| Output | Exported symbols | Symbol set | Normalized required libraries |
| --- | ---: | --- | --- |
| `libavcodec.61.dylib` | 422 | equal | equal |
| `libavfilter.10.dylib` | 290 | equal | equal |
| `libavformat.61.dylib` | 526 | equal | candidate omits only direct `libobjc.A.dylib` edge |
| `libavutil.59.dylib` | 607 | equal | candidate omits only direct `libobjc.A.dylib` edge |
| `libswresample.5.dylib` | 23 | equal | equal |
| `libswscale.8.dylib` | 31 | equal | equal |
| `libmpv.dylib` | 54 | equal | equal |
| `libOKMPVBridge.dylib` | 25 | equal | equal |

The two link-graph differences are omissions, not new dependencies: current
clang dead-stripped a direct `/usr/lib/libobjc.A.dylib` load command from
libavformat and libavutil. No Objective-C symbol was lost from their exported
sets and the capability comparison below is exact. This toolchain drift is
documented rather than misreported as byte identity.

## Capability Results

A small repository-owned enumerator links once against the stable FFmpeg
family and once against the candidate family. It records sorted codec,
demuxer, protocol, filter and hardware-configuration entries from the runtime
libraries. Both 1,732-line outputs have SHA-256:

`72fef45a39ca86b323d84225aa33c375614b4f83a0d27b5bc339ff6f981c0b50`

The byte-for-byte empty diff covers, among the complete enumeration:

- H.264, HEVC and AV1 video support;
- AAC, AC3 and EAC3 audio support;
- MOV/MP4, Matroska, MPEG-TS and HLS demuxers;
- HTTP, HTTPS and TCP protocols;
- ASS subtitle decoding;
- VideoToolbox hardware configurations.

libmpv retains the same 54-symbol public client interface, linked subtitle
stack (`libass`/HarfBuzz through unchanged support libraries), network stack,
CoreAudio and VideoToolbox-facing media stack. The bridge retains all 25
stable exported functions.

## Boundary of This PASS

This PASS establishes architecture, load-command compatibility, public ABI,
and enumerated FFmpeg feature equality. It does not establish playback UX,
performance, HDR appearance, subtitle appearance, or live switching quality.
Those remain separate regression gates. It also does not promote the unchanged
Level B/C support components to Level A.
