#!/bin/bash
set -euo pipefail

# List of app prefixes to exclude from archive releases
EXCLUDED_APPS=(
  # Add any new apps you want to exclude to this list in the future
)

echo "Removing frequently updated apps from the build directory before archive upload..."

for app in "${EXCLUDED_APPS[@]}"; do
  echo "Excluding: $app"
  rm -f ./build/"$app"* 2>/dev/null || true
done
