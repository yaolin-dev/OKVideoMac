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
if [[ "$NOTARIZE" -eq 1 ]] &&
   ! xcrun notarytool history \
     --keychain-profile "$OKVIDEOMAC_NOTARY_PROFILE" \
     --output-format json >/dev/null 2>&1; then
  echo "notary profile unavailable: $OKVIDEOMAC_NOTARY_PROFILE" >&2
  exit 2
fi

"$SCRIPT_DIR/check-doc-status.sh"

NODE_ENTITLEMENTS="$PROJECT_DIR/Supporting/NodeHelper.entitlements"
DERIVED_DATA="${OKVIDEOMAC_DERIVED_DATA:-$OKVIDEOMAC_BUILD_ROOT/DerivedData}"
ARTIFACTS="${OKVIDEOMAC_ARTIFACTS:-$OKVIDEOMAC_BUILD_ROOT/Artifacts}"
SOURCE_RELEASE_DIR="${OKVIDEOMAC_SOURCE_RELEASE_DIR:-$ARTIFACTS/SourceRelease}"
SOURCE_RELEASE_CACHE="${OKVIDEOMAC_SOURCE_RELEASE_CACHE:-$OKVIDEOMAC_BUILD_ROOT/Downloads/SourceRelease}"
APP_SOURCE="$DERIVED_DATA/Build/Products/Release/OKVideoMac.app"
FINAL_APP_DESTINATION="$ARTIFACTS/OKVideoMac.app"
# Documents/Desktop can be backed by File Provider, which may immediately
# reattach FinderInfo after xattr removes it. Assemble and sign on the local
# temporary filesystem so the "sanitize + codesign" boundary is deterministic.
PACKAGE_STAGING="$(mktemp -d "${TMPDIR:-/tmp}/OKVideoMac-Package-Staging.XXXXXX")"
APP_DESTINATION="$PACKAGE_STAGING/OKVideoMac.app"
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
  "$REPOSITORY_ROOT/Docs/MPL_GPL_COMBINATION_AUDIT.md"
  "$REPOSITORY_ROOT/Docs/compliance/juniversalchardet-1.0.3-file-license-audit.json"
  "$REPOSITORY_ROOT/Docs/compliance/juniversalchardet-1.0.3-file-license-audit.md"
  "$REPOSITORY_ROOT/Docs/compliance/juniversalchardet-1.0.3-release-dex-audit.md"
  "$REPOSITORY_ROOT/Docs/compliance/juniversalchardet-1.0.3-release-dex-classes.txt"
  "$REPOSITORY_ROOT/Docs/legal/MPL_GPL_COUNSEL_PACKAGE/README.md"
  "$REPOSITORY_ROOT/Docs/legal/MPL_GPL_COUNSEL_PACKAGE/01_COMPONENTS.md"
  "$REPOSITORY_ROOT/Docs/legal/MPL_GPL_COUNSEL_PACKAGE/02_LICENSE_HEADERS.md"
  "$REPOSITORY_ROOT/Docs/legal/MPL_GPL_COUNSEL_PACKAGE/03_BUILD_AND_DEX_RELATIONSHIP.md"
  "$REPOSITORY_ROOT/Docs/legal/MPL_GPL_COUNSEL_PACKAGE/04_MODIFICATIONS.md"
  "$REPOSITORY_ROOT/Docs/legal/MPL_GPL_COUNSEL_PACKAGE/05_DISTRIBUTION_MODEL.md"
  "$REPOSITORY_ROOT/Docs/legal/MPL_GPL_COUNSEL_PACKAGE/06_EXACT_HASHES.md"
  "$REPOSITORY_ROOT/Docs/legal/MPL_GPL_COUNSEL_PACKAGE/07_QUESTIONS_FOR_COUNSEL.md"
  "$REPOSITORY_ROOT/Docs/NATIVE_REPRODUCIBLE_PROVENANCE.md"
  "$REPOSITORY_ROOT/Docs/LGPL_LIBRARY_REPLACEMENT.md"
  "$REPOSITORY_ROOT/Docs/SBOM_RELEASE_PROCESS.md"
  "$REPOSITORY_ROOT/Docs/THIRD_PARTY_LICENSE_REAUDIT_PHASE2.md"
  "$REPOSITORY_ROOT/Docs/SOURCE_RELEASE_PROCESS.md"
  "$REPOSITORY_ROOT/Docs/XPP3_1_1_3_3_REMEDIATION.md"
  "$REPOSITORY_ROOT/Docs/ENGINEERING_OPEN_SOURCE_READINESS_PHASE4.md"
  "$REPOSITORY_ROOT/Docs/APPLE_RELEASE_GATES_PHASE4.md"
  "$REPOSITORY_ROOT/Docs/IMMUTABLE_RELEASE_READINESS.md"
  "$REPOSITORY_ROOT/Docs/native/PHASE4_NATIVE_INVENTORY.json"
  "$REPOSITORY_ROOT/Docs/native/PHASE4_NATIVE_PROVENANCE.md"
  "$REPOSITORY_ROOT/Docs/native/PHASE4_BASELINE_MACHO_SHA256.txt"
  "$REPOSITORY_ROOT/Docs/native/PROVENANCE_CLEAN_NATIVE_BUILD.md"
  "$REPOSITORY_ROOT/Docs/native/PHASE4_CANDIDATE_ABI_CAPABILITY.md"
  "$REPOSITORY_ROOT/Docs/native/PHASE4_PLAYBACK_REGRESSION.md"
  "$REPOSITORY_ROOT/Docs/native/MANUAL_PLAYBACK_REGRESSION.md"
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
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  EXCLUDED_ARCHS=x86_64 \
  CODE_SIGNING_ALLOWED=NO \
  ENABLE_CODE_COVERAGE=NO \
  clean build

