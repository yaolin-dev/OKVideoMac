# xpp3 1.1.3.3 Remediation

Date: 2026-08-13

## Decision

`xpp3:xpp3:1.1.3.3` is **REPLACEMENT REQUIRED** for compliance purposes and
is excluded from the AndroidDexBridge runtime graph. No replacement artifact
is added: Android already supplies the XML Pull API and parser implementation
needed by Android applications, while `stax:stax:1.2.0` remains available to
the existing Simple XML dependency.

This changes only dependency packaging. It does not change the catvod API,
Sardine API, bridge protocol, or any OKVideoMac playback code.

## Exact-version evidence

- Resolved JAR SHA-256:
  `b14a6716def83417542d5515677d947fecd2597c125f2c82aa9be8792f66b5ee`.
- Exact Maven POM SHA-256:
  `13726683b80def052cb843a746cce5af8d3a1703e845bd40131d4d060b447045`.
- The JAR contains `XPP3_1.1.3.3_VERSION` and is dated 2003-07-01, but contains
  no LICENSE or NOTICE.
- The exact Maven POM contains no license or SCM declaration and Maven Central
  provides no matching source JAR.
- The original-author repository at `https://github.com/aslom/xpp3` preserves
  an Indiana University Extreme! Lab Software License 1.1.1 and a change-log
  entry for `XPP3_1_1_3_3`, but its CVS migration does not preserve the exact
  1.1.3.3 source revision or an immutable source archive.
- Independent historical notices associate 1.1.3.3 with that license, but they
  cannot substitute for the missing exact corresponding source required by
  this project's evidence standard.

The exact artifact is therefore not relabeled as `VERIFIED`.

## Compatibility evidence

- Gradle `releaseRuntimeClasspath` resolves without xpp3 after the scoped
  exclusion on `sardine-android:0.9`; all other resolved versions are retained.
- AndroidDexBridge Release APK builds successfully with Gradle 8.9.
- The experiment APK contains no `org/xmlpull/mxp1` classes or
  `XPP3_1.1.3.3_VERSION` marker.
- APK size changed from 8,099,432 bytes to 8,054,609 bytes (-44,823 bytes).
- The experiment APK installed into an isolated emulator and returned
  `{"ok":true,"version":"0.3.14"}` from the bridge health endpoint.
- A Simple XML parse smoke passed on a classpath containing Simple XML and
  stax but no xpp3 JAR.

The allowlist-gated source smoke tool was also attempted, but its private
`extracted_inventory.json` input is intentionally absent from the isolated
worktree. No result is claimed for that unavailable test.

## Rollback

Remove the scoped Gradle exclusion from
`Helpers/AndroidDexBridge/catvod/build.gradle` to restore the prior graph.
