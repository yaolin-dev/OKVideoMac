# OKVideoMac 0.5.0 (Build 99) Source Provenance Manifest

Manifest date: 2026-09-07
Baseline audit: `Docs/THIRD_PARTY_LICENSE_AUDIT.md`
Status vocabulary: `VERIFIED`, `PARTIAL`, `UNRESOLVED`

`VERIFIED` means the inspected build input can be tied to a fixed official
source/distribution and integrity value. It does not mean that every release
obligation is complete. `PARTIAL` means that version/source evidence exists
but the exact binary cannot be recreated from a retained complete recipe and
log. `UNRESOLVED` means repository evidence is insufficient to establish the
stated source or provenance relationship. Build-machine paths are intentionally
represented as `<BUILD_ROOT>` and `<MACPORTS_PREFIX>`.

## Verified inputs

| Component | Version / source | Archive SHA-256 | Build input, tool, and flags | Patch | Audited output | Status |
| --- | --- | --- | --- | --- | --- | --- |
| mpv/libmpv | [v0.41.0 archive](https://github.com/mpv-player/mpv/archive/refs/tags/v0.41.0.tar.gz) | `ee21092a5ee427353392360929dc64645c54479aefdb5babc5cfbb5fad626209` | `macOS/OKVideoMac/Scripts/build-libmpv.sh`; Meson arm64, Cocoa disabled, GPL left enabled; actual config has `HAVE_GPL 1` | `mpv-0.41.0-coreaudio-without-cocoa.patch`, SHA `f57fa49d8916d3ffc3834bb3f2a53b041c0113984bbd9f3ef6b68257b3c0af9f` | pre-package `libmpv.2.dylib` `15f4516f…`; audited signed `Frameworks/libmpv.dylib` `6f2f7f53ed3ec1309ae6cef869dd8a83bb4bfff09ad9d61a87f6e2f5778b0cd4` | `VERIFIED` |
| QuickJS | [quickjs-2025-09-13-2.tar.xz](https://bellard.org/quickjs/quickjs-2025-09-13-2.tar.xz) | `996c6b5018fc955ad4d06426d0e9cb713685a00c825aa5c0418bd53f7df8b0b4` | `macOS/OKVideoMac/Scripts/build-quickjs.sh`; arm64 static archive, linker `-force_load` into project bridge | None in upstream source | pre-package bridge `d60f16…`; audited signed `libOKQuickJS.dylib` `e1dc2d48b5972e8e6d346e5f6e20da9d5e3d701163450c73f06a2d58a2141414` | `VERIFIED` |
| Node.js executable input | [node-v22.23.0-darwin-arm64.tar.gz](https://nodejs.org/download/release/v22.23.0/node-v22.23.0-darwin-arm64.tar.gz) | `e0f383a215dd3093de6d2c74f87056dc2306a2e09ad494cbffdba28f89046f56`, matching official `SHASUMS256.txt` | `project.yml` copies only `bin/node`; package script applies project entitlements and re-signs it | None; local input is byte-identical to official binary | official/local input `cc61696726abdfe8392297ecd75aa9863cd9b6435b202c0dc2266039f493da10`; audited re-signed App output `60df37880c72f74c789d0857c2729f42256e7ae944c9a5055162da97e54adc3e` | `VERIFIED` |
| FongMi/TV `catvod` source | [commit `5fdff00a…`](https://github.com/FongMi/TV/tree/5fdff00a602dc56e8ba756174daef20edab024f2/catvod/src/main) | Git commit identity; deterministic source-only subset is included in the 0.5.0 third-party source archive | Gradle 8.9 / Android plugin; compiled as Android bridge module | `Proxy.java` port `-1` → `9978`; see change notice | `AndroidDexBridge-release.apk`; per-package SHA is generated in `Legal/Compliance/BUILD_OUTPUT_SHA256.txt` | `VERIFIED` source identity and local diff; corresponding source published with `v0.5.0` |
| stax | Maven `stax:stax:1.2.0`; [Central directory](https://repo1.maven.org/maven2/stax/stax/1.2.0/) | sources JAR `dfa08201c86e04eb93baf726af3495efcc30709f6a35ba902c44dfbc36266a11`; binary JAR `df6905a047b05e23bc91f03ba57ac2f87c1ddf83e048aa0e5bd13169d5ebf0d9` | Gradle-resolved transitive input, compiled into APK | None known | Android bridge APK | `VERIFIED` exact source/license identity |
| Gradle distribution | [gradle-8.9-bin.zip](https://services.gradle.org/distributions/gradle-8.9-bin.zip) | `d725d707bfabd4dfdc958c624003b3c80accc03f7037b5122c4b1d0ef15cecab` | Wrapper 8.9; SHA locked in `gradle-wrapper.properties` | None | tracked wrapper JAR SHA `e996d452d2645e70c01c11143ca2d3742734a28da2bf61f25c82bdc288c9e637`; build-time only | `VERIFIED` distribution; wrapper JAR retained with license/NOTICE |
| juniversalchardet covered source | Maven `com.googlecode.juniversalchardet:juniversalchardet:1.0.3` [sources JAR](https://repo1.maven.org/maven2/com/googlecode/juniversalchardet/juniversalchardet/1.0.3/juniversalchardet-1.0.3-sources.jar) | sources `3d1cb067f5cfe3cc19b77c837156f22368462af9acac5dd878e785966758fc27`; binary `757bfe906193b8b651e79dc26cd67d6b55d0770a2cdfb0381591504f779d4a76`; POM `7846399b35c7cd642a9b3a000c3e2d62d04eb37a4547b6933cc8b18bcc2f086b` | exact 58-file list retained; Gradle runtime lock fixes the artifact | None by OKVideoMac | Android bridge APK | `VERIFIED` exact source delivery; **DOCUMENTED LICENSE INTERPRETATION RISK**; independent legal review `NOT PERFORMED` |

The Node investigation found that `<HOMEBREW_PREFIX>/opt/node@22-direct` is a
regular local directory rather than a Homebrew formula or symlink. It also
contains unrelated CLI packages, but the project copies only `bin/node`.
Direct comparison proves that binary is byte-for-byte identical to the
official Node 22.23.0 darwin-arm64 binary, signed by Apple Developer Team
`HX7739G8FX`. Thus the binary input is verified even though the local directory
name itself is not a package-manager provenance record.
The exact corresponding source archive is
`node-v22.23.0.tar.gz`, SHA-256
`61fd42cd1c3ff04a849f5ad5d08c58b111831944b5b94bc90fc623eab41418a2`,
from the same official v22.23.0 release directory.

## Media dependency inputs with partial build provenance

The source trees and archives below were retained under
`<BUILD_ROOT>/Source/MediaDeps`, and their versions match the binary metadata.
No complete, replayable project build script/log ties every current output to
those inputs; therefore they remain `PARTIAL`.

| Component | Version | Fixed source archive | SHA-256 | Known build evidence / output | License | Status |
| --- | --- | --- | --- | --- | --- | --- |
| FFmpeg family | 7.1.4 | `https://ffmpeg.org/releases/ffmpeg-7.1.4.tar.xz` | `71f4aac3573ed9060489cb62526a6c7dda815ae10993789611acd7be9fa9fbf4` | binary configuration proves LGPL path and flags described in `THIRD_PARTY_NOTICES.md`; six dylibs listed below | `LGPL-2.1-or-later` build | `PARTIAL` |
| libass | 0.17.5 | `https://github.com/libass/libass/archive/refs/tags/0.17.5.tar.gz` | `fa286fc9ee1ba3b932703a3df7b8474d01dc8abe29ec69b6fa68781dc4bf7acc` | retained source; `libass.9.dylib` metadata matches | `ISC` | `PARTIAL` |
| HarfBuzz | 14.2.1 | `https://github.com/harfbuzz/harfbuzz/releases/download/14.2.1/harfbuzz-14.2.1.tar.xz` | `a54a5d8e9380a41fbb762ce367bcbf7704792dfca0d93f1bbca86c5a57902e0e` | retained source; `libharfbuzz.0.dylib` metadata matches | `MIT` | `PARTIAL` |

Phase 2 adds `ThirdParty/native-lock.json` and isolated build recipes. FFmpeg
7.1.4 and patched mpv 0.41.0 were rebuilt successfully against locked versions,
with unchanged public FFmpeg symbol sets and license mode. This raises FFmpeg
to `VERIFIED` for exact source plus functional recipe reproducibility, but not
for original-batch or bit-for-bit identity; the stable SDK is 13.1 and the
current validation SDK is 15.2. The overall native chain remains `PARTIAL` for
the reasons recorded in `Docs/NATIVE_REPRODUCIBLE_PROVENANCE.md`.

## MacPorts native inputs with partial build provenance

Installed registry receipts retain exact versions, variants, and the Portfile
used. Portfile checksums identify upstream distfiles, and installed dylibs are
the inputs recursively copied by `package-app.sh`. MacPorts build logs and a
complete replay environment for this batch were not retained, so none is
promoted to `VERIFIED`.

| Component / receipt | Fixed source archive | Source SHA-256 from retained Portfile | License | Build tool / flags evidence | Audited signed output SHA-256 | Status |
| --- | --- | --- | --- | --- | --- | --- |
| libplacebo 7.360.1 | [tag archive](https://github.com/haasn/libplacebo/archive/refs/tags/v7.360.1.tar.gz) | `d05fdf90bea2f629eaa2d115e909fd356388ac639e54f77b87a018a6d76224bd` | `LGPL-2.1-or-later` | MacPorts receipt/Portfile, `+opengl` | `c0d56e040b62f565c397e833d4cdf63ed3ee0204e1a3795e65df2ece501bd95d` | `PARTIAL` |
| FreeType 2.14.3 | [freetype-2.14.3.tar.xz](https://download.savannah.gnu.org/releases/freetype/freetype-2.14.3.tar.xz) | source `36bc4f1cc413335368ee656c42afca65c5a3987e8768cc28cf11ba775e785a5f`; docs `66a988d8bbb58f83efafe555678ac172f70f0b060cf61424fe5460157470fd21` | `FTL` selected | MacPorts patches and dynamic HarfBuzz option in retained Portfile | `0aeb6b32083af5905fa455c1bb4dcfdbb4e875474cdafdcc96149a01f6f03150` | `PARTIAL` |
| FriBidi 1.0.16 | [fribidi-1.0.16.tar.xz](https://github.com/fribidi/fribidi/releases/download/v1.0.16/fribidi-1.0.16.tar.xz) | `1b1cde5b235d40479e91be2f0e88a309e3214c8ab470ec8a2744d82a5a9ea05c` | `LGPL-2.1-or-later` | MacPorts receipt/Portfile | `2c2ceea3c6f13a147a90995c42d9c8cc92b6ea5a42aa7377771e8633d2981a78` | `PARTIAL` |
| Brotli 1.2.0 | [v1.2.0 tag archive](https://github.com/google/brotli/archive/refs/tags/v1.2.0.tar.gz) | `816c96e8e8f193b40151dad7e8ff37b1221d019dbcb9c35cd3fadbfe6477dfec` | `MIT` | MacPorts receipt/Portfile | decoder `f000b6403215d7f37664c4eeb3c5085d64034d7557118c7ed61bdc54040b3e96`; common `86a2a571055f648ded77205c89fb56982cf5c4c199466e7f75c8c2216bd5d02d` | `PARTIAL` |
| Little CMS 2 2.19.1 | [lcms2-2.19.1.tar.gz](https://github.com/mm2/Little-CMS/releases/download/lcms2.19.1/lcms2-2.19.1.tar.gz) | `bfc54f7bab59fbc921012014a8032e4cba4abd46db47d46b76416a8c0b2815c8` | `MIT` | MacPorts receipt/Portfile | `7ca8711d2681113e5e442729b478ce2191014d6b7efcaa1b02d234b1d6acccd7` | `PARTIAL` |
| libpng 1.6.58 | [libpng-1.6.58.tar.xz](https://download.sourceforge.net/libpng/libpng16/1.6.58/libpng-1.6.58.tar.xz) | `28eb403f51f0f7405249132cecfe82ea5c0ef97f1b32c5a65828814ae0d34775` | `Libpng` | MacPorts receipt/Portfile | `7dbba253a553534b35d38ff9120b7d2703ac2f4fbfa216f4cbc199e461c1b35a` | `PARTIAL` |
| libjpeg-turbo 3.2.0 | [libjpeg-turbo-3.2.0.tar.gz](https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/3.2.0/libjpeg-turbo-3.2.0.tar.gz) | `6f30092cef9fb839779646608f4ee14ae3cbac989c47fa05e841b0841f09878e` | `BSD-3-Clause`, IJG, `Zlib` portions | MacPorts CMake, shared library enabled | `374bd2ae25393b6d165fd04f98b48a1930b37fdb1b2c8cefeb12b42141ecd64c` | `PARTIAL` |
| XZ/liblzma 5.8.3 | [xz-5.8.3.tar.bz2](https://github.com/tukaani-project/xz/releases/download/v5.8.3/xz-5.8.3.tar.bz2) | `33bf69c0d6c698e83a68f77e6c1f465778e418ca0b3d59860d3ab446f4ac99a6` | `0BSD` for liblzma | MacPorts receipt/Portfile | `399ead9f2d64ec9ad05d852c8a95d85608d730073684d6952f758d107074a773` | `PARTIAL` |
| SQLite 3.53.4 | [sqlite-autoconf-3530400.tar.gz](https://www.sqlite.org/2026/sqlite-autoconf-3530400.tar.gz) | `0e9483900e92cd5de8fd48d16bf9200145a61f7fd5be542a5ac81d8a9516eb9c` | Public Domain | MacPorts receipt/Portfile | `0cc34425224eb33e959bd2ff2b6d67e19f3e4208c5b79c4de27115dff2dd272c` | `PARTIAL` |
| GNU libiconv 1.18 | [libiconv-1.18.tar.gz](https://ftp.gnu.org/pub/gnu/libiconv/libiconv-1.18.tar.gz) | `3b08f5f4f9b4eb82f151a7040bfd6fe6c6fb922efe4b1659c66ea933276965e8` | `LGPL-2.1-or-later` library | MacPorts receipt/Portfile | `de69743a272ffcf7cf76b9b59cfbac1e87020f89219c5ea07771deb6d1cd905b` | `PARTIAL` |
| bzip2 1.0.8 | [bzip2-1.0.8.tar.gz](https://sourceware.org/pub/bzip2/bzip2-1.0.8.tar.gz) | `ab5a03176ee106d3f0fa90e381da478ddae405918153cca248e682cd0c4a2269` | bzip2 license | MacPorts receipt/Portfile | `b57f67715c0d0a4b2f544b0bf36d9c41e6a6f497a368bee1c9d01c8ceb5e3bff` | `PARTIAL` |
| zlib 1.3.2 | [zlib-1.3.2.tar.gz](https://www.zlib.net/zlib-1.3.2.tar.gz) | retained Portfile expects `d7a0654783a4da529d1bb793b7ad9c3318020af77667bcae35f95d0e42a792f3` | `Zlib` | MacPorts receipt; current upstream URL yields a regenerated different hash, so equivalence is not claimed | `9b5d38572e4d584ec4354b8721f77bcff30ac6f70ad5385e226d8cbb0d13a5f7` | `PARTIAL` |
| MacPorts libc++ / libc++abi 11.1.0 | no independent distfile; receipt copies its clang-11 input | not available | `Apache-2.0 WITH LLVM-exception` plus retained legacy notices | MacPorts receipt; historical clang input and build flags incomplete | libc++ `9b883e2304d73fb4c2ae9ee8a4ff934b7f5f9c676719b461122b97515e72347c`; libc++abi `9f7d551daa6b311e6528fb0ca6d466e9384cad8da983fbd1313ec472bfea51bb` | `PARTIAL` |

## Audited Release output inventory

The stable native third-party hashes below freeze the audited inputs reused by
0.5.0 (Build 99). Some unchanged inputs were first audited for the Build 63 candidate.
Code signing or rebuilding can change output hashes even when source is
unchanged. Therefore `package-app.sh` generates the authoritative hash of the
27 stable nested Mach-O objects and the rebuilt APK inside each actual App at
`Contents/Resources/Legal/Compliance/BUILD_OUTPUT_SHA256.txt`; bundle
verification recalculates every entry. The outer App signature is authoritative
for `Contents/MacOS/OKVideoMac`, whose embedded signature is rewritten after
the legal resource is sealed. Static values here are evidence, not a substitute
for that per-package manifest.

The same package also generates SPDX 2.3 and CycloneDX 1.6 SBOMs. The macOS
documents contain exactly 28 Mach-O components and the Android documents
contain the APK aggregate, exact FongMi source component and 87 locked Maven
modules. `verify_sbom.py` enforces exact inventory/lock equality; the final
source-release manifest records each SBOM SHA-256.

| App-relative output | SHA-256 |
| --- | --- |
| `Contents/MacOS/OKVideoMac` | verified by the final outer App signature; an App-internal self-hash cannot remain stable across that signing step |
| `Contents/Resources/NodeRuntime/node` | `60df37880c72f74c789d0857c2729f42256e7ae944c9a5055162da97e54adc3e` |
| `Contents/Resources/AndroidDexBridge-release.apk` | generated and verified per package in `BUILD_OUTPUT_SHA256.txt` |
| `Frameworks/libOKMPVBridge.dylib` | `068d6fe69b4f51ddada58499754d177c2d7b0d51c2bf73e23491aa77a8edc350` |
| `Frameworks/libOKQuickJS.dylib` | `e1dc2d48b5972e8e6d346e5f6e20da9d5e3d701163450c73f06a2d58a2141414` |
| `Frameworks/libmpv.dylib` | `6f2f7f53ed3ec1309ae6cef869dd8a83bb4bfff09ad9d61a87f6e2f5778b0cd4` |
| `Frameworks/libavcodec.61.dylib` | `c2cd9e5d9993a1ce6e2d6361d0dab55c12d64c48a5ec51e24e4abcfb8cc616a1` |
| `Frameworks/libavfilter.10.dylib` | `47fc8696d302d84a085a91e21dd83414dd36afe6d150b775e36a279cc367a0b5` |
| `Frameworks/libavformat.61.dylib` | `75f3aa0d50d57688618849ed2814ff4eaeaab3870f0d232004ff63d5b282bcf0` |
| `Frameworks/libavutil.59.dylib` | `a0efd1ba3e43b135b802d6af01a1a26aa66801c6ff1ff868abbb288c82c69331` |
| `Frameworks/libswresample.5.dylib` | `0fe4c643bf83444da3f6024cbfa057c6643a968b766dddf726459ac0ce907736` |
| `Frameworks/libswscale.8.dylib` | `3977f92265d0262f52a4181e673018a96b953f3231bc63facdb1fdbad50af686` |
| `Frameworks/libass.9.dylib` | `edc1b46c29e05f2a4d73c51a8e44ce9fd014d25f52fff7ad9e3c5e1af32151c7` |
| `Frameworks/libbrotlicommon.1.dylib` | `86a2a571055f648ded77205c89fb56982cf5c4c199466e7f75c8c2216bd5d02d` |
| `Frameworks/libbrotlidec.1.dylib` | `f000b6403215d7f37664c4eeb3c5085d64034d7557118c7ed61bdc54040b3e96` |
| `Frameworks/libbz2.1.0.dylib` | `b57f67715c0d0a4b2f544b0bf36d9c41e6a6f497a368bee1c9d01c8ceb5e3bff` |
| `Frameworks/libc++.1.0.dylib` | `9b883e2304d73fb4c2ae9ee8a4ff934b7f5f9c676719b461122b97515e72347c` |
| `Frameworks/libc++abi.1.dylib` | `9f7d551daa6b311e6528fb0ca6d466e9384cad8da983fbd1313ec472bfea51bb` |
| `Frameworks/libfreetype.6.dylib` | `0aeb6b32083af5905fa455c1bb4dcfdbb4e875474cdafdcc96149a01f6f03150` |
| `Frameworks/libfribidi.0.dylib` | `2c2ceea3c6f13a147a90995c42d9c8cc92b6ea5a42aa7377771e8633d2981a78` |
| `Frameworks/libharfbuzz.0.dylib` | `9bf8008c39c3cb90b4aeb27862dbd9ed443ac504121084066c2a5f025611fefc` |
| `Frameworks/libiconv.2.dylib` | `de69743a272ffcf7cf76b9b59cfbac1e87020f89219c5ea07771deb6d1cd905b` |
| `Frameworks/libjpeg.8.dylib` | `374bd2ae25393b6d165fd04f98b48a1930b37fdb1b2c8cefeb12b42141ecd64c` |
| `Frameworks/liblcms2.2.dylib` | `7ca8711d2681113e5e442729b478ce2191014d6b7efcaa1b02d234b1d6acccd7` |
| `Frameworks/liblzma.5.dylib` | `399ead9f2d64ec9ad05d852c8a95d85608d730073684d6952f758d107074a773` |
| `Frameworks/libplacebo.360.dylib` | `c0d56e040b62f565c397e833d4cdf63ed3ee0204e1a3795e65df2ece501bd95d` |
| `Frameworks/libpng16.16.dylib` | `7dbba253a553534b35d38ff9120b7d2703ac2f4fbfa216f4cbc199e461c1b35a` |
| `Frameworks/libsqlite3.dylib` | `0cc34425224eb33e959bd2ff2b6d67e19f3e4208c5b79c4de27115dff2dd272c` |
| `Frameworks/libz.1.dylib` | `9b5d38572e4d584ec4354b8721f77bcff30ac6f70ad5385e226d8cbb0d13a5f7` |

## Remediated inputs and assets

| Component | Evidence | Status / required action |
| --- | --- | --- |
| `xpp3:xpp3:1.1.3.3` | exact POM/JAR contain no license or SCM metadata; no matching source JAR; binary SHA `b14a6716def83417542d5515677d947fecd2597c125f2c82aa9be8792f66b5ee`; original-author repository confirms the license family but not exact source | `REPLACEMENT REQUIRED`; excluded from the Phase 2 APK, so no unresolved artifact is distributed |
| App icon asset set | Final runtime input: ten red/coral PNGs in `OKVideoMac/macOS/OKVideoMac/Resources/Assets.xcassets/AppIcon.appiconset/`, finalized by `ae7fa3d` and retained in release commit `b0b6fec`. Historical intermediate evidence: ImageGen source SHA `147b37b7eada29efb420b5b78836d9d8c695cb9d17e1718f12fc39551063c835` and blue 1024px master SHA `1b795d144d5d0244b109e97380d91af7dc48965e0a8eb3993c85968dd6becd3d`; neither is a runtime input. See `Docs/APP_ICON_PROVENANCE.md`. | Release identity: `VERIFIED`. Direct creative/source provenance of the final red artwork: `UNRESOLVED`; repository evidence does not establish a direct blue-to-red derivation. |

### App icon rights investigation

The superseded asset catalog first appears in Git commit
`f084439a7ccdf2b3b931a60851a44d3883be7c3e` (`chore: establish 0.3.20
rollback baseline`), authored as
`Codex <codex@openai.com>` on 2026-08-08. PNG file timestamps predate that
commit, but timestamps and commit authorship do not establish copyright. A
repository and history search found no original SVG, PSD, Sketch, Figma, or
other design source, no AI-generation record, and no commission, purchase, or
license document. Its only defensible result remains `UNRESOLVED`.

Commit `8e05a3d` replaced that baseline with the documented blue ImageGen
intermediate and retained its no-input generation record, prompt, hashes, and
1024px master. Commit `ae7fa3d` subsequently replaced only the ten AppIcon
catalog PNGs with the final red runtime artwork; it did not replace or establish
a derivation from the retained blue source or master. The final red catalog's
identity and release path are `VERIFIED` by `ae7fa3d`, the Build 63 candidate
commit `b0b6fec`, and their unchanged presence through the Build 65 mainline. Its
direct creative/source provenance remains `UNRESOLVED` from repository
evidence. See
`Docs/APP_ICON_PROVENANCE.md` for the detailed boundary.
