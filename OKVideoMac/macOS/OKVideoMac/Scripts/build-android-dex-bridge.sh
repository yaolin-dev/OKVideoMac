#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
REPOSITORY_ROOT=${SCRIPT_DIR:h:h:h}
HELPER_DIR="$REPOSITORY_ROOT/Helpers/AndroidDexBridge"
ANDROID_SDK_ROOT=${ANDROID_SDK_ROOT:-/Volumes/XcodeDev/AndroidSDK}
GRADLE_USER_HOME=${GRADLE_USER_HOME:-/Volumes/XcodeDev/OKVideoMacBuild/Gradle}

if [[ ! -x "$ANDROID_SDK_ROOT/platform-tools/adb" ]]; then
    print -u2 "Android SDK not found at $ANDROID_SDK_ROOT"
    exit 1
fi

export ANDROID_SDK_ROOT
export GRADLE_USER_HOME
export JAVA_HOME=${JAVA_HOME:-/Library/Java/JavaVirtualMachines/zulu-17.jdk/Contents/Home}

cd "$HELPER_DIR"
./gradlew --no-daemon :app:assembleRelease

APK="$HELPER_DIR/app/build/outputs/apk/release/app-release.apk"
[[ -f "$APK" ]] || {
    print -u2 "Bridge APK was not produced"
    exit 1
}
print "$APK"
