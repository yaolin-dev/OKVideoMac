#!/bin/zsh
set -euo pipefail

# Explicit developer-only preparation for Candidate Matrix evaluation. By
# default it installs only the selected API 35 candidate. Additional SDK
# packages must be passed explicitly as arguments. This changes only the SDK
# named by OKVIDEOMAC_MATRIX_SDK_ROOT, does not accept licenses automatically,
# and never reads or writes the production AVD.

: ${OKVIDEOMAC_MATRIX_SDK_ROOT:?Set OKVIDEOMAC_MATRIX_SDK_ROOT to an explicit Android SDK.}
: ${OKVIDEOMAC_MATRIX_JAVA_HOME:?Set OKVIDEOMAC_MATRIX_JAVA_HOME to an explicit JDK.}

[[ "$OKVIDEOMAC_MATRIX_SDK_ROOT" == /* ]] || {
    print -u2 "OKVIDEOMAC_MATRIX_SDK_ROOT must be absolute."
    exit 2
}
SDKMANAGER="$OKVIDEOMAC_MATRIX_SDK_ROOT/cmdline-tools/latest/bin/sdkmanager"
[[ -x "$SDKMANAGER" ]] || {
    print -u2 "sdkmanager is missing: $SDKMANAGER"
    exit 1
}

export ANDROID_HOME="$OKVIDEOMAC_MATRIX_SDK_ROOT"
export ANDROID_SDK_ROOT="$OKVIDEOMAC_MATRIX_SDK_ROOT"
export JAVA_HOME="$OKVIDEOMAC_MATRIX_JAVA_HOME"
export PATH="$JAVA_HOME/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export LANG=C
export LC_ALL=C
unset ADB_SERVER_SOCKET ANDROID_ADB_SERVER_PORT ADB_VENDOR_KEYS

PACKAGES=("$@")
if (( ${#PACKAGES[@]} == 0 )); then
    PACKAGES=(
        "platforms;android-35"
        "build-tools;35.0.0"
        "system-images;android-35;google_apis;arm64-v8a"
    )
fi

"$SDKMANAGER" --install "${PACKAGES[@]}"
