#!/bin/bash
set -euo pipefail
NL=$'\n'

if [ -z "${TG_TOKEN:-}" ]; then
  echo "TG_TOKEN is not set. Skipping Telegram notification."
  exit 0
fi

BUILD_FILE="build.md"
if [ ! -f "$BUILD_FILE" ]; then
  BUILD_FILE="build.tmp"
fi
if [ ! -f "$BUILD_FILE" ]; then
  echo "Release notes file (build.md or build.tmp) not found"
  exit 1
fi

BODY="$(sed \
  -e 's/&/&amp;/g; s/</\&lt;/g; s/>/\&gt;/g' \
  -e 's/^### \(.*\)/<b>\1<\/b>/g' \
  -e 's/^\* /• /g' \
  -e 's/^  \* /  ↪ /g' \
  -e 's/^- /• /g' \
  -e 's/^---$//g' \
  -e 's/\*\*\([^*]*\)\*\*/<b>\1<\/b>/g' \
  -e 's/`\([^`]*\)`/<code>\1<\/code>/g' \
  -e 's/\[\([^]]*\)\](\([^)]*\))/<a href="\2">\1<\/a>/g' \
  "$BUILD_FILE")"

TITLE_SUFFIX_ESC="$(echo "${TITLE_SUFFIX:-}" | sed 's/&/&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')"
MSG="<b>Build No. $NEXT_VER_CODE</b>${TITLE_SUFFIX_ESC}${NL}${NL}${BODY}"

# Split MSG into ≤4096-char chunks on line boundaries (never breaks URLs)
TG_LIMIT=4096
CHUNK=""
send_chunk() {
  local text="${1:-}"
  [ -z "$text" ] && return 0
  curl -s -X POST \
    --data-urlencode "parse_mode=HTML" \
    --data-urlencode "disable_web_page_preview=true" \
    --data-urlencode "text=${text}" \
    --data-urlencode "chat_id=@rvb27" \
    --data-urlencode "message_thread_id=${TG_THREAD_ID:-}" \
    "https://api.telegram.org/bot${TG_TOKEN}/sendMessage"
  curl -s -X POST \
    --data-urlencode "parse_mode=HTML" \
    --data-urlencode "disable_web_page_preview=true" \
    --data-urlencode "text=${text}" \
    --data-urlencode "chat_id=@rvb28" \
    "https://api.telegram.org/bot${TG_TOKEN}/sendMessage"
}

while IFS= read -r LINE; do
  # +1 for the newline we'll re-add between lines
  CANDIDATE="${CHUNK:+${CHUNK}${NL}}${LINE}"
  if [ "${#CANDIDATE}" -le "$TG_LIMIT" ]; then
    CHUNK="$CANDIDATE"
  else
    # Flush current chunk and start a new one with this line
    if [ -n "$CHUNK" ]; then
      send_chunk "$CHUNK"
    fi
    CHUNK="$LINE"
  fi
done <<< "$MSG"

# Send any remaining content
if [ -n "$CHUNK" ]; then
  send_chunk "$CHUNK"
fi
