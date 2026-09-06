# ADR 0006: API 35 Evaluation and Runtime Installation Transactions

## Status

Accepted as the single-candidate engineering baseline. API 35 remains an
`evaluation` candidate for the wider machine matrix and is now the fixed,
installable default managed profile for product validation.

## Candidate scope

Only `api-35-google-apis-arm64` was exercised. The normal preparation and run
scripts default to this candidate; evaluating another API requires an explicit
`--candidate` argument. This prevents an ordinary validation run from
downloading or starting multiple multi-gigabyte system images.

The isolated run used:

- macOS 14.8.8 on Apple M1 (`iMac21,1`)
- JRE 17.0.19
- Android Command-line Tools 22.0
- Platform Tools / ADB 37.0.0
- Android Emulator 36.6.11
- `system-images;android-35;google_apis;arm64-v8a`
- the release AndroidDexBridge APK and a deterministic Dex Spider fixture

All required phases passed:

- fresh AVD creation
- cold boot private ADB online in 13.71 seconds
- cold boot completion in a further 9.18 seconds (22.90 seconds total)
- Bridge install, start, and health check
- real Dex Spider invocation returning `OKVideoMac Matrix PASS`
- controlled shutdown
- second boot private ADB online in 10.33 seconds
- reused Bridge health check and final shutdown
- isolated tool, AVD, key, port, and environment checks

The observed ADB timeline changed from `missing`, to `offline`, to `device` on
both boots. The Emulator, private ADB server, Bridge forwarding, and fixture
server were all gone after final cleanup. The production Runtime was never
started or mutated by the run.

This evidence proves the selected API 35 guest works on this host. It does not
prove macOS 12, 13, and 15 real-machine coverage, so the Candidate Matrix entry
remains `evaluation`. Product profile status is a separate dimension: the same
locked generation is the shipped `default` profile.

## Installation transaction

`AndroidRuntimeInstaller` is the installation-side single-flight. Admission is
atomic per managed Runtime root. Concurrent requests for the same generation
await the same task; requests for different generations serialize and receive
their own result. This actor is independent from the existing Emulator Session
single-flight.

The transaction order is:

```text
prepare managed directories
  -> recover abandoned managed staging
  -> download to a unique .partial file
  -> verify catalog SHA-256
  -> publish immutable download cache entry
  -> extract/materialize under Staging/<transaction>/
  -> validate identity, layout, critical tools, and versions
  -> move the generation into Generations/<id>/
  -> validate committed files
  -> atomically replace current-runtime.json
```

Archives are hash-verified before extraction. Catalog archive paths and
destinations reject absolute paths and traversal; extracted symlinks must stay
inside their staging tree. Transaction diagnostics do not persist arbitrary
underlying error text or user paths.

The official direct Emulator archive does not contain the local SDK
`emulator/package.xml` normally written by `sdkmanager`. The installer creates
that metadata inside staging from the pinned Catalog package ID and revision,
without overwriting artifact-provided metadata. This is required for the
managed `avdmanager` to recognize the installed Emulator package. A second
empty-root installation test and a full Session matrix were run from that exact
installer output.

On download, hash, extraction, validation, or cancellation failure, the active
pointer is not changed and only that transaction's staging directory is
removed. Downloads that passed SHA-256 may be reused. A generation committed
before a pointer-write failure remains inactive and can be validated and
activated by a retry. AVD userdata remains outside all generations and is not
part of installation rollback.

## Productization update

- Catalog `managed-runtime-2026-09-07` pins the API 35 generation, official
  Google/Azul URLs, exact compressed sizes and SHA-256 values, licenses,
  architectures, destinations, expected archive roots, and extraction caps.
- The main app now presents explicit license acceptance and real-byte progress,
  while `AndroidManagedRuntimeManager` coordinates installation independently
  from `AndroidDexBridgeRuntime` Session ownership.
- macOS 12/13/15 real-machine Emulator E2E remains a field-validation item and
  is not implied by the macOS 12 deployment target.
- The final empty-root transaction consumed 2,442,693,558 compressed bytes and
  produced 5,713,038,554 logical bytes. Using the verified local download cache,
  materialization, validation, and activation took 28.37 seconds.
