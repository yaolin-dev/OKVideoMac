# AndroidDexBridge Third-Party Notices

This inventory describes the runtime graph compiled into
`AndroidDexBridge-release.apk`. It was re-resolved with Gradle 8.9 using
`:app:dependencies --configuration releaseRuntimeClasspath` on 2026-08-13.
Constraints and evicted versions are not listed as shipped versions.

License texts referenced below are distributed in the repository-level
`THIRD_PARTY_LICENSES/` directory and in the App's
`Contents/Resources/Legal/THIRD_PARTY_LICENSES/` copy.

## Copied and modified source

| Component | Exact source | License | Use / modification | Source location |
| --- | --- | --- | --- | --- |
| FongMi/TV `catvod` | commit `5fdff00a602dc56e8ba756174daef20edab024f2`, original `catvod/src/main` | `GPL-3.0-only` | Directly copied into the APK; `Proxy.java` default port changed `-1` → `9978` with a local comment | `Helpers/AndroidDexBridge/catvod`; see `FONGMI_CATVOD_CHANGES.md` |

## Resolved Maven artifacts

| Components / exact resolved versions | License | Copyright / upstream | License file / status |
| --- | --- | --- | --- |
| AndroidX: `annotation:1.9.1`, `annotation-jvm:1.9.1`, `annotation-experimental:1.1.0`, `startup-runtime:1.2.0`, `tracing:1.0.0`, `preference:1.2.1`, `appcompat:1.1.0`, `appcompat-resources:1.1.0`, `core:1.8.0`, `core-ktx:1.2.0`, `collection:1.1.0`, `collection-ktx:1.1.0`, `concurrent-futures:1.0.0`, `arch.core:core-common:2.1.0`, `arch.core:core-runtime:2.1.0`, `lifecycle-runtime:2.5.1`, `lifecycle-runtime-ktx:2.5.1`, `lifecycle-common:2.5.1`, `lifecycle-livedata:2.0.0`, `lifecycle-livedata-core:2.5.1`, `lifecycle-livedata-core-ktx:2.3.1`, `lifecycle-viewmodel:2.5.1`, `lifecycle-viewmodel-ktx:2.5.1`, `lifecycle-viewmodel-savedstate:2.5.1`, `versionedparcelable:1.1.1`, `cursoradapter:1.0.0`, `fragment:1.3.6`, `fragment-ktx:1.3.6`, `viewpager:1.0.0`, `customview:1.1.0`, `loader:1.0.0`, `activity:1.5.1`, `activity-ktx:1.5.1`, `savedstate:1.2.0`, `savedstate-ktx:1.2.0`, `vectordrawable:1.1.0`, `vectordrawable-animated:1.1.0`, `interpolator:1.0.0`, `drawerlayout:1.0.0`, `recyclerview:1.0.0`, `legacy-support-core-ui:1.0.0`, `legacy-support-core-utils:1.0.0`, `documentfile:1.0.0`, `localbroadcastmanager:1.0.0`, `print:1.0.0`, `coordinatorlayout:1.0.0`, `slidingpanelayout:1.2.0`, `window:1.0.0`, `transition:1.4.1`, `swiperefreshlayout:1.0.0`, `asynclayoutinflater:1.0.0` | `Apache-2.0` | Android Open Source Project contributors | `Apache-2.0.txt` |
| Kotlin `kotlin-stdlib:2.2.0`, `kotlin-stdlib-common:2.2.0`, `kotlin-stdlib-jdk7:1.8.0`, `kotlin-stdlib-jdk8:1.8.0`; Kotlinx Coroutines `core:1.6.1`, `core-jvm:1.6.1`, `android:1.6.1`; JetBrains `annotations:13.0` | `Apache-2.0` | JetBrains and Kotlin contributors | `Apache-2.0.txt` |
| `org.brotli:dec:0.1.2` | `MIT` | Google Brotli Authors | `Brotli-MIT.txt` |
| OkHttp `okhttp:5.1.0`, `okhttp-android:5.1.0`, `okhttp-dnsoverhttps:5.1.0`, `logging-interceptor:5.1.0`; Okio `okio:3.15.0`, `okio-jvm:3.15.0` | `Apache-2.0` | Square contributors | `Apache-2.0.txt` |
| Gson `2.13.1`; Error Prone annotations `2.38.0` | `Apache-2.0` | Google contributors | `Apache-2.0.txt` |
| Guava `33.4.8-android`, `failureaccess:1.0.3`, `listenablefuture:9999.0-empty-to-avoid-conflict-with-guava`; `jspecify:1.0.0`; J2ObjC annotations `3.0.0` | `Apache-2.0` | Google, JSpecify, and contributors | `Apache-2.0.txt` |
| `com.googlecode.juniversalchardet:juniversalchardet:1.0.3` | `MPL-1.1` | Mozilla universalchardet authors / Java port contributors | `juniversalchardet-MPL-1.1.txt`; covered-source obligation applies |
| `com.orhanobut:logger:2.2.0`; Android support annotations `27.1.0` | `Apache-2.0` | logger and Android contributors | `Apache-2.0.txt` |
| `com.github.thegrizzlylabs:sardine-android:0.9`; `org.simpleframework:simple-xml:2.7.1`; `stax:stax-api:1.0.1` | `Apache-2.0` | respective upstream authors | `Apache-2.0.txt` |
| `stax:stax:1.2.0` | `Apache-2.0` — **CONFIRMED** | Copyright 2004 BEA Systems | `stax-1.2.0-Apache-2.0.txt` |
| `com.hierynomus:smbj:0.14.0`; `com.hierynomus:asn-one:0.6.0` | `Apache-2.0` | Hierynomus and contributors | `Apache-2.0.txt` |
| `org.bouncycastle:bcprov-jdk18on:1.79` | Bouncy Castle license (`MIT`-style) | Legion of the Bouncy Castle Inc. | `Bouncy-Castle-MIT.txt` |
| `net.engio:mbassador:1.3.0` | `MIT` | mbassador authors | `mbassador-MIT.txt` |
| `org.slf4j:slf4j-api:2.0.9` | `MIT` | QOS.ch / SLF4J authors | `SLF4J-MIT.txt` |
| `com.google.zxing:core:3.5.3` | `Apache-2.0` | ZXing authors | `Apache-2.0.txt` |

