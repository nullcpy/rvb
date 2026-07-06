#!/bin/bash
set -euo pipefail

CURRENT_VERSIONS=".github/configs/app_versions.json"
ACTIVE_APPS="active_apps.json"

[ -f "$CURRENT_VERSIONS" ] || echo '{}' > "$CURRENT_VERSIONS"

if [ -z "${FETCHED_APP_VERSIONS:-}" ]; then
    FETCHED_APP_VERSIONS="{}"
fi
[ -f "$ACTIVE_APPS" ] || echo '[]' > "$ACTIVE_APPS"

APP_UPDATES_FILE="app_updates.json"
echo '{}' > "$APP_UPDATES_FILE"

TRIGGER_APP_UPDATE=0

# Compare fetched versions with current versions
APPS=$(echo "$FETCHED_APP_VERSIONS" | jq -r 'keys[]')
for app in $APPS; do
    new_ver=$(echo "$FETCHED_APP_VERSIONS" | jq -r ".\"$app\"")
    old_ver=$(jq -r ".\"$app\" // empty" "$CURRENT_VERSIONS")
    
    if [ "$new_ver" != "$old_ver" ] && [ -n "$new_ver" ]; then
        echo "Update detected for $app: $old_ver -> $new_ver"
        TRIGGER_APP_UPDATE=1
        
        # Add to active_apps.json
        jq --arg app "$app" '. + [$app] | unique' "$ACTIVE_APPS" > tmp.json && mv tmp.json "$ACTIVE_APPS"
        
        # Add to app_updates.json for Telegram notification
        jq --arg app "$app" --arg old "${old_ver:-unknown}" --arg new "$new_ver" '.[$app] = {old: $old, new: $new}' "$APP_UPDATES_FILE" > tmp.json && mv tmp.json "$APP_UPDATES_FILE"
        
        # Update current versions
        jq --arg app "$app" --arg ver "$new_ver" '.[$app] = $ver' "$CURRENT_VERSIONS" > tmp.json && mv tmp.json "$CURRENT_VERSIONS"
    fi
done

if [ "$TRIGGER_APP_UPDATE" = "1" ]; then
    echo "Updates were found!"
else
    echo "No app updates found."
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "TRIGGER_APP_UPDATE=$TRIGGER_APP_UPDATE" >> "$GITHUB_OUTPUT"
fi
