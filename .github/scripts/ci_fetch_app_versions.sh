#!/bin/bash
set -euo pipefail

# Convert utils.sh to Unix line endings if needed
dos2unix utils.sh 2>/dev/null || true

source utils.sh
set_prebuilts

# Find all app configs
CONFIG_FILES=$(find .github/configs/patches -name "*.toml")

if [ -z "$CONFIG_FILES" ]; then
    echo "No config files found in .github/configs/patches"
    exit 0
fi

# Convert all TOML files to a single JSON
# shellcheck disable=SC2086
yq -o=json eval-all '. as $item ireduce ({}; . * $item)' $CONFIG_FILES > temp_all_configs.json

[ -f .github/configs/app_versions.json ] || echo '{}' > .github/configs/app_versions.json
> fetched_app_versions.jsonl
CHECK_ONLY_LISTED=$(jq -r '."_check_only_listed" // false' .github/configs/app_versions.json)

if [ "$CHECK_ONLY_LISTED" = "true" ]; then
    APPS=$(jq -r --argjson allowed "$(jq 'keys | map(select(startswith("_") | not))' .github/configs/app_versions.json)" '
        to_entries | map(select(.value.enabled == true and (.key as $k | $allowed | index($k)))) | .[].key
    ' temp_all_configs.json)
else
    APPS=$(jq -r 'to_entries | map(select(.value.enabled == true)) | .[].key' temp_all_configs.json)
fi

declare -A cached_versions

for app in $APPS; do
    echo "Checking version for $app..."
    
    uptodown_url=$(jq -r ".\"$app\".\"uptodown-dlurl\" // empty" temp_all_configs.json)
    apkmirror_url=$(jq -r ".\"$app\".\"apkmirror-dlurl\" // empty" temp_all_configs.json)
    apkpure_url=$(jq -r ".\"$app\".\"apkpure-dlurl\" // empty" temp_all_configs.json)
    apkcombo_url=$(jq -r ".\"$app\".\"apkcombo-dlurl\" // empty" temp_all_configs.json)

    dlurls=()
    [ -n "$uptodown_url" ] && dlurls+=("$uptodown_url")
    [ -n "$apkmirror_url" ] && dlurls+=("$apkmirror_url")
    [ -n "$apkpure_url" ] && dlurls+=("$apkpure_url")
    [ -n "$apkcombo_url" ] && dlurls+=("$apkcombo_url")

    if [ ${#dlurls[@]} -eq 0 ]; then
        echo "No dlurl for $app, skipping"
        continue
    fi
    
    latest_ver=""
    for dlurl in "${dlurls[@]}"; do
        if [ -n "${cached_versions[$dlurl]:-}" ]; then
            latest_ver="${cached_versions[$dlurl]}"
            echo "Reusing cached version for $app: $latest_ver"
            break
        else
            if [[ "$dlurl" == *"uptodown"* ]]; then
                get_uptodown_resp "$dlurl" || { echo "Failed uptodown resp for $app"; continue; }
                vers=$(get_uptodown_vers) || { echo "Failed uptodown vers for $app"; continue; }
                latest_ver=$(echo "$vers" | get_highest_ver) || true
            elif [[ "$dlurl" == *"apkmirror"* ]]; then
                get_apkmirror_resp "$dlurl" || { echo "Failed apkmirror resp for $app"; continue; }
                vers=$(get_apkmirror_vers) || { echo "Failed apkmirror vers for $app"; continue; }
                latest_ver=$(echo "$vers" | get_highest_ver) || true
            elif [[ "$dlurl" == *"apkpure"* ]]; then
                get_apkpure_resp "$dlurl" || { echo "Failed apkpure resp for $app"; continue; }
                vers=$(get_apkpure_vers) || { echo "Failed apkpure vers for $app"; continue; }
                latest_ver=$(echo "$vers" | get_highest_ver) || true
            elif [[ "$dlurl" == *"apkcombo"* ]]; then
                get_apkcombo_resp "$dlurl" || { echo "Failed apkcombo resp for $app"; continue; }
                vers=$(get_apkcombo_vers) || { echo "Failed apkcombo vers for $app"; continue; }
                latest_ver=$(echo "$vers" | get_highest_ver) || true
            fi
            
            if [ -n "$latest_ver" ]; then
                cached_versions[$dlurl]="$latest_ver"
                # Sleep to avoid rate limiting only if we actually fetched
                sleep 2
                break
            fi
        fi
    done
    
    if [ -n "$latest_ver" ]; then
        echo "Latest version for $app is $latest_ver"
        jq -n --arg app "$app" --arg ver "$latest_ver" '{($app): $ver}' >> fetched_app_versions.jsonl
    else
        echo "Could not find latest version for $app"
    fi
done

if [ -s fetched_app_versions.jsonl ]; then
    FETCHED_JSON=$(jq -s 'reduce .[] as $item ({}; . * $item)' fetched_app_versions.jsonl)
else
    FETCHED_JSON="{}"
fi

DELIM="$(openssl rand -hex 8)"
echo "fetched<<${DELIM}" >> "$GITHUB_OUTPUT"
echo "$FETCHED_JSON" >> "$GITHUB_OUTPUT"
echo "${DELIM}" >> "$GITHUB_OUTPUT"

rm -f temp_all_configs.json fetched_app_versions.jsonl
