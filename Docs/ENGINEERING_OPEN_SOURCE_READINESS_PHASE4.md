# OKVideoMac Engineering Open Source Readiness — Phase 4

Date: 2026-08-13

Release: OKVideoMac 0.3.41 (62)

Status: **IN PROGRESS — NO FINAL RATING RECORDED AT BASELINE**

## Phase A — Frozen Baseline

This Phase 4 audit runs in an isolated worktree. The primary, Phase 2, Phase 3,
and installed Desktop application were read only when this baseline was
recorded.

| Item | Exact baseline |
| --- | --- |
| Phase 4 starting commit | `70120436d477e205fafcebc17974049e5c375d09` |
| Phase 4 branch | `codex/engineering-readiness-phase4` |
| Phase 4 worktree | `/private/tmp/okvideomac-engineering-readiness-phase4` |
| Phase 3 branch / commit | `codex/mpl-gpl-p0-audit` / `70120436d477e205fafcebc17974049e5c375d09` |
| Primary branch / commit | `codex/mpv-teardown-ab-experiment` / `557c3c90051b9867e84c4de78bddce1bd62be93c` |
| Phase 2 branch / commit | `codex/open-source-compliance-phase2` / `1552e51df9bc42aa7832e0ed3816e4dc96d7b88f` |
| Beginning worktree state | primary, Phase 2, and Phase 3 all clean; new Phase 4 worktree clean |
| Submodules | none configured (`git submodule status` produced no entries) |
| Desktop version | `0.3.41` |
| Desktop build | `62` |
| Desktop APK SHA-256 | `59ee18fa061bad09bf60b8836e3be141878b7b0167987af6228386173072a845` |
| Test host | macOS 14.8.8 (23J620), arm64 |
| Xcode / SDK | Xcode 16.2 (16C5032a), macOS SDK 15.2 |
| Compiler | Apple clang 16.0.0 (clang-1600.0.26.6) |

The exact 28-entry stable Mach-O hash baseline is frozen in
`Docs/native/PHASE4_BASELINE_MACHO_SHA256.txt`. Recording a hash does not by
itself establish source provenance or a readiness result.

## Rating Framework

Phase 4 separates these independent statements:

- **Engineering Open Source Readiness:** not yet determined at baseline.
- **Independent Legal Review:** `NOT PERFORMED`.
- **Known License Interpretation Risk:** Phase 3 evidence is preserved; its
  final Phase 4 disposition will be recorded only after the engineering audit.

OKVideoMac is a non-commercial personal open-source project. License
obligations are still treated as applicable to distribution. Independent legal
review is not used as a mandatory engineering release gate; known license
interpretation issues are documented transparently.

