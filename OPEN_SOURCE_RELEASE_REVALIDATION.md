# OKVideoMac 0.3.41 (63) Open Source Release Revalidation

Audit date: 2026-08-15 (Asia/Shanghai)

## 1. Final Status

`READY_WITH_REMAINING_GATES`

The integrated source passes the automated engineering, clean Release build,
runtime smoke, bundle, source-release, SBOM, secret, and runtime-path gates.
Formal distribution signing can begin after maintainer review. GitHub publication
and the final DMG remain gated by the explicit items in sections 15 and 16.

## 2. New Release Candidate

- Integration branch: `codex/release-0.3.41-revalidation`
- Validated source HEAD: `f169e2491831359950f771513f6fd2a74f6c0a49`
- Parent: `d31489a39256896c64294efbab61c87557d877ab`
- Historical frozen baseline: `ae7fa3d20c2feb46f53758f946d7b18cd239b76a`
- Version: `0.3.41`
- Build: `63`
- Bundle identifier: `com.okvideomac.OKVideoMac`
- Display name: `OKVideoMac`
- Worktree: `/private/tmp/okvideomac-release-revalidation`
- Working tree before this report was added: clean
- Formal `release/0.3.41` reference: unchanged at the historical frozen baseline

The report commit follows the validated source HEAD and changes documentation
only. Its exact SHA is reported in the maintainer handoff because a commit cannot
embed its own SHA.

### Commit graph from the historical baseline

```text
f169e24 fix(node): capture runtime actor for readiness closure
d31489a docs: refresh release candidate status for build 63
b0dc0e8 release: bump build number to 63
cb06914 fix(import): make configuration submission atomic and cancellable
7f800e2 fix(player): retry until media playback actually starts
554d4f2 fix(import): report progress and defer live post-processing
b4ab14b fix(android): make compatibility runtime portable and device-safe
82c47c8 fix(app): standardize display name as OKVideoMac
49ab212 fix: add home configuration shortcut
edac4d5 fix: clarify setup guidance and attribution
00a1194 fix: synchronize node runtime readiness
ae7fa3d release: finalize app icon for 0.3.41
```

## 3. Incorporated Fixes

All entries below are classified `ACCEPTED_FOR_RELEASE`.

### Node runtime readiness

- Commits: `00a1194dc0372f880001abcdaaa604d6e8f2e4b5`,
  `f169e2491831359950f771513f6fd2a74f6c0a49`
- Files: `AppState.swift`, `NodeBundleRuntimeService.swift`,
  `NodeHTTPSpiderSiteProvider.swift`, `OKVideoMacTests.swift`
- Purpose: coalesce startup, await real readiness, recover stale endpoints, and
  avoid capturing the non-Sendable application environment in the readiness
  closure.
- Verification: App tests, strict concurrency comparison, and Node/V8 JIT
  packaged-runtime smoke passed.

### Setup guidance, attribution, naming, and home shortcut

- Commits: `edac4d55efc17283cc77a81cb9540c6e44a80b47`,
  `49ab21224284189b516f012e718480cca9b298db`,
  `82c47c8513f7de37ef6a4e608759aea37b11d325`
- Files: configuration/home/live/settings views, configuration parser,
  `Info.plist`, and `project.yml`
- Purpose: correct import/live empty-state guidance, add the home configuration
  action, retain the maintainer attribution, and consistently present
  `OKVideoMac`.
- Verification: compile, App tests, Info.plist inspection, and packaged App
  metadata passed.

### Android compatibility runtime portability and device ownership

- Commit: `b4ab14b0741a6200e4441f8d766289986fe7c7a2`
- Files: Android bridge Gradle/Java files, `AppEnvironment.swift`,
  `AppState.swift`, JavaScript provider, settings UI, bundle verifier, and tests
- Purpose: replace developer-machine runtime assumptions with SDK resolution,
  a dedicated managed AVD, dynamic serial/port identity, scoped forwarding, and
  ownership-safe stop/install operations.
- Verification: snapshot tree reconstruction matched the reviewed snapshot;
  App tests, Android Release assembly, bundle verification, and hardcoded-path
  audit passed.

### Import progress and deferred live post-processing

- Commit: `554d4f2f9a9d82f5200b2f3278dc7cbbf6858e05`
- Files: `AppState.swift`, configuration/live views, live models, XMLTV tests,
  and App tests
- Purpose: immediate local submit progress, duplicate-submit prevention,
  background EPG/channel checks, and XMLTV index work outside MainActor.
