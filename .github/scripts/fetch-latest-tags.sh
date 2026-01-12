#!/bin/bash
set -euo pipefail

# Fetch latest patch tags from GitHub repos
# Usage: fetch-latest-tags.sh [patch_file]

# Source shared config
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh" || { echo "❌ Failed to source config.sh"; exit 1; }

# Validate required config variables
if [ -z "${PATCH_SOURCES_FILE:-}" ]; then
  echo "❌ Required config variables not set"
  exit 1
fi

PATCH_FILE="${1:-$PATCH_SOURCES_FILE}"
GH_TOKEN="${GH_TOKEN:?GH_TOKEN environment variable required}"

BASE_JSON=$(cat "$PATCH_FILE")

# If empty JSON (no entries), just propagate as-is
if echo "$BASE_JSON" | jq -e 'length == 0' >/dev/null; then
  DELIM="$(openssl rand -hex 8)"
  echo "latest<<${DELIM}" >> "$GITHUB_OUTPUT"
  echo "$BASE_JSON" >> "$GITHUB_OUTPUT"
  echo "${DELIM}" >> "$GITHUB_OUTPUT"
  exit 0
fi

get_latest_tag() {
  local repo=$1
  local prerelease=$2

  # Fetch releases with auth, grab body + status
  local resp status body
  resp=$(curl -sS -w '%{http_code}' \
    -H "Authorization: Bearer $GH_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$repo/releases" 2>&1 || echo "000")

  status="${resp: -3}"
  body="${resp::-3}"

  # On non-200, log error and treat as "no tag"
  if [ "$status" != "200" ]; then
    echo "⚠️  Failed to fetch releases for $repo (HTTP $status)" >&2
    echo ""
    return 0
  fi

  if [ "$prerelease" = "true" ]; then
    echo "$body" | jq -r '[.[] | select(.prerelease == true)] | .[0].tag_name // ""' 2>/dev/null || echo ""
  else
    echo "$body" | jq -r '[.[] | select(.prerelease == false)] | .[0].tag_name // ""' 2>/dev/null || echo ""
  fi
}

NEW_JSON="$BASE_JSON"

# For each patch source, get stable + prerelease tags (skip empty repo)
while read -r id repo; do
  if [ -z "$repo" ]; then
    continue
  fi

  STABLE_TAG=$(get_latest_tag "$repo" "false")
  PRERELEASE_TAG=$(get_latest_tag "$repo" "true")

  NEW_JSON=$(echo "$NEW_JSON" | jq \
    --arg id "$id" \
    --arg stable "$STABLE_TAG" \
    --arg prerelease "$PRERELEASE_TAG" \
    '.[$id].stable = $stable | .[$id].prerelease = $prerelease')
done < <(echo "$BASE_JSON" | jq -r 'to_entries[] | select(.value.repo != "") | "\(.key) \(.value.repo)"')

DELIM="$(openssl rand -hex 8)"
echo "latest<<${DELIM}" >> "$GITHUB_OUTPUT"
echo "$NEW_JSON" >> "$GITHUB_OUTPUT"
echo "${DELIM}" >> "$GITHUB_OUTPUT"

echo "✅ Fetched latest tags"
