#!/bin/bash
set -euo pipefail
BASE_CONFIG="config.toml"
BASE_CONFIG_STABLE=".github/configs/config.stable.toml"
BASE_CONFIG_DEV=".github/configs/config.dev.toml"

[ -n "${TAGS_OLD:-}" ] || TAGS_OLD='{}'
[ -n "${TAGS_NEW:-}" ] || TAGS_NEW='{}'

jq -rn --argjson new "$TAGS_NEW" --argjson old "$TAGS_OLD" '
  [ $new | to_entries[] | . as $e
      | ($old[$e.key] // {}) as $o
      | select($e.value.stable != "" and $e.value.stable != ($o.stable // ""))
      | select($e.value.enabled != false and $e.value.enabledStable != false)
      | $e.value.repo | ascii_downcase
  ]
' > active.stable.json

jq -rn --argjson new "$TAGS_NEW" --argjson old "$TAGS_OLD" '
  [ $new | to_entries[] | . as $e
      | ($old[$e.key] // {}) as $o
      | select($e.value.prerelease != "" and $e.value.prerelease != ($o.prerelease // ""))
      | select($e.value.enabled != false and $e.value.enabledDev != false)
      | $e.value.repo | ascii_downcase
  ]
' > active.prerelease.json

yq -o=json '.' "$BASE_CONFIG" > base.json

if [ "${TRIGGER_STABLE:-0}" = "1" ]; then
  if [ -f "$BASE_CONFIG_STABLE" ]; then
    yq -o=json '.' "$BASE_CONFIG_STABLE" > stable_overrides.json
    jq -s '.[0] * .[1]' base.json stable_overrides.json > config.stable.json
  else
    cp base.json config.stable.json
  fi

  jq --slurpfile active active.stable.json '
    { "parallel-jobs": 1, "enable-module-update": true } as $force |
    ($force + . + $force) |
    map_values(
      if type == "object" then
        . as $app |
        (($app["patches-source"] // "ReVanced/revanced-patches") | ascii_downcase | gsub("[\"\\u0027\\n\\r\\t]"; " ") | split(" ") | map(select(. != ""))) as $srcs |
        if (($srcs - $active[0]) != $srcs) then $app else ($app | .enabled = false) end
      else . end
    )
  ' config.stable.json > .github/configs/config.stable.updated.json
fi

if [ "${TRIGGER_PRERELEASE:-0}" = "1" ]; then
  if [ -f "$BASE_CONFIG_DEV" ]; then
    yq -o=json '.' "$BASE_CONFIG_DEV" > dev_overrides.json
    jq -s '.[0] * .[1]' base.json dev_overrides.json > config.dev.json
  else
    cp base.json config.dev.json
  fi

  jq --slurpfile active active.prerelease.json '
    { "parallel-jobs": 1, "patches-version": "dev", "enable-module-update": false } as $force |
    ($force + . + $force) |
    map_values(
      if type == "object" then
        . as $app |
        (($app["patches-source"] // "ReVanced/revanced-patches") | ascii_downcase | gsub("[\"\\u0027\\n\\r\\t]"; " ") | split(" ") | map(select(. != ""))) as $srcs |
        if (($srcs - $active[0]) != $srcs) then $app else ($app | .enabled = false) end
      else . end
    )
  ' config.dev.json > .github/configs/config.dev.updated.json
fi
