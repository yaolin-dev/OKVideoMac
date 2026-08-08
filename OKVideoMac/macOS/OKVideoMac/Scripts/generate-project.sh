#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen is required. Install XcodeGen 2.38.0 or newer." >&2
  echo "Add a standalone XcodeGen binary or the MacPorts xcodegen port to PATH." >&2
  exit 1
fi

xcodegen_version="$(xcodegen --version | awk '{print $2}')"
echo "Using XcodeGen $xcodegen_version"
xcodegen generate --spec "$PROJECT_DIR/project.yml" --project "$PROJECT_DIR"
echo "Generated $PROJECT_DIR/OKVideoMac.xcodeproj"
