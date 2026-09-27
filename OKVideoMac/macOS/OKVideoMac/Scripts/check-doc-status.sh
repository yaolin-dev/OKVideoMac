#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
README="$PROJECT_DIR/../../README.md"
REPOSITORY_ROOT="$(cd "$PROJECT_DIR/../../.." && pwd)"
ROOT_README="$REPOSITORY_ROOT/README.md"
ROOT_README_ZH="$REPOSITORY_ROOT/README_zh-CN.md"
CHANGELOG="$REPOSITORY_ROOT/CHANGELOG.md"
NOTICES="$PROJECT_DIR/../../THIRD_PARTY_NOTICES.md"
NATIVE_LOCK="$REPOSITORY_ROOT/ThirdParty/native-lock.json"
SOURCE_RELEASE_PROCESS="$REPOSITORY_ROOT/Docs/SOURCE_RELEASE_PROCESS.md"
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
READINESS="$REPOSITORY_ROOT/Docs/RELEASE_READINESS_${VERSION}.md"
VALIDATION="$REPOSITORY_ROOT/Docs/RELEASE_VALIDATION_${VERSION}.md"

assert_exact_line() {
  file="$1"
  expected="$2"
  if ! grep -Fqx -- "$expected" "$file"; then
    echo "Documentation metadata is stale: $file" >&2
    echo "Expected exact line: $expected" >&2
    exit 1
  fi
}

assert_contains() {
  file="$1"
  expected="$2"
  if ! grep -Fq -- "$expected" "$file"; then
    echo "Documentation metadata is stale: $file" >&2
    echo "Expected text: $expected" >&2
    exit 1
  fi
}

assert_exact_line "$README" "- 当前稳定版本：${VERSION}（Build ${BUILD}）"
assert_exact_line "$COMPATIBILITY" "- 对照版本：${VERSION}（Build ${BUILD}）"
assert_exact_line "$PERFORMANCE" "- 对照版本：${VERSION}（Build ${BUILD}）"
assert_contains "$ROOT_README" "latest stable release is **${VERSION} (Build ${BUILD})**"
assert_contains "$ROOT_README_ZH" "最新稳定版本为 **${VERSION}（Build ${BUILD}）**"
assert_contains "$CHANGELOG" "## [${VERSION}] - "
assert_contains "$NOTICES" "OKVideoMac ${VERSION} (Build ${BUILD})"
assert_exact_line "$PERFORMANCE" "- 多站搜索全局并发 20；共享同一 Node runtime 的站点并发 20，聚合搜索每站只取第一页；"
assert_contains "$SOURCE_RELEASE_PROCESS" "OKVideoMac-${VERSION}.dmg"
assert_contains "$SOURCE_RELEASE_PROCESS" "OKVideoMac-${VERSION}-macOS-arm64.zip"
assert_contains "$SOURCE_RELEASE_PROCESS" "OKVideoMac-${VERSION}-build${BUILD}-SOURCE_RELEASE_INDEX.json"
assert_exact_line "$REPOSITORY_ROOT/Docs/RELEASE_NOTES_${VERSION}.md" "# OKVideoMac ${VERSION}（Build ${BUILD}）Release Notes"
assert_contains "$README" "Tag：\`v${VERSION}\`"
assert_contains "$README" "OKVideoMac-${VERSION}-build${BUILD}-SOURCE_RELEASE_INDEX.json"
assert_contains "$COMPATIBILITY" "tag \`v${VERSION}\`"
assert_exact_line "$READINESS" "# OKVideoMac ${VERSION}（Build ${BUILD}）发布就绪记录"
assert_exact_line "$VALIDATION" "# OKVideoMac ${VERSION}（Build ${BUILD}）正式发布验证记录"

PYTHONDONTWRITEBYTECODE=1 python3 - "$PROJECT_DIR" "$VERSION" "$BUILD" <<'PY'
import pathlib
import plistlib
import re
import sys

root, version, build = sys.argv[1:]
root = pathlib.Path(root)
project = (root / "OKVideoMac.xcodeproj/project.pbxproj").read_text()
for key, expected in (("MARKETING_VERSION", version), ("CURRENT_PROJECT_VERSION", build)):
    values = re.findall(rf"\b{key}\s*=\s*([^;]+);", project)
    if not values or any(value.strip().strip('"') != expected for value in values):
        raise SystemExit(f"Xcode project {key} disagrees with project.yml: {values}")
info = plistlib.loads((root / "Supporting/Info.plist").read_bytes())
for key, expected in (("CFBundleShortVersionString", "$(MARKETING_VERSION)"),
                      ("CFBundleVersion", "$(CURRENT_PROJECT_VERSION)")):
    if info.get(key) != expected:
        raise SystemExit(f"Info.plist must use the shared build setting for {key}")
PY

PYTHONDONTWRITEBYTECODE=1 python3 - "$NATIVE_LOCK" "$VERSION" "$BUILD" <<'PY'
import json
import sys

path, version, build = sys.argv[1:]
with open(path, encoding="utf-8") as source:
    release = json.load(source).get("release")
expected = f"OKVideoMac {version} ({build})"
if release != expected:
    raise SystemExit(f"Native lock release metadata is stale: {release!r}; expected {expected!r}")
PY

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

echo "Documentation status check passed: ${VERSION} (Build ${BUILD})"
