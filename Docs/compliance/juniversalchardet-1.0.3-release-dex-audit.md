# juniversalchardet 1.0.3 Release APK / DEX Audit

Status: `PRESENT_IN_RELEASE_DEX`

Date: 2026-08-13

This is a factual binary inventory, not a legal opinion.

## Exact Release artifact

- Source baseline: commit `1552e51df9bc42aa7832e0ed3816e4dc96d7b88f`.
- Final build output path:
  `OKVideoMac/Helpers/AndroidDexBridge/app/build/outputs/apk/release/app-release.apk`.
- Final packaged/installed Release path:
  `/Users/linyao/Desktop/OKVideoMac.app/Contents/Resources/AndroidDexBridge-release.apk`.
- The Gradle output and packaged app copy were byte-identical after the final
  clean Release rebuild.
- Final APK SHA-256:
  `59ee18fa061bad09bf60b8836e3be141878b7b0167987af6228386173072a845`.
- The pre-audit Phase 2 APK had SHA-256
  `5a46aec0bcdd9fc446cfeb1e3ddc3d97b1b2de7978ad88b8283d78fec2f20af7`;
  its two DEX entries are byte-identical to the final rebuild. The APK-level
  hash changed only at the outer signed/ZIP container level.
- App Release: `OKVideoMac 0.3.41 (62)`.
- Android build type: `release`, `minifyEnabled false`.

## DEX payload

| Entry | Bytes | SHA-256 | Defined classes |
|---|---:|---|---:|
| `classes.dex` | 8,494,012 | `a317f2f8af8ce79e5f6a02efc0bf2f2f9e126d50686bcf597fcff98ac303e9ea` | 7,439 |
| `classes2.dex` | 7,624,588 | `332360b30f2dd6393493b0bda7860d9769f901dfb4177f2fd8b816b215f4f0c7` | 6,599 |

Android SDK build-tools 36.0.0 `dexdump` was used to emit XML class
inventories and plain disassembly. All 62 class files from the exact binary
JAR appear unchanged in package/class identity in `classes2.dex`. None appear
in `classes.dex`. The complete list is in
`juniversalchardet-1.0.3-release-dex-classes.txt`.

The exact binary JAR contains 62 class files under
`org/mozilla/universalchardet/`; a sorted comparison against the DEX inventory
had no additions or omissions. The 62 classes correspond to all 58 Java source
entries plus four compiler-generated inner/enum classes. This is full-library
inclusion, not partial retention.

## Reference scan

The disassembly was scanned by class section for descriptors and strings
containing `org/mozilla/universalchardet`. Results:

- `classes.dex`: zero occurrences;
- `classes2.dex`: 62 owning class sections, all themselves within
  `org.mozilla.universalchardet`;
- external APK class sections with a static descriptor, invocation, field,
  string, or reflective-name reference: zero.

The repository production sources, the exact FongMi commit archive, and the
two Java/Dex Spider JARs referenced by this machine's saved configurations
were also scanned. None contained a static or reflective reference to the
package. The two configuration JARs were MD5-pinned and verified before DEX
inspection:

| Configuration artifact | MD5 | SHA-256 | Reference result |
|---|---|---|---|
| Wex package | `8af3bd6512cac8c518a4c6d65c9f6539` | `f4eb80fcfb009b59efa811153d4705755324c68d7a4f281dcbd51642a9ca6744` | None |
| Dianbo package | `9d90c83bc7504392dd02c2236f08713a` | `6a7442551dad7ac0bde979655fd95644ac695039848918a32240809146d7d15d` | None |

## Packaging relationship

Gradle `dependencyInsight` shows the locked module is a direct `api`
dependency of project `:catvod`, inherited by the app's
`releaseRuntimeClasspath`. D8 merges it into the same APK and same
multidex application as GPL-3.0 FongMi/catvod and local bridge classes. The 56
`com.github.catvod` classes and 19 local bridge classes are in `classes.dex`;
the 62 juniversalchardet classes are in `classes2.dex`. They are therefore in
the same APK and application/class-loader graph, but not the same individual
DEX file. There is no JAR boundary, relocation, shading, source copying,
source modification, separate process, IPC boundary, or build-tool-only use
for this component.

The bridge does, however, use `DexClassLoader` at runtime to download arbitrary
configuration-selected CatVod Spider JARs with the APK's class loader as
parent. This means the host's exported runtime classes can be consumed by a
future external Spider even though no audited current caller was found. That
open-ended host-contract risk is the reason zero current references alone do
not establish `REMOVE_SAFE`.