if [[ ! -d "$APP_SOURCE" ]]; then
  echo "Release app not found at $APP_SOURCE" >&2
  exit 1
fi

mkdir -p "$ARTIFACTS"
cp -R "$APP_SOURCE" "$APP_DESTINATION"
# Xcode keeps DWARF sections in the unsigned Release executable even when it
# also emits an external dSYM. Strip those sections before signing so absolute
# build paths cannot leak into the distributable App; runtime symbols remain.
/usr/bin/strip -S "$EXECUTABLE"
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
DMG="$ARTIFACTS/OKVideoMac-${APP_VERSION}.dmg"
DMG_STAGING=""
cleanup_package_staging() {
  if [[ -n "$DMG_STAGING" && -d "$DMG_STAGING" ]]; then
    rm -rf "$DMG_STAGING"
  fi
  if [[ -n "$PACKAGE_STAGING" && -d "$PACKAGE_STAGING" ]]; then
    rm -rf "$PACKAGE_STAGING"
  fi
}
trap cleanup_package_staging EXIT
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
  "$LEGAL_ROOT/Compliance/Phase4/Native" \
  "$LEGAL_ROOT/Compliance/MPL_GPL_COUNSEL_PACKAGE" \
  "$LEGAL_ROOT/Compliance/MPL_GPL_EVIDENCE" \
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
cp "$REPOSITORY_ROOT/Docs/MPL_GPL_COMBINATION_AUDIT.md" \
  "$LEGAL_ROOT/Compliance/"
cp "$REPOSITORY_ROOT/Docs/compliance/juniversalchardet-1.0.3-file-license-audit.json" \
  "$LEGAL_ROOT/Compliance/MPL_GPL_EVIDENCE/"
cp "$REPOSITORY_ROOT/Docs/compliance/juniversalchardet-1.0.3-file-license-audit.md" \
  "$LEGAL_ROOT/Compliance/MPL_GPL_EVIDENCE/"
cp "$REPOSITORY_ROOT/Docs/compliance/juniversalchardet-1.0.3-release-dex-audit.md" \
  "$LEGAL_ROOT/Compliance/MPL_GPL_EVIDENCE/"
cp "$REPOSITORY_ROOT/Docs/compliance/juniversalchardet-1.0.3-release-dex-classes.txt" \
  "$LEGAL_ROOT/Compliance/MPL_GPL_EVIDENCE/"
cp -R "$REPOSITORY_ROOT/Docs/legal/MPL_GPL_COUNSEL_PACKAGE/." \
  "$LEGAL_ROOT/Compliance/MPL_GPL_COUNSEL_PACKAGE/"
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
cp "$REPOSITORY_ROOT/Docs/ENGINEERING_OPEN_SOURCE_READINESS_PHASE4.md" \
  "$LEGAL_ROOT/Compliance/"
cp "$REPOSITORY_ROOT/Docs/APPLE_RELEASE_GATES_PHASE4.md" \
  "$LEGAL_ROOT/Compliance/"
cp "$REPOSITORY_ROOT/Docs/IMMUTABLE_RELEASE_READINESS.md" \
  "$LEGAL_ROOT/Compliance/"
cp "$REPOSITORY_ROOT/Docs/native/PHASE4_NATIVE_INVENTORY.json" \
  "$LEGAL_ROOT/Compliance/Phase4/Native/"
cp "$REPOSITORY_ROOT/Docs/native/PHASE4_NATIVE_PROVENANCE.md" \
  "$LEGAL_ROOT/Compliance/Phase4/Native/"
cp "$REPOSITORY_ROOT/Docs/native/PHASE4_BASELINE_MACHO_SHA256.txt" \
  "$LEGAL_ROOT/Compliance/Phase4/Native/"
