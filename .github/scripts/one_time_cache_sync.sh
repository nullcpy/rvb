#!/bin/bash
set -euo pipefail

APK_FOLDER="${1:-temp/apks}"
TARGET_REPO="nullcpy/apks"

echo "Starting one-time sync of local cache to $TARGET_REPO..."

if [ ! -d "$APK_FOLDER" ]; then
    echo "Folder '$APK_FOLDER' does not exist. Nothing to sync."
    exit 0
fi

apks=($(find "$APK_FOLDER" -maxdepth 1 -type f \( -name "*.apk" -o -name "*.apkm" -o -name "*.xapk" -o -name "*.apks" \)))

if [ ${#apks[@]} -eq 0 ]; then
    echo "No APKs found to process."
    exit 0
fi

echo "Found ${#apks[@]} APK(s) to process."

for file in "${apks[@]}"; do
    filename=$(basename "$file")
    pkg_name="${filename%%-*}"
    
    echo "------------------------------------------------"
    echo "Checking $filename for release $pkg_name..."
    
    # Fetch release data
    if release_data=$(gh release view "$pkg_name" --repo "$TARGET_REPO" --json assets 2>/dev/null); then
        # Check if asset already exists
        if echo "$release_data" | jq -e ".assets[] | select(.name == \"$filename\")" > /dev/null; then
            echo " -> Asset $filename already exists on GitHub. Skipping!"
            continue
        fi
        
        echo " -> Uploading new asset to existing release..."
        gh release upload "$pkg_name" "$file" --repo "$TARGET_REPO" --clobber || true
    else
        echo " -> Release $pkg_name does not exist. Creating and uploading..."
        gh release create "$pkg_name" "$file" --repo "$TARGET_REPO" --title "$pkg_name" --notes "" || true
    fi
done

echo "------------------------------------------------"
echo "Cache sync complete!"
