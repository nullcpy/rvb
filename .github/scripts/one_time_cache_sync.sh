#!/bin/bash
set -euo pipefail

APK_FOLDER="${1:-temp/apks}"
TARGET_REPO="nullcpy/apks"

echo "Starting one-time sync and sanitization of local cache to $TARGET_REPO..."

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
    # Rename locally if it has a buggy name
    if [[ "$file" == *.apk.apkm ]] || [[ "$file" == *.apk.xapk ]] || [[ "$file" == *.apk.apks ]]; then
        clean_file="${file%.apk.apkm}.apkm"
        if [[ "$file" == *.apk.xapk ]]; then clean_file="${file%.apk.xapk}.xapk"; fi
        if [[ "$file" == *.apk.apks ]]; then clean_file="${file%.apk.apks}.apks"; fi
        echo "Renaming locally: $(basename "$file") -> $(basename "$clean_file")"
        mv "$file" "$clean_file"
        file="$clean_file"
    fi

    filename=$(basename "$file")
    pkg_name="${filename%%-*}"
    
    echo "------------------------------------------------"
    echo "Checking $filename for release $pkg_name..."
    
    # Fetch release data
    if release_data=$(gh release view "$pkg_name" --repo "$TARGET_REPO" --json assets 2>/dev/null); then
        # Check if a buggy legacy asset exists remotely
        for buggy_ext in ".apk.apkm" ".apk.xapk" ".apk.apks"; do
            faulty_name="${filename%.*}${buggy_ext}"
            if [[ "$faulty_name" == *.apkm.apk.apkm ]]; then faulty_name="${filename%.apkm}.apk.apkm"; fi
            if [[ "$faulty_name" == *.xapk.apk.xapk ]]; then faulty_name="${filename%.xapk}.apk.xapk"; fi
            if [[ "$faulty_name" == *.apks.apk.apks ]]; then faulty_name="${filename%.apks}.apk.apks"; fi

            if echo "$release_data" | jq -e ".assets[] | select(.name == \"$faulty_name\")" > /dev/null 2>&1; then
                echo " -> Found BUGGY remote asset: $faulty_name. Deleting..."
                asset_id=$(echo "$release_data" | jq -e -r ".assets[] | select(.name == \"$faulty_name\") | .id")
                if [ -n "$asset_id" ]; then
                    gh api -X DELETE "repos/${TARGET_REPO}/releases/assets/${asset_id}" || true
                    echo " -> Successfully deleted buggy asset!"
                fi
            fi
        done

        # Check if correct asset already exists
        if echo "$release_data" | jq -e ".assets[] | select(.name == \"$filename\")" > /dev/null 2>&1; then
            echo " -> Asset $filename already exists on GitHub. Skipping!"
            continue
        fi
        
        echo " -> Uploading clean asset to existing release..."
        gh release upload "$pkg_name" "$file" --repo "$TARGET_REPO" --clobber || true
    else
        echo " -> Release $pkg_name does not exist. Creating and uploading..."
        gh release create "$pkg_name" "$file" --repo "$TARGET_REPO" --title "$pkg_name" --notes "" || true
    fi
done

echo "------------------------------------------------"
echo "Cache sanitization and sync complete!"
