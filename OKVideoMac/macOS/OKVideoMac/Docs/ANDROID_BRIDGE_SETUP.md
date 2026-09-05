# Android Bridge Setup

[中文](ANDROID_BRIDGE_SETUP_zh-CN.md)

Android Bridge is an optional compatibility runtime for selected Java/Dex
`csp_` providers. It is not a foundation for playback, Native providers,
QuickJS, Node, Live TV, or XMLTV.
This document describes the current OKVideoMac 0.4.0 (Build 94)
implementation. The
presence of the Bridge does not imply compatibility with every Java/Dex
`csp_` Spider.

## Do I need Android?

| Use case | Android required |
| --- | --- |
| Native providers, including CMS JSON/XML response paths | No |
| FongMi image/Base64-wrapped JSON configuration | No |
| QuickJS Spider | No |
| Node `.js.md5` Spider | No |
| M3U, TXT, JSON Live, and XMLTV | No |
| Normal libmpv playback | No |
| Supported Java/Dex `csp_` Spider | Yes |

Android Bridge starts only when a site is dispatched to the Java/Dex provider.
Loading a configuration does not by itself mean Android is required; dispatch
depends on the site's `type`, `api`, script, and Java/Dex package reference.

## Required components

| Component | Required | How OKVideoMac detects it | User action |
| --- | --- | --- | --- |
| Android Studio | No | The IDE is not detected | Recommended as the easiest SDK Manager UI; official command-line tools also work |
| Android SDK root | Yes | Searched in the order below or selected in the app | Provide one complete SDK directory |
| Android SDK Platform-Tools / `adb` | Yes | `<SDK>/platform-tools/adb` must be executable | Install from **SDK Tools** |
| Android Emulator | Yes | `<SDK>/emulator/emulator` must be executable | Install from **SDK Tools** |
| Android SDK Command-line Tools | Required for a clean setup | Looks for `cmdline-tools/latest/bin/avdmanager`, then other version directories | Install the latest stable package from **SDK Tools** |
| Android system image | Yes | Only `arm64-v8a` images with `package.xml` are recognized | Install an ARM 64 v8a image at API 24 or newer |
| AVD | Yes, app-managed | Dedicated name is `OKVideoMac_Runtime` | Do not create one manually; OKVideoMac creates it |
| Bridge APK | Yes, bundled with the app | `Contents/Resources/AndroidDexBridge-release.apk` | Do not download or install it manually |
| `sdkmanager` | Not a runtime command | OKVideoMac never invokes it | Use it only for a command-line SDK installation |

The Bridge APK has `minSdk` 24. Runtime code does not pin one API level. It
selects the highest installed `arm64-v8a` image; at the same API level it
prefers `google_apis`, then `default`, then other variants. A Google Play image
is not required. The current implementation does not select `x86_64` images.

## Recommended installation

1. Confirm that you actually need a Java/Dex `csp_` provider. All other source
   types can skip this setup.
