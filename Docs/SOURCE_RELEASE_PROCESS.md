# Immutable Corresponding-Source Release Process

## Published 0.9.0 identity

Release `v0.9.0` pins exact clean main commit `4a69c5905cbb1717f86c84e7ac7f6b9d56956cdb`, rebuilt by the existing distribution pipeline. The Accepted/stapled public DMG is `OKVideoMac-0.9.0.dmg`; `OKVideoMac-0.9.0-macOS-arm64.zip` remains internal. Index `OKVideoMac-0.9.0-build155-SOURCE_RELEASE_INDEX.json`, source and third-party source archives, licences, APK, SBOMs, notes and signed feed bind this release. All 16 public assets passed draft and anonymous download SHA-256 checks against local files and GitHub digests. See [formal verification](RELEASE_VALIDATION_0.9.0.md). Documentation commits after publication preserve the tag, binary, signed feed and build-time source/notes snapshots.

## Earlier local candidates

Builds 141–154 were local acceptance candidates used to verify the changes now included in 0.9.0. Their captured source trees and local DMGs are engineering evidence, not formal public release assets. The 0.9.0 distribution set is rebuilt from its exact clean main commit.

## Published 0.8.7 identity

Release `v0.8.7` pins clean main commit `8208c1ea6db514cb35bbd32bbed8a15ade06cb03`. The notarized/stapled public download is `OKVideoMac-0.8.7.dmg`; `OKVideoMac-0.8.7-macOS-arm64.zip` remains internal. Source index `OKVideoMac-0.8.7-build140-SOURCE_RELEASE_INDEX.json`, source/licence archives, APK, SBOMs, notices, notes and signed feed bind the final release. All 16 public assets passed local/GitHub/anonymous SHA-256 checks. See [formal verification](RELEASE_VALIDATION_0.8.7.md); earlier tags/assets remain immutable.

## Published 0.8.6 identity

The published release uses `OKVideoMac-0.8.6.dmg`, internal `OKVideoMac-0.8.6-macOS-arm64.zip`, and `OKVideoMac-0.8.6-build139-SOURCE_RELEASE_INDEX.json`. Public source keeps an empty crash ingest configuration; the official App receives its public DSN as a private packaging input before signing. See [configuration](CRASH_REPORTING_RELEASE_CONFIGURATION.md). Tag v0.8.6 pins 590a065d93116d341f94b925b46d8fed0d719744; all 16 public assets passed [verification](RELEASE_VALIDATION_0.8.6.md). Prior release assets remain immutable.

## Published 0.8.5 identity

The published release uses `OKVideoMac-0.8.5.dmg`, internal `OKVideoMac-0.8.5-macOS-arm64.zip`, and `OKVideoMac-0.8.5-build138-SOURCE_RELEASE_INDEX.json`. Public distribution requires the existing exact-main-commit, signing, notarization, install and source/asset gates. Static PLCrashReporter and Sentry source/notice records accompany this release. Tag v0.8.5 pins b7fd9026bfee95d2d815dbb39e985225c3004e67; all final asset hashes passed [verification](RELEASE_VALIDATION_0.8.5.md). The existing 0.8.4 artifacts below remain immutable.

The published 0.8.4 (Build 137) release uses `OKVideoMac-0.8.4-macOS-arm64.zip` as the internal identity carrier, `OKVideoMac-0.8.4.dmg` as the notarized public download, and `OKVideoMac-0.8.4-build137-SOURCE_RELEASE_INDEX.json` as its source-side identity.

Tag `v0.8.4` pins `58e83d0aa29c7a7ffa9a00b15011875678395481`. Apple Notarization Accepted, stapling, Gatekeeper, installation and all 16 public asset checks passed; see [formal verification](RELEASE_VALIDATION_0.8.4.md). The branch candidate was not reused. Documentation updates preserve signed artifacts and immutable build-time source/notes snapshots.

Historical 0.8.3 release evidence remains in [its verification](RELEASE_VALIDATION_0.8.3.md).

Each formal OKVideoMac binary must be published with a source set produced by
`macOS/OKVideoMac/Scripts/create-source-release.sh` from the exact release Git
commit. Moving branches and `latest` URLs are not corresponding-source links.

For the formal 0.9.0 release (Build 155), the required release artifact set is:

- `OKVideoMac-0.9.0-build155-source.tar.gz`
- `OKVideoMac-0.9.0-build155-third-party-source.tar.gz`
- `OKVideoMac-0.9.0-build155-licenses.tar.gz`
- `OKVideoMac-0.9.0-build155-SOURCE_RELEASE_INDEX.json`
- `OKVideoMac-0.9.0-build155-SOURCE_RELEASE_MANIFEST.json`
- `OKVideoMac-0.9.0-build155-SHA256SUMS`
- `OKVideoMac-0.9.0-macOS-arm64.zip` (internal identity/archive carrier)
- `OKVideoMac-0.9.0.dmg` (the public binary bound by the final manifest)
- `OKVideoMac-0.9.0.dmg.sha256` (checksum of the final stapled DMG)
- `OKVideoMac-0.9.0-AndroidDexBridge-release.apk`
- `THIRD_PARTY_NOTICES.md`
- `RELEASE_NOTES_0.9.0.md`
- `appcast.xml` (signed stable feed; immutable DMG URL and embedded release notes)

