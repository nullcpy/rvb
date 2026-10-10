#!/bin/bash
set -euo pipefail

# No-change guard: decide whether this build has anything to publish at all.
#
# scripts/build.sh exits 0 with temp/unchanged/all.txt when every artifact it
# produced matched its published fingerprint (dedup enforcement, issue #165).
# The publish chain must then stop — a numbered release with no assets was the
# flaw that closed PR #171. Any other outcome, including "nothing was built
# because everything failed" (build.sh aborts before this runs), keeps
# HAS_NEW_FILES=true so no step of the normal chain can be lost silently.
#
# Reads: build/, temp/unchanged/
# Writes: HAS_NEW_FILES=true|false to $GITHUB_OUTPUT
#
# Explicit `if` blocks throughout: a `[ … ] && …` list whose last test fails
# would abort this step under set -e before the output is written.

if [ -d build ] && [ -n "$(ls -A1 build 2>/dev/null)" ]; then
	echo "New artifacts present in build/ — publishing normally."
	HAS_NEW_FILES=true
elif [ -f temp/unchanged/all.txt ]; then
	echo "Every artifact this pool built is identical to the published one — no release."
	HAS_NEW_FILES=false
else
	# Unreachable for a build.sh that completed (it aborts on an empty build/
	# without the marker), but the safe answer to an unknown state is "publish".
	echo "No build/ content and no unchanged marker — keeping the publish chain enabled."
	HAS_NEW_FILES=true
fi

echo "HAS_NEW_FILES=$HAS_NEW_FILES" >>"$GITHUB_OUTPUT"
