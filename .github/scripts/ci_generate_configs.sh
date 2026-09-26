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

# One program for both pools. The stable and beta generators used to be separate
# ~25-line jq copies; they differed in exactly three things, all expressed via
# $channel below, and any rule change had to be applied twice in lockstep.
#
#   $channel   "stable"/"beta": the inherited default written by $force, and
#              which tag field of the watcher snapshot supplies the pin.
#   $active / $activePatchApps / the config and output paths: per pool.
#   app_update_ok: an app-version bump only pulls an app into the BETA pool when
#              one of its sources really has beta_date > stable_date, because
#              otherwise the stable pool already covers that app. The stable pool
#              has no such condition, so it is vacuously satisfied there.
#
# Quoted heredoc: no shell expansion, so jq's single-quoted strings stay ordinary
# single quotes instead of the '\'' maze the copies used.
read -r -d '' POOL_PROGRAM <<'JQ' || true
  { "patches-version": $channel } as $force |
  ($force + . + $force) |
  with_entries(
    if .value | type == "object" then
      .key as $k |
      .value as $app |
      (($app["patches-source"] // "morpheapp/morphe-patches") | ascii_downcase | gsub("[\"'\n\r\t]"; " ") | split(" ") | map(select(. != ""))) as $srcs |

      # The concrete tag of each of this app's sources, index-aligned with the
      # patches-source list, read from the watcher snapshot so the build resolves
      # an exact release instead of re-resolving the floating channel per app
      # (which let a mid-run release switch cause dev.14/dev.15 drift).
      ($srcs | map(. as $src | ($tags | to_entries | map(select(((.value.repo // .key) | ascii_downcase) == $src)) | (.[0].value[$channel] // "")))) as $ptags |
      # No pin at all if any source lacks a recorded tag: inherit the channel.
      ((($ptags | length) > 0) and ($ptags | all(. != ""))) as $pin_ok |
      (if ($ptags | length) == 1 then $ptags[0] else ("'" + ($ptags | join("' '")) + "'") end) as $pin |

      (if $channel != "beta" then true else
         ($srcs | map(
            . as $src |
            ($tags | to_entries | map(select(((.value.repo // .key) | ascii_downcase) == $src)) | .[0].value) as $t |
            if $t == null then false
            else (($t.beta_date // "") > ($t.stable_date // "")) end
          ) | any)
       end) as $app_update_ok |

      # A manual TOML pin (patches-pin-manual, set by compile_patch_configs.py)
      # is authoritative: the app still follows the trigger rules, but its version
      # is left alone instead of being re-stamped to the watcher's current tag.
      if ((($srcs - $active[0]) != $srcs) and ($activePatchApps[0] | index($k))) or (($activeApps[0] | index($k)) and $app_update_ok) then
        (if ($pin_ok and ($app["patches-pin-manual"] | if . == true then false else true end)) then (.value["patches-version"] = $pin) else . end)
      else
        (.value.enabled = false)
      end
    else . end
  )
JQ

# A pool is regenerated when its own channel moved, or when any structural event
# that can change membership happened (app updates, blocked sources).
channel_triggered() {
  [ "${TRIGGER_BLOCKED:-0}" = "1" ] || [ "${TRIGGER_APP_UPDATE:-0}" = "1" ] || [ "${1:-0}" = "1" ]
}

generate_pool() {
  local channel="$1" active_file="$2" patch_apps_file="$3" out="$4"
  jq --argjson tags "$TAGS_NEW" \
     --arg channel "$channel" \
     --slurpfile active "$active_file" \
     --slurpfile activeApps active_apps.json \
     --slurpfile activePatchApps "$patch_apps_file" \
     "$POOL_PROGRAM" "config.$channel.json" > "$out"
}

if channel_triggered "${TRIGGER_STABLE:-0}"; then
  generate_pool stable active.stable.json active_patch_apps.stable.json configs/stable_build.json
fi

if channel_triggered "${TRIGGER_BETA:-0}"; then
  generate_pool beta active.beta.json active_patch_apps.beta.json configs/beta_build.json
fi
