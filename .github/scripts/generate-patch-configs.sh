#!/bin/bash
set -e

# Source config with validation
if [[ ! -f .github/scripts/config.sh ]]; then
  echo "❌ config.sh not found"
  exit 1
fi

source .github/scripts/config.sh

# Validate required variables
for var in CONFIG_STABLE CONFIG_DEV CONFIG_STABLE_UPDATED CONFIG_DEV_UPDATED ACTIVE_PRERELEASE_TXT ACTIVE_STABLE_TXT; do
  if [[ -z "${!var}" ]]; then
    echo "❌ Required variable $var not set in config.sh"
    exit 1
  fi
done

# Ensure we're in repo root
cd "$(git rev-parse --show-toplevel)"

# Function to generate modified config
# Arguments: input_config, active_repos_file, output_config
generate_config() {
  local input_config="$1"
  local active_repos_file="$2"
  local output_config="$3"

  # Check if input config exists
  if [[ ! -f "$input_config" ]]; then
    echo "❌ Input config not found: $input_config"
    return 1
  fi

  # Read active repos into an associative array
  declare -A active_repos
  if [[ -f "$active_repos_file" ]]; then
    while IFS= read -r repo; do
      [[ -n "$repo" ]] && active_repos["$repo"]=1
    done < "$active_repos_file"
  fi

  # Process config line by line
  {
    local current_section=""
    local current_patches_source=""
    local enabled_value="false"
    
    while IFS= read -r line; do
      # Detect section header: [SectionName]
      if [[ "$line" =~ ^\[[^[].*\]$ ]]; then
        current_section="$line"
        current_patches_source=""
        enabled_value="false"
        echo "$line"
        continue
      fi

      # Extract patches-source value and track it
      if [[ "$line" =~ ^patches-source[[:space:]]*= ]]; then
        echo "$line"
        # Extract the value between quotes: patches-source = "some/repo"
        current_patches_source=$(echo "$line" | sed -n 's/^patches-source[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p')
        # Determine if we should enable based on whether this repo is in active list
        if [[ -n "$current_patches_source" && -n "${active_repos[$current_patches_source]}" ]]; then
          enabled_value="true"
        else
          enabled_value="false"
        fi
        continue
      fi

      # Replace enabled field with the correct value
      if [[ "$line" =~ ^enabled[[:space:]]*= ]]; then
        echo "enabled = $enabled_value"
        continue
      fi

      # Output all other lines as-is
      echo "$line"
    done < "$input_config"
  } > "$output_config"

  return 0
}

# Generate configs
echo "📝 Generating stable config..."
if ! generate_config "$CONFIG_STABLE" "$ACTIVE_STABLE_TXT" "$CONFIG_STABLE_UPDATED"; then
  echo "❌ Failed to generate stable config"
  exit 1
fi

echo "📝 Generating dev config..."
if ! generate_config "$CONFIG_DEV" "$ACTIVE_PRERELEASE_TXT" "$CONFIG_DEV_UPDATED"; then
  echo "❌ Failed to generate dev config"
  exit 1
fi

echo "✅ Config generation complete"
echo "  Stable config:     $CONFIG_STABLE_UPDATED"
echo "  Dev config:        $CONFIG_DEV_UPDATED"
