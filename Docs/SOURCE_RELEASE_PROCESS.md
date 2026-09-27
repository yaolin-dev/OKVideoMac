# Immutable Corresponding-Source Release Process

The formal 0.7.3 (Build 129) release uses
`OKVideoMac-0.7.3-macOS-arm64.zip` as its internal identity/archive carrier and
`OKVideoMac-0.7.3.dmg` as its public user download. Tag `v0.7.3` pins exact
release commit `55ffa9d55faced404b20034d7cfe5bcfbc1be581`; the 15 public assets were
published with the GitHub Release and verified against the build outputs. See the
[final validation record](RELEASE_VALIDATION_0.7.3.md).

> Historical note: the 0.6.1 DMG passed Developer ID signing, Apple notarization, stapling, Gatekeeper
> and installation smoke tests. Tag `v0.6.1` pins release commit
> `25155f52fb8c416f3245c9a829a93175dec9857b`; see the
> [validation record](RELEASE_VALIDATION_0.6.1.md). Subsequent documentation updates
> do not rewrite signed assets or build-time source/notes snapshots. The v0.6.0 set is unchanged.

Each formal OKVideoMac binary must be published with a source set produced by
`macOS/OKVideoMac/Scripts/create-source-release.sh` from the exact release Git
commit. Moving branches and `latest` URLs are not corresponding-source links.

For the formal 0.7.3 release (Build 129), the required public artifact set is:

- `OKVideoMac-0.7.3-build129-source.tar.gz`
- `OKVideoMac-0.7.3-build129-third-party-source.tar.gz`
- `OKVideoMac-0.7.3-build129-licenses.tar.gz`
- `OKVideoMac-0.7.3-build129-SOURCE_RELEASE_INDEX.json`
- `OKVideoMac-0.7.3-build129-SOURCE_RELEASE_MANIFEST.json`
- `OKVideoMac-0.7.3-build129-SHA256SUMS`
- `OKVideoMac-0.7.3-macOS-arm64.zip` (internal identity/archive carrier)
- `OKVideoMac-0.7.3.dmg` (the public binary bound by the final manifest)
- `OKVideoMac-0.7.3-AndroidDexBridge-release.apk`
- `THIRD_PARTY_NOTICES.md`
- `RELEASE_NOTES_0.7.3.md`

The Build 129 release set must also include the macOS and Android SPDX/CycloneDX
files (`OKVideoMac-macOS.spdx.json`, `OKVideoMac-macOS.cdx.json`,
`OKVideoMac-Android.spdx.json`, and `OKVideoMac-Android.cdx.json`), and the
release-specific `OKVideoMac-0.7.3-build129-SHA256SUMS` that binds the release
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

For release 0.7.3 (129), the generated index and manifest record the actual
release builder, exact commit, binary hashes and source inputs. Xcode 14.2 remains
the older supported macOS 12 baseline, but is not reported as the tool that
produced the audited 0.7.3 binary.

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
  --binary /path/to/OKVideoMac-0.7.3-macOS-arm64.zip \
  --release-artifact /path/to/OKVideoMac-0.7.3.dmg
```

Use `--offline` for the second run or for an air-gapped release after every
locked input is present in the cache. The script fails on a dirty worktree,
unknown commit, binary/version mismatch, unavailable input, or any checksum
mismatch.

The public Build 129 set must be generated from the exact clean commit selected
for `v0.7.3`. After all distribution gates pass, the tag must point to that same
commit. The notarized and stapled DMG, checksum, source archives, manifests, and
SBOMs must be published together on the GitHub Release. Historical
Build 62/63/64/65/94 records remain historical facts and must not be presented
as the current release.
