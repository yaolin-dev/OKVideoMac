# Immutable Corresponding-Source Release Process

Each formal OKVideoMac binary must be published with a source set produced by
`macOS/OKVideoMac/Scripts/create-source-release.sh` from the exact release Git
commit. Moving branches and `latest` URLs are not corresponding-source links.

For 0.3.41 (Build 62), the generated set is:

- `OKVideoMac-0.3.41-build62-source.tar.gz`
- `OKVideoMac-0.3.41-build62-third-party-source.tar.gz`
- `OKVideoMac-0.3.41-build62-licenses.tar.gz`
- `OKVideoMac-0.3.41-build62-SOURCE_RELEASE_INDEX.json`
- `OKVideoMac-0.3.41-build62-SOURCE_RELEASE_MANIFEST.json`
- `OKVideoMac-0.3.41-build62-SHA256SUMS`

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

The licenses archive contains the project license/notices, every retained
third-party license, APK notices, change notices, and provenance documents.
`SOURCE_RELEASE_INDEX.json` records the source-side mapping and is safe to
embed in the signed App. After the App ZIP is final, rerun with `--binary` to
create the outer `SOURCE_RELEASE_MANIFEST.json` and `SHA256SUMS`; these bind the
immutable binary and all source archives without creating a circular App hash.
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
  --binary /path/to/OKVideoMac-0.3.41-macOS-arm64.zip
```

Use `--offline` for the second run or for an air-gapped release after every
locked input is present in the cache. The script fails on a dirty worktree,
unknown commit, binary/version mismatch, unavailable input, or any checksum
mismatch.
