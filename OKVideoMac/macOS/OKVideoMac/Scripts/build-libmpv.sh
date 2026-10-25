#!/usr/bin/env bash
set -euo pipefail
# The public player must use the pinned FFmpeg build with DASH support.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/build-dash-native.sh" "$@"
