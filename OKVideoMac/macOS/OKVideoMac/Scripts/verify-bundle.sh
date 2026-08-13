#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_FILE="$SCRIPT_DIR/../OKVideoMac.xcodeproj/project.pbxproj"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
GRADLE_LOCK="$REPOSITORY_ROOT/OKVideoMac/Helpers/AndroidDexBridge/app/gradle.lockfile"

if [[ "$#" -ne 1 ]]; then
  echo "Usage: $0 /path/to/OKVideoMac.app" >&2
  exit 64
fi

APP="$1"
EXECUTABLE="$APP/Contents/MacOS/OKVideoMac"
FRAMEWORKS="$APP/Contents/Frameworks"
BRIDGE_APK="$APP/Contents/Resources/AndroidDexBridge-release.apk"
NODE_RUNTIME="$APP/Contents/Resources/NodeRuntime/node"
LEGAL_ROOT="$APP/Contents/Resources/Legal"
APKANALYZER="${ANDROID_SDK_ROOT:-/Volumes/XcodeDev/AndroidSDK}/cmdline-tools/latest/bin/apkanalyzer"
EXPECTED_VERSION="${OKVIDEOMAC_EXPECTED_VERSION:-$(
  awk -F' = ' '/MARKETING_VERSION = / {
    gsub(/[ ;]/, "", $2)
    print $2
    exit
  }' "$PROJECT_FILE"
)}"
EXPECTED_BUILD="${OKVIDEOMAC_EXPECTED_BUILD:-$(
  awk -F' = ' '/CURRENT_PROJECT_VERSION = / {
    gsub(/[ ;]/, "", $2)
    print $2
    exit
  }' "$PROJECT_FILE"
)}"

if [[ ! -x "$EXECUTABLE" ]]; then
  echo "Main executable missing: $EXECUTABLE" >&2
  exit 1
fi
if ! lipo -info "$EXECUTABLE" | grep -q 'arm64'; then
  echo "Main executable is not arm64." >&2
  exit 1
fi
if [[ ! -f "$FRAMEWORKS/libmpv.dylib" ]]; then
  echo "Bundled libmpv is missing." >&2
  exit 1
fi
if [[ ! -f "$FRAMEWORKS/libOKMPVBridge.dylib" ]]; then
  echo "Bundled libmpv bridge is missing." >&2
  exit 1
fi
if [[ ! -f "$FRAMEWORKS/libOKQuickJS.dylib" ]]; then
  echo "Bundled QuickJS bridge is missing." >&2
  exit 1
fi
if [[ ! -x "$NODE_RUNTIME" ]]; then
  echo "Bundled Node runtime is missing." >&2
  exit 1
fi
if [[ ! -f "$BRIDGE_APK" ]]; then
  echo "Bundled Android Release bridge is missing." >&2
  exit 1
fi
ACTUAL_VERSION="$(
  plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist"
)"
ACTUAL_BUILD="$(plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist")"
if [[ "$ACTUAL_VERSION" != "$EXPECTED_VERSION" ]] ||
   [[ "$ACTUAL_BUILD" != "$EXPECTED_BUILD" ]]; then
  echo "The app has unexpected formal-release version metadata:" >&2
  echo "  expected $EXPECTED_VERSION ($EXPECTED_BUILD)" >&2
  echo "  actual   $ACTUAL_VERSION ($ACTUAL_BUILD)" >&2
  exit 1
fi
if [[ ! -f "$APP/Contents/Resources/AppIcon.icns" ]] ||
   [[ ! -f "$APP/Contents/Resources/Assets.car" ]]; then
  echo "The formal AppIcon is missing from the app bundle." >&2
  exit 1
fi
if [[ -f "$APP/Contents/Resources/AndroidDexBridge-debug.apk" ]]; then
  echo "A Debug Android bridge must not be included in a formal package." >&2
  exit 1
fi
if [[ ! -x "$APKANALYZER" ]]; then
  echo "apkanalyzer is required to verify the Android bridge." >&2
  exit 1
fi
if [[ "$("$APKANALYZER" manifest debuggable "$BRIDGE_APK")" != "false" ]]; then
  echo "Bundled Android bridge is debuggable." >&2
  exit 1
fi
if [[ "$("$APKANALYZER" manifest target-sdk "$BRIDGE_APK")" != "27" ]]; then
  echo "Bundled Android bridge lost legacy Spider Activity compatibility." >&2
  exit 1
