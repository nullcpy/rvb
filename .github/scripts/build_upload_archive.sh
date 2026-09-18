#!/bin/bash
set -euo pipefail

ARCHIVE_TAG="${ARCHIVE_TAG:?ARCHIVE_TAG not set}"
REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY not set}"

echo "=== Uploading build files to archive release: $ARCHIVE_TAG ==="

# 1. Ensure archive release exists or create it
if ! gh release view "$ARCHIVE_TAG" -R "$REPO" >/dev/null 2>&1; then
    echo "Archive release $ARCHIVE_TAG does not exist, creating..."
    gh release create "$ARCHIVE_TAG" -t "$ARCHIVE_TAG" -n "Archive release for $ARCHIVE_TAG builds" --target main -R "$REPO"
fi

# 2. Collect files from ./build/
shopt -s nullglob
FILES=(./build/*)
shopt -u nullglob

if [ ${#FILES[@]} -eq 0 ]; then
    echo "No files in ./build/ to upload to archive"
    exit 0
fi

echo "Uploading ${#FILES[@]} file(s) to archive $ARCHIVE_TAG..."
for file in "${FILES[@]}"; do
    [ -f "$file" ] || continue
    filename=$(basename "$file")
    echo "⬆️ Uploading $filename to archive..."
    for attempt in 1 2 3; do
        if gh release upload "$ARCHIVE_TAG" "$file" --clobber -R "$REPO"; then
            echo "✅ Uploaded $filename to archive"
            break
        fi
        echo "::warning::Attempt $attempt/3 failed for $filename, retrying in 10s..."
        sleep 10
    done
done

echo "=== Archive release upload completed ==="
