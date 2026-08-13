# OKVideoMac juniversalchardet Dependency Elimination Feasibility Audit

Date: 2026-08-13

Release: `OKVideoMac 0.3.41 (62)`

Final decision: `KEEP_FOR_COMPATIBILITY`

Compliance state: `DOCUMENTED LICENSE INTERPRETATION RISK` remains open.

This is an engineering compatibility audit, not a new license interpretation.

## Executive Summary

`com.googlecode.juniversalchardet:juniversalchardet:1.0.3` was introduced by
FongMi in 2024 to normalize non-UTF-8 local subtitles. FongMi removed the only
tracked call site three months later but retained the direct `api` dependency.
OKVideoMac copied that dependency declaration with the exact FongMi catvod
source. Current tracked OKVideoMac, AndroidDexBridge, catvod, FongMi, JavaScript,
and DEX code has no caller.

That evidence is not enough to remove the library. The two current cached
Spider JARs and two retained Phase 3 snapshots are protected packages: their
small visible DEX loaders invoke native/runtime-decrypted implementations from
large `.guard` payloads. All four are `UNINSPECTABLE_DYNAMIC_CODE`. The bridge
constructs `DexClassLoader(..., parent = context.getClassLoader())`, so the
host's exported package is visible to those implementations and to arbitrary
configuration-selected external Spider packages.

The actual Android bridge has nine byte-to-String call sites and no heuristic
detector use. All 262 retained real text artifacts are strict UTF-8. A
metadata-first `TextEncodingResolver` prototype resolved all seven
project-shaped fixtures without a heuristic. This shows that tracked business
code does not need juniversalchardet; it does not show that the open Spider
host classpath can remove it.

ICU4J 78.3 is technically available as a standalone Maven dependency and is
more accurate on several long East Asian fixtures, but it is not an Android
framework API and is a poor product trade: exact D8 output was 2,949,564 bytes
versus 168,956 for juniversalchardet, with 1,776 versus 62 classes and 15,806
versus 306 method IDs. Its Maven artifact has no transitive dependencies, but
it adds the Unicode-3.0 license plus bundled third-party notices. The
comparison benchmark was approximately 6.4 times slower on this workstation.
Introducing it would not solve binary compatibility for existing
`org.mozilla.universalchardet.*` consumers.

The exact old JAR exposes 61 public types and 354 public members. Because the
protected Spider implementations are uninspectable, the needed subset cannot
be established. A small common-API shim is therefore not proven compatible;
reconstructing the whole surface is not a simple clean-room shim and is marked
`LEGAL/COMPATIBILITY REVIEW REQUIRED`.

Neither removal Path A nor Path B was met. No formal dependency-removal
prototype or modified-Spider dynamic run was authorized by the evidence gate.
The verified current Release app was not replaced.

## Baseline

The primary worktree was inspected read-only before isolation:

- primary commit: `557c3c90051b9867e84c4de78bddce1bd62be93c`;
- primary branch: `codex/mpv-teardown-ab-experiment`;
- primary status: clean;
- Phase 2 worktree: `/private/tmp/okvideomac-compliance-phase2`, commit
  `1552e51df9bc42aa7832e0ed3816e4dc96d7b88f`;
- Phase 3/MPL worktree: `/private/tmp/okvideomac-mpl-gpl-p0`, commit
  `70120436d477e205fafcebc17974049e5c375d09`.

The new isolated worktree is
`/private/tmp/okvideomac-juniversalchardet-elimination` on branch
`codex/juniversalchardet-elimination-audit`, based on Phase 4's descendant
commit `20a7acaaff1854aa686b6cdfc76ca254651fa5dd` so that Phase 2/3 exact evidence
and current packaging scripts are present.

Release evidence recorded before work:

