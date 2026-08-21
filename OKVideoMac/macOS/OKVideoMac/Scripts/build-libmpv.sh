#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/build-environment.sh"

BUILD_ROOT="$OKVIDEOMAC_BUILD_ROOT/libmpv"
SOURCE_ROOT="$OKVIDEOMAC_BUILD_ROOT/Source"
DOWNLOAD_ROOT="$OKVIDEOMAC_BUILD_ROOT/Downloads"
ARCHIVE="$DOWNLOAD_ROOT/mpv-v0.41.0.tar.gz"
SOURCE_DIR="$SOURCE_ROOT/mpv-0.41.0"
MESON_BUILD_DIR="$SOURCE_ROOT/mpv-0.41.0-build"
PATCH_FILE="$PROJECT_DIR/Patches/mpv-0.41.0-coreaudio-without-cocoa.patch"
URL="https://github.com/mpv-player/mpv/archive/refs/tags/v0.41.0.tar.gz"
EXPECTED_SHA256="ee21092a5ee427353392360929dc64645c54479aefdb5babc5cfbb5fad626209"

if ! xcodebuild -version >/dev/null 2>&1; then
  echo "Full Xcode is required to build libmpv." >&2
  exit 1
fi
for tool in curl shasum tar otool lipo; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Required tool missing: $tool" >&2
    exit 1
  fi
done
if [[ ! -f "$PATCH_FILE" ]]; then
  echo "Required mpv patch missing: $PATCH_FILE" >&2
  exit 1
fi
for macports_tool in meson ninja pkg-config; do
  if [[ ! -x "/opt/local/bin/$macports_tool" ]]; then
    echo "Required MacPorts tool missing: /opt/local/bin/$macports_tool" >&2
    exit 1
  fi
