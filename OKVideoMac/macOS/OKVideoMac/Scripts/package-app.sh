#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/build-environment.sh"

DERIVED_DATA="${OKVIDEOMAC_DERIVED_DATA:-$OKVIDEOMAC_BUILD_ROOT/DerivedData}"
ARTIFACTS="${OKVIDEOMAC_ARTIFACTS:-$OKVIDEOMAC_BUILD_ROOT/Artifacts}"
APP_SOURCE="$DERIVED_DATA/Build/Products/Release/OKVideoMac.app"
APP_DESTINATION="$ARTIFACTS/OKVideoMac.app"
ARCHIVE="$ARTIFACTS/OKVideoMac-0.3.25-macOS-arm64.zip"
LIBMPV_ROOT="$OKVIDEOMAC_BUILD_ROOT/libmpv"
QUICKJS_ROOT="$OKVIDEOMAC_BUILD_ROOT/QuickJS"
NODE_RUNTIME="$APP_DESTINATION/Contents/Resources/NodeRuntime/node"
EXECUTABLE="$APP_DESTINATION/Contents/MacOS/OKVideoMac"
MPV_BRIDGE="$LIBMPV_ROOT/lib/libOKMPVBridge.dylib"

if ! xcodebuild -version >/dev/null 2>&1; then
  echo "Full Xcode is required for packaging." >&2
  exit 1
fi
if [[ ! -d "$PROJECT_DIR/OKVideoMac.xcodeproj" ]]; then
  echo "Generate OKVideoMac.xcodeproj first." >&2
  exit 1
fi

if [[ "${OKVIDEOMAC_SKIP_ANDROID_BRIDGE_BUILD:-0}" != "1" ]]; then
  "$SCRIPT_DIR/build-android-dex-bridge.sh"
fi

ANDROID_BRIDGE_APK="$PROJECT_DIR/../../Helpers/AndroidDexBridge/app/build/outputs/apk/release/app-release.apk"
if [[ ! -f "$ANDROID_BRIDGE_APK" ]]; then
  echo "Android bridge APK is missing; build it before packaging." >&2
  exit 1
fi

xcodebuild \
  -project "$PROJECT_DIR/OKVideoMac.xcodeproj" \
  -scheme OKVideoMac \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  clean build

if [[ ! -d "$APP_SOURCE" ]]; then
  echo "Release app not found at $APP_SOURCE" >&2
  exit 1
fi

rm -rf "$APP_DESTINATION"
mkdir -p "$ARTIFACTS"
cp -R "$APP_SOURCE" "$APP_DESTINATION"
FRAMEWORKS="$APP_DESTINATION/Contents/Frameworks"
mkdir -p "$FRAMEWORKS"

if [[ ! -f "$APP_DESTINATION/Contents/Resources/LICENSE" ]] ||
   [[ ! -f "$APP_DESTINATION/Contents/Resources/NOTICE.md" ]]; then
  echo "License resources are missing from the built app." >&2
  exit 1
fi

LIBMPV_PATH="$(find "$LIBMPV_ROOT" -name 'libmpv*.dylib' -type f | head -n 1)"
if [[ -z "$LIBMPV_PATH" ]]; then
  echo "Run build-libmpv.sh before packaging." >&2
  exit 1
fi
if [[ ! -f "$MPV_BRIDGE" ]]; then
  echo "libOKMPVBridge is missing; rerun build-libmpv.sh." >&2
  exit 1
fi
cp "$LIBMPV_PATH" "$FRAMEWORKS/libmpv.dylib"
install_name_tool -id '@rpath/libmpv.dylib' "$FRAMEWORKS/libmpv.dylib"
cp "$MPV_BRIDGE" "$FRAMEWORKS/libOKMPVBridge.dylib"
install_name_tool -id '@rpath/libOKMPVBridge.dylib' \
  "$FRAMEWORKS/libOKMPVBridge.dylib"

QUICKJS_PATH="$QUICKJS_ROOT/lib/libOKQuickJS.dylib"
if [[ ! -f "$QUICKJS_PATH" ]]; then
  echo "Run build-quickjs.sh before packaging." >&2
  exit 1
fi
cp "$QUICKJS_PATH" "$FRAMEWORKS/libOKQuickJS.dylib"
install_name_tool -id '@rpath/libOKQuickJS.dylib' "$FRAMEWORKS/libOKQuickJS.dylib"
mkdir -p "$APP_DESTINATION/Contents/Resources/Licenses"
cp "$QUICKJS_ROOT/LICENSE" \
  "$APP_DESTINATION/Contents/Resources/Licenses/QuickJS-MIT.txt"
cp "$LIBMPV_ROOT/licenses/"* \
  "$APP_DESTINATION/Contents/Resources/Licenses/"

if [[ ! -x "$NODE_RUNTIME" ]]; then
  echo "Bundled Node runtime is missing; set OKVIDEOMAC_NODE_RUNTIME." >&2
  exit 1
fi
if [[ ! -f "$APP_DESTINATION/Contents/Resources/Licenses/Node.js-LICENSE.txt" ]]; then
  echo "Bundled Node.js license is missing." >&2
  exit 1
fi

pending=(
  "$EXECUTABLE"
  "$NODE_RUNTIME"
  "$FRAMEWORKS/libmpv.dylib"
  "$FRAMEWORKS/libOKMPVBridge.dylib"
  "$FRAMEWORKS/libOKQuickJS.dylib"
)
processed=()
while [[ "${#pending[@]}" -gt 0 ]]; do
  binary="${pending[0]}"
  pending=("${pending[@]:1}")
  processed+=("$binary")
  while IFS= read -r dependency; do
    case "$dependency" in
      /opt/homebrew/*|/opt/local/*|/usr/local/*)
        base="$(basename "$dependency")"
        destination="$FRAMEWORKS/$base"
        if [[ ! -f "$destination" ]]; then
          cp "$dependency" "$destination"
          chmod u+w "$destination"
          install_name_tool -id "@rpath/$base" "$destination"
          pending+=("$destination")
        fi
        install_name_tool -change "$dependency" "@rpath/$base" "$binary"
        ;;
    esac
  done < <(otool -L "$binary" | tail -n +2 | awk '{print $1}')
  while IFS= read -r search_path; do
    case "$search_path" in
      /opt/homebrew/*|/opt/local/*|/usr/local/*|/Users/*)
        install_name_tool -delete_rpath "$search_path" "$binary"
        ;;
    esac
  done < <(
    otool -l "$binary" |
      awk '$1 == "cmd" && $2 == "LC_RPATH" {
        getline
        getline
        print $2
      }'
  )
done

for ((index=${#processed[@]} - 1; index >= 0; index--)); do
  codesign --force --sign - --timestamp=none "${processed[$index]}"
done
codesign --force --sign - --timestamp=none "$APP_DESTINATION"

"$SCRIPT_DIR/verify-bundle.sh" "$APP_DESTINATION"
rm -f "$ARCHIVE" "$ARCHIVE.sha256"
ditto -c -k --sequesterRsrc --keepParent "$APP_DESTINATION" "$ARCHIVE"
(
  cd "$ARTIFACTS"
  shasum -a 256 "$(basename "$ARCHIVE")" > "$(basename "$ARCHIVE").sha256"
)
echo "Packaged app: $APP_DESTINATION"
echo "Archive: $ARCHIVE"
