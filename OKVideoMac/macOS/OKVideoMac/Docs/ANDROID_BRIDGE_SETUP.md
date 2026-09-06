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

- Every Android/Java executable must come from the active Generation.
- ADB uses an OKVideoMac-owned high port and private keypair.
- The AVD must remain under the private `AndroidRuntime/avd` root.
- Child processes receive explicit `PATH`, `JAVA_HOME`, Android home variables,
  AVD home, and `ADB_VENDOR_KEYS` values.
- Once a managed pointer exists, a bad Generation fails closed instead of
  falling back to Android Studio, Homebrew, system Java, or shell `PATH`.
- Installation and Emulator Session have independent single-flights. Concurrent
  install requests join one transaction; Runtime requests retain the existing
  one-startup-task behavior.

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

## Legacy / Troubleshooting / Developer Setup

The **Legacy Manual Environment…** control is retained for maintainers and old
installations only. The legacy resolver may inspect a selected SDK or Android
environment only when no managed-generation pointer exists. This is not the
normal setup path and does not provide managed versioning, purity, or rollback.

## Compatibility statement

- Static App support: Apple Silicon / arm64, macOS 12.0 or later.
- Real Managed API 35 Runtime E2E: Apple M1, macOS 14.8.8.
- macOS 12, 13, and 15: no real-machine Emulator E2E yet.
- Java/Dex Spider compatibility remains a selected/experimental subset.

Refer to [Android Developers](https://developer.android.com/studio) for upstream
Android terms and [Azul](https://www.azul.com/downloads/) for Zulu JRE details.
