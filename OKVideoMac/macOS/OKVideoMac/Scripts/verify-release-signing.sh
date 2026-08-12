#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 --mode local|distribution [--require-gatekeeper] /path/to/OKVideoMac.app" >&2
}

MODE=""
REQUIRE_GATEKEEPER=0
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --mode)
      MODE="${2:-}"
      shift 2
      ;;
    --require-gatekeeper)
      REQUIRE_GATEKEEPER=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      break
      ;;
  esac
done

if [[ "$MODE" != "local" && "$MODE" != "distribution" ]]; then
  usage
  exit 64
fi
if [[ "$#" -ne 1 ]]; then
  usage
  exit 64
fi
if [[ "$REQUIRE_GATEKEEPER" -eq 1 && "$MODE" != "distribution" ]]; then
  echo "--require-gatekeeper is only valid in distribution mode." >&2
  exit 64
fi

APP="$1"
MAIN_EXECUTABLE="$APP/Contents/MacOS/OKVideoMac"
NODE_EXECUTABLE="$APP/Contents/Resources/NodeRuntime/node"
if [[ ! -d "$APP" || ! -x "$MAIN_EXECUTABLE" || ! -x "$NODE_EXECUTABLE" ]]; then
  echo "Incomplete OKVideoMac bundle: $APP" >&2
  exit 1
fi

signature_info() {
  codesign -d --verbose=4 "$1" 2>&1
}

entitlements_xml() {
  codesign -d --entitlements :- "$1" 2>&1 |
    sed -n '/^<?xml/,$p' || true
}

has_entitlement() {
  target="$1"
  entitlement="$2"
  xml="$(entitlements_xml "$target")"
  [[ -n "$xml" ]] || return 1
  compact_xml="$(printf '%s' "$xml" | tr -d '[:space:]')"
  [[ "$compact_xml" == *"<key>$entitlement</key><true/>"* ]]
}

failure=0
if ! codesign --verify --deep --strict --verbose=4 "$APP"; then
  echo "FAIL: strict deep signature verification" >&2
  failure=1
else
  echo "PASS: codesign --verify --deep --strict"
fi

app_info="$(signature_info "$APP")"
app_team="$(printf '%s\n' "$app_info" | awk -F= '/^TeamIdentifier=/{print $2; exit}')"
app_authority="$(printf '%s\n' "$app_info" | awk -F= '/^Authority=/{print $2; exit}')"
app_flags="$(printf '%s\n' "$app_info" | awk -F= '/^CodeDirectory /{for (i=1;i<=NF;i++) if ($i ~ /^0x/) print $i; exit}')"

if [[ "$app_flags" != *runtime* ]]; then
  echo "FAIL: main app has no Hardened Runtime flag." >&2
  failure=1
fi
if [[ "$MODE" == "distribution" ]]; then
  if [[ -z "$app_team" || "$app_team" == "not set" ]]; then
    echo "FAIL: distribution app has no TeamIdentifier." >&2
    failure=1
  fi
  if [[ "$app_authority" != Developer\ ID\ Application:* ]]; then
    echo "FAIL: distribution app is not signed by Developer ID Application." >&2
    failure=1
  fi
  if printf '%s\n' "$app_info" | grep -q 'Signature=adhoc'; then
    echo "FAIL: distribution app is ad-hoc signed." >&2
    failure=1
  fi
else
  if ! printf '%s\n' "$app_info" | grep -q 'Signature=adhoc'; then
    echo "FAIL: local package is expected to be ad-hoc signed." >&2
    failure=1
  fi
fi

for forbidden in \
  com.apple.security.cs.allow-jit \
  com.apple.security.cs.allow-unsigned-executable-memory \
  com.apple.security.get-task-allow; do
  if has_entitlement "$APP" "$forbidden"; then
    echo "FAIL: main app contains forbidden entitlement: $forbidden" >&2
    failure=1
  fi
done
if [[ "$MODE" == "distribution" ]]; then
  if has_entitlement "$APP" com.apple.security.cs.disable-library-validation; then
    echo "FAIL: distribution app disables Library Validation." >&2
    failure=1
  fi
