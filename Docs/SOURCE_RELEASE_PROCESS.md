# Immutable Corresponding-Source Release Process

Each formal OKVideoMac binary must be published with a source set produced by
`macOS/OKVideoMac/Scripts/create-source-release.sh` from the exact release Git
commit. Moving branches and `latest` URLs are not corresponding-source links.

For the formal 0.5.0 release (Build 99), the published set is:

- `OKVideoMac-0.5.0-build99-source.tar.gz`
- `OKVideoMac-0.5.0-build99-third-party-source.tar.gz`
- `OKVideoMac-0.5.0-build99-licenses.tar.gz`
- `OKVideoMac-0.5.0-build99-SOURCE_RELEASE_INDEX.json`
- `OKVideoMac-0.5.0-build99-SOURCE_RELEASE_MANIFEST.json`
- `OKVideoMac-0.5.0-build99-SHA256SUMS`
- `OKVideoMac-0.5.0-macOS-arm64.zip` (internal identity/archive carrier)
- `OKVideoMac-0.5.0.dmg` (the public binary bound by the final manifest)
- `OKVideoMac-0.5.0-AndroidDexBridge-release.apk`
- `THIRD_PARTY_NOTICES.md`
- `RELEASE_NOTES_0.5.0.md`

The Build 99 release set also includes the macOS and Android SPDX/CycloneDX
files (`OKVideoMac-macOS.spdx.json`, `OKVideoMac-macOS.cdx.json`,
`OKVideoMac-Android.spdx.json`, and `OKVideoMac-Android.cdx.json`), and the
release-specific `OKVideoMac-0.5.0-build99-SHA256SUMS` that binds the release
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

For release 0.5.0 (99), the manifest records Xcode 16.2 and macOS SDK 15.2 as
the actual Phase 2 package builder. Xcode 14.2 remains the older supported
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
  --binary /path/to/OKVideoMac-0.5.0-macOS-arm64.zip \
  --release-artifact /path/to/OKVideoMac-0.5.0.dmg
```

Use `--offline` for the second run or for an air-gapped release after every
locked input is present in the cache. The script fails on a dirty worktree,
unknown commit, binary/version mismatch, unavailable input, or any checksum
mismatch.

The public Build 99 set is generated from the exact clean commit tagged
`v0.5.0`. The notarized and stapled DMG, checksum, source archives, manifests,
and SBOMs are published together on the GitHub Release. Historical
Build 62/63/64/65/94 records remain historical facts and must not be presented
as the current release.
