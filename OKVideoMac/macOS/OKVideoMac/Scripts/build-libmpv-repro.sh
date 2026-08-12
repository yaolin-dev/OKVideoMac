#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/build-environment.sh"

REPRO_ROOT="${OKVIDEOMAC_REPRO_ROOT:-$OKVIDEOMAC_BUILD_ROOT/ReproNative}"
DOWNLOAD_ROOT="${OKVIDEOMAC_NATIVE_DOWNLOADS:-$OKVIDEOMAC_BUILD_ROOT/Downloads}"
ARCHIVE="$DOWNLOAD_ROOT/mpv-v0.41.0.tar.gz"
EXPECTED_SHA256="ee21092a5ee427353392360929dc64645c54479aefdb5babc5cfbb5fad626209"
SOURCE_DIR="$REPRO_ROOT/src/mpv-0.41.0"
BUILD_DIR="$REPRO_ROOT/build/mpv-0.41.0"
PREFIX="$REPRO_ROOT/mpv-prefix"
PATCH_FILE="$PROJECT_DIR/Patches/mpv-0.41.0-coreaudio-without-cocoa.patch"
FFMPEG_PREFIX="$REPRO_ROOT/prefix"
REPORT_DIR="$REPRO_ROOT/reports"

for tool in shasum tar lipo otool clang; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Required tool missing: $tool" >&2
    exit 1
  fi
done
for tool in /opt/local/bin/meson /opt/local/bin/ninja /opt/local/bin/pkg-config; do
  if [[ ! -x "$tool" ]]; then
    echo "Required build tool missing: $tool" >&2
    exit 1
  fi
done
if [[ ! -f "$ARCHIVE" || ! -f "$PATCH_FILE" ]]; then
  echo "Locked mpv source or patch is missing." >&2
  exit 1
fi
if [[ "$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')" != "$EXPECTED_SHA256" ]]; then
  echo "mpv source checksum mismatch." >&2
  exit 1
fi

export PKG_CONFIG=/opt/local/bin/pkg-config
export PKG_CONFIG_LIBDIR="$FFMPEG_PREFIX/lib/pkgconfig:/opt/local/lib/pkgconfig:/opt/local/share/pkgconfig"
for package in libavcodec libavfilter libavformat libavutil libswresample libswscale; do
  pc_dir="$($PKG_CONFIG --variable=pcfiledir "$package")"
  if [[ "$pc_dir" != "$FFMPEG_PREFIX/lib/pkgconfig" ]]; then
    echo "Repro FFmpeg pkg-config input not selected: $package -> $pc_dir" >&2
    exit 1
  fi
done
for package in libass libplacebo; do
  pc_dir="$($PKG_CONFIG --variable=pcfiledir "$package")"
  if [[ "$pc_dir" != /opt/local/* ]]; then
    echo "Expected receipt-locked MacPorts input: $package -> $pc_dir" >&2
    exit 1
  fi
done

mkdir -p "$REPRO_ROOT/src" "$REPRO_ROOT/build" "$PREFIX" "$REPORT_DIR"
rm -rf "$SOURCE_DIR" "$BUILD_DIR" "$PREFIX"
tar -xzf "$ARCHIVE" -C "$REPRO_ROOT/src"
/usr/bin/patch -d "$SOURCE_DIR" -p1 -i "$PATCH_FILE"

export MACOSX_DEPLOYMENT_TARGET=12.0
/opt/local/bin/meson setup "$BUILD_DIR" "$SOURCE_DIR" \
  --prefix "$PREFIX" \
  --buildtype release \
  -Dcplayer=false \
  -Dlibmpv=true \
  -Dbuild-date=false \
  -Dtests=false \
  -Dfuzzers=false \
  -Dswift-build=disabled \
  -Dmacos-cocoa-cb=disabled \
  -Dmacos-media-player=disabled \
  -Dmacos-touchbar=disabled \
  -Djavascript=disabled \
  -Dlua=disabled \
  -Dcplugins=disabled \
  -Dvapoursynth=disabled \
  -Dlibavdevice=disabled \
  -Dplain-gl=enabled \
  -Dgl=enabled \
  -Dcocoa=disabled \
  -Dvideotoolbox-gl=disabled \
  -Dcoreaudio=enabled
/opt/local/bin/meson compile -C "$BUILD_DIR"
/opt/local/bin/meson install -C "$BUILD_DIR"

LIBMPV="$(find "$PREFIX/lib" -type f -name 'libmpv*.dylib' | head -1)"
if [[ -z "$LIBMPV" ]] || ! lipo -info "$LIBMPV" | grep -q arm64; then
  echo "Repro libmpv is missing or not arm64." >&2
  exit 1
fi
for library in libavcodec libavfilter libavformat libavutil libswresample libswscale; do
  if ! otool -L "$LIBMPV" | grep -q "$FFMPEG_PREFIX/lib/$library"; then
    echo "Repro libmpv did not link against repro $library." >&2
    exit 1
  fi
done

BRIDGE="$PREFIX/lib/libOKMPVBridge.dylib"
SMOKE="$PREFIX/bin/mpv-bridge-smoke"
clang -arch arm64 -std=c11 -Wall -Wextra -Werror -dynamiclib \
  -mmacosx-version-min=12.0 \
  -I"$PREFIX/include" \
  "$PROJECT_DIR/Native/MPVBridge/OKMPVBridge.c" \
  -L"$(dirname "$LIBMPV")" -lmpv \
  -Wl,-install_name,@rpath/libOKMPVBridge.dylib \
  -Wl,-rpath,"$(dirname "$LIBMPV")" \
  -o "$BRIDGE"
mkdir -p "$(dirname "$SMOKE")"
clang -arch arm64 -std=c11 -Wall -Wextra -Werror \
  -mmacosx-version-min=12.0 \
  -I"$PROJECT_DIR/Native/MPVBridge" \
  "$PROJECT_DIR/Native/MPVBridge/smoke.c" \
  -L"$(dirname "$BRIDGE")" -lOKMPVBridge \
  -Wl,-rpath,"$(dirname "$BRIDGE")" \
  -o "$SMOKE"
"$SMOKE" | tee "$REPORT_DIR/mpv-bridge-repro-smoke.txt"

{
  echo "source_sha256=$EXPECTED_SHA256"
  echo "patch_sha256=$(shasum -a 256 "$PATCH_FILE" | awk '{print $1}')"
  echo "architecture=arm64"
  echo "deployment_target=12.0"
  echo "compiler=$(clang --version | head -1)"
  echo "sdk=$(xcrun --sdk macosx --show-sdk-version)"
  shasum -a 256 "$LIBMPV" "$BRIDGE"
  otool -L "$LIBMPV"
} > "$REPORT_DIR/MPV_REPRO_BUILD.txt"

echo "Repro libmpv experiment completed: $PREFIX"
