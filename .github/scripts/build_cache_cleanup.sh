#!/bin/bash
set -euo pipefail

# Cache cleanup script to prevent temp/apks from ballooning across CI runs
# Retains APKs that have been modified (or touched) in the last 30 days

APK_CACHE_DIR="temp/apks"
RETENTION_DAYS=30

if [ -d "$APK_CACHE_DIR" ]; then
    echo "Scanning $APK_CACHE_DIR for APKs older than $RETENTION_DAYS days..."
    
    # Use find to locate files older than RETENTION_DAYS days and delete them
    # -mtime +N matches files modified strictly greater than N*24 hours ago
    deleted_files=$(find "$APK_CACHE_DIR" -type f -name "*.apk" -mtime +$RETENTION_DAYS -print -delete)
    
    if [ -n "$deleted_files" ]; then
        echo "Deleted the following outdated cached APKs:"
        echo "$deleted_files"
    else
        echo "No APKs older than $RETENTION_DAYS days found."
    fi
else
    echo "Cache directory $APK_CACHE_DIR does not exist yet. Skipping cleanup."
fi
