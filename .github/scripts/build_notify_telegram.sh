#!/bin/bash
set -euo pipefail
cd build || { echo "build folder not found"; exit 1; }

NL=$'\n'
APKS=""
MODULES=""
HAS_MODULES=false

shopt -s nullglob
for OUTPUT in *; do
  DL_URL="$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/releases/download/$NEXT_VER_CODE/${OUTPUT}"
  if [[ $OUTPUT = *.apk ]]; then
    APKS+="${NL}${NL}[${OUTPUT}](${DL_URL})"
  elif [[ $OUTPUT = *.zip ]]; then
    MODULES+="${NL}${NL}[${OUTPUT}](${DL_URL})"
    HAS_MODULES=true
  fi
done
shopt -u nullglob

MODULES=${MODULES#"$NL"}
APKS=${APKS#"$NL"}

BODY="$(sed 's/^\* \*\*/↪ \*\*/g; s/^\* `/↪ \*\*/g; s/`/\*/g; s/^\* /\↪/g; s/\*\*/\*/g; s/###//g; s/^- /↪ /g; /^==/d;' ../build.tmp)"

MSG="*Build No. $NEXT_VER_CODE*${TITLE_SUFFIX}${NL}${NL}${BODY}${NL}${NL}"
  
if [ "$HAS_MODULES" = true ]; then
  MSG+="*Modules:*${MODULES}${NL}${NL}"
fi

MSG+="*APKs:*${APKS}"

# Split MSG into ≤4096-char chunks on line boundaries (never breaks URLs)
TG_LIMIT=4096
CHUNK=""
send_chunk() {
  local text="$1"
  curl -s -X POST \
    --data-urlencode "parse_mode=Markdown" \
    --data-urlencode "disable_web_page_preview=true" \
    --data-urlencode "text=${text}" \
    --data-urlencode "chat_id=@rvb27" \
    --data-urlencode "message_thread_id=${TG_THREAD_ID}" \
    "https://api.telegram.org/bot${TG_TOKEN}/sendMessage"
  curl -s -X POST \
    --data-urlencode "parse_mode=Markdown" \
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
