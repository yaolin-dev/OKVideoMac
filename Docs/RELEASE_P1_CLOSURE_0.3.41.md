# OKVideoMac 0.3.41 (62) P1 Release Closure

Date: 2026-08-13

Final engineering decision: **READY_FOR_DISTRIBUTION_SIGNING**

This report closes only P1-01 and P1-02 from the External Release Gate Final
Audit. It is an engineering/release-facts record, not legal advice. No new
architecture, dependency, player, performance, or legal review was performed.

## Executive Summary

- P1-01 — No single frozen public-release commit/tag: **CLOSED**
- P1-02 — First-public-release documentation is incomplete: **CLOSED**
- P0 count: **0**
- P1 count: **0**
- P2 count: **4**
- Product/runtime code changes in this closure: **NONE**
- Apple credential gate: **EXTERNAL GATE**
- Independent Legal Review: **NOT PERFORMED**
- juniversalchardet: **KEEP_FOR_COMPATIBILITY**
- Known license status: **DOCUMENTED LICENSE INTERPRETATION RISK**

No new P0/P1 fact was found during the targeted closure. Non-blocking
engineering/compliance remediation for 0.3.41 (62) ends here.

## Frozen Release Baseline

| Item | Frozen value |
| --- | --- |
| Branch | `release/0.3.41` |
| Exact release commit | the commit containing this report, resolved by `git rev-parse release/0.3.41^{commit}` and recorded in the release handoff before signing |
| Version/build | `0.3.41 (62)` |
| Architecture | `arm64` |
| Minimum macOS | `12.0` |
| Intended tag | `v0.3.41` |
| Phase 4 baseline | `3c87aa07acd8d0d5a3ef32f0e5fdaf35c408ad59` |
| Phase 4/common fork point | `20a7acaaff1854aa686b6cdfc76ca254651fa5dd` |
| juniversalchardet audit source | `cd72101dc45543418178900062c963e9e1c3291b`, `af4ba948f58572cd5df07ec52a97864b0efab07a` |
| Integrated equivalents | `0068325` and `ee67611` on `release/0.3.41` |

Git commit IDs are content-derived, so a tracked report cannot literally embed
the SHA of the commit that contains itself. The authoritative exact SHA is the
clean `release/0.3.41` HEAD reported by the final handoff and, after the Apple
external gate, the commit peeled from annotated tag `v0.3.41`. A moving branch
is not the publication identity; the future immutable tag/exact commit is.

The annotated tag is deliberately deferred until the Developer ID signed,
notarized, stapled artifact has passed final verification. This prevents an
immutable tag from being attached before the last fail-closed distribution
gate. No existing `v0.3.41` or `0.3.41` tag was present or overwritten.

## Integration Details

The actual DAG was inspected independently. Phase 4 and the charset audit
diverged after `20a7aca`.

Phase 4 unique commits retained as the release base:

- `5aca687`: playback regression evidence documents only;
- `e07ff95`: compliance, Apple gate, readiness, NOTICE documents only;
- `008a1e1`: release packaging/bundle/source-release/secret-scan sealing;
- `3c87aa0`: final Phase 4 engineering readiness report.

The two charset audit commits were inspected before integration:

- `cd72101` added `Docs/android/CHARSET_RESOLUTION_MAP.md`,
  `Docs/android/JUNIVERSALCHARDET_DEPENDENCY_ORIGIN.md`,
  `Docs/android/SPIDER_CHARSET_COMPATIBILITY_CENSUS.md`, and standalone audit
  harness `Tools/SourceAudit/CharsetDetectorComparison.java`;
- `af4ba94` added `Docs/JUNIVERSALCHARDET_ELIMINATION_AUDIT.md`.

They were cherry-picked rather than merged because both commits are wholly
inside the allowed audit documentation/compatibility evidence/harness scope.
The standalone Java harness is outside Gradle source sets and is not linked
into AndroidDexBridge or the Release APK. No other branch content was brought
in. A merge would have obscured the minimal integration boundary and manual
copying would have weakened commit-level provenance.

The main worktree's pre-existing untracked
`Docs/EXTERNAL_RELEASE_GATE_AUDIT_0.3.41_62.md` was read as audit input and left
untouched. This closure report is the tracked final P1 disposition.

## Documentation Closure

- Installation: **CLOSED** — official GitHub Release download, extraction,
  `/Applications` installation, and normal launch are documented.
- Gatekeeper: **CLOSED** — Developer ID/notarization/staple target and safe
  Control-click/Open or Privacy & Security/Open Anyway recovery are documented;
  no system-security disabling guidance is given.
- Native Mode: **CLOSED** — XML/JSON/Base64, live/XMLTV, QuickJS, Node and
  native playback boundaries are documented without requiring Android.
- Android Compatibility: **CLOSED** — optional Java/Dex `csp_` compatibility,
  external SDK/ADB/emulator requirements, Experimental status and manual path
  caveat are documented.
- Issue reporting: **CLOSED** — required environment/reproduction/result/log
  fields and sensitive-data exclusions are in README and the issue template.
