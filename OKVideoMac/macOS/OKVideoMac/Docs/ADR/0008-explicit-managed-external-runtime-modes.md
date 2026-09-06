# ADR 0008: Explicit Managed and External Android Runtime Modes

## Status

Accepted as a backward-compatibility correction. This decision does not change
the App version or the existing Emulator Session implementation.

## Context

Managed Runtime product integration made installation a mandatory prerequisite
for every Dex request. Earlier OKVideoMac releases allowed the user to save an
Android SDK root and run the private AVD from that SDK. Consequently, an upgrade
could block a still-valid External installation behind a Managed download.

A pointer file alone is not evidence that Managed Runtime is usable, and ambient
Android discovery is not evidence that the user selected External mode.

## Decision

OKVideoMac persists one canonical, versioned Runtime choice in
`AndroidRuntime/runtime-selection.json`. The file is written atomically. The
historical `OKVideoMac.AndroidSDKRoot` preference is migration input and
downgrade compatibility only.

One-time migration order is:

1. Preserve an existing explicit mode record.
2. Select Managed only when the existing detector, Generation validation, and
   Purity checks resolve a usable Managed Runtime.
3. Otherwise select External when the historical OKVideoMac preference exists,
   preserving its path even if currently invalid.
4. Otherwise default to Managed.

`ANDROID_HOME`, shell `PATH`, Homebrew, and Android Studio discovery cannot
silently choose External mode.

The mode coordinator is the only prerequisite used by Dex requests and Settings
actions. Managed routes only to Managed installation admission and a validated
Generation. External routes only to the exact confirmed SDK and never invokes
Managed admission. Existing Managed-install and Emulator-start single-flights
remain separate and unchanged.

## External validation

Validation reports two independent capabilities:

- Launch requires exact executable/host-compatible `adb` and Emulator binaries,
  an existing complete private AVD, and the exact referenced arm64 interactive
  system image inside the selected SDK.
- Create/repair additionally requires `avdmanager` and a Java Runtime. Their
  absence does not block launch of an already usable AVD.

Mode changes require a stopped Session. A new SDK is committed only after
selection, validation, capability presentation, and explicit confirmation.
Cancellation or validation failure preserves the current record.

## Shared AVD safety

Managed and External continue to share the existing OKVideoMac-private AVD
location. A separate compatibility fingerprint records Runtime source and
identity, AVD schema, API, ABI, system-image package/tag, and Emulator major
compatibility. The configured `image.sysdir` must resolve to matching controlled
image metadata in the selected SDK. Incompatibility fails closed and never
silently deletes or rebuilds userdata.

## Consequences

Existing explicitly configured users can continue without downloading Managed
Runtime. Managed remains the recommended default and retains full Purity and
rollback guarantees. External users own SDK maintenance, while private ADB,
keys, Android homes, AVD ownership, startup single-flight, GPU fallback,
recovery, and shutdown stay inside the unchanged Session boundary.