else
  if ! has_entitlement "$APP" com.apple.security.cs.disable-library-validation; then
    echo "FAIL: local ad-hoc package lacks its development-only Library Validation exception." >&2
    failure=1
  fi
fi

if ! has_entitlement "$NODE_EXECUTABLE" com.apple.security.cs.allow-jit; then
  echo "FAIL: bundled Node does not have allow-jit." >&2
  failure=1
fi
for forbidden in \
  com.apple.security.cs.disable-library-validation \
  com.apple.security.cs.allow-unsigned-executable-memory \
  com.apple.security.get-task-allow; do
  if has_entitlement "$NODE_EXECUTABLE" "$forbidden"; then
    echo "FAIL: bundled Node contains forbidden entitlement: $forbidden" >&2
    failure=1
  fi
done

machos=()
while IFS= read -r -d '' candidate; do
  if file "$candidate" | grep -q 'Mach-O'; then
    machos+=("$candidate")
  fi
done < <(find "$APP/Contents" -type f -print0)

if [[ "${#machos[@]}" -eq 0 ]]; then
  echo "FAIL: no Mach-O objects found." >&2
  exit 1
fi

printf 'PATH\tARCH\tTEAM\tRUNTIME\tSIGNATURE\n'
for binary in "${machos[@]}"; do
  relative_path="${binary#"$APP/"}"
  architectures="$(lipo -archs "$binary")"
  info="$(signature_info "$binary")"
  team="$(printf '%s\n' "$info" | awk -F= '/^TeamIdentifier=/{print $2; exit}')"
  flags="$(printf '%s\n' "$info" | awk -F= '/^CodeDirectory /{for (i=1;i<=NF;i++) if ($i ~ /^0x/) print $i; exit}')"
  signature="Developer ID"
  if printf '%s\n' "$info" | grep -q 'Signature=adhoc'; then
    signature="ad-hoc"
  fi

  if ! codesign --verify --strict "$binary"; then
    echo "FAIL: invalid nested signature: $relative_path" >&2
    failure=1
  fi
  if [[ "$architectures" != "arm64" ]]; then
    echo "FAIL: unexpected architecture '$architectures': $relative_path" >&2
    failure=1
  fi
  if [[ "$flags" != *runtime* ]]; then
    echo "FAIL: Hardened Runtime missing: $relative_path" >&2
    failure=1
  fi
  if [[ "$binary" != "$NODE_EXECUTABLE" ]] &&
     has_entitlement "$binary" com.apple.security.cs.allow-jit; then
    echo "FAIL: allow-jit escaped the Node boundary: $relative_path" >&2
    failure=1
  fi
  if [[ "$MODE" == "distribution" ]]; then
    if [[ -z "$team" || "$team" == "not set" || "$team" != "$app_team" ]]; then
      echo "FAIL: TeamIdentifier mismatch: $relative_path (${team:-missing})" >&2
      failure=1
    fi
    if [[ "$signature" == "ad-hoc" ]]; then
      echo "FAIL: unexpected ad-hoc nested code: $relative_path" >&2
      failure=1
    fi
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$relative_path" \
    "$architectures" \
    "${team:-not set}" \
    "${flags:-missing}" \
    "$signature"
done

if [[ "$MODE" == "distribution" ]]; then
  if spctl --assess --type execute --verbose=4 "$APP"; then
    echo "PASS: Gatekeeper assessment"
  elif [[ "$REQUIRE_GATEKEEPER" -eq 1 ]]; then
    echo "FAIL: Gatekeeper assessment is required after notarization." >&2
    failure=1
  else
    echo "NOT ACCEPTED: Gatekeeper assessment (expected before notarization)" >&2
  fi
else
  echo "NOT TESTED: Gatekeeper assessment is not applicable to an ad-hoc local package."
fi

if [[ "$failure" -ne 0 ]]; then
  exit 1
fi
echo "Signing verification passed (${#machos[@]} Mach-O objects, mode=$MODE)."