fi
if [[ "$("$APKANALYZER" manifest version-name "$BRIDGE_APK")" != "0.3.14" ]]; then
  echo "Bundled Android bridge has an unexpected version." >&2
  exit 1
fi
if [[ ! -f "$APP/Contents/Resources/LICENSE" ]] ||
   [[ ! -f "$APP/Contents/Resources/NOTICE.md" ]]; then
  echo "GPL license or source/modification notice is missing." >&2
  exit 1
fi
if [[ ! -f "$APP/Contents/Resources/Licenses/QuickJS-MIT.txt" ]]; then
  echo "QuickJS license is missing." >&2
  exit 1
fi
if [[ ! -f "$APP/Contents/Resources/Licenses/Node.js-LICENSE.txt" ]]; then
  echo "Node.js license is missing." >&2
  exit 1
fi
if [[ ! -f "$APP/Contents/Resources/Licenses/mpv-GPL-2.0-or-later.txt" ]] ||
   [[ ! -f "$APP/Contents/Resources/Licenses/mpv-Copyright.txt" ]]; then
  echo "mpv license or copyright notice is missing." >&2
  exit 1
fi
required_legal_files=(
  "$LEGAL_ROOT/LICENSE"
  "$LEGAL_ROOT/NOTICE.md"
  "$LEGAL_ROOT/THIRD_PARTY_NOTICES.md"
  "$LEGAL_ROOT/THIRD_PARTY_LICENSES/FFmpeg-LGPL-2.1-or-later.txt"
  "$LEGAL_ROOT/THIRD_PARTY_LICENSES/FFmpeg-LICENSE.md"
  "$LEGAL_ROOT/THIRD_PARTY_LICENSES/mpv-GPL-2.0-or-later.txt"
  "$LEGAL_ROOT/THIRD_PARTY_LICENSES/mpv-Copyright.txt"
  "$LEGAL_ROOT/THIRD_PARTY_LICENSES/QuickJS-MIT.txt"
  "$LEGAL_ROOT/THIRD_PARTY_LICENSES/Node.js-LICENSE.txt"
  "$LEGAL_ROOT/THIRD_PARTY_LICENSES/libass-ISC.txt"
  "$LEGAL_ROOT/THIRD_PARTY_LICENSES/libplacebo-LGPL-2.1-or-later.txt"
  "$LEGAL_ROOT/THIRD_PARTY_LICENSES/HarfBuzz-MIT.txt"
  "$LEGAL_ROOT/THIRD_PARTY_LICENSES/FriBidi-LGPL-2.1-or-later.txt"
  "$LEGAL_ROOT/THIRD_PARTY_LICENSES/Brotli-MIT.txt"
  "$LEGAL_ROOT/THIRD_PARTY_LICENSES/Little-CMS-2-MIT.txt"
  "$LEGAL_ROOT/THIRD_PARTY_LICENSES/libpng-License.txt"
  "$LEGAL_ROOT/THIRD_PARTY_LICENSES/libjpeg-turbo-LICENSE.md"
  "$LEGAL_ROOT/THIRD_PARTY_LICENSES/libjpeg-turbo-README.ijg"
  "$LEGAL_ROOT/THIRD_PARTY_LICENSES/FreeType-FTL.txt"
  "$LEGAL_ROOT/THIRD_PARTY_LICENSES/XZ-libLZMA-0BSD.txt"
  "$LEGAL_ROOT/THIRD_PARTY_LICENSES/SQLite-Public-Domain.txt"
  "$LEGAL_ROOT/THIRD_PARTY_LICENSES/GNU-libiconv-LGPL-2.1-or-later.txt"
  "$LEGAL_ROOT/THIRD_PARTY_LICENSES/bzip2-License.txt"
  "$LEGAL_ROOT/THIRD_PARTY_LICENSES/zlib-License.txt"
  "$LEGAL_ROOT/THIRD_PARTY_LICENSES/LLVM-Apache-2.0-WITH-LLVM-exception.txt"
  "$LEGAL_ROOT/THIRD_PARTY_LICENSES/Apache-2.0.txt"
  "$LEGAL_ROOT/THIRD_PARTY_LICENSES/Bouncy-Castle-MIT.txt"
  "$LEGAL_ROOT/THIRD_PARTY_LICENSES/SLF4J-MIT.txt"
  "$LEGAL_ROOT/THIRD_PARTY_LICENSES/mbassador-MIT.txt"
  "$LEGAL_ROOT/THIRD_PARTY_LICENSES/juniversalchardet-MPL-1.1.txt"
  "$LEGAL_ROOT/THIRD_PARTY_LICENSES/stax-1.2.0-Apache-2.0.txt"
  "$LEGAL_ROOT/THIRD_PARTY_LICENSES/Gradle-LICENSE.txt"
  "$LEGAL_ROOT/THIRD_PARTY_LICENSES/Gradle-NOTICE.txt"
  "$LEGAL_ROOT/AndroidDexBridge/THIRD_PARTY_NOTICES.md"
  "$LEGAL_ROOT/AndroidDexBridge/FONGMI_CATVOD_CHANGES.md"
  "$LEGAL_ROOT/ModifiedSources/mpv-0.41.0-coreaudio-without-cocoa.patch"
  "$LEGAL_ROOT/ModifiedSources/mpv-0.41.0-coreaudio-without-cocoa.NOTICE.md"
  "$LEGAL_ROOT/Compliance/THIRD_PARTY_LICENSE_AUDIT.md"
  "$LEGAL_ROOT/Compliance/SOURCE_PROVENANCE_MANIFEST.md"
  "$LEGAL_ROOT/Compliance/BINARY_SOURCE_MAPPING.md"
  "$LEGAL_ROOT/Compliance/OPEN_SOURCE_COMPLIANCE.md"
  "$LEGAL_ROOT/Compliance/OPEN_SOURCE_P0_STATUS.md"
  "$LEGAL_ROOT/Compliance/APP_ICON_PROVENANCE.md"
  "$LEGAL_ROOT/Compliance/MPL_GPL_COMBINATION_REVIEW.md"
  "$LEGAL_ROOT/Compliance/MPL_GPL_COMBINATION_AUDIT.md"
  "$LEGAL_ROOT/Compliance/MPL_GPL_EVIDENCE/juniversalchardet-1.0.3-file-license-audit.json"
  "$LEGAL_ROOT/Compliance/MPL_GPL_EVIDENCE/juniversalchardet-1.0.3-file-license-audit.md"
  "$LEGAL_ROOT/Compliance/MPL_GPL_EVIDENCE/juniversalchardet-1.0.3-release-dex-audit.md"
  "$LEGAL_ROOT/Compliance/MPL_GPL_EVIDENCE/juniversalchardet-1.0.3-release-dex-classes.txt"
  "$LEGAL_ROOT/Compliance/MPL_GPL_COUNSEL_PACKAGE/README.md"
  "$LEGAL_ROOT/Compliance/MPL_GPL_COUNSEL_PACKAGE/01_COMPONENTS.md"
  "$LEGAL_ROOT/Compliance/MPL_GPL_COUNSEL_PACKAGE/02_LICENSE_HEADERS.md"
  "$LEGAL_ROOT/Compliance/MPL_GPL_COUNSEL_PACKAGE/03_BUILD_AND_DEX_RELATIONSHIP.md"
  "$LEGAL_ROOT/Compliance/MPL_GPL_COUNSEL_PACKAGE/04_MODIFICATIONS.md"
  "$LEGAL_ROOT/Compliance/MPL_GPL_COUNSEL_PACKAGE/05_DISTRIBUTION_MODEL.md"
  "$LEGAL_ROOT/Compliance/MPL_GPL_COUNSEL_PACKAGE/06_EXACT_HASHES.md"
  "$LEGAL_ROOT/Compliance/MPL_GPL_COUNSEL_PACKAGE/07_QUESTIONS_FOR_COUNSEL.md"
  "$LEGAL_ROOT/Compliance/NATIVE_REPRODUCIBLE_PROVENANCE.md"
  "$LEGAL_ROOT/Compliance/LGPL_LIBRARY_REPLACEMENT.md"
  "$LEGAL_ROOT/Compliance/SBOM_RELEASE_PROCESS.md"
  "$LEGAL_ROOT/Compliance/THIRD_PARTY_LICENSE_REAUDIT_PHASE2.md"
  "$LEGAL_ROOT/Compliance/NATIVE_DEPENDENCY_LOCK.json"
  "$LEGAL_ROOT/Compliance/SOURCE_RELEASE_PROCESS.md"
  "$LEGAL_ROOT/Compliance/XPP3_1_1_3_3_REMEDIATION.md"
  "$LEGAL_ROOT/Compliance/ENGINEERING_OPEN_SOURCE_READINESS_PHASE4.md"
  "$LEGAL_ROOT/Compliance/APPLE_RELEASE_GATES_PHASE4.md"
  "$LEGAL_ROOT/Compliance/IMMUTABLE_RELEASE_READINESS.md"
  "$LEGAL_ROOT/Compliance/Phase4/Native/PHASE4_NATIVE_INVENTORY.json"
  "$LEGAL_ROOT/Compliance/Phase4/Native/PHASE4_NATIVE_PROVENANCE.md"
  "$LEGAL_ROOT/Compliance/Phase4/Native/PHASE4_BASELINE_MACHO_SHA256.txt"
  "$LEGAL_ROOT/Compliance/Phase4/Native/PROVENANCE_CLEAN_NATIVE_BUILD.md"
  "$LEGAL_ROOT/Compliance/Phase4/Native/PHASE4_CANDIDATE_ABI_CAPABILITY.md"
  "$LEGAL_ROOT/Compliance/Phase4/Native/PHASE4_PLAYBACK_REGRESSION.md"
  "$LEGAL_ROOT/Compliance/Phase4/Native/MANUAL_PLAYBACK_REGRESSION.md"
  "$LEGAL_ROOT/Compliance/SENSITIVE_INFORMATION_SCAN.json"
  "$LEGAL_ROOT/Compliance/SOURCE_RELEASE_INDEX.json"
  "$LEGAL_ROOT/Compliance/BUILD_OUTPUT_SHA256.txt"
  "$LEGAL_ROOT/Compliance/SBOM/OKVideoMac-macOS.spdx.json"
  "$LEGAL_ROOT/Compliance/SBOM/OKVideoMac-macOS.cdx.json"
  "$LEGAL_ROOT/Compliance/SBOM/OKVideoMac-Android.spdx.json"
  "$LEGAL_ROOT/Compliance/SBOM/OKVideoMac-Android.cdx.json"
)
for required_legal_file in "${required_legal_files[@]}"; do
  if [[ ! -f "$required_legal_file" ]]; then
    echo "Legal payload file is missing: $required_legal_file" >&2
    exit 1
  fi
