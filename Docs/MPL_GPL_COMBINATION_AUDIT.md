# OKVideoMac MPL-1.1 / GPLv3 P0 Resolution Audit

Release: `OKVideoMac 0.3.41 (62)`

Audit date: 2026-08-13

Phase 2D baseline: `1552e51df9bc42aa7832e0ed3816e4dc96d7b88f`

Decision: `KEEP_AND_COUNSEL_REVIEW`

P0 disposition: `OPEN — COUNSEL REVIEW REQUIRED`

This is an engineering/compliance audit, not a legal opinion.

## Executive Summary

The exact sources JAR establishes that 57 of 58 Java files carry a historical
MPL-1.1/GPL-2.0-or-later/LGPL-2.1-or-later alternative notice. The remaining
file, `Constants.java`, has no file header. The POM declares only MPL-1.1.
These are **FACTS**; the legal effect and license election are **LEGAL REVIEW
REQUIRED**.

The exact Release APK is `PRESENT_IN_RELEASE_DEX`: all 62 classes produced by
the 58 source files are in `classes2.dex`. The GPL-3.0-only copied/modified
FongMi/catvod classes are in `classes.dex`. They are in one APK, one Android
application, and a shared class-loader graph, but not the same individual DEX
file. No tracked or current visible plugin code statically or reflectively
calls juniversalchardet.

Removal is nevertheless not classified `REMOVE_SAFE`. AndroidDexBridge is an
open-ended CatVod plugin host: it downloads configuration-selected JAR/DEX
packages and loads them with the APK class loader as parent. The FongMi exact
commit exports juniversalchardet as an `api` dependency. Protected or future
Spider payloads may therefore depend on the host-provided class surface even
when current visible DEX does not. Removing it could cause
`NoClassDefFoundError` or behavior loss in Java/Dex sources that are not
exhaustively enumerable.

No public Android platform charset-detection API with equivalent semantics was
found. `java.nio.charset` decodes a named encoding but does not choose among
unknown encodings. An application-owned compatibility shim or new detector
would change detection behavior and require broad real-Spider regression;
there is no actual current caller against which to establish equivalence.

Accordingly no runtime dependency, source, FongMi commit, catvod behavior,
player, UI, SBOM, lock, or APK was changed. The stable implementation is kept
and exact evidence is packaged for counsel.

## Exact Components

| Component | Exact identity | Relationship |
|---|---|---|
| juniversalchardet | `com.googlecode.juniversalchardet:juniversalchardet:1.0.3` | Direct `api` dependency of `:catvod`; locked Release runtime module |
| Binary JAR | SHA-256 `757bfe906193b8b651e79dc26cd67d6b55d0770a2cdfb0381591504f779d4a76` | D8 input; unmodified |
| Sources JAR | SHA-256 `3d1cb067f5cfe3cc19b77c837156f22368462af9acac5dd878e785966758fc27` | Exact file-level license evidence |
| POM | SHA-256 `7846399b35c7cd642a9b3a000c3e2d62d04eb37a4547b6933cc8b18bcc2f086b` | Declares MPL-1.1 only |
| FongMi catvod | commit `5fdff00a602dc56e8ba756174daef20edab024f2` | Copied/modified GPL-3.0-only source |
| AndroidDexBridge | local app + catvod source | APK host, RPC bridge, and dynamic Spider loader |
| Final Release APK | SHA-256 `59ee18fa061bad09bf60b8836e3be141878b7b0167987af6228386173072a845` | Gradle output embedded byte-for-byte in Desktop Release |

Exact Gradle origin, reproduced offline:

```text
com.googlecode.juniversalchardet:juniversalchardet:1.0.3
\--- project :catvod
     \--- releaseRuntimeClasspath
```

The lock entry is
`com.googlecode.juniversalchardet:juniversalchardet:1.0.3=releaseRuntimeClasspath`.
This is direct from the local `:catvod` project, not a transitive dependency of
another Maven module.

## Exact License Evidence

**FACT:** The exact 1.0.3 sources JAR contains 58 Java entries. Fifty-seven
headers state MPL 1.1, then state that the file may alternatively be used under
GPL 2.0 or later or LGPL 2.1 or later, and state that a recipient may use the
file under any one of MPL, GPL, or LGPL. No Apache, BSD, MIT, or other
alternative text was detected. No file contains Exhibit A.

