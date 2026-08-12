#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/build-environment.sh"

REPRO_ROOT="${OKVIDEOMAC_REPRO_ROOT:-$OKVIDEOMAC_BUILD_ROOT/ReproNative}"
DOWNLOAD_ROOT="${OKVIDEOMAC_NATIVE_DOWNLOADS:-$OKVIDEOMAC_BUILD_ROOT/Downloads}"
ARCHIVE="$DOWNLOAD_ROOT/ffmpeg-7.1.4.tar.xz"
EXPECTED_SHA256="71f4aac3573ed9060489cb62526a6c7dda815ae10993789611acd7be9fa9fbf4"
SOURCE_DIR="$REPRO_ROOT/src/ffmpeg-7.1.4"
BUILD_DIR="$REPRO_ROOT/build/ffmpeg-7.1.4"
PREFIX="$REPRO_ROOT/prefix"
REPORT_DIR="$REPRO_ROOT/reports"
STABLE_PREFIX="${OKVIDEOMAC_STABLE_NATIVE_PREFIX:-/opt/local}"
BUILD_JOBS="${OKVIDEOMAC_BUILD_JOBS:-4}"

case "$REPRO_ROOT" in
  /|/opt/local|/usr|/System|/Library|/Users)
    echo "Unsafe OKVIDEOMAC_REPRO_ROOT: $REPRO_ROOT" >&2
    exit 64
    ;;
esac

for tool in clang make shasum tar lipo otool nm; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Required tool missing: $tool" >&2
    exit 1
  fi
done
if [[ ! -f "$ARCHIVE" ]]; then
  echo "Locked FFmpeg archive is missing: $ARCHIVE" >&2
  exit 1
fi
actual_sha256="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
if [[ "$actual_sha256" != "$EXPECTED_SHA256" ]]; then
  echo "FFmpeg source checksum mismatch: $actual_sha256" >&2
  exit 1
fi

mkdir -p "$REPRO_ROOT/src" "$REPRO_ROOT/build" "$PREFIX" "$REPORT_DIR"
rm -rf "$SOURCE_DIR" "$BUILD_DIR"
tar -xJf "$ARCHIVE" -C "$REPRO_ROOT/src"
mkdir -p "$BUILD_DIR"

export MACOSX_DEPLOYMENT_TARGET=12.0
export PKG_CONFIG=/opt/local/bin/pkg-config
export PKG_CONFIG_LIBDIR=/opt/local/lib/pkgconfig:/opt/local/share/pkgconfig
configure_flags=(
  "--prefix=$PREFIX"
  "--libdir=$PREFIX/lib"
  "--incdir=$PREFIX/include"
  "--pkgconfigdir=$PREFIX/lib/pkgconfig"
  --arch=arm64
  --target-os=darwin
  --cc=/usr/bin/clang
  --cxx=/usr/bin/clang++
  --pkg-config=/opt/local/bin/pkg-config
  --enable-shared
  --disable-static
  --enable-pic
  --disable-programs
  --disable-doc
  --disable-debug
  --disable-avdevice
  --disable-autodetect
  --enable-network
  --enable-securetransport
  --enable-videotoolbox
  --enable-audiotoolbox
  --enable-zlib
  --enable-bzlib
  --enable-iconv
  --enable-lzma
  --enable-pthreads
  --disable-sdl2
  "--extra-cflags=-O2 -arch arm64 -mmacosx-version-min=12.0 -I/opt/local/include"
  "--extra-cxxflags=-O2 -arch arm64 -mmacosx-version-min=12.0 -I/opt/local/include"
  "--extra-ldflags=-arch arm64 -mmacosx-version-min=12.0 -L/opt/local/lib"
  --extra-libs=-liconv
)
(
  cd "$BUILD_DIR"
  "$SOURCE_DIR/configure" "${configure_flags[@]}"
  make -j"$BUILD_JOBS"
  make install
)

expected_outputs=(
  libavcodec.61.dylib
  libavfilter.10.dylib
  libavformat.61.dylib
  libavutil.59.dylib
  libswresample.5.dylib
  libswscale.8.dylib
)
for output in "${expected_outputs[@]}"; do
  rebuilt="$PREFIX/lib/$output"
  stable="$STABLE_PREFIX/lib/$output"
  if [[ ! -f "$rebuilt" || ! -f "$stable" ]]; then
    echo "FFmpeg comparison input missing: $output" >&2
    exit 1
  fi
  if ! lipo -info "$rebuilt" | grep -q arm64; then
    echo "Rebuilt FFmpeg output is not arm64: $rebuilt" >&2
    exit 1
  fi
  min_version="$(otool -l "$rebuilt" | awk '/LC_BUILD_VERSION/{found=1} found && /minos/{print $2; exit}')"
  if [[ "$min_version" != "12.0" ]]; then
    echo "Unexpected deployment target for $output: $min_version" >&2
    exit 1
  fi
  nm -gjU "$stable" | LC_ALL=C sort -u > "$REPORT_DIR/$output.stable-symbols.txt"
  nm -gjU "$rebuilt" | LC_ALL=C sort -u > "$REPORT_DIR/$output.rebuilt-symbols.txt"
  if ! diff -u "$REPORT_DIR/$output.stable-symbols.txt" \
    "$REPORT_DIR/$output.rebuilt-symbols.txt" > "$REPORT_DIR/$output.symbol-diff.txt"; then
    echo "Public symbol mismatch for $output" >&2
    exit 1
  fi
done

SMOKE="$REPRO_ROOT/bin/ffmpeg-smoke"
mkdir -p "$(dirname "$SMOKE")"
clang -arch arm64 -mmacosx-version-min=12.0 \
  -I"$PREFIX/include" \
  "$PROJECT_DIR/Native/FFmpegSmoke/ffmpeg-smoke.c" \
  -L"$PREFIX/lib" -lavformat -lavcodec -lavutil \
  -Wl,-rpath,"$PREFIX/lib" \
  -o "$SMOKE"
"$SMOKE" | tee "$REPORT_DIR/ffmpeg-smoke.txt"

{
  echo "source_sha256=$actual_sha256"
  echo "architecture=arm64"
  echo "deployment_target=12.0"
  echo "compiler=$(clang --version | head -1)"
  echo "sdk=$(xcrun --sdk macosx --show-sdk-version)"
  echo "stable_prefix=$STABLE_PREFIX"
  printf 'configure='
  printf '%q ' "${configure_flags[@]}"
  echo
  for output in "${expected_outputs[@]}"; do
    shasum -a 256 "$PREFIX/lib/$output"
  done
} > "$REPORT_DIR/FFMPEG_REPRO_BUILD.txt"

echo "FFmpeg reproducibility experiment completed: $REPRO_ROOT"
