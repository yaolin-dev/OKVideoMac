#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPOSITORY_DIR="$(cd "$PROJECT_DIR/../.." && pwd)"
REQUIRED_XCODEGEN_VERSION="2.38.0"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen is required. OKVideoMac requires XcodeGen $REQUIRED_XCODEGEN_VERSION exactly." >&2
  echo "Add a standalone XcodeGen binary or the MacPorts xcodegen port to PATH." >&2
  exit 1
fi

xcodegen_version="$(xcodegen --version | awk '{print $2}')"
if [[ "$xcodegen_version" != "$REQUIRED_XCODEGEN_VERSION" ]]; then
  echo "Unsupported XcodeGen version: $xcodegen_version" >&2
  echo "OKVideoMac requires XcodeGen $REQUIRED_XCODEGEN_VERSION exactly." >&2
  exit 1
fi

echo "Using XcodeGen $xcodegen_version"

if [[ "${1:-}" == "--check" ]]; then
  if [[ "$#" -ne 1 ]]; then
    echo "Usage: $0 [--check]" >&2
    exit 2
  fi

  temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/okvideomac-xcodegen-check.XXXXXX")"
  trap 'rm -rf "$temporary_root"' EXIT
  temporary_repository="$temporary_root/OKVideoMac"
  temporary_project="$temporary_repository/macOS/OKVideoMac"

  cp -R "$REPOSITORY_DIR" "$temporary_repository"
  xcodegen generate \
    --spec "$temporary_project/project.yml" \
    --project "$temporary_project"

  generated_paths=(
    "OKVideoMac.xcodeproj/project.pbxproj"
    "OKVideoMac.xcodeproj/project.xcworkspace/contents.xcworkspacedata"
    "OKVideoMac.xcodeproj/xcshareddata/xcschemes/OKVideoMac.xcscheme"
    "Supporting/Info.plist"
  )

  drift_detected=0
  for relative_path in "${generated_paths[@]}"; do
    if ! cmp -s "$PROJECT_DIR/$relative_path" "$temporary_project/$relative_path"; then
      echo "Generated project drift detected: $relative_path" >&2
      diff -u "$PROJECT_DIR/$relative_path" "$temporary_project/$relative_path" >&2 || true
      drift_detected=1
    fi
  done

  if [[ "$drift_detected" -ne 0 ]]; then
    echo "Run $0 with XcodeGen $REQUIRED_XCODEGEN_VERSION and commit the generated files." >&2
    exit 1
  fi

  echo "XcodeGen generation check passed."
  exit 0
fi

if [[ "$#" -ne 0 ]]; then
  echo "Usage: $0 [--check]" >&2
  exit 2
fi

xcodegen generate --spec "$PROJECT_DIR/project.yml" --project "$PROJECT_DIR"
echo "Generated $PROJECT_DIR/OKVideoMac.xcodeproj"
