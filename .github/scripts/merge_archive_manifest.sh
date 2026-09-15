#!/bin/bash
set -euo pipefail

# Merge this build's manifest into the archive release's cumulative build.json.
# Run AFTER the archive file upload so the live-asset filter sees the new files.
#
# Env: ARCHIVE_TAG (stable|beta), GITHUB_REPOSITORY
# Reads:  temp/manifest/build.json (from build_make_manifest.py)
# Writes: temp/archive-upload/build.json and uploads it to the archive release.
#
# Concurrency: build.yml holds a single "build" concurrency group, so two builders
# never merge against the archive release at the same time.

ARCHIVE_TAG="${ARCHIVE_TAG:?ARCHIVE_TAG not set}"
REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY not set}"
NEW_MANIFEST="temp/manifest/build.json"
OLD_MANIFEST="temp/manifest/archive-old.json"
LIVE_LIST="temp/manifest/archive-live-assets.txt"
OUT_DIR="temp/archive-upload"
OUT_MANIFEST="$OUT_DIR/build.json"

mkdir -p temp/manifest "$OUT_DIR"

if [ ! -f "$NEW_MANIFEST" ]; then
  echo "No $NEW_MANIFEST present — skipping archive manifest merge."
  exit 0
fi

# 1. Previous cumulative manifest from the archive release (or empty).
if ! gh release download "$ARCHIVE_TAG" -p build.json -O "$OLD_MANIFEST" -R "$REPO" 2>/dev/null; then
  echo 'null' > "$OLD_MANIFEST"
fi

# 2. APK/ZIP assets actually present in the archive release right now.
gh api --paginate "repos/$REPO/releases/tags/$ARCHIVE_TAG" -q '.assets[].name' \
  | grep -E '\.(apk|zip)$' > "$LIVE_LIST" || true
jq -Rn '[inputs]' "$LIVE_LIST" > temp/manifest/archive-live.json

# 3. Union (new entries override same-filename old entries), keep only keys whose
#    file exists in the release, stamp archive meta.
jq -s --slurpfile live temp/manifest/archive-live.json \
  --arg tag "$ARCHIVE_TAG" \
  --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    ((.[0].files // {}) + (.[1].files // {})) as $merged
    | {schema: 1,
       kind: "archive",
       meta: {build: $tag, channel: $tag, publishedAt: $now},
       files: ($merged | with_entries(select(.key as $k | $live[0] | index($k))))}
  ' "$OLD_MANIFEST" "$NEW_MANIFEST" > "$OUT_MANIFEST"

ENTRIES=$(jq '.files | length' "$OUT_MANIFEST")
echo "Merged archive manifest for $ARCHIVE_TAG: $ENTRIES entries. Uploading..."

# 4. Upload with retries so a transient API failure doesn't silently orphan the
#    new files' metadata until the next rebuild.
ATTEMPT=1
until gh release upload "$ARCHIVE_TAG" "$OUT_MANIFEST" --clobber -R "$REPO"; do
  ATTEMPT=$((ATTEMPT + 1))
  if [ "$ATTEMPT" -gt 3 ]; then
    echo "::error::Failed to upload archive manifest to $ARCHIVE_TAG after 3 attempts" >&2
    exit 1
  fi
  echo "Upload attempt $((ATTEMPT - 1)) failed, retrying in 15s..." >&2
  sleep 15
done
echo "Archive manifest uploaded to $ARCHIVE_TAG."
