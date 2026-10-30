#!/bin/bash
set -euo pipefail

# Publish this build's manifest to the permanent archive repo's `website` branch so
# a download site can be generated from nullcpy/archive without touching rvb's own
# website branch. The mirror is numbered-only — it has no rolling stable/beta, so
# there is no cumulative archive/<channel>.json and no live-existence filter here,
# only the immutable per-build manifests/<tag>.json. The manifest carries no download
# URLs (originBuild names the build tag), so the exact same bytes rvb uses are valid
# in the archive repo; nothing is re-keyed.
#
# Fail-soft on purpose (repo rule 9): a metadata push must never turn a good build
# red — the next build converges. Gated upstream on the archive mirror having landed.
#
# Env: ARCHIVE_REPO (owner/name), BUILD_TAG (this release's tag), GH_TOKEN (PAT with
#      contents:write on ARCHIVE_REPO). Reads: temp/manifest/build.json.
# gh performs the cross-repo write because GITHUB_TOKEN cannot reach another repo.
# Output: appends PUBLISHED=true to $GITHUB_OUTPUT only when the blob actually
#      landed, so a follower (the archive page rebuild) can gate on real success
#      rather than on this script exiting 0, which it also does when it gives up.

REPO="${ARCHIVE_REPO:-}"
TAG="${BUILD_TAG:-}"
MANIFEST="temp/manifest/build.json"
BRANCH="website"
PATH_JSON="manifests/${TAG}.json"

skip() { echo "${1:-}"; exit 0; }
trap 'echo "::warning::archive manifest push failed (next build converges)"; exit 0' ERR

if [ -z "$REPO" ] || [ -z "$TAG" ]; then
	skip "ARCHIVE_REPO or BUILD_TAG not set — skipping archive manifest push."
fi
if [ ! -f "$MANIFEST" ]; then
	skip "No $MANIFEST present — skipping archive manifest push."
fi
if [ -z "${GH_TOKEN:-}" ]; then
	skip "GH_TOKEN not set — skipping archive manifest push."
fi

# 1. Ensure the website branch exists. Only when it is absent do we resolve the
#    default branch head and create it, so a steady-state run costs one API call.
if ! gh api "repos/$REPO/branches/$BRANCH" >/dev/null 2>&1; then
	DEFAULT=$(gh api "repos/$REPO" | jq -r '.default_branch')
	SHA=$(gh api "repos/$REPO/git/ref/heads/$DEFAULT" | jq -r '.object.sha')
	gh api -X POST "repos/$REPO/git/refs" -f "ref=refs/heads/$BRANCH" -f "sha=$SHA" >/dev/null
	echo "Created $BRANCH branch on $REPO from $DEFAULT."
fi

# 2. Read the existing blob sha (404 -> create). Under pipefail a missing file makes
#    this pipeline fail, so the || pins an empty value rather than tripping ERR.
OLD_SHA=$(gh api "repos/$REPO/contents/${PATH_JSON}?ref=${BRANCH}" 2>/dev/null | jq -r '.sha // ""') || OLD_SHA=""

# 3. Build the request body in a file and hand it to gh as a body, never as argv.
#    Linux caps ONE argument at MAX_ARG_STRLEN (128 KiB); a full-pool rebuild's
#    manifest is larger than that once base64-encoded (260368: 104 KB -> 139 KB),
#    and `-f content=<b64>` then dies with "Argument list too long" before gh even
#    starts — the push silently never landed for the builds that matter most.
if [ -n "$OLD_SHA" ]; then
	MSG="chore: update $BRANCH manifest for build $TAG [skip ci]"
else
	MSG="chore: publish $BRANCH manifest for build $TAG [skip ci]"
fi

REQ=$(mktemp)
trap 'rm -f "$REQ"' EXIT
base64 "$MANIFEST" | tr -d '\n' | jq -Rs \
	--arg message "$MSG" --arg branch "$BRANCH" --arg sha "$OLD_SHA" \
	'{content: ., message: $message, branch: $branch}
	 + (if $sha == "" then {} else {sha: $sha} end)' > "$REQ"

gh api -X PUT "repos/$REPO/contents/$PATH_JSON" --input "$REQ" >/dev/null

if [ -n "$OLD_SHA" ]; then
	echo "Updated $PATH_JSON on $REPO#$BRANCH."
else
	echo "Published $PATH_JSON on $REPO#$BRANCH."
fi

# Only now, after the PUT returned, is the manifest real. The page rebuild gates on
# this, so a run whose push was refused must not ask for a rebuild of a manifest the
# archive repo never received.
if [ -n "${GITHUB_OUTPUT:-}" ]; then
	printf 'PUBLISHED=true\n' >>"$GITHUB_OUTPUT"
fi