| Item | Baseline value |
|---|---|
| Desktop APK SHA-256 | `59ee18fa061bad09bf60b8836e3be141878b7b0167987af6228386173072a845` |
| Desktop APK bytes | 8,054,609 |
| `classes.dex` SHA-256 | `a317f2f8af8ce79e5f6a02efc0bf2f2f9e126d50686bcf597fcff98ac303e9ea` |
| `classes2.dex` SHA-256 | `332360b30f2dd6393493b0bda7860d9769f901dfb4177f2fd8b816b215f4f0c7` |
| dependency lock SHA-256 | `8d78cccdaede67020bf060fa8e5488e99c7c7a7fb6c5ccbdd91f7a9bd796e163` |
| Android SBOM SHA-256 | `17341c5dcac9cf960a07594921aa7e491403f794034ae891669afabbd2b800f4` |
| SBOM component | `pkg:maven/com.googlecode.juniversalchardet/juniversalchardet@1.0.3`, `MPL-1.1` |

## Dependency Origin

The local `:catvod` module directly declares the artifact as `api`. The
application uses `implementation project(":catvod")`, which puts the artifact
on the application's locked `releaseRuntimeClasspath`. It is not transitive
from another Maven component.

The historical introduction and removal commits are proven in
[JUNIVERSALCHARDET_DEPENDENCY_ORIGIN.md](android/JUNIVERSALCHARDET_DEPENDENCY_ORIGIN.md).
In short: upstream commit `4b545153` added the detector for non-UTF-8 local
subtitles; upstream commit `6e737cd4` deleted that feature and its call while
leaving the Gradle declaration. Current FongMi source therefore treats it as
an exported but unused dependency.

## Current Repository References

Text, public-class-name, archive-string, and compiled DEX scans covered Swift,
Java, Gradle, JavaScript, QuickJS resources, assets, copied catvod, local
AndroidDexBridge, and the exact FongMi tree.

Result outside audit documentation/harness:

- direct import: 0;
- static type/method/field reference: 0;
- reflection string: 0;
- class-name string: 0;
- resource reference: 0;
- external APK DEX owner referencing the package: 0.

The committed comparison harness imports both libraries by design and is not
part of an Android source set or Release build.

## APK / DEX Presence

Phase 3 and the reproduced retained-baseline build agree:

- all 62 exact JAR classes remain in `classes2.dex`;
- `classes.dex` has no package reference;
- `classes2.dex` has 62 owning sections referencing the package, all owned by
  the package itself;
- no external APK class owns a descriptor, invocation, field, or string
  reference to it;
- `minifyEnabled false` explains full-library retention.

The isolated clean retained-baseline APK had a different signed ZIP-container
hash (`d90cdce7...`) but exactly matched the Desktop APK in size and both DEX
hashes. This is reproducible binary evidence that the current graph remains
unchanged.

## Spider Ecosystem Census

Full inventory: [SPIDER_CHARSET_COMPATIBILITY_CENSUS.md](android/SPIDER_CHARSET_COMPATIBILITY_CENSUS.md).

| Metric | Count |
|---|---:|
| logical Spider JAR/DEX artifacts | 4 |
| fully inspectable | 0 |
| confirmed direct references | 0 |
| confirmed reflection references | 0 |
| confirmed `NO_REFERENCE` artifacts | 0 |
| `UNINSPECTABLE_DYNAMIC_CODE` | 4 |

Two artifacts are current cached snapshots. Two are the corresponding Phase 3
snapshots. They represent two visible loader-DEX families, but all four
artifact hashes were scanned and counted because their protected payloads
differ by snapshot.

## Dynamic / Protected Spider Limits

The visible DEX layers contain no juniversalchardet reference. Each artifact
also contains native guard code and an encrypted `.guard` payload, and logs
show native/runtime loading. The effective code cannot be exhaustively
disassembled from the available artifact.

The bridge's parent class loader is the APK class loader. Consequently a
protected Spider can resolve host dependencies even when its loader DEX has no
reference. External Spider compatibility is open-ended and cannot be proven
closed from this corpus.

## Charset Resolution Map

Full map: [CHARSET_RESOLUTION_MAP.md](android/CHARSET_RESOLUTION_MAP.md).

