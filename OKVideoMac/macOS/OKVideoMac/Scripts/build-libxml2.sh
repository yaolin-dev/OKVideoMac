#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/build-environment.sh"
ROOT="${OKVIDEOMAC_REPRO_ROOT:-$OKVIDEOMAC_BUILD_ROOT/ReproNative}"
DOWNLOADS="${OKVIDEOMAC_NATIVE_DOWNLOADS:-$OKVIDEOMAC_BUILD_ROOT/Downloads}"
VERSION=2.15.4
SHA256=98087fd181d9070724f3fbc65c7377db03038eb92bd882374daff44940138821
ARCHIVE="$DOWNLOADS/libxml2-$VERSION.tar.xz"
SOURCE="$ROOT/src/libxml2-$VERSION"
BUILD="$ROOT/build/libxml2-$VERSION"
PREFIX="$ROOT/xml-prefix"
case "$ROOT" in /|/opt/local|/usr|/System|/Library|/Users) exit 64 ;; esac
mkdir -p "$DOWNLOADS" "$ROOT/src" "$ROOT/build" "$ROOT/reports"
if [[ ! -f "$ARCHIVE" ]]; then
  curl --fail --location --show-error "https://download.gnome.org/sources/libxml2/2.15/libxml2-$VERSION.tar.xz" -o "$ARCHIVE"
fi
[[ "$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')" == "$SHA256" ]] || {
  echo "libxml2 source checksum mismatch" >&2; exit 1;
}
rm -rf "$SOURCE" "$BUILD" "$PREFIX"
tar -xJf "$ARCHIVE" -C "$ROOT/src"
mkdir -p "$BUILD"
export MACOSX_DEPLOYMENT_TARGET=12.0
(
  cd "$BUILD"
  CFLAGS='-O2 -arch arm64 -mmacosx-version-min=12.0' \
  LDFLAGS='-arch arm64 -mmacosx-version-min=12.0' \
  "$SOURCE/configure" --prefix="$PREFIX" --enable-shared --disable-static \
    --without-python --without-programs --without-iconv --without-icu \
    --without-zlib --without-lzma
  make -j"${OKVIDEOMAC_BUILD_JOBS:-4}"
  make install
)
cp "$SOURCE/Copyright" "$PREFIX/Copyright"
{
  echo "version=$VERSION"
  echo "source_sha256=$SHA256"
  echo "architecture=arm64"
  echo "deployment_target=12.0"
  shasum -a 256 "$PREFIX"/lib/libxml2.*.dylib
} > "$ROOT/reports/LIBXML2_BUILD.txt"
