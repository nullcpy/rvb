#!/bin/bash
set -euo pipefail

# Send Telegram notification for new build
# Usage: notify-telegram.sh <release_number> <tg_token> <tg_chat> <tg_channel> <tg_thread_id> <title_suffix> <github_server_url> <github_repo> <buzz_link> <buzz_success> <filebin_link> <filebin_success>

RELEASE_NUMBER="${1:?Release number required}"
TG_TOKEN="${2:?Telegram token required}"
TG_CHAT="${3:?Telegram chat required}"
TG_CHANNEL="${4:?Telegram channel required}"
TG_THREAD_ID="${5:?Telegram thread ID required}"
TITLE_SUFFIX="${6:-}"  # Optional, e.g., " (Pre-release)" or ""
GITHUB_SERVER_URL="${7:?GitHub server URL required}"
GITHUB_REPO="${8:?GitHub repository required}"
BUZZHEAVIER_LINK="${9:-}"
BUZZHEAVIER_SUCCESS="${10:-false}"
FILEBIN_LINK="${11:-}"
FILEBIN_SUCCESS="${12:-false}"

# Source shared config
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh" || { echo "❌ Failed to source config.sh"; exit 1; }

# Validate required config variables
if [ -z "${BUILD_DIR:-}" ] || [ -z "${MAX_MSG_LENGTH:-}" ]; then
  echo "❌ Required config variables not set"
  exit 1
fi

cd "$BUILD_DIR" || { echo "❌ build folder not found"; exit 1; }

NL=$'\n'
APKS=""
MODULES=""
HAS_MODULES=false

for OUTPUT in *; do
  DL_URL="$GITHUB_SERVER_URL/$GITHUB_REPO/releases/download/$RELEASE_NUMBER/${OUTPUT}"
  if [[ $OUTPUT = *.apk ]]; then
    APKS+="${NL}${NL}[${OUTPUT}](${DL_URL})"
  elif [[ $OUTPUT = *.zip ]]; then
    MODULES+="${NL}${NL}[${OUTPUT}](${DL_URL})"
    HAS_MODULES=true
  fi
done

MODULES=${MODULES#"$NL"}
APKS=${APKS#"$NL"}

BODY="$(sed 's/^\* \*\*/↪ \*\*/g; s/^\* `/↪ \*\*/g; s/`/\*/g; s/^\* /\↪/g; s/\*\*/\*/g; s/###//g; s/^- /↪ /g; /^==/d;' ../build.md)"

MSG="*Build No. $RELEASE_NUMBER*${TITLE_SUFFIX}${NL}${NL}${BODY}${NL}${NL}"

MIRRORS=""
if [ "$BUZZHEAVIER_SUCCESS" = "true" ]; then
  MIRRORS+="[BuzzHeavier]($BUZZHEAVIER_LINK)${NL}"
fi
if [ "$FILEBIN_SUCCESS" = "true" ]; then
  MIRRORS+="[Filebin]($FILEBIN_LINK)${NL}"
fi

if [ -n "$MIRRORS" ]; then
  MSG+="*Mirrors:*${NL}${MIRRORS}${NL}"
fi

if [ "$HAS_MODULES" = true ]; then
  MSG+="*Modules:*${MODULES}${NL}${NL}"
fi

MSG+="*APKs:*${APKS}"
MSG=${MSG:0:$MAX_MSG_LENGTH}

# Send to group
curl -X POST \
  --data-urlencode "parse_mode=Markdown" \
  --data-urlencode "disable_web_page_preview=true" \
  --data-urlencode "text=${MSG}" \
  --data-urlencode "chat_id=${TG_CHAT}" \
  --data-urlencode "message_thread_id=${TG_THREAD_ID}" \
  "https://api.telegram.org/bot${TG_TOKEN}/sendMessage"

sleep 2

# Send to channel
curl -X POST \
  --data-urlencode "parse_mode=Markdown" \
  --data-urlencode "disable_web_page_preview=true" \
  --data-urlencode "text=${MSG}" \
  --data-urlencode "chat_id=${TG_CHANNEL}" \
  "https://api.telegram.org/bot${TG_TOKEN}/sendMessage"

echo "✅ Telegram notifications sent"