cp "$REPOSITORY_ROOT/Docs/native/PROVENANCE_CLEAN_NATIVE_BUILD.md" \
  "$LEGAL_ROOT/Compliance/Phase4/Native/"
cp "$REPOSITORY_ROOT/Docs/native/PHASE4_CANDIDATE_ABI_CAPABILITY.md" \
  "$LEGAL_ROOT/Compliance/Phase4/Native/"
cp "$REPOSITORY_ROOT/Docs/native/PHASE4_PLAYBACK_REGRESSION.md" \
  "$LEGAL_ROOT/Compliance/Phase4/Native/"
cp "$REPOSITORY_ROOT/Docs/native/MANUAL_PLAYBACK_REGRESSION.md" \
  "$LEGAL_ROOT/Compliance/Phase4/Native/"
cp "$SOURCE_RELEASE_INDEX" "$LEGAL_ROOT/Compliance/SOURCE_RELEASE_INDEX.json"

if [[ ! -f "$APP_DESTINATION/Contents/Resources/LICENSE" ]] ||
   [[ ! -f "$APP_DESTINATION/Contents/Resources/NOTICE.md" ]]; then
  echo "License resources are missing from the built app." >&2
  exit 1
fi

# The Swift player and C bridge evolve together. Rebuild the lightweight
# bridge on every package so a stale native artifact can never satisfy a mere
# file-exists check while missing symbols required by the current executable.
"$SCRIPT_DIR/build-mpv-bridge.sh"

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
  # File Provider can reattach FinderInfo while earlier nested binaries are
  # being signed. Clear this exact target at the last possible moment so there
  # is no multi-second gap between sanitization and codesign.
  /usr/bin/xattr -cr "$target"
  codesign "${arguments[@]}" "$target"
}

# Xcode/File Provider can attach Finder metadata while the unsigned bundle is
# assembled. codesign rejects resource forks and FinderInfo anywhere in the
# bundle, so remove all host-local extended attributes only after the final
# file writes and immediately before applying signatures.
/usr/bin/xattr -cr "$APP_DESTINATION"

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

# Scan the complete pre-sign App and exact source-release artifacts for common
# credentials and accidental host-local paths. The JSON attestation is sealed
# into the outer App signature immediately afterward.
sensitive_scan_arguments=(
  "$APP_DESTINATION"
  "$SOURCE_RELEASE_DIR/${SOURCE_RELEASE_BASE}-source.tar.gz"
  "$SOURCE_RELEASE_DIR/${SOURCE_RELEASE_BASE}-third-party-source.tar.gz"
  "$SOURCE_RELEASE_DIR/${SOURCE_RELEASE_BASE}-licenses.tar.gz"
  "$SOURCE_RELEASE_INDEX"
  --forbidden-literal "/Users/$(id -un)/"
  --forbidden-literal "$REPOSITORY_ROOT/"
)
if [[ -n "${TMPDIR:-}" ]]; then
  sensitive_scan_arguments+=(--forbidden-literal "${TMPDIR%/}/")
fi
PYTHONDONTWRITEBYTECODE=1 python3 \
  "$REPOSITORY_ROOT/Tools/SourceAudit/scan_release_artifacts.py" \
  "${sensitive_scan_arguments[@]}" \
  --json-output "$LEGAL_ROOT/Compliance/SENSITIVE_INFORMATION_SCAN.json"
# The SBOM, hash manifest, and scan attestation above are final resource writes.
# File Provider may attach Finder metadata again while they are generated, so
# sanitize once more at the outer-signing boundary.
/usr/bin/xattr -cr "$APP_DESTINATION"
sign_code "$APP_DESTINATION" "$APP_ENTITLEMENTS"

"$SCRIPT_DIR/verify-bundle.sh" "$APP_DESTINATION"
"$SCRIPT_DIR/verify-release-signing.sh" --mode "$PACKAGE_MODE" "$APP_DESTINATION"

create_archive() {
  rm -f "$ARCHIVE" "$ARCHIVE.sha256"
  # Extended attributes here describe the build host, not the product. In
  # particular, preserving FinderInfo would make an otherwise valid bundle
  # fail strict verification after extraction.
  ditto -c -k --norsrc --noextattr --keepParent "$APP_DESTINATION" "$ARCHIVE"
  (
    cd "$ARTIFACTS"
    shasum -a 256 "$(basename "$ARCHIVE")" > "$(basename "$ARCHIVE").sha256"
  )
}

