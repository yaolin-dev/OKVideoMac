# Spider Charset Compatibility Census

Audit date: 2026-08-13

Release: `OKVideoMac 0.3.41 (62)`

Privacy rule: configuration URLs, credentials, and private configuration
content are intentionally omitted. Artifact hashes are recorded because they
identify the inspected binaries without publishing user configuration.

## Scope and Counting Rule

The scan covered legally accessible local material:

- current configuration-referenced JARs in `SourceAuditCache`;
- their extracted DEX files;
- retained Phase 3 Spider JAR evidence in `/private/tmp`;
- tracked fixtures and AndroidDexBridge/FongMi source.

A JAR and its extracted `classes.dex` are one logical Spider artifact. Two
older retained JAR snapshots and two current cached snapshots were distinct by
SHA-256, so the census total is four. The four artifacts form two loader-DEX
families; each family's visible DEX is byte-identical across its two snapshots.

## Artifact Inventory

| Artifact | Origin | JAR SHA-256 | Bytes | Visible DEX SHA-256 | Visible classes | Result |
|---|---|---|---:|---|---:|---|
| current family A | current download manifest; 46 hashed config origins | `4ea2ae69eb1b5d403a0418a785d62f9fbad4783a6934e19d2298ab69f56b0fea` | 1,105,907 | `e0a39c5d9074fc5a47e65e252ba55b1cfe6e939c7078d670d1856db1bc812422` | 74 | `UNINSPECTABLE_DYNAMIC_CODE` |
| current family B | current download manifest; 87 hashed config origins | `fa8cb1fb62f0c4a892b49eaa8d9c97401fc7b05bfeaebac05939e313e5c80f65` | 1,268,616 | `2b6803c4590493acdcfb988f327386bd459d4c42ebbdef85a0b859a5a992077c` | 159 | `UNINSPECTABLE_DYNAMIC_CODE` |
| Phase 3 family A snapshot | retained Phase 3 artifact | `6a7442551dad7ac0bde979655fd95644ac695039848918a32240809146d7d15d` | 1,105,757 | `e0a39c5d9074fc5a47e65e252ba55b1cfe6e939c7078d670d1856db1bc812422` | 74 | `UNINSPECTABLE_DYNAMIC_CODE` |
| Phase 3 family B snapshot | retained Phase 3 artifact | `f4eb80fcfb009b59efa811153d4705755324c68d7a4f281dcbd51642a9ca6744` | 1,269,336 | `2b6803c4590493acdcfb988f327386bd459d4c42ebbdef85a0b859a5a992077c` | 159 | `UNINSPECTABLE_DYNAMIC_CODE` |

## Static Scan

Each JAR, visible DEX, native guard, and encrypted payload was scanned for:

- `org/mozilla/universalchardet` and dotted equivalents;
- `UniversalDetector` and `CharsetListener`;
- every public class simple name from the exact 1.0.3 JAR;
- strings that could be passed to reflection;
- DEX type, field, and method descriptors.

No visible direct or reflection reference was found. This is a statement about
the visible loader layer only.

## Protected / Encrypted Limit

All four JARs contain:

- a small visible loader `classes.dex`;
- architecture-specific native guard libraries;
- a much larger `.guard` payload;
- code paths that obtain/load the effective runtime implementation through
  native code.

Existing Android logs show the packages loading native/decrypted runtime code.
The effective Spider implementations are therefore not exhaustively present
as inspectable DEX instructions or strings in the JAR. Per the audit rule,
`NO STATIC REFERENCE` cannot be promoted to `NO DEPENDENCY`.

## Summary

| Classification | Count |
|---|---:|
| total logical Spider JAR/DEX artifacts | 4 |
| fully inspectable | 0 |
| `DIRECT_REFERENCE` | 0 confirmed |
| `REFLECTION_REFERENCE` | 0 confirmed |
| `NO_REFERENCE` | 0 (not assignable to protected artifacts) |
| `UNINSPECTABLE_DYNAMIC_CODE` | 4 |

The current cached corpus contains two JAR snapshots; both are uninspectable.
The retained Phase 3 snapshots add historical coverage but not a fully visible
Spider implementation.

## Compatibility Conclusion

No known visible Spider code confirms use of juniversalchardet. Whether the
current protected runtime implementations use it is unknown. Arbitrary
external Spider compatibility cannot be closed because the host accepts
configuration-selected JAR/DEX packages and gives their `DexClassLoader` the
APK class loader as parent.

This census does not satisfy removal Path A. It also cannot define the actual
legacy API subset needed for a Path B shim.

