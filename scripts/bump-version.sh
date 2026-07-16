#!/bin/bash
# ============================================================
# bump-version.sh - 版本号自动递增脚本
# 用法: ./scripts/bump-version.sh [patch|minor|major]
# ============================================================

set -e

BUMP_TYPE="${1:-patch}"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

cd "$ROOT_DIR"

# 读取当前版本
if [ ! -f VERSION ]; then
    echo "1.0.0" > VERSION
fi

CURRENT_VERSION=$(cat VERSION)
echo "当前版本: $CURRENT_VERSION"

# 解析版本号
IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT_VERSION"

case "$BUMP_TYPE" in
    major)
        MAJOR=$((MAJOR + 1))
        MINOR=0
        PATCH=0
        ;;
    minor)
        MINOR=$((MINOR + 1))
        PATCH=0
        ;;
    patch|*)
        PATCH=$((PATCH + 1))
        ;;
esac

NEW_VERSION="${MAJOR}.${MINOR}.${PATCH}"
echo "新版本: $NEW_VERSION"

# 更新 VERSION 文件
echo "$NEW_VERSION" > VERSION

# 更新 control 文件
if [ -f control ]; then
    sed -i '' "s/Version: .*/Version: $NEW_VERSION/" control 2>/dev/null || \
    sed -i "s/Version: .*/Version: $NEW_VERSION/" control
fi

# 更新 Tweak.x 中的版本号
if [ -f Tweak.x ]; then
    sed -i '' "s/DK Multi-Account Tweak v[0-9.]*/DK Multi-Account Tweak v$NEW_VERSION/" Tweak.x 2>/dev/null || \
    sed -i "s/DK Multi-Account Tweak v[0-9.]*/DK Multi-Account Tweak v$NEW_VERSION/" Tweak.x
fi

echo "✅ 版本号已更新: $CURRENT_VERSION -> $NEW_VERSION"
echo "$NEW_VERSION"