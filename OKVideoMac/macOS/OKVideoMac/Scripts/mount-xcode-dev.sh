#!/usr/bin/env bash
set -euo pipefail

XCODE_BUNDLE="${OKVIDEOMAC_XCODE_BUNDLE:-}"
XCODE_VOLUME="${OKVIDEOMAC_XCODE_VOLUME:-}"

if [[ -z "$XCODE_BUNDLE" || -z "$XCODE_VOLUME" ]]; then
  echo "Set OKVIDEOMAC_XCODE_BUNDLE and OKVIDEOMAC_XCODE_VOLUME first." >&2
  exit 64
fi

if [[ -d "$XCODE_VOLUME" ]]; then
  echo "Xcode development volume is already mounted: $XCODE_VOLUME"
elif [[ -d "$XCODE_BUNDLE" ]]; then
  hdiutil attach -nobrowse "$XCODE_BUNDLE"
else
  echo "Xcode sparse bundle is unavailable: $XCODE_BUNDLE" >&2
  echo "Connect the configured external development volume and try again." >&2
  exit 1
fi

XCODE_DEVELOPER_DIR="$XCODE_VOLUME/Xcode.app/Contents/Developer"
if [[ -d "$XCODE_DEVELOPER_DIR" ]]; then
  echo "Xcode developer directory: $XCODE_DEVELOPER_DIR"
  echo "For this shell, run:"
  printf "export DEVELOPER_DIR=%q\n" "$XCODE_DEVELOPER_DIR"
else
  echo "The volume is mounted, but Xcode.app is not installed yet." >&2
fi