- Verification: snapshot tree reconstruction matched the reviewed snapshot;
  App and package tests passed.

### Playback no-media retry

- Commit: `7f800e28b624b3db11bab3c6bbcf7f7e6bb21857`
- Files: `AppState.swift`, `PlayerClient.swift`, `MPVPlayerClient.swift`, and
  App tests
- Purpose: retry eligible sources until actual audio/video playback begins,
  while preserving request identity and stale-request rejection.
- Verification: snapshot tree reconstruction matched the reviewed snapshot;
  App tests and MPV/FFmpeg initialization smoke passed.

### Atomic and cancellable configuration submission

- Commit: `cb06914767b36f588c3b2beec42d91ca4c6ea2ae`
- Original uncommitted-diff evidence SHA-256:
  `955d1399249bd5e6df21627fb76b5fe4cea154f160b096997ce116c22e34bc67`
- Files: `AppState.swift`, `NodeBundleRuntimeService.swift`,
  `ConfigurationView.swift`, `ConfigurationLoader.swift`, `SQLiteStore.swift`,
  loader/persistence tests, and App tests
- Purpose: Sheet-local error presentation, same-event paste synchronization,
  edge-only URL whitespace normalization, operation identity/cancellation
  checkpoints, and atomic SQLite persistence.
- Verification: seven targeted regression tests were added; the integrated App
  and package suites passed. Cancellation is checked after network return and
  parse, before persistence, before reload/provider activation, and before UI
  success commit. Once the database transaction has committed, the Sheet no
  longer offers a misleading cancellation path.

### Build and release documentation

- Commits: `b0dc0e86e4d34a272945e3cb0e555d4a7f69bc5e`,
  `d31489a39256896c64294efbab61c87557d877ab`
- Files: Xcode project, `project.yml`, README, BUILDING, COMPATIBILITY, and
  PERFORMANCE documentation
- Purpose: retain marketing version 0.3.41, move build 62 to 63, and describe
  the actual candidate implementation and validation workflow.
- Verification: documentation status gate and packaged metadata passed.

## 4. Excluded Changes

- No mpv teardown A/B experiment or unrelated experimental branch was merged.
- No TEMP/test commit message was retained from the reviewed snapshots.
- No SDK/system-image automatic downloader was added to the Android runtime.
- No unrelated formatting, cache, user data, signing artifact, or local
  configuration was included.
- The unrelated historical stash on the main worktree was left untouched.

## 5. Changed Files

Relative to `ae7fa3d20c2feb46f53758f946d7b18cd239b76a`, the validated source changed:

```text
OKVideoMac/Helpers/AndroidDexBridge/app/build.gradle
OKVideoMac/Helpers/AndroidDexBridge/app/src/main/java/com/okvideomac/dexbridge/BridgeActivity.java
OKVideoMac/Helpers/AndroidDexBridge/app/src/main/java/com/okvideomac/dexbridge/BridgeServer.java
OKVideoMac/README.md
OKVideoMac/macOS/OKVideoMac/App/AppEnvironment.swift
OKVideoMac/macOS/OKVideoMac/App/AppState.swift
OKVideoMac/macOS/OKVideoMac/Docs/BUILDING.md
OKVideoMac/macOS/OKVideoMac/Docs/COMPATIBILITY.md
OKVideoMac/macOS/OKVideoMac/Docs/PERFORMANCE.md
OKVideoMac/macOS/OKVideoMac/Engines/Spider/JavaScriptSpiderSiteProvider.swift
OKVideoMac/macOS/OKVideoMac/Engines/Spider/NodeBundleRuntimeService.swift
OKVideoMac/macOS/OKVideoMac/Engines/Spider/NodeHTTPSpiderSiteProvider.swift
OKVideoMac/macOS/OKVideoMac/Features/Configuration/ConfigurationView.swift
OKVideoMac/macOS/OKVideoMac/Features/Home/HomeView.swift
OKVideoMac/macOS/OKVideoMac/Features/Live/LiveView.swift
OKVideoMac/macOS/OKVideoMac/Features/Settings/SettingsView.swift
OKVideoMac/macOS/OKVideoMac/OKVideoMac.xcodeproj/project.pbxproj
OKVideoMac/macOS/OKVideoMac/Packages/OKVideoKit/Sources/OKVideoCore/Configuration/ConfigurationLoader.swift
OKVideoMac/macOS/OKVideoMac/Packages/OKVideoKit/Sources/OKVideoCore/Configuration/ConfigurationParser.swift
OKVideoMac/macOS/OKVideoMac/Packages/OKVideoKit/Sources/OKVideoCore/Live/LiveModels.swift
OKVideoMac/macOS/OKVideoMac/Packages/OKVideoKit/Sources/OKVideoCore/Player/PlayerClient.swift
OKVideoMac/macOS/OKVideoMac/Packages/OKVideoKit/Sources/OKVideoPersistence/Database/SQLiteStore.swift
OKVideoMac/macOS/OKVideoMac/Packages/OKVideoKit/Tests/OKVideoCoreTests/ConfigurationLoaderTests.swift
OKVideoMac/macOS/OKVideoMac/Packages/OKVideoKit/Tests/OKVideoCoreTests/XMLTVParserTests.swift
OKVideoMac/macOS/OKVideoMac/Packages/OKVideoKit/Tests/OKVideoPersistenceTests/SQLiteStoreTests.swift
OKVideoMac/macOS/OKVideoMac/Player/MPVPlayerClient.swift
OKVideoMac/macOS/OKVideoMac/Scripts/verify-bundle.sh
OKVideoMac/macOS/OKVideoMac/Supporting/Info.plist
OKVideoMac/macOS/OKVideoMac/Tests/OKVideoMacTests.swift
OKVideoMac/macOS/OKVideoMac/project.yml
```

