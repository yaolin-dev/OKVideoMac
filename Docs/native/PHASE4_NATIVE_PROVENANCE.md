# Phase 4 Native Bundle Provenance Inventory

Date: 2026-08-13

Release inspected:
`/Volumes/XcodeDev/OKVideoMacBuild/Artifacts/OKVideoMac.app`

This is a fresh inspection of the actual packaged Release, not a copy of the
Phase 2 report. The deterministic machine inventory is
`PHASE4_NATIVE_INVENTORY.json` and records, per Mach-O, its bundle path,
architecture, SHA-256, install name, linked dylibs, rpaths, exported-symbol
count/hash, signature state, source/version/archive/hash, and provenance level.

## Inventory Result

| Measure | Result |
| --- | ---: |
| Mach-O files | 28 |
| arm64 | 28 |
| individually valid ad-hoc signatures | 28 |
| LEVEL A | 10 |
| LEVEL B | 15 |
| LEVEL C | 3 |
| LEVEL D | 0 |

The package contains no LEVEL D native component.

## LEVEL A — Recipe / Rebuild Verified

- `Contents/MacOS/OKVideoMac` — exact project source and Xcode Release recipe;
- `libOKMPVBridge.dylib` — exact project bridge source and executable smoke;
- `libOKQuickJS.dylib` — QuickJS 2025-09-13-2 exact archive, locked build and
  bridge smoke;
- `libmpv.dylib` — mpv 0.41.0 exact archive, exact patch, locked Meson options,
  successful rebuild and client/bridge smoke;
- FFmpeg 7.1.4 six-dylib family — exact source/configuration, clean rebuild,
  public-symbol comparison and codec/network capability smoke.

LEVEL A means the current functional recipe can be replayed and checked. It
does not assert bit-for-bit recreation of the historical stable batch.

## LEVEL B — Source Locked

- Node.js 22.23.0 official binary and corresponding source;
- libass 0.17.5;
- HarfBuzz 14.2.1;
- libplacebo 7.360.1;
- FreeType 2.14.3;
- FriBidi 1.0.16;
- Brotli 1.2.0 (`libbrotlicommon`, `libbrotlidec`);
- Little CMS 2 2.19.1;
- libpng 1.6.58;
- libjpeg-turbo 3.2.0;
- XZ/liblzma 5.8.3;
- GNU libiconv 1.18;
- bzip2 1.0.8;
- SQLite 3.53.4.

For the MacPorts components, the exact upstream archive hash, installed
receipt, variants and matching retained Portfile are available. The original
complete build log/environment was not retained, so they are not promoted to
LEVEL A.

## LEVEL C — Historical Partial Provenance

- `libz.1.dylib`: zlib 1.3.2 receipt, Portfile and expected source hash are
  retained, but the original exact archive is unavailable;
- `libc++.1.0.dylib` and `libc++abi.1.dylib`: MacPorts 11.1.0 receipt and
  output identity are retained, but the historical clang-11 source/input and
  complete build configuration are unavailable.

These are disclosed historical limitations, not unknown component identity or
unknown-license artifacts. They are not replaced without full playback and
manual verification.

## Signature Boundary

All 28 packaged Mach-O files validate with ad-hoc signatures and the package
has Hardened Runtime flags in local packaging mode. Ad-hoc identity is not a
Developer ID signature and is not evidence of notarization, staple, or
Gatekeeper acceptance.

