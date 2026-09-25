#!/bin/bash
set -euo pipefail

# Prune the update branch:
#  1. *-update.json whose download pointer is fossilized — the zipUrl asset is
#     gone from the archive release AND the origin build's numbered release has
#     been deleted. Asset rotation alone never triggers this: a slug that is
#     still being built gets its update.json rewritten on every build against
#     files that exist at that moment.
#  2. changelogs/<tag>.md for releases that no longer exist and are no longer
#     referenced by any surviving *-update.json.
#
# The branch root is a wire format: module zips bake
# https://raw.githubusercontent.com/<repo>/update/<name>-update.json at build
# time, so files are only ever deleted here, never moved or renamed.

REPO="${GITHUB_REPOSITORY:-nullcpy/rvb}"

echo "--- Fetching active releases ---"
ACTIVE_TAGS=$(gh release list -L 200 --json tagName -q '.[].tagName' 2>/dev/null || true)
if [ -z "$ACTIVE_TAGS" ]; then
  echo "No active releases found or gh CLI call failed. Skipping update branch cleanup."
  exit 0
fi

# Current asset names on the two rolling archive releases (zipUrls point here).
LIVE_ASSETS=$(
  {
    gh api --paginate "repos/$REPO/releases/tags/stable" -q '.assets[].name' 2>/dev/null || true
    gh api --paginate "repos/$REPO/releases/tags/beta"  -q '.assets[].name' 2>/dev/null || true
  } | sort -u
)

ORIG_REF=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || git rev-parse HEAD 2>/dev/null || echo "main")
cleanup() {
  echo "--- Restoring original branch ($ORIG_REF) ---"
  git checkout "$ORIG_REF" 2>/dev/null || git checkout main 2>/dev/null || true
}
trap cleanup EXIT

echo "--- Checking out update branch ---"
git fetch origin update || true
git checkout -B update origin/update

DELETED_JSON=0
echo "--- Checking root update.json files for fossilized pointers ---"
shopt -s nullglob
for f in *-update.json; do
  [ -f "$f" ] || continue
  url=$(jq -r '.zipUrl // empty' "$f" 2>/dev/null || echo '')
  [ -n "$url" ] || continue
  # .../releases/download/<tag>/<asset>
  tag=$(basename "$(dirname "$url")")
  asset=$(basename "$url")
  if [ "$tag" = "stable" ] || [ "$tag" = "beta" ]; then
    asset_live=1
    echo "$LIVE_ASSETS" | grep -Fxq "$asset" || asset_live=0
    if [ "$asset_live" = "1" ]; then
      continue  # pointer still resolves, keep
    fi
    # Dead archive asset: only prune when the origin build is also gone,
    # so a failed archive upload (release alive) does not orphan the slug.
    rel=$(jq -r '.changelog // empty' "$f" | sed -n 's#.*/changelogs/\(.*\)\.md$#\1#p')
    if [ -n "$rel" ] && echo "$ACTIVE_TAGS" | grep -Fxq "$rel"; then
      echo "Keeping $f (asset pruned but release $rel is still active)"
      continue
    fi
    echo "Pruning fossilized pointer: $f (asset '$asset' gone, release '${rel:-?}' gone)"
    rm -f "$f"
    DELETED_JSON=$((DELETED_JSON + 1))
  else
    # Pointer to a numbered release: dead once that release is deleted.
    if ! echo "$ACTIVE_TAGS" | grep -Fxq "$tag"; then
      echo "Pruning fossilized pointer: $f (release '$tag' no longer exists)"
      rm -f "$f"
      DELETED_JSON=$((DELETED_JSON + 1))
    fi
  fi
done
shopt -u nullglob
echo "Pruned $DELETED_JSON fossilized update.json pointer(s)."

DELETED_COUNT=0
if [ -d changelogs ]; then
  echo "--- Checking changelogs directory for orphaned files ---"
  shopt -s nullglob
  for f in changelogs/*.md; do
    [ -f "$f" ] || continue
    fname=$(basename "$f")
    tag="${fname%.md}"
    if ! echo "$ACTIVE_TAGS" | grep -Fxq "$tag"; then
      if grep -q "changelogs/${tag}\.md" *-update.json /dev/null 2>/dev/null; then
        echo "Keeping changelog: $f (release '$tag' pruned, but still referenced by an active update.json)"
        continue
      fi
      echo "Pruning orphaned changelog: $f (release tag '$tag' no longer exists)"
      rm -f "$f"
      DELETED_COUNT=$((DELETED_COUNT + 1))
    fi
  done
  shopt -u nullglob
fi

echo "Pruned $DELETED_COUNT orphaned changelog(s)."

if ! git diff --quiet || ! git diff --cached --quiet || [ -n "$(git status --porcelain)" ]; then
  echo "--- Committing and pushing cleaned update branch ---"
  git config user.name "github-actions[bot]"
  git config user.email "github-actions[bot]@users.noreply.github.com"
  git add -A
  git commit -m "chore: prune fossilized update pointers and orphaned changelogs [skip ci]"
  git push origin update
else
  echo "Nothing to prune. Update branch is clean."
fi
