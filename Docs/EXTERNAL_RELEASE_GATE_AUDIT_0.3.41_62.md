# OKVideoMac 0.3.41 (62) External Release Gate Final Audit

Date: 2026-08-13

Audit type: first public GitHub Release engineering gate

Final decision: **BLOCKED**

This is an engineering and release-facts audit, not legal advice. The audit was
read-only with respect to product code, dependencies, player behavior, Spider
architecture, Android Bridge architecture, UI, performance policy, signing
architecture, and the installed Desktop application. Only this report was
added.

## 1. Executive Summary

OKVideoMac has crossed most of the engineering threshold from a development
project to a distributable open-source application. The verified Phase 4 local
Release artifact builds the expected 0.3.41 (62) app, contains 28 arm64 Mach-O
objects with Hardened Runtime, has a strict-valid inside-out ad-hoc signature,
contains an exact Android Release APK, passes exact SBOM equality, embeds a
substantial license/provenance payload, and has a complete Developer ID and
notarization workflow that fails closed when credentials are absent.

No real secret, private key, certificate, keystore, user database, Cookie,
OAuth token, content-source configuration, or private media history was found
in the current Phase 4 tracked tree, its Git archive, or the verified Phase 4
App. No P0 release blocker was found.

The release is nevertheless **BLOCKED** by two narrowly scoped P1 findings:

1. there is no single frozen branch/commit/tag containing the final Phase 4
   release pipeline and the latest juniversalchardet audit; the primary and
   `main` branches are older, while the two latest audit branches diverge; and
2. the public entry documentation does not yet tell a first-time user how to
   install safely, handle Gatekeeper without disabling security, distinguish
   Native Mode from Android compatibility, report issues, contribute, or map
   the binary to its exact source. `BUILDING.md` also begins with a stale
   pre-build environment statement that contradicts the current verified
   state.

These are release-integration/documentation tasks, not grounds for dependency
replacement, architecture work, player work, performance tuning, or further
license refactoring. After the two P1 items are closed, the engineering state
should move directly to Developer ID signing, notarization, final hash
generation, and publication.

## 2. Final Decision

**BLOCKED**

- P0: 0
- P1: 2
- P2: 4
- Apple signing/notarization: external credential gates, not failures
- Independent legal review: not performed, not an automatic engineering gate
- Known juniversalchardet license interpretation risk: documented and open

The decision is not caused by optional optimization, incomplete broad
performance testing, the absence of a lawyer opinion, or the lack of Apple
credentials. It is caused only by the two concrete P1 release-readiness gaps
listed above.

## 3. Frozen Baseline

| Item | Frozen value |
| --- | --- |
| Audit date/time baseline | 2026-08-13 10:58 CST |
| Primary branch | `codex/mpv-teardown-ab-experiment` |
| Primary commit | `557c3c90051b9867e84c4de78bddce1bd62be93c` |
| Primary initial status | clean |
| `main` | `b10135c6c73cdd6795c54019ed2e223e30f6c033` |
| Release version | 0.3.41 |
| Build | 62 |
| Host | macOS 14.8.8 (23J620), arm64 |
| Xcode | 16.2 (16C5032a) |
| Swift | 6.0.3 (`swiftlang-6.0.3.1.10`) |
| Clang | Apple clang 16.0.0 |
| Release architecture | arm64 |
| Deployment target | macOS 12.0 |

No primary-worktree change was stashed, reset, or overwritten.

## 4. Source / Worktree Status

All pre-existing worktrees were clean at freeze time:

| Worktree / branch | Commit | State |
| --- | --- | --- |
| primary / `codex/mpv-teardown-ab-experiment` | `557c3c9` | clean |
| Phase 2 / `codex/open-source-compliance-phase2` | `1552e51` | clean |
| Phase 3 / `codex/mpl-gpl-p0-audit` | `7012043` | clean |
| Phase 4 / `codex/engineering-readiness-phase4` | `3c87aa0` | clean |
| juniversalchardet / `codex/juniversalchardet-elimination-audit` | `af4ba94` | clean |
| legal detached worktree | `a250437` | clean |
| legal detached worktree | `557c3c9` | clean |

The history is linear through `20a7aca`, then diverges:

