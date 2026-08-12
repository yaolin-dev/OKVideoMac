# Open Source Compliance P0 Status — Phase 2

Date: 2026-08-13
Baseline: `Docs/THIRD_PARTY_LICENSE_AUDIT.md`
Overall rating during Phase 2: **Blocked**

The baseline audit remains unchanged as historical evidence. Similar findings
are grouped below only for reporting the remaining work.

| P0 | Before | Phase 1 | Phase 2 evidence/status | Final status |
| --- | --- | --- | --- | --- |
| GPL mpv source chain | No consolidated fixed source/patch/build mapping | Exact upstream, patch and build mapping established | Release generator includes fixed archive, patch, license, options and build recipe and binds their archive to the binary | **CLOSED technically; publication pending** |
| FongMi/catvod GPL chain | Incorrectly described as not bundled | Exact copied/modified source and APK mapping established | Project archive plus source-only upstream commit subset, change notice, wrapper and dependency lock are generated and hash-bound | **CLOSED technically; publication pending** |
| Binary provenance | Node and native chain unresolved | Node/mpv/QuickJS verified; native chain partial | Native lock and exact Portfile receipts retained; isolated FFmpeg + patched mpv functional/ABI rebuild passed, but original platform drift, libc++/zlib gaps and manual player regression remain | **OPEN — PARTIAL** |
| stax/xpp3 exact licenses | Both unknown | stax confirmed; xpp3 unresolved | xpp3 exact source recovery exhausted; artifact excluded without adding a replacement, APK builds and runs in an isolated emulator | **CLOSED** |
| MPL covered source | No source delivery/review | Notice and MPL text present | Exact sources JAR/hash and 58-file boundary delivered; DEX combination documented | **NEEDS LEGAL REVIEW** |
| App icon rights | No author/license evidence | Unresolved | Old asset replaced; retained no-input ImageGen source, prompt, master, hashes and processing record | **CLOSED — VERIFIED OWNED** |
| Binary/source release mapping | No immutable mapping | Mapping document exists | Deterministic generator, source index, outer manifest and SHA256SUMS implemented; public upload still required | **CLOSED technically; publication pending** |

## Remaining P0 count

The remaining release blockers after the Phase 2B implementation are:

1. upload the generated immutable binary/source set to the same persistent
   release location;
2. reproducible exact provenance for FFmpeg/native dylibs;
3. counsel review of the documented juniversalchardet/GPL DEX combination.

Exact MPL covered-source delivery is no longer missing. The rating remains
**Blocked** while publication, legal review and native provenance are open.
