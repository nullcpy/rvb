#!/bin/bash
set -euo pipefail

# Materialize the `data` branch into the working tree: configs/ (human TOMLs
# + generated *-build.json) and state/ (watcher JSONs), so every generator,
# watcher and build finds its inputs at the paths it already references
# (commit_data_branch.sh / push_data_configs.sh are the writer sides).
#
# Run right after actions/checkout in any job that reads them:
#   ci.yml (watcher), build.yml (builds). Local dev: run after cloning, and
# whenever you want fresh state/configs.
#
# WARNING: this OVERWRITES local files under configs/ — publish hand-edited
# TOMLs first with: bash .github/scripts/push_data_configs.sh "<message>"
#
# Hard-fail by design: a missing `data` branch must never silently fall back
# to stale or empty state (same stance as merge_archive_branch.sh).

if ! git fetch -q origin data; then
	echo "FATAL: 'data' branch not found on origin — restore it (see temp/seed_data_branch.sh)." >&2
	exit 1
fi

git checkout -q FETCH_HEAD -- configs/ state/
# Worktree-only: drop the staging entries the checkout added (the paths are
# gitignored on main; leaving them in the index dirties `git status`).
git reset -q -- $(git ls-tree --name-only -r FETCH_HEAD configs/ state/)
echo "Materialized data@$(git rev-parse --short FETCH_HEAD):"
git ls-tree --name-only -r FETCH_HEAD configs/ state/ | sed 's/^/  /'
