#!/bin/bash
set -euo pipefail

RAW_TRIGGER_STABLE=${RAW_TRIGGER_STABLE:-0}
RAW_TRIGGER_BETA=${RAW_TRIGGER_BETA:-${RAW_TRIGGER_PRERELEASE:-0}}
RAW_TRIGGER_APP_UPDATE=${RAW_TRIGGER_APP_UPDATE:-0}

TRIGGER_STABLE=0
TRIGGER_BETA=0

if [ "$RAW_TRIGGER_STABLE" = "1" ] || [ "$RAW_TRIGGER_APP_UPDATE" = "1" ]; then
  CFG=".github/configs/config.stable.updated.json"
  if [ -f "$CFG" ]; then
    ENABLED_COUNT=$(jq '[.[] | objects | select(.enabled != false)] | length' "$CFG" || echo 0)
    if [ "${ENABLED_COUNT:-0}" -gt 0 ]; then
      TRIGGER_STABLE=1
    else
      echo "::notice::Skipping stable build trigger: no enabled apps in $CFG"
    fi
  fi
fi

if [ "$RAW_TRIGGER_BETA" = "1" ] || [ "$RAW_TRIGGER_APP_UPDATE" = "1" ]; then
  CFG=".github/configs/config.beta.updated.json"
  if [ -f "$CFG" ]; then
    ENABLED_COUNT=$(jq '[.[] | objects | select(.enabled != false)] | length' "$CFG" || echo 0)
    if [ "${ENABLED_COUNT:-0}" -gt 0 ]; then
      TRIGGER_BETA=1
    else
      echo "::notice::Skipping beta build trigger: no enabled apps in $CFG"
    fi
  fi
fi

echo "TRIGGER_STABLE=$TRIGGER_STABLE" >> "$GITHUB_OUTPUT"
echo "TRIGGER_BETA=$TRIGGER_BETA" >> "$GITHUB_OUTPUT"
echo "TRIGGER_PRERELEASE=$TRIGGER_BETA" >> "$GITHUB_OUTPUT"
