#!/bin/bash
set -euo pipefail
PATCH_FILE=".github/configs/patch_sources.json"
BASE_JSON=$(cat "$PATCH_FILE")

fetch_gitlab_releases() {
  local repo=$1 encoded_repo
  encoded_repo=$(jq -nr --arg v "$repo" '$v | @uri')
  curl -sS -L -w '\n%{http_code}' "https://gitlab.com/api/v4/projects/${encoded_repo}/releases?per_page=100"
}

if echo "$BASE_JSON" | jq -e 'length == 0' >/dev/null; then
  DELIM="$(openssl rand -hex 8)"
  echo "latest<<${DELIM}" >> "$GITHUB_OUTPUT"
  echo "$BASE_JSON" >> "$GITHUB_OUTPUT"
  echo "${DELIM}" >> "$GITHUB_OUTPUT"
  exit 0
fi

> updates.jsonl

while read -r id repo host enabled enabledStable enabledDev; do
  if [ "$enabled" == "false" ]; then continue; fi

  if [ "$host" = "gitlab" ]; then
    api_response=$(fetch_gitlab_releases "$repo" 2>&1 || true)
    api_http_code=$(printf '%s\n' "$api_response" | tail -n1)
    api_response=$(printf '%s\n' "$api_response" | sed '$d')
  else
    api_response=$(gh api "repos/$repo/releases?per_page=100" 2>&1 || true)
  fi

  if [ "$host" = "github" ] && echo "$api_response" | grep -qiE '"message".*(Repository access blocked|Not Found)'; then
    jq -n --arg id "$id" '{($id): {"blocked": true}}' >> updates.jsonl
  elif [ "$host" = "gitlab" ] && { [ "$api_http_code" = "403" ] || [ "$api_http_code" = "404" ]; }; then
    jq -n --arg id "$id" '{($id): {"blocked": true}}' >> updates.jsonl
  elif echo "$api_response" | jq -e 'type == "array"' >/dev/null 2>&1; then
    if [ "$host" = "gitlab" ]; then
      stable=$(echo "$api_response" | jq -r '(map(select(.tag_name != null and .tag_name != "" and (.tag_name | test("(?i)(dev|alpha|beta|rc)") | not))) | sort_by(.released_at // .created_at // "") | reverse | .[0].tag_name // "")')
      pre=$(echo "$api_response" | jq -r '(map(select(.tag_name != null and .tag_name != "" and (.tag_name | test("(?i)(dev|alpha|beta|rc)")))) | sort_by(.released_at // .created_at // "") | reverse | .[0].tag_name // "")')
    else
      stable=$(echo "$api_response" | jq -r '(map(select(.prerelease == false and .tag_name != null and .tag_name != "")) | sort_by(.published_at) | reverse | .[0].tag_name // "")')
      pre=$(echo "$api_response" | jq -r '(map(select(.prerelease == true and .tag_name != null and .tag_name != "")) | sort_by(.published_at) | reverse | .[0].tag_name // "")')
    fi

    jq -n --arg id "$id" --arg stable "$stable" --arg pre "$pre" \
      '{($id): {"stable": $stable, "prerelease": $pre, "blocked": false}}' >> updates.jsonl
  else
    echo "::warning::API error or rate limit for $repo. Retaining previous state."
    old_stable=$(echo "$BASE_JSON" | jq -r ".\"$id\".stable // \"\"")
    old_pre=$(echo "$BASE_JSON" | jq -r ".\"$id\".prerelease // \"\"")
    old_blocked=$(echo "$BASE_JSON" | jq -r ".\"$id\".blocked // false")
    
    jq -n --arg id "$id" --arg stable "$old_stable" --arg pre "$old_pre" --argjson blocked "$old_blocked" \
      '{($id): {"stable": $stable, "prerelease": $pre, "blocked": $blocked}}' >> updates.jsonl
  fi

done < <(echo "$BASE_JSON" | jq -r 'to_entries[] | select(.value.repo != "") | "\(.key) \(.value.repo) \((.value.host // "github") | ascii_downcase) \(if .value.enabled == false then false else true end) \(if .value.enabledStable == false then false else true end) \(if .value.enabledDev == false then false else true end)"')

if [ -s updates.jsonl ]; then
   NEW_JSON=$(jq -s --argjson base "$BASE_JSON" 'reduce .[] as $item ($base; . * $item)' updates.jsonl)
else
   NEW_JSON="$BASE_JSON"
fi

DELIM="$(openssl rand -hex 8)"
echo "latest<<${DELIM}" >> "$GITHUB_OUTPUT"
echo "$NEW_JSON" >> "$GITHUB_OUTPUT"
echo "${DELIM}" >> "$GITHUB_OUTPUT"
