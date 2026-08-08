# ADR 0004: Hybrid Native JVM/Dex Execution

- Status: Accepted
- Date: 2026-07-31

## Context

OKVideoMac currently executes `csp_` Java/Dex spiders in a headless Android
emulator through `AndroidDexBridgeClient`. This preserves broad FongMi
compatibility but requires an Android SDK, ADB, an AVD, an emulator and a
bridge APK.

The current production Spider package is not plain Java. It contains DEX,
Android framework references, Android ARM ELF libraries and JNI entry points
that dynamically produce the actual Spider implementations. It therefore
cannot be made JVM-compatible by bytecode conversion alone.

## Decision

Introduce a runtime-neutral `SpiderExecutionService` and route each Spider
session through a `HybridSpiderExecutionService`.

- A sandboxed macOS XPC service with a bundled JVM will execute packages that
  have passed static capability inspection and Android-oracle conformance
  tests.
- The existing Android bridge remains the fallback for unknown,
  Android-specific or JNI-protected packages.
- An engine is selected once per site session. Calls that share cookies,
  preferences, authorization or proxy state must not cross engines.
- Compatibility is keyed by package SHA-256 and service version. A changed
  package loses native eligibility until it is tested again.
- Android SDK removal is permitted only after the active compatibility corpus
  records zero required fallbacks for 30 consecutive days and all cloud
  authorization providers have native implementations.

## Consequences

- Existing functionality remains available throughout the migration.
- Plain JVM and portable DEX packages can become faster and no longer incur
  emulator startup cost.
- The project must maintain an Android oracle and dual-engine conformance
  suite during the transition.
- Android API shims are implemented only from verified corpus requirements;
  the project will not attempt to recreate the full Android framework.
- Android ELF/JNI packages require a vendor macOS build, a permitted native
  reimplementation or a functionally equivalent replacement configuration.
- The migration takes longer than a direct replacement, but prevents an
  unverified native engine from breaking formal releases.

The execution plan and removal gates are specified in
`../NATIVE_JVM_DEX_MIGRATION_PLAN.md`.

