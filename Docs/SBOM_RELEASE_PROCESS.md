# Release SBOM Process

Date: 2026-09-05

Every packaged release contains four machine-readable documents under
`Contents/Resources/Legal/Compliance/SBOM/`:

- `OKVideoMac-macOS.spdx.json` (SPDX 2.3);
- `OKVideoMac-macOS.cdx.json` (CycloneDX 1.6);
- `OKVideoMac-Android.spdx.json` (SPDX 2.3);
- `OKVideoMac-Android.cdx.json` (CycloneDX 1.6).

`Tools/SourceAudit/generate_sbom.py` inventories the built App, not a static
expected-file list. It refuses an unknown Mach-O and requires exactly 28
arm64 Mach-O components. Every nested Mach-O has a final post-signing SHA-256.
The main executable deliberately has no embedded-SBOM hash because signing the
outer App rewrites its code signature, which would create a circular resource
hash. Its integrity is checked by `codesign` after outer signing.

The Android documents contain the AndroidDexBridge aggregate, exact FongMi
commit, and all 87 coordinates in the tracked `releaseRuntimeClasspath`
Gradle lock. Locally resolved Maven artifacts carry SHA-256 values; the APK
aggregate carries the exact embedded APK SHA-256. Excluded xpp3 is forbidden.

`Tools/SourceAudit/verify_sbom.py` compares the actual Mach-O path set with the
SPDX packages, validates all non-main Mach-O hashes, and compares Maven
coordinates and versions with the Gradle lock. `verify-bundle.sh` invokes it,
so a newly copied dylib or undeclared locked Android module fails packaging.
The final source-release directory contains all four SBOMs, and its manifest
and SHA256SUMS include their exact SHA-256 values beside the public DMG.

## Published 0.4.0 values

The formal Build 94 assets published with tag `v0.4.0` have these SHA-256
values:

| SBOM | SHA-256 |
| --- | --- |
| `OKVideoMac-macOS.spdx.json` | `78d0181e5105735b1fe0c4ae0d2be53a20382615f266b756aefd58b3dd1d8be8` |
| `OKVideoMac-macOS.cdx.json` | `1e6f23225f560b7af1b46a277d1038930f8b53ec373969156c17767c78064484` |
| `OKVideoMac-Android.spdx.json` | `3dc95b64b6ba39f74aaaec41be1165b8a6ff885954716164613cf6631973a22c` |
| `OKVideoMac-Android.cdx.json` | `71b2832013305bd2e1422d783853ebaf16618beaf671a1d09e4bda8f517c25a4` |

The release also publishes `THIRD_PARTY_NOTICES.md` with SHA-256
`d34884d5145f972713ba91a816395c7ececb9cffdf1bd3968ccfc9366f774ad9`.
All five files are named in the outer source-release manifest and checksums.
