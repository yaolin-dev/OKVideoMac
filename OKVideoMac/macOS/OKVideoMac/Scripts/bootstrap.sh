#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/build-environment.sh"
missing=0

echo "Checking OKVideoMac build environment"
echo "Project: $PROJECT_DIR"
echo "Build root: $OKVIDEOMAC_BUILD_ROOT"

if ! xcodebuild -version >/dev/null 2>&1; then
  echo "MISSING: full Xcode (Xcode 14.2 is the supported Monterey baseline)" >&2
  missing=1
else
  xcodebuild -version
fi

for tool in swift git curl shasum xcodegen; do
  if command -v "$tool" >/dev/null 2>&1; then
    echo "FOUND: $tool -> $(command -v "$tool")"
  else
    echo "MISSING: $tool" >&2
    missing=1
  fi
done
if [[ -x /opt/local/bin/pkg-config ]]; then
  echo "FOUND: pkg-config -> /opt/local/bin/pkg-config"
else
  echo "MISSING: MacPorts pkg-config (/opt/local/bin/pkg-config)" >&2
  missing=1
fi

if [[ "${1:-}" == "--with-native-dependencies" ]]; then
  for tool in meson ninja; do
    if [[ ! -x "/opt/local/bin/$tool" ]]; then
      echo "MISSING: MacPorts $tool (/opt/local/bin/$tool)" >&2
      missing=1
    fi
  done
  for package in libavcodec libavformat libavutil libswresample libswscale libass; do
    if [[ ! -x "$PKG_CONFIG" ]] || ! "$PKG_CONFIG" --exists "$package"; then
      echo "MISSING pkg-config package: $package" >&2
      missing=1
    elif [[ "$("$PKG_CONFIG" --variable=pcfiledir "$package")" != /opt/local/* ]]; then
      echo "INVALID pkg-config provider for $package (expected /opt/local)" >&2
      missing=1
    fi
  done
fi

if [[ "$missing" -ne 0 ]]; then
  echo "Bootstrap checks failed. No packages were installed automatically." >&2
  exit 1
fi

"$SCRIPT_DIR/generate-project.sh"
echo "Bootstrap checks passed."
