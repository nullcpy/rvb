#!/bin/bash
set -euo pipefail

# Compare old and new patch tags to trigger builds
# Usage: compare-patch-tags.sh [patch_file] <latest_tags>

# Source shared config
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh" || { echo "❌ Failed to source config.sh"; exit 1; }

# Validate required config variables
if [ -z "${PATCH_SOURCES_FILE:-}" ]; then
  echo "❌ Required config variables not set"
  exit 1
fi

PATCH_FILE="${1:-$PATCH_SOURCES_FILE}"
LATEST_TAGS="${2:?Latest tags JSON required}"

# Validate patch file exists
if [ ! -f "$PATCH_FILE" ]; then
  echo "❌ Patch file not found: $PATCH_FILE" >&2
  exit 1
fi

OLD_JSON=$(cat "$PATCH_FILE")
NEW_JSON="$LATEST_TAGS"

# Safety: if NEW_JSON is empty for some reason, treat as empty JSON
if [ -z "$NEW_JSON" ]; then
  echo "⚠️  Empty new tags JSON, using empty object" >&2
  NEW_JSON="{}"
fi

# Compute triggers
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

# Update patch_sources.json to the new tags
echo "$NEW_JSON" > "$PATCH_FILE"

echo "TRIGGER_STABLE=$TRIGGER_STABLE" >> "$GITHUB_OUTPUT"
echo "TRIGGER_PRERELEASE=$TRIGGER_PRERELEASE" >> "$GITHUB_OUTPUT"

# Expose old & new JSON as outputs
DELIM1="$(openssl rand -hex 8)"
echo "tags_old<<${DELIM1}" >> "$GITHUB_OUTPUT"
echo "$OLD_JSON" >> "$GITHUB_OUTPUT"
echo "${DELIM1}" >> "$GITHUB_OUTPUT"

DELIM2="$(openssl rand -hex 8)"
echo "tags_new<<${DELIM2}" >> "$GITHUB_OUTPUT"
echo "$NEW_JSON" >> "$GITHUB_OUTPUT"
echo "${DELIM2}" >> "$GITHUB_OUTPUT"

echo "✅ Compared patch tags (Stable: $TRIGGER_STABLE, Prerelease: $TRIGGER_PRERELEASE)"