done
PYTHONDONTWRITEBYTECODE=1 python3 -m json.tool \
  "$LEGAL_ROOT/Compliance/MPL_GPL_EVIDENCE/juniversalchardet-1.0.3-file-license-audit.json" \
  >/dev/null
PYTHONDONTWRITEBYTECODE=1 python3 -m json.tool \
  "$LEGAL_ROOT/Compliance/Phase4/Native/PHASE4_NATIVE_INVENTORY.json" \
  >/dev/null
if [[ "$(PYTHONDONTWRITEBYTECODE=1 python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["status"])' "$LEGAL_ROOT/Compliance/SENSITIVE_INFORMATION_SCAN.json")" != "CLEAN" ]]; then
  echo "The packaged sensitive-information scan is not clean." >&2
  exit 1
fi
if [[ "$(wc -l < "$LEGAL_ROOT/Compliance/MPL_GPL_EVIDENCE/juniversalchardet-1.0.3-release-dex-classes.txt" | tr -d ' ')" != "62" ]]; then
  echo "The packaged juniversalchardet DEX class inventory is incomplete." >&2
  exit 1
fi
PYTHONDONTWRITEBYTECODE=1 python3 \
  "$REPOSITORY_ROOT/Tools/SourceAudit/verify_sbom.py" \
  --app "$APP" \
  --gradle-lock "$GRADLE_LOCK" \
  --sbom-dir "$LEGAL_ROOT/Compliance/SBOM"
