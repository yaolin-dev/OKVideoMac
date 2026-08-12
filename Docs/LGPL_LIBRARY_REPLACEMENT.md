# LGPL Dylib Replacement and Re-sign Test

Date: 2026-08-13

Legal sufficiency: **Needs legal review**

## Tested result

The audit copied the isolated `OKVideoMac-ReproBuild.app`, replaced
`libavutil.59.dylib` with a distinct ABI-compatible arm64 build, and observed
the expected deep-signature failure. The original and replacement SHA-256
values were respectively:

- `1a6e8f541b20531065dcf06c78bcebb54a40afb647eec05f70058c3b4d4245fe`
- `a0efd1ba3e43b135b802d6af01a1a26aa66801c6ff1ff868abbb288c82c69331`

After ad-hoc signing the replacement dylib, the main executable and the outer
App, deep strict verification passed. LaunchServices then started the App and
the process remained alive until the audit ended it. This proves the tested
local replacement/startup path, not playback correctness or legal sufficiency.

## Reproducible procedure

Run the guarded test script against a copy; its destination is restricted to
an explicit App below `/private/tmp`:

```sh
OKVideoMac/macOS/OKVideoMac/Scripts/test-lgpl-replacement.sh \
  SOURCE.app libavutil.59.dylib REPLACEMENT.dylib \
  /private/tmp/OKVideoMac-LGPL-ReplacementTest.app
```

The script confirms that replacement invalidates the original signature,
ad-hoc signs the changed dylib, re-signs the main executable and outer bundle
with Hardened Runtime and the development entitlement, and runs deep strict
verification. The user must then launch the copy and perform playback tests.

## Library Validation boundary

The local development entitlement contains
`com.apple.security.cs.disable-library-validation=true`; the release
entitlement is empty. A Developer ID distribution keeps Library Validation
strict, so a user-modified ad-hoc dylib must not be expected to load under the
unchanged Developer ID main signature. The documented local replacement path
therefore re-signs the main executable and outer App ad-hoc with the
development entitlement. That destroys Developer ID/notarization trust for
the modified copy and may require the user to approve local execution.

No valid Developer ID identity or notary profile was present on the audit host,
so this Phase did not claim that a Developer ID/notarized sample passed the
replacement test. Counsel must review whether the source, notices, relinking
information and replacement procedure satisfy the applicable LGPL obligations.