**FACT:** `org/mozilla/universalchardet/Constants.java` begins directly with its
package declaration and has no file-level license or copyright header.

**FACT:** The Maven POM names only MPL-1.1. The complete sources JAR, rather
than a project page or another version, is the primary file evidence.

**LEGAL REVIEW REQUIRED:** Whether the alternative text can or should be
relied upon for the whole component, especially the headerless file and
MPL-only POM, is reserved for counsel.

## 58-file Header Audit

Machine-readable audit:
`Docs/compliance/juniversalchardet-1.0.3-file-license-audit.json`.

Human-readable per-file table:
`Docs/compliance/juniversalchardet-1.0.3-file-license-audit.md`.

Summary:

| Result | Count |
|---|---:|
| MPL-1.1/GPL-2.0-or-later/LGPL-2.1-or-later alternative header | 57 |
| Headerless | 1 |
| Exhibit A | 0 |
| 1998 Initial Developer copyright statement | 48 |
| 2001 Initial Developer copyright statement | 7 |
| 2005 Initial Developer copyright statement | 2 |

The 58 files are not all consistent.

## APK / DEX Inclusion

Conclusion: `PRESENT_IN_RELEASE_DEX`.

The final clean Release APK at the Gradle build output and packaged app is
byte-identical with SHA-256
`59ee18fa061bad09bf60b8836e3be141878b7b0167987af6228386173072a845`.
The pre-audit Phase 2 APK/container SHA-256 was
`5a46aec0bcdd9fc446cfeb1e3ddc3d97b1b2de7978ad88b8283d78fec2f20af7`;
both DEX payload hashes below remained byte-identical across the rebuild.

| DEX | SHA-256 | Role |
|---|---|---|
| `classes.dex` | `a317f2f8af8ce79e5f6a02efc0bf2f2f9e126d50686bcf597fcff98ac303e9ea` | 56 `com.github.catvod` classes and 19 bridge classes among 7,439 total |
| `classes2.dex` | `332360b30f2dd6393493b0bda7860d9769f901dfb4177f2fd8b816b215f4f0c7` | all 62 `org.mozilla.universalchardet` classes among 6,599 total |

The exact binary JAR has 62 class entries under the package and the sorted DEX
inventory has the same 62 entries. Thus the entire library, not a small used
subset, is included. `minifyEnabled false`; no R8/ProGuard shrinking occurs.
No relocation or shading was found. Complete class list:
`Docs/compliance/juniversalchardet-1.0.3-release-dex-classes.txt`.

## Runtime / Build Relationship

```text
OKVideoMac.app
└── AndroidDexBridge-release.apk
    ├── classes.dex
    │   ├── local AndroidDexBridge
    │   └── copied/modified FongMi catvod (GPL-3.0-only)
    ├── classes2.dex
    │   └── exact juniversalchardet 1.0.3 classes
    └── DexClassLoader(parent = APK class loader)
        └── downloaded configuration-selected Spider JAR/DEX
```

**FACT:** The GPL and covered code are in one APK and application/class-loader
graph, in separate DEX files. There is no static reference between tracked
GPL/bridge classes and juniversalchardet. There is no reflection string, IPC,
separate executable, dynamically downloaded copy of juniversalchardet, or
build-tool-only relationship.

**FACT:** The macOS program and APK run as different native processes across a
local/forwarded bridge connection. Inside the Android application, catvod,
bridge, dependencies, and external Spiders share the APK/plugin class-loader
relationship described above.

**LEGAL REVIEW REQUIRED:** No legal compatibility conclusion is inferred from
separate DEX placement, lack of current static calls, or the macOS/Android
process boundary.

## Actual Use of juniversalchardet

Repository production Java sources: zero imports, descriptors, calls, or
reflective names. AndroidDexBridge: zero direct calls. Local catvod: zero calls.
Exact FongMi commit archive: dependency declaration only, zero source calls.

The two MD5-pinned Java/Dex packages in the machine's saved configurations
were downloaded, hash-verified, and inspected. Their visible `classes.dex`
files contain no package reference. The active saved configuration uses Node
Spider paths instead of a Java/Dex JAR.