The tracked Android path has nine byte-to-String sites:

- six use a charset explicitly at the Java call site;
- two use OkHttp's HTTP `Content-Type` charset with UTF-8 fallback;
- one shell stdout path relies on Android's UTF-8 platform default;
- zero use heuristic detection.

Binary downloads/proxies remain bytes. Spider return data reaches the bridge
as Java `String`, so protected Spider internal conversions are outside this
map.

## Current Need for Heuristic Detection

Among 262 retained real text artifacts, 262 (100.0%) are strict UTF-8 and zero
require a heuristic. An additional `.json`-suffixed cache entry is a JPEG and
was correctly excluded by magic bytes.

In seven project-shaped resolver fixtures:

- explicit metadata/BOM/declaration: 6/7 = 85.7%;
- strict UTF-8 after metadata: 1/7 = 14.3%;
- heuristic fallback: 0/7 = 0.0%.

These percentages characterize retained bytes and the prototype fixture set,
not unknown future Spider traffic.

## ICU4J Evaluation

Candidate: `com.ibm.icu:icu4j:78.3`, exact binary SHA-256
`e962c1758d9659ea1e1fbab99c58683f654d304e1126ace19aaabfe39e0edb25`.

It is a standalone ICU4J dependency. Android exposes named converters through
`java.nio.charset` and some `android.icu` APIs, but its public
`android.icu.text` package does not expose `CharsetDetector`; there is no
public system-level equivalent detector. Android's public `Charset` API maps
known encodings and documents UTF-8 as the platform default.

The exact POM declares `Unicode-3.0`. The exact license contains the Unicode
License v3 plus bundled third-party notices. Source is available as the exact
2,645,358-byte sources JAR, SHA-256
`b8458be1c296aec6c52ea8f195f27e833c5d6030fa15a4b361a0e83030c3c3fe`.
The exact POM declares no dependencies. `CharsetDetector` is Java 11 bytecode;
D8 36.0.0 accepted the whole artifact with `--min-api 24`, providing a build
compatibility check for this project's minSdk, not a full device regression.

### Functional fixture comparison

| Fixture | Expected | juniversalchardet 1.0.3 | ICU4J 78.3 (confidence) |
|---|---|---|---|
| UTF-8 | UTF-8 | UTF-8 | UTF-8 (100) |
| BOM UTF-8 | UTF-8 | UTF-8 | UTF-8 (100) |
| BOM UTF-16LE | UTF-16LE | UTF-16LE | UTF-16LE (100) |
| BOM UTF-16BE | UTF-16BE | UTF-16BE | UTF-16BE (100) |
| long GB18030 Chinese | GB18030 | KOI8-R | GB18030 (100) |
| long Big5 traditional Chinese | Big5 | null | Big5 (91) |
| long Shift-JIS Japanese | Shift_JIS | SHIFT_JIS | Shift_JIS (100) |
| long EUC-JP Japanese | EUC-JP | EUC-JP | EUC-JP (100) |
| long EUC-KR Korean | EUC-KR | EUC-KR | EUC-KR (100) |
| ISO-8859-1 Western text | ISO-8859-1 | WINDOWS-1252 | ISO-8859-1 (39) |
| ASCII-only short text | ASCII/UTF-8 | null | ISO-8859-9 (35) |
| short GB18030 | GB18030 | KOI8-R | Big5 (10) |
| mixed-language UTF-8 | UTF-8 | UTF-8 | UTF-8 (100) |
| malformed bytes | invalid | WINDOWS-1252 | UTF-16LE (20) |

Both detectors demonstrate why heuristic output must be low-priority and
confidence/failure must not be silently swallowed. ICU4J improves long Chinese
fixtures but remains unreliable on short and malformed inputs.

### Size, method, performance, and memory

