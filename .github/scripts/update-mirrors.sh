#!/bin/bash
set -euo pipefail

# Update mirrors.md with new build links
# Usage: update-mirrors.sh <release_number> <release_type> <buzz_link> <filebin_link> <github_repo>

RELEASE_NUM="${1:?Release number required}"
RELEASE_TYPE="${2:-}"  # Optional, e.g., " (Pre-release)" or ""
BUZZ_LINK="${3:-}"
FILEBIN_LINK="${4:-}"
GITHUB_REPO="${5:?GitHub repository required}"

# Source shared config
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh" || { echo "❌ Failed to source config.sh"; exit 1; }

# Validate required config variables
if [ -z "${MIRRORS_DIR:-}" ] || [ -z "${MIRRORS_FILE:-}" ] || [ -z "${MAX_BUILDS:-}" ]; then
  echo "❌ Required config variables not set"
  exit 1
fi

mkdir -p "$MIRRORS_DIR"

if [ ! -f "$MIRRORS_FILE" ]; then
  echo "# 🗃️ Mirrors" > "$MIRRORS_FILE"
  echo "Updated automatically. Only recent $MAX_BUILDS builds retained." >> "$MIRRORS_FILE"
  echo "" >> "$MIRRORS_FILE"
fi

if [ -z "$RELEASE_NUM" ]; then
  echo "⚠️ No release number — skipping mirror update"
  exit 0
fi

ENTRY="## Build No. $RELEASE_NUM${RELEASE_TYPE}  \n"
if [ -n "$BUZZ_LINK" ]; then
  ENTRY+="🔗 [BuzzHeavier]($BUZZ_LINK)  \n"
fi
if [ -n "$FILEBIN_LINK" ]; then
  ENTRY+="🔗 [Filebin]($FILEBIN_LINK)  \n"
fi
if [ -z "$BUZZ_LINK" ] && [ -z "$FILEBIN_LINK" ]; then
  ENTRY+="⚠️ No mirrors available. Check [GitHub Release](https://github.com/$GITHUB_REPO/releases/tag/$RELEASE_NUM).  \n"
fi
ENTRY+="\n"

# Create new file with: header + new entry + old entries (limited to keep MAX_BUILDS total)
{
  # Keep header (first 3 lines)
  head -n 3 "$MIRRORS_FILE"
  # Add new entry
  echo -e "$ENTRY"
  # Add old entries (skip first 3 lines), keep only (MAX_BUILDS-1) blocks
  tail -n +4 "$MIRRORS_FILE" | awk -v max=$((MAX_BUILDS - 1)) '/^## Build No\./ { 
    if (block_count >= max) { exit }
    block_count++
  }
  block_count <= max { print }'
} > "$MIRRORS_FILE.tmp" && mv "$MIRRORS_FILE.tmp" "$MIRRORS_FILE"

echo "✅ Updated mirrors.md with Build No. $RELEASE_NUM"
