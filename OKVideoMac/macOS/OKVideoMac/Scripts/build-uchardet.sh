#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/build-environment.sh"
REPRO_ROOT="${OKVIDEOMAC_REPRO_ROOT:-$OKVIDEOMAC_BUILD_ROOT/ReproNative}"
DOWNLOADS="${OKVIDEOMAC_NATIVE_DOWNLOADS:-$OKVIDEOMAC_BUILD_ROOT/Downloads}"
ARCHIVE="$DOWNLOADS/uchardet-0.0.8.tar.xz"
HASH=e97a60cfc00a1c147a674b097bb1422abd9fa78a2d9ce3f3fdcc2e78a34ac5f0
mkdir -p "$DOWNLOADS" "$REPRO_ROOT/src" "$REPRO_ROOT/build"
if [[ ! -f "$ARCHIVE" ]]; then
  curl --fail --location --retry 3 https://www.freedesktop.org/software/uchardet/releases/uchardet-0.0.8.tar.xz -o "$ARCHIVE"
fi
[[ "$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')" == "$HASH" ]] || { echo 'uchardet checksum mismatch' >&2; exit 1; }
tar -xf "$ARCHIVE" -C "$REPRO_ROOT/src"
CMAKE="${OKVIDEOMAC_CMAKE:-cmake}"
"$CMAKE" -S "$REPRO_ROOT/src/uchardet-0.0.8" -B "$REPRO_ROOT/build/uchardet-0.0.8" \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0 \
  -DCMAKE_INSTALL_PREFIX="$REPRO_ROOT/uchardet-prefix" -DBUILD_SHARED_LIBS=OFF -DBUILD_BINARY=OFF \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON
"$CMAKE" --build "$REPRO_ROOT/build/uchardet-0.0.8" --parallel 4
"$CMAKE" --install "$REPRO_ROOT/build/uchardet-0.0.8"
# mpv links this small detector statically. Its C API needs the C++ runtime.
python3 - "$REPRO_ROOT/uchardet-prefix/lib/pkgconfig/uchardet.pc" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
if '-lc++' not in s:
    p.write_text(s.replace('-luchardet', '-luchardet -lc++'))
PY