| Metric | juniversalchardet 1.0.3 | ICU4J 78.3 |
|---|---:|---:|
| Maven JAR bytes | 220,813 | 15,156,073 |
| exact whole-artifact D8 bytes | 168,956 | 2,949,564 |
| D8 class defs | 62 | 1,776 |
| D8 method IDs | 306 | 15,806 |
| gzip estimate of DEX | 76,116 | 1,377,842 |
| benchmark mean, 28,000 fixture detections | 34.9 µs | 222.0 µs |

The benchmark is a workstation Java microbenchmark, not Android startup or
device memory telemetry. Separate JVM native-memory summaries were dominated
by VM reservation/GC and did not show a meaningful detector-specific committed
memory delta; Android memory impact remains unmeasured. Because ICU was not
integrated, exact signed APK increase is not claimed. The whole-artifact D8
comparison indicates approximately +1.30 MB compressed DEX versus the current
detector, before packaging interactions.

Conclusion: ICU4J is usable but not worth adding here. It is much larger,
slower in this fixture benchmark, adds a new notice chain, and does not retain
the old package/API contract.

## No-Detector Architecture

The proposed `TextEncodingResolver` is metadata-first:

1. BOM;
2. supplied charset;
3. HTTP `Content-Type` charset;
4. XML encoding declaration;
5. HTML meta charset;
6. strict UTF-8;
7. optional `EncodingDetector` fallback;
8. deterministic media-specific fallback or surfaced failure.

Tracked business code can use this design without a detector today. It should
be adopted only when an actual text-resolution feature is requested; adding it
now would not remove the Spider host-compatibility reason for retaining the
old package.

## Compatibility Shim Evaluation

The most common API is:

- `UniversalDetector(CharsetListener)`;
- `handleData(byte[], int, int)`, `dataEnd()`, `reset()`, `isDone()`;
- `getDetectedCharset()`, listener getter/setter;
- `CharsetListener.report(String)`;
- charset constants in `Constants`.

But this is not the full public surface. Exact `javap -public` analysis found
61 public types and 354 public members across detector, prober, context,
distribution, sequence, and state-machine packages. Exception and streaming
callback behavior is part of compatibility as well.

Because every current Spider artifact is protected, no evidence defines which
subset the effective code uses. A small shim cannot be called complete. A
whole-surface reimplementation is not a simple API bridge and raises both
semantic and clean-room review requirements.

Result: compatibility shim is not currently feasible under the audit's
evidence standard. `LEGAL/COMPATIBILITY REVIEW REQUIRED` before any attempt to
reconstruct more than the simple top-level API.

## Prototype Changes

The only prototype is the standalone
`Tools/SourceAudit/CharsetDetectorComparison.java` harness. It is outside all
Gradle source sets and is not in the Release APK.

The Phase I entry gate failed:

- Path A failed because the corpus is not inspectable and cannot establish
  zero Spider dependencies;
- Path B failed because actual consumers/API subset are unknown and no
  complete shim was established.

Therefore the formal removal prototype (dependency edit, lock regeneration,
removed-package APK, SBOM rewrite) was not performed. This is the required
effect of “No evidence → No removal,” not a missing implementation step.

## Functional Regression

No runtime dependency or behavior was changed. The retained-baseline Android
Release built cleanly and reproduced both baseline DEX hashes. Gradle lint
printed pre-existing Kotlin 2.2 metadata warnings but completed successfully.

Historical Phase 3 dynamic artifacts cover 46 site directories with available
results for `home`, `homeVod`, `search`, `category`, `detail`, `play`, `action`,
`proxyLocal` probes, and `destroy` as supported by each site. Those runs prove
baseline behavior only. They cannot prove behavior after removal because the
removal gate was not met.

Accordingly “current Spider regression after deletion” and exact
search/detail/player/proxy equivalence after deletion are `NOT RUN — GATE NOT
MET`, not `PASS`.

## Dynamic DexClassLoader Regression

Baseline logs confirm dynamic native/runtime code loading and contain no
`ClassNotFoundException`, `NoClassDefFoundError`, `LinkageError`, or
juniversalchardet error. They also contain unrelated protected-Spider runtime
errors, so the baseline corpus is not a perfect all-site functional pass.

