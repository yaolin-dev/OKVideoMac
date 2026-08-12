#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
  echo "Usage: $0 --mode local|distribution /path/to/OKVideoMac.app" >&2
}

MODE=""
if [[ "${1:-}" == "--mode" && "$#" -ge 3 ]]; then
  MODE="$2"
  shift 2
fi
if [[ "$MODE" != "local" && "$MODE" != "distribution" ]] || [[ "$#" -ne 1 ]]; then
  usage
  exit 64
fi

APP="$1"
FRAMEWORKS="$APP/Contents/Frameworks"
MAIN_EXECUTABLE="$APP/Contents/MacOS/OKVideoMac"
NODE_EXECUTABLE="$APP/Contents/Resources/NodeRuntime/node"
if [[ ! -x "$MAIN_EXECUTABLE" || ! -x "$NODE_EXECUTABLE" ]]; then
  echo "Incomplete OKVideoMac app: $APP" >&2
  exit 1
fi

if [[ "$MODE" == "distribution" ]]; then
  SIGN_IDENTITY="${DEVELOPER_ID_APPLICATION:-}"
  HOST_ENTITLEMENTS="$PROJECT_DIR/Supporting/OKVideoMac.release.entitlements"
  TIMESTAMP_ARGUMENT="--timestamp"
  if [[ -z "$SIGN_IDENTITY" || "$SIGN_IDENTITY" == "-" ]]; then
    echo "distribution smoke requires DEVELOPER_ID_APPLICATION." >&2
    exit 2
  fi
else
  SIGN_IDENTITY="-"
  HOST_ENTITLEMENTS="$PROJECT_DIR/Supporting/OKVideoMac.dev.entitlements"
  TIMESTAMP_ARGUMENT="--timestamp=none"
fi

TEMPORARY_DIRECTORY="$(mktemp -d /tmp/okvideomac-hr-smoke.XXXXXX)"
cleanup() {
  rm -rf "$TEMPORARY_DIRECTORY"
}
trap cleanup EXIT

sign_smoke_host() {
  codesign \
    --force \
    --sign "$SIGN_IDENTITY" \
    --options runtime \
    "$TIMESTAMP_ARGUMENT" \
    --entitlements "$HOST_ENTITLEMENTS" \
    "$1"
}

QUICKJS_SMOKE="$TEMPORARY_DIRECTORY/quickjs-bridge-smoke"
clang \
  -arch arm64 \
  -mmacosx-version-min=12.0 \
  -I"$PROJECT_DIR/Native/QuickJSBridge" \
  "$PROJECT_DIR/Native/QuickJSBridge/smoke.c" \
  -L"$FRAMEWORKS" \
  -lOKQuickJS \
  -Wl,-rpath,"$FRAMEWORKS" \
  -o "$QUICKJS_SMOKE"
sign_smoke_host "$QUICKJS_SMOKE"
quickjs_output="$($QUICKJS_SMOKE 2>&1)"
echo "PASS: QuickJS Hardened Runtime smoke (exit=0)"
printf '%s\n' "$quickjs_output"

MPV_SMOKE="$TEMPORARY_DIRECTORY/mpv-bridge-smoke"
clang \
  -arch arm64 \
  -mmacosx-version-min=12.0 \
  -I"$PROJECT_DIR/Native/MPVBridge" \
  "$PROJECT_DIR/Native/MPVBridge/smoke.c" \
  -L"$FRAMEWORKS" \
  -lOKMPVBridge \
  -Wl,-rpath,"$FRAMEWORKS" \
  -o "$MPV_SMOKE"
sign_smoke_host "$MPV_SMOKE"
mpv_output="$($MPV_SMOKE 2>&1)"
echo "PASS: MPV/FFmpeg Hardened Runtime initialization smoke (exit=0)"
printf '%s\n' "$mpv_output"

node_output="$($NODE_EXECUTABLE -e '
  const values = Array.from({length: 20000}, (_, index) => index);
  const sum = values.reduce((total, value) => total + value, 0);
  console.log(`node=${process.version} v8=${process.versions.v8} sum=${sum}`);
' 2>&1)"
echo "PASS: Node/V8 Hardened Runtime JIT smoke (exit=0, no SIGTRAP)"
printf '%s\n' "$node_output"

"$MAIN_EXECUTABLE" \
  >"$TEMPORARY_DIRECTORY/app.stdout.log" \
  2>"$TEMPORARY_DIRECTORY/app.stderr.log" &
app_pid=$!
sleep 5
if ! kill -0 "$app_pid" 2>/dev/null; then
  echo "FAIL: Release app exited during startup smoke." >&2
  sed -n '1,120p' "$TEMPORARY_DIRECTORY/app.stderr.log" >&2
  wait "$app_pid" || true
  exit 1
fi
echo "PASS: Release app remained running for 5 seconds."
kill "$app_pid" 2>/dev/null || true
wait "$app_pid" || true

echo "Hardened Runtime smoke tests passed (mode=$MODE)."
