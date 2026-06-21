#!/bin/bash
set -euo pipefail
PATCH_FILE=".github/configs/patch_sources.json"

OLD_JSON=$(cat "$PATCH_FILE")
NEW_JSON="$LATEST_TAGS"

if [ -z "$NEW_JSON" ]; then
  NEW_JSON="{}"
fi

TRIGGER_STABLE=$(jq -n --argjson old "$OLD_JSON" --argjson new "$NEW_JSON" '
  [ $new | to_entries[] | . as $e
    | ($old[$e.key] // {}) as $o
    | select($e.value.stable != "" and $e.value.stable != ($o.stable // ""))
  ] | if length > 0 then 1 else 0 end
')

TRIGGER_PRERELEASE=$(jq -n --argjson old "$OLD_JSON" --argjson new "$NEW_JSON" '
  [ $new | to_entries[] | . as $e
    | ($old[$e.key] // {}) as $o
    | select($e.value.prerelease != "" and $e.value.prerelease != ($o.prerelease // ""))
  ] | if length > 0 then 1 else 0 end
')

TRIGGER_BLOCKED=$(jq -n --argjson old "$OLD_JSON" --argjson new "$NEW_JSON" '
  [ $new | to_entries[] | . as $e
    | ($old[$e.key] // {}) as $o
    | select($e.value.blocked == true and $o.blocked != true)
  ] | if length > 0 then 1 else 0 end
')

echo "$NEW_JSON" > "$PATCH_FILE"

echo "TRIGGER_STABLE=$TRIGGER_STABLE" >> "$GITHUB_OUTPUT"
echo "TRIGGER_PRERELEASE=$TRIGGER_PRERELEASE" >> "$GITHUB_OUTPUT"
echo "TRIGGER_BLOCKED=$TRIGGER_BLOCKED" >> "$GITHUB_OUTPUT"

DELIM1="$(openssl rand -hex 8)"
echo "tags_old<<${DELIM1}" >> "$GITHUB_OUTPUT"
echo "$OLD_JSON" >> "$GITHUB_OUTPUT"
echo "${DELIM1}" >> "$GITHUB_OUTPUT"

DELIM2="$(openssl rand -hex 8)"
echo "tags_new<<${DELIM2}" >> "$GITHUB_OUTPUT"
echo "$NEW_JSON" >> "$GITHUB_OUTPUT"
echo "${DELIM2}" >> "$GITHUB_OUTPUT"
