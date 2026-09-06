# ADR 0005: Managed Android Runtime Generations

## Status

Accepted for phased implementation.

## Context

The existing `AndroidDexBridgeRuntime` owns a private AVD session, private ADB
server, startup single-flight, process ownership, recovery, and shutdown. It
can discover an SDK under `Application Support/OKVideoMac/AndroidRuntime/sdk`,
but it does not install that SDK. A clean Mac therefore still depends on an
external Android SDK and Java runtime.

Installation and Emulator session state have different safety requirements.
Combining them would put the existing process ownership and single-flight
guarantees at risk. Replacing a live `sdk/` directory in place would also make
rollback expensive and could mix binaries from two releases.

## Decision

`AndroidRuntimeKit` is a separate Swift Package responsible for managed
installation metadata, read-only detection, Runtime Generation layout, path
confinement, and Managed Environment Purity.

Runtime binaries use immutable generations:

```text
AndroidRuntime/
  Generations/r1/{sdk,jre}
  Generations/r2/{sdk,jre}
  current-runtime.json
```

Activation and rollback change only `current-runtime.json`. AVD userdata stays
outside Runtime Generations under `AndroidRuntime/avd`; its `avdSchema` and the
Bridge `bridgeSchema` are versioned independently from `runtimeSchema`.

The first catalog contains only an API 28/30/31/35 candidate matrix. No API is
qualified and no downloadable generation is active until the clean-machine and
representative-Spider validation matrix is complete. The eventual catalog must
pin the managed JRE and every Android component with vendor, version,
architecture, HTTPS source, SHA-256, license, expected version output, size,
and minimum macOS.

Every future installer mutation must pass through
`ManagedRuntimePathBoundary`. It rejects traversal, sibling-prefix paths,
managed-root deletion, and symlink escapes. Detection is read-only.

The Managed Environment Purity gate fails unless Java, sdkmanager, avdmanager,
ADB, Emulator, system image, AVD, ADB key, Android environment variables, and
the owned private ADB server all resolve to the expected active generation or
private AndroidRuntime directory. Diagnostic locations are redacted.

The existing `AndroidDexBridgeRuntime` remains the Session owner. A later
`AndroidRuntimeManager` adapter will coordinate Installation maintenance leases
with that Session; the two single-flight actors and state machines remain
separate.

## Consequences

- A broken update can roll back without moving several gigabytes.
- SDK tool updates do not imply AVD userdata destruction.
- No managed process may silently fall back to Android Studio, Homebrew, PATH,
  or a user JDK.
- The first phase changes no live Runtime selection or Emulator behavior.
- Downloading, license presentation, installation transactions, and UI are
  deliberately deferred to later phases.
