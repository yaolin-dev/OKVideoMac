#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/build-environment.sh"

LIBMPV_ROOT="$OKVIDEOMAC_BUILD_ROOT/libmpv"
LIBMPV_PATH="$(find "$LIBMPV_ROOT" -name 'libmpv*.dylib' -type f | head -n 1)"
BRIDGE_SOURCE="$PROJECT_DIR/Native/MPVBridge/OKMPVBridge.c"
BRIDGE_OUTPUT="$LIBMPV_ROOT/lib/libOKMPVBridge.dylib"
BRIDGE_SMOKE="$LIBMPV_ROOT/bin/mpv-bridge-smoke"

if [[ -z "$LIBMPV_PATH" ]] || [[ ! -d "$LIBMPV_ROOT/include" ]]; then
  echo "Existing libmpv headers/library are required; run build-libmpv.sh first." >&2
  exit 1
fi
for package in libavformat libavcodec libavutil; do
  if ! "$PKG_CONFIG" --exists "$package"; then
    echo "Required pkg-config package is missing: $package" >&2
    exit 1
  fi
done

FFMPEG_CFLAGS=( $("$PKG_CONFIG" --cflags libavformat libavcodec libavutil) )
FFMPEG_LIBS=( $("$PKG_CONFIG" --libs libavformat libavcodec libavutil) )
mkdir -p "$(dirname "$BRIDGE_OUTPUT")" "$(dirname "$BRIDGE_SMOKE")"

MACOSX_DEPLOYMENT_TARGET=12.0 clang \
  -arch arm64 \
  -std=c11 \
  -Wall \
  -Wextra \
  -Werror \
  -dynamiclib \
  -mmacosx-version-min=12.0 \
  "${FFMPEG_CFLAGS[@]}" \
  -I"$LIBMPV_ROOT/include" \
  "$BRIDGE_SOURCE" \
  -L"$(dirname "$LIBMPV_PATH")" \
  -lmpv \
  "${FFMPEG_LIBS[@]}" \
  -Wl,-install_name,@rpath/libOKMPVBridge.dylib \
  -Wl,-rpath,@loader_path \
  -o "$BRIDGE_OUTPUT"

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

required_symbols=(
  okmpv_create
  okmpv_initialize
  okmpv_get_property_string
  okmpv_set_property_string
  okmpv_event_size
  okmpv_render_create
  okmpv_render_destroy
)
exported_symbols="$(nm -gU "$BRIDGE_OUTPUT" | awk '{print $NF}')"
for symbol in "${required_symbols[@]}"; do
  if ! grep -qx "_$symbol" <<< "$exported_symbols"; then
    echo "libOKMPVBridge is missing required symbol: $symbol" >&2
    exit 1
  fi
done

echo "mpv bridge rebuilt and verified at $BRIDGE_OUTPUT"
