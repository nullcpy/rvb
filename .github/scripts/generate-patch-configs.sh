#!/bin/bash
set -euo pipefail

# Generate build configuration files based on patch changes
# Usage: generate-patch-configs.sh <tags_old_json> <tags_new_json>

# Source shared config
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh" || { echo "❌ Failed to source config.sh"; exit 1; }

# Validate required config variables
if [ -z "${ACTIVE_STABLE_TXT:-}" ] || [ -z "${ACTIVE_PRERELEASE_TXT:-}" ] || [ -z "${CONFIG_STABLE_UPDATED:-}" ] || [ -z "${CONFIG_DEV_UPDATED:-}" ]; then
  echo "❌ Required config variables not set"
  exit 1
fi

TAGS_OLD="${1:?Old tags JSON required}"
TAGS_NEW="${2:?New tags JSON required}"

BASE_CONFIG="config.toml"

# Build ACTIVE repo lists:
# For STABLE: repos where new.stable is non-empty AND changed vs old
# For PRERELEASE: repos where new.prerelease is non-empty AND changed vs old

# active.stable.txt
jq -rn --argjson new "$TAGS_NEW" --argjson old "$TAGS_OLD" '
  [ $new | to_entries[] | . as $e
      | ($old[$e.key] // {}) as $o
      | select($e.value.stable != "" and $e.value.stable != ($o.stable // ""))
      | $e.value.repo
  ] | .[]
' > "$ACTIVE_STABLE_TXT" || true

# active.prerelease.txt
jq -rn --argjson new "$TAGS_NEW" --argjson old "$TAGS_OLD" '
  [ $new | to_entries[] | . as $e
      | ($old[$e.key] // {}) as $o
      | select($e.value.prerelease != "" and $e.value.prerelease != ($o.prerelease // ""))
      | $e.value.repo
  ] | .[]
' > "$ACTIVE_PRERELEASE_TXT" || true

generate_config() {
  local mode="$1" # stable | dev
  local out_file
  if [ "$mode" = "stable" ]; then
    out_file="$CONFIG_STABLE_UPDATED"
  else
    out_file="$CONFIG_DEV_UPDATED"
  fi
  cp "$BASE_CONFIG" "$out_file"

  # Inject mode-specific global settings BEFORE patch toggling:
  if [ "$mode" = "stable" ]; then
    # Stable: magisk update enabled
    {
      echo 'enable-magisk-update = true'
      cat "$out_file"
    } > tmp_header
    mv tmp_header "$out_file"
  else
    # Dev: patches-version + magisk update disabled
    {
      echo 'patches-version = "dev"'
      echo 'enable-magisk-update = false'
      cat "$out_file"
    } > tmp_header
    mv tmp_header "$out_file"
  fi

  # Now, for each active repo, enable all patches
  local active_file
  if [ "$mode" = "stable" ]; then
    active_file="$ACTIVE_STABLE_TXT"
  else
    active_file="$ACTIVE_PRERELEASE_TXT"
  fi
  
  if [ -f "$active_file" ]; then
    while read -r repo; do
      # Find the [[patches.<repo>]] section and set enabled = true for all patches
      # Escape special characters in repo name for regex
      escaped_repo=$(printf '%s\n' "$repo" | sed 's/[.\\[]/\\&/g')
      awk -v repo="$escaped_repo" '
        /^\[\[patches\./ {
          if ($0 ~ "^\\[\\[patches\\." repo "\\]\\]$") {
            in_section = 1
          } else {
            in_section = 0
          }
        }
        in_section && /^enabled = / {
          $0 = "enabled = true"
        }
        { print }
      ' "$out_file" > tmp_patches
      mv tmp_patches "$out_file"
    done < "$active_file"
  fi

  echo "✅ Generated config.$mode.updated.toml"
}

if [ -s "$ACTIVE_STABLE_TXT" ]; then
  generate_config "stable"
fi

if [ -s "$ACTIVE_PRERELEASE_TXT" ]; then
  generate_config "dev"
fi
