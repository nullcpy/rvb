#!/bin/bash
set -euo pipefail

# Upload build artifacts to BuzzHeavier
# Usage: upload-buzzheavier.sh <release_number> <buzzheavier_account_id>

RELEASE_NUMBER="${1:?Release number required}"
BUZZHEAVIER_ACCOUNT_ID="${2:?BuzzHeavier account ID required}"

# Source shared config
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh" || { echo "❌ Failed to source config.sh"; exit 1; }

# Validate required config variables
if [ -z "${BUILD_DIR:-}" ] || [ -z "${BUZZHEAVIER_PARENT_ID:-}" ]; then
  echo "❌ Required config variables not set"
  exit 1
fi

cd "$BUILD_DIR" || { echo "❌ build folder not found"; exit 1; }

# Create full archive ONCE
ARCHIVE_NAME="archive-$RELEASE_NUMBER.zip"
echo "📦 Creating full archive: $ARCHIVE_NAME"
zip -q9 "$ARCHIVE_NAME" *

TOKEN=$(echo "$BUZZHEAVIER_ACCOUNT_ID" | xargs)
if [ -z "$TOKEN" ]; then
  echo "❌ BUZZHEAVIER_ACCOUNT_ID is missing"
  exit 1
fi

AUTH="Authorization: Bearer $TOKEN"

echo "✅ Using revanced-builder directory ID: $BUZZHEAVIER_PARENT_ID"
echo "🔍 Checking if folder '$RELEASE_NUMBER' already exists..."

# Fetch parent contents
PARENT_CONTENTS=$(curl -sS -H "$AUTH" "https://buzzheavier.com/api/fs/$BUZZHEAVIER_PARENT_ID")
EXISTING_ID=$(echo "$PARENT_CONTENTS" | jq -r ".data.children[] // [] | select(.name == \"$RELEASE_NUMBER\" and .isDirectory == true) | .id // empty")

if [ -n "$EXISTING_ID" ]; then
  echo "🗑️ Deleting existing folder '$RELEASE_NUMBER' (ID: $EXISTING_ID)..."
  curl -sS -X DELETE -H "$AUTH" "https://buzzheavier.com/api/fs/$EXISTING_ID" || true
  sleep 1
fi

echo "📁 Creating fresh folder: $RELEASE_NUMBER"
CREATE_RES=$(curl -sS -X POST \
  -H "$AUTH" \
  -H "Content-Type: application/json" \
  -d "{\"name\":\"$RELEASE_NUMBER\"}" \
  "https://buzzheavier.com/api/fs/$BUZZHEAVIER_PARENT_ID")

RELEASE_DIR_ID=$(echo "$CREATE_RES" | jq -r '.data.id // empty')
if [ -z "$RELEASE_DIR_ID" ]; then
  echo "❌ Failed to create folder. Response: $CREATE_RES"
  exit 1
fi
echo "✅ Folder created with ID: $RELEASE_DIR_ID"

# Upload ALL files (including archive-XXX.zip)
SUCCESS_COUNT=0
for FILE in *; do
  if [ -f "$FILE" ]; then
    echo "⬆️ Uploading $FILE..."
    if curl -# -T "$FILE" -H "$AUTH" "https://w.buzzheavier.com/$RELEASE_DIR_ID/$FILE"; then
      SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
      echo "⚠️ Failed to upload $FILE"
    fi
  fi
done

if [ "$SUCCESS_COUNT" -gt 0 ]; then
  PUBLIC_LINK="https://buzzheavier.com/$RELEASE_DIR_ID"
  echo "BUZZHEAVIER_LINK=$PUBLIC_LINK" >> "$GITHUB_OUTPUT"
  echo "UPLOAD_SUCCESS=true" >> "$GITHUB_OUTPUT"
  echo "✅ Uploaded $SUCCESS_COUNT files. Mirror: $PUBLIC_LINK"
else
  echo "UPLOAD_SUCCESS=false" >> "$GITHUB_OUTPUT"
  echo "BUZZHEAVIER_LINK=" >> "$GITHUB_OUTPUT"
  echo "❌ No files uploaded to BuzzHeavier."
fi
