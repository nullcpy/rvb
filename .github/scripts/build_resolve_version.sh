#!/bin/bash
set -euo pipefail

YEAR=$(date -u +"%y")
TAG=$( {
    gh release list -L 100 2>/dev/null | awk -F '\t' -v year="$YEAR" '$3 ~ "^" year "[0-9][0-9][0-9][0-9]$" {print $3}' || true
    git tag -l "${YEAR}*" 2>/dev/null | awk -v year="$YEAR" '$1 ~ "^" year "[0-9][0-9][0-9][0-9]$" {print $1}' || true
} | sort -u -nr | head -n1 )

if [ -n "$TAG" ]; then
    BUILD_COUNT=${TAG:2:4}
    BUILD_COUNT=$((10#$BUILD_COUNT + 1))
else
    BUILD_COUNT=1
fi

NEXT_VER_CODE=$(printf "%s%04d" "$YEAR" "$BUILD_COUNT")
if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "NEXT_VER_CODE=$NEXT_VER_CODE" >> "$GITHUB_OUTPUT"
fi
echo "NEXT_VER_CODE=$NEXT_VER_CODE"