- Phase 4 adds four commits ending at `3c87aa0`, including final release
  scanning/packaging changes and the current readiness conclusion.
- The juniversalchardet branch adds two commits ending at `af4ba94`, containing
  `KEEP_FOR_COMPATIBILITY`, but it does not contain the final Phase 4 commits.
- The current primary branch is 15 audit-chain commits behind `af4ba94`; `main`
  is older still.
- No tag matching 0.3.41 exists.

This split is P1-01. Publishing any currently named branch without an explicit
integration/freeze step would omit material release evidence or hardening.

## 5. Fresh Build Result

Status: **NOT VERIFIED in this audit run; prior clean Phase 4 build PASS is
retained as historical evidence.**

Actions and results:

- A new detached clean worktree was created from `3c87aa0`.
- New DerivedData and Artifacts paths were placed under `/private/tmp`.
- Documentation/version preflight passed: `0.3.41 (62)`.
- `bootstrap.sh --with-native-dependencies` found Xcode, Swift, Git, curl,
  shasum and MacPorts pkg-config, but `xcodegen` was not on PATH. The tracked
  `.xcodeproj` exists, so formal packaging does not require regeneration.
- A fresh Gradle 8.9 distribution downloaded successfully into a new Gradle
  home. Android dependency resolution then stopped on a Google Maven TLS
  handshake termination. This is an external network result, not a compiler or
  source failure.
- The older Gradle cache and the only Xcode installation are on
  `/Volumes/XcodeDev`. Java thread inspection showed the Gradle wrapper blocked
  in `RandomAccessFile.open0`; even read-only directory traversal stalled.
- The clean Xcode Release attempt reported an I/O error before compilation and
  was confirmed to be using `/Volumes/XcodeDev/Xcode.app`.

Accordingly this run does not claim a fresh-build PASS or FAIL. Phase 4's
same-day evidence records a clean Release build, package generation, source
release generation, SBOM verification, and strict local signature validation.
The existing Phase 4 artifact independently verifies that result.

## 6. Release Packaging

Status: **PASS for the Phase 4 local-validation artifact; distribution remains
an external gate.**

Verified artifact:
`/Volumes/XcodeDev/OKVideoMacBuild/Artifacts/OKVideoMac.app`

- Version/build: 0.3.41 (62)
- Source index commit: `3c87aa07acd8d0d5a3ef32f0e5fdaf35c408ad59`
- Bundle: 125 files, approximately 165 MiB
- Mach-O: 28, all arm64
- External load paths/RPATHs: none under `/Users`, `/private/tmp`, `/Volumes`,
  `/opt/homebrew`, `/opt/local`, or `/usr/local`
- Hash manifest: 27 nested Mach-O entries plus one APK entry
- SBOM verification: 28 Mach-O and 87 locked Maven modules
- No `.DS_Store`, dSYM, log, temporary file, Debug APK, loose JAR/DEX, or ICU4J
  audit artifact was found

`package-app.sh` uses `set -euo pipefail`, checks required legal inputs,
requires the Android Release APK, performs a clean Xcode Release build with
Xcode signing disabled, normalizes the dependency closure, signs explicitly,
verifies the bundle and signatures, generates source archives/SBOMs/hashes,
and fails closed on missing or mismatched inputs.

## 7. Hardened Runtime

Status: **PASS — LOCAL VALIDATION**

- Project Release configuration sets `ENABLE_HARDENED_RUNTIME = true`.
- Debug and Release entitlement files are distinct.
- The distribution App entitlement file is intentionally empty.
- The local ad-hoc App uses only the documented development-only
  `com.apple.security.cs.disable-library-validation` exception.
- Node alone has `com.apple.security.cs.allow-jit`.
- No evidence of `allow-unsigned-executable-memory`,
  `disable-executable-page-protection`, or `get-task-allow` was found.
- `allow-jit` did not escape the Node executable boundary.

The local App's library-validation exception is not evidence about the future
Developer ID App; the distribution path selects the empty Release entitlement
file and the verification script rejects that exception in distribution mode.

## 8. Signing

Status: **PASS — LOCAL VALIDATION; EXTERNAL GATE — REAL DEVELOPER ID SIGNING
NOT VERIFIED**