- Contributing: **CLOSED** — focused PR, secret, provenance, dependency and
  relevant verification rules are in `CONTRIBUTING.md`.
- Security: **CLOSED** — no fictitious contact is supplied; sensitive reports
  use a non-sensitive public summary pending maintainer instructions.
- Binary/source verification: **CLOSED** — source index, mapping, manifest,
  SHA256SUMS, four SBOMs, exact APK, project/third-party/license archives and
  exact tag/commit rule are documented with their real generated names.
- Known risks: **CLOSED** — Android environment, broad media/performance matrix,
  open-ended Spider compatibility, trusted Node input, and the documented
  juniversalchardet risk are visible from the public entry point.
- BUILDING stale statement: **CLOSED** — the historical pre-build state is
  preserved as history while the Phase 4 verified environment and fresh-audit
  network/storage caveats are stated accurately.

## Files Changed by P1 Closure

- `OKVideoMac/README.md`
- `OKVideoMac/macOS/OKVideoMac/Docs/BUILDING.md`
- `CONTRIBUTING.md`
- `SECURITY.md`
- `.github/ISSUE_TEMPLATE/bug_report.md`
- `Docs/RELEASE_P1_CLOSURE_0.3.41.md`

The two cherry-picked audit commits additionally add the five audit/harness
files listed in Integration Details.

## Runtime No-Change Statement

本轮未修改播放器、UI、Spider runtime、Android Bridge runtime、依赖版本、
native binaries、APK behavior、signing architecture、Hardened Runtime
architecture 或 performance policy。

No dependency lock, Gradle dependency, entitlement, package script behavior,
SBOM dependency content, third-party license interpretation, or Git history was
rewritten. juniversalchardet remains in the runtime graph unchanged.

## Targeted Verification

The closure gate requires and records:

- clean release worktree and unique `release/0.3.41` HEAD;
- branch, HEAD, worktree, log graph and tag inventory;
- diff against Phase 4 and the charset audit branch;
- changed-path classification confirming no product/runtime/dependency path;
- README coverage for install, Gatekeeper, Native Mode, optional Android
  compatibility, issue reporting, contributing, security, binary/source
  verification, known risks and legal-review wording;
- version `0.3.41`, build `62`, minimum macOS `12.0`, architecture `arm64`;
- documentation status check, whitespace/link/reference checks, and Release
  packaging from the clean exact commit.

The exact command outputs and final commit SHA are recorded in the release
handoff. Apple credential-dependent results are not claimed by this report.

## Remaining P2

1. **P2-01 — Historical developer paths:** reachable old commits contain
   non-secret developer paths. Current release HEAD remains sanitized and the
   prior secret scan remains PASS. No history rewrite is authorized.
2. **P2-02 — Android path portability:** optional Android compatibility still
   has `/Volumes/XcodeDev` defaults and may need manual SDK/runtime path
   configuration. Native Mode does not require Android.
3. **P2-03 — CI/environment resilience:** local Xcode/MacPorts/Android tooling,
   Google Maven TLS availability and external-volume health affect fresh
   reproducibility. No CI/bootstrap redesign is part of this release closure.
4. **P2-04 — Desktop App FinderInfo:** the pre-existing Desktop copy is not a
   release source and is not modified in this closure. Only controlled
   packaging output may become a distribution artifact.

These remain P2 and do not block entry to distribution signing.

## External Gates

The following are not performed or claimed in this P1 closure:

- Developer ID Application certificate availability;
- signing with a real Team ID;
- secure timestamp validation;
- Apple notarization acceptance;
- staple and `stapler validate`;
- Gatekeeper `spctl --assess --type execute` acceptance;
- post-staple ZIP recreation and final hashes;
- annotated immutable tag creation;
- GitHub Release publication.

Current known host state remains Developer ID Application identities `0` and
notary profile unavailable. The distribution workflow must fail closed and no
ad-hoc package may be represented as Developer ID signed or notarized.

## Exact Next Distribution Action

After installing a real Developer ID Application identity and configuring a
valid `notarytool` keychain profile, run from the clean frozen release commit:

```bash
export DEVELOPER_ID_APPLICATION='Developer ID Application: <legal name> (<TEAM_ID>)'
export OKVIDEOMAC_NOTARY_PROFILE='<notarytool-keychain-profile>'
OKVideoMac/macOS/OKVideoMac/Scripts/package-app.sh \
  --mode distribution \
  --notarize
```

Then require Team ID equality, secure timestamp, notarization acceptance,
staple validation, Gatekeeper acceptance, bundle/SBOM verification, and final
post-staple hash regeneration. If and only if all pass without source changes,
create the annotated `v0.3.41` tag with message `OKVideoMac 0.3.41 (62)`, verify
that it peels to the frozen release commit, and publish the one-shot immutable
artifact set. Do not push or create a GitHub Release as part of this closure.

## Final Decision

P1-01 and P1-02 are closed with no new P0/P1 finding and no runtime/product
change. Engineering state: **READY_FOR_DISTRIBUTION_SIGNING** —
**ENGINEERING RELEASE READY; APPLE EXTERNAL GATES REMAIN**.
