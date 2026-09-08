#!/bin/bash
set -euo pipefail

# Check if any module zip was actually built
shopt -s nullglob
MODULES=(build/*module*.zip)
shopt -u nullglob

if [ ${#MODULES[@]} -eq 0 ]; then
  echo "No modules produced in this build. Skipping update branch changelog."
  if [ -n "${GITHUB_OUTPUT-}" ]; then
    echo "has_modules=false" >> "$GITHUB_OUTPUT"
  fi
  exit 0
fi

if [ -n "${GITHUB_OUTPUT-}" ]; then
  echo "has_modules=true" >> "$GITHUB_OUTPUT"
fi

git checkout -f update || git switch --discard-changes --orphan update
mkdir -p changelogs
SRC_MD="build.md"
[ -f build.tmp ] && SRC_MD="build.tmp"
if [ -f "$SRC_MD" ]; then
  cp -f "$SRC_MD" "changelogs/${NEXT_VER_CODE}.md"
fi

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
  DLURL="$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/releases/download/$ARCHIVE_TAG/${OUTPUT}"
  get_update_json "$VER" "$DLURL" >"../$UPDATE_JSON"
done