The Phase 4 artifact passes `codesign --verify --deep --strict`. Every Mach-O
has `adhoc,runtime`, arm64, and no Team ID, which is correct for local
validation and must not be described as Developer ID distribution validation.

The packaging implementation:

- signs dependency Mach-O files before Node, the main executable, and the App;
- uses `--options runtime` for every code object;
- uses `--timestamp=none` only in local mode and `--timestamp` in distribution
  mode;
- never uses `--deep` to create or repair a signature;
- requires an explicit non-ad-hoc `DEVELOPER_ID_APPLICATION` identity;
- verifies Team ID consistency and rejects nested ad-hoc code in distribution
  mode; and
- does not perform a final ad-hoc overwrite.

The Desktop copy is an older Phase 3 package and has FinderInfo metadata on its
App root. Strict verification fails on that local filesystem copy. A copy made
under `/private/tmp` with only the copied Finder metadata removed passes strict
verification without re-signing, proving that the signed bytes are intact.
The Desktop copy must not be used as the GitHub upload source.

## 9. Notarization

Status: **EXTERNAL GATE — APPLE CREDENTIALS REQUIRED**

The workflow contains and orders:

1. final ZIP creation;
2. `xcrun notarytool submit ... --wait`;
3. `xcrun stapler staple`;
4. `xcrun stapler validate`;
5. distribution signature re-verification;
6. required `spctl --assess --type execute` acceptance;
7. ZIP recreation after stapling; and
8. final binary/source manifest and SHA-256 regeneration.

Current host state:

- Developer ID Application identities: 0
- selected notary profile: not configured
- real timestamp: not executed
- Apple notarization: not executed
- staple/staple validation: not executed
- Gatekeeper distribution assessment: not executed

Negative checks passed: distribution mode without an identity fails before
build; `--notarize` in local mode is rejected.

## 10. Secret Scan

Status: **PASS**

Coverage included the Phase 4 current tracked tree, a `git archive` of Phase 4,
the verified App, sensitive filename history, and signature-based scans across
reachable Git commits/all refs.

- Current Phase 4 tree scan: CLEAN, 313 files
- Current Phase 4 Git archive scan: CLEAN
- Embedded Phase 4 release attestation: CLEAN, 128 files
- Private-key markers: none
- AWS/GitHub/Slack/OpenAI-style tokens: none
- `.p12`, `.pfx`, private-key PEM, provisioning profile, keystore/JKS,
  credential file, or Cookie/session dump: none

False positives manually classified:

- `example.invalid` URL credentials and fake Bearer values occur only in log
  redaction tests;
- `password`, `token`, `Cookie`, and Authorization identifiers are runtime
  field/variable names or sanitization tests;
- public DoH endpoints and loopback URLs are public/product protocol data, not
  secrets.

Reachable history contains old `/Users/linyao` path literals in `AGENTS.md`,
an Android dependency inventory, and a DEX evidence document. Current Phase 4
HEAD is sanitized. No credential was present in those paths. This is P2-01,
not a secret-scan failure. If a future history scan finds a real credential,
deleting it from HEAD would be insufficient and the credential would require
revocation plus history remediation.

## 11. Privacy/Data Scan

Status: **PASS**

No tracked or bundled user history database, favorites, search history,
Cookie, OAuth token, cloud-drive credential, browser/WebView data, crash log,
real user account, real test phone number, or saved private content-source
configuration was found.

The test configurations use `example.invalid`, loopback, and documentation
address ranges. The App declares in UI and README that it does not bundle
content sources, accounts, Cookies, parser addresses, or DRM keys. The public
DoH and logo endpoints are not content-source configurations.

The product persists user-selected configuration/history at runtime, but those
Application Support files are not tracked or included in the Release bundle.

## 12. Dependency Inventory

Status: **PASS**

Actual Release distribution inventory is represented by:

- 28 macOS Mach-O objects;
- Node.js 22.23.0;
- QuickJS 2025-09-13-2 plus project bridge;
- mpv 0.41.0 plus local patch and project bridge;
- FFmpeg 7.1.4 six-library family;
- 18 additional native support dylibs;
- AndroidDexBridge Release APK;
- copied/modified FongMi catvod source at commit
  `5fdff00a602dc56e8ba756174daef20edab024f2`;
