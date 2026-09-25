#!/bin/bash
set -euo pipefail

# Merge this build's manifest into the `website` branch:
#   manifests/<tag>.json       (per-build copy, appended every run)
#   archive/<channel>.json     (cumulative, union + live-filter like the old
#                               release-asset merge, but the previous state is
#                               a checked-out file — no gh download that can
#                               silently fail into an empty base)
#
# Run AFTER the archive file upload so the live-asset filter sees new files.
# Env: ARCHIVE_TAG (stable|beta), BUILD_TAG (release tag of this build),
#      GITHUB_REPOSITORY; git credentials from the workflow's checkout token.
# Reads: temp/manifest/build.json (from build_make_manifest.py)
#
# Concurrency: build.yml holds a single "build" concurrency group, so two
# builders never merge against the branch at the same time.

ARCHIVE_TAG="${ARCHIVE_TAG:?ARCHIVE_TAG not set}"
BUILD_TAG="${BUILD_TAG:?BUILD_TAG not set}"
REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY not set}"
BRANCH="website"
NEW_MANIFEST="temp/manifest/build.json"
OLD_MANIFEST="temp/manifest/archive-old.json"
LIVE_LIST="temp/manifest/archive-live-assets.txt"

if [ ! -f "$NEW_MANIFEST" ]; then
  echo "No $NEW_MANIFEST present — skipping archive manifest merge."
  exit 0
fi

ORIG_REF=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)
cleanup() {
  git checkout "$ORIG_REF" 2>/dev/null || git checkout main 2>/dev/null || true
}
trap cleanup EXIT

# 1. Previous branch state. A fetch failure is fatal by design: unlike the old
#    asset download there is no "start fresh from empty" path, the job must
#    fail loudly rather than restart the cumulative manifest.
git fetch origin "$BRANCH"
git checkout -q -B "$BRANCH" "origin/$BRANCH"

mkdir -p manifests archive
cp "$NEW_MANIFEST" "manifests/$BUILD_TAG.json"

if [ -f "archive/$ARCHIVE_TAG.json" ]; then
  cp "archive/$ARCHIVE_TAG.json" "$OLD_MANIFEST"
else
  echo "No archive/$ARCHIVE_TAG.json on $BRANCH yet — starting a fresh cumulative manifest."
  echo 'null' > "$OLD_MANIFEST"
fi

# 2. APK/ZIP assets actually present in the archive release right now
#    (releases remain the source of truth for file existence).
gh api --paginate "repos/$REPO/releases/tags/$ARCHIVE_TAG" -q '.assets[].name' \
  | grep -E '\.(apk|zip)$' > "$LIVE_LIST" || true
jq -Rn '[inputs]' "$LIVE_LIST" > temp/manifest/archive-live.json

# 3. Union (new entries override same-filename old entries), keep only keys
#    whose file exists in the release, stamp archive meta.
jq -s --slurpfile live temp/manifest/archive-live.json \
  --arg tag "$ARCHIVE_TAG" \
  --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    ((.[0].files // {}) + (.[1].files // {})) as $merged
    | {schema: 1,
       kind: "archive",
       meta: {build: $tag, channel: $tag, publishedAt: $now},
       files: ($merged | with_entries(select(.key as $k | $live[0] | index($k))))}
  ' "$OLD_MANIFEST" "$NEW_MANIFEST" > "archive/$ARCHIVE_TAG.json"

ENTRIES=$(jq '.files | length' "archive/$ARCHIVE_TAG.json")
# Sanity gate: every old/new entry whose file still lives on the release must
# have survived the merge. A shortfall means something upstream went wrong —
# refuse to publish instead of silently shrinking the archive manifest.
EXPECTED=$(jq -s --slurpfile live temp/manifest/archive-live.json '
  (((.[0].files // {}) | keys) + ((.[1].files // {}) | keys) | unique) as $keys
  | [$keys[] | select(. as $k | $live[0] | index($k))] | length
' "$OLD_MANIFEST" "$NEW_MANIFEST")
if [ "$ENTRIES" -lt "$EXPECTED" ]; then
  echo "::error::Merge kept $ENTRIES entries but $EXPECTED archived files still have manifest entries — refusing to push" >&2
  exit 1
fi
LIVE_COUNT=$(grep -c . "$LIVE_LIST" || true)
echo "Merged archive manifest for $ARCHIVE_TAG: $ENTRIES entries ($LIVE_COUNT live assets, $EXPECTED expected minimum)."

# 4. Commit and push; between attempts integrate any concurrent branch update
#    (paths are disjoint from cleanup's, so plain rebase is safe).
git config user.name "github-actions[bot]"
git config user.email "github-actions[bot]@users.noreply.github.com"
git add "manifests/$BUILD_TAG.json" "archive/$ARCHIVE_TAG.json"
git commit -q -m "chore: update $ARCHIVE_TAG manifest for build $BUILD_TAG [skip ci]"

ATTEMPT=1
until git push -q origin "$BRANCH"; do
  ATTEMPT=$((ATTEMPT + 1))
  if [ "$ATTEMPT" -gt 3 ]; then
    echo "::error::Failed to push $BRANCH after 3 attempts" >&2
    exit 1
  fi
  echo "Push attempt $((ATTEMPT - 1)) failed, rebasing and retrying in 15s..." >&2
  if ! git pull --rebase -q origin "$BRANCH"; then
    git rebase --abort || true
    echo "::error::Conflicting $BRANCH history — leaving merge committed locally; next build will reconverge" >&2
    exit 1
  fi
  sleep 15
done
echo "Website branch updated: manifests/$BUILD_TAG.json + archive/$ARCHIVE_TAG.json."
