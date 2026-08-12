# Open Source Compliance P0 Status — Phase 2

Date: 2026-08-13
Baseline: `Docs/THIRD_PARTY_LICENSE_AUDIT.md`
Overall rating during Phase 2: **Blocked**

The baseline audit remains unchanged as historical evidence. Similar findings
are grouped below only for reporting the remaining work.

| P0 | Before | Phase 1 | Phase 2 evidence/status | Final status |
| --- | --- | --- | --- | --- |
| GPL mpv source chain | No consolidated fixed source/patch/build mapping | Exact upstream, patch and build mapping established | Immutable bundle implementation pending | **OPEN** |
| FongMi/catvod GPL chain | Incorrectly described as not bundled | Exact copied/modified source and APK mapping established | Immutable APK source bundle pending | **OPEN** |
| Binary provenance | Node and native chain unresolved | Node/mpv/QuickJS verified; native chain partial | Reproducible native recipe and experiment pending | **OPEN** |
| stax/xpp3 exact licenses | Both unknown | stax confirmed; xpp3 unresolved | xpp3 exact source recovery exhausted; artifact excluded without adding a replacement, APK builds and runs in an isolated emulator | **CLOSED** |
| MPL covered source | No source delivery/review | Notice and MPL text present | Exact covered-source bundle and boundary review pending | **OPEN** |
| App icon rights | No author/license evidence | Unresolved | Old asset replaced; retained no-input ImageGen source, prompt, master, hashes and processing record | **CLOSED — VERIFIED OWNED** |
| Binary/source release mapping | No immutable mapping | Mapping document exists | Source-release artifacts pending | **OPEN** |

## Remaining P0 count

Three grouped P0 items remain open after Phase 2A:

1. immutable corresponding-source publication for project/GPL mpv/GPL APK;
2. reproducible exact provenance for FFmpeg/native dylibs;
3. MPL-1.1 covered-source delivery and GPLv3 combination legal review.

Phase 2A closes the xpp3 and icon P0s without changing playback behavior. The
rating remains **Blocked** until the remaining source-release, MPL and native
provenance work is complete and verified.
