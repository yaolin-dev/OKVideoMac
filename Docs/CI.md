# CI: coverage and local verification

[Workflow](../.github/workflows/ci.yml) · [Runs](https://github.com/yaolin-dev/OKVideoMac/actions/workflows/ci.yml) · [Contributing](../CONTRIBUTING.md)

CI runs on pull requests targeting `main`, pushes to `main`, and manual dispatch.
It uses synthetic fixtures and public build dependencies, without Developer ID,
notary credentials, service accounts, private providers or GitHub secrets.
Dependency downloads still require network access; “offline” describes the audit
fixtures, not installation of the CI toolchain.

## Checks and scope

| Check | What runs | Baseline after 0.9.0 |
| --- | --- | --- |
| Core (debug), Core (release) | Entire `OKVideoKit` Core/Persistence XCTest suite, separately built and discovered for each configuration | Each: 1,233 discovered, 1,204 passed, 29 declared skips |
| Node | All five `*.test.js` suites selected by `run_node.py`, using the Node test runner | 55 passed, no skips |
| Offline audits and static checks | SourceAudit synthetic tests, crash configuration tests, tiny Mach-O/dSYM symbol gates, CI validator tests, static checks | 51 audit tests (including 7 native launcher cases), 15 crash configuration tests, 7 symbol cases; no skips |
| Android Release JVM and unsigned bridge | Existing locked Gradle Release build and JVM tests in a fresh source copy; verify APK is unsigned | 45 JVM tests, no skips; compile-only APK |
| Main App Release compile (unsigned) | Existing project and dependency scripts, main App plus preview/relaunch helpers, arm64 Release | Three executables; validate version/build, empty service configuration and embedded APK hash |
| CI required | Aggregate the five job groups, including both Core matrix results | Only exact `success` for every group is accepted |

Counts describe the checked baseline, not a target used to suppress new tests.
Discovery and generated reports are authoritative. Core skips must match the exact
test name and reason in [core-allowed-skips.json](../Tools/CI/core-allowed-skips.json).
They cover existing opt-in/live/resource/worker paths; they are not passed tests.
Empty suites, unexplained skips, missing completions, duplicates, test process
errors and contradictory totals fail the check. Other test suites allow no skips.
The 28 CI validator tests exercise malformed reports, missing work, failure,
cancellation, skipped jobs, and Python fixture errors.

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
- Android keeps Gradle 8.9, AGP 8.7.3, SDK platform 35 and build-tools 34.0.0 with
  the existing wrapper checksum and dependency locks. It does not load signing inputs.
- Android/App builds copy only tracked regular files to a new directory outside
  the checkout. Ignored local outputs, keys and configuration are not copied.
  Android uses a UTF-8 locale so non-ASCII checkout paths remain valid.
- The App job accepts only the same commit's successful Android test manifest and
  matching APK SHA-256. It does not run `package-app.sh`, launch the App, install it,
  replace a Desktop app or publish a Release. Native audit fixtures use ad-hoc
  signing (`codesign -s -`), which requires no signing identity or certificate.

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

- This workflow does not run all macOS App XCTest/UI suites, AndroidRuntimeKit
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
