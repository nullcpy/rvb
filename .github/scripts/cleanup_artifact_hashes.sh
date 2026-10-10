#!/bin/bash
set -euo pipefail

# Prune state/build_content_hashes.json entries whose artifact no longer lives
# on ANY release of this repository.
#
# Why this is correctness, not tidying: a duplicate verdict suppresses
# publishing on the strength of the state entry. If cleanup's asset pruning
# later deletes that very file (keep-2-newest-per-app+arch, archive exclusions,
# or a whole app being dropped), a pinned rebuild of the same version would be
# "skipped" as identical to a file nobody can download — the suppression would
# silently eat the release. The entry may only suppress a build while its file
# is actually published somewhere.
#
# Ordering: run AFTER cleanup-archive-assets.py and the release deleter, so
# entries whose assets were legitimately pruned this pass are removed here in
# the same run (an entry that still has a live asset is never touched).
#
# A stem counts as live through either published spelling it can produce:
#   <stem>.apk                     (apk / both builds)
#   <pre>-module-v<rest>-<arch>.zip (module build; stem's first "-v"+digit
#                                   becomes "-module-v", case-insensitive)
#
# The fetch is fail-loud on a broken paginated call (empty output with
# --paginate would otherwise read as "everything is gone" and wipe all
# entries). A repo with genuinely no releases cannot hold live assets, so
# clearing then converges at the cost of one rebuild per app.
#
# Env: GITHUB_TOKEN (gh default), GH_OUTPUT_FILE optional
#      (default "temp/gh_outputs/cleanup_hashes.env", written for the
#      follow-up commit step), GITHUB_REPOSITORY required.
# Writes: state/build_content_hashes.json (pruned in place when changed)

REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY not set}"
STATE_FILE="state/build_content_hashes.json"
ASSETS="temp/gh_outputs/release-assets.txt"
OUT_ENV="${GH_OUTPUT_FILE:-temp/gh_outputs/cleanup_hashes.env}"

if [ ! -f "$STATE_FILE" ]; then
	echo "No $STATE_FILE yet; nothing to prune."
	mkdir -p "$(dirname "$OUT_ENV")"
	echo "STATE_PRUNED=false" >"$OUT_ENV"
	exit 0
fi
if ! jq -e 'type == "object"' "$STATE_FILE" >/dev/null 2>&1; then
	echo "::error::$STATE_FILE is not a JSON object — refusing to prune a malformed state file" >&2
	exit 1
fi

mkdir -p "$(dirname "$ASSETS")" "$(dirname "$OUT_ENV")"
if ! gh api --paginate "repos/$REPO/releases" -q '.[].assets[].name' >"$ASSETS"; then
	echo "::error::Could not list release assets — refusing to prune (a partial list could delete live guards)" >&2
	exit 1
fi
echo "Comparing against $(grep -c . "$ASSETS" || true) live asset name(s)."

jq --rawfile rel "$ASSETS" '
  def candidate_files:
    . as $s
    | [ ($s | ascii_downcase) + ".apk",
        (($s | sub("^(?<pre>.+?)-v(?<d>[0-9])"; .pre + "-module-v" + .d) | ascii_downcase)
          + ".zip") ];
  ([$rel | splits("\n") | select(length > 0) | ascii_downcase] | INDEX(.)) as $live
  | with_entries(.value |= with_entries(
      select(any(.key | candidate_files[]; . as $f | ($live | has($f))))))
  | with_entries(select(.value | length > 0))
' "$STATE_FILE" >"${STATE_FILE}.tmp"

before=$(jq '[.[] | length] | add // 0' "$STATE_FILE")
after=$(jq '[.[] | length] | add // 0' "$STATE_FILE.tmp")
if [ "$before" != "$after" ]; then
	mv -f "${STATE_FILE}.tmp" "$STATE_FILE"
	echo "Pruned $((before - after)) stale fingerprint(s) from $STATE_FILE ($before -> $after)."
	echo "STATE_PRUNED=true" >"$OUT_ENV"
else
	rm -f "${STATE_FILE}.tmp"
	echo "All $after fingerprints have live release assets; state unchanged."
	echo "STATE_PRUNED=false" >"$OUT_ENV"
fi
