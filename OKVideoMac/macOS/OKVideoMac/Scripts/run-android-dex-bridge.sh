#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
REPOSITORY_ROOT=${SCRIPT_DIR:h:h:h}
ANDROID_SDK_ROOT=${ANDROID_SDK_ROOT:-/Volumes/XcodeDev/AndroidSDK}
ANDROID_AVD_HOME=${ANDROID_AVD_HOME:-/Volumes/XcodeDev/AndroidAVD}
RUNTIME_DIR=${OKVIDEO_ANDROID_RUNTIME_DIR:-/Volumes/XcodeDev/OKVideoMacBuild/AndroidRuntime}
APK="$REPOSITORY_ROOT/Helpers/AndroidDexBridge/app/build/outputs/apk/release/app-release.apk"
ADB="$ANDROID_SDK_ROOT/platform-tools/adb"
EMULATOR="$ANDROID_SDK_ROOT/emulator/emulator"
DEVICE=emulator-5554

export ANDROID_SDK_ROOT ANDROID_AVD_HOME

mkdir -p "$RUNTIME_DIR"

if ! "$ADB" -s "$DEVICE" get-state >/dev/null 2>&1; then
    FIRST_BOOT=()
    if [[ ! -f "$RUNTIME_DIR/userdata-qemu.img" ]]; then
        FIRST_BOOT=(-wipe-data)
    fi
    nohup "$EMULATOR" \
        -avd OKVideoDexBridge \
        -no-window \
        -no-audio \
        -no-boot-anim \
        -no-metrics \
        -no-snapshot \
        -gpu off \
        -accel on \
        -datadir "$RUNTIME_DIR" \
        -show-kernel \
        "${FIRST_BOOT[@]}" \
        >"$RUNTIME_DIR/emulator.log" 2>&1 </dev/null &
    EMULATOR_PID=$!
    print $EMULATOR_PID >"$RUNTIME_DIR/emulator.pid"
fi

"$ADB" -s "$DEVICE" wait-for-device
BOOT_WAIT_STARTED=$SECONDS
while [[ "$("$ADB" -s "$DEVICE" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" != "1" ]]; do
    if (( SECONDS - BOOT_WAIT_STARTED > 240 )); then
        print -u2 "Android emulator did not boot within 240 seconds"
        exit 1
    fi
    sleep 1
done

"$ADB" -s "$DEVICE" shell cmd wifi clear-user-disabled-networks \
    >/dev/null 2>&1 || true
if ! "$ADB" -s "$DEVICE" shell cmd wifi status 2>/dev/null |
    grep -q "Wifi is connected"; then
    "$ADB" -s "$DEVICE" shell cmd wifi connect-network AndroidWifi open
fi

[[ -f "$APK" ]] || {
    print -u2 "Build the bridge APK first: Scripts/build-android-dex-bridge.sh"
    exit 1
}

"$ADB" -s "$DEVICE" install -r "$APK"
"$ADB" -s "$DEVICE" shell am start -n com.okvideomac.dexbridge/.BridgeActivity
"$ADB" -s "$DEVICE" forward --remove tcp:19978 >/dev/null 2>&1 || true
"$ADB" -s "$DEVICE" forward tcp:19978 tcp:9978
"$ADB" -s "$DEVICE" forward --remove tcp:18096 >/dev/null 2>&1 || true
"$ADB" -s "$DEVICE" forward tcp:18096 tcp:8096
"$ADB" -s "$DEVICE" forward --remove tcp:16677 >/dev/null 2>&1 || true
"$ADB" -s "$DEVICE" forward tcp:16677 tcp:6677
curl --fail --silent --show-error --max-time 5 http://127.0.0.1:19978/health
