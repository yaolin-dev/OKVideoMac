# 03 — Build and DEX Relationship

## FACT

1. `catvod/build.gradle` declares juniversalchardet 1.0.3 as a direct `api`
   dependency.
2. Dependency locking fixes it to 1.0.3 for `releaseRuntimeClasspath`.
3. `:app` depends on project `:catvod`.
4. The Release build has `minifyEnabled false`; R8/ProGuard shrinking does not
   remove unused library classes.
5. D8 converts the exact binary JAR into the APK's multidex payload.
6. The binary JAR's 62 classes exactly match the 62
   `org.mozilla.universalchardet` classes in `classes2.dex`.
7. GPL-3.0 FongMi/catvod and local bridge classes reside in `classes.dex`.
8. The two groups are in one APK and Android application/class-loader graph,
   but not the same individual DEX file.
9. No APK-owned static descriptor, method invocation, field, reflective class
   name, or package-name string references juniversalchardet.
10. There is no shading, relocation, source copying, source modification,
    separate process, IPC boundary, external executable, or build-time-only
    role for juniversalchardet.
11. The bridge uses `DexClassLoader` with the APK class loader as parent to
    execute external configuration-selected Spider JARs.

Exact binary inventory:
`Docs/compliance/juniversalchardet-1.0.3-release-dex-audit.md`.

## ENGINEERING INFERENCE

The library is presently packaged because shrinking is disabled and it is on
the runtime graph, not because an audited tracked caller requires it. Its
remaining engineering purpose is compatibility insurance for dynamically
loaded Spider packages that may expect FongMi's exported host dependencies.

## LEGAL REVIEW REQUIRED

Counsel must determine the legal significance, if any, of one APK with the
covered classes and GPL classes in separate DEX entries but a shared Android
application and class-loader graph.

