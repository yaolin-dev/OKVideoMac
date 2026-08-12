#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_ROOT="$(cd "$PROJECT_DIR/../.." && pwd)"
REPOSITORY_ROOT="$(cd "$SOURCE_ROOT/.." && pwd)"
source "$SCRIPT_DIR/build-environment.sh"

usage() {
  cat <<'USAGE'
Usage: package-app.sh [--mode local|distribution] [--notarize]

Modes:
  local         Ad-hoc Hardened Runtime package for local testing (default).
  distribution  Developer ID Application package suitable for notarization.

Distribution environment:
  DEVELOPER_ID_APPLICATION   Certificate name or SHA-1 identity (required).
  OKVIDEOMAC_NOTARY_PROFILE  notarytool keychain profile (with --notarize).
USAGE
}

PACKAGE_MODE="${OKVIDEOMAC_PACKAGE_MODE:-local}"
NOTARIZE=0
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --mode)
      if [[ "$#" -lt 2 ]]; then
        echo "--mode requires local or distribution." >&2
        exit 64
      fi
      PACKAGE_MODE="$2"
      shift 2
      ;;
    --notarize)
      NOTARIZE=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
done

case "$PACKAGE_MODE" in
  local)
    SIGN_IDENTITY="-"
    APP_ENTITLEMENTS="$PROJECT_DIR/Supporting/OKVideoMac.dev.entitlements"
    TIMESTAMP_ARGUMENT="--timestamp=none"
    ;;
  distribution)
    SIGN_IDENTITY="${DEVELOPER_ID_APPLICATION:-}"
    APP_ENTITLEMENTS="$PROJECT_DIR/Supporting/OKVideoMac.release.entitlements"
    TIMESTAMP_ARGUMENT="--timestamp"
    if [[ -z "$SIGN_IDENTITY" || "$SIGN_IDENTITY" == "-" ]]; then
      echo "distribution mode requires DEVELOPER_ID_APPLICATION." >&2
      exit 2
    fi
    if ! security find-identity -v -p codesigning |
         grep -F -- "$SIGN_IDENTITY" >/dev/null; then
      echo "Developer ID signing identity is not available: $SIGN_IDENTITY" >&2
      exit 2
    fi
    ;;
  *)
    echo "Unsupported package mode: $PACKAGE_MODE" >&2
    exit 64
    ;;
esac

if [[ "$NOTARIZE" -eq 1 && "$PACKAGE_MODE" != "distribution" ]]; then
  echo "--notarize is only valid in distribution mode." >&2
  exit 64
fi
if [[ "$NOTARIZE" -eq 1 && -z "${OKVIDEOMAC_NOTARY_PROFILE:-}" ]]; then
  echo "--notarize requires OKVIDEOMAC_NOTARY_PROFILE." >&2
  exit 2
fi

"$SCRIPT_DIR/check-doc-status.sh"

NODE_ENTITLEMENTS="$PROJECT_DIR/Supporting/NodeHelper.entitlements"
DERIVED_DATA="${OKVIDEOMAC_DERIVED_DATA:-$OKVIDEOMAC_BUILD_ROOT/DerivedData}"
ARTIFACTS="${OKVIDEOMAC_ARTIFACTS:-$OKVIDEOMAC_BUILD_ROOT/Artifacts}"
SOURCE_RELEASE_DIR="${OKVIDEOMAC_SOURCE_RELEASE_DIR:-$ARTIFACTS/SourceRelease}"
SOURCE_RELEASE_CACHE="${OKVIDEOMAC_SOURCE_RELEASE_CACHE:-$OKVIDEOMAC_BUILD_ROOT/Downloads/SourceRelease}"
APP_SOURCE="$DERIVED_DATA/Build/Products/Release/OKVideoMac.app"
APP_DESTINATION="$ARTIFACTS/OKVideoMac.app"
LIBMPV_ROOT="$OKVIDEOMAC_BUILD_ROOT/libmpv"
QUICKJS_ROOT="$OKVIDEOMAC_BUILD_ROOT/QuickJS"
NODE_RUNTIME="$APP_DESTINATION/Contents/Resources/NodeRuntime/node"
EXECUTABLE="$APP_DESTINATION/Contents/MacOS/OKVideoMac"
MPV_BRIDGE="$LIBMPV_ROOT/lib/libOKMPVBridge.dylib"
LEGAL_SOURCE_DIR="$SOURCE_ROOT/THIRD_PARTY_LICENSES"
LEGAL_ROOT="$APP_DESTINATION/Contents/Resources/Legal"
SBOM_DIR="$LEGAL_ROOT/Compliance/SBOM"
GRADLE_LOCK="$SOURCE_ROOT/Helpers/AndroidDexBridge/app/gradle.lockfile"

