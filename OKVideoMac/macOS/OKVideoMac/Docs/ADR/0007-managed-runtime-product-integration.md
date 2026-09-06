# ADR 0007: Managed Runtime Product Integration

## Status

Accepted for the 0.4.2 source candidate without changing the App version.

## Decision

`AndroidManagedRuntimeManager`, supplied by `AndroidRuntimeKit`, is the only
product-level coordinator for installation. It owns the installation UI state,
license gate, Dex-request waiters, install/repair single-flight, progress,
post-install Purity check, and waiter resumption. It does not own Emulator
processes.

`AndroidDexBridgeRuntime` remains the Session owner for private ADB, AVD
ownership, Emulator startup single-flight, offline recovery, Bridge health, and
shutdown. The integration point is a prerequisite closure invoked immediately
before an actual Bridge request. Configuration parsing alone does not install
Android.

The product flow is:

```text
Dex request
  -> managed selection/Purity check
  -> suspend request and present offer if absent
  -> explicit license acceptance
  -> transactional immutable-generation install
  -> post-activation selection/Purity gate
  -> resume all waiting Dex requests
  -> existing Session startup
```

Closing the offer cancels every suspended request. Concurrent settings and Dex
install actions join one installation flight. A token prevents a late waiter
from clearing or publishing state for a newer flight.

## Failure and repair

Download, integrity, extraction, validation, cancellation, and activation
failures never point `current-runtime.json` at staging. Safe partial downloads
remain resumable. Product repair moves only the selected immutable Generation
to a recoverable backup; if repair fails, it restores both the Generation and
the previous pointer. AVD userdata is never part of that transaction.

When a managed pointer exists, all Java and Android resolution fails closed.
Legacy external SDK/JDK discovery is available only when there is no managed
pointer, and is labeled as a developer/troubleshooting path in the UI.

## Compatibility

The App remains arm64 with a macOS 12 deployment target. The API 35 managed
Runtime has real-machine evidence on M1 / macOS 14.8.8 only. App deployment
support and Managed Runtime field verification are documented separately.

The final installed-generation run reached private ADB `device` after 13.71
seconds, `boot_completed` after 22.90 seconds total, Bridge health after 25.99
seconds total, and the real Dex result after 26.17 seconds total. A second boot
reached ADB in 10.33 seconds and reused Bridge health in 13.40 seconds total.
These measurements are host observations, not promises for other Macs.
