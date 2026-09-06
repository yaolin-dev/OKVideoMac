#!/bin/zsh
set -euo pipefail

# Developer/release-engineering entry point. It uses an isolated workspace,
# AVD namespace, private ADB daemon, ADB key, and port range. It never installs
# SDK packages and never mutates OKVideoMac's production AndroidRuntime.

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
PACKAGE_DIR="$PROJECT_DIR/Packages/AndroidRuntimeKit"
MODE="${1:-preflight}"
shift $(( $# > 0 ? 1 : 0 ))

[[ "$MODE" == "preflight" || "$MODE" == "run" ]] || {
    print -u2 "Usage: $0 preflight|run [--candidate candidate-id ...]"
    exit 2
}

: ${OKVIDEOMAC_MATRIX_SDK_ROOT:?Set OKVIDEOMAC_MATRIX_SDK_ROOT to an explicit Android SDK.}
: ${OKVIDEOMAC_MATRIX_JAVA_HOME:?Set OKVIDEOMAC_MATRIX_JAVA_HOME to an explicit JDK.}

[[ "$OKVIDEOMAC_MATRIX_SDK_ROOT" == /* ]] || {
    print -u2 "OKVIDEOMAC_MATRIX_SDK_ROOT must be absolute."
    exit 2
}
[[ "$OKVIDEOMAC_MATRIX_JAVA_HOME" == /* ]] || {
    print -u2 "OKVIDEOMAC_MATRIX_JAVA_HOME must be absolute."
    exit 2
}

MATRIX_WORKSPACE="${OKVIDEOMAC_MATRIX_WORKSPACE:-$PROJECT_DIR/Vendor/Build/AndroidRuntimeMatrix}"
BRIDGE_APK="${OKVIDEOMAC_MATRIX_BRIDGE_APK:-$PROJECT_DIR/../../Helpers/AndroidDexBridge/app/build/outputs/apk/release/app-release.apk}"
FIXTURE_JAR="${OKVIDEOMAC_MATRIX_FIXTURE_JAR:-$MATRIX_WORKSPACE/matrix-fixture.jar}"
PROFILE="${OKVIDEOMAC_MATRIX_ENVIRONMENT_PROFILE:-contaminated}"
SELECTED_CANDIDATE="api-35-google-apis-arm64"

if [[ "$MODE" == "run" && ! -f "$FIXTURE_JAR" ]]; then
    ANDROID_HOME="$OKVIDEOMAC_MATRIX_SDK_ROOT" \
    ANDROID_SDK_ROOT="$OKVIDEOMAC_MATRIX_SDK_ROOT" \
    JAVA_HOME="$OKVIDEOMAC_MATRIX_JAVA_HOME" \
        "$SCRIPT_DIR/build-android-runtime-matrix-fixture.sh" "$FIXTURE_JAR"
fi

ARGUMENTS=(
    "$MODE"
    --sdk-root "$OKVIDEOMAC_MATRIX_SDK_ROOT"
    --java-home "$OKVIDEOMAC_MATRIX_JAVA_HOME"
    --bridge-apk "$BRIDGE_APK"
    --workspace "$MATRIX_WORKSPACE"
    --environment-profile "$PROFILE"
)
if [[ "$MODE" == "run" ]]; then
    ARGUMENTS+=(--fixture-jar "$FIXTURE_JAR")
fi

# Keep the normal entry point intentionally narrow. Running a broader matrix
# requires explicit --candidate arguments rather than happening by accident.
if (( ${@[(I)--candidate]} == 0 )); then
    ARGUMENTS+=(--candidate "$SELECTED_CANDIDATE")
fi
ARGUMENTS+=("$@")

cd "$PACKAGE_DIR"
swift run android-runtime-matrix "${ARGUMENTS[@]}"
