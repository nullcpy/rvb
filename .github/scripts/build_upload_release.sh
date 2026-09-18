#!/bin/bash
set -euo pipefail

# Unified release uploader using native gh CLI with per-file retry and clobber.
#
# Inputs (via env vars):
#   RELEASE_TAG / TAG     : Release tag name (required)
#   RELEASE_TITLE / TITLE : Release title (default: "Build No. $TAG")
#   RELEASE_BODY_FILE     : Path to markdown notes file (e.g. build.md)
#   RELEASE_NOTES         : Inline release notes string (used if no body file)
#   IS_PRERELEASE         : "true" to mark as prerelease (default: "false")
#   RELEASE_TARGET        : Target branch/commit for new release (optional, e.g. main)
#   UPLOAD_FILES          : Space-separated files/glob patterns (default: "./build/*")
#   GITHUB_REPOSITORY     : owner/repo (required)
#   GH_TOKEN              : GitHub token (required)

TAG="${RELEASE_TAG:-${TAG:?RELEASE_TAG or TAG not set}}"
REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY not set}"
TITLE="${RELEASE_TITLE:-${TITLE:-Build No. $TAG}}"
BODY_FILE="${RELEASE_BODY_FILE:-${BODY_FILE:-}}"
IS_PRERELEASE="${IS_PRERELEASE:-false}"
TARGET="${RELEASE_TARGET:-${TARGET:-}}"
FILES_PATTERN="${UPLOAD_FILES:-${FILES:-./build/*}}"

echo "=== Uploading release assets for tag: $TAG ==="

# 1. Prepare create / edit flags
TARGET_ARG=()
[ -n "$TARGET" ] && TARGET_ARG=(--target "$TARGET")

PRERELEASE_CREATE_ARG=()
PRERELEASE_EDIT_ARG=()
if [ "$IS_PRERELEASE" = "true" ]; then
    PRERELEASE_CREATE_ARG=(--prerelease)
    PRERELEASE_EDIT_ARG=(--prerelease)
else
    PRERELEASE_EDIT_ARG=(--prerelease=false)
fi

NOTES_ARG=()
if [ -n "$BODY_FILE" ] && [ -s "$BODY_FILE" ]; then
    NOTES_ARG=(-F "$BODY_FILE")
elif [ -n "${RELEASE_NOTES:-}" ]; then
    NOTES_ARG=(-n "$RELEASE_NOTES")
else
    NOTES_ARG=(-n "")
fi

# 2. Ensure release exists or create it
if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
    echo "Release $TAG already exists, updating metadata..."
    gh release edit "$TAG" -t "$TITLE" "${NOTES_ARG[@]}" "${PRERELEASE_EDIT_ARG[@]}" -R "$REPO" || true
else
    echo "Creating release $TAG..."
    gh release create "$TAG" -t "$TITLE" "${NOTES_ARG[@]}" "${PRERELEASE_CREATE_ARG[@]}" "${TARGET_ARG[@]}" -R "$REPO"
fi

# 3. Collect files to upload
shopt -s nullglob
FILES=()
for pattern in $FILES_PATTERN; do
    for f in $pattern; do
        [ -f "$f" ] && FILES+=("$f")
    done
done
shopt -u nullglob

if [ ${#FILES[@]} -eq 0 ]; then
    echo "No files matched '$FILES_PATTERN' to upload"
    exit 0
fi

PARALLEL_JOBS="${UPLOAD_CONCURRENCY:-4}"
echo "Uploading ${#FILES[@]} file(s) to release $TAG (concurrency: $PARALLEL_JOBS)..."

# 4. Upload files in parallel with per-file retry
FAILED_LOG=$(mktemp)
trap 'rm -f "$FAILED_LOG"' EXIT

upload_file() {
    local file="$1"
    local idx="$2"
    local total="$3"
    local filename
    filename=$(basename "$file")
    echo "⬆️ [$idx/$total] Uploading $filename..."
    for attempt in 1 2 3; do
        if gh release upload "$TAG" "$file" --clobber -R "$REPO"; then
            echo "✅ [$idx/$total] Uploaded $filename"
            return 0
        fi
        echo "::warning::[$idx/$total] Attempt $attempt/3 failed for $filename, retrying in 5s..."
        sleep 5
    done
    echo "::error::[$idx/$total] Failed to upload $filename after 3 attempts"
    echo "$filename" >> "$FAILED_LOG"
    return 1
}

job_count=0
idx=0
total=${#FILES[@]}

for file in "${FILES[@]}"; do
    ((idx++)) || true
    upload_file "$file" "$idx" "$total" &
    ((job_count++)) || true
    if [ "$job_count" -ge "$PARALLEL_JOBS" ]; then
        wait -n || true
        ((job_count--)) || true
    fi
done
wait

if [ -s "$FAILED_LOG" ]; then
    echo "::error::The following file(s) failed to upload:"
    cat "$FAILED_LOG"
    exit 1
fi

echo "=== All release assets uploaded successfully ==="
