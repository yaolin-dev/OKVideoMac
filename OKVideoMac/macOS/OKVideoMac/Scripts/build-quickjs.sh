#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/build-environment.sh"

BUILD_ROOT="$OKVIDEOMAC_BUILD_ROOT/QuickJS"
BRIDGE_ROOT="$PROJECT_DIR/Native/QuickJSBridge"
SOURCE_ROOT="$OKVIDEOMAC_BUILD_ROOT/Source"
DOWNLOAD_ROOT="$OKVIDEOMAC_BUILD_ROOT/Downloads"
ARCHIVE="$DOWNLOAD_ROOT/quickjs-2025-09-13-2.tar.xz"
SOURCE_DIR="$SOURCE_ROOT/quickjs-2025-09-13"
URL="https://bellard.org/quickjs/quickjs-2025-09-13-2.tar.xz"
EXPECTED_SHA256="996c6b5018fc955ad4d06426d0e9cb713685a00c825aa5c0418bd53f7df8b0b4"

for tool in curl shasum make clang tar; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Required tool missing: $tool" >&2
    exit 1
  fi
done

mkdir -p "$DOWNLOAD_ROOT" "$SOURCE_ROOT" "$BUILD_ROOT/include" "$BUILD_ROOT/lib"
if [[ ! -f "$ARCHIVE" ]]; then
  curl -L --fail --show-error "$URL" -o "$ARCHIVE"
fi

actual_sha256="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
if [[ "$actual_sha256" != "$EXPECTED_SHA256" ]]; then
  echo "QuickJS source checksum mismatch: $actual_sha256" >&2
  exit 1
fi

if [[ ! -d "$SOURCE_DIR" ]]; then
  tar -xJf "$ARCHIVE" -C "$SOURCE_ROOT"
fi

make -C "$SOURCE_DIR" clean
make -C "$SOURCE_DIR" \
  CC=clang \
  CFLAGS_OPT="-O2 -fwrapv -D_GNU_SOURCE -DCONFIG_VERSION=\\\"2025-09-13\\\" -fPIC -arch arm64 -mmacosx-version-min=12.0" \
  libquickjs.a

cp "$SOURCE_DIR/libquickjs.a" "$BUILD_ROOT/lib/"
cp "$SOURCE_DIR/quickjs.h" "$SOURCE_DIR/quickjs-libc.h" "$BUILD_ROOT/include/"
cp "$SOURCE_DIR/LICENSE" "$BUILD_ROOT/LICENSE"

clang \
  -dynamiclib \
  -arch arm64 \
  -mmacosx-version-min=12.0 \
  -I"$BUILD_ROOT/include" \
  "$BRIDGE_ROOT/OKQuickJSBridge.c" \
  -Wl,-force_load,"$BUILD_ROOT/lib/libquickjs.a" \
  -Wl,-install_name,@rpath/libOKQuickJS.dylib \
  -o "$BUILD_ROOT/lib/libOKQuickJS.dylib"

/usr/bin/codesign \
  --force \
  --sign - \
  --timestamp=none \
  "$BUILD_ROOT/lib/libOKQuickJS.dylib"

clang \
  -arch arm64 \
  -mmacosx-version-min=12.0 \
  -I"$BRIDGE_ROOT" \
  "$BRIDGE_ROOT/smoke.c" \
  -L"$BUILD_ROOT/lib" \
  -lOKQuickJS \
  -Wl,-rpath,"$BUILD_ROOT/lib" \
  -o "$BUILD_ROOT/quickjs-bridge-smoke"

"$BUILD_ROOT/quickjs-bridge-smoke"
if ! lipo -info "$BUILD_ROOT/lib/libOKQuickJS.dylib" | grep -q 'arm64'; then
  echo "QuickJS bridge is not arm64." >&2
  exit 1
fi

file "$BUILD_ROOT/lib/libquickjs.a"
otool -L "$BUILD_ROOT/lib/libOKQuickJS.dylib"
echo "QuickJS built at $BUILD_ROOT"
