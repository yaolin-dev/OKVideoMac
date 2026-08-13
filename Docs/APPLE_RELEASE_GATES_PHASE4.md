# Phase 4 Apple Release Gates

Date: 2026-08-13

Release: OKVideoMac 0.3.41 (62)

Status: **EXTERNAL CREDENTIAL GATE**

## Current Credential State

- `security find-identity -v -p codesigning`: `0 valid identities found`.
- `security find-identity -v -p basic`: `0 valid identities found`.
- Developer ID Application identity: unavailable.
- Team ID from a usable local signing identity: unavailable.
- `DEVELOPER_ID_APPLICATION`: not configured for the release process.
- `OKVIDEOMAC_NOTARY_PROFILE`: not configured for the release process.

No keychain secret was read or exported. Absence of a selected project profile
does not assert that no unrelated notary profile exists anywhere in the user's
keychain; it means the audited release workflow has no usable identity/profile.

## Gate Results

| Gate | Result |
| --- | --- |
| clean local Release | required and verified by final packaging record |
| inside-out nested signing | local ad-hoc Hardened Runtime path verified |
| entitlement boundary | main local App has only development library-validation exception; Node alone has `allow-jit`; no `get-task-allow` or unsigned-executable-memory exception |
| Developer ID Application / Team ID | NOT EXECUTED — identity unavailable |
| secure timestamp | NOT EXECUTED — Developer ID gate |
| notarization | NOT EXECUTED — identity/profile unavailable |
| staple | NOT EXECUTED |
| staple validation | NOT EXECUTED |
| Gatekeeper distribution assessment | NOT EXECUTED; local ad-hoc verification is not a substitute |

Formal Developer ID / notarization / staple / Gatekeeper verification remains
pending only because external Apple credentials are unavailable.

When credentials become available, run `package-app.sh --mode distribution
--notarize`. The script requires a usable Developer ID identity, uses the
release entitlement boundary, signs nested code inside-out with Hardened
Runtime and timestamp, submits the final ZIP, staples and validates the App,
requires Gatekeeper acceptance, recreates the ZIP after staple, and only then
regenerates the outer binary/source hash manifest. No hash from the current
local package may be presented as the future notarized hash.
