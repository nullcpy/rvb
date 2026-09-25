#!/bin/bash
set -euo pipefail

# Human-side writer for the `data` branch: publishes locally edited TOML
# configs (configs/*.toml + configs/patches/*.toml) as a normal commit on
# `data`. This is the ONLY sanctioned way to change configs once main stops
# tracking them — watcher JSONs are excluded by design (*.toml glob), so a
# stale local JSON can never be pushed over the watcher's state.
#
# Usage (from a main checkout, after editing configs/**.toml):
#   bash .github/scripts/push_data_configs.sh "feat(configs): add <app> patches"
#   # then pull the canonical copies back (optional):
#   bash .github/scripts/fetch_data_branch.sh
#
# Plumbing-only, mirroring commit_data_branch.sh: temporary index built on
# origin/data's tip, commit-tree, direct ref push — the main worktree (dirty
# or not) is never touched. Authored with YOUR git identity, not the bot's.
# Single maintainer assumed: on a push race, your TOML versions win.

BRANCH="data"
MSG="${1:-}"
if [ -z "$MSG" ]; then
	echo "usage: push_data_configs.sh \"<commit message>\"" >&2
	exit 2
fi

build_commit() {
	local base=$1 f idx dir blob old changed="" commit
	idx=$(mktemp)
	GIT_INDEX_FILE=$idx git read-tree "$base"
	shopt -s nullglob
	for dir in configs configs/patches; do
		for f in "$dir"/*.toml; do
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
	commit=$(git commit-tree "$tree" -p "$base" -m "$MSG")
	echo "$commit"
}

if ! git fetch -q origin "$BRANCH"; then
	echo "FATAL: '$BRANCH' branch not found on origin — restore it before editing configs." >&2
	exit 1
fi

for attempt in 1 2 3; do
	base=$(git rev-parse FETCH_HEAD)
	if ! new=$(build_commit "$base"); then
		echo "No config changes to push ($BRANCH already matches your local TOMLs)."
		exit 0
	fi
	if git push -q origin "$new:refs/heads/$BRANCH" 2> /dev/null; then
		echo "Pushed $new to $BRANCH: $MSG"
		exit 0
	fi
	echo "Push attempt $attempt failed (watcher commit raced?); re-fetching..."
	sleep 3
	git fetch -q origin "$BRANCH"
done
echo "FATAL: could not push configs to $BRANCH after 3 attempts." >&2
exit 1