legal_source_files=(
  "$SOURCE_ROOT/LICENSE"
  "$SOURCE_ROOT/NOTICE.md"
  "$SOURCE_ROOT/THIRD_PARTY_NOTICES.md"
  "$SOURCE_ROOT/Helpers/AndroidDexBridge/THIRD_PARTY_NOTICES.md"
  "$SOURCE_ROOT/Helpers/AndroidDexBridge/FONGMI_CATVOD_CHANGES.md"
  "$PROJECT_DIR/Patches/mpv-0.41.0-coreaudio-without-cocoa.patch"
  "$PROJECT_DIR/Patches/mpv-0.41.0-coreaudio-without-cocoa.NOTICE.md"
  "$REPOSITORY_ROOT/Docs/THIRD_PARTY_LICENSE_AUDIT.md"
  "$REPOSITORY_ROOT/Docs/SOURCE_PROVENANCE_MANIFEST.md"
  "$REPOSITORY_ROOT/Docs/BINARY_SOURCE_MAPPING.md"
  "$REPOSITORY_ROOT/Docs/OPEN_SOURCE_COMPLIANCE.md"
  "$REPOSITORY_ROOT/Docs/OPEN_SOURCE_P0_STATUS.md"
  "$REPOSITORY_ROOT/Docs/APP_ICON_PROVENANCE.md"
  "$REPOSITORY_ROOT/Docs/MPL_GPL_COMBINATION_REVIEW.md"
  "$REPOSITORY_ROOT/Docs/NATIVE_REPRODUCIBLE_PROVENANCE.md"
  "$REPOSITORY_ROOT/Docs/LGPL_LIBRARY_REPLACEMENT.md"
  "$REPOSITORY_ROOT/Docs/SBOM_RELEASE_PROCESS.md"
  "$REPOSITORY_ROOT/Docs/THIRD_PARTY_LICENSE_REAUDIT_PHASE2.md"
  "$REPOSITORY_ROOT/Docs/SOURCE_RELEASE_PROCESS.md"
  "$REPOSITORY_ROOT/Docs/XPP3_1_1_3_3_REMEDIATION.md"
  "$REPOSITORY_ROOT/ThirdParty/native-lock.json"
)
for legal_source_file in "${legal_source_files[@]}"; do
  if [[ ! -f "$legal_source_file" ]]; then
    echo "Legal source file is missing: $legal_source_file" >&2
    exit 1
  fi
done
if [[ ! -d "$LEGAL_SOURCE_DIR" ]] ||
   [[ -z "$(find "$LEGAL_SOURCE_DIR" -maxdepth 1 -type f -print -quit)" ]]; then
  echo "Third-party license directory is missing or empty: $LEGAL_SOURCE_DIR" >&2
  exit 1
fi

for entitlement_file in "$APP_ENTITLEMENTS" "$NODE_ENTITLEMENTS"; do
  if [[ ! -f "$entitlement_file" ]]; then
    echo "Entitlements file is missing: $entitlement_file" >&2
    exit 1
  fi
done
if ! xcodebuild -version >/dev/null 2>&1; then
  echo "Full Xcode is required for packaging." >&2
  exit 1
fi
if [[ ! -d "$PROJECT_DIR/OKVideoMac.xcodeproj" ]]; then
  echo "Generate OKVideoMac.xcodeproj first." >&2
  exit 1
fi

echo "Packaging mode: $PACKAGE_MODE"
if [[ "${OKVIDEOMAC_SKIP_ANDROID_BRIDGE_BUILD:-0}" != "1" ]]; then
  "$SCRIPT_DIR/build-android-dex-bridge.sh"
fi