if ! grep -Fq 'AndroidDexBridge-release.apk' \
  "$LEGAL_ROOT/THIRD_PARTY_NOTICES.md" ||
   ! grep -Fq 'xpp3:xpp3:1.1.3.3' \
  "$LEGAL_ROOT/AndroidDexBridge/THIRD_PARTY_NOTICES.md"; then
  echo "The legal payload does not link the APK to its dependency notice." >&2
  exit 1
fi
apk_dex_packages="$("$APKANALYZER" dex packages "$BRIDGE_APK")"
if grep -Fq 'org.xmlpull.mxp1' <<<"$apk_dex_packages"; then
  echo "The excluded xpp3 implementation is still present in the APK." >&2
  exit 1
fi
if ! grep -Fq 'juniversalchardet-1.0.3-sources.jar' \
  "$LEGAL_ROOT/Compliance/SOURCE_RELEASE_INDEX.json"; then
  echo "The source release index does not map MPL covered source." >&2
  exit 1
fi
OUTPUT_HASH_MANIFEST="$LEGAL_ROOT/Compliance/BUILD_OUTPUT_SHA256.txt"
expected_hash_entries=0
mach_o_entries=0
while IFS= read -r -d '' packaged_artifact; do
  if file "$packaged_artifact" | grep -q 'Mach-O'; then
    mach_o_entries=$((mach_o_entries + 1))
    packaged_relative="${packaged_artifact#"$APP/"}"
    if [[ "$packaged_relative" == "Contents/MacOS/OKVideoMac" ]]; then
      continue
    fi
    packaged_sha="$(shasum -a 256 "$packaged_artifact" | awk '{print $1}')"
    if ! grep -Fqx "$packaged_sha  $packaged_relative" \
      "$OUTPUT_HASH_MANIFEST"; then
      echo "Generated output hash is missing or stale: $packaged_relative" >&2
      exit 1
    fi
    expected_hash_entries=$((expected_hash_entries + 1))
  fi
