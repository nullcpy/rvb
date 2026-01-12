#!/bin/bash
set -euo pipefail

# Update changelog and Magisk update JSON files
# Usage: update-changelog.sh <release_number> <github_server_url> <github_repo>

RELEASE_NUMBER="${1:?Release number required}"
GITHUB_SERVER_URL="${2:?GitHub server URL required}"
GITHUB_REPO="${3:?GitHub repository required}"

# Source shared config
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh" || { echo "❌ Failed to source config.sh"; exit 1; }

# Validate required config variables
if [ -z "${BUILD_DIR:-}" ]; then
  echo "❌ Required config variables not set"
  exit 1
fi

git checkout -f update || git switch --discard-changes --orphan update
cp -f build.tmp build.md

get_update_json() {
  echo "{
  \"version\": \"$1\",
  \"versionCode\": $RELEASE_NUMBER,
  \"zipUrl\": \"$2\",
  \"changelog\": \"https://raw.githubusercontent.com/$GITHUB_REPO/update/build.md\"
}"
}

cd "$BUILD_DIR" || { echo "❌ build folder not found"; exit 1; }

for OUTPUT in *magisk*.zip; do
  [ "$OUTPUT" = "*magisk*.zip" ] && continue
  ZIP_S=$(unzip -p "$OUTPUT" module.prop)
  if ! UPDATE_JSON=$(echo "$ZIP_S" | grep updateJson); then continue; fi
  UPDATE_JSON="${UPDATE_JSON##*/}"
  VER=$(echo "$ZIP_S" | grep version=)
  VER="${VER##*=}"
  DLURL="$GITHUB_SERVER_URL/$GITHUB_REPO/releases/download/$RELEASE_NUMBER/${OUTPUT}"
  get_update_json "$VER" "$DLURL" >"../$UPDATE_JSON"
done

cd ..

find . -name "*-update.json" | grep . || : >dummy-update.json

echo "✅ Updated changelog and Magisk update JSON files"