ANDROID_BRIDGE_APK="$PROJECT_DIR/../../Helpers/AndroidDexBridge/app/build/outputs/apk/release/app-release.apk"
if [[ ! -f "$ANDROID_BRIDGE_APK" ]]; then
  echo "Android bridge APK is missing; build it before packaging." >&2
  exit 1
fi

# Native dependencies are normalized after Xcode has built the app. Signing is
# therefore deliberately deferred until the complete nested-code inventory is
# final; Xcode must not create a signature that install_name_tool later breaks.
xcodebuild \
  -project "$PROJECT_DIR/OKVideoMac.xcodeproj" \
  -scheme OKVideoMac \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  clean build

if [[ ! -d "$APP_SOURCE" ]]; then
  echo "Release app not found at $APP_SOURCE" >&2
  exit 1
fi

rm -rf "$APP_DESTINATION"
mkdir -p "$ARTIFACTS"
cp -R "$APP_SOURCE" "$APP_DESTINATION"
APP_VERSION="$(
  /usr/libexec/PlistBuddy \
    -c 'Print :CFBundleShortVersionString' \
    "$APP_DESTINATION/Contents/Info.plist"
)"
APP_BUILD="$(
  /usr/libexec/PlistBuddy \
    -c 'Print :CFBundleVersion' \
    "$APP_DESTINATION/Contents/Info.plist"
)"
if [[ -z "$APP_VERSION" || -z "$APP_BUILD" ]]; then
  echo "Packaged app version or build is missing." >&2
  exit 1
fi
ARCHIVE="$ARTIFACTS/OKVideoMac-${APP_VERSION}-macOS-arm64.zip"
SOURCE_RELEASE_BASE="OKVideoMac-${APP_VERSION}-build${APP_BUILD}"
SOURCE_RELEASE_INDEX="$SOURCE_RELEASE_DIR/${SOURCE_RELEASE_BASE}-SOURCE_RELEASE_INDEX.json"
source_release_arguments=(
  --output-dir "$SOURCE_RELEASE_DIR"
  --cache-dir "$SOURCE_RELEASE_CACHE"
  --commit HEAD
  --apk "$ANDROID_BRIDGE_APK"
)
if [[ "${OKVIDEOMAC_SOURCE_RELEASE_OFFLINE:-0}" == "1" ]]; then
  source_release_arguments+=(--offline)
fi
"$SCRIPT_DIR/create-source-release.sh" "${source_release_arguments[@]}"
if [[ ! -f "$SOURCE_RELEASE_INDEX" ]]; then
  echo "Source release index is missing: $SOURCE_RELEASE_INDEX" >&2
  exit 1
fi
FRAMEWORKS="$APP_DESTINATION/Contents/Frameworks"
mkdir -p "$FRAMEWORKS"

# Install the complete, repository-maintained legal payload before signing.
# This changes resources only; executable dependencies, linkage, entitlements,
# and the inside-out signing order below remain unchanged.
rm -rf "$LEGAL_ROOT"
mkdir -p \
  "$LEGAL_ROOT/AndroidDexBridge" \
  "$LEGAL_ROOT/Compliance" \
  "$LEGAL_ROOT/ModifiedSources"
cp "$SOURCE_ROOT/LICENSE" "$LEGAL_ROOT/LICENSE"
cp "$SOURCE_ROOT/NOTICE.md" "$LEGAL_ROOT/NOTICE.md"
cp "$SOURCE_ROOT/THIRD_PARTY_NOTICES.md" \
  "$LEGAL_ROOT/THIRD_PARTY_NOTICES.md"
cp -R "$LEGAL_SOURCE_DIR" "$LEGAL_ROOT/THIRD_PARTY_LICENSES"
cp "$SOURCE_ROOT/Helpers/AndroidDexBridge/THIRD_PARTY_NOTICES.md" \
  "$LEGAL_ROOT/AndroidDexBridge/THIRD_PARTY_NOTICES.md"
cp "$SOURCE_ROOT/Helpers/AndroidDexBridge/FONGMI_CATVOD_CHANGES.md" \
  "$LEGAL_ROOT/AndroidDexBridge/FONGMI_CATVOD_CHANGES.md"