This report is the only additional file in the report commit.

## 6. Regression Results

### Automated suites

| Suite | Total | Passed | Failed | Skipped | Result |
|---|---:|---:|---:|---:|---|
| Xcode integrated App tests | 198 | 198 | 0 | 0 | PASS |
| OKVideoKit package tests | 94 | 94 | 0 | 0 | PASS |
| Android Gradle tests | 0 | 0 | 0 | 0 | NO-SOURCE |
| Android `:app:assembleRelease` | n/a | n/a | 0 | n/a | PASS |

The Xcode result bundle is:
`/private/tmp/okvideomac-revalidation-node-capture-tests/Logs/Test/Test-OKVideoMac-2026.08.15_11-27-30-+0800.xcresult`.

The 94 package tests cover configuration loading/parsing, HTTP, live source
loading/parsing, XMLTV, logging redaction, search, playback resolution, SQLite,
site providers, and spider behavior. New import regressions cover URL edge
normalization, paste synchronization, cancellation before side effects, and
atomic replacement/rollback.

The first package-test attempt in the restricted sandbox could not write the
Clang module cache; the identical authorized rerun passed 94/94. The first final
packaging attempt similarly could not access the existing Gradle cache lock;
the identical authorized rerun completed. These were environment permission
failures, not hidden product-test failures.

### Maintainer/manual coverage

Earlier maintainer reproduction evidence drove the import and playback fixes.
This automated revalidation did not claim completion of the final real-source
manual matrix (remote provider credentials, seek/episode switching, full live
switching, and restart persistence). That remains a P1 maintainer acceptance
gate for the final signed candidate.

## 7. Node Runtime

- Cold startup readiness: PASS by actor-level tests and packaged Node smoke.
- First operation: provider now waits on shared `ensureReady()`; the former
  first-fail/second-success race is covered by tests.
- Concurrent callers: coalesced startup task; PASS.
- Warm runtime: existing ready endpoint is reused after validation; PASS.
- Stale endpoint/runtime recovery: stale readiness is invalidated and restarted;
  PASS by tests.
- Packaged runtime: Node `v22.23.0`, V8 `12.4.254.21-node.56`, JIT calculation
  passed without SIGTRAP.
- Strict concurrency follow-up: the newly introduced non-Sendable
  `AppEnvironment` capture was removed without unchecked Sendable,
  `@preconcurrency`, or warning suppression.

## 8. Android Compatibility

- Toolchain discovery order: App-managed SDK (future), user-saved SDK,
  `ANDROID_HOME`, deprecated `ANDROID_SDK_ROOT`, default user SDK, then PATH
  inference.
- AVD: dedicated `OKVideoMac_Runtime` under application support; child-process
  `ANDROID_AVD_HOME` only.
- Emulator identity: generation/nonce, PID, executable/arguments, AVD name,
  console port, dynamic serial, and scoped forwards are revalidated.
- Fixed production serial: absent.
- Implicit production ADB selection/`adb -e`: absent.
- Mutating ADB commands: explicitly scoped to a verified serial.
- Forward removal: only the runtime-owned specific forward is removed; no
  production `forward --remove-all`.
