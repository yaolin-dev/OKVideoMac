# OKVideoMac Open Source Compliance Re-audit — Phase 2

Date: 2026-08-13

Release: OKVideoMac 0.3.41 (62)

Baseline: `Docs/THIRD_PARTY_LICENSE_AUDIT.md` (preserved unchanged)

Final rating: **Blocked**

This rating is intentionally not raised: three genuine release P0s remain.
The Phase closed the xpp3 distribution and icon-rights P0s without weakening
evidence standards, and implemented local immutable source artifacts, but did
not publish them. It did not replace the stable native binaries.

## Required answers

| # | Question | Phase 2 result |
| --- | --- | --- |
| 1 | xpp3 final license | **Not established for exact 1.1.3.3**. Its license remains unresolved as historical evidence, and the artifact is excluded from the Release APK. |
| 2 | Exact xpp3 evidence | Exact JAR SHA `b14a6716…b5ee`, POM SHA `13726683…7045`, no exact sources JAR/SCM/license; upstream and archives did not bind exact source. Result: `REPLACEMENT REQUIRED`, resolved for distribution by exclusion after isolated build/emulator health checks. |
| 3 | App icon rights chain | **VERIFIED OWNED for release provenance**: retained no-input ImageGen source, exact prompt/date/tool record, master, generated sizes and SHA-256 values. Copyrightability/AI-law interpretation remains for counsel. |
| 4 | Immutable corresponding source | `create_source_release.py` deterministically produces project, third-party and license tarballs, source index, outer binary-bound manifest and SHA256SUMS from the exact clean commit. |
| 5 | mpv exact source mapping | mpv v0.41.0 archive SHA `ee21092a…6209`, local patch SHA `f57fa49d…af9f`, Meson options, recipe and notes are included and bound by the release manifest. |
| 6 | APK exact GPL source mapping | Manifest binds the exact APK to project AndroidDexBridge source, dependency lock, exact FongMi commit `5fdff00a…`, source-only upstream subset, local catvod source and change notice. |
| 7 | MPL covered source | juniversalchardet 1.0.3 sources JAR SHA `3d1cb067…fc27`, 58-file boundary and MPL-1.1 text are included in the third-party source archive. Combination remains **Needs legal review**. |
| 8 | FFmpeg reproducible provenance | Exact 7.1.4 source and functional recipe reproducibility passed; ABI, sonames, symbol sets, LGPL configuration and decoder capability smoke matched. Original batch/bit-for-bit provenance is **PARTIAL**. |
| 9 | Native libraries verified | Eleven components have exact MacPorts receipts, retained matching Portfiles and locked source hashes; FFmpeg additionally has a successful locked recipe rebuild. |
| 10 | Native libraries partial | libass/HarfBuzz have source locks but pending full-chain recipes; zlib lacks the original exact archive; libc++/libc++abi lack their historical clang-11 input; all stable-batch binaries lack original logs/environment replay. |
| 11 | Unresolved | Yes: historical libc++ source input, zlib exact archive, public source publication and MPL/GPL legal review. No unresolved-license artifact remains in the generated APK. |
| 12 | Player behavior change | Stable player binaries were not replaced. The experimental chain passed ABI/capability/launch smokes only; interactive playback behavior was not claimed. |
| 13 | Performance | Not measured against the user-required real playback/live fixture matrix; no claim of equivalence. This prevents native replacement. |
| 14 | SBOM components | macOS: 28 Mach-O components. Android: 89 components (AndroidDexBridge, exact FongMi source component, 87 locked Maven modules). |
| 15 | Actual App vs SBOM | Enforced by `verify_sbom.py`: exact 28-path equality, nested hashes and exact Gradle coordinate/version equality. Unknown/new dylibs fail packaging. |
| 16 | LGPL replacement | Replacing `libavutil.59.dylib` invalidated the signature as expected; guarded ad-hoc re-sign of dylib, main and App passed deep verification and LaunchServices health. **Needs legal review**. |
| 17 | Developer ID | Not executed: audit host has zero valid code-signing identities. |
| 18 | Notarization | Not executed: no Developer ID identity or configured notary profile. |
| 19 | Staple | Not executed because no notarized ticket exists. |
| 20 | Gatekeeper | A final Developer ID/notarized Gatekeeper result is unavailable. Ad-hoc verification is not treated as equivalent. |
| 21 | Legal payload | Packaging requires LICENSE, notices, 30+ license/notice texts, modification notices, mappings, source index, native lock/report, four SBOMs and this re-audit. Final completeness is verified during packaging. |
| 22 | Binary/source hash binding | Implemented locally: the final ZIP must contain the byte-identical source index and exact APK; outer manifest and SHA256SUMS bind ZIP, source archives, licenses and SBOMs. Public immutable upload remains pending. |
| 23 | Sensitive information | Current tracked/current-tree scans found no private-key marker or credential. One private HOME path in an old inventory was normalized; source archives exclude `AGENTS.md`. History retains only non-secret path evidence. Test `expired-stoken` strings are deliberate invalid fixtures. |
| 24 | Remaining P0 count | **3**: immutable public publication, complete native provenance/manual regression, and MPL/GPL legal review. |
| 25 | Final rating | **Blocked**. |
| 26 | Commits | Phase 1 `557c3c9`; Phase 2A `8e05a3d`; Phase 2B `ede51bf`; Phase 2C `22fda60`; Phase 2D is the commit containing this report. |
| 27 | Rollback | Revert Phase 2 commits in reverse order with `git revert <commit>`; do not reset or rewrite the Phase 1 baseline. |
| 28 | Workspace | The isolated worktree must be clean after the final commit/package verification; the user's primary worktree is not modified. |

## P0 disposition

- Closed: xpp3 distribution; App icon rights/provenance.
- Technically complete but still a release blocker: immutable local source
  generation, pending publication beside the exact binary.
- Open: native exact-batch provenance and required manual playback/performance
  regression.
- Open for counsel: MPL-1.1/GPLv3 DEX combination review.

The release must not be described as `Open Source Ready` until all three open
items have verifiable evidence and the Developer ID/notarization/release gates
are rerun on the actual published binary/source pair.
