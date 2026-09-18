#!/bin/bash
set -euo pipefail

TAG="${TAG:?TAG not set}"
REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY not set}"
PRERELEASE="${IS_PRERELEASE:-false}"
BODY_FILE="build.md"
TITLE="Build No. $TAG"

echo "=== Uploading build release for tag: $TAG ==="

# 1. Ensure release exists or create it
PRERELEASE_ARG=()
if [ "$PRERELEASE" = "true" ]; then
    PRERELEASE_ARG=(--prerelease)
fi

NOTES_ARG=()
if [ -s "$BODY_FILE" ]; then
    NOTES_ARG=(-F "$BODY_FILE")
else
    NOTES_ARG=(-n "")
fi

if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
    echo "Release $TAG already exists, updating metadata..."
    EDIT_PRERELEASE_ARG=()
    if [ "$PRERELEASE" = "true" ]; then
        EDIT_PRERELEASE_ARG=(--prerelease)
    else
        EDIT_PRERELEASE_ARG=(--prerelease=false)
    fi
    gh release edit "$TAG" -t "$TITLE" "${NOTES_ARG[@]}" "${EDIT_PRERELEASE_ARG[@]}" -R "$REPO" || true
else
    echo "Creating release $TAG..."
    gh release create "$TAG" -t "$TITLE" "${NOTES_ARG[@]}" "${PRERELEASE_ARG[@]}" -R "$REPO"
fi

# 2. Collect files to upload
shopt -s nullglob
FILES=(./build/* ./temp/manifest/build.json)
shopt -u nullglob

if [ ${#FILES[@]} -eq 0 ]; then
    echo "::warning::No build files found to upload"
    exit 0
fi

echo "Uploading ${#FILES[@]} file(s) to release $TAG..."

# 3. Upload each file with retry
FAILED_FILES=()
for file in "${FILES[@]}"; do
    [ -f "$file" ] || continue
    filename=$(basename "$file")
    echo "⬆️ Uploading $filename..."
    uploaded=false
    for attempt in 1 2 3; do
        if gh release upload "$TAG" "$file" --clobber -R "$REPO"; then
            echo "✅ Uploaded $filename"
            uploaded=true
            break
        fi
        echo "::warning::Attempt $attempt/3 failed for $filename, retrying in 10s..."
        sleep 10
    done
    if [ "$uploaded" = false ]; then
        echo "::error::Failed to upload $filename after 3 attempts"
        FAILED_FILES+=("$filename")
    fi
done

if [ ${#FAILED_FILES[@]} -gt 0 ]; then
    echo "::error::The following file(s) failed to upload: ${FAILED_FILES[*]}"
    exit 1
fi

echo "=== All release assets uploaded successfully ==="