cp "$PROJECT_DIR/Patches/mpv-0.41.0-coreaudio-without-cocoa.patch" \
  "$LEGAL_ROOT/ModifiedSources/"
cp "$PROJECT_DIR/Patches/mpv-0.41.0-coreaudio-without-cocoa.NOTICE.md" \
  "$LEGAL_ROOT/ModifiedSources/"
cp "$REPOSITORY_ROOT/Docs/THIRD_PARTY_LICENSE_AUDIT.md" \
  "$LEGAL_ROOT/Compliance/"
cp "$REPOSITORY_ROOT/Docs/SOURCE_PROVENANCE_MANIFEST.md" \
  "$LEGAL_ROOT/Compliance/"
cp "$REPOSITORY_ROOT/Docs/BINARY_SOURCE_MAPPING.md" \
  "$LEGAL_ROOT/Compliance/"
cp "$REPOSITORY_ROOT/Docs/OPEN_SOURCE_COMPLIANCE.md" \
  "$LEGAL_ROOT/Compliance/"
cp "$REPOSITORY_ROOT/Docs/OPEN_SOURCE_P0_STATUS.md" \
  "$LEGAL_ROOT/Compliance/"
cp "$REPOSITORY_ROOT/Docs/APP_ICON_PROVENANCE.md" \
  "$LEGAL_ROOT/Compliance/"
cp "$REPOSITORY_ROOT/Docs/MPL_GPL_COMBINATION_REVIEW.md" \
  "$LEGAL_ROOT/Compliance/"
cp "$REPOSITORY_ROOT/Docs/NATIVE_REPRODUCIBLE_PROVENANCE.md" \
  "$LEGAL_ROOT/Compliance/"
cp "$REPOSITORY_ROOT/Docs/LGPL_LIBRARY_REPLACEMENT.md" \
  "$LEGAL_ROOT/Compliance/"
cp "$REPOSITORY_ROOT/Docs/SBOM_RELEASE_PROCESS.md" \
  "$LEGAL_ROOT/Compliance/"
cp "$REPOSITORY_ROOT/Docs/THIRD_PARTY_LICENSE_REAUDIT_PHASE2.md" \
  "$LEGAL_ROOT/Compliance/"
cp "$REPOSITORY_ROOT/Docs/SOURCE_RELEASE_PROCESS.md" \
  "$LEGAL_ROOT/Compliance/"
cp "$REPOSITORY_ROOT/ThirdParty/native-lock.json" \
  "$LEGAL_ROOT/Compliance/NATIVE_DEPENDENCY_LOCK.json"
cp "$REPOSITORY_ROOT/Docs/XPP3_1_1_3_3_REMEDIATION.md" \
  "$LEGAL_ROOT/Compliance/"
cp "$SOURCE_RELEASE_INDEX" "$LEGAL_ROOT/Compliance/SOURCE_RELEASE_INDEX.json"

if [[ ! -f "$APP_DESTINATION/Contents/Resources/LICENSE" ]] ||
   [[ ! -f "$APP_DESTINATION/Contents/Resources/NOTICE.md" ]]; then
  echo "License resources are missing from the built app." >&2
  exit 1
fi

LIBMPV_PATH="$(find "$LIBMPV_ROOT" -name 'libmpv*.dylib' -type f | head -n 1)"
if [[ -z "$LIBMPV_PATH" ]]; then
  echo "Run build-libmpv.sh before packaging." >&2
  exit 1
fi
if [[ ! -f "$MPV_BRIDGE" ]]; then
  echo "libOKMPVBridge is missing; rerun build-libmpv.sh." >&2
  exit 1
fi
cp "$LIBMPV_PATH" "$FRAMEWORKS/libmpv.dylib"
install_name_tool -id '@rpath/libmpv.dylib' "$FRAMEWORKS/libmpv.dylib"
cp "$MPV_BRIDGE" "$FRAMEWORKS/libOKMPVBridge.dylib"
install_name_tool -id '@rpath/libOKMPVBridge.dylib' \
  "$FRAMEWORKS/libOKMPVBridge.dylib"