create_dmg() {
  # Keep DMG staging outside the repository/File Provider tree. FinderInfo can
  # be reattached there after the signed App has already passed verification,
  # which makes the otherwise-valid bundle fail when verified from the DMG.
  DMG_STAGING="$(mktemp -d "${TMPDIR:-/tmp}/OKVideoMac-DMG-Staging.XXXXXX")"
  cp -R "$APP_DESTINATION" "$DMG_STAGING/OKVideoMac.app"
  /usr/bin/xattr -cr "$DMG_STAGING/OKVideoMac.app"
  ln -s /Applications "$DMG_STAGING/Applications"
  rm -f "$DMG" "$DMG.sha256"
  hdiutil create \
    -volname "OKVideoMac ${APP_VERSION}" \
    -srcfolder "$DMG_STAGING" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    "$DMG"
  rm -rf "$DMG_STAGING"
  DMG_STAGING=""

  dmg_signing_arguments=(
    --force
    --sign "$SIGN_IDENTITY"
    "$TIMESTAMP_ARGUMENT"
  )
  codesign "${dmg_signing_arguments[@]}" "$DMG"
  (
    cd "$ARTIFACTS"
    shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256"
  )
  "$SCRIPT_DIR/verify-dmg.sh" \
    --mode "$PACKAGE_MODE" \
    --source-index "$SOURCE_RELEASE_INDEX" \
    --apk "$ANDROID_BRIDGE_APK" \
    "$DMG"
}

create_archive
create_dmg
if [[ "$NOTARIZE" -eq 1 ]]; then
  NOTARY_RESULT="$ARTIFACTS/OKVideoMac-${APP_VERSION}-notarization.json"
  xcrun notarytool submit "$DMG" \
    --keychain-profile "$OKVIDEOMAC_NOTARY_PROFILE" \
    --wait \
    --output-format json > "$NOTARY_RESULT"
  NOTARY_STATUS="$(python3 - "$NOTARY_RESULT" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as source:
    print(json.load(source).get("status", ""))
PY
)"
  if [[ "$NOTARY_STATUS" != "Accepted" ]]; then
    echo "Apple notarization did not return Accepted: ${NOTARY_STATUS:-missing}" >&2
    exit 1
  fi
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  codesign --verify --strict --verbose=4 "$DMG"
  "$SCRIPT_DIR/verify-dmg.sh" \
    --mode distribution \
    --source-index "$SOURCE_RELEASE_INDEX" \
    --apk "$ANDROID_BRIDGE_APK" \
    --require-gatekeeper \
    "$DMG"
  (
    cd "$ARTIFACTS"
    shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256"
  )
elif [[ "$PACKAGE_MODE" == "distribution" ]]; then
  echo "Notarization step not executed because credentials were not requested."
fi

# Preserve the established ZIP source/binary identity check: it verifies the
# embedded source index and APK byte-for-byte. The final public DMG is added as
# an outer release artifact and is independently checked by verify-dmg.sh.
"$SCRIPT_DIR/create-source-release.sh" \
  --output-dir "$SOURCE_RELEASE_DIR" \
  --cache-dir "$SOURCE_RELEASE_CACHE" \
  --commit HEAD \
  --apk "$ANDROID_BRIDGE_APK" \
  --binary "$ARCHIVE" \
  --release-artifact "$DMG" \
  --sbom "$SBOM_DIR/OKVideoMac-macOS.spdx.json" \
  --sbom "$SBOM_DIR/OKVideoMac-macOS.cdx.json" \
  --sbom "$SBOM_DIR/OKVideoMac-Android.spdx.json" \
  --sbom "$SBOM_DIR/OKVideoMac-Android.cdx.json" \
  --offline

# This second pass covers the final, possibly stapled DMG and every adjacent
# manifest/SBOM-bound source artifact. It runs after the last mutating step.
final_sensitive_scan_arguments=(
  "$SOURCE_RELEASE_DIR"
  --forbidden-literal "/Users/$(id -un)/"
  --forbidden-literal "$REPOSITORY_ROOT/"
)
if [[ -n "${TMPDIR:-}" ]]; then
  final_sensitive_scan_arguments+=(--forbidden-literal "${TMPDIR%/}/")
fi
PYTHONDONTWRITEBYTECODE=1 python3 \
  "$REPOSITORY_ROOT/Tools/SourceAudit/scan_release_artifacts.py" \
  "${final_sensitive_scan_arguments[@]}"

# Materialize the standalone App only after the canonical staging App, ZIP,
# DMG, signatures, SBOMs, and source-release identity have all passed. The
# destination may acquire host-local File Provider attributes, but its signed
# file bytes are copied from the already verified canonical bundle.
FINAL_APP_STAGING="$ARTIFACTS/.OKVideoMac.app.incoming"
rm -rf "$FINAL_APP_STAGING"
cp -R "$APP_DESTINATION" "$FINAL_APP_STAGING"
rm -rf "$FINAL_APP_DESTINATION"
mv "$FINAL_APP_STAGING" "$FINAL_APP_DESTINATION"

echo "Packaged app: $FINAL_APP_DESTINATION"
echo "Internal archive: $ARCHIVE"
echo "Public DMG: $DMG"
echo "Source release: $SOURCE_RELEASE_DIR"
