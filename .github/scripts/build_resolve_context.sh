#!/bin/bash
set -euo pipefail
CONFIG="${1:-}"

if [ -z "$CONFIG" ] || [ ! -f "$CONFIG" ]; then
  echo "::error::Config file not found: ${CONFIG:-(empty)}"
  exit 1
fi

echo "CONFIG_FILE=$CONFIG" >> "$GITHUB_OUTPUT"

IS_BETA=false
# Two ways a build is a pre-release: the config FILENAME (the generated
# beta_build.json, or a hand-written .beta. TOML) or the channel value it carries,
# which is only ever "stable" or "beta". A "dev" spelling used to be accepted in
# both; it matched whole paths too loosely to be safe and no config ever used it.
if [[ "$CONFIG" == *"beta"* ]]; then
  IS_BETA=true
elif [[ "$CONFIG" == *.json ]]; then
  pv=$(jq -r '."patches-version" // empty' "$CONFIG")
  if [ "$pv" = "beta" ]; then
    IS_BETA=true
  fi
elif [[ "$CONFIG" == *.toml ]]; then
  if awk '/^\[/ {exit} {print}' "$CONFIG" | grep -qE '^[[:space:]]*patches-version[[:space:]]*=[[:space:]]*"?beta"?'; then
    IS_BETA=true
  fi
fi

if [ "$IS_BETA" = true ]; then
  echo "IS_PRERELEASE=true" >> "$GITHUB_OUTPUT"
  echo "TG_THREAD_ID=${TG_THREAD_BETA:-350}" >> "$GITHUB_OUTPUT"
  echo "TITLE_SUFFIX= (Pre-release)" >> "$GITHUB_OUTPUT"
  echo "ARCHIVE_TAG=beta" >> "$GITHUB_OUTPUT"
else
  echo "IS_PRERELEASE=false" >> "$GITHUB_OUTPUT"
  echo "TG_THREAD_ID=${TG_THREAD_STABLE:-262}" >> "$GITHUB_OUTPUT"
  echo "TITLE_SUFFIX=" >> "$GITHUB_OUTPUT"
  echo "ARCHIVE_TAG=stable" >> "$GITHUB_OUTPUT"
fi
