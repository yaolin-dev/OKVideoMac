# Android Bridge Setup

[中文](ANDROID_BRIDGE_SETUP_zh-CN.md)

Android Bridge is used only by supported Java/Dex `csp_` providers. Native,
QuickJS, Node, Live TV, XMLTV, and normal playback do not need Android and do
not trigger a download.

## Default setup

Normal users do not need Android Studio, Homebrew, a JDK, ADB, SDK Manager, or
Terminal commands.

1. The first real Java/Dex request pauses in place.
2. OKVideoMac presents the Android compatibility component with its actual
   download size, required free space, managed location, and Google Android SDK
   and Azul Zulu JRE license links.
3. License acceptance is explicit and never preselected.
4. The app downloads immutable components with real byte progress, then
   verifies, extracts, installs, validates, and activates them.
5. After installation and Managed Environment Purity pass, the original
   request resumes automatically.

The same component can be installed, inspected, updated, repaired, or
diagnosed from **Settings → Android Compatibility Module**.

## Runtime choice and backward compatibility

Managed Runtime remains the default and recommended choice. Advanced users
may instead explicitly select an existing Android SDK in Settings. External
mode is a first-class compatibility path: OKVideoMac uses `adb`, Emulator, and
the matching arm64 system image from that exact SDK while retaining its own ADB
server port, ADB keypair, Android home, and private AVD.

An existing OKVideoMac SDK preference is migrated once. A validated Managed
Generation takes precedence; otherwise the historical explicitly saved SDK is
preserved as External mode even when that path is currently unavailable, so
the user can see and correct the real configuration. Shell `PATH`,
`ANDROID_HOME`, Homebrew, and Android Studio discovery never silently select
External mode.

Selecting a new SDK follows `select → validate → show capabilities →
confirm → atomically switch`. A failed validation or cancellation leaves the
current choice unchanged. The Emulator Session must be stopped before changing
mode.

## Managed layout

The multi-gigabyte Runtime is not bundled in the app. It is installed on demand:

```text
~/Library/Application Support/OKVideoMac/AndroidRuntime/
  Generations/<generation>/{sdk,jre}
  current-runtime.json
  Downloads/
  Staging/
  Backups/
  avd/
  home/.android/
```

The default profile uses API 35 Google APIs for `arm64-v8a`. The catalog pins
the JRE, Command-line Tools, Platform Tools/ADB, Android Platform, Emulator, and
system image by exact version, URL, size, SHA-256, architecture, license, and
archive layout.

Runtime Generations are immutable. An update is installed and validated as a
new Generation before `current-runtime.json` is switched atomically. The AVD
is outside every Generation, so a tool update does not overwrite userdata.
Repair reinstalls managed components while preserving the AVD, favorites,
history, and normal settings.

## Isolation and trust boundaries

- In Managed mode every Android/Java executable must come from the active
  Generation. In External mode Android executables must come from the exact
  user-confirmed SDK.
- ADB uses an OKVideoMac-owned high port and private keypair.
- The AVD must remain under the private `AndroidRuntime/avd` root.
- Child processes receive explicit `PATH`, `JAVA_HOME`, Android home variables,
  AVD home, and `ADB_VENDOR_KEYS` values.
- Once a managed pointer exists, a bad Generation fails closed instead of
  falling back to Android Studio, Homebrew, system Java, or shell `PATH`.
- Installation and Emulator Session have independent single-flights. Concurrent
  install requests join one transaction; Runtime requests retain the existing
  one-startup-task behavior.
- Managed mode never reads or launches an External Android executable. External
  mode never invokes Managed installation admission.
- The shared private AVD is guarded by a compatibility fingerprint containing
  Runtime source, API, ABI, system-image package/tag, AVD schema, and Emulator
  compatibility. A mismatch fails closed without deleting or rebuilding
  userdata.

The catalog is untrusted input. Non-HTTPS or non-allowlisted downloads, bad
SHA-256 values, traversal, absolute paths, duplicate IDs, unexpected archive
roots, symlink escapes, and extraction-size overruns fail before activation.
Failure and cancellation preserve the active pointer. Safe completed downloads
can be reused, and partial downloads support HTTP Range resumption.

## Troubleshooting

- **Download failed:** check the network and retry. A safe `.partial` is kept
  for resumption.
- **Integrity failed:** the artifact and Generation are rejected; the current
  Runtime and AVD are unchanged.
- **Insufficient disk:** the app checks download, extraction, two-generation,
  and safety headroom before downloading.
- **Damaged/incompatible Runtime:** use **Repair** in Settings. Repair uses a
  recoverable backup and never deletes Android Studio data or user ADB keys.
- **Emulator/Bridge failure:** export diagnostics. Reports contain product and
  lifecycle evidence but redact user paths and omit cookies, tokens, private
  source URLs, playback URLs, Spider content, and ADB private keys.

## Existing Android SDK mode

External mode does not download or version the selected SDK and cannot provide
Managed Generation rollback. Validation separates launch capability from
create/repair capability: an already compatible private AVD may launch without
Java or `avdmanager`; creating or rebuilding one requires both. Missing or
incompatible components are reported without falling through to another SDK.

## Compatibility statement

- Static App support: Apple Silicon / arm64, macOS 12.0 or later.
- Real Managed API 35 Runtime E2E: Apple M1, macOS 14.8.8.
- macOS 12, 13, and 15: no real-machine Emulator E2E yet.
- Java/Dex Spider compatibility remains a selected/experimental subset.

Refer to [Android Developers](https://developer.android.com/studio) for upstream
Android terms and [Azul](https://www.azul.com/downloads/) for Zulu JRE details.
