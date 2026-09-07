#!/bin/bash
set -euo pipefail
CONFIG="$1"

if [ ! -f "$CONFIG" ]; then
  echo "::error::Config file not found: $CONFIG"
  exit 1
fi

echo "CONFIG_FILE=$CONFIG" >> "$GITHUB_OUTPUT"

IS_BETA=false
if [[ "$CONFIG" == *"beta"* ]] || [[ "$CONFIG" == *"dev"* ]]; then
  IS_BETA=true
elif [[ "$CONFIG" == *.json ]]; then
  pv=$(jq -r '."patches-version" // empty' "$CONFIG")
  if [ "$pv" = "beta" ] || [ "$pv" = "dev" ]; then
    IS_BETA=true
  fi
elif [[ "$CONFIG" == *.toml ]]; then
  if awk '/^\[/ {exit} {print}' "$CONFIG" | grep -qE '^[[:space:]]*patches-version[[:space:]]*=[[:space:]]*"?(beta|dev)"?'; then
    IS_BETA=true
  fi
fi

if [ "$IS_BETA" = true ]; then
  echo "IS_PRERELEASE=true" >> "$GITHUB_OUTPUT"
  echo "TG_THREAD_ID=350" >> "$GITHUB_OUTPUT"
  echo "TITLE_SUFFIX= (Pre-release)" >> "$GITHUB_OUTPUT"
  echo "ARCHIVE_TAG=beta" >> "$GITHUB_OUTPUT"
else
  echo "IS_PRERELEASE=false" >> "$GITHUB_OUTPUT"
  echo "TG_THREAD_ID=262" >> "$GITHUB_OUTPUT"
  echo "TITLE_SUFFIX=" >> "$GITHUB_OUTPUT"
  echo "ARCHIVE_TAG=stable" >> "$GITHUB_OUTPUT"
fi