2. Install and launch Android Studio once, following the
   [official Android instructions](https://developer.android.com/studio/install.html).
   Android Studio is the recommended installer UI, not an OKVideoMac runtime
   dependency.
3. Open **Tools → SDK Manager** in Android Studio:
   - Under **SDK Tools**, install **Android SDK Platform-Tools**,
     **Android Emulator**, and **Android SDK Command-line Tools (latest)**.
   - Under **SDK Platforms**, enable **Show Package Details** and install an
     **ARM 64 v8a System Image** at API 24 or newer.
   - Note the **Android SDK Location** shown at the top of the window.
4. In OKVideoMac, open **Settings (设置) → Advanced (高级) → Android
   Compatibility Module (Android 兼容模块)** and click **Check (检查)**.
5. If the app reports that no complete Android SDK was found, click
   **Choose SDK… (选择 SDK…)** and select the SDK root from step 3. The selected
   directory must directly contain `platform-tools` and `emulator`.
6. Click **Start (启动)**, or open a site that needs Java/Dex. On first use,
   OKVideoMac creates its dedicated AVD, launches a headless Emulator, installs
   the bundled APK, and configures port forwarding. This can take 1–4 minutes.
7. Setup is complete when the status reads **已就绪 — Java/Dex 站点可正常使用**
   (Ready — Java/Dex sites are available).

Do not create an AVD in Android Studio's Device Manager, and do not connect an
Android phone for OKVideoMac.

## SDK discovery order

The runtime uses the first SDK root containing executable
`platform-tools/adb` and `emulator/emulator`, in this exact order:

1. `~/Library/Application Support/OKVideoMac/AndroidRuntime/sdk` (reserved
   app-managed location; this release does not download an SDK into it);
2. the directory saved by **Settings (设置) → Advanced (高级) → Android
   Compatibility Module (Android 兼容模块) → Choose SDK… (选择 SDK…)**;
3. `ANDROID_HOME` visible to the OKVideoMac process at launch;
4. `ANDROID_SDK_ROOT` visible to the process at launch;
5. `~/Library/Android/sdk`;
6. an SDK root inferred from `PATH` entries ending in `platform-tools`,
   `emulator`, or `cmdline-tools/<version>/bin`.

This is not a general `which adb` search. A standalone `adb` on `PATH` only
helps when its PATH entry can be mapped back to one SDK root that also contains
the Emulator. Apps launched from Finder may not inherit interactive-shell
environment variables, so **Choose SDK… (选择 SDK…)** is the most deterministic
option.

## The app-managed Android environment

OKVideoMac does not use ordinary user AVDs. It points `ANDROID_AVD_HOME` to:

```text
~/Library/Application Support/OKVideoMac/AndroidRuntime/avd
```

It then creates `OKVideoMac_Runtime` with `avdmanager create avd` and launches
it headlessly, without audio or snapshots and with hardware acceleration. The
runtime connects only to the `emulator-<console-port>` process it launched and
verified. A physical Android device cannot replace this dedicated Emulator.

Swift uses serial-scoped `adb` commands to verify the process and AVD, wait for
boot, run `adb install -r`, start the Activity, and configure loopback port
forwarding. Inside the Emulator, the APK binds to `127.0.0.1:9978`; the main
Mac-side HTTP endpoint is `127.0.0.1:19978`. The Bridge loads
`com.github.catvod.spider.<csp_ suffix>` with `DexClassLoader` and returns JSON
results to the Swift provider.

**Stop** shuts down the dedicated Emulator only after its PID, AVD, serial, and
process command match the saved runtime identity. A mismatch causes a safe
refusal rather than an attempt to stop another Emulator.

## Advanced setup without Android Studio

The runtime supports a standard Android SDK directory and does not require the
Android Studio IDE. Follow the
[official `sdkmanager` documentation](https://developer.android.com/tools/sdkmanager)
to install Platform-Tools, Emulator, Command-line Tools, and a qualifying
`arm64-v8a` system image, then select that SDK root in OKVideoMac.

OKVideoMac does not invoke `sdkmanager`, accept SDK licenses, download, or
upgrade SDK packages. It also does not repair an incomplete SDK. Obtain all SDK
components only from official Android channels.

For a read-only Terminal check, replace `SDK_ROOT` with the actual SDK root:

```bash
test -x "$SDK_ROOT/platform-tools/adb"
test -x "$SDK_ROOT/emulator/emulator"
test -x "$SDK_ROOT/cmdline-tools/latest/bin/avdmanager"
"$SDK_ROOT/platform-tools/adb" version
"$SDK_ROOT/emulator/emulator" -version
find "$SDK_ROOT/system-images" -path '*/arm64-v8a/package.xml' -print
```

`avdmanager` may also be under `cmdline-tools/<version>/bin`. An empty result
from the default `emulator -list-avds` is not evidence of failure: OKVideoMac's
dedicated AVD lives under a separate `ANDROID_AVD_HOME` and does not appear in
the default user AVD list.

## Troubleshooting

### Complete Android SDK not found

The SDK root must contain both executable `platform-tools/adb` and
`emulator/emulator`. In **Settings (设置) → Advanced (高级) → Android
Compatibility Module (Android 兼容模块)**, click **Choose SDK… (选择 SDK…)** and
select the SDK root itself, not its `platform-tools` or `emulator` child
directory.

### `adb` not found

Install **Android SDK Platform-Tools** in Android Studio's SDK Manager. A device
driver, `fastboot`, or a standalone script without the required SDK directory
layout does not satisfy the current resolver.

### Emulator missing or unable to start

Install **Android Emulator** and ensure that its architecture is suitable for
Apple Silicon. The runtime passes `-accel on`, so the host must provide the
hardware virtualization required by Android Emulator. OKVideoMac currently
checks only that the executable exists; it does not preflight the Emulator
version or host CPU features. A present but unusable Emulator therefore fails
when **Start (启动)** is clicked and its launch error is shown then.

### Command-line Tools (`avdmanager`) missing

Install **Android SDK Command-line Tools (latest)**. A complete existing
dedicated AVD can still be reused, but a clean setup needs `avdmanager` to
create it automatically.

### No arm64 Android system image

Install an **ARM 64 v8a System Image** at API 24 or newer. An SDK containing
only `x86_64` images does not pass the current check. This release does not
download images automatically.

### Incomplete AVD record or unverified runtime ownership

The runtime stops and preserves its record; it will not mutate an Emulator it
cannot prove it owns. Click **Check** first. For a normally owned running
instance, **Repair (修复)** rebuilds port forwarding and reinstalls the bundled
APK.
Do not use `killall`, `adb kill-server`, delete other AVDs, or wipe data as a
routine fix. Export redacted diagnostics and file an issue if the problem
persists.

The current UI has no “delete and recreate dedicated AVD” action. A damaged
dedicated AVD directory requires maintainer diagnosis rather than asking a
normal user to delete it manually.

### Bridge APK fails to start

The formal app should contain
`Contents/Resources/AndroidDexBridge-release.apk`. Users should not install an
APK manually. Try **Repair (修复)** first. If the app reports that the APK is
missing, reinstall the complete official app instead of downloading an APK
elsewhere.

### Native sources work but a Java/Dex provider fails

This normally means only the optional Android compatibility runtime is not
ready. It does not mean that OKVideoMac, libmpv, QuickJS, Node, or Live TV has
failed. Check the Android Compatibility Module status in Settings.

### Stopping or disabling Android Bridge

When the status is Ready, click **Stop (停止)** under **Settings (设置) → Advanced
(高级) → Android Compatibility Module (Android 兼容模块)**. This release has no
persistent disable toggle; opening a Java/Dex site again prepares the runtime
automatically. Avoiding Java/Dex `csp_` providers prevents it from being
triggered.

Quitting OKVideoMac does not forcibly stop the dedicated Emulator. Click
**Stop (停止)** before quitting if you do not want it to keep using resources.

## Current platform scope

The 0.4.0 public build targets Apple Silicon / arm64, and the runtime selects
only `arm64-v8a` system images. It does not select `x86_64` images, so this
document does not claim Intel Mac Android Bridge support. Rosetta is not
required.

For Android SDK, Emulator, and hardware requirements, use the official Android
documentation:

- [Install Android Studio](https://developer.android.com/studio/install.html)
- [SDK Manager](https://developer.android.com/studio/intro/update.html#sdk-manager)
- [Configure Emulator acceleration](https://developer.android.com/studio/run/emulator-acceleration)
