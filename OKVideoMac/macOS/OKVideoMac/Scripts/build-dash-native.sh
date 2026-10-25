#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/build-environment.sh"
REPRO_ROOT="${OKVIDEOMAC_REPRO_ROOT:-$OKVIDEOMAC_BUILD_ROOT/ReproNative}"
if [[ "${1:-}" != "--stage-built" ]]; then
  DOWNLOADS="${OKVIDEOMAC_NATIVE_DOWNLOADS:-$OKVIDEOMAC_BUILD_ROOT/Downloads}"
  mkdir -p "$DOWNLOADS"
  if [[ ! -f "$DOWNLOADS/ffmpeg-7.1.4.tar.xz" ]]; then
    curl --fail --location --retry 3 https://ffmpeg.org/releases/ffmpeg-7.1.4.tar.xz \
      -o "$DOWNLOADS/ffmpeg-7.1.4.tar.xz"
  fi
  if [[ ! -f "$DOWNLOADS/mpv-v0.41.0.tar.gz" ]]; then
    curl --fail --location --retry 3 https://github.com/mpv-player/mpv/archive/refs/tags/v0.41.0.tar.gz \
      -o "$DOWNLOADS/mpv-v0.41.0.tar.gz"
  fi
  # Each stage validates its locked archive checksum before extracting it.
  "$SCRIPT_DIR/build-libxml2.sh"
  "$SCRIPT_DIR/build-third-party-native.sh"
  "$SCRIPT_DIR/build-libmpv-repro.sh"
fi
SOURCE="$REPRO_ROOT/mpv-prefix"
DESTINATION="$OKVIDEOMAC_BUILD_ROOT/libmpv"
python3 "$SCRIPT_DIR/mpv-coreaudio-provenance.py" verify \
  --library "$SOURCE/lib/libmpv.2.dylib" --receipt "$SOURCE/coreaudio-build.json"
mkdir -p "$DESTINATION/lib" "$DESTINATION/include" "$DESTINATION/licenses"
cp -R "$SOURCE/include/mpv" "$DESTINATION/include/"
cp "$SOURCE/lib/libmpv.2.dylib" "$DESTINATION/lib/libmpv.dylib"
install_name_tool -id '@rpath/libmpv.dylib' "$DESTINATION/lib/libmpv.dylib"
cp "$PROJECT_DIR/../../THIRD_PARTY_LICENSES/"* "$DESTINATION/licenses/"
python3 "$SCRIPT_DIR/mpv-coreaudio-provenance.py" record \
  --source "$REPRO_ROOT/src/mpv-0.41.0" --library "$DESTINATION/lib/libmpv.dylib" \
  --receipt "$DESTINATION/coreaudio-build.json"
"$SCRIPT_DIR/build-mpv-bridge.sh"
echo "DASH native libraries staged: $DESTINATION"
