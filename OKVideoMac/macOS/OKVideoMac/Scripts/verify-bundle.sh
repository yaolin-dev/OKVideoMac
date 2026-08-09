#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 1 ]]; then
  echo "Usage: $0 /path/to/OKVideoMac.app" >&2
  exit 64
fi

APP="$1"
EXECUTABLE="$APP/Contents/MacOS/OKVideoMac"
FRAMEWORKS="$APP/Contents/Frameworks"
BRIDGE_APK="$APP/Contents/Resources/AndroidDexBridge-release.apk"
NODE_RUNTIME="$APP/Contents/Resources/NodeRuntime/node"
APKANALYZER="${ANDROID_SDK_ROOT:-/Volumes/XcodeDev/AndroidSDK}/cmdline-tools/latest/bin/apkanalyzer"

if [[ ! -x "$EXECUTABLE" ]]; then
  echo "Main executable missing: $EXECUTABLE" >&2
  exit 1
fi
if ! lipo -info "$EXECUTABLE" | grep -q 'arm64'; then
  echo "Main executable is not arm64." >&2
  exit 1
fi
if [[ ! -f "$FRAMEWORKS/libmpv.dylib" ]]; then
  echo "Bundled libmpv is missing." >&2
  exit 1
fi
if [[ ! -f "$FRAMEWORKS/libOKMPVBridge.dylib" ]]; then
  echo "Bundled libmpv bridge is missing." >&2
  exit 1
fi
if [[ ! -f "$FRAMEWORKS/libOKQuickJS.dylib" ]]; then
  echo "Bundled QuickJS bridge is missing." >&2
  exit 1
fi
if [[ ! -x "$NODE_RUNTIME" ]]; then
  echo "Bundled Node runtime is missing." >&2
  exit 1
fi
if [[ ! -f "$BRIDGE_APK" ]]; then
  echo "Bundled Android Release bridge is missing." >&2
  exit 1
fi
if [[ "$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")" != "0.3.30" ]] ||
   [[ "$(plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist")" != "42" ]]; then
  echo "The app has unexpected formal-release version metadata." >&2
  exit 1
fi
if [[ ! -f "$APP/Contents/Resources/AppIcon.icns" ]] ||
   [[ ! -f "$APP/Contents/Resources/Assets.car" ]]; then
  echo "The formal AppIcon is missing from the app bundle." >&2
  exit 1
fi
if [[ -f "$APP/Contents/Resources/AndroidDexBridge-debug.apk" ]]; then
  echo "A Debug Android bridge must not be included in a formal package." >&2
  exit 1
fi
if [[ ! -x "$APKANALYZER" ]]; then
  echo "apkanalyzer is required to verify the Android bridge." >&2
  exit 1
fi
if [[ "$("$APKANALYZER" manifest debuggable "$BRIDGE_APK")" != "false" ]]; then
  echo "Bundled Android bridge is debuggable." >&2
  exit 1
fi
if [[ "$("$APKANALYZER" manifest target-sdk "$BRIDGE_APK")" != "27" ]]; then
  echo "Bundled Android bridge lost legacy Spider Activity compatibility." >&2
  exit 1
fi
if [[ "$("$APKANALYZER" manifest version-name "$BRIDGE_APK")" != "0.3.14" ]]; then
  echo "Bundled Android bridge has an unexpected version." >&2
  exit 1
fi
if [[ ! -f "$APP/Contents/Resources/LICENSE" ]] ||
   [[ ! -f "$APP/Contents/Resources/NOTICE.md" ]]; then
  echo "GPL license or source/modification notice is missing." >&2
  exit 1
fi
if [[ ! -f "$APP/Contents/Resources/Licenses/QuickJS-MIT.txt" ]]; then
  echo "QuickJS license is missing." >&2
  exit 1
fi
if [[ ! -f "$APP/Contents/Resources/Licenses/Node.js-LICENSE.txt" ]]; then
  echo "Node.js license is missing." >&2
  exit 1
fi
if [[ ! -f "$APP/Contents/Resources/Licenses/mpv-GPL-2.0-or-later.txt" ]] ||
   [[ ! -f "$APP/Contents/Resources/Licenses/mpv-Copyright.txt" ]]; then
  echo "mpv license or copyright notice is missing." >&2
  exit 1
fi
minimum_system="$(plutil -extract LSMinimumSystemVersion raw "$APP/Contents/Info.plist")"
if [[ "$minimum_system" != "12.0" ]]; then
  echo "Unexpected LSMinimumSystemVersion: $minimum_system" >&2
  exit 1
fi
if ! otool -L "$FRAMEWORKS/libOKMPVBridge.dylib" |
   grep -q '@rpath/libmpv.dylib'; then
  echo "libmpv bridge is not linked to bundled libmpv." >&2
  exit 1
fi

failure=0
while IFS= read -r binary; do
  # The first line printed by otool is the inspected binary's own path. Skip
  # it so an app installed below /Users is not mistaken for an external dylib.
  if otool -L "$binary" | tail -n +2 |
       grep -E '/opt/homebrew|/opt/local|/usr/local|/Users/' >/dev/null ||
     otool -l "$binary" | tail -n +2 |
       grep -E '/opt/homebrew|/opt/local|/usr/local|/Users/' >/dev/null; then
    echo "Forbidden absolute dependency in $binary" >&2
    otool -L "$binary" >&2
    failure=1
  fi
  if ! codesign --verify --strict "$binary"; then
    echo "Invalid signature: $binary" >&2
    failure=1
  fi
  if ! lipo -info "$binary" | grep -q 'arm64'; then
    echo "Non-arm64 binary: $binary" >&2
    failure=1
  fi
  if ! vtool -show-build "$binary" | awk '
    /minos/ {
      split($2, version, ".");
      found = 1;
      if (version[1] > 12 || (version[1] == 12 && version[2] > 0)) {
        exit 1;
      }
    }
    END { if (!found) exit 1 }
  '; then
    echo "Binary requires a system newer than macOS 12.0: $binary" >&2
    failure=1
  fi
done < <(find "$APP/Contents" -type f \( -perm -111 -o -name '*.dylib' \))

if ! codesign --verify --strict "$APP"; then
  echo "App signature verification failed." >&2
  failure=1
fi
if [[ "$failure" -ne 0 ]]; then
  exit 1
fi

echo "Bundle verification passed: $APP"