done
for package in libavcodec libavfilter libavformat libavutil libswresample libswscale libass libplacebo; do
  if ! "$PKG_CONFIG" --exists "$package"; then
    echo "Required pkg-config package missing: $package" >&2
    exit 1
  fi
  package_pc_dir="$("$PKG_CONFIG" --variable=pcfiledir "$package")"
  if [[ "$package_pc_dir" != /opt/local/* ]]; then
    echo "pkg-config package is not from MacPorts: $package -> $package_pc_dir" >&2
    exit 1
  fi
done
if "$PKG_CONFIG" --cflags --libs \
  libavcodec libavfilter libavformat libavutil libswresample libswscale libass libplacebo |
  grep -q '/opt/homebrew'; then
  echo "Homebrew path detected in native dependency flags." >&2
  exit 1
fi

mkdir -p "$DOWNLOAD_ROOT" "$SOURCE_ROOT" "$BUILD_ROOT"
if [[ ! -f "$ARCHIVE" ]]; then
  curl -L --fail --show-error "$URL" -o "$ARCHIVE"
fi
actual_sha256="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
if [[ "$actual_sha256" != "$EXPECTED_SHA256" ]]; then
  echo "mpv source checksum mismatch: $actual_sha256" >&2
  exit 1
fi
if [[ ! -d "$SOURCE_DIR" ]]; then
  tar -xzf "$ARCHIVE" -C "$SOURCE_ROOT"
fi
if ! grep -q "sources += files('osdep/utils-mac.c')" "$SOURCE_DIR/meson.build"; then
  /usr/bin/patch -d "$SOURCE_DIR" -p1 -i "$PATCH_FILE"
fi

rm -rf "$MESON_BUILD_DIR"
MACOSX_DEPLOYMENT_TARGET=12.0 /opt/local/bin/meson setup "$MESON_BUILD_DIR" "$SOURCE_DIR" \
  --prefix "$BUILD_ROOT" \
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

MACOSX_DEPLOYMENT_TARGET=12.0 /opt/local/bin/meson compile -C "$MESON_BUILD_DIR"
/opt/local/bin/meson install -C "$MESON_BUILD_DIR"
mkdir -p "$BUILD_ROOT/licenses"
cp "$SOURCE_DIR/LICENSE.GPL" "$BUILD_ROOT/licenses/mpv-GPL-2.0-or-later.txt"
cp "$SOURCE_DIR/LICENSE.LGPL" "$BUILD_ROOT/licenses/mpv-LGPL-2.1-or-later.txt"
cp "$SOURCE_DIR/Copyright" "$BUILD_ROOT/licenses/mpv-Copyright.txt"

LIBMPV_PATH="$(find "$BUILD_ROOT" -name 'libmpv*.dylib' -type f | head -n 1)"
if [[ -z "$LIBMPV_PATH" ]]; then
  echo "libmpv dylib was not produced." >&2
  exit 1
fi
chmod u+w "$LIBMPV_PATH"
install_name_tool -id '@rpath/libmpv.dylib' "$LIBMPV_PATH"

BRIDGE_SOURCE="$PROJECT_DIR/Native/MPVBridge/OKMPVBridge.c"
BRIDGE_OUTPUT="$BUILD_ROOT/lib/libOKMPVBridge.dylib"
BRIDGE_SMOKE="$BUILD_ROOT/bin/mpv-bridge-smoke"
FFMPEG_CFLAGS=( $("$PKG_CONFIG" --cflags libavformat libavcodec libavutil) )
FFMPEG_LIBS=( $("$PKG_CONFIG" --libs libavformat libavcodec libavutil) )
mkdir -p "$(dirname "$BRIDGE_OUTPUT")"
MACOSX_DEPLOYMENT_TARGET=12.0 clang \
  -arch arm64 \
  -std=c11 \
  -Wall \
  -Wextra \
  -Werror \
  -dynamiclib \
  -mmacosx-version-min=12.0 \
  "${FFMPEG_CFLAGS[@]}" \
  -I"$BUILD_ROOT/include" \
  "$BRIDGE_SOURCE" \
  -L"$(dirname "$LIBMPV_PATH")" \
  -lmpv \
  "${FFMPEG_LIBS[@]}" \
  -Wl,-install_name,@rpath/libOKMPVBridge.dylib \
  -Wl,-rpath,@loader_path \
  -o "$BRIDGE_OUTPUT"
mkdir -p "$(dirname "$BRIDGE_SMOKE")"
MACOSX_DEPLOYMENT_TARGET=12.0 clang \
  -arch arm64 \
  -std=c11 \
  -Wall \
  -Wextra \
  -Werror \
  -mmacosx-version-min=12.0 \
  -I"$PROJECT_DIR/Native/MPVBridge" \
  "$PROJECT_DIR/Native/MPVBridge/smoke.c" \
  -L"$(dirname "$BRIDGE_OUTPUT")" \
  -lOKMPVBridge \
  -Wl,-rpath,@executable_path/../lib \
  -o "$BRIDGE_SMOKE"
"$BRIDGE_SMOKE"

if ! lipo -info "$LIBMPV_PATH" | grep -q 'arm64'; then
  echo "libmpv is not arm64: $LIBMPV_PATH" >&2
  exit 1
fi
if ! lipo -info "$BRIDGE_OUTPUT" | grep -q 'arm64'; then
  echo "libOKMPVBridge is not arm64: $BRIDGE_OUTPUT" >&2
  exit 1
fi
for binary in "$LIBMPV_PATH" "$BRIDGE_OUTPUT"; do
  min_version="$(otool -l "$binary" | awk '/LC_BUILD_VERSION/{found=1} found && /minos/{print $2; exit}')"
  if [[ "$min_version" != "12.0" ]]; then
    echo "Unexpected macOS deployment target for $binary: ${min_version:-missing}" >&2
    exit 1
  fi
  if otool -L "$binary" | grep -q '/opt/homebrew'; then
    echo "Homebrew dependency detected in $binary." >&2
    exit 1
  fi
done
otool -L "$LIBMPV_PATH"
otool -L "$BRIDGE_OUTPUT"
echo "libmpv built at $LIBMPV_PATH"
echo "mpv bridge built at $BRIDGE_OUTPUT"