This establishes no current visible caller. It does not establish that every
protected, encrypted, runtime-generated, historical, or future FongMi-compatible
Spider has no dependency. The package provides charset detection across UTF-8,
UTF-16/32 BOMs, GB18030, Big5, EUC-JP/KR/TW, Shift-JIS, ISO-2022 variants,
several ISO-8859 families, and Cyrillic/Hebrew encodings. If an external Spider
calls it, the concrete function is unknown-byte charset detection before text
decoding.

## Replacement Analysis

| Candidate | License/distribution | Coverage and API | Risk | APK impact | Complexity |
|---|---|---|---|---|---|
| Remove dependency | No replacement | Works only if no external Spider expects any exported class | High/unknown compatibility risk because plugin set is open-ended | Decrease; exact delta not built because gate failed | Low code change, high validation burden |
| `java.nio.charset` / platform decoders | Android platform API; no packaged dependency | Decodes a named charset; does not detect an unknown charset | Not functionally equivalent | No material dependency growth | Low implementation, inadequate coverage |
| BOM + UTF-8 validity heuristic | Project code under project license | UTF BOM/UTF-8 only; cannot reliably distinguish GBK/GB18030/Big5/Shift-JIS/EUC/ISO families | Unacceptable for FongMi Chinese/Japanese compatibility if called | Small decrease | Medium, behavior loss |
| App-owned compatibility shim using public platform APIs | Project code; no new dependency | Could retain selected `UniversalDetector` signatures, but no public Android equivalent detector exists | High semantic/API completeness risk; external callers may use other public/internal classes | Smaller than current library | High plus broad real-plugin regression |
| New permissive detector dependency | Candidate-specific review required | Potentially broad coverage, but exact API/behavior differs | Adds a new license/source chain and potentially large binary | Likely increase | Medium/high |
| Keep exact 1.0.3 | Existing exact evidence; legal status reserved | Preserves current host contract and behavior | No engineering regression; legal review remains | No change | None |

Android's public `java.nio.charset` API provides named encoders/decoders and
support queries, not an unknown-input detector. The audited SDK stubs do not
expose `android.icu.text.CharsetDetector`. Therefore no no-dependency,
system-level equivalent was established.

Lowest engineering-risk option: keep exact 1.0.3 and submit the exact evidence
to counsel. Lowest license-complexity direction, if future product requirements
permit, would be removal after defining a closed supported Spider set and
proving those exact packages do not use the API. That proof does not currently
exist.

## Changes Made

No runtime or dependency change was made. The audit added only:

- a reproducible exact-source header auditor;
- machine- and human-readable 58-file records;
- Release DEX class inventory;
- this audit and the counsel package;
- factual corrections/links in compliance documentation.

No macOS player, libmpv, FFmpeg, UI, Native Mode, Android Bridge architecture,
FongMi commit, catvod behavior, Maven version, native binary, Hardened Runtime,
or signing strategy was changed.

## Regression Results

Because the decision gate was `KEEP_AND_COUNSEL_REVIEW`, Phase G/H runtime
removal/replacement and charset behavior regression were not triggered.

Completed audit verification:

- exact source audit regeneration is byte-deterministic;
- all generated JSON parses successfully;
- exact JAR/source/POM/APK/DEX hashes were independently recomputed;
- binary JAR versus DEX class list matched 62/62;
- Gradle offline `dependencyInsight` reproduced direct origin and lock reason;
- current saved Java/Dex package MD5 values matched configuration pins;
- visible DEX reference scans found no caller.

`MANUAL REGRESSION REQUIRED` if a future removal/replacement is attempted:
Android bridge startup, protected Spider initialization, home/category/search,
detail, play resolution, cloud authorization, malformed input fallback, and
real fixtures covering only encodings actually used by the selected Spiders.
A successful build alone must not be treated as behavior equivalence.

## SBOM Changes

None. The component remains in the APK and dependency lock, so the existing
Android SBOM continues to list it. Removing it from the SBOM would be false.
No new dependency or license-sensitive component was introduced.

## Source Mapping Changes

No binary/source mapping changed. Exact 1.0.3 sources, POM, license text,
covered-file list, FongMi source subset, local modified source, build files,
lock, and notices remain delivered. This audit adds more precise header and DEX
evidence without replacing Phase 1/2 materials.

## Counsel Package

`Docs/legal/MPL_GPL_COUNSEL_PACKAGE/` contains:

