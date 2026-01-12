#!/bin/bash
set -euo pipefail

# Notify about detected patch updates
# Usage: notify-patch-detected.sh <build_type> <tags_old> <tags_new> <github_repo> <tg_token>

BUILD_TYPE="${1:?Build type required (stable or dev)}"
TAGS_OLD="${2:?Old tags JSON required}"
TAGS_NEW="${3:?New tags JSON required}"
GITHUB_REPO="${4:?GitHub repository required}"
TG_TOKEN="${5:?Telegram token required}"

# Source shared config
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh" || { echo "❌ Failed to source config.sh"; exit 1; }

# Validate required config variables
if [ -z "${TG_CHAT:-}" ] || [ -z "${TG_THREAD_ID_PATCH_DETECTION:-}" ] || [ -z "${MAX_MSG_LENGTH:-}" ]; then
  echo "❌ Required config variables not set"
  exit 1
fi

NL=$'\n'
MSG="*New Patch Detected!*"

if [ "$BUILD_TYPE" = "dev" ]; then
  MSG="*New Patch Detected!* (Pre-release)"
  VERSION_KEY="prerelease"
else
  VERSION_KEY="stable"
fi

MSG+="${NL}"

CHANGES=$(jq -n --argjson old "$TAGS_OLD" --argjson new "$TAGS_NEW" --arg key "$VERSION_KEY" '
  [
    (
      to_entries[] 
      | select(.value[$key] != ($old[.key][$key] // ""))
      | "\(.key): \(.value[$key] // "none")"
    )
  ] 
  | unique
')

if [ "$(echo "$CHANGES" | jq 'length')" -eq 0 ]; then
  MSG+="${NL}(Patch versions changed, but details could not be parsed)${NL}"
else
  while read -r change; do
    MSG+="${NL}• ${change}"
  done < <(echo "$CHANGES" | jq -r '.[]')
  MSG+="${NL}"
fi

MSG+="${NL}[Triggering new build...](https://github.com/$GITHUB_REPO/actions/runs/$GITHUB_RUN_ID)"
MSG=${MSG:0:$MAX_MSG_LENGTH}

curl -X POST \
  --data-urlencode "chat_id=${TG_CHAT}" \
  --data-urlencode "message_thread_id=${TG_THREAD_ID_PATCH_DETECTION}" \
  --data-urlencode "parse_mode=Markdown" \
  --data-urlencode "disable_web_page_preview=true" \
  --data-urlencode "text=${MSG}" \
  "https://api.telegram.org/bot${TG_TOKEN}/sendMessage"

echo "✅ Patch detection notification sent"