QUICKJS_PATH="$QUICKJS_ROOT/lib/libOKQuickJS.dylib"
if [[ ! -f "$QUICKJS_PATH" ]]; then
  echo "Run build-quickjs.sh before packaging." >&2
  exit 1
fi
cp "$QUICKJS_PATH" "$FRAMEWORKS/libOKQuickJS.dylib"
install_name_tool -id '@rpath/libOKQuickJS.dylib' "$FRAMEWORKS/libOKQuickJS.dylib"
mkdir -p "$APP_DESTINATION/Contents/Resources/Licenses"
cp "$QUICKJS_ROOT/LICENSE" \
  "$APP_DESTINATION/Contents/Resources/Licenses/QuickJS-MIT.txt"
cp "$LIBMPV_ROOT/licenses/"* \
  "$APP_DESTINATION/Contents/Resources/Licenses/"

if [[ ! -x "$NODE_RUNTIME" ]]; then
  echo "Bundled Node runtime is missing; set OKVIDEOMAC_NODE_RUNTIME." >&2
  exit 1
fi
if [[ ! -f "$APP_DESTINATION/Contents/Resources/Licenses/Node.js-LICENSE.txt" ]]; then
  echo "Bundled Node.js license is missing." >&2
  exit 1
fi

pending=(
  "$EXECUTABLE"
  "$NODE_RUNTIME"
  "$FRAMEWORKS/libmpv.dylib"
  "$FRAMEWORKS/libOKMPVBridge.dylib"
  "$FRAMEWORKS/libOKQuickJS.dylib"
)
processed=()
while [[ "${#pending[@]}" -gt 0 ]]; do
  binary="${pending[0]}"
  pending=("${pending[@]:1}")
  already_processed=0
  if [[ "${#processed[@]}" -gt 0 ]]; then
    for existing_binary in "${processed[@]}"; do
      if [[ "$existing_binary" == "$binary" ]]; then
        already_processed=1
        break
      fi
    done
  fi
  if [[ "$already_processed" -eq 1 ]]; then
    continue
  fi
  processed+=("$binary")

  while IFS= read -r dependency; do
    case "$dependency" in
      /opt/homebrew/*|/opt/local/*|/usr/local/*)
        base="$(basename "$dependency")"
        destination="$FRAMEWORKS/$base"
        if [[ ! -f "$destination" ]]; then
          cp "$dependency" "$destination"
          chmod u+w "$destination"
          install_name_tool -id "@rpath/$base" "$destination"
        fi
        pending+=("$destination")
        install_name_tool -change "$dependency" "@rpath/$base" "$binary"
        ;;
    esac
  done < <(otool -L "$binary" | tail -n +2 | awk '{print $1}')
  while IFS= read -r search_path; do
    case "$search_path" in
      /opt/homebrew/*|/opt/local/*|/usr/local/*|/Users/*)
        install_name_tool -delete_rpath "$search_path" "$binary"
        ;;
    esac
  done < <(
    otool -l "$binary" |
      awk '$1 == "cmd" && $2 == "LC_RPATH" {
        getline
        getline
        print $2
      }'
  )
done

sign_code() {
  target="$1"
  entitlement_file="${2:-}"
  arguments=(
    --force
    --sign "$SIGN_IDENTITY"
    --options runtime
    "$TIMESTAMP_ARGUMENT"
  )
  if [[ -n "$entitlement_file" ]]; then
    arguments+=(--entitlements "$entitlement_file")
  fi
  codesign "${arguments[@]}" "$target"
}

# Explicit inside-out signing. --deep is verification-only and is never used
# to create or repair signatures.
for ((index=${#processed[@]} - 1; index >= 0; index--)); do
  binary="${processed[$index]}"
  if [[ "$binary" == "$EXECUTABLE" || "$binary" == "$NODE_RUNTIME" ]]; then
    continue
  fi
  sign_code "$binary"
done
sign_code "$NODE_RUNTIME" "$NODE_ENTITLEMENTS"
sign_code "$EXECUTABLE" "$APP_ENTITLEMENTS"

# Generate the release SBOMs after nested-code signatures are final. The main
# executable intentionally has no SBOM hash because signing the outer bundle
# rewrites its embedded signature; all other Mach-O and APK artifacts are
# hash-bound. verify_sbom.py enforces exact inventory equality.
mkdir -p "$SBOM_DIR"
PYTHONDONTWRITEBYTECODE=1 python3 \
  "$REPOSITORY_ROOT/Tools/SourceAudit/generate_sbom.py" \
  --app "$APP_DESTINATION" \
  --gradle-lock "$GRADLE_LOCK" \
  --output-dir "$SBOM_DIR"
PYTHONDONTWRITEBYTECODE=1 python3 \
  "$REPOSITORY_ROOT/Tools/SourceAudit/verify_sbom.py" \
  --app "$APP_DESTINATION" \
  --gradle-lock "$GRADLE_LOCK" \
  --sbom-dir "$SBOM_DIR"

# Record hashes only after every nested Mach-O has its final signature. The
# main executable is deliberately excluded: signing the outer App rewrites its
# embedded signature, while the manifest itself must already be sealed as an
# App resource. The final main executable is instead verified by codesign.
OUTPUT_HASH_MANIFEST="$LEGAL_ROOT/Compliance/BUILD_OUTPUT_SHA256.txt"
(
  cd "$APP_DESTINATION"
  echo "# OKVideoMac $APP_VERSION ($APP_BUILD) stable packaged binary hashes"
  echo "# Generated after nested signing; paths are App-relative."
  echo "# Contents/MacOS/OKVideoMac is excluded because outer App signing rewrites it."
  while IFS= read -r -d '' artifact_file; do
    if [[ "$artifact_file" != "Contents/MacOS/OKVideoMac" ]] &&
       file "$artifact_file" | grep -q 'Mach-O'; then
      shasum -a 256 "$artifact_file"
    fi
  done < <(find Contents -type f -print0 | sort -z)
  shasum -a 256 Contents/Resources/AndroidDexBridge-release.apk
) > "$OUTPUT_HASH_MANIFEST"
sign_code "$APP_DESTINATION" "$APP_ENTITLEMENTS"

"$SCRIPT_DIR/verify-bundle.sh" "$APP_DESTINATION"
"$SCRIPT_DIR/verify-release-signing.sh" --mode "$PACKAGE_MODE" "$APP_DESTINATION"

create_archive() {
  rm -f "$ARCHIVE" "$ARCHIVE.sha256"
  ditto -c -k --sequesterRsrc --keepParent "$APP_DESTINATION" "$ARCHIVE"
  (
    cd "$ARTIFACTS"
    shasum -a 256 "$(basename "$ARCHIVE")" > "$(basename "$ARCHIVE").sha256"
  )
}

create_archive
if [[ "$NOTARIZE" -eq 1 ]]; then
  xcrun notarytool submit "$ARCHIVE" \
    --keychain-profile "$OKVIDEOMAC_NOTARY_PROFILE" \
    --wait
  xcrun stapler staple "$APP_DESTINATION"
  xcrun stapler validate "$APP_DESTINATION"
  "$SCRIPT_DIR/verify-release-signing.sh" \
    --mode distribution \
    --require-gatekeeper \
    "$APP_DESTINATION"
  create_archive
elif [[ "$PACKAGE_MODE" == "distribution" ]]; then
  echo "Notarization step not executed because credentials were not requested."
fi

# Bind the final (possibly notarized) binary ZIP to the already embedded
# source-side index. This outer manifest cannot be embedded in the App without
# creating a circular ZIP/signature hash.
"$SCRIPT_DIR/create-source-release.sh" \
  --output-dir "$SOURCE_RELEASE_DIR" \
  --cache-dir "$SOURCE_RELEASE_CACHE" \
  --commit HEAD \
  --apk "$ANDROID_BRIDGE_APK" \
  --binary "$ARCHIVE" \
  --sbom "$SBOM_DIR/OKVideoMac-macOS.spdx.json" \
  --sbom "$SBOM_DIR/OKVideoMac-macOS.cdx.json" \
  --sbom "$SBOM_DIR/OKVideoMac-Android.spdx.json" \
  --sbom "$SBOM_DIR/OKVideoMac-Android.cdx.json" \
  --offline

echo "Packaged app: $APP_DESTINATION"
echo "Archive: $ARCHIVE"
echo "Source release: $SOURCE_RELEASE_DIR"
