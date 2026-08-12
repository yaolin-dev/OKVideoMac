# Open Source Compliance Guide

## Licensing model

OKVideoMac project-owned code is released under `GPL-3.0-only`. That choice is
compatible with the current GPL-enabled mpv combination, but it does not
replace or erase third-party licenses. MIT, ISC, Apache-2.0, LGPL, MPL, FTL,
and other third-party material continues under its original terms.

The baseline legal audit is `Docs/THIRD_PARTY_LICENSE_AUDIT.md`. The maintained
release materials are:

- `OKVideoMac/NOTICE.md` — project source and copied-source disclosure;
- `OKVideoMac/THIRD_PARTY_NOTICES.md` — authoritative App component index;
- `OKVideoMac/THIRD_PARTY_LICENSES/` — exact license/NOTICE texts;
- `OKVideoMac/Helpers/AndroidDexBridge/THIRD_PARTY_NOTICES.md` — APK graph;
- `Docs/SOURCE_PROVENANCE_MANIFEST.md` — versions, hashes, inputs, outputs;
- `Docs/BINARY_SOURCE_MAPPING.md` — immutable binary-to-source answers; and
- `Docs/OPEN_SOURCE_P0_STATUS.md` — unresolved release blockers.

Release packaging copies this material into
`OKVideoMac.app/Contents/Resources/Legal/` so the App is self-describing.

## Important current facts

- mpv v0.41.0 is built with GPL enabled (`HAVE_GPL 1`) and with a local source
  patch. Its corresponding source is the fixed upstream archive plus that
  patch, not the pristine upstream tree alone.
- FFmpeg 7.1.4 follows `LGPL-2.1-or-later`: its embedded configuration does not
  enable GPL, version3, nonfree, x264, x265, libfdk-aac, OpenSSL, or GnuTLS.
- The Android bridge contains source copied and modified from FongMi/TV at
  commit `5fdff00a602dc56e8ba756174daef20edab024f2`, under `GPL-3.0-only`.
- Node.js is an official Node 22.23.0 darwin-arm64 binary input that is re-signed
  during packaging; Node's distribution LICENSE covers its bundled notices.
- An exact-version license/source proof for `xpp3:1.1.3.3` and a rights chain
  for the App icon are not available. The release remains **Blocked**.

## Corresponding source

For a binary release, follow `BINARY_SOURCE_MAPPING.md` and publish immutable
project and third-party source material. GPL modified sources must include the
actual local changes and build instructions. LGPL dynamic libraries need their
exact source/configuration and a documented lawful replacement path. MPL-1.1
covered source must be made available. A moving branch or an upstream homepage
does not identify the source corresponding to a historical binary.

## Release checklist

Before every new release, the maintainer must:

1. Resolve Gradle `releaseRuntimeClasspath` and inventory every APK runtime
   artifact, including transitive version changes.
2. Build/package Release, recursively inventory every bundled Mach-O and APK,
   and compare the result with both notices and the provenance manifest.
3. Update exact versions, source/tag/commit, archive URL, SHA-256, build flags,
   patches, patch hashes, output hashes, and provenance status.
4. Preserve upstream copyright/SPDX headers, component NOTICE files, FFmpeg/IJG
   and FreeType credits, and the complete Node distribution LICENSE.
5. Create immutable source archives for project GPL code, patched mpv, modified
   FongMi/catvod, LGPL native inputs, and MPL covered source.
6. Confirm the App's `Resources/Legal/` payload contains the project LICENSE,
   both notices, every referenced license file, provenance/mapping documents,
   APK notice entry, and change notices.
7. Run repository link/path/conflict checks, bundle verification, Hardened
   Runtime verification, 28-Mach-O architecture/dependency verification, and
   `codesign --verify --deep --strict` on the actual deliverable.
   Confirm the generated `Legal/Compliance/BUILD_OUTPUT_SHA256.txt` matches the
   27 stable nested Mach-O files and the embedded APK. Verify the main
   executable through the final outer App signature; it cannot self-report a
   stable hash because signing that outer container rewrites the executable.
8. Reassess `OPEN_SOURCE_P0_STATUS.md`. Do not publish while any P0 remains.

Never upgrade or replace a third-party binary without synchronizing its source
lock, license, notices, change record, binary mapping, and final output hashes.
Never mark provenance `VERIFIED` based on a filename or version string alone.
