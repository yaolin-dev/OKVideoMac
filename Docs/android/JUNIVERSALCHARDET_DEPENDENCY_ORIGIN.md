# juniversalchardet 1.0.3 Dependency Origin

Audit date: 2026-08-13

Release: `OKVideoMac 0.3.41 (62)`

Audit baseline: `20a7acaaff1854aa686b6cdfc76ca254651fa5dd`

This report distinguishes current facts, historical facts, and inference. It is
an engineering record, not a license interpretation.

## Current Facts

### Direct declaration

The dependency is declared directly by the local `:catvod` Android library:

```gradle
api "com.googlecode.juniversalchardet:juniversalchardet:1.0.3"
```

It is not transitive, `compileOnly`, or `runtimeOnly`. The application declares
`implementation project(":catvod")`; therefore the `api` dependency is exposed
to `:app` and is present on `releaseRuntimeClasspath`.

Offline Gradle `dependencyInsight` reproduced this graph:

```text
com.googlecode.juniversalchardet:juniversalchardet:1.0.3
\--- project :catvod
     \--- releaseRuntimeClasspath
```

The lock entry is:

```text
com.googlecode.juniversalchardet:juniversalchardet:1.0.3=releaseRuntimeClasspath
```

The exact upstream FongMi commit
`5fdff00a602dc56e8ba756174daef20edab024f2` also declares
`api libs.juniversalchardet` in `catvod/build.gradle`; its version catalog maps
that alias to `com.googlecode.juniversalchardet:juniversalchardet:1.0.3`.

### Current call sites

There are no current imports, descriptors, method calls, reflection strings,
or class-name strings for `org.mozilla.universalchardet` in:

- OKVideoMac Swift, Java, JavaScript, QuickJS resources, assets, and Gradle
  source;
- the local AndroidDexBridge app;
- the copied local `catvod` source;
- the exact FongMi source at commit `5fdff00a...`.

A scan using every public class simple name from the exact binary JAR produced
only unrelated English uses of the word `Constants`; DEX class-owner analysis
found no external APK class referencing the package.

## Historical Facts

The upstream history establishes the original purpose without relying on the
artifact name.

### Introduction

[FongMi/TV commit `4b545153dcfddce027a35174e5ff50f13bdff5f9`](https://github.com/FongMi/TV/commit/4b545153dcfddce027a35174e5ff50f13bdff5f9)
was authored on 2024-05-19 with the subject `Support non utf-8 subtitle`. The
same commit:

- added the direct `api` declaration for juniversalchardet 1.0.3;
- imported `org.mozilla.universalchardet.UniversalDetector`;
- added `Util.utf8(byte[])`, which detected an input byte array's charset and
  converted it to UTF-8;
- routed a local subtitle file through `Path.utf8(...)` before use.

This is direct historical evidence that the library was introduced for local
non-UTF-8 subtitle normalization.

### Follow-up and removal of the call site

[Commit `2632b33e0ed975ba313d1528d090b2143f6f4fdb`](https://github.com/FongMi/TV/commit/2632b33e0ed975ba313d1528d090b2143f6f4fdb)
on 2024-08-24 added UTF-8 BOM removal after detection.

[Commit `6e737cd4b9864ea81fb10d7c956240edead1bb48`](https://github.com/FongMi/TV/commit/6e737cd4b9864ea81fb10d7c956240edead1bb48)
on 2024-08-28, subject `Clean code`, removed:

- the local subtitle conversion call;
- `Path.utf8(...)`;
- `Util.utf8(byte[])` and BOM removal;
- the `UniversalDetector` import.

That commit did not remove the Gradle dependency. The dependency remained in
the exact FongMi commit later copied by OKVideoMac.

## Inference

It is reasonable to infer that the declaration became unused by FongMi's own
tracked source after `6e737cd4`. That makes it a historical-residue candidate.
This is not sufficient evidence that it is safe for OKVideoMac to remove:
FongMi exports the dependency as `api`, and AndroidDexBridge loads external
Spider DEX/JAR code with the APK class loader as parent. The host classpath may
therefore have become an accidental compatibility surface after the original
subtitle call was removed.

The repository call census supports “unused by current visible source.” It
does not support “unused by arbitrary external or protected Spider code.”
