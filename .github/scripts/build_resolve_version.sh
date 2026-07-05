#!/bin/bash
set -euo pipefail

YEAR=$(date -u +"%y")
TAG=$( { gh release list --exclude-drafts -L 100 2>/dev/null || true; } | awk -F '\t' -v year="$YEAR" '$3 ~ "^" year "[0-9][0-9][0-9][0-9]$" {print $3}' | sort -nr | head -n1 )

if [ -n "$TAG" ]; then
    BUILD_COUNT=${TAG:2:4}
    BUILD_COUNT=$((10#$BUILD_COUNT + 1))
else
    BUILD_COUNT=1
fi

NEXT_VER_CODE=$(printf "%s%04d" "$YEAR" "$BUILD_COUNT")
echo "NEXT_VER_CODE=$NEXT_VER_CODE" >> "$GITHUB_OUTPUT"
