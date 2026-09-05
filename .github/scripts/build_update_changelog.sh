#!/bin/bash
set -euo pipefail

NEXT_VER_CODE="${NEXT_VER_CODE:-$(date +'%Y%m%d')}"
ARCHIVE_TAG="${ARCHIVE_TAG:-stable}"
GITHUB_SERVER_URL="${GITHUB_SERVER_URL:-https://github.com}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-}"

git checkout -f update || git switch --discard-changes --orphan update
mkdir -p changelogs
cp -f build.tmp "changelogs/${NEXT_VER_CODE}.md"
cp -f build.tmp build.md

get_update_json() {
  echo "{
  \"version\": \"$1\",
  \"versionCode\": $NEXT_VER_CODE,
  \"zipUrl\": \"$2\",
  \"changelog\": \"https://raw.githubusercontent.com/$GITHUB_REPOSITORY/update/changelogs/$NEXT_VER_CODE.md\"
}"
}

cd build || { echo "build folder not found"; exit 1; }
for OUTPUT in *module*.zip; do
  [ "$OUTPUT" = "*module*.zip" ] && continue
  ZIP_S=$(unzip -p "$OUTPUT" module.prop)
  if ! UPDATE_JSON=$(echo "$ZIP_S" | grep updateJson); then continue; fi
  UPDATE_JSON="${UPDATE_JSON##*/}"
  VER=$(echo "$ZIP_S" | grep version=)
  VER="${VER##*=}"
  DLURL="$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/releases/download/${ARCHIVE_TAG:-stable}/${OUTPUT}"
  get_update_json "$VER" "$DLURL" >"../$UPDATE_JSON"
done
cd ..
