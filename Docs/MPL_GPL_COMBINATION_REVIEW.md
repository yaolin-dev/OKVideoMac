# juniversalchardet 1.0.3 / GPL-3.0 APK Combination Review

Status: **Needs legal review**

Date: 2026-08-13

This document records technical facts for counsel. It does not select a
license alternative or make a legal compatibility conclusion.

## Exact artifact and covered source

- Runtime coordinate: `com.googlecode.juniversalchardet:juniversalchardet:1.0.3`.
- Runtime JAR SHA-256:
  `757bfe906193b8b651e79dc26cd67d6b55d0770a2cdfb0381591504f779d4a76`.
- Maven POM SHA-256:
  `7846399b35c7cd642a9b3a000c3e2d62d04eb37a4547b6933cc8b18bcc2f086b`.
- Exact sources JAR SHA-256:
  `3d1cb067f5cfe3cc19b77c837156f22368462af9acac5dd878e785966758fc27`.
- The POM declares MPL-1.1. Fifty-seven of the 58 Java files carry the
  historical MPL-1.1/GPL-2.0-or-later/LGPL-2.1-or-later alternative notice;
  `Constants.java` has no file header. No project modification to these files
  was identified.
- `ThirdParty/juniversalchardet-1.0.3-covered-files.txt` enumerates the exact
  source entries. The complete, unmodified sources JAR and MPL-1.1 text are
  included in the third-party source and license archives.

## Artifact and file boundary

Gradle resolves the unmodified Maven JAR as a runtime dependency of the
`catvod` Android library. D8 converts its Java class files and the project and
other dependency class files into the APK's `classes.dex`/`classes2.dex`.
There is no separate JAR at runtime and no process, IPC, plugin, or dynamic
class-loader boundary between catvod and juniversalchardet.

The corresponding Java file boundary remains identifiable by the package
prefix `org.mozilla.universalchardet`. The binary JAR contains class outputs
for all 58 entries in the covered-file list, including compiler-generated
inner classes. The project does not copy, edit, or merge juniversalchardet
source files at source level.

## GPL-3.0 combination context

The same APK contains copied and modified FongMi/TV catvod code distributed by
this project under GPL-3.0. The classes are merged into the same DEX payload at
build time. The APK notice identifies both the GPL catvod source and the
juniversalchardet license/source. The release bundle provides:

1. exact project and modified catvod source;
2. exact FongMi upstream commit source subset and change notice;
3. the complete juniversalchardet 1.0.3 sources JAR and covered-file list;
4. GPL-3.0, MPL-1.1 and the artifact's retained file notices;
5. the Gradle dependency lock and build instructions.

## Question reserved for counsel

Counsel should confirm the appropriate license-election and notice treatment
for distributing the tri-licensed files in the same DEX payload as GPL-3.0
code, with particular attention to the headerless `Constants.java` and the
POM's MPL-only declaration. Until that review is complete, the combination is
not represented as legally cleared even though exact covered source is
delivered.
