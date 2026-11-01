# CI: coverage and local verification

[Workflow](../.github/workflows/ci.yml) · [Runs](https://github.com/yaolin-dev/OKVideoMac/actions/workflows/ci.yml) · [Contributing](../CONTRIBUTING.md)

CI runs on pull requests targeting `main`, pushes to `main`, and manual dispatch.
It uses synthetic fixtures and public build dependencies, without Developer ID,
notary credentials, service accounts, private providers or GitHub secrets.
Dependency downloads still require network access; “offline” describes the audit
fixtures, not installation of the CI toolchain.

## Checks and scope

| Check | What runs | Current 0.9.1 validation |
| --- | --- | --- |
| Core (debug), Core (release) | Entire `OKVideoKit` Core/Persistence XCTest suite, separately built and discovered for each configuration | Each: 1,261 discovered, 1,232 passed, 29 declared skips |
| Node | All six `*.test.js` suites selected by `run_node.py`, using the Node test runner | 72 passed, no skips |
| Offline audits and static checks | SourceAudit synthetic tests, crash configuration tests, tiny Mach-O/dSYM symbol gates, CI validator tests, static checks | 52 audit tests (including 7 native launcher cases), 15 crash configuration tests, 7 symbol cases; no skips |
| Android Release JVM and unsigned bridge | Existing locked Gradle Release build and JVM tests in a fresh source copy; verify APK is unsigned | 65 JVM tests, no skips; compile-only APK |
| Main App Release compile and critical flows | Verify unsigned App/helpers, then build an isolated ad-hoc signed Release test host and execute the logical user-flow contract | Three executables plus exact test identities from `Tools/CI/critical-user-flows.json`; zero allowed skips |
| CI required | Aggregate the five job groups, including both Core matrix results | Only exact `success` for every group is accepted |

Counts describe the checked baseline, not a target used to suppress new tests.
Discovery and generated reports are authoritative. Core skips must match the exact
test name and reason in [core-allowed-skips.json](../Tools/CI/core-allowed-skips.json).
They cover existing opt-in/live/resource/worker paths; they are not passed tests.
Empty suites, unexplained skips, missing completions, duplicates, test process
errors and contradictory totals fail the check. Other test suites allow no skips.
The 51 CI validator tests exercise malformed reports, missing work, failure,
cancellation, skipped jobs, Python fixture errors, complete tool installation and generated test-host configuration.

Static checks parse tracked Python, JavaScript, shell and JSON inputs, run actionlint,
require full commit SHA pins for Actions, reject workflow secret references and
scan the CI sources/workflow with the repository artifact scanner. This is syntax
and workflow validation; it does not claim SwiftLint, ShellCheck, Pyflakes, a full
repository secret-history scan or a security audit.

`CI required` is a stable check name for review. Adding it does not enable a GitHub
branch-protection rule; repository protection settings were not changed.

## Toolchain and isolation

- macOS 14 arm64 runners select Xcode 16.2 / Swift 6.0.3. Linux jobs use Ubuntu 24.04.
- Python 3.13.15, Node 22.23.0 and Temurin JDK 17.0.19+10 are selected explicitly.
- actionlint 1.7.12 and XcodeGen 2.46.0 downloads must match the official archive
  SHA-256 values in [tool-downloads.json](../Tools/CI/tool-downloads.json).
  XcodeGen must retain its official `bin/` and `share/xcodegen/SettingPresets/` layout.
  The downloaded launcher executes the verified binary beside those resources;
  version equality alone is insufficient. Before compilation, the App job validates
  both generated test configurations, including `BUNDLE_LOADER` and `TEST_HOST`.
- Android keeps Gradle 8.9, AGP 8.7.3, SDK platform 35 and build-tools 34.0.0 with
  the existing wrapper checksum and dependency locks. It does not load signing inputs.
- Android/App builds copy only tracked regular files to a new directory outside
  the checkout. Ignored local outputs, keys and configuration are not copied.
  Android uses a UTF-8 locale so non-ASCII checkout paths remain valid.
- The App job accepts only the same commit's successful Android test manifest and
  matching APK SHA-256. After unsigned bundle inspection, it launches an isolated
  test host with a separate bundle ID; XCTest startup uses isolated application
  data. It does not run `package-app.sh`, install an App, replace a Desktop app
  or publish a Release. Test hosts and native audit fixtures use ad-hoc signing
  (`codesign -s -`), which requires no signing identity or certificate.

Jobs and subprocesses have finite timeouts. A Core matrix failure does not cancel
its other configuration. Caches are separated by OS/architecture, toolchain and
relevant input hashes; only successful jobs on a `main` push save caches. Tests
still run after a cache hit. Android explicitly reruns tasks without build-cache
results. Toolchain/dependency upgrades must update the corresponding pins and
verification evidence together.

## Local commands

Run from the repository root with the matching toolchain. Use a new output directory
outside the checkout; reports and build products must not be committed. The scripts
record `HEAD`, so use a clean, committed checkout for evidence tied to a commit.

```bash
export DEVELOPER_DIR=/Applications/Xcode_16.2.app/Contents/Developer
export PYTHONDONTWRITEBYTECODE=1
ci_work_dir="$(mktemp -d /tmp/okvideo-ci.XXXXXX)"
python3 Tools/CI/run_python.py --suite ci --output "$ci_work_dir/validators"
python3 Tools/CI/run_core.py --configuration debug --jobs 2 \
  --scratch-path "$ci_work_dir/core-debug-build" --output "$ci_work_dir/core-debug"
python3 Tools/CI/run_core.py --configuration release --jobs 2 \
  --scratch-path "$ci_work_dir/core-release-build" --output "$ci_work_dir/core-release"
python3 Tools/CI/run_node.py --output "$ci_work_dir/node"
python3 Tools/CI/fetch_tool.py actionlint --output "$ci_work_dir/tools"
python3 Tools/CI/run_static.py --actionlint "$ci_work_dir/tools/actionlint" \
  --output "$ci_work_dir/static"
```

Run the complete offline/native audit in a dedicated test environment with no real
OKVideoMac instance running. Its process-isolation guard intentionally rejects an
active App; do not bypass the guard or stop someone else's playback to run it.
GitHub's fresh runner is the normal environment for this check.

```bash
python3 Tools/CI/run_offline.py --actionlint "$ci_work_dir/tools/actionlint" \
  --work-dir "$ci_work_dir/offline-fixtures" --output "$ci_work_dir/offline"
```

For Android/App compilation, install the toolchain and Android SDK listed above,
set `JAVA_HOME` and `ANDROID_HOME` to those installations, and keep the complete
Node distribution (including its `LICENSE`) available on `PATH`:

```bash
export GRADLE_USER_HOME="$ci_work_dir/gradle"
python3 Tools/CI/run_android.py --work-dir "$ci_work_dir/android-build" \
  --output "$ci_work_dir/android" --artifact-dir "$ci_work_dir/bridge-input"
python3 Tools/CI/fetch_tool.py xcodegen --output "$ci_work_dir/tools"
python3 Tools/CI/run_app.py --work-dir "$ci_work_dir/app-build" \
  --dependencies "$ci_work_dir/app-dependencies" --output "$ci_work_dir/app" \
  --bridge-input "$ci_work_dir/bridge-input" --xcodegen "$ci_work_dir/tools/xcodegen"
```

## Critical App user flows

`Tools/CI/critical-user-flows.json` is the reviewed list of test identities. The
`logic` group covers episode navigation (including decoded video with an audio
suffix), history resource matching, refresh/cancel/source replacement, and
playback close/reopen ownership. It runs in the App CI job without requiring a
key window. Fixtures substitute network providers and media decoding.

The `desktop` group drives real AppKit/SwiftUI events and renders production
controls: outside-click dismissal, switching panels, hover/seek coordinates and
preview bounds. Run it on an unlocked GUI session before accepting changes to
these interactions. It is a separate automated local gate, not an assertion that
a dedicated GUI CI runner has been configured. Focus failures are reported as
`desktop-focus-unavailable`; they are never counted as a skip or a successful run.

After preparing the existing Release dependencies/APK and generating the Xcode
project, run from the repository root (use absolute output paths):

```sh
python3 Tools/CI/run_app_regressions.py \
  --derived-data "$regression_work_dir/DerivedData" \
  --output "$regression_work_dir/logic" --group logic \
  --build-setting "OKVIDEOMAC_BUILD_ROOT=$OKVIDEOMAC_BUILD_ROOT" \
  --build-setting "OKVIDEOMAC_SPARKLE_ROOT=$OKVIDEOMAC_BUILD_ROOT/Sparkle"
python3 Tools/CI/run_app_regressions.py \
  --derived-data "$regression_work_dir/DerivedData" \
  --output "$regression_work_dir/desktop" --group desktop --skip-build
```

Use a dedicated DerivedData directory for this test host, separate from unsigned
compile/package builds. Reusing a host with a different bundle identity is
rejected before launch. `--skip-build` requires matching source, executable, test
bundle and test-manifest fingerprints from the preceding build. Use a fresh
report directory for each execution. The test host has a separate
bundle ID, Release optimization, test-only fixture hooks and ad-hoc signing. It
must never replace the Desktop app. The fixture host explicitly omits optional
MPV/QuickJS runtime libraries, matching CI; these groups do not validate decoding
or plugin execution. Complete runtime validation remains a separate Release gate.
Every listed test must start and complete
exactly once; missing tests, duplicates/retries, skips, timeouts, mismatched totals
and nonzero process exits fail the gate. JSON, JUnit, raw logs and xcresult evidence
are retained. To add or rename a critical assertion, update the contract in the
same change; the runner does not silently lower a minimum test count.

## Real media playback journeys

`Tools/CI/media-user-flows.json` defines a separate native-media gate. It uses the
production resolver, AppState, libmpv render surface, and isolated database,
served by a loopback HTTP fixture with byte-range requests, a controlled 503
failure/recovery, and an observed slow request. It covers play, seek, immediate
pause/close, persisted resume, next episode despite a misleading audio suffix,
retry/replacement, and ten native open/seek/close cycles. This is a short lifecycle
regression, not a long-duration memory soak or a claim that external providers pass.

After building the logical host above, run on an unlocked macOS GUI session:

```sh
python3 Tools/CI/run_media_journeys.py \
  --derived-data "$regression_work_dir/DerivedData" \
  --runtime-app "$verified_release_app" \
  --output "$regression_work_dir/real-media"
```

The runner verifies source/test fingerprints and the runtime bundle signature,
copies the test host and pinned native libraries into a fresh output directory,
and signs that disposable host. It never launches or modifies the installed app.
The original logical host stays suitable for CI. Fixture hashes, native-library
hashes, HTTP activity, exact test results, JUnit, and xcresult are retained; focus
failures are failures, never skips. This GUI gate is local until a dedicated
unlocked runner is configured. Hosted CI and minimum-supported macOS validation
remain independent publication gates.

## Reports and failure verification

Each job retains raw command logs, machine-readable summaries and available JUnit
results for seven days, including after a failure. Core records configuration,
toolchain, discovered identities and test-log SHA-256. A build/discovery failure may
have no test XML; the failed JSON summary and command log remain the evidence.
The unsigned APK and test manifest are an internal compile input with one-day
retention, not a release asset or installable deliverable. No App binary is uploaded.
If the APK has expired, rerun the whole workflow rather than only the App job.

Inspect the first failed step and its retained report before retrying. A hosted
runner that never starts supplies no test evidence; queue/capacity cancellation
must not be counted as a pass. Use a new successful run to resolve it. Fix test or
build failures without weakening assertions or the skip policy.

The initial [complete six-job run](https://github.com/yaolin-dev/OKVideoMac/actions/runs/40343489109)
passed. A separate [intentional failure run](https://github.com/yaolin-dev/OKVideoMac/actions/runs/40346059822)
then inserted one failing Core assertion: both configurations reported exactly one
failure, the other jobs passed, and `CI required` rejected the aggregate. The faulty
commit was isolated from the implementation branch. Follow the workflow page for
the current branch's latest result, rather than treating these historical runs as
proof for later changes.

## Remaining limits and formal releases

- This workflow runs the logical critical-user-flow contract, not all macOS App
  XCTest/UI suites. It does not cover AndroidRuntimeKit
  installation tests, real Emulator/ADB/Bridge E2E, actual playback or private
  provider/account flows. It does not establish compatibility on every supported
  macOS version, including the historical macOS 12.5.1 crash path.
- Main App compilation leaves the existing optional libmpv/QuickJS native artifacts
  unbuilt. Their runtime behavior and a complete distributable bundle require the
  existing release build and playback verification.
- Existing AGP 8.7.3 lint metadata analysis emits diagnostics for Kotlin 2.2 metadata
  in locked dependencies. Release assembly and JVM tests pass, and the Android
  summary records these diagnostics. Full dependency lint coverage is **not**
  established; resolving this requires a separately verified Android toolchain
  upgrade, not suppressing the warnings or changing locks during CI setup.
- Developer ID, Hardened Runtime, Apple Accepted notarization, staple, Gatekeeper,
  installation and public artifact/source integrity remain required by the
  [formal release process](SOURCE_RELEASE_PROCESS.md). CI success is not release
  approval. These CI/test/documentation changes leave App 0.9.0 / Build 155 and its
  existing signed release assets unchanged.
