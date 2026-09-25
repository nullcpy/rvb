#!/bin/bash
set -euo pipefail

# Commit the watcher-owned generated files (state/*.json: patch_sources,
# app_versions, patch_file_hashes; configs/*-build.json: the generated pool
# configs) to the `data` branch so main's history stays human-only.
#
# Plumbing-only by design: builds the commit with a temporary index and
# commit-tree, never touching the checked-out branch, the real index, or the
# dirty worktree — safe to call from ci.yml while sitting on a dirtied main
# checkout right after the generators ran.
#
# Contract:
#   - Single writer (ci.yml's `ci` concurrency group); the push-retry loop is
#     insurance, not a merge strategy: on a race, our worktree files win.
#   - fetch_data_branch.sh is the counterpart that materializes the branch
#     back into configs/ and state/ for builds and watchers.
#   - Only *.json directly under configs/ and state/ is committed — human
#     TOMLs (push_data_configs.sh territory) can never reach `data` here.

BRANCH="data"
STATE_DIRS=("configs" "state")
COMMIT_MSG="${DATA_COMMIT_MSG:-chore: update generated patch sources, app versions and configs}"

export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-github-actions[bot]}"
export GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}"
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"

# build_commit <base> — creates a commit on <base> carrying the worktree's
# generated json files; echoes the new sha, returns 1 when nothing differs.
build_commit() {
	local base=$1 d idx tree blob old changed="" commit
	idx=$(mktemp)
	GIT_INDEX_FILE=$idx git read-tree "$base"
	shopt -s nullglob
	for d in "${STATE_DIRS[@]}"; do
		for f in "$d"/*.json; do
			blob=$(git hash-object -w "$f")
			old=$(git rev-parse "$base:$f" 2> /dev/null || echo '')
			[ "$blob" = "$old" ] && continue
			GIT_INDEX_FILE=$idx git update-index --add --cacheinfo "100644,$blob,$f"
			changed=1
		done
	done
	shopt -u nullglob
	[ -n "$changed" ] || {
		rm -f "$idx"
		return 1
	}
	tree=$(GIT_INDEX_FILE=$idx git write-tree)
	rm -f "$idx"
	commit=$(git commit-tree "$tree" -p "$base" -m "$COMMIT_MSG")
	echo "$commit"
}

if ! git fetch -q origin "$BRANCH"; then
	echo "FATAL: '$BRANCH' branch not found on origin — restore it (see temp/seed_data_branch.sh) before running the watcher." >&2
	exit 1
fi

for attempt in 1 2 3; do
	base=$(git rev-parse FETCH_HEAD)
	if ! new=$(build_commit "$base"); then
		echo "No state changes to commit to $BRANCH."
		exit 0
	fi
	if git push -q origin "$new:refs/heads/$BRANCH" 2> /dev/null; then
		echo "Pushed $new to $BRANCH."
		exit 0
	fi
	echo "Push attempt $attempt failed (branch moved?); re-fetching and retrying..."
	sleep 3
	git fetch -q origin "$BRANCH"
done
echo "FATAL: could not push state to $BRANCH after 3 attempts." >&2
exit 1
