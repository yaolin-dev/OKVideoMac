# OKVideoMac 0.3.41 (62) Developer ID / Notarization Release Audit

Date: 2026-08-14 (Asia/Shanghai)

Final status: **BLOCKED_BEFORE_NOTARIZATION**

Preflight gate: **PRECHECK BLOCKED**

No Release build, Developer ID signing, Apple submission, staple, formal
Gatekeeper assessment, DMG creation, tag, push, GitHub Release, or Desktop App
replacement was performed after this gate failed.

## 1. Release identity

| Item | Observed value |
| --- | --- |
| Repository | `/Users/linyao/Documents/ok影视 mac 版本` |
| Current branch | `codex/mpv-teardown-ab-experiment` |
| Current HEAD | `557c3c90051b9867e84c4de78bddce1bd62be93c` |
| Intended release branch | `release/0.3.41` |
| Intended branch HEAD | `713ba7337525a6aa450b67b3550d98b8d3eebdea` |
| Relationship | current HEAD is 21 commits behind `release/0.3.41`; it is not ahead |
| Marketing version | `0.3.41` |
| Build | `62` |
| Release architecture | `arm64` |
| Deployment target | macOS 12.0 |

The initial worktree was not clean. It contained ten modified AppIcon PNGs and
the pre-existing untracked report
`Docs/EXTERNAL_RELEASE_GATE_AUDIT_0.3.41_62.md`. No existing change was reset,
stashed, deleted, staged, or committed.

## 2. App Icon baseline

The project maps `ASSETCATALOG_COMPILER_APPICON_NAME` to `AppIcon`, and the
bundle metadata maps `CFBundleIconFile` and `CFBundleIconName` to `AppIcon`.
The asset catalog contains the complete 16 through 1024 pixel macOS icon set.

The latest working-tree icon has **not** entered Git HEAD. All ten icon PNGs
are modified. The representative 1024 pixel source hashes are:

| Baseline | SHA-256 of `icon_512x512@2x.png` |
| --- | --- |
| Current HEAD `557c3c9` | `84ccb4d56f0cd32190797f8f19e2e75165bc6c477324ff2b3fff84b11cdd895d` |
| `release/0.3.41` / `713ba733` | `1b795d144d5d0244b109e97380d91af7dc48965e0a8eb3993c85968dd6becd3d` |
| Current working tree | `1052904f4449615f5f74fd849e4132505029977e299a1afdd1c830c305e7f093` |

The existing local App artifact contains both `AppIcon.icns` and `Assets.car`,
but it is an ad-hoc artifact and there is no immutable Git commit that identifies
the working-tree icon used to create it. Consequently the required equality
`latest source icon == formal Release artifact icon` cannot be proven for a
Developer ID candidate.

The previous release baseline `713ba7337525a6aa450b67b3550d98b8d3eebdea`
is therefore invalid as the final publication commit if the current working
icons are the intended latest icon. A new exact commit cannot be stated until
the owner deliberately integrates those icon files into the release branch.

## 3. Release pipeline audit

The `release/0.3.41` pipeline is structurally suitable for the Apple signing
phase once the source baseline is frozen:

- clean Xcode Release build with `CODE_SIGNING_ALLOWED=NO` before packaging;
- `arm64`, Hardened Runtime, and secure timestamp in distribution mode;
- explicit inside-out signing; `--deep` is verification-only;
- empty/minimal main Release entitlement file;
- Node alone receives `com.apple.security.cs.allow-jit`;
- QuickJS receives no JIT or unsigned-executable-memory entitlement;
- distribution verification rejects ad-hoc code, Team ID mismatches,
  missing runtime flags, and `disable-library-validation`;
- notarization uses a ZIP, followed by App staple, validation, required
  Gatekeeper assessment, and archive recreation after stapling.

No audited DMG creation script was found. The current formal pipeline emits
`OKVideoMac-<version>-macOS-arm64.zip`. Since the requested READY gate requires
a final DMG, an audited DMG workflow still needs an explicit release decision;
none was invented during this run.

## 4. Android Bridge / APK

The current local Release APK and the APK embedded in the existing App are
byte-identical:

