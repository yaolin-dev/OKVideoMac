#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
REFERENCE_DIR="$PROJECT_ROOT/Reference/FongMiTV"
UPSTREAM_URL="https://github.com/FongMi/TV.git"
UPSTREAM_COMMIT="5fdff00a602dc56e8ba756174daef20edab024f2"

if [[ -e "$REFERENCE_DIR/.git" ]] && git -C "$REFERENCE_DIR" rev-parse --verify HEAD >/dev/null 2>&1; then
  current_commit="$(git -C "$REFERENCE_DIR" rev-parse HEAD)"
  if [[ "$current_commit" == "$UPSTREAM_COMMIT" ]]; then
    echo "FongMi/TV reference is already at $UPSTREAM_COMMIT"
    exit 0
  fi
  echo "Reference checkout exists at unexpected commit: $current_commit" >&2
  echo "Move it manually before fetching the pinned baseline." >&2
  exit 1
fi

mkdir -p "$(dirname "$REFERENCE_DIR")"
if [[ ! -e "$REFERENCE_DIR/.git" ]]; then
  git init "$REFERENCE_DIR"
fi
if ! git -C "$REFERENCE_DIR" remote get-url origin >/dev/null 2>&1; then
  git -C "$REFERENCE_DIR" remote add origin "$UPSTREAM_URL"
fi
git -C "$REFERENCE_DIR" fetch --depth 1 origin "$UPSTREAM_COMMIT"
git -C "$REFERENCE_DIR" checkout --detach FETCH_HEAD

actual_commit="$(git -C "$REFERENCE_DIR" rev-parse HEAD)"
if [[ "$actual_commit" != "$UPSTREAM_COMMIT" ]]; then
  echo "Fetched commit mismatch: $actual_commit" >&2
  exit 1
fi
echo "Fetched FongMi/TV $actual_commit into $REFERENCE_DIR"
