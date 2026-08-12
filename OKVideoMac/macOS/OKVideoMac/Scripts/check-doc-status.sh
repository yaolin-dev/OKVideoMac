#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
README="$PROJECT_DIR/../../README.md"
COMPATIBILITY="$PROJECT_DIR/Docs/COMPATIBILITY.md"
PERFORMANCE="$PROJECT_DIR/Docs/PERFORMANCE.md"
PROJECT_YAML="$PROJECT_DIR/project.yml"

read_setting() {
  setting="$1"
  awk -v setting="$setting" '
    $1 == setting ":" {
      gsub(/["[:space:]]/, "", $2)
      print $2
      exit
    }
  ' "$PROJECT_YAML"
}

VERSION="$(read_setting MARKETING_VERSION)"
BUILD="$(read_setting CURRENT_PROJECT_VERSION)"
if [[ -z "$VERSION" || -z "$BUILD" ]]; then
  echo "Unable to read version metadata from $PROJECT_YAML" >&2
  exit 1
fi

assert_exact_line() {
  file="$1"
  expected="$2"
  if ! grep -Fqx -- "$expected" "$file"; then
    echo "Documentation metadata is stale: $file" >&2
    echo "Expected exact line: $expected" >&2
    exit 1
  fi
}

assert_exact_line "$README" "- 当前版本：${VERSION}（Build ${BUILD}）"
assert_exact_line "$COMPATIBILITY" "- 对照版本：${VERSION}（Build ${BUILD}）"
assert_exact_line "$PERFORMANCE" "- 对照版本：${VERSION}（Build ${BUILD}）"

STALE_PATTERN='当前尚未成功构建|当前尚无可运行 App|未构建/链接/播放|Swift/App 未经 Xcode 构建'
if grep -En "$STALE_PATTERN" "$README" "$COMPATIBILITY" "$PERFORMANCE"; then
  echo "Current-status documentation contains an obsolete build claim." >&2
  exit 1
fi

for historical_document in \
  "$PROJECT_DIR/Docs/MIGRATION_STATUS.md" \
  "$PROJECT_DIR/Docs/PLAYER_SPIKE.md"; do
  if ! grep -Fq -- '文档类型：历史' "$historical_document"; then
    echo "Historical document is missing its status banner: $historical_document" >&2
    exit 1
  fi
done

echo "Documentation status check passed: ${VERSION} (${BUILD})"
