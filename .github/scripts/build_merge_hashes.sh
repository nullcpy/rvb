#!/bin/bash
set -euo pipefail

# Merge the fingerprints this build computed into state/build_content_hashes.json.
#
# The engine's check_duplicate_build (scripts/utils.sh) writes one
# "<channel>\t<key>\t<md5>" line per freshly patched APK into
# temp/hashes/append.*.tsv — for every eligible build in BOTH dedup modes, so
# the measurement phase accumulates comparison data without ever mutating the
# local reference. This step is the only writer that folds those lines into
# the state file, and build.yml runs it only after the upload chain succeeded:
# a hash becomes authoritative precisely when its artifact is published. A run
# that built but failed to upload commits nothing, so the next run republishes
# rather than wrongly skipping.
#
# The state file itself is pushed to `data` by the commit_data_branch.sh step
# that follows (it already commits every state/*.json — no new machinery).
#
# Env: GITHUB_REPOSITORY (presence gates CI-only behavior); GITHUB_OUTPUT for
#      the STATE_UPDATED flag the workflow's commit-data step triggers on.
# Reads: temp/hashes/append.*.tsv, state/build_content_hashes.json (optional).
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

# The lines are TAB-separated channel/key/hash triples. A generated key can
# never contain a tab or quote (it is a filename stem), and jq's own TSV
# slurp parses the fields — no shell interpolation of the values happens, so
# a surprise byte lands in a jq type error (loud exit) rather than anywhere
# executable. The channel is whitelisted exactly like the state schema: a
# line for any other namespace is dropped, not trusted.
updated=$(printf '%s\n' "$lines" | jq -Rs --slurpfile old "$STATE_FILE" '
  (split("\n") | map(select(length > 0)) | map(split("\t"))
    | map(select((length == 3) and (.[0] == "stable" or .[0] == "beta")))
    | reduce .[] as $p ({};
        .[$p[0]] = ((.[$p[0]] // {}) + { ($p[1]): $p[2] }))) as $new
  | ($old[0] // {}) * $new
'
)

printf '%s\n' "$updated" >"$STATE_FILE"
line_count=$(printf '%s\n' "$lines" | grep -c . || true)
echo "Merged $line_count fingerprint line(s) from $nfiles file(s) into $STATE_FILE:"
jq -c 'to_entries | map("\(.key): \(.value | length) key(s))")' "$STATE_FILE"
echo "STATE_UPDATED=true" >>"$GITHUB_OUTPUT"
