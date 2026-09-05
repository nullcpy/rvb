#!/bin/bash
set -euo pipefail

echo "--- Fetching active releases ---"
ACTIVE_TAGS=$(gh release list -L 200 --json tagName -q '.[].tagName' 2>/dev/null || true)
if [ -z "$ACTIVE_TAGS" ]; then
  echo "No active releases found or gh CLI call failed. Skipping update branch cleanup."
  exit 0
fi

echo "--- Checking out update branch ---"
git fetch origin update || true
git checkout -B update origin/update


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
  git commit -m "chore: prune orphaned changelogs on update branch [skip ci]"
  git push origin update
else
  echo "No orphaned changelogs to prune. Update branch is clean."
fi
