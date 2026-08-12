# Open Source Compliance P0 Status — Phase 1

Date: 2026-08-13
Baseline: `Docs/THIRD_PARTY_LICENSE_AUDIT.md`
Overall rating after Phase 1: **Blocked**

The baseline audit remains unchanged as historical evidence. Similar findings
are grouped below only for reporting the remaining work.

| P0 | Before | After Phase 1 | Remaining action |
| --- | --- | --- | --- |
| GPL mpv source chain | No consolidated fixed source/patch/build mapping | **PARTIAL** — v0.41.0 archive/hash, patch/hash, GPL flags, output and change notice are fixed; provenance itself is `VERIFIED` | Publish an immutable combined corresponding-source archive with build instructions |
| FongMi/catvod GPL chain | Incorrectly described as not bundled; modification disclosure absent | **PARTIAL** — copied/modified fact, exact commit/path/diff and APK relationship are documented | Publish immutable APK corresponding source containing the local modified tree |
| False/outdated legal docs | NOTICE denied Android source; license doc said mpv/FFmpeg absent | **CLOSED** | Keep release inventory checks mandatory |
| Native App notices and licenses | Most recursive dylibs, FFmpeg/IJG and FreeType credits absent | **CLOSED for Phase 1 materials** | Regenerate notices whenever inventory changes |
| APK notices | No consolidated runtime graph | **CLOSED for Phase 1 materials** | Regenerate from every Release graph |
| Binary provenance | Node and much of native chain unresolved | **PARTIAL** — Node, mpv and QuickJS are `VERIFIED`; FFmpeg/libass/HarfBuzz and MacPorts inputs remain `PARTIAL` | Create and retain a reproducible, source-locked native build with logs and compare outputs |
| stax/xpp3 exact licenses | Both unknown | **PARTIAL** — stax 1.2.0 is confirmed `Apache-2.0`; xpp3 1.1.3.3 remains `UNRESOLVED` | Obtain authoritative exact historical xpp3 source/license or replace it after dependency review |
| MPL covered source | No 1.0.3 source delivery plan or combination review | **OPEN** — notice and MPL text are present | Retain/publish exact juniversalchardet 1.0.3 covered source and complete GPLv3 combination legal review |
| App icon rights | No author/license evidence | **UNRESOLVED** | Obtain written ownership/license proof or replace with a newly documented asset in Phase 2 |
| Binary/source release mapping | No immutable per-binary answer | **PARTIAL** — mapping exists, but the public project/source bundles do not | Publish fixed source/tag archives and link them from the 0.3.41 binary release |

## Remaining P0 count

Five grouped P0 items remain open:

1. immutable corresponding-source publication for project/GPL mpv/GPL APK;
2. reproducible exact provenance for FFmpeg/native dylibs;
3. exact source and license for `xpp3:xpp3:1.1.3.3`;
4. MPL-1.1 covered-source delivery and GPLv3 combination legal review; and
5. App icon ownership or compatible license evidence.

Phase 1 intentionally does not rebuild dependencies, replace xpp3, redesign
the icon, or manufacture source URLs. A successful legal-payload build does
not change this **Blocked** rating.