No removed-package dynamic build existed; therefore absence of linkage errors
after deletion cannot be claimed. If a future closed corpus or inspectable
payload permits a removal prototype, the required test order is startup,
configuration, package init, loader creation, home/category/search/detail/
player/proxy as supported, switching, and repeated unload/reload while
collecting full linkage logs.

## Performance / APK Size

Current retained APK: 8,054,609 bytes. Isolated rebuild: also 8,054,609 bytes.
Both DEX files are byte-identical to the Desktop baseline.

No exact removal APK size or startup delta is reported because no removal
prototype was permitted. The current library's isolated compressed-Dex proxy
is 76,116 bytes, but multidex repartitioning and signing make that unsuitable
as an exact APK delta. Startup and Spider initialization are unchanged because
the runtime graph is unchanged.

ICU's whole-artifact D8/gzip proxy is 1,377,842 bytes, approximately 1.30 MB
larger than the current detector proxy. Its detection benchmark was about 6.4x
slower. Android device memory was not measured.

## SBOM Impact

There is no distribution change. The current Android SBOM correctly retains
juniversalchardet 1.0.3 with the exact POM hash and `MPL-1.1`. ICU4J is an
audit-only `/private/tmp` artifact and must not be added to the SBOM.

No SBOM, dependency lock, source release, notices, or license payload was
changed. No new license-sensitive distributed dependency was created.

## License / Compliance Impact

The final binary still contains all 62 old classes; consequently notices and
historical Phase 3 materials remain correct and must not be removed.

`DOCUMENTED LICENSE INTERPRETATION RISK` cannot be closed. ICU's primary
license is Unicode-3.0 and it contains additional third-party notices, but it
was not distributed. The audit makes no new conclusion about the old license.

## Decision

`KEEP_FOR_COMPATIBILITY`

juniversalchardet is retained intentionally as part of the open dynamic Spider
host compatibility surface. No current known Spider in the inspected visible
corpus requires it, but complete compatibility cannot be proven for arbitrary
externally supplied Spider JARs. In addition, every current/retained Spider
artifact inspected here contains uninspectable dynamic code, so the actual
current requirement is unknown rather than confirmed absent.

Compatibility outranks architecture simplification and license-maintenance
reduction. Removing approximately a small compressed-Dex component does not
justify a possible runtime linkage break in protected or external Spiders.

## Remaining Risks

- Protected current Spider code may use any part of the 61-public-type surface.
- A future external Spider may rely on the historical FongMi host classpath.
- Keeping the artifact retains the documented license-interpretation risk.
- Current tracked text paths have inconsistent failure behavior and one
  implicit default-charset call, though neither creates current detector use.
- Historical baseline regression artifacts include unrelated Spider failures;
  they are not a claim that every site is currently healthy.

Evidence that could reopen removal: a policy defining a closed supported
Spider set plus inspectable/decrypted legal artifacts for every supported
package, or provider attestations/build manifests proving no old API linkage.

## Required Answers

1. `:catvod` directly introduces 1.0.3 as `api`; `:app` inherits it through
   `implementation project(":catvod")`.
2. FongMi commit `4b545153` introduced it for non-UTF-8 local subtitles.
3. No current visible production source call exists.
4. Yes. The current APK contains all 62 classes in `classes2.dex`.
5. Four logical JAR/DEX artifacts were scanned: two current and two retained
   Phase 3 snapshots, representing two visible loader-DEX families.
6. Zero confirmed direct references.
7. Zero confirmed reflection references.
8. Four artifacts contain uninspectable dynamic code.
9. Visible code does not need it; actual protected current Spider need is
   unknown.
10. No. Arbitrary external Spider compatibility is open-ended.
11. The tracked Android bridge/catvod path has nine byte-to-String call sites.
12. Eight are resolved by an explicit call-site charset or HTTP charset rule;
    one relies on Android's documented UTF-8 default.
