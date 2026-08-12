#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/build-environment.sh"

REPRO_ROOT="${OKVIDEOMAC_REPRO_ROOT:-$OKVIDEOMAC_BUILD_ROOT/ReproNative}"
SOURCE_APP="${OKVIDEOMAC_EXPERIMENT_SOURCE_APP:-$OKVIDEOMAC_BUILD_ROOT/Artifacts/OKVideoMac.app}"
DESTINATION_APP="${OKVIDEOMAC_EXPERIMENT_APP:-$REPRO_ROOT/OKVideoMac-ReproBuild.app}"
FFMPEG_PREFIX="$REPRO_ROOT/prefix"
MPV_PREFIX="$REPRO_ROOT/mpv-prefix"

if [[ ! -d "$SOURCE_APP" ]]; then
  echo "Stable source App is missing: $SOURCE_APP" >&2
  exit 1
fi
case "$DESTINATION_APP" in
  /|/Applications|/Users|*/Desktop/OKVideoMac.app)
    echo "Unsafe experiment destination: $DESTINATION_APP" >&2
    exit 64
    ;;
esac

rm -rf "$DESTINATION_APP"
mkdir -p "$(dirname "$DESTINATION_APP")"
cp -R "$SOURCE_APP" "$DESTINATION_APP"
FRAMEWORKS="$DESTINATION_APP/Contents/Frameworks"

libmpv="$(find "$MPV_PREFIX/lib" -type f -name 'libmpv*.dylib' | head -1)"
cp "$libmpv" "$FRAMEWORKS/libmpv.dylib"
cp "$MPV_PREFIX/lib/libOKMPVBridge.dylib" "$FRAMEWORKS/libOKMPVBridge.dylib"
replaced=(
  "$FRAMEWORKS/libmpv.dylib"
  "$FRAMEWORKS/libOKMPVBridge.dylib"
)
for name in \
  libavcodec.61.dylib \
  libavfilter.10.dylib \
  libavformat.61.dylib \
  libavutil.59.dylib \
  libswresample.5.dylib \
  libswscale.8.dylib; do
  cp "$FFMPEG_PREFIX/lib/$name" "$FRAMEWORKS/$name"
  replaced+=("$FRAMEWORKS/$name")
done

for binary in "${replaced[@]}"; do
  base="$(basename "$binary")"
  chmod u+w "$binary"
  install_name_tool -id "@rpath/$base" "$binary"
  while IFS= read -r dependency; do
    case "$dependency" in
      "$REPRO_ROOT"/*|/opt/local/*)
        dependency_base="$(basename "$dependency")"
        case "$dependency_base" in
          libmpv*.dylib) dependency_base="libmpv.dylib" ;;
        esac
        if [[ ! -f "$FRAMEWORKS/$dependency_base" ]]; then
          echo "Experiment dependency is absent from App: $dependency" >&2
          exit 1
        fi
        install_name_tool -change "$dependency" "@rpath/$dependency_base" "$binary"
        ;;
    esac
  done < <(otool -L "$binary" | tail -n +2 | awk '{print $1}')
  while IFS= read -r search_path; do
    case "$search_path" in
      "$REPRO_ROOT"/*|/opt/local/*|/Users/*)
        install_name_tool -delete_rpath "$search_path" "$binary"
        ;;
    esac
  done < <(
    otool -l "$binary" |
      awk '$1 == "cmd" && $2 == "LC_RPATH" {getline; getline; print $2}'
  )
done

for ((index=${#replaced[@]} - 1; index >= 0; index--)); do
  codesign --force --sign - --options runtime --timestamp=none "${replaced[$index]}"
done
codesign --force --sign - --options runtime --timestamp=none \
  --entitlements "$PROJECT_DIR/Supporting/OKVideoMac.dev.entitlements" \
  "$DESTINATION_APP"
codesign --verify --deep --strict --verbose=2 "$DESTINATION_APP"

failure=0
while IFS= read -r binary; do
  if otool -L "$binary" | grep -Eq "$REPRO_ROOT|/opt/local|/opt/homebrew|/usr/local|/Users/"; then
    echo "Experiment App retains a nonportable dependency: $binary" >&2
    failure=1
  fi
done < <(find "$DESTINATION_APP/Contents" -type f -print0 | xargs -0 file | awk -F: '/Mach-O/{print $1}')
if [[ "$failure" -ne 0 ]]; then
  exit 1
fi

echo "Experimental App created without replacing the stable App: $DESTINATION_APP"
