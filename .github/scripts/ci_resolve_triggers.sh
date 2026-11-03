#!/bin/bash
set -euo pipefail

# Resolve which build pools this run actually starts, one channel at a time.
#
# Every flag below is shared between the channels except RAW_TRIGGER_STABLE and
# RAW_TRIGGER_BETA, which come from the patch-source sync and already name their
# channel. Sharing the rest is what let a maintainer's edit to a STABLE app wake the
# BETA pool: run 41590950846 removed an architecture field from Xiaomi Screen
# Recorder (stable), which raised TRIGGER_CONFIG_CHANGE, and the beta branch treated
# that as its own reason - so Google Keyboard and its clone were re-patched from
# cache, the content-hash gate called both "Unchanged build", nothing was published,
# and the queue notice announced apps that had no reason to be built. A pool now
# wakes only on a reason that belongs to it; membership, not a global flag, decides
# which pool an event concerns. The pools still regenerate on the shared flags
# (ci_generate_configs.sh reconsiders membership per app key), because reconsidering
# is free and building is not.
#
# A pending new/retry item remains a reason to build on its own: it reaches the
# ENABLED_COUNT check (which is now > 0 because ci_generate_configs force-enables the
# pending keys) even when no source or app version moved - for the channel that
# holds the entry.
#
# Env: RAW_TRIGGER_STABLE RAW_TRIGGER_BETA RAW_TRIGGER_APP_UPDATE
#      RAW_TRIGGER_CONFIG_CHANGE (each 0/1), GITHUB_OUTPUT.
# Reads from the run's working directory, written by the steps that run before this
# one in the same job:
#   configs/<channel>_build.json                      the regenerated pools
#   pending.<channel>.json new_apps.json changed_apps.json
#                                                     ci_detect_config_changes.sh, per channel
#   active_apps.json                                  ci_compare_app_versions.sh, app keys whose
#                                                     group moved up in a store

RAW_TRIGGER_STABLE=${RAW_TRIGGER_STABLE:-0}
RAW_TRIGGER_BETA=${RAW_TRIGGER_BETA:-0}
RAW_TRIGGER_APP_UPDATE=${RAW_TRIGGER_APP_UPDATE:-0}
RAW_TRIGGER_CONFIG_CHANGE=${RAW_TRIGGER_CONFIG_CHANGE:-0}

TRIGGER_STABLE=0
TRIGGER_BETA=0

# state_count <channel> — how many entries this channel's own reconciliation left
# behind: carried-over or re-armed pending items, apps added this run, and apps whose
# tracked config moved. The detector keeps each of those lists keyed by channel, so an
# edit to a stable app contributes nothing to the beta count.
state_count() {
	local ch="$1" n=0 out
	if [ -f "pending.$ch.json" ]; then
		out=$(jq 'length' "pending.$ch.json" 2>/dev/null || echo 0)
		n=$((n + ${out:-0}))
	fi
	for f in new_apps.json changed_apps.json; do
		if [ -f "$f" ]; then
			out=$(jq --arg c "$ch" '(.[$c] // []) | length' "$f" 2>/dev/null || echo 0)
			n=$((n + ${out:-0}))
		fi
	done
	echo "$n"
}

# updated_key_in_pool <config-file> — did a store report a version move for a group
# that has a key in this pool? A group spans both channels when the same app is built
# from both pools, so the intersection decides which pool the update is a reason for;
# the shared flag alone decides nothing.
updated_key_in_pool() {
	local cfg="$1"
	[ -f active_apps.json ] && [ -f "$cfg" ] || return 1
	jq -e -n --slurpfile act active_apps.json --slurpfile pool "$cfg" \
		'any($act[0][]; . as $k | $pool[0] | has($k))' >/dev/null 2>&1
}

# channel_has_reason <channel> <raw per-channel flag> — does THIS pool have a reason
# to build this run? Returns through the exit status so callers read as plainly as the
# original `if` blocks; every test is short-circuited inside an `if`, never as a
# `[ .. ] && ..` list that could abort the step under set -e.
channel_has_reason() {
	local ch="$1" raw="$2"
	if [ "$raw" = "1" ]; then
		return 0
	fi
	if [ "$RAW_TRIGGER_CONFIG_CHANGE" = "1" ] && [ "$(state_count "$ch")" -gt 0 ]; then
		return 0
	fi
	if [ "$RAW_TRIGGER_APP_UPDATE" = "1" ] && updated_key_in_pool "configs/${ch}_build.json"; then
		return 0
	fi
	return 1
}

if channel_has_reason stable "$RAW_TRIGGER_STABLE"; then
	CFG="configs/stable_build.json"
	if [ -f "$CFG" ]; then
		ENABLED_COUNT=$(jq '[.[] | objects | select(.enabled != false)] | length' "$CFG" || echo 0)
		if [ "${ENABLED_COUNT:-0}" -gt 0 ]; then
			TRIGGER_STABLE=1
		else
			echo "::notice::Skipping stable build trigger: no enabled apps in $CFG"
		fi
	fi
fi

if channel_has_reason beta "$RAW_TRIGGER_BETA"; then
	CFG="configs/beta_build.json"
	if [ -f "$CFG" ]; then
		ENABLED_COUNT=$(jq '[.[] | objects | select(.enabled != false)] | length' "$CFG" || echo 0)
		if [ "${ENABLED_COUNT:-0}" -gt 0 ]; then
			TRIGGER_BETA=1
		else
			echo "::notice::Skipping beta build trigger: no enabled apps in $CFG"
		fi
	fi
fi

echo "TRIGGER_STABLE=$TRIGGER_STABLE" >>"$GITHUB_OUTPUT"
echo "TRIGGER_BETA=$TRIGGER_BETA" >>"$GITHUB_OUTPUT"
