#!/bin/bash
set -euo pipefail

# Convert utils.sh to Unix line endings if needed
dos2unix utils.sh 2>/dev/null || true
source utils.sh

[ -f tags_old.json ] && TAGS_OLD=$(cat tags_old.json) || TAGS_OLD='{}'
[ -f tags_new.json ] && TAGS_NEW=$(cat tags_new.json) || TAGS_NEW='{}'
[ -f active_apps.json ] || echo '[]' > active_apps.json
[ -f active_patch_apps.stable.json ] || echo '[]' > active_patch_apps.stable.json
[ -f active_patch_apps.beta.json ] || echo '[]' > active_patch_apps.beta.json

jq -rn --argjson new "$TAGS_NEW" --argjson old "$TAGS_OLD" '
  [ $new | to_entries[] | . as $e
      | ($old[$e.key] // {}) as $o
      | select($e.value.stable != "" and $e.value.stable != ($o.stable // ""))
      | select($e.value.blocked != true)
      | ($e.value.repo // $e.key // "") as $r
      | select($r != "")
      | $r | ascii_downcase
  ]
' > active.stable.json

jq -rn --argjson new "$TAGS_NEW" --argjson old "$TAGS_OLD" '
  [ $new | to_entries[] | . as $e
      | ($old[$e.key] // {}) as $o
      | ($e.value.beta // "") as $new_beta
      | ($o.beta // "") as $old_beta
      | ($e.value.beta_date // "") as $b_date
      | ($e.value.stable_date // "") as $s_date
      | select($new_beta != "" and $new_beta != $old_beta)
      | select($e.value.blocked != true)
      | select($b_date > $s_date)
      | ($e.value.repo // $e.key // "") as $r
      | select($r != "")
      | $r | ascii_downcase
  ]
' > active.beta.json

# Compile base configs if missing
if [ ! -f config.stable.json ] || [ ! -f config.beta.json ]; then
  python3 .github/scripts/compile_patch_configs.py
fi

if [ "${TRIGGER_STABLE:-0}" = "1" ] || [ "${TRIGGER_APP_UPDATE:-0}" = "1" ] || [ "${TRIGGER_BLOCKED:-0}" = "1" ]; then
  jq --slurpfile active active.stable.json --slurpfile activeApps active_apps.json --slurpfile activePatchApps active_patch_apps.stable.json '
    { "patches-version": "stable" } as $force |
    ($force + . + $force) |
    with_entries(
      if .value | type == "object" then
        .key as $k |
        .value as $app |
        (($app["patches-source"] // "morpheapp/morphe-patches") | ascii_downcase | gsub("[\"'\''\\n\\r\\t]"; " ") | split(" ") | map(select(. != ""))) as $srcs |
        if ((($srcs - $active[0]) != $srcs) and ($activePatchApps[0] | index($k))) or ($activeApps[0] | index($k)) then . else (.value.enabled = false) end
      else . end
    )
  ' config.stable.json > .github/configs/config.stable.updated.json
fi

if [ "${TRIGGER_BETA:-0}" = "1" ] || [ "${TRIGGER_APP_UPDATE:-0}" = "1" ] || [ "${TRIGGER_BLOCKED:-0}" = "1" ]; then
  jq --slurpfile active active.beta.json --slurpfile activeApps active_apps.json --slurpfile activePatchApps active_patch_apps.beta.json --argjson tags "$TAGS_NEW" '
    { "patches-version": "beta" } as $force |
    ($force + . + $force) |
    with_entries(
      if .value | type == "object" then
        .key as $k |
        .value as $app |
        (($app["patches-source"] // "morpheapp/morphe-patches") | ascii_downcase | gsub("[\"'\''\\n\\r\\t]"; " ") | split(" ") | map(select(. != ""))) as $srcs |
        
        # Check if the app has any source where beta_date > stable_date
        (
          $srcs | map(
            . as $src |
            ($tags | to_entries | map(select((.value.repo | ascii_downcase) == $src)) | .[0].value) as $t |
            if $t == null then false
            else (($t.beta_date // "") > ($t.stable_date // "")) end
          ) | any
        ) as $has_valid_beta |

        if ((($srcs - $active[0]) != $srcs) and ($activePatchApps[0] | index($k))) or (($activeApps[0] | index($k)) and $has_valid_beta) then . else (.value.enabled = false) end
      else . end
    )
  ' config.beta.json > .github/configs/config.beta.updated.json
fi