- Ownership safety: stop/install/forward refuse to proceed if ownership cannot
  be re-established.
- Automatic downloads: intentionally absent; a missing installed system image
  is reported instead of silently invoking `sdkmanager`.
- Optional isolation: missing Android components do not block Native, QuickJS,
  Node, or Live paths.

The fixed `emulator-5554` literal remains only in test fixtures and the
developer-only manual `run-android-dex-bridge.sh`; it is not invoked by the App
runtime. Modernizing that developer script is P2.

## 9. Hardcoded Path Audit

`PASS`

No production runtime dependency on `/Volumes/XcodeDev`, a developer home,
`/private/tmp`, `/tmp`, Homebrew, MacPorts, DerivedData, signing material, or a
fixed Emulator serial was found. The `/Users/...` pattern in `LogRedactor.swift`
is a redaction rule, not a runtime path.

Build/project scripts retain build-time SDK/Xcode/package-manager defaults.
Tests retain explicit path and serial fixtures. The developer-only Android
bridge launcher retains legacy local defaults. These are classified build-time
or test/developer-tool-only, not user runtime dependencies.

## 10. Secret Scan

`PASS`

- Candidate ancestry patch: no API key, token, cookie, password,
  authorization, Apple/notary credential, private key, certificate, or private
  configuration pattern found.
- Current package scan: 128 files, no findings, `CLEAN`.
- Final source-release scan: 8 archives/manifests, no findings, `CLEAN`.
- No tracked `.p12`, `.p8`, PEM/key, provisioning profile, database, or SQLite
  user-data file was found at the validated HEAD.

## 11. Privacy Audit

`ATTENTION`

The current distributable source/package scan is clean. Candidate Git ancestry
contains the local path `/Users/linyao/` in historical `AGENTS.md`, introduced
by `008a1e10fdd179a4ec2aea4d958ca01a405c3e5b`. This is not a credential and is
excluded from the generated source release, but it would remain visible if the
complete Git history were made public. No history was rewritten. The maintainer
must explicitly accept that disclosure or authorize a separate history privacy
remediation before making the repository public.

Candidate-ancestry author email was `codex@openai.com`; no private maintainer
email, user database, account, cookie, or private content-source payload was
found.

## 12. License / Provenance

- Native inventory: 28 Mach-O objects.
- Binary/source mapping classification: A=10, B=15, C=3, D=0. No unmapped
  category-D binary exists.
- Android SBOM: 89 components, including 87 locked Maven modules.
- Native SBOM: 28 components; bundle-to-SBOM verification passed.
- `LICENSE`, `NOTICE.md`, `THIRD_PARTY_NOTICES.md`,
  `THIRD_PARTY_LICENSES.md`, `SOURCE_PROVENANCE_MANIFEST.md`, and
  `BINARY_SOURCE_MAPPING.md` are present and package-verified.
- Current bundled families include mpv/FFmpeg, Node.js, QuickJS, libass,
  HarfBuzz, FreeType, FriBidi, libplacebo, Brotli, lcms2, libpng, libjpeg,
  liblzma, libiconv, bzip2, SQLite, zlib, libc++, and the Android bridge's
  locked dependencies.
- Source release, third-party source archive, license archive, index, manifest,
  and checksums were generated and verified offline.

No source/binary mapping defect was found. A maintainer or counsel review of the
published license/provenance set remains an external GitHub-publication gate; no
claim of legal advice is made by this engineering audit.

## 13. Documentation

- `OKVideoMac/README.md`: current for 0.3.41 (63), source-free product behavior,
  Native/JS/Node/Java-Dex scope, optional Android requirements, Apple Silicon,
  build/test workflow, and limitations.
- `BUILDING.md`: current clean build, test, package, and gate instructions.
- `LICENSE`, `NOTICE.md`, third-party notices/licenses: present.
- `SECURITY.md`, `CONTRIBUTING.md`: present.
- Documentation status check: PASS.

The public README is intentionally under `OKVideoMac/`, matching the project
layout; absence of a duplicate repository-root README is not treated as a
product defect.

## 14. Build

- Source commit: `f169e2491831359950f771513f6fd2a74f6c0a49`
- Command: `OKVideoMac/macOS/OKVideoMac/Scripts/package-app.sh --mode local`
  with isolated DerivedData/artifact paths and offline source-release cache.
