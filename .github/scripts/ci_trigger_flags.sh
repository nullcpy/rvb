#!/bin/bash
set -euo pipefail

# Classify the watcher's trigger flags into the two questions every later step
# actually asks. Before this, the same boolean expressions were pasted into four
# separate `if:` clauses in ci.yml, so adding a trigger type meant hunting them
# all down - and the copies were free to drift.
#
#   SOURCES_CHANGED  a patch source published a new release: worth running the
#                    per-app patch relevance scan, which downloads bundles.
#   ANYTHING_CHANGED SOURCES_CHANGED, or an app's own APK updated, or a source
#                    got blocked/unblocked: enough to reshape the generated
#                    configs, so regenerate, notify and commit.
#
# The per-channel flags stay owned by their producers: ci_generate_configs.sh
# reads TRIGGER_STABLE/TRIGGER_BETA to pick which pool to rebuild, and
# ci_resolve_triggers.sh turns them into the effective build triggers once the
# pools exist. This step only answers "is there any work left downstream".
#
# Written with explicit `if` blocks rather than `[ .. ] || [ .. ] && assign`
# lists on purpose: under set -e a short-circuit list whose final command never
# runs exits non-zero, which would kill this step before it wrote its outputs
# and silently turn every dependent step into a no-op.

TRIGGER_STABLE=${TRIGGER_STABLE:-0}
TRIGGER_BETA=${TRIGGER_BETA:-0}
TRIGGER_BLOCKED=${TRIGGER_BLOCKED:-0}
TRIGGER_APP_UPDATE=${TRIGGER_APP_UPDATE:-0}

sources_changed=0
anything_changed=0

if [ "$TRIGGER_STABLE" = "1" ] || [ "$TRIGGER_BETA" = "1" ]; then
  sources_changed=1
fi

if [ "$sources_changed" = "1" ] || [ "$TRIGGER_BLOCKED" = "1" ] || [ "$TRIGGER_APP_UPDATE" = "1" ]; then
  anything_changed=1
fi

{
  echo "SOURCES_CHANGED=$sources_changed"
  echo "ANYTHING_CHANGED=$anything_changed"
} >> "$GITHUB_OUTPUT"
