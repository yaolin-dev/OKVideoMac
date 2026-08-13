# OKVideoMac Engineering Open Source Readiness — Phase 4

Date: 2026-08-13

Release: OKVideoMac 0.3.41 (62)

Status: **READY WITH EXTERNAL RELEASE GATE**

## Phase A — Frozen Baseline

This Phase 4 audit runs in an isolated worktree. The primary, Phase 2, Phase 3,
and installed Desktop application were read only when this baseline was
recorded.

| Item | Exact baseline |
| --- | --- |
| Phase 4 starting commit | `70120436d477e205fafcebc17974049e5c375d09` |
| Phase 4 branch | `codex/engineering-readiness-phase4` |
| Phase 4 worktree | isolated temporary worktree (local path intentionally omitted from release evidence) |
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

- **Engineering Open Source Readiness:** `READY WITH EXTERNAL RELEASE GATE`.
- **Independent Legal Review:** `NOT PERFORMED`.
- **Known License Interpretation Risk:** Phase 3 evidence is preserved; its
  Phase 4 disposition is `DOCUMENTED LICENSE INTERPRETATION RISK`.

OKVideoMac is a non-commercial personal open-source project. License
obligations are still treated as applicable to distribution. Independent legal
review is not used as a mandatory engineering release gate; known license
interpretation issues are documented transparently.

## Final Engineering Conclusion

**Engineering Open Source Readiness: READY WITH EXTERNAL RELEASE GATE**

**Independent Legal Review: NOT PERFORMED**

The external release gates are Developer ID Application identity, notary
credentials, notarization, staple, Gatekeeper distribution acceptance, and the
explicitly unperformed public GitHub Release. These gates do not erase the
local engineering evidence and are not represented as completed.

The stable native set remains the distribution input. A provenance-clean
candidate was successfully produced for the eight FFmpeg/mpv/bridge
media-core objects. Its architecture, public symbols and enumerated FFmpeg
capability set match the stable set, and limited real VOD/live/seek regression
showed no obvious degradation. It is not adopted because the full manual,
subtitle, HDR, long-form and statistical performance matrix is incomplete.
Retaining the already validated stable set avoids trading product stability
for a provenance-only change.

## Native Closure

Fresh enumeration of the actual Release App found 28 arm64 Mach-O objects:

- Level A (10): main App, OKMPVBridge, QuickJS bridge, mpv, and six FFmpeg
  dylibs;
- Level B (15): Node.js, libass, HarfBuzz, libplacebo, FreeType, FriBidi, two
  Brotli dylibs, Little CMS, libpng, libjpeg, liblzma, libiconv, bzip2 and
  SQLite;
- Level C (3): zlib, libc++ and libc++abi; and
- Level D: none.

The candidate's eight exported-symbol sets are exactly equal to stable. The
1,732-line codec/demuxer/protocol/filter/hardware enumeration is byte-identical
for stable and candidate with SHA-256
`72fef45a39ca86b323d84225aa33c375614b4f83a0d27b5bc339ff6f981c0b50`.
The only normalized link-graph drift is omission of a direct system
`libobjc.A.dylib` edge from candidate libavformat/libavutil; no symbol or
capability loss results.

The audit also corrected the stable bridge's project-source mapping. The
25-symbol stable bridge includes two media-probe functions absent from the
Phase 3 checkout; exact corresponding source was recovered from repository
history and restored. This was a source-binding correction, not a replacement
of the stable distributed bridge.

## Playback and Performance Boundary

Direct UI checks observed stable and candidate playback of the same 1080p VOD,
pause/resume, repeated small forward/backward seek, CCTV-1 live playback, five
rapid next-channel actions through CCTV-5+, and clean playback exit/re-entry.
The candidate also decoded a user-existing 4K HEVC MKV with AAC and visible
Chinese text. An external-subtitle TS fixture was blocked before decoding by
an expired user cloud cookie and is not classified as a native failure.

Five steady-playback samples on the same 1080p fixture averaged 48.7% CPU and
312560 KiB RSS for stable, versus 46.4% CPU and 309123 KiB RSS for candidate.
No crash or hang was observed. Sample size is insufficient for first-frame,
seek or live-switch P90 claims, and post-exit memory samples were not
comparable. Full manual regression remains `MANUAL USER VERIFICATION REQUIRED`.

## Apple Release Boundary

Current re-checks found zero valid signing identities and no project-selected
notary profile. Formal Developer ID signing, secure timestamp, notarization,
staple, staple validation and Gatekeeper distribution assessment were not
executed. The local package nevertheless passes clean Release construction,
inside-out ad-hoc Hardened Runtime signing, the main/Node entitlement boundary,
strict signature verification, exact 28-Mach-O inventory and package
integrity. See `APPLE_RELEASE_GATES_PHASE4.md`.

