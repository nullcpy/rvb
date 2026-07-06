#!/bin/bash
set -euo pipefail

[ -n "${TAGS_OLD:-}" ] || TAGS_OLD='{}'
[ -n "${TAGS_NEW:-}" ] || TAGS_NEW='{}'
[ -f active_apps.json ] || echo '[]' > active_apps.json

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

if [ "${TRIGGER_STABLE:-0}" = "1" ] || [ "${TRIGGER_APP_UPDATE:-0}" = "1" ] || [ "${TRIGGER_BLOCKED:-0}" = "1" ]; then
  STABLE_CONFIGS=$(find .github/configs/patches -name "*.toml" ! -name "*dev*.toml" | sort)
  if [ -n "$STABLE_CONFIGS" ]; then
    # shellcheck disable=SC2086
    yq -o=json eval-all '. as $item ireduce ({}; . * $item)' $STABLE_CONFIGS > config.stable.json
  else
    echo "{}" > config.stable.json
  fi

  jq --slurpfile active active.stable.json --slurpfile activeApps active_apps.json '
    { "parallel-jobs": 1, "enable-module-update": true } as $force |
    ($force + . + $force) |
    with_entries(
      if .value | type == "object" then
        .key as $k |
        .value as $app |
        (($app["patches-source"] // "ReVanced/revanced-patches") | ascii_downcase | gsub("[\"'\''\\n\\r\\t]"; " ") | split(" ") | map(select(. != ""))) as $srcs |
        if (($srcs - $active[0]) != $srcs) or ($activeApps[0] | index($k)) then . else (.value.enabled = false) end
      else . end
    )
  ' config.stable.json > .github/configs/config.stable.updated.json
fi

if [ "${TRIGGER_PRERELEASE:-0}" = "1" ]; then
  DEV_CONFIGS=$(find .github/configs/patches -name "*.toml" ! -name "*stable*.toml" | sort)
  if [ -n "$DEV_CONFIGS" ]; then
    # shellcheck disable=SC2086
    yq -o=json eval-all '. as $item ireduce ({}; . * $item)' $DEV_CONFIGS > config.dev.json
  else
    echo "{}" > config.dev.json
  fi

  jq --slurpfile active active.prerelease.json --slurpfile activeApps active_apps.json '
    { "parallel-jobs": 1, "patches-version": "dev", "enable-module-update": false } as $force |
    ($force + . + $force) |
    with_entries(
      if .value | type == "object" then
        .key as $k |
        .value as $app |
        (($app["patches-source"] // "ReVanced/revanced-patches") | ascii_downcase | gsub("[\"'\''\\n\\r\\t]"; " ") | split(" ") | map(select(. != ""))) as $srcs |
        if (($srcs - $active[0]) != $srcs) or ($activeApps[0] | index($k)) then . else (.value.enabled = false) end
      else . end
    )
  ' config.dev.json > .github/configs/config.dev.updated.json
fi
