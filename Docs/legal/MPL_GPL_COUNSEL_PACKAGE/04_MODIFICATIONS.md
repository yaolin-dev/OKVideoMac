# 04 — Modifications

## juniversalchardet

**FACT:** OKVideoMac resolves the exact Maven binary JAR and does not copy any
`org.mozilla.universalchardet` source into the repository. The JAR SHA-256 is
`757bfe906193b8b651e79dc26cd67d6b55d0770a2cdfb0381591504f779d4a76`.
All 62 binary classes retain their package/class identity in DEX. No OKVideoMac
modification, shading, or relocation was identified.

## FongMi/catvod

**FACT:** Local `catvod/src/main` was copied from FongMi/TV commit
`5fdff00a602dc56e8ba756174daef20edab024f2` and remains GPL-3.0-only.
`com/github/catvod/net/Proxy.java` changes the initial proxy port from `-1` to
`9978` and adds an explanatory local comment. `AndroidManifest.xml` differs
only by final newline. See `FONGMI_CATVOD_CHANGES.md`.

## AndroidDexBridge

**FACT:** The app module is local OKVideoMac source. It provides the embedded
HTTP/RPC server, Android UI handoff, external JAR download, parented
`DexClassLoader`, Spider reflection, and FongMi host integration.

## LEGAL REVIEW REQUIRED

Counsel should verify whether existing source delivery and modification
notices are sufficient for each applicable license and distribution path.

