#!/bin/bash
# ============================================================
# gen-changelog.sh - 更新日志生成脚本
# 用法: ./scripts/gen-changelog.sh
# ============================================================

set -e

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

VERSION=$(cat VERSION 2>/dev/null || echo "1.0.0")
TODAY=$(date +%Y-%m-%d)

# 获取最近的 commit 消息
LAST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
if [ -z "$LAST_TAG" ]; then
    COMMITS=$(git log --oneline --no-merges -10 2>/dev/null || echo "")
else
    COMMITS=$(git log ${LAST_TAG}..HEAD --oneline --no-merges 2>/dev/null || echo "")
fi

# 生成 changelog 条目
CHANGELOG_ENTRY="## [${VERSION}] - ${TODAY}"

if [ -z "$COMMITS" ]; then
    CHANGELOG_ENTRY+="\n- 构建版本更新"
else
    while IFS= read -r line; do
        if [ -n "$line" ]; then
            CHANGELOG_ENTRY+="\n- ${line}"
        fi
    done <<< "$COMMITS"
fi

# 更新 CHANGELOG.md
if [ -f CHANGELOG.md ]; then
    HEADER=$(head -1 CHANGELOG.md)
    CONTENT=$(tail -n +2 CHANGELOG.md)
    echo -e "$HEADER\n\n$CHANGELOG_ENTRY\n$CONTENT" > CHANGELOG.md
else
    echo -e "# Changelog\n\n$CHANGELOG_ENTRY" > CHANGELOG.md
fi

echo "✅ 更新日志已生成"
echo -e "$CHANGELOG_ENTRY"