- 87 locked Maven runtime modules; and
- project icon/resource assets with provenance records.

Swift dependencies are local OKVideoKit products; there is no configured Git
submodule. Native and Android dependency locks are tracked.

## 13. SBOM / NOTICE / Provenance

Status: **PASS WITH DOCUMENTED PARTIAL HISTORICAL PROVENANCE**

`verify_sbom.py` passed exact equality between the App and macOS SBOM and
between the Gradle lock and Android SBOM. Both SPDX 2.3 and CycloneDX 1.6 are
present for macOS and Android.

The bundle includes project LICENSE/NOTICE, authoritative third-party notices,
Android notices, 30+ license/notice texts, modified-source patch/notice,
binary-to-source mapping, source-release index, native lock, Phase 4 native
evidence, MPL/GPL evidence, and counsel package.

No actually distributed binary was found wholly absent from both SBOM and
NOTICE. Level C historical provenance remains explicitly recorded for zlib and
MacPorts libc++/libc++abi; component identity and license are known. This is a
documented provenance limitation, not an unknown binary or missing-license
P0/P1.

## 14. Android Compatibility Runtime

Status: **PASS for package/build-path facts; runtime smoke inherited; this
audit's UI run NOT VERIFIED**

- The APK has package `com.okvideomac.dexbridge`, versionCode 26,
  versionName 0.3.14, minSdk 24, targetSdk 27.
- No `android:debuggable=true` manifest attribute was found.
- APK build entry is `./gradlew --no-daemon :app:assembleRelease`, wrapped by
  `build-android-dex-bridge.sh`.
- The APK is optional compatibility infrastructure for Java/Dex `csp_`
  Spiders. Static provider dispatch selects Android only for type 3 `csp_`
  sites; standard XML/JSON/Base64, live/XMLTV, QuickJS, and Node paths are
  separate.
- The App is not accurately described as having no Android dependency: it
  distributes the APK and contains an optional SDK/ADB/emulator path.
- The optional Android runtime currently uses developer-specific default paths
  under `/Volumes/XcodeDev`. This does not block native App startup but makes
  Android compatibility non-portable without matching external setup. It is
  documented Experimental capability and P2-02.

The current audit could not establish a fresh Native Mode UI run without an
Android process because Computer Use timed out and older emulator/adb processes
already existed. This is `NOT VERIFIED`, not `FAIL`. Static separation and
prior host regression evidence show no release-host regression.

## 15. juniversalchardet Status

Status: **COMPATIBILITY_EXPORTED — KEEP_FOR_COMPATIBILITY**

The latest audit at `af4ba94` was read and inherited. No deletion or
replacement was attempted.

- Coordinate: `com.googlecode.juniversalchardet:juniversalchardet:1.0.3`
- Gradle relationship: direct `api` dependency of local `:catvod`
- Current tracked business-code callers: none known
- Compatibility reason: an open FongMi/Spider host classpath and protected or
  future external Spider code may depend on the exported package
- SBOM: 1.0.3 remains present in SPDX and CycloneDX
- NOTICE/license/source evidence: present
- Release APK: all 62 package classes remain in `classes2.dex`
- `classes.dex` SHA-256:
  `a317f2f8af8ce79e5f6a02efc0bf2f2f9e126d50686bcf597fcff98ac303e9ea`
- `classes2.dex` SHA-256:
  `332360b30f2dd6393493b0bda7860d9769f901dfb4177f2fd8b816b215f4f0c7`

ICU4J 78.3 remains audit-only and is absent from the Release bundle and SBOM.

Known status: **DOCUMENTED LICENSE INTERPRETATION RISK**.

## 16. License Engineering Evidence

Status: **PASS for engineering materials; no new legal conclusion**

GPL/LGPL facts:

- mpv/FFmpeg/native binaries map to versions, source locations, configuration,
  patches, notices and provenance levels.
- mpv's modified source patch is bundled.
- FongMi/catvod copied/modified source and upstream commit are identified.
- LGPL dynamic replacement mechanics were tested historically; stable binaries
  were retained.

MPL facts:

