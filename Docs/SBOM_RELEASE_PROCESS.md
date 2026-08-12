# Release SBOM Process

Date: 2026-08-13

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
The final source-release manifest includes the SHA-256 of all four SBOMs.
