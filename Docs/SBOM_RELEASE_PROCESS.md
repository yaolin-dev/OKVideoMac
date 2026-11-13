# Release SBOM Process

0.9.4（Build 208）已正式发布，标签 `v0.9.4` 固定构建提交 `89455caa1e59fe8f798798b84374420fe0c65112`。最终 DMG SHA-256 为 `2d2ffd84375495c3ce9af815dae2f768b0ea50ece7247ea99b48af9cf4c80813`。见[正式验证](RELEASE_VALIDATION_0.9.4.md)。

0.9.4（Build 208）的 SBOM 使用 Android Bridge 0.3.59（71）和现有原生依赖锁。见[发布说明](RELEASE_NOTES_0.9.4.md)。

**2026-11-05：0.9.2 / Build 198 已正式发布。** 签名、公证 Accepted、staple、Gatekeeper、安装、准确提交 CI 及 16 项匿名公开下载均通过。完整结果与 SHA-256 见[正式验证](RELEASE_VALIDATION_0.9.2.md)；下方历史记录保留各自范围。

Date: 2026-11-11

Previous published release: OKVideoMac 0.9.3 (Build 204), Android Bridge 0.3.59 (71). The Android SBOMs derive their aggregate versions and package URLs from the Bridge source and verify the packaged APK hash. Build 204 passed macOS and Android SBOM verification. See [release validation](RELEASE_VALIDATION_0.9.3.md) for the four public SBOM checksums.

Every packaged release contains four machine-readable documents under
`Contents/Resources/Legal/Compliance/SBOM/`:

- `OKVideoMac-macOS.spdx.json` (SPDX 2.3);
- `OKVideoMac-macOS.cdx.json` (CycloneDX 1.6);
- `OKVideoMac-Android.spdx.json` (SPDX 2.3);
- `OKVideoMac-Android.cdx.json` (CycloneDX 1.6).

`Tools/SourceAudit/generate_sbom.py` inventories the built App, not a static
expected-file list. It refuses unknown or missing executables by comparing the exact approved Mach-O
path set in `ThirdParty/approved-macho-paths.json`. The 0.9.3 package contains
38 arm64 Mach-O components, including five Sparkle executables; the count is
derived from that exact path set and is not a lower-bound allowance. Every nested Mach-O has a final post-signing SHA-256.
The main executable deliberately has no embedded-SBOM hash because signing the
outer App rewrites its code signature, which would create a circular resource
hash. Its integrity is checked by `codesign` after outer signing.

The Android documents contain the AndroidDexBridge aggregate, exact FongMi
commit, and all 170 coordinates in the tracked `releaseRuntimeClasspath`
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

## Android aggregate metadata gate (Build 198)

`generate_sbom.py` reads the single literal `versionName` in the Bridge app build.gradle, using it for the SPDX aggregate version/purl and CycloneDX metadata/component version/purl/bom-ref. `verify_sbom.py` independently checks both documents against that source version and the SHA-256 of the exact packaged APK, rejecting stale metadata and missing or duplicate aggregates. Ten regression tests cover version changes and these rejection paths. The existing APK/host version contract remains required.

The strict inventory contains 38 Mach-O paths, 170 locked Maven modules and two static diagnostics SDKs. uchardet 0.0.8 and the unmodified Noto Sans CJK SC 2.004 font additionally retain their native lock, source archive, notices and font provenance; those records do not imply an extra dynamic executable.
