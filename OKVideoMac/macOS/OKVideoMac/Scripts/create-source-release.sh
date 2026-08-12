#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

exec /usr/bin/python3 \
  "$REPOSITORY_ROOT/Tools/SourceAudit/create_source_release.py" "$@"
