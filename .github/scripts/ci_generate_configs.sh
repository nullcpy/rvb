#!/bin/bash
set -euo pipefail

# Convert utils.sh to Unix line endings if needed
dos2unix scripts/utils.sh 2>/dev/null || true
source scripts/utils.sh

[ -f tags_new.json ] && TAGS_NEW=$(cat tags_new.json) || TAGS_NEW='{}'
[ -f active_apps.json ] || echo '[]' > active_apps.json
[ -f active_patch_apps.stable.json ] || echo '[]' > active_patch_apps.stable.json
[ -f active_patch_apps.beta.json ] || echo '[]' > active_patch_apps.beta.json

# The changed-source diff is no longer re-derived here. changed_sources.json is
# written once by Sync Patch Sources (derive_source_changes.py), so this step,
# ci_check_app_patches.py and the TRIGGER_* flags can never disagree about which
# sources moved. These are projections, not rule copies: beta keeps its
# historical "only when newer than stable" gate, now carried as a record field.
if [ ! -f changed_sources.json ]; then
  echo "::error::changed_sources.json missing - Sync Patch Sources must run first."
  exit 1
fi

jq -c '[ .[] | select(.channel == "stable") | .repo ] | unique' changed_sources.json > active.stable.json
jq -c '[ .[] | select(.channel == "beta" and .newer_than_base) | .repo ] | unique' changed_sources.json > active.beta.json

# Compile base configs if missing
if [ ! -f config.stable.json ] || [ ! -f config.beta.json ]; then
  python3 .github/scripts/compile_patch_configs.py
fi

if [ "${TRIGGER_STABLE:-0}" = "1" ] || [ "${TRIGGER_APP_UPDATE:-0}" = "1" ] || [ "${TRIGGER_BLOCKED:-0}" = "1" ]; then
  jq --argjson tags "$TAGS_NEW" --slurpfile active active.stable.json --slurpfile activeApps active_apps.json --slurpfile activePatchApps active_patch_apps.stable.json '
    { "patches-version": "stable" } as $force |
    ($force + . + $force) |
    with_entries(
      if .value | type == "object" then
        .key as $k |
        .value as $app |
        (($app["patches-source"] // "morpheapp/morphe-patches") | ascii_downcase | gsub("[\"'\''\\n\\r\\t]"; " ") | split(" ") | map(select(. != ""))) as $srcs |
        # Hard-pin each app to the concrete stable tag from the watcher snapshot, so
        # the build resolves an exact release instead of re-resolving "stable" live
        # per app (which let a mid-run release switch cause dev.14/dev.15 drift).
        # One tag per source, index-aligned with the patches-source list; skip the
        # pin (inherit the floating channel) if any source has no recorded tag.
        # A manual TOML pin (patches-pin-manual, set by compile_patch_configs.py)
        # is authoritative: the app stays enabled but its version is left alone.
        ($srcs | map(. as $src | ($tags | to_entries | map(select(((.value.repo // .key) | ascii_downcase) == $src)) | (.[0].value.stable // "")))) as $ptags |
        ((($ptags | length) > 0) and ($ptags | all(. != ""))) as $pin_ok |
        (if ($ptags | length) == 1 then $ptags[0] else ("'\''" + ($ptags | join("'\'' '\''")) + "'\''") end) as $pin |
        if ((($srcs - $active[0]) != $srcs) and ($activePatchApps[0] | index($k))) or ($activeApps[0] | index($k)) then
          (if ($pin_ok and ($app["patches-pin-manual"] | if . == true then false else true end)) then (.value["patches-version"] = $pin) else . end)
        else
          (.value.enabled = false)
        end
      else . end
    )
  ' config.stable.json > configs/stable_build.json
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

        # Hard-pin each app to the concrete beta tag from the watcher snapshot (one
        # per source, index-aligned with patches-source); skip the pin and inherit
        # the floating "beta" channel if any source has no recorded beta tag.
        # A manual TOML pin (patches-pin-manual) is authoritative: keep its version.
        ($srcs | map(. as $src | ($tags | to_entries | map(select(((.value.repo // .key) | ascii_downcase) == $src)) | (.[0].value.beta // "")))) as $ptags |
        ((($ptags | length) > 0) and ($ptags | all(. != ""))) as $pin_ok |
        (if ($ptags | length) == 1 then $ptags[0] else ("'\''" + ($ptags | join("'\'' '\''")) + "'\''") end) as $pin |
        if ((($srcs - $active[0]) != $srcs) and ($activePatchApps[0] | index($k))) or (($activeApps[0] | index($k)) and $has_valid_beta) then
          (if ($pin_ok and ($app["patches-pin-manual"] | if . == true then false else true end)) then (.value["patches-version"] = $pin) else . end)
        else
          (.value.enabled = false)
        end
      else . end
    )
  ' config.beta.json > configs/beta_build.json
fi