- SHA-256: `0ef35575005620cccd2a927d31915f3e0b090cf4a877581d5f49007d32a70576`
- size: `8,099,432` bytes
- debuggable: `false`
- target SDK: `27`
- version name: `0.3.14`

No Android Bridge file was modified. The packaging pipeline continues to copy
the Release APK into `AndroidDexBridge-release.apk`; no Debug APK is allowed.

## 5. Developer ID environment

Read-only Keychain inspection found exactly one valid code-signing identity:

`Developer ID Application: Yao Lin (KGG363ABK9)`

Identity SHA-1: `D604D626E220F2290C35D94AA025D30C3B9E0EB9`

Certificate details:

| Item | Value |
| --- | --- |
| Certificate type | Developer ID Application |
| Authority | `Developer ID Application: Yao Lin (KGG363ABK9)` |
| Team ID | `KGG363ABK9` |
| Issuer | Apple Developer ID Certification Authority G2 |
| Valid from | 2026-08-14 04:41:09 UTC |
| Valid until | 2031-08-15 04:41:08 UTC |
| Trust chain | Developer ID Application -> Developer ID Certification Authority -> Apple Root CA |
| System trust verification | successful; revocation checked |

No private key, `.p12`, password, Keychain credential, or other secret was
read, copied, exported, or recorded.

## 6. Existing signed artifact (local evidence only)

Existing local artifact:

`/Volumes/XcodeDev/OKVideoMacBuild/Artifacts/OKVideoMac.app`

This artifact is **not** the requested distribution candidate. It is version
0.3.41 (62), contains 28 Mach-O objects, and all 28 are thin arm64 with
Hardened Runtime. Strict deep signature verification passed, but every object
is ad-hoc signed with no TeamIdentifier. Node contains only `allow-jit`;
QuickJS contains no entitlement.

Therefore the Developer ID result for this run is **NOT EXECUTED**, not PASS:

- Developer ID Authority: not present on candidate;
- Team ID verification across nested objects: not executed on a formal build;
- secure timestamp verification: not executed;
- distribution entitlement verification: not executed;
- final signed artifact: not created.

The 28-object local inventory matches the prior expected count, but it is only
historical/local pipeline evidence and cannot satisfy the formal signing gate.

## 7. Notarization

Keychain profile: `OKVideoMac-Notary`

Read-only authentication check result:

`No submission history.`

Authentication therefore succeeded without exposing credentials. Because the
Preflight gate failed, nothing was uploaded.

| Item | Result |
| --- | --- |
| Submission ID | not created |
| Upload result | not executed |
| Processing result | not executed |
| Final Apple status | not submitted |

## 8. Staple and Gatekeeper

| Gate | Result |
| --- | --- |
| `stapler staple` | not executed |
| `stapler validate` | not executed |
| formal `spctl --assess --type execute` | not executed |
| Notarized Developer ID source | not available |

These operations were deliberately withheld because there is no accepted
notarization submission and no formal Developer ID candidate.

## 9. Final artifact

| Item | Result |
| --- | --- |
| Formal `.app` path | not created |
| Final `.dmg` path | not created |
| Final DMG size | not available |
| Final DMG SHA-256 | not available |

The existing local `.app` and ZIP must not be relabeled or uploaded as the
formal release artifact.

## 10. Gate decision and next release action

Final status: **BLOCKED_BEFORE_NOTARIZATION**

Blocking facts:

1. The active branch is not `release/0.3.41` and is 21 commits behind it.
2. The worktree is dirty.
3. The latest App Icon is not present in current HEAD and differs from the icon
   in `713ba733`.
4. No exact immutable commit currently represents both the intended release
   source and the latest icon.
5. No audited DMG workflow exists, while the requested READY definition
   requires a DMG.

Recommendation: **do not create `v0.3.41` now**. First, deliberately integrate
the intended icon into `release/0.3.41` without losing the user's work, freeze
a clean new release commit, and decide or audit the DMG workflow. Then rerun the
entire clean build, Developer ID signing, 28-object audit, runtime smoke test,
notarization, staple, Gatekeeper, and final hash gates from that exact commit.

