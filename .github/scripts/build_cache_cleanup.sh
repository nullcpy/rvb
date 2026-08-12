#!/bin/bash
set -euo pipefail

# Cache cleanup script to prevent temp/apks from ballooning across CI runs
# Uses a Tiered Watermark Eviction Strategy to maximize cache hit rates
# while staying safely below GitHub's 10GB total repository cache limit.

APK_CACHE_DIR="temp/apks"
# Set limit to 8 GB (8 * 1024 * 1024 * 1024 bytes)
MAX_SIZE_BYTES=$((8 * 1024 * 1024 * 1024))
RETENTION_TIERS=(30 14 7 3)

if [ ! -d "$APK_CACHE_DIR" ]; then
    echo "Cache directory $APK_CACHE_DIR does not exist yet. Skipping cleanup."
    exit 0
fi

# Function to get current size in bytes
get_size() {
    du -sb "$APK_CACHE_DIR" | cut -f1
}

current_size=$(get_size)

if [ "$current_size" -lt "$MAX_SIZE_BYTES" ]; then
    echo "Cache size is currently $current_size bytes (under 8GB). No cleanup needed!"
    exit 0
fi

echo "Cache size ($current_size bytes) exceeds 8GB limit! Initiating tiered cleanup..."

for days in "${RETENTION_TIERS[@]}"; do
    echo "Evicting APKs older than $days days..."
    
    deleted=$(find "$APK_CACHE_DIR" -type f \( -name "*.apk" -o -name "*.apkm" -o -name "*.xapk" -o -name "*.apks" \) -mtime +$days -print -delete)
    
    if [ -n "$deleted" ]; then
        echo "Deleted the following outdated cached files:"
        echo "$deleted"
    else
        echo "No files older than $days days found."
    fi
    
    current_size=$(get_size)
    if [ "$current_size" -lt "$MAX_SIZE_BYTES" ]; then
        echo "Cache size successfully reduced to $current_size bytes. Stopping cleanup."
        exit 0
    fi
done

echo "Cache size is still $current_size bytes even after maximum cleanup."
