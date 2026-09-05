#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
REPOSITORY_ROOT=${SCRIPT_DIR:h:h:h}
HELPER_DIR="$REPOSITORY_ROOT/Helpers/AndroidDexBridge"
EXPECTED_CERTIFICATE_FILE="$SCRIPT_DIR/android-bridge-signing.sha256"

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

[[ -f "$EXPECTED_CERTIFICATE_FILE" ]] || {
    print -u2 "Pinned Android Bridge certificate fingerprint is missing."
    exit 1
}
EXPECTED_CERTIFICATE="$(tr -d '[:space:]' < "$EXPECTED_CERTIFICATE_FILE")"
print -r -- "$EXPECTED_CERTIFICATE" | grep -Eq '^[0-9a-f]{64}$' || {
    print -u2 "Pinned Android Bridge certificate fingerprint is invalid."
    exit 1
}

SIGNING_ROOT="${OKVIDEOMAC_ANDROID_BRIDGE_SIGNING_ROOT:-$HOME/Library/Application Support/OKVideoMac/Signing}"
RELEASE_KEYSTORE="${OKVIDEOMAC_ANDROID_BRIDGE_KEYSTORE:-$SIGNING_ROOT/AndroidBridgeRelease.jks}"
LEGACY_KEYSTORE="${OKVIDEOMAC_ANDROID_BRIDGE_LEGACY_KEYSTORE:-$HOME/.android/debug.keystore}"
STORE_PASSWORD="${OKVIDEOMAC_ANDROID_BRIDGE_STORE_PASSWORD:-android}"
KEY_ALIAS="${OKVIDEOMAC_ANDROID_BRIDGE_KEY_ALIAS:-androiddebugkey}"
KEY_PASSWORD="${OKVIDEOMAC_ANDROID_BRIDGE_KEY_PASSWORD:-android}"
KEYTOOL="$JAVA_HOME/bin/keytool"
[[ -x "$KEYTOOL" ]] || {
    print -u2 "JDK keytool is required to verify the Android Bridge signer."
    exit 1
}

keystore_certificate() {
    LC_ALL=C "$KEYTOOL" -list -v \
        -keystore "$1" \
        -alias "$KEY_ALIAS" \
        -storepass "$STORE_PASSWORD" \
        -keypass "$KEY_PASSWORD" 2>/dev/null |
        awk -F'SHA256:' '/SHA256:/ {
            value=$2
            gsub(/[^0-9A-Fa-f]/, "", value)
            print tolower(value)
            exit
        }'
}

if [[ ! -f "$RELEASE_KEYSTORE" ]]; then
    [[ -f "$LEGACY_KEYSTORE" ]] || {
        print -u2 "Persistent Android Bridge keystore is missing."
        print -u2 "Provide the original compatible keystore; a new key would erase upgrade continuity."
        exit 1
    }
    LEGACY_CERTIFICATE="$(keystore_certificate "$LEGACY_KEYSTORE")"
    [[ "$LEGACY_CERTIFICATE" == "$EXPECTED_CERTIFICATE" ]] || {
        print -u2 "Legacy Android keystore does not match the pinned Bridge identity."
        exit 1
    }
    /bin/mkdir -p "$SIGNING_ROOT"
    /usr/bin/install -m 600 "$LEGACY_KEYSTORE" "$RELEASE_KEYSTORE"
fi

ACTUAL_KEYSTORE_CERTIFICATE="$(keystore_certificate "$RELEASE_KEYSTORE")"
[[ "$ACTUAL_KEYSTORE_CERTIFICATE" == "$EXPECTED_CERTIFICATE" ]] || {
    print -u2 "Android Bridge Release keystore identity mismatch; build stopped."
    exit 1
}

APKSIGNER=""
while IFS= read -r candidate; do
    [[ -x "$candidate" ]] || continue
    APKSIGNER="$candidate"
done < <(find "$RESOLVED_ANDROID_SDK/build-tools" -mindepth 2 -maxdepth 2 \
    -path '*/apksigner' -type f 2>/dev/null | sort -V)
[[ -x "$APKSIGNER" ]] || {
    print -u2 "Android SDK apksigner is required."
    exit 1
}

export OKVIDEOMAC_ANDROID_BRIDGE_KEYSTORE="$RELEASE_KEYSTORE"
export OKVIDEOMAC_ANDROID_BRIDGE_STORE_PASSWORD="$STORE_PASSWORD"
export OKVIDEOMAC_ANDROID_BRIDGE_KEY_ALIAS="$KEY_ALIAS"
export OKVIDEOMAC_ANDROID_BRIDGE_KEY_PASSWORD="$KEY_PASSWORD"

cd "$HELPER_DIR"
./gradlew --no-daemon :app:assembleRelease

APK="$HELPER_DIR/app/build/outputs/apk/release/app-release.apk"
[[ -f "$APK" ]] || {
    print -u2 "Bridge APK was not produced"
    exit 1
}
APK_CERTIFICATE="$($APKSIGNER verify --print-certs "$APK" |
    awk -F': ' '/Signer #1 certificate SHA-256 digest:/ {
        value=$2
        gsub(/[^0-9A-Fa-f]/, "", value)
        print tolower(value)
        exit
    }')"
[[ "$APK_CERTIFICATE" == "$EXPECTED_CERTIFICATE" ]] || {
    print -u2 "Built Android Bridge certificate does not match the pinned identity."
    exit 1
}
print "$APK"
