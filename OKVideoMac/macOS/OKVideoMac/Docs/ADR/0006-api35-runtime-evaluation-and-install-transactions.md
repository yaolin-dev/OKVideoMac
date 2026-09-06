# ADR 0006: API 35 Evaluation and Runtime Installation Transactions

## Status

Accepted as a single-candidate engineering baseline. API 35 remains an
evaluation candidate and is not yet a public downloadable generation.

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
- cold boot private ADB online in 12.48 seconds
- cold boot completion in a further 9.10 seconds
- Bridge install, start, and health check
- real Dex Spider invocation returning `OKVideoMac Matrix PASS`
- controlled shutdown
- second boot private ADB online in 11.35 seconds
- reused Bridge health check and final shutdown
- isolated tool, AVD, key, port, and environment checks

The observed ADB timeline changed from `missing`, to `offline`, to `device` on
both boots. The Emulator, private ADB server, Bridge forwarding, and fixture
server were all gone after final cleanup. The production Runtime was never
started or mutated by the run.

This evidence proves the selected API 35 guest works on this host. It does not
yet prove clean-machine behavior or macOS 12, 13, and 15 coverage, so the
candidate remains `evaluation` in the bundled catalog.

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

On download, hash, extraction, validation, or cancellation failure, the active
pointer is not changed and only that transaction's staging directory is
removed. Downloads that passed SHA-256 may be reused. A generation committed
before a pointer-write failure remains inactive and can be validated and
activated by a retry. AVD userdata remains outside all generations and is not
part of installation rollback.

## Deferred release gates

- Pin official immutable URLs, hashes, sizes, licenses, and archive layouts for
  the JRE and each Android component.
- Run the selected API 35 candidate on the required clean and supported macOS
  host set.
- Publish the first non-empty Runtime Generation only after those gates pass.
- Connect installation progress and explicit license acceptance to the main
  app UI without changing `AndroidDexBridgeRuntime` Session ownership.