The resolved runtime JARs were also scanned for component `NOTICE` entries.
No separate Apache NOTICE was present in this runtime set. The Gradle 8.9
distribution is build tooling rather than APK runtime content; its own complete
`LICENSE` and `NOTICE` are nevertheless retained as `Gradle-LICENSE.txt` and
`Gradle-NOTICE.txt`.

## Exact-version stax and removed xpp3 findings

### `stax:stax:1.2.0` — CONFIRMED

Maven Central's exact `stax-1.2.0-sources.jar` has SHA-256
`dfa08201c86e04eb93baf726af3495efcc30709f6a35ba902c44dfbc36266a11`.
It contains `ASF2.0.txt`, and its Java source headers state Copyright 2004 BEA
Systems and the Apache License 2.0. The resolved binary JAR SHA-256 is
`df6905a047b05e23bc91f03ba57ac2f87c1ddf83e048aa0e5bd13169d5ebf0d9`.
This proves the exact version's license and source family.

### `xpp3:xpp3:1.1.3.3` — excluded from the distributed APK

The resolved binary JAR SHA-256 is
`b14a6716def83417542d5515677d947fecd2597c125f2c82aa9be8792f66b5ee`.
Its exact Maven POM declares no license or source-control location, the JAR has
no license text, and Maven Central provides no matching source JAR. Licensing
statements for later `1.1.4c` code cannot prove the rights for `1.1.3.3` and
are deliberately not extrapolated. The original-author Git/CVS migration also
lacks an exact 1.1.3.3 source revision. Phase 2 therefore classifies this
artifact as `REPLACEMENT REQUIRED` and excludes it from `sardine-android:0.9`'s
transitive graph. Android supplies the XML Pull API/implementation; no new
artifact is introduced. See `Docs/XPP3_1_1_3_3_REMEDIATION.md` for compatibility
evidence. Current APK DEX inventory contains no `org/xmlpull/mxp1` class.
