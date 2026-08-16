# OKVideoMac Immutable Release Readiness

> **Historical Build 62 release-readiness snapshot**
>
> This document records the pre-finalization Build 62 state as assessed on
> 2026-08-13. Its original findings are retained unchanged as historical
> engineering evidence and do not describe the final v0.3.41 release. The final
> v0.3.41 release is Build 64; Build 63 was a later pre-publication candidate.
> The final binary, source-release, signing, notarization,
> and publication state are defined by the current release metadata and release
> documentation.

Date: 2026-08-13

Release: OKVideoMac 0.3.41 (62)

Publication workflow status: **READY_FOR_IMMUTABLE_PUBLICATION**

Public GitHub Release status: **NOT PUBLISHED**

Apple distribution status: **EXTERNAL CREDENTIAL GATE**

The project can create a single immutable release set from one exact clean Git
commit. This document does not authorize or perform a public upload. The
current local package is ad-hoc signed for structural verification; the public
macOS distribution artifact must be regenerated under Developer ID and
notarized before a formal Apple-gated release.

## One-Shot Release Set

The final GitHub Release must attach, in one publication action:

1. final post-signing/post-notarization/post-staple macOS ZIP (or final DMG);
2. deterministic project source tarball;
3. locked third-party source tarball;
4. complete licenses tarball;
5. source release index;
6. binary-bound source release manifest;
7. `SHA256SUMS`;
8. macOS and Android SPDX/CycloneDX SBOMs; and
9. release notes describing known provenance and license-interpretation risk.

The exact APK is copied alongside those files and is hash-bound by the same
manifest. `create_source_release.py` rejects a dirty or mismatched commit,
builds source archives from that commit, and records the binary, APK, SBOM,
archive and license payload hashes.

## Mutation and Hash Rule

The final binary hash is calculated only after every operation that mutates
the distributable. For a Developer ID release this means after nested signing,
outer signing, notarization, stapling and archive recreation. The outer source
manifest and `SHA256SUMS` are created after that final archive exists. Hashes
from an unsigned, ad-hoc, pre-notarization or pre-staple artifact are not final
publication hashes.

## Current Boundary

The verified local package proves source-release generation, SBOM equality,
legal payload completeness, structural signing, package integrity and outer
binary/source binding. It is suitable as engineering evidence, not as a claim
of Apple notarization. Once Apple credentials are available, rerun the same
locked workflow at the same intended release commit and publish only the new
post-staple set. GitHub publication itself remains an explicit user action.
