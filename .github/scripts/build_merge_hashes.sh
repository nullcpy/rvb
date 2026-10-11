#!/bin/bash
set -euo pipefail

# Merge the fingerprints this build computed into state/build_content_hashes.json.
#
# The engine's check_duplicate_build (scripts/utils.sh) writes one
# "<channel>\t<key>\t<md5>" line per freshly patched APK into
# temp/hashes/append.*.tsv — for every eligible build in BOTH dedup modes, so
# the measurement phase accumulates comparison data without ever mutating the
# local reference. That record happens at patch time, BEFORE the artifact has
# necessarily reached build/: a later stage of the same app (module packing,
# stock merge) can still fail and return, leaving a fingerprint whose file was
# never published. The hazard is structural (run 1390 had post-patch failures
# while its stems were already recorded by earlier good builds — no wrong
# entry resulted, but only because those keys had shipped before).
#
# So this step — the only writer of the state file — filters every line by
# PUBLISHED PRESENCE: the recorded stem is merged only when the artifact it
# stands for (stem.apk or the stem's -module-v- zip spelling) is in build/ at
# upload time, or is already an entry in the state file (a fingerprint from an
# earlier successful run stays valid while cleanup has not pruned its file).
# Combined with the workflow gate that runs this step only after the upload
# chain succeeded, a hash becomes authoritative precisely when its artifact is
# live; nothing a build lost can suppress a future one.
#
# The state file itself is pushed to `data` by the commit_data_branch.sh step
# that follows (it already commits every state/*.json — no new machinery).
#
# Env: GITHUB_REPOSITORY (presence gates CI-only behavior); GITHUB_OUTPUT for
#      the STATE_UPDATED flag the workflow's commit-data step triggers on.
# Reads: temp/hashes/append.*.tsv, build/, state/build_content_hashes.json (optional).
# Writes: state/build_content_hashes.json

[ -n "${GITHUB_REPOSITORY:-}" ] || { echo "Not running on GitHub; skipping hash merge."; exit 0; }

echo "STATE_UPDATED=false" >>"${GITHUB_OUTPUT:?GITHUB_OUTPUT not set}"

STATE_FILE="state/build_content_hashes.json"

lines=""
nfiles=0
for f in temp/hashes/append.*.tsv; do
	[ -f "$f" ] || continue
	lines+=$(cat "$f")
	lines+=$'\n'
	nfiles=$((nfiles + 1))
done

if [ -z "${lines//[[:space:]]/}" ]; then
	echo "No fingerprint lines from this run; state file untouched."
	exit 0
fi

[ -f "$STATE_FILE" ] || { mkdir -p "$(dirname "$STATE_FILE")"; echo '{}' >"$STATE_FILE"; }

# What this run actually shipped, as a JSON array (names as uploaded). The
# engine lowercases the stem when it builds filenames; the recorded stem and
# the filename are compared case-insensitively on both sides to be safe.
published_json='[]'
if [ -d build ]; then
	published_json=$(find build -maxdepth 1 -type f -printf '%f\n' | jq -Rn '[inputs]')
fi

# The lines are TAB-separated channel/key/hash triples. A generated key can
# never contain a tab or quote (it is a filename stem), so no shell value ever
# reaches the program text. The channel is whitelisted exactly like the state
# schema: a line for any other namespace is dropped, not trusted. A line whose
# stem has neither a published file this run nor an existing state entry is
# dropped with a note — this is the failed-build-after-patch case, and the
# whole reason the merge is per-line and not a blind union.
updated=$(printf '%s\n' "$lines" | jq -Rs --argjson pub "$published_json" --slurpfile old "$STATE_FILE" '
  def candidates:
    . as $s
    | [ ($s | ascii_downcase) + ".apk",
        (($s | sub("^(?<pre>.+?)-v(?<d>[0-9])"; .pre + "-module-v" + .d) | ascii_downcase) + ".zip") ];
  ($pub | map(ascii_downcase) | INDEX(.)) as $shipped
  | ($old[0] // {}) as $old_state
  | (split("\n") | map(select(length > 0)) | map(split("\t"))
      | map(select((length == 3) and (.[0] == "stable" or .[0] == "beta")))
      | reduce .[] as $p ({};
          if (any($p[1] | candidates[]; . as $f | ($shipped | has($f))))
             or (($old_state[$p[0]] // {}) | has($p[1]))
          then .[$p[0]] = ((.[$p[0]] // {}) + { ($p[1]): $p[2] })
          else . end)) as $new
  | ($old_state * $new)
'
)

printf '%s\n' "$updated" >"$STATE_FILE"
line_count=$(printf '%s\n' "$lines" | grep -c . || true)
merged_count=$(jq '[.[] | length] | add // 0' "$STATE_FILE")
echo "Merged $line_count fingerprint line(s) from $nfiles file(s) into $STATE_FILE (state now holds $merged_count key(s); unpublished-and-unknown stems were dropped)."
jq -c 'to_entries | map("\(.key): \(.value | length) key(s))")' "$STATE_FILE"
echo "STATE_UPDATED=true" >>"$GITHUB_OUTPUT"