- exact 1.0.3 sources JAR and POM hashes are recorded;
- 57 of 58 Java files contain tri-license alternative headers;
- `Constants.java` has no file-level header;
- all 62 output classes are mapped in the Release DEX;
- no project modification to juniversalchardet was found; and
- exact source, license, covered-file list, DEX evidence and counsel questions
  are distributed.

FongMi/catvod facts:

- copied/adapted code is not represented as wholly original;
- upstream commit and local change are recorded;
- project-authored bridge code is distinguished from copied catvod code.

Historical Phase 3 documents still contain their original `Blocked`/P0
language, but their first-page addendum identifies them as historical and
points to Phase 4's current `DOCUMENTED LICENSE INTERPRETATION RISK`
disposition. No claim of legal compliance or lawyer approval is made.

## 17. Release Bundle Inventory

Status: **PASS**

The Phase 4 bundle contains:

- one main App executable;
- one Node executable;
- 26 dylibs;
- one Android Release APK;
- App icon and compiled assets;
- localized strings;
- runtime licenses; and
- the complete Legal/Compliance hierarchy.

No source-audit harness, Phase temporary artifact, build log, debug symbol,
Debug APK, test APK, test fixture, developer configuration, duplicate dylib,
ICU4J artifact, loose JAR/DEX, or unexpected executable was found. The 28
executable/Mach-O paths exactly match the SBOM inventory.

## 18. Functional Regression

Status: **PASS WITH KNOWN COVERAGE, inherited from Phase 4; current UI rerun
NOT VERIFIED**

Phase 4 records observed passes for:

- 1080p H.264/AAC VOD playback;
- pause/resume;
- repeated small forward/backward seek;
- a 4K HEVC/AAC MKV candidate smoke;
- CCTV-1 live playback;
- five rapid next-channel actions; and
- VOD/live close and re-entry cycles.

One external-subtitle TS source was blocked before decode by an expired user
cloud Cookie and was correctly classified as an external source credential
failure, not a native host failure.

This audit's Computer Use request timed out twice and did not return an
accessibility tree. Therefore cold launch, settings/navigation, close/reopen,
subtitle switching, episode switching, and a fresh Native Mode run are not
newly claimed here. The absence of a new UI observation is not converted into
a failure.

## 19. Runtime Lifecycle

Status: **PASS WITH KNOWN PERFORMANCE CHARACTERISTICS**, based on retained
release evidence; this audit did not run a new soak.

The established lifecycle evidence includes:

- five `fullDestroy` playback/close rounds;
- eight extreme lifecycle scenarios;
- approximately 505 MiB lower final close-state footprint versus warm stop in
  the historical comparison;
- 52–69 ms explicit client recreation time;
- no leak reported by the limited `leaks` observation;
- no crash after the documented final-draw race fix; and
- no obvious steady-playback CPU/RSS regression in the Phase 4 five-sample
  stable/candidate comparison.

Process inspection during this audit found an already running Phase 4 App and
Node process (about two hours) plus emulator/adb processes predating this audit
by much longer. Because there was no known closed baseline and the App remained
running, those processes cannot be classified as zombies or post-exit leaks.

The broader AV1, multi-audio, selectable subtitle, HDR, long-form, cross-source
live, P90 latency and long-soak matrix remains incomplete. Stable binaries were
retained, so this is not a release-candidate replacement gate.

## 20. Git Hygiene

Status: **PASS with P1 branch freeze and P2 history/path findings**

- Tracked file count at Phase 4: 303
- Largest file: approximately 1.59 MiB
- No Git LFS need identified
- No submodules
- No tracked symlinks or broken symlinks
- No tracked App, APK, dylib, DerivedData, Gradle cache, test output, dSYM, or
  build log
- The Gradle wrapper JAR is intentionally tracked build tooling
- `.gitignore` covers SwiftPM/build, DerivedData, Xcode user data, Vendor build,
  Artifacts, reference checkout and release ZIP paths

Reachable history contains low-sensitivity developer paths that are removed
from current HEAD. They are not credentials but would remain visible if full
history is published. This is P2-01; no history rewrite is authorized by this
audit.

## 21. README / Public Release Documentation

Status: **FAIL — P1-02**

README currently answers what the project is, version, macOS/architecture,
major features, lack of bundled content sources, known limitations, build
commands, local/distribution packaging commands, upstream identity, and
project license.

