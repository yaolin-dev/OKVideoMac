#!/bin/zsh
set -euo pipefail

# Developer/release-engineering tool. The generated DEX JAR is never shipped
# in OKVideoMac.app and is served only to an isolated Candidate Matrix AVD.

SCRIPT_DIR=${0:A:h}
REPOSITORY_ROOT=${SCRIPT_DIR:h:h:h}
HELPER_DIR="$REPOSITORY_ROOT/Helpers/AndroidDexBridge"
SOURCE="$HELPER_DIR/matrix-fixture/src/com/github/catvod/spider/MatrixFixture.java"
OUTPUT="${1:-$SCRIPT_DIR/../Vendor/Build/AndroidRuntimeMatrix/matrix-fixture.jar}"

if [[ -n "${ANDROID_HOME:-}" ]]; then
    RESOLVED_ANDROID_SDK="$ANDROID_HOME"
elif [[ -n "${ANDROID_SDK_ROOT:-}" ]]; then
    RESOLVED_ANDROID_SDK="$ANDROID_SDK_ROOT"
else
    print -u2 "Set ANDROID_HOME to the explicit Candidate Matrix SDK."
    exit 1
fi

[[ -f "$SOURCE" ]] || {
    print -u2 "Matrix fixture source is missing: $SOURCE"
    exit 1
}
[[ -x "$RESOLVED_ANDROID_SDK/platform-tools/adb" ]] || {
    print -u2 "Candidate Matrix SDK is incomplete: $RESOLVED_ANDROID_SDK"
    exit 1
}

if [[ -z "${JAVA_HOME:-}" ]]; then
    print -u2 "Set JAVA_HOME to the explicit Candidate Matrix JDK."
    exit 1
fi
JAVAC="$JAVA_HOME/bin/javac"
[[ -x "$JAVAC" ]] || {
    print -u2 "Managed matrix javac is missing: $JAVAC"
    exit 1
}

ANDROID_JAR="$RESOLVED_ANDROID_SDK/platforms/android-35/android.jar"
[[ -f "$ANDROID_JAR" ]] || {
    print -u2 "Android 35 compile platform is required: $ANDROID_JAR"
    exit 1
}

CATVOD_CLASSES="$HELPER_DIR/catvod/build/intermediates/compile_library_classes_jar/release/bundleLibCompileToJarRelease/classes.jar"
if [[ ! -f "$CATVOD_CLASSES" ]]; then
    (
        cd "$HELPER_DIR"
        ./gradlew --no-daemon :catvod:bundleReleaseAar
    )
fi
[[ -f "$CATVOD_CLASSES" ]] || {
    print -u2 "CatVod compile classes were not produced."
    exit 1
}

D8=""
while IFS= read -r candidate; do
    [[ -x "$candidate" ]] || continue
    D8="$candidate"
done < <(find "$RESOLVED_ANDROID_SDK/build-tools" -mindepth 2 -maxdepth 2 \
    -path '*/d8' -type f 2>/dev/null | sort -V)
[[ -x "$D8" ]] || {
    print -u2 "Android build-tools d8 is required."
    exit 1
}

WORKSPACE="$(mktemp -d "${TMPDIR:-/tmp}/okvideo-matrix-fixture.XXXXXX")"
trap '/bin/rm -rf "$WORKSPACE"' EXIT
CLASSES="$WORKSPACE/classes"
/bin/mkdir -p "$CLASSES" "${OUTPUT:h}"

"$JAVAC" --release 8 \
    -classpath "$ANDROID_JAR:$CATVOD_CLASSES" \
    -d "$CLASSES" \
    "$SOURCE"

"$D8" --release \
    --lib "$ANDROID_JAR" \
    --classpath "$CATVOD_CLASSES" \
    --output "$OUTPUT" \
    "$CLASSES/com/github/catvod/spider/MatrixFixture.class"

[[ -s "$OUTPUT" ]] || {
    print -u2 "Matrix fixture DEX JAR was not produced."
    exit 1
}
/usr/bin/shasum -a 256 "$OUTPUT"