done < <(find "$APP/Contents" -type f -print0)
apk_sha="$(shasum -a 256 "$BRIDGE_APK" | awk '{print $1}')"
apk_relative="${BRIDGE_APK#"$APP/"}"
if ! grep -Fqx "$apk_sha  $apk_relative" "$OUTPUT_HASH_MANIFEST"; then
  echo "Generated output hash is missing or stale: $apk_relative" >&2
  exit 1
fi
actual_hash_entries="$(grep -Ec '^[0-9a-f]{64}  Contents/' \
  "$OUTPUT_HASH_MANIFEST")"
if [[ "$mach_o_entries" -ne 28 ]] ||
   [[ "$expected_hash_entries" -ne 27 ]] ||
   [[ "$actual_hash_entries" -ne 28 ]]; then
  echo "Unexpected generated output hash inventory: $actual_hash_entries entries" >&2
  exit 1
fi
minimum_system="$(plutil -extract LSMinimumSystemVersion raw "$APP/Contents/Info.plist")"
if [[ "$minimum_system" != "12.0" ]]; then
  echo "Unexpected LSMinimumSystemVersion: $minimum_system" >&2
  exit 1
fi
if ! otool -L "$FRAMEWORKS/libOKMPVBridge.dylib" |
   grep -q '@rpath/libmpv.dylib'; then
  echo "libmpv bridge is not linked to bundled libmpv." >&2
  exit 1
fi

failure=0
mach_o_count=0
while IFS= read -r binary; do
  mach_o_count=$((mach_o_count + 1))
  # The first line printed by otool is the inspected binary's own path. Skip
  # it so an app installed below /Users is not mistaken for an external dylib.
  if otool -L "$binary" | tail -n +2 |
       grep -E '/opt/homebrew|/opt/local|/usr/local|/Users/' >/dev/null ||
     otool -l "$binary" | tail -n +2 |
       grep -E '/opt/homebrew|/opt/local|/usr/local|/Users/' >/dev/null; then
    echo "Forbidden absolute dependency in $binary" >&2
    otool -L "$binary" >&2
    failure=1
  fi
  if ! codesign --verify --strict "$binary"; then
    echo "Invalid signature: $binary" >&2
    failure=1
  fi
  if ! lipo -info "$binary" | grep -q 'arm64'; then
    echo "Non-arm64 binary: $binary" >&2
    failure=1
  fi
  if ! vtool -show-build "$binary" | awk '
    /minos/ {
      split($2, version, ".");
      found = 1;
      if (version[1] > 12 || (version[1] == 12 && version[2] > 0)) {
        exit 1;
      }
    }
    END { if (!found) exit 1 }
  '; then
    echo "Binary requires a system newer than macOS 12.0: $binary" >&2
    failure=1
  fi
done < <(find "$APP/Contents" -type f \( -perm -111 -o -name '*.dylib' \))

if [[ "$mach_o_count" -ne 28 ]]; then
  echo "Unexpected Mach-O inventory count: $mach_o_count (expected 28)" >&2
  failure=1
fi

if ! codesign --verify --strict "$APP"; then
  echo "App signature verification failed." >&2
  failure=1
fi
if [[ "$failure" -ne 0 ]]; then
  exit 1
fi

echo "Bundle verification passed: $APP"