The Build 155 release set must also include the macOS and Android SPDX/CycloneDX
files (`OKVideoMac-macOS.spdx.json`, `OKVideoMac-macOS.cdx.json`,
`OKVideoMac-Android.spdx.json`, and `OKVideoMac-Android.cdx.json`), and the
release-specific `OKVideoMac-0.9.0-build155-SHA256SUMS` that binds the release
asset set. The ZIP remains the established internal `binary` identity carrier;
it is not the public user download. The DMG is recorded separately as the
public release artifact.

The project archive is a deterministic `git archive` of the fixed commit. It
contains OKVideoMac, OKVideoKit, Xcode/XcodeGen configuration, Android bridge
and modified catvod source, QuickJS/mpv bridges, patches, tests, documentation,
and release/legal scripts. Git-ignored user data, caches, logs, build output,
downloaded spiders, credentials, and local configuration cannot enter it.

The third-party archive contains hash-verified upstream source inputs plus the
lock files, build recipes, patch/change notices and MPL covered-file map. The
large FongMi repository archive is used only as a verified input: the release
archive contains a deterministic source-only subset (`LICENSE.md`, catvod
build file and `catvod/src/main`) so unrelated upstream prebuilt AARs are not
redistributed.

Native inputs are sourced from `ThirdParty/native-lock.json`. The generator
downloads and verifies every exact available native archive. It records but
does not disguise exceptions: the missing original zlib 1.3.2 distfile and
historical clang-11 input used by MacPorts libc++ remain explicit in the
manifest and keep native provenance incomplete.

The formal 0.8.4 package was built with Xcode 16.2 / macOS SDK 15.2 on macOS
14.8.9. Formal release manifests must record the actual final builder, not copy
historical values. For release 0.6.1 (101), the manifest records Xcode 16.2 and macOS SDK 15.2 as
the actual release package builder. Xcode 14.2 remains the older supported
macOS 12 baseline, but is not reported as the tool that produced this audited
binary.

The licenses archive contains the project license/notices, every retained
third-party license, APK notices, change notices, and provenance documents.
`SOURCE_RELEASE_INDEX.json` records the source-side mapping and is safe to
embed in the signed App. After the ZIP and DMG are final, rerun with `--binary`
for the ZIP and `--release-artifact` for the DMG to
create the outer `SOURCE_RELEASE_MANIFEST.json` and `SHA256SUMS`; these bind the
immutable binary and all source archives without creating a circular App hash.
The generator preserves the existing ZIP validation: it verifies the embedded
source index and APK byte-for-byte. `verify-dmg.sh` independently mounts the
DMG read-only and verifies its exact two-item layout, App identity, signature,
and embedded source index. The generator then copies the ZIP, DMG, and APK into
the same release directory and includes all three in `SHA256SUMS`, so that directory is independently
verifiable without relying on paths elsewhere on the build machine.
Finalization fails unless the ZIP contains a byte-identical embedded source
index and the same APK supplied to the manifest, preventing a same-version
older binary from being attached to a newer source set.

Example:

```sh
OKVideoMac/macOS/OKVideoMac/Scripts/create-source-release.sh \
  --output-dir /path/to/release \
  --cache-dir /path/to/verified-source-cache \
  --commit HEAD

OKVideoMac/macOS/OKVideoMac/Scripts/create-source-release.sh \
  --output-dir /path/to/release \
  --cache-dir /path/to/verified-source-cache \
  --commit HEAD \
  --binary /path/to/OKVideoMac-0.8.4-macOS-arm64.zip \
  --release-artifact /path/to/OKVideoMac-0.8.4.dmg
```

Use `--offline` for the second run or for an air-gapped release after every
locked input is present in the cache. The script fails on a dirty worktree,
unknown commit, binary/version mismatch, unavailable input, or any checksum
mismatch.

The public Build 137 set must be generated from the exact clean commit selected
for `v0.8.4`. After all distribution gates pass, the tag must point to that same
commit. The notarized and stapled DMG, checksum, source archives, manifests, and
SBOMs must be published together on the GitHub Release. Historical
Build 62/63/64/65/94 records remain historical facts and must not be presented
as the current release.

## 0.8.4 release

Release artifact names (distribution gates passed; see [verification](RELEASE_VALIDATION_0.8.4.md)): `OKVideoMac-0.8.4.dmg`, `OKVideoMac-0.8.4-macOS-arm64.zip`,
and `OKVideoMac-0.8.4-build137-SOURCE_RELEASE_INDEX.json`.
Formal artifacts bind the clean main release commit. Earlier local snapshots retain
acceptanceOnly/publicReleaseEligible flags and cannot be published, even when
signed with Developer ID for loopback Sparkle testing.

The formal 0.8.4 pipeline additionally binds signed `appcast.xml` as a release
artifact after DMG notarization and stapling. It references the immutable DMG
URL and embeds release notes. Publish it with the existing 16-asset layout;
the ZIP remains an internal identity carrier. Local acceptance artifacts and
test signing keys remain ineligible for publication.