It does not adequately answer:

- how a user installs the downloaded Release;
- what a correctly signed/notarized first launch should look like;
- safe Gatekeeper recovery without disabling system security;
- what “Native Mode” means;
- which exact capabilities do not require Android;
- that Android Bridge is optional compatibility rather than an App startup
  prerequisite;
- how to report an issue;
- how to contribute;
- how the Release binary maps to its exact project/third-party source and
  hashes; or
- where first-release known risks are summarized.

There is no CONTRIBUTING, SECURITY, issue template, or equivalent public
guidance. `BUILDING.md` also opens with a dated statement saying the App has
not built on the machine, contradicting current Phase 4 evidence later in the
repository. Under the requested rubric, a README that cannot guide a first
user through installation is P1.

## 22. Version Consistency

Status: **PASS**

- `project.yml`: 0.3.41 / 62
- Xcode project: 0.3.41 / 62
- Info.plist indirection: correct
- verified Phase 4 App: 0.3.41 / 62
- Desktop App: 0.3.41 / 62
- minimum macOS: 12.0
- Node: 22.23.0
- Android companion: separately versioned 0.3.14 (versionCode 26), consistent
  with package verification rules

References to 0.3.39/Build 60 are confined to explicitly historical Hardened
Runtime and player A/B reports and are not current user-visible version drift.
No 0.3.40 user-facing version was found.

## 23. P0 Findings

**Count: 0**

No secret/private key, broken Release startup evidence, missing mandatory
license/source material, untracked private data, or unverified binary closure
was found at P0 severity.

## 24. P1 Findings

**Count: 2**

### P1-01 — No single frozen public-release commit/tag

Evidence: primary `557c3c9`, `main` `b10135c`, Phase 4 `3c87aa0`, and
juniversalchardet `af4ba94`; Phase 4 and juniversalchardet diverge after
`20a7aca`; there is no 0.3.41 tag.

Impact: the maintainer cannot name one immutable commit that contains all
current release pipeline and final audit evidence. Publishing the wrong branch
would omit material release changes.

Required fix: create a release branch from `3c87aa0`, integrate only the two
juniversalchardet documentation/harness commits (or otherwise preserve their
facts), add this report, verify a clean tree, and tag the exact verified commit.
No runtime dependency change is required.

### P1-02 — First-public-release documentation is incomplete

Evidence: README lacks installation, safe Gatekeeper handling, Native/Android
capability boundary, issue/contribution, exact binary-source, and release-risk
guidance; `BUILDING.md` begins with a stale contradictory environment status.

Impact: a first-time GitHub visitor cannot reliably install, understand the
compatibility boundary, or verify/report/contribute to the Release.

Required fix: make a targeted release-documentation update. Do not rewrite the
architecture or turn this into a broad documentation redesign.

## 25. P2 Findings

**Count: 4**

1. **P2-01 — Historical developer paths:** old reachable commits contain
   `/Users/linyao` in non-secret audit/instruction files. Current HEAD and
   release scan are clean.
2. **P2-02 — Optional Android path portability:** Android compatibility uses
   `/Volumes/XcodeDev` defaults and external SDK/emulator setup. Native paths
   remain usable without it; capability is documented Experimental.
3. **P2-03 — Build environment resilience/CI:** the build relies on locally
   installed Xcode/MacPorts/Android tooling; the current external volume and
   Google Maven TLS failure prevented an independent rerun. Better CI/cache
   resilience is desirable but prior verified packaging exists.
4. **P2-04 — Desktop maintenance copy:** the Desktop App is a Phase 3 package
   and has FinderInfo metadata that strict codesign rejects on that copy. The
   Phase 4 artifact is valid and is the only acceptable local evidence source.

None of these P2 items independently blocks the first public Release.

## 26. External Gates

- Developer ID Application certificate: **EXTERNAL GATE**
- Real Team ID signature: **EXTERNAL GATE**
- Secure timestamp: **EXTERNAL GATE**
- Notary keychain profile/credentials: **EXTERNAL GATE**
- Apple notarization: **EXTERNAL GATE**
- Staple and staple validation: **EXTERNAL GATE**
- Gatekeeper acceptance of the notarized artifact: **EXTERNAL GATE**
- Public GitHub Release creation/upload: **EXTERNAL GATE / explicit release
  action**
