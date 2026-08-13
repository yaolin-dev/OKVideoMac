# Phase 4 Provenance-Clean Native Candidate Build

Date: 2026-08-13

Release under comparison: OKVideoMac 0.3.41 (62)

Status: **PARTIAL MEDIA-CORE CANDIDATE BUILT; NOT A FULL 28-MACH-O REPLACEMENT SET**

This build answers whether the currently locked FFmpeg/mpv media core can be
replayed from exact source without upgrading it. It does not claim that the
historical stable batch used this environment, and it does not promote the
remaining Level B or Level C support libraries.

## Locked Inputs

| Component | Version | Exact source SHA-256 | Patch SHA-256 |
| --- | --- | --- | --- |
| FFmpeg | 7.1.4 | `71f4aac3573ed9060489cb62526a6c7dda815ae10993789611acd7be9fa9fbf4` | none |
| mpv | 0.41.0 | `ee21092a5ee427353392360929dc64645c54479aefdb5babc5cfbb5fad626209` | `f57fa49d8916d3ffc3834bb3f2a53b041c0113984bbd9f3ef6b68257b3c0af9f` |

No dependency version was upgraded. The archives were read from the locked
local source cache and their hashes were checked before extraction.

## Environment and Recipe

- Host: macOS 14.8.8 (23J620), arm64.
- Compiler: Apple clang 16.0.0 (`clang-1600.0.26.6`).
- Xcode / SDK: Xcode 16.2 (`16C5032a`), macOS SDK 15.2.
- Architecture: arm64.
- Deployment target: macOS 12.0.
- Build root: a dedicated, non-release local root represented as
  `<PHASE4_NATIVE_BUILD_ROOT>`.
- FFmpeg recipe: `Scripts/build-third-party-native.sh`.
- mpv/bridge recipe: `Scripts/build-libmpv-repro.sh`.
- Comparison recipe: `Scripts/compare-native-candidate.sh`.

FFmpeg was configured as shared-only, PIC, no programs/docs/debug/avdevice,
autodetection disabled, and with network, SecureTransport, VideoToolbox,
AudioToolbox, zlib, bzip2, iconv, lzma and pthreads explicitly enabled. The
compiler and linker flags lock arm64, optimization `-O2`, and the macOS 12.0
minimum. The complete executable argument construction is retained in the
script rather than copied into a host-path-bearing environment dump.

mpv was configured with Meson for an arm64 shared library, patched CoreAudio,
Cocoa/Swift/media-player/touchbar disabled, plain GL and CoreAudio enabled,
and JavaScript/Lua/cplugins/VapourSynth/libavdevice disabled. Its FFmpeg inputs
are the candidate outputs above; unchanged support dependencies are still the
stable MacPorts inputs.

## Resulting Candidate Outputs

| Candidate output | SHA-256 |
| --- | --- |
| `libavcodec.61.dylib` | `8e890986c33ea5b5c19a83932be11ed2d2978b1e9cd95f81c48ba9acb022b8be` |
| `libavfilter.10.dylib` | `7c0b391b86c4bd91a1946ef7eb2f022e39ede4e0d06df3d321e052ef69c25d54` |
| `libavformat.61.dylib` | `d2712a32729890b3f9c52ba8a9118a02121c62748055bb37ee7da057b46731f8` |
| `libavutil.59.dylib` | `4131f25fb921db79ca61dee351630fcafebe0e50da1208b31d4bb7771fbffddb` |
| `libswresample.5.dylib` | `79b29d481f9508af37d04b22a25fdb34e23b22130213f50fcf279480d7386c18` |
| `libswscale.8.dylib` | `091548b0daa2b0573ccf3205339c5ef43984e0139143798732f8353883a2a240` |
| `libmpv.2.dylib` | `1923687feeaab38dd7cf93119288faee05f52b111686ba531b66769c5fa53916` |
| `libOKMPVBridge.dylib` | `47005b6fd928a91de20c0c39a5a36917f8a16bfac6bf7cd459eea3267ac30077` |

The FFmpeg link/run smoke reported libavcodec `4002661`, libavformat `3999590`
and `LGPL version 2.1 or later`. The bridge smoke passed client API 2.5 and
event size 64.

## Bridge Source-Binding Correction

The stable bridge exports 25 symbols, including `okmpv_probe_media_info` and
`okmpv_probe_dolby_vision`. The Phase 3 checkout contained an older 23-symbol
bridge source, so it could not truthfully be described as the exact source of
the stable bridge. The corresponding implementation was recovered from
project history at commit `481dc64` and restored byte-for-byte:

- `OKMPVBridge.c` SHA-256:
  `591c4a94b41a6ee10d1d5ad8fd283b1147c01f8c433dca7e5688675d3dd69e02`
- `OKMPVBridge.h` SHA-256:
  `7d758788817b2a536b32f41bad7b69a629c63189d372344112754a9d6596a5e5`

This closes the project-source mapping gap without changing the distributed
stable binary. Direct FFmpeg link flags were added to both bridge recipes so
the restored probe implementation is linked and testable.

## Scope Limit and Decision

This is a provenance-clean candidate for eight media-core outputs, not for the
entire App. libass, HarfBuzz, libplacebo, FreeType, FriBidi, iconv, zlib,
libc++/libc++abi and the other stable support libraries were not rebuilt.

Decision at this stage: **KEEP_STABLE_NATIVE_BINARIES**. No candidate was
copied into the stable build root or Desktop App. Replacement requires ABI and
capability checks, automated playback/performance regression, and a credible
manual pass; build success alone is insufficient.
