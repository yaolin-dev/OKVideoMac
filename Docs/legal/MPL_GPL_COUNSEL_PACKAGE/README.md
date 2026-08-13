# MPL-1.1 / GPLv3 Counsel Evidence Package

Release: `OKVideoMac 0.3.41 (62)`

Technical baseline: `1552e51df9bc42aa7832e0ed3816e4dc96d7b88f`

Disposition: `OPEN — COUNSEL REVIEW REQUIRED`

Phase 4 current disposition: `DOCUMENTED LICENSE INTERPRETATION RISK`

Independent Legal Review: `NOT PERFORMED`

The original disposition above identifies the historical Phase 3 decision.
This evidence package remains available for a future independent review, but
such review is not represented as completed and is not a mandatory Phase 4
engineering release gate.

This package separates three categories:

- **FACT**: reproduced from exact artifacts, source, locks, DEX inventory, or
  current configuration artifacts.
- **ENGINEERING INFERENCE**: a bounded technical conclusion based on those
  facts.
- **LEGAL REVIEW REQUIRED**: a question intentionally left to qualified
  counsel.

The exact 1.0.3 source audit found 57 tri-license alternative headers and one
headerless file. The Release APK contains the complete library in
`classes2.dex`; GPL-3.0 FongMi/catvod and bridge classes are in `classes.dex`.
No current static or reflective caller was found. Removal was not performed
because the bridge is an open-ended CatVod plugin host, FongMi exposes the
module as an `api` dependency, and protected/dynamically supplied Spider code
cannot be exhaustively proven not to consume the host class contract.

Counsel should begin with `07_QUESTIONS_FOR_COUNSEL.md`. The machine-readable
58-file record and complete DEX class inventory are in `Docs/compliance/`.