- Result: clean Xcode Release build PASS; Android Release APK PASS.
- App: `/private/tmp/okvideomac-revalidation-f169e249/Artifacts/OKVideoMac.app`
- Archive: `/private/tmp/okvideomac-revalidation-f169e249/Artifacts/OKVideoMac-0.3.41-macOS-arm64.zip`
- Archive size: 64,520,571 bytes
- Archive SHA-256:
  `e65c34ef669e2272a6169a801034ecaf9ab1cc08f9f6a6693e2045bb1f3dc91c`
- Architecture: arm64 for all 28 Mach-O objects.
- Hardened Runtime: present on all 28 local signatures.
- Local signature structure: strict verification PASS; all 28 objects are
  intentionally ad-hoc for this engineering candidate.
- Entitlements: existing main/Node boundary retained and package-verified.
- Bundled Android APK SHA-256:
  `2961ebf5c1a572b187a5ba005c55981a119c7c9fff57b3c58aa5de726aff2fc6`
- Runtime smoke: QuickJS PASS; MPV/FFmpeg PASS; Node/V8 JIT PASS; App remained
  running for five seconds PASS.
- Gatekeeper: not applicable to the ad-hoc local candidate and not claimed.

`UNSIGNED ENGINEERING CANDIDATE`

No Developer ID distribution signing, notarization, staple, Gatekeeper final
assessment, or final DMG creation occurred.

### Warning audit

- Baseline strict-concurrency build: 149 warning lines.
- Candidate before the focused Node capture fix: 153 warning lines.
- Candidate after the fix: 152 warning lines.
- Baseline and final candidate each have 50 distinct warning messages.
- New non-Sendable `AppEnvironment` capture at the integration point: reduced
  from one diagnostic class to zero.
- Existing Swift 6 migration warnings, MPV callback Sendable warnings, WebKit
  import suggestions, OpenGL/menu deprecations, and build-phase output
  declarations remain visible. They were not suppressed and do not fail the
  current Swift 5 Release build.
- Android build warnings: command-line tools/SDK XML version skew, javac
  deprecation, and lint Kotlin metadata version skew; Android Release build and
  lint still pass.

## 15. Release Baseline

`NEW_RELEASE_BASELINE_CANDIDATE` is intentionally **not defined yet**.

The integration source HEAD is an engineering candidate and has passed the
automated gates, but the Git-history privacy decision, external license review,
and final maintainer manual regression remain open. The historical baseline
`ae7fa3d20c2feb46f53758f946d7b18cd239b76a` was not changed, deleted, amended,
or rewritten.

## 16. Remaining Issues

### P0

None found.

### P1

1. GitHub history privacy decision: the historical local username/path described
   in section 11 requires explicit maintainer acceptance or separately authorized
   history remediation before the repository is made public.
2. Final maintainer manual regression has not been repeated against the eventual
   Developer ID signed candidate. Real configuration import, playback/seek/
   episode switching, Live switching, and restart persistence must be accepted.
3. Published license/provenance materials need the maintainer's external legal
   acceptance before public-repository publication.
4. Existing Swift 6 concurrency diagnostics are technical debt for a future
   language-mode migration. They do not block the current Swift 5 Release build,
   and no new distinct warning class remains from the recent fix set.

### P2

1. Modernize the developer-only Android bridge launcher so it no longer uses a
   fixed local SDK/AVD/serial default.
2. Align Android command-line tools, SDK XML, and Kotlin metadata versions.
3. Add build-phase output declarations and plan the future OpenGL/Metal migration.

## 17. Release Gates

- `ENGINEERING_OPEN_SOURCE_READINESS=READY_WITH_EXTERNAL_GATES`
- `DISTRIBUTION_SIGNING_GATE=READY_FOR_DISTRIBUTION_SIGNING`
- `GITHUB_PUBLICATION_GATE=NOT_READY`
- `FINAL_DMG_GATE=NOT_READY`

The signing gate means the exact engineering source is technically ready to
enter the controlled Developer ID workflow; it does not mean signing was
performed. GitHub and DMG gates are deliberately independent.

## 18. Recommended Next Step

`MAINTAINER_REVIEW_GITHUB_HISTORY_PRIVACY_AND_LICENSE_GATES`

Resolve or explicitly accept those two publication-only external gates before
defining the immutable new release baseline candidate and authorizing the next
controlled distribution-signing run.

## 19. Integrity

- Rewrite history: NO
- Modify/amend old release commit: NO
- Modify `release/0.3.41` reference: NO
- Formal Developer ID signing: NO
- Apple notarization: NO
- Staple: NO
- Final DMG: NO
- Tag: NO
- Push: NO
- Make GitHub public: NO
- GitHub Release: NO

