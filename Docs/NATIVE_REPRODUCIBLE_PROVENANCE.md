# Native Reproducible Provenance — Phase 2C

Date: 2026-08-13

Overall native status: **PARTIAL — P0 remains open**

No rebuilt binary in this experiment replaces the stable Release. All outputs
are under an isolated `OKVIDEOMAC_REPRO_ROOT`; the Desktop App was not touched.

## Stable-batch reconstruction

`ThirdParty/native-lock.json` records versions, source URLs and SHA-256 values,
licenses, build systems, deployment target, output sonames, MacPorts revisions,
variants and retained Portfile hashes. The installed registry contains 42
active receipts built for `darwin 21`/arm64. Each listed receipt Portfile hash
matches the retained registry copy and current local ports-tree copy.

The host has since moved to macOS 14.8.8 (`darwin 23`) and Xcode 16.2/SDK 15.2.
MacPorts refuses build operations because the registry platform is `darwin 21`.
The old native build logs and distfiles were not retained. Therefore receipt
identity is exact, but the complete original build batch is not reproducible on
the present host without a matching clean macOS 12/Xcode environment.

Two inputs remain weaker than the required standard:

- MacPorts `macports-libcxx 11.1.0` copied outputs from a then-installed
  `clang-11` port. That clang receipt/source/configuration is no longer in the
  registry, so `libc++.1.0.dylib` and `libc++abi.1.dylib` remain
  `UNRESOLVED_SOURCE_INPUT`.
- The zlib 1.3.2 receipt/Portfile and expected distfile SHA are retained, but
  the original distfile is absent and the current upstream URL no longer
  produces that archive hash. It remains `RECEIPT_EXACT_ARCHIVE_UNAVAILABLE`.

## FFmpeg Stage 1 experiment

`build-third-party-native.sh` reconstructed the configuration embedded in the
stable FFmpeg 7.1.4 dylibs and built into an isolated prefix from the exact
archive SHA
`71f4aac3573ed9060489cb62526a6c7dda815ae10993789611acd7be9fa9fbf4`.

Verified results:

- arm64 and macOS deployment target 12.0;
- same six dylib sonames and the same public symbol sets as the stable inputs;
- shared build, LGPL 2.1-or-later, with no GPL/version3/nonfree flags;
- SecureTransport, network/HLS/HTTPS, VideoToolbox, AudioToolbox, zlib, bz2,
  iconv and lzma retained;
- H.264, HEVC and AAC decoders found by an executable ABI/capability smoke;
- output versions remained libavcodec 61.19.101, libavformat 61.7.102,
  libavfilter 10.5.100, libavutil 59.39.100, libswresample 5.3.100 and
  libswscale 8.3.100.

Two consecutive clean builds with the same current toolchain produced
bit-identical hashes for five of six dylibs. `libavutil.59.dylib` differed while
retaining the same public symbols, soname, version and runtime smoke result.
Thus bit-for-bit reproducibility is not claimed. The current outputs also carry
SDK 15.2 whereas the stable dylibs carry SDK 13.1; they establish functional
and recipe reproducibility, not exact original-batch identity.

## mpv Stage 3 experiment

`build-libmpv-repro.sh` then built patched mpv 0.41.0 against the isolated
FFmpeg family while keeping receipt-locked libass 0.17.5 and libplacebo
7.360.1. Meson reported `gpl`, `libmpv`, OpenGL, CoreAudio, libass, libplacebo,
lcms2 and the expected FFmpeg versions enabled; Cocoa and the intentionally
disabled scripting/device features remained disabled. The project bridge
compiled and its client initialization/command/header smoke passed with client
API 2.5 and event size 64.

An ad-hoc Hardened Runtime experiment bundle was created as
`OKVideoMac-ReproBuild.app`, independently of the stable Desktop app. Deep,
strict code-signature verification passed; LaunchServices started the arm64
application and the process remained alive until the audit explicitly ended
it. This is a launch health check only, not a playback or performance result.

## Verification boundary and stop decision

This experiment did not run the user's required interactive point-on-demand,
live-channel, HDR/subtitle, seek, rapid switching, history-resume and
performance matrix because no approved media/live fixture set or interactive
business test session is present in the isolated audit environment. No claim
is made about startup, first-frame, CPU, memory, dropped frames or A/V sync.

The rebuilt chain is therefore **not approved to replace the stable native
binaries**. The result is not `BLOCKED BY REPRODUCIBILITY REGRESSION`—no
regression was observed in the executed ABI/capability smokes—but it remains
blocked by incomplete batch provenance, missing libc++ input, unavailable zlib
distfile, platform drift and the unexecuted manual playback/performance gate.
