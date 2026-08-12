#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ "$#" -ne 4 ]]; then
  echo "Usage: $0 SOURCE.app BUNDLED_DYLIB_NAME REPLACEMENT_DYLIB DESTINATION.app" >&2
  exit 64
fi

SOURCE_APP="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
DYLIB_NAME="$2"
REPLACEMENT="$(cd "$(dirname "$3")" && pwd)/$(basename "$3")"
DESTINATION="$(cd "$(dirname "$4")" && pwd)/$(basename "$4")"

case "$DESTINATION" in
  /private/tmp/*.app|/tmp/*.app) ;;
  *)
    echo "The LGPL replacement test destination must be an explicit /private/tmp App." >&2
    exit 64
    ;;
esac
if [[ ! -d "$SOURCE_APP" || ! -f "$REPLACEMENT" ]]; then
  echo "Source App or replacement dylib does not exist." >&2
  exit 1
fi
if [[ -e "$DESTINATION" ]]; then
  echo "Refusing to overwrite an existing destination: $DESTINATION" >&2
  exit 1
fi
TARGET_DYLIB="$DESTINATION/Contents/Frameworks/$DYLIB_NAME"
MAIN_EXECUTABLE="$DESTINATION/Contents/MacOS/OKVideoMac"
if [[ ! -f "$SOURCE_APP/Contents/Frameworks/$DYLIB_NAME" ]]; then
  echo "The source App does not bundle $DYLIB_NAME." >&2
  exit 1
fi
if ! file "$REPLACEMENT" | grep -q 'Mach-O.*arm64'; then
  echo "Replacement is not an arm64 Mach-O dylib." >&2
  exit 1
fi

ditto "$SOURCE_APP" "$DESTINATION"
cp "$REPLACEMENT" "$TARGET_DYLIB"
if codesign --verify --deep --strict "$DESTINATION" >/dev/null 2>&1; then
  echo "Replacing $DYLIB_NAME did not invalidate the expected signature." >&2
  exit 1
fi
echo "Expected signature invalidation observed."

codesign --force --sign - --options runtime --timestamp=none "$TARGET_DYLIB"
codesign --force --sign - --options runtime --timestamp=none \
  --entitlements "$PROJECT_DIR/Supporting/OKVideoMac.dev.entitlements" \
  "$MAIN_EXECUTABLE"
codesign --force --sign - --options runtime --timestamp=none \
  --entitlements "$PROJECT_DIR/Supporting/OKVideoMac.dev.entitlements" \
  "$DESTINATION"
codesign --verify --deep --strict --verbose=2 "$DESTINATION"
if ! codesign -d --entitlements :- "$MAIN_EXECUTABLE" 2>&1 |
   grep -q 'com.apple.security.cs.disable-library-validation'; then
  echo "Ad-hoc main executable lacks the documented Library Validation entitlement." >&2
  exit 1
fi
echo "LGPL replacement and ad-hoc re-sign verification passed: $DESTINATION"
