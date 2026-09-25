#!/bin/bash
set -euo pipefail

# Materialize the machine-owned state from the `data` branch into
# configs/ so generators, watchers and builds find the JSONs at the
# paths they already reference (commit_data_branch.sh is the writer side).
#
# Run right after actions/checkout in any job that reads:
#   ci.yml (watcher), build.yml (builds). Local dev: run it manually once per
# clone/update if you build from the generated configs.
#
# Hard-fail by design: a missing `data` branch must never silently fall back
# to stale or empty state (same stance as merge_archive_branch.sh).

if ! git fetch -q origin data; then
	echo "FATAL: 'data' branch not found on origin — restore it (see temp/seed_data_branch.sh)." >&2
	exit 1
fi

git checkout -q FETCH_HEAD -- configs/
# Worktree-only: drop the staging checkout added (files are gitignored on main;
# leaving them in the index dirties `git status` for every later step).
git reset -q -- $(git ls-tree --name-only -r FETCH_HEAD configs/)
echo "Materialized state from data@$(git rev-parse --short FETCH_HEAD):"
git ls-tree --name-only -r FETCH_HEAD configs/ | sed 's/^/  /'