1. components and dependency graph;
2. exact header findings;
3. build, multidex, runtime, and plugin-loader relationship;
4. modification facts;
5. macOS + embedded APK distribution model;
6. exact hashes;
7. questions reserved for counsel.

The package is complete for the engineering facts available in this audit.
Counsel may request additional commercial/distribution context.

## Remaining Legal Questions

- Legal effect of the 57 alternative grants.
- Treatment of headerless `Constants.java` and the MPL-only POM.
- Compatibility analysis for one APK/shared class-loader graph with separate
  DEX placement and no current static reference.
- Required notices/source availability if kept.
- Sufficiency of AndroidDexBridge/FongMi/catvod publication model.
- Effect of embedding/installing the APK through the macOS product.
- Need for a written offer or more prominent notice.

No answer is supplied by this engineering report.

## P0 Disposition

`OPEN — COUNSEL REVIEW REQUIRED`

Reason: the component remains packaged with the GPL code in one APK; the exact
headers contain meaningful alternative text but one file is headerless and the
legal effect is not decided here. Engineering removal cannot be certified safe
against the product's open-ended dynamic Spider compatibility contract.

## Final Rating

Overall compliance rating remains **Blocked** on this P0 pending counsel review
or a future evidence-backed removal/replacement. It is not marked Ready.

## Required Answers

1. **Exact license evidence:** exact sources JAR SHA
   `3d1cb067…fc27`; 57 tri-license alternative headers; one headerless file;
   POM declares MPL-1.1.
2. **All 58 consistent:** No.
3. **Alternate/dual/secondary license:** Present in 57 files: GPL 2.0 or later
   or LGPL 2.1 or later instead of MPL; legal effect reserved. None in
   `Constants.java`.
4. **In final Release APK:** Yes, `PRESENT_IN_RELEASE_DEX`.
5. **Classes in DEX:** all 62 binary classes, listed in the DEX inventory.
6. **Actual caller:** none found in tracked host/FongMi source or current
   visible saved-plugin DEX.
7. **With GPL code in same DEX/APK:** same APK/application, separate DEX files.
8. **Static reference:** none found.
9. **Modified:** no juniversalchardet modification; FongMi/catvod has the
   documented proxy-port change.
10. **Can completely delete:** not safely proven for arbitrary dynamic Spiders.
11. **If not deleted, function depended upon:** potential host-provided unknown
    charset detection/API compatibility for external CatVod Spiders; no current
    visible caller.
12. **No-new-dependency system replacement:** no functionally equivalent public
    Android API established.
13. **Lowest-risk replacement:** none demonstrated; keeping exact 1.0.3 is the
    lowest engineering-risk disposition. Future removal is preferable only
    after closing/proving the supported plugin set.
14. **Replacement tests:** not applicable; no replacement made.
15. **APK hash changed:** Yes at the outer signed/ZIP container level after
    the mandated clean final rebuild: Phase 2 `5a46aec0…20af7`, final Release
    `59ee18fa…a845`. Both DEX hashes and inventories are unchanged; there was
    no Android runtime/source/dependency change.
16. **SBOM accurate:** Yes; component remains listed.
17. **MPL-1.1 component remains:** Yes, according to POM/component treatment;
    57 exact file headers also offer alternatives.
18. **New license-sensitive dependency:** No.
19. **Counsel package complete:** Yes for available engineering evidence.
20. **P0 state:** `OPEN — COUNSEL REVIEW REQUIRED`.
21. **macOS player behavior:** no impact; untouched.
22. **Android compatibility:** no runtime change; current compatibility
    preserved.
23. **Performance risk:** none introduced. Replacement performance remains
    unmeasured and is one reason no change was made.
24. **Commits:** recorded in the final handoff; Phase A and B are independent
    commits and counsel/report changes are a further commit.
25. **Rollback:** revert newest-to-oldest; exact commands are supplied in the
    final handoff.
26. **Final isolated worktree:** verified in the final handoff after commits and
    package verification.

## Final Recommendation

在不牺牲功能、兼容性和稳定性的前提下，优先消除不必要的许可证组合复杂度；如果无法无损消除，则保留稳定实现并将 exact evidence 提交专业法律审查。

For this release, retain the stable implementation, keep the P0 open, and give
the exact evidence package to counsel. A later removal should proceed only
after product policy defines a closed supported Spider set and real protected
packages demonstrate that the host-provided API is unnecessary.
