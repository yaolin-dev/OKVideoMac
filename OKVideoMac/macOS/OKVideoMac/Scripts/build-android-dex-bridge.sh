#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
REPOSITORY_ROOT=${SCRIPT_DIR:h:h:h}
HELPER_DIR="$REPOSITORY_ROOT/Helpers/AndroidDexBridge"

if [[ -n "${ANDROID_HOME:-}" ]]; then
    RESOLVED_ANDROID_SDK="$ANDROID_HOME"
elif [[ -n "${ANDROID_SDK_ROOT:-}" ]]; then
    RESOLVED_ANDROID_SDK="$ANDROID_SDK_ROOT"
elif [[ -d "$HOME/Library/Android/sdk" ]]; then
    RESOLVED_ANDROID_SDK="$HOME/Library/Android/sdk"
else
    print -u2 "Android SDK not found. Set ANDROID_HOME or ANDROID_SDK_ROOT, or install it at $HOME/Library/Android/sdk."
    exit 1
fi

if [[ ! -x "$RESOLVED_ANDROID_SDK/platform-tools/adb" ]]; then
    print -u2 "Android SDK platform-tools are missing: $RESOLVED_ANDROID_SDK/platform-tools/adb"
    exit 1
fi

export ANDROID_HOME="$RESOLVED_ANDROID_SDK"
export ANDROID_SDK_ROOT="$RESOLVED_ANDROID_SDK"
if [[ -z "${JAVA_HOME:-}" ]]; then
    RESOLVED_JAVA_HOME="$(/usr/libexec/java_home -v 17 2>/dev/null)" || {
        print -u2 "JDK 17 is required. Set JAVA_HOME to a JDK 17 installation."
        exit 1
    }
    export JAVA_HOME="$RESOLVED_JAVA_HOME"
fi

cd "$HELPER_DIR"
./gradlew --no-daemon :app:assembleRelease

APK="$HELPER_DIR/app/build/outputs/apk/release/app-release.apk"
[[ -f "$APK" ]] || {
    print -u2 "Bridge APK was not produced"
    exit 1
}
print "$APK"
