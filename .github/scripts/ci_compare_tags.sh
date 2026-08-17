#!/bin/bash
set -euo pipefail
PATCH_FILE=".github/configs/patch_sources.json"

OLD_JSON=$(cat "$PATCH_FILE")
NEW_JSON=$(cat "tags_new.json")

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

echo "$OLD_JSON" > tags_old.json
echo "$NEW_JSON" > "$PATCH_FILE"

if [ "$TRIGGER_STABLE" -eq 1 ]; then
  jq -r --argjson old "$OLD_JSON" --argjson new "$NEW_JSON" '
    $new | to_entries[] | . as $e
    | ($old[$e.key] // {}) as $o
    | select($e.value.stable != "" and $e.value.stable != ($o.stable // ""))
    | "::notice::Stable update detected for \($e.value.repo // $e.key): \($o.stable // "unknown") -> \($e.value.stable)"
  ' <<<"{}"
fi

if [ "$TRIGGER_PRERELEASE" -eq 1 ]; then
  jq -r --argjson old "$OLD_JSON" --argjson new "$NEW_JSON" '
    $new | to_entries[] | . as $e
    | ($old[$e.key] // {}) as $o
    | select($e.value.prerelease != "" and $e.value.prerelease != ($o.prerelease // ""))
    | "::notice::Pre-release update detected for \($e.value.repo // $e.key): \($o.prerelease // "unknown") -> \($e.value.prerelease)"
  ' <<<"{}"
fi

if [ "$TRIGGER_BLOCKED" -eq 1 ]; then
  jq -r --argjson old "$OLD_JSON" --argjson new "$NEW_JSON" '
    $new | to_entries[] | . as $e
    | ($old[$e.key] // {}) as $o
    | select($e.value.blocked == true and $o.blocked != true)
    | "::warning::Repository access blocked for \($e.value.repo // $e.key)!"
  ' <<<"{}"
fi

echo "TRIGGER_STABLE=$TRIGGER_STABLE" >> "$GITHUB_OUTPUT"
echo "TRIGGER_PRERELEASE=$TRIGGER_PRERELEASE" >> "$GITHUB_OUTPUT"
echo "TRIGGER_BLOCKED=$TRIGGER_BLOCKED" >> "$GITHUB_OUTPUT"
