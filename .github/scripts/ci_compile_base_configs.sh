#!/bin/bash
set -euo pipefail

# Convert utils.sh to Unix line endings if needed
dos2unix utils.sh 2>/dev/null || true
source utils.sh

echo "--- Compiling base patch configs (JSON) ---"
STABLE_CONFIGS=$(find .github/configs/patches -name "*.toml" ! -name "*.dev.toml" | sort)
if [ -n "$STABLE_CONFIGS" ]; then
  # shellcheck disable=SC2086
  toml_merge_configs $STABLE_CONFIGS > config.stable.json
else
  echo "{}" > config.stable.json
fi

DEV_CONFIGS=$(find .github/configs/patches -name "*.toml" ! -name "*.stable.toml" | sort)
if [ -n "$DEV_CONFIGS" ]; then
  # shellcheck disable=SC2086
  toml_merge_configs $DEV_CONFIGS > config.dev.json
else
  echo "{}" > config.dev.json
fi

# Create a unified config for version fetching
jq -s 'add // {}' config.stable.json config.dev.json > config.all.json

echo "Base configs compiled successfully."
echo "Stable apps/keys: $(jq 'keys | length' config.stable.json)"
echo "Dev apps/keys:    $(jq 'keys | length' config.dev.json)"
echo "Total apps/keys:  $(jq 'keys | length' config.all.json)"
