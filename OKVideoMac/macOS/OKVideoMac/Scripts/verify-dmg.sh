#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
  echo "Usage: $0 --mode local|distribution --source-index FILE --apk FILE [--require-gatekeeper] /path/to/OKVideoMac-VERSION.dmg" >&2
}

MODE=""
REQUIRE_GATEKEEPER=0
SOURCE_INDEX=""
APK=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --mode)
      MODE="${2:-}"
      shift 2
      ;;
    --require-gatekeeper)
      REQUIRE_GATEKEEPER=1
      shift
      ;;
    --source-index)
      SOURCE_INDEX="${2:-}"
      shift 2
      ;;
    --apk)
      APK="${2:-}"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      break
      ;;
  esac
done

if [[ "$MODE" != "local" && "$MODE" != "distribution" ]]; then
  usage
  exit 64
fi
if [[ "$#" -ne 1 ]]; then
  usage
  exit 64
fi
if [[ ! -f "$SOURCE_INDEX" || ! -f "$APK" ]]; then
  echo "--source-index and --apk must name existing files." >&2
  exit 64
fi
if [[ "$REQUIRE_GATEKEEPER" -eq 1 && "$MODE" != "distribution" ]]; then
  echo "--require-gatekeeper is only valid in distribution mode." >&2
  exit 64
fi

DMG="$1"
if [[ ! -f "$DMG" ]]; then
  echo "DMG does not exist: $DMG" >&2
  exit 1
fi

VERSION="$(
  awk '$1 == "MARKETING_VERSION:" { gsub(/["[:space:]]/, "", $2); print $2; exit }' \
    "$PROJECT_DIR/project.yml"
)"
BUILD="$(
  awk '$1 == "CURRENT_PROJECT_VERSION:" { gsub(/["[:space:]]/, "", $2); print $2; exit }' \
    "$PROJECT_DIR/project.yml"
)"
EXPECTED_NAME="OKVideoMac-${VERSION}.dmg"
if [[ "$(basename "$DMG")" != "$EXPECTED_NAME" ]]; then
  echo "Unexpected DMG filename: $(basename "$DMG") (expected $EXPECTED_NAME)" >&2
  exit 1
fi

if ! codesign --verify --strict --verbose=4 "$DMG"; then
  echo "DMG signature verification failed: $DMG" >&2
  exit 1
fi
DMG_INFO="$(codesign -d --verbose=4 "$DMG" 2>&1)"
if [[ "$MODE" == "distribution" ]]; then
  if ! grep -q '^Authority=Developer ID Application:' <<< "$DMG_INFO"; then
    echo "Distribution DMG is not signed by Developer ID Application." >&2
    exit 1
  fi
  if grep -q 'Signature=adhoc' <<< "$DMG_INFO"; then
    echo "Distribution DMG is ad-hoc signed." >&2
    exit 1
  fi
else
  if ! grep -q 'Signature=adhoc' <<< "$DMG_INFO"; then
    echo "Local DMG is expected to be ad-hoc signed." >&2
    exit 1
  fi
fi

MOUNT_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/okvideomac-dmg-verify.XXXXXX")"
MOUNT_POINT="$MOUNT_ROOT/mount"
mkdir -p "$MOUNT_POINT"
ATTACHED=0
cleanup() {
  if [[ "$ATTACHED" -eq 1 ]]; then
    hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 || true
  fi
  rm -rf "$MOUNT_ROOT"
}
trap cleanup EXIT

hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT_POINT" "$DMG" >/dev/null
ATTACHED=1

APP="$MOUNT_POINT/OKVideoMac.app"
APPLICATIONS_LINK="$MOUNT_POINT/Applications"
if [[ ! -d "$APP" ]]; then
  echo "DMG does not contain OKVideoMac.app." >&2
  exit 1
fi
if [[ ! -L "$APPLICATIONS_LINK" ]] || [[ "$(readlink "$APPLICATIONS_LINK")" != "/Applications" ]]; then
  echo "DMG does not contain Applications -> /Applications." >&2
  exit 1
fi

unexpected=()
while IFS= read -r entry; do
  case "$(basename "$entry")" in
    OKVideoMac.app|Applications) ;;
    *) unexpected+=("$(basename "$entry")") ;;
  esac
done < <(find "$MOUNT_POINT" -mindepth 1 -maxdepth 1 -print | sort)
if [[ "${#unexpected[@]}" -ne 0 ]]; then
  echo "DMG contains unexpected top-level entries: ${unexpected[*]}" >&2
  exit 1
fi

APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
APP_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
if [[ "$APP_VERSION" != "$VERSION" || "$APP_BUILD" != "$BUILD" ]]; then
  echo "DMG app metadata mismatch: ${APP_VERSION} (${APP_BUILD}), expected ${VERSION} (${BUILD})." >&2
  exit 1
fi
EMBEDDED_INDEX="$APP/Contents/Resources/Legal/Compliance/SOURCE_RELEASE_INDEX.json"
EMBEDDED_APK="$APP/Contents/Resources/AndroidDexBridge-release.apk"
if [[ ! -f "$EMBEDDED_INDEX" ]] || ! cmp -s "$SOURCE_INDEX" "$EMBEDDED_INDEX"; then
  echo "DMG app source release index does not match the expected index." >&2
  exit 1
fi
if [[ ! -f "$EMBEDDED_APK" ]] || \
   [[ "$(shasum -a 256 "$EMBEDDED_APK" | awk '{print $1}')" != \
      "$(shasum -a 256 "$APK" | awk '{print $1}')" ]]; then
  echo "DMG app Android Bridge APK does not match the release APK." >&2
  exit 1
fi

signing_arguments=(--mode "$MODE")
if [[ "$REQUIRE_GATEKEEPER" -eq 1 ]]; then
  signing_arguments+=(--require-gatekeeper)
fi
"$SCRIPT_DIR/verify-release-signing.sh" "${signing_arguments[@]}" "$APP"

if [[ "$REQUIRE_GATEKEEPER" -eq 1 ]]; then
  spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG"
  echo "PASS: DMG Gatekeeper assessment"
else
  echo "NOT TESTED: DMG Gatekeeper assessment requires an accepted notarization."
fi

echo "DMG verification passed: $EXPECTED_NAME, app ${VERSION} (${BUILD}), mode=$MODE."
