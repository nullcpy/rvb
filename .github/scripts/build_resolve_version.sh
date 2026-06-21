#!/bin/bash
set -euo pipefail
TAG=$( { gh release list --exclude-drafts -L 100 2>/dev/null || true; } | awk -F '\t' '$3 ~ /^[0-9]+$/ {print $3}' | sort -nr | head -n1 )
if [ -z "$TAG" ] || ! [[ "$TAG" =~ ^[0-9]+$ ]]; then TAG=0; fi
echo "NEXT_VER_CODE=$((TAG + 1))" >> "$GITHUB_OUTPUT"