- Optional independent legal review: **NOT PERFORMED**

These gates do not explain the current `BLOCKED` result; P1-01 and P1-02 do.

## 27. Known Documented Risks

- juniversalchardet 1.0.3 license interpretation and GPL/APK combination:
  **DOCUMENTED LICENSE INTERPRETATION RISK**
- one juniversalchardet source file lacks a file header; POM names MPL-1.1;
  57 files contain historical alternative grants
- stable native zlib/libc++/libc++abi exact historical build provenance is
  partial
- Node bundles execute with Node capability and must be trusted/hash-checked
- dynamic/protected external Spiders are open-ended and can fail independently
- Android compatibility requires external SDK/emulator setup
- broad manual format/subtitle/HDR/performance matrix is incomplete, while the
  already validated stable native set is retained

These are not represented as “no legal risk,” “legally compliant,” or lawyer
approved.

## 28. Independent Legal Review Status

**Independent Legal Review: NOT PERFORMED**

Engineering evidence has been assembled for counsel. The absence of a lawyer
opinion is not by itself an engineering release FAIL. The known license
interpretation issue remains `DOCUMENTED RISK`.

## 29. Exact Next Actions

Perform only the following release-focused work:

1. Create one release branch/commit that contains Phase 4 `3c87aa0`, the latest
   juniversalchardet audit facts from `af4ba94`, and this final report.
2. Make the narrow README/BUILDING/public-contribution update described in
   P1-02. Include safe Gatekeeper instructions; do not recommend disabling
   Gatekeeper, SIP, or quarantine globally.
3. Verify all worktrees and the selected release commit are clean; create the
   immutable 0.3.41 tag only at that commit.
4. Restore a healthy Xcode/Gradle build environment and run
   `package-app.sh --mode distribution --notarize` with a real Developer ID
   identity and notary profile.
5. Require Developer ID Team ID equality, timestamp, notarization acceptance,
   staple validation, `spctl` acceptance, bundle/SBOM verification, and final
   post-staple hash regeneration.
6. Upload the one-shot set from `IMMUTABLE_RELEASE_READINESS.md`: final ZIP,
   project source, third-party source, licenses, source index, binary-bound
   manifest, SHA256SUMS, four SBOMs, exact APK, and release notes.
7. State the documented juniversalchardet risk and `Independent Legal Review:
   NOT PERFORMED` in release notes without turning it into a false legal
   assurance.

After P1-01 and P1-02 are closed, stop non-blocking compliance refactoring and
enter Developer ID signing, notarization, and first public Release. Do not
delete juniversalchardet, replace stable native binaries, refactor playback,
or reopen Spider/Android architecture work for this release.

## 30. Rollback / No-Change Statement

No product source, business logic, UI, dependency, lock, entitlement, signing
script, runtime, player, Spider, Android Bridge, native binary, APK, SBOM,
installed Desktop App, credential, or Git history was changed by this audit.

Temporary audit worktrees, DerivedData, Gradle downloads, copied bundle inputs,
and an xattr-cleared verification copy were created only under `/private/tmp`.
The Desktop App was read-only. Failed/hung audit processes started by this
audit were interrupted; pre-existing App, Node, adb and emulator processes
were not terminated.

Rollback for this audit is therefore limited to removing this report and the
temporary audit worktrees/artifacts. No runtime rollback exists or is needed.

## Release Go/No-Go

Engineering Release Status: **BLOCKED**

P0: **0**

P1: **2**

P2: **4**

Apple Developer ID Signing: **EXTERNAL GATE**

Apple Notarization: **EXTERNAL GATE**

Open Source Materials: **PASS**

Secret Scan: **PASS**

SBOM: **PASS**

Third-Party Provenance: **PASS**

Independent Legal Review: **NOT PERFORMED**

Known License Interpretation Risk: **DOCUMENTED**

Recommended Action: **Close only P1-01 and P1-02, then stop non-blocking
engineering/compliance work and proceed directly to Developer ID signing,
notarization, final immutable hash generation, and the first public GitHub
Release.**