## Source, Legal and Immutable Release

The final packaging workflow regenerates project source, locked third-party
source and licenses archives from the exact clean commit; produces SPDX 2.3
and CycloneDX 1.6 for the exact 28-Mach-O App and the 87-module Android lock;
embeds the complete Legal payload; verifies the exact Release APK; and creates
the final binary-bound manifest plus `SHA256SUMS` only after the distributable
ZIP is final. Pre-sign and final-artifact sensitive scans are `CLEAN`.

The immutable workflow is `READY_FOR_IMMUTABLE_PUBLICATION`, but no GitHub
Release was created. A future Developer ID/notarized run must regenerate every
post-signing/post-staple hash; the local ad-hoc ZIP hash is not reusable as a
notarized publication hash.

## Known License Interpretation Risk

Component: `com.googlecode.juniversalchardet:juniversalchardet:1.0.3`

Disposition: `DOCUMENTED LICENSE INTERPRETATION RISK`

Exact source evidence shows tri-license text on 57 of 58 Java source files.
One file lacks a file-level header. Maven metadata identifies MPL-1.1. No
independent legal opinion has been obtained regarding artifact-wide license
interpretation. The component is retained to preserve the open Spider
compatibility contract.

This is neither a finding of infringement nor an independent legal approval.
All Phase 3 evidence, including the 58-file JSON audit, 62-class DEX inventory,
combination analysis, modification notices and counsel evidence package,
remains in the release payload.

## Required Answers

1. Baseline commit: `70120436d477e205fafcebc17974049e5c375d09`.
2. Final App Mach-O count: 28.
3. Level D component: none.
4. Level A: main App, OKMPVBridge, QuickJS, mpv, six FFmpeg dylibs.
5. Level B: the 15 source-locked components listed under Native Closure.
6. Level C: zlib, libc++, libc++abi.
7. Provenance-clean candidate: yes for eight media-core objects; no claim of a
   full 28-object clean replacement set.
8. Candidate/stable ABI: exact exported-symbol equality for all eight.
9. Codec/demuxer/protocol capability: exact enumerated equality.
10. VOD: core real fixtures pass; complete format/codec matrix incomplete.
11. Seek: repeated small paused forward/backward path passes; full matrix
    incomplete.
12. Subtitle: no full PASS; visible Chinese text observed, selectable subtitle
    and external ASS/SSA/SRT matrix incomplete.
13. Live: CCTV-1 real playback passes for stable and candidate.
14. Continuous switching: short five-channel sequence passes; extended matrix
    incomplete.
15. First frame: no obvious observed regression; statistical conclusion has
    insufficient data.
16. Seek latency: no obvious observed regression; median/P90 not established.
17. Live-switch latency: no observed regression in the matched short sequence.
18. CPU: no obvious steady-playback regression in the five-sample comparison.
19. Memory: no obvious steady-playback regression; post-exit comparison is
    inconclusive.
20. Crash/hang: none observed.
21. Manual regression: not complete; user verification required.
22. Stable binaries replaced: no.
23. Reason: full manual/broad playback/performance gate is incomplete, and
    stable retention avoids an unproven product-experience change.
24. Developer ID identity: no; zero valid identities.
25. Formal notarization: not executed.
26. Staple: not executed.
27. Gatekeeper distribution assessment: not executed.
28. Source release: successful in the verified packaging workflow.
29. SBOM/final App: exact inventory equality verified.
30. Binary/source binding: complete for the verified local artifact set.
31. Legal payload: complete and bundle-verified.
32. Sensitive scan: clean.
33. juniversalchardet disposition: documented license interpretation risk.
34. Independent Legal Review: not performed.
35. Immutable publication: workflow/artifact set ready; public upload not
    performed; Apple distribution artifact remains credential-gated.
36. Engineering rating: READY WITH EXTERNAL RELEASE GATE.
37. External gates: Developer ID/notary credentials, notarization/staple/
    Gatekeeper, and explicit GitHub publication. Candidate replacement also
    requires the incomplete manual matrix but is not needed while stable is
    retained.
38. Commits: delivered as separate baseline, inventory, source-binding,
    candidate, regression, compliance and release-pipeline commits; exact IDs
    are listed in the final handoff.
39. Rollback: revert those commits in reverse chronological order.
40. Worktrees: final cleanliness is checked after final packaging and reported
    in the handoff.