13. Seven paths resolve as UTF-8 directly or by HTTP's UTF-8 fallback; the
    header-line path is US-ASCII and shell stdout is implicit Android UTF-8.
14. Zero tracked paths currently require a heuristic detector.
15. No public Android system API equivalent to `CharsetDetector` was found.
16. ICU4J 78.3 is technically usable as a standalone Maven dependency.
17. Its exact POM license is `Unicode-3.0`; its license file includes bundled
    third-party notices.
18. No exact integrated APK delta was produced. Whole-artifact D8/gzip
    estimates +1.30 MB compressed DEX versus the current detector.
19. No. The exact ICU4J POM declares no transitive dependencies.
20. ICU won long GB18030/Big5 fixtures; both handled Unicode/Japanese/Korean
    long fixtures, while both produced unreliable short/malformed guesses.
21. No. Its size, performance, notice, and API-compatibility costs outweigh
    its unused tracked-code benefit.
22. Tracked business code can use no detector; the Spider host compatibility
    surface cannot currently eliminate the old detector package.
23. Not with current evidence. The needed API subset is unknown; full-surface
    reconstruction requires legal/compatibility review.
24. Not tested after deletion because the removal-prototype gate failed. The
    retained baseline clean Release build passed.
25. No; no deletion build was allowed. All 62 classes remain.
26. Not run after deletion. Historical baseline results exist but include
    unrelated source failures.
27. No such linkage errors occur in retained baseline logs; post-deletion is
    not testable without an authorized prototype.
28. No post-deletion equivalence claim is made. Historical supported-method
    baseline artifacts remain available.
29. Retained APK size is unchanged at 8,054,609 bytes; removal delta is not
    claimed.
30. Runtime performance is unchanged. The audit harness measured ICU about
    6.4x slower than 1.0.3 on its workstation fixture loop.
31. Yes. Because distribution is unchanged, the current SBOM correctly still
    lists 1.0.3.
32. No new distributed dependency was added.
33. Final decision: `KEEP_FOR_COMPATIBILITY`.
34. No. `DOCUMENTED LICENSE INTERPRETATION RISK` remains open.
35. No shipped compatibility is changed; retention avoids an unbounded risk.
36. No macOS runtime code was changed.
37. No player code or behavior was changed.
38. Audit commits: `cd72101` (origin/census/map/harness) and the final report
    commit containing this document.
39. Rollback: no runtime rollback is needed. Revert the final report commit,
    then `cd72101`; remove the isolated worktree/branch only after preserving
    desired audit records. Desktop App is unchanged.
40. Primary, Phase 2, Phase 3, Phase 4, and this audit worktree were checked;
    final clean status is recorded after the report commit below.

## Rollback

There is no dependency, lock, APK, SBOM, app, or Desktop rollback. For audit
documents only, revert commits newest-first:

1. the final `Docs/JUNIVERSALCHARDET_ELIMINATION_AUDIT.md` commit;
2. `cd72101`.

Then remove `/private/tmp/okvideomac-juniversalchardet-elimination` and branch
`codex/juniversalchardet-elimination-audit` if the audit itself is no longer
wanted. Do not delete Phase 3 historical evidence.

## Sources

Primary external sources used for unstable/current candidate facts:

- [Maven Central: ICU4J 78.3](https://central.sonatype.com/artifact/com.ibm.icu/icu4j/78.3)
- [ICU charset-detection guide](https://unicode-org.github.io/icu/userguide/conversion/detection)
- [ICU4J `CharsetDetector` API](https://unicode-org.github.io/icu-docs/apidoc/dev/icu4j/com/ibm/icu/text/CharsetDetector.html)
- [Android `java.nio.charset.Charset`](https://developer.android.com/reference/java/nio/charset/Charset)
- [Android `android.icu.text` package](https://developer.android.com/reference/android/icu/text/package-summary)

Exact binary/source/POM/license facts were additionally verified from the
downloaded official Maven/Unicode artifacts and are identified by hash above.
