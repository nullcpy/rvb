#!/bin/bash
set -euo pipefail

# Upload archive to Filebin
# Usage: upload-filebin.sh <release_number> <build_type> <run_id> <run_attempt>

RELEASE_NUMBER="${1:?Release number required}"
BUILD_TYPE="${2:?Build type required (e.g., manual, stable, dev)}"
RUN_ID="${3:?GitHub run ID required}"
RUN_ATTEMPT="${4:?GitHub run attempt required}"

# Source shared config
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh" || { echo "❌ Failed to source config.sh"; exit 1; }

# Validate required config variables
if [ -z "${BUILD_DIR:-}" ] || [ -z "${FILEBIN_URL:-}" ] || [ -z "${FILEBIN_CONNECT_TIMEOUT:-}" ] || [ -z "${FILEBIN_MAX_TIMEOUT:-}" ]; then
  echo "❌ Required config variables not set"
  exit 1
fi

cd "$BUILD_DIR" || { echo "❌ build folder not found"; exit 1; }

ARCHIVE_NAME="archive-$RELEASE_NUMBER.zip"

# The archive should already exist from BuzzHeavier step
if [ ! -f "$ARCHIVE_NAME" ]; then
  echo "❌ Expected archive $ARCHIVE_NAME not found!"
  exit 1
fi

BIN_ID="revanced-builder-${BUILD_TYPE}-${RELEASE_NUMBER}-${RUN_ID}-${RUN_ATTEMPT}"

echo "⬆️ Uploading $ARCHIVE_NAME to Filebin bin: $BIN_ID"
if curl --connect-timeout "$FILEBIN_CONNECT_TIMEOUT" --max-time "$FILEBIN_MAX_TIMEOUT" --fail-with-body --upload-file "$ARCHIVE_NAME" "$FILEBIN_URL/$BIN_ID/$ARCHIVE_NAME"; then
  echo "✅ $ARCHIVE_NAME uploaded to Filebin"
  
  # Lock bin
  if curl --connect-timeout 10 --max-time 30 --fail-with-body -X PUT "$FILEBIN_URL/$BIN_ID"; then
    echo "🔒 Bin locked successfully."
  else
    echo "⚠️ Failed to lock bin (not critical)."
  fi
  
  echo "UPLOAD_SUCCESS=true" >> "$GITHUB_OUTPUT"
  echo "FILEBIN_LINK=$FILEBIN_URL/$BIN_ID/$ARCHIVE_NAME" >> "$GITHUB_OUTPUT"
else
  echo "❌ Failed to upload $ARCHIVE_NAME to Filebin."
  echo "UPLOAD_SUCCESS=false" >> "$GITHUB_OUTPUT"
  echo "FILEBIN_LINK=" >> "$GITHUB_OUTPUT"
fi

# DELETE archive after upload (so it doesn't appear in Telegram)
if [ -f "$ARCHIVE_NAME" ]; then
  echo "🗑️ Removing $ARCHIVE_NAME from local build dir"
  rm -f "$ARCHIVE_NAME"
fi
