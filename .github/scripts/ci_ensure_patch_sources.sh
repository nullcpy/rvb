#!/bin/bash
set -euo pipefail
mkdir -p .github/configs
PATCH_FILE=".github/configs/patch_sources.json"

if [ ! -f "$PATCH_FILE" ]; then
  cat > "$PATCH_FILE" << 'EOF'
{
  "dummy_patch": { "enabled": false, "repo": "" }
}
EOF
  echo "created=true" >> "$GITHUB_OUTPUT"
else
  echo "created=false" >> "$GITHUB_OUTPUT"
fi
