# mpv v0.41.0 Local Modification Notice

- Upstream: <https://github.com/mpv-player/mpv/tree/v0.41.0>
- Upstream version: `v0.41.0`
- License mode of the resulting build: `GPL-2.0-or-later`
- Patch: `mpv-0.41.0-coreaudio-without-cocoa.patch`
- Patch SHA-256: `f57fa49d8916d3ffc3834bb3f2a53b041c0113984bbd9f3ef6b68257b3c0af9f`
- First project baseline carrying the patch: OKVideoMac 0.3.20,
  committed 2026-08-08

## Purpose and effect

The patch modifies upstream `meson.build`. It moves `osdep/utils-mac.c` from
the Cocoa-only source list to the source list used by every Darwin build. This
allows mpv's CoreAudio path to use the macOS utility implementation when Cocoa
is disabled. It does not change the implementation in `utils-mac.c`; it
changes which upstream source file is compiled for that configuration.

The distributed `libmpv.dylib` therefore corresponds to the fixed upstream
source archive plus this patch, not to an unmodified upstream binary.
