#!/bin/bash
# ci_detect_config_changes.sh — the watcher's reconciliation for ADR 0010.
#
# Runs in check_patch after the base configs compile and the app-version compare,
# before ci_trigger_flags.sh. It answers one question per channel: "has the config
# changed relative to what we last built, and is anything still owed a build?" and
# turns that into an actionable pending list the pool generator force-enables.
#
#   * a brand-new app, or a newly requested arch for a known app (arch not in
#     built_shape) -> enqueue reason "new" so the next build picks it up even
#     though no patch source or app version moved (the _check_only_listed throttle
#     means a new app would otherwise never be fetched or triggered).
#   * a tracked field of an app that is already built moved — `build-mode`,
#     `patches-source`, a pin, the patch selection, anything in
#     `retry_tracked_keys` — -> enqueue `reason: "config"` and record the field diff
#     in changed_apps.json. built_shape stores each app's last-built tracked map for
#     exactly this, because arch equality is not config equality: publishing
#     `build-mode = "both"` over an app that shipped an APK built nothing new, and the
#     pool left it disabled (why: decisions/0014).
#   * an app removed from the config, or a failed arch no longer requested ->
#     prune it from the pending list (MacroDroid both -> arm64-v8a drops its
#     arm-v7a retry). A key the config no longer lists is unreachable from here on
#     — this loop only visits present apps, and the build job skips a disabled one —
#     so it would sit in the queue forever and keep firing TRIGGER_CONFIG_CHANGE.
#     Pruning covers the queue ONLY: built_shape records that the artifact was
#     built, and it still was, so disabling an app and re-enabling it is not a new
#     build request unless its own config changed (ADR 0010).
#   * a pending entry already recorded by the build job (reason "retry") is left
#     alone as to its budget - attempts/parked belong to the build job - except for
#     arch pruning, and except for the re-arm: when the app's OWN compiled entry
#     changed since the entry was written (its `cfg` fingerprint differs), the
#     maintainer has acted on the thing that failed, so attempts reset to 0 and a
#     parked entry is queued again (ADR 0010). An entry with no `cfg` predates the
#     field: it gets a baseline recorded, and only a parked one is also re-armed,
#     so a live retry never loses its count to a missing baseline.
#
# Cold start: built_shape is empty the first time this runs after the feature
# lands. Without a guard every app would look "new" and the whole pool would be
# force-built, so the first run per channel SEEDS built_shape to the current
# config and enqueues nothing; only apps/arches added afterwards are treated as
# new. The seed is persisted by flagging TRIGGER_CONFIG_CHANGE so the watcher's
# commit step runs — the flag means "the watcher's state moved", and a run only
# starts if the resulting pool has an enabled app to build.
#
# Env: GITHUB_OUTPUT (writes TRIGGER_CONFIG_CHANGE=0/1). Writes
# pending.stable.json, pending.beta.json, new_apps.json and changed_apps.json.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=retry_lib.sh
source "$SCRIPT_DIR/retry_lib.sh"

BS_FILE="state/built_shape.json"
PB_FILE="state/pending_builds.json"

bs=$(retry_load "$BS_FILE")
pb=$(retry_load "$PB_FILE")
bs_orig="$bs"
pb_orig="$pb"
trigger=0
# Apps newly enqueued THIS run (not carried-over retries), per channel, for the
# "new apps added" notification. Written to new_apps.json at the end.
newjson='{"stable":[],"beta":[]}'
# Apps enqueued (or re-queued) because their tracked config moved, with the field
# diff that proves it: {channel: {app: [{field, from, to}]}}. Written to
# changed_apps.json; the announcement reads it, so it carries no rendering rules.
changedjson='{"stable":{},"beta":{}}'
# The tracked key set, resolved once per run and handed to retry_effective_cfg so the
# per-app map does not re-derive it (two jq spawns saved for every one of 225 apps).
tracked_json=$(retry_tracked_keys | jqx -R . | jqx -sc .)

# to_arr <space-separated tokens> -> sorted, unique JSON array. LC_ALL=C keeps the
# order byte-stable ("arm-v7a" before "arm64-v8a") regardless of the runner locale.
to_arr() {
	if [ -z "${1:-}" ]; then
		printf '[]'
	else
		# shellcheck disable=SC2086
		printf '%s\n' $1 | LC_ALL=C sort -u | jqx -R . | jqx -sc .
	fi
}

process_channel() { # $1=channel $2=config-file
	local ch=$1 cfg=$2
	[ -f "$cfg" ] || return 0

	local apps cfg_count bs_count first_run key want want_arr bs_arr pend_json pend_arches kept need added fp rearmed present gone
	local have_cfg want_cfg cdiff cdiff_other cfg_known want_k have_k widened widened_list moved prev_cfg change_msg
	local is_new wake
	apps=$(retry_list_apps "$cfg")
	cfg_count=$(printf '%s\n' "$apps" | grep -c . || true)
	bs_count=$(jqx -r --arg c "$ch" '(.[$c] // {}) | length' <<<"$bs")

	# Drop queue entries for apps this channel no longer lists. The write still has
	# to be committed (see the flag's double role at the foot of this file), but it
	# enqueues nothing, so no build follows from it alone.
	present=$(printf '%s' "$apps" | jqx -Rs 'split("\n") | map(select(length > 0)) | unique')
	gone=$(jqx -r --arg c "$ch" --argjson have "$present" \
		'(.[$c] // {}) | keys_unsorted[] | . as $k | select($have | index($k) | not)' <<<"$pb")
	if [ -n "$gone" ]; then
		while IFS= read -r key; do
			[ -z "$key" ] && continue
			echo "Pruned stale pending entry '$key' ($ch): the config no longer lists it."
			pb=$(jqx -c --arg c "$ch" --arg k "$key" 'del(.[$c][$k])' <<<"$pb")
		done <<<"$gone"
	fi

	# Cold start for this channel: nothing built yet but the config has apps.
	if [ "${bs_count:-0}" -eq 0 ] && [ "${cfg_count:-0}" -gt 0 ]; then
		first_run=1
	else
		first_run=0
	fi

	if [ "$first_run" = 1 ]; then
		# Seed built_shape to the current config shape and enqueue nothing. The
		# tracked map is seeded alongside the arches for exactly the reason the arch
		# list is: an empty file must not make 200 apps look newly requested.
		local seed="{}" wmap
		while IFS= read -r key; do
			[ -z "$key" ] && continue
			want=$(retry_effective_arch "$cfg" "$key")
			want_arr=$(to_arr "$want")
			wmap=$(retry_effective_cfg "$cfg" "$key" "$tracked_json")
			seed=$(jqx -c --arg k "$key" --argjson a "$want_arr" --argjson m "$wmap" \
				'.[$k] = {arches: $a, cfg: $m}' <<<"$seed")
		done <<<"$apps"
		bs=$(jqx -c --arg c "$ch" --argjson s "$seed" '.[$c] = $s' <<<"$bs")
		return 0
	fi

	while IFS= read -r key; do
		[ -z "$key" ] && continue
		want=$(retry_effective_arch "$cfg" "$key")
		want_arr=$(to_arr "$want")
		bs_arr=$(retry_shape_arches "$ch" "$key" "$bs")

		# Does the tracked part of this app's config differ from the config its last
		# successful build was produced from? A map the entry does not carry is not an
		# empty diff: it is NO EVIDENCE, and guessing from the current config would
		# forgive every edit published before the seed landed.
		have_cfg=$(retry_shape_cfg "$ch" "$key" "$bs")
		want_cfg=$(retry_effective_cfg "$cfg" "$key" "$tracked_json")
		cdiff='[]'
		cdiff_other='[]'
		moved=0
		cfg_known=true
		# One human sentence per woken app, shared by the log line and the announcement.
		# Built here because this is the only place that knows both the tracked-field diff
		# and the artifact delta; an empty diff is a real state (the fields match the last
		# build while the queue still owes artifacts) and must not print as a bare colon.
		change_msg=""
		widened_list=""
		if [ "$have_cfg" = '"NONE"' ]; then
			cfg_known=false
			change_msg="no last-built baseline to compare against yet"
		else
			cdiff=$(jqx -cn --argjson a "$have_cfg" --argjson b "$want_cfg" '
				[ ($a | keys_unsorted[]), ($b | keys_unsorted[]) ] | unique
				| map(. as $f | {field: $f, from: ($a[$f] // null), to: ($b[$f] // null)})
				| map(select(.from != .to))')
			cdiff_other=$(printf '%s' "$cdiff" | jqx -c \
				'map(select((.field != "arch") and (.field != "build-mode")))')
			# WIDENING, not difference. A `both -> apk` edit asks for fewer artifacts than
			# the last build produced; no rebuild can un-publish the module it dropped, and
			# re-running it would only re-derive an APK that already matches its published
			# fingerprint. Any other tracked key is a difference in kind, not in size — a
			# new source, a new pin, a changed patch selection — so it always counts.
			want_k=$(to_arr "$(retry_effective_kinds "$cfg" "$key")")
			have_k=$(to_arr "$(retry_shape_kinds "$ch" "$key" "$bs")")
			widened_list=$(jqx -rn --argjson wa "$want_arr" --argjson wk "$want_k" \
				--argjson ha "$bs_arr" --argjson hk "$have_k" '
					[ $wa[] as $a | $wk[] as $k | "\($a):\($k)"] -
					[ $ha[] as $a | $hk[] as $k | "\($a):\($k)"] | join(", ")')
			widened=$(jqx -cn --argjson wa "$want_arr" --argjson wk "$want_k" \
				--argjson ha "$bs_arr" --argjson hk "$have_k" '
					[ $wa[] as $a | $wk[] as $k | "\($a):\($k)"] -
					[ $ha[] as $a | $hk[] as $k | "\($a):\($k)"] | length')
			moved=0
			if [ "${widened:-0}" -gt 0 ] || [ "$cdiff_other" != "[]" ]; then
				moved=1
			fi
			# Tracked fields identical to the last build yet artifacts still owed is the
			# common case for an app whose earlier attempt never got past the download, so
			# the name has to say what is owed instead of printing an empty diff after the
			# colon (the run that showed it: 41590950846, Xiaomi Screen Recorder).
			change_msg=$(printf '%s' "$cdiff" | jqx -r 'map("\(.field): \(.from // "-") -> \(.to // "-")") | join(", ")')
			if [ -z "$change_msg" ]; then
				if [ -n "$widened_list" ]; then
					change_msg="no tracked field differs from the last-built baseline; still owed: $widened_list"
				else
					change_msg="no tracked field differs from the last-built baseline"
				fi
			fi
		fi

		pend_json=$(jqx -c --arg c "$ch" --arg k "$key" '.[$c][$k]' <<<"$pb")
		if [ "$pend_json" = "null" ]; then
			# Not already queued: arches never built, and/or a tracked field that moved.
			need=$(jqx -cn --argjson want "$want_arr" --argjson have "$bs_arr" '$want - $have')
			added=$(jqx -r 'length' <<<"$need")
			# A brand-new app and an existing app asking for one more arch are different
			# events that used to wear the same clothes: only the first is an addition
			# anybody should hear about as a new app.
			is_new=$(jqx -r --arg c "$ch" --arg k "$key" '((.[$c][$k] // null) == null)' <<<"$bs")
			if [ "$is_new" = "true" ] && [ "${added:-0}" -gt 0 ]; then
				fp=$(retry_fingerprint "$cfg" "$key")
				pb=$(jqx -c --arg c "$ch" --arg k "$key" --argjson a "$need" --arg fp "$fp" \
					'.[$c][$k] = {reason:"new", arches:$a, attempts:0, parked:false, cfg:$fp}' <<<"$pb")
				newjson=$(jqx -c --arg c "$ch" --arg k "$key" '(.[$c] // []) += [$k]' <<<"$newjson")
				trigger=1
			elif [ "${added:-0}" -gt 0 ]; then
				# An existing app asking for an arch it has never produced is a widening,
				# not an addition: queue just the missing arches and name the delta in the
				# notice, expanded to concrete ABIs like every other arch value in this
				# message rather than left as the raw `both`/`auto` keyword.
				wake=$(jqx -cn \
					--arg from "$(printf '%s' "$bs_arr" | jqx -r 'join(", ")')" \
					--arg to "$(printf '%s' "$want_arr" | jqx -r 'join(", ")')" \
					'[{field:"arch", from:$from, to:$to}]')
				fp=$(retry_fingerprint "$cfg" "$key")
				pb=$(jqx -c --arg c "$ch" --arg k "$key" --argjson a "$need" --arg fp "$fp" \
					'.[$c][$k] = {reason:"config", arches:$a, attempts:0, parked:false, cfg:$fp}' <<<"$pb")
				changedjson=$(jqx -c --arg c "$ch" --arg k "$key" --argjson d "$wake" \
					'(.[$c] // {})[$k] = $d' <<<"$changedjson")
				echo "Arch widening for '$key' ($ch): $(printf '%s' "$wake" | jqx -r 'map("\(.field): \(.from) -> \(.to)") | join(", ")')"
				trigger=1
			elif [ "$cfg_known" != true ]; then
				# No baseline yet: take the current one and ask for nothing. This is the
				# per-app cold-start guard, and the reason the one-shot seed reads published
				# artifacts instead — see decisions/0014.
				bs=$(jqx -c --arg c "$ch" --arg k "$key" --argjson m "$want_cfg" '
					.[$c][$k] = ((.[$c][$k] // []) | if type == "array"
						then {arches: ., cfg: $m} else . + {cfg: $m} end)' <<<"$bs")
				echo "Recorded the tracked config for '$key' ($ch); nothing to build."
			elif [ "$moved" = 1 ]; then
				# The order changed but no arch did — the `build-mode` / `patches-source`
				# / pin edit that used to vanish. Force the app the same way a new arch
				# does, and keep the baseline where it is: only a build that actually
				# produced the artifacts may advance it, or a failing rebuild would be
				# forgiven and the change forgotten.
				fp=$(retry_fingerprint "$cfg" "$key")
				pb=$(jqx -c --arg c "$ch" --arg k "$key" --argjson a "$want_arr" --arg fp "$fp" \
					'.[$c][$k] = {reason:"config", arches:$a, attempts:0, parked:false, cfg:$fp}' <<<"$pb")
				changedjson=$(jqx -c --arg c "$ch" --arg k "$key" --argjson d "$cdiff" \
					'(.[$c] // {})[$k] = $d' <<<"$changedjson")
				echo "Config change for '$key' ($ch): $change_msg"
				trigger=1
			fi
		else
			# Already queued: prune arches the config no longer requests.
			pend_arches=$(jqx -c '.arches' <<<"$pend_json")
			kept=$(jqx -cn --argjson pa "$pend_arches" --argjson want "$want_arr" '$pa - ($pa - $want)')
			if [ "$(jqx -r 'length' <<<"$kept")" -eq 0 ]; then
				pb=$(jqx -c --arg c "$ch" --arg k "$key" 'del(.[$c][$k])' <<<"$pb")
				trigger=1
			elif [ "$kept" != "$pend_arches" ]; then
				pb=$(jqx -c --arg c "$ch" --arg k "$key" --argjson a "$kept" '.[$c][$k].arches = $a' <<<"$pb")
				trigger=1
			fi
			# The fingerprint the entry was written under, kept before anything
			# refreshes it: this is what tells an edit noticed for the first time from
			# the same edit being re-announced on every later run.
			prev_cfg=$(jqx -r --arg c "$ch" --arg k "$key" '(.[$c][$k].cfg // "")' <<<"$pb")
			# Re-arm (ADR 0010): the entry describes an order placed under a previous
			# config, so ask whether that config still exists. Three cases, and only two
			# of them touch a budget:
			#   `cfg` differs from this app's current fingerprint -> the config moved (a
			#   new source, dlurl or pin), so what failed is not what is being asked for:
			#   attempts reset and the park lifts.
			#   `cfg` absent -> the entry predates the fingerprint. Record it, and lift a
			#   PARKED entry once (a decision the pipeline gave up on gets one fresh
			#   chance now that the engine changed). A live entry keeps its count: were
			#   it reset here, the cap could never be reached and every failure would
			#   retry forever - the exact churn this mechanism exists to stop.
			#   unchanged -> no write at all, so the state file stays byte-identical.
			fp=$(retry_fingerprint "$cfg" "$key")
			rearmed=$(jqx -c --arg c "$ch" --arg k "$key" --arg fp "$fp" '
				if (.[$c][$k] // null) == null then .
				elif (.[$c][$k].cfg // "") == "" then
					if .[$c][$k].parked == true then
						.[$c][$k] |= (.attempts = 0 | .parked = false | .cfg = $fp)
					else .[$c][$k].cfg = $fp end
				elif .[$c][$k].cfg != $fp then
					.[$c][$k] |= (.attempts = 0 | .parked = false | .cfg = $fp)
				else . end' <<<"$pb")
			if [ "$rearmed" != "$pb" ]; then
				# Only a budget change is worth announcing as work queued. Recording a
				# baseline changes the file without changing any app's budget, so it does
				# not touch `trigger` here — the write is persisted by the flag's second
				# role at the foot of this file, and it starts no run because it enables
				# nothing in the pool.
				if [ "$(jqx -c --arg c "$ch" --arg k "$key" '.[$c][$k] | {attempts, parked}' <<<"$pb")" != \
					"$(jqx -c --arg c "$ch" --arg k "$key" '.[$c][$k] | {attempts, parked}' <<<"$rearmed")" ]; then
					echo "Re-armed '$key' ($ch): its config changed since this entry was written (attempts reset, park lifted)."
					trigger=1
				fi
				# Announce only when this run is the one that noticed. The entry keeps a
				# widened app in the pool on every later run, so announcing on `moved`
				# alone would repeat one edit on the announcement topic until the build
				# finally ran — and the notice would stop meaning "something changed just
				# now". A stale entry fingerprint is exactly that first noticing. An entry
				# with no fingerprint predates it, so there is nothing to compare and
				# nothing to claim.
				if [ "$moved" = 1 ] && [ -n "$prev_cfg" ] && [ "$prev_cfg" != "$fp" ]; then
					changedjson=$(jqx -c --arg c "$ch" --arg k "$key" --argjson d "$cdiff" \
						'(.[$c] // {})[$k] = $d' <<<"$changedjson")
					echo "Config change for '$key' ($ch): $change_msg"
				fi
				pb=$rearmed
			fi
		fi
	done <<<"$apps"
}

process_channel stable config.stable.json
process_channel beta config.beta.json

# A build must run whenever anything non-parked is still pending, even if this
# run changed nothing (a retry carried over from a previous run).
if [ "$(jqx -r '[.stable, .beta | to_entries[] | select(.value.parked != true)] | length' <<<"$pb")" -gt 0 ]; then
	trigger=1
fi

# Persist the seed/reconciliation even when nothing is pending: if the files
# changed this run, the commit step must fire so the baseline survives.
if [ "$bs" != "$bs_orig" ] || [ "$pb" != "$pb_orig" ]; then
	mkdir -p state
	# Values are carried compactly in the variables (that is what the comparisons
	# above are against); only the files get the canonical document layout every
	# other persisted JSON in this repo uses - see jsonfmt.py.
	jqx . <<<"$bs" >"$BS_FILE"
	jqx . <<<"$pb" >"$PB_FILE"
	# Either file moving has to reach `data`, and this flag is the only signal that
	# gets it there: the commit step is gated on ANYTHING_CHANGED, which this feeds.
	# The flag therefore has a double role — "the watcher's state moved", not "build
	# something" — and whether a run actually starts is decided downstream, by
	# ci_resolve_triggers.sh counting the enabled apps in the pool. A bookkeeping
	# write enables nothing, so it persists without buying a build; suppressing it
	# here would lose the write and leave the next run to repeat it forever.
	trigger=1
fi

# Pre-extract the non-parked pending keys per channel for the pool generator.
jqx -c '[.stable | to_entries[] | select(.value.parked != true) | .key]' <<<"$pb" >pending.stable.json
jqx -c '[.beta | to_entries[] | select(.value.parked != true) | .key]' <<<"$pb" >pending.beta.json

# The apps added THIS run, per channel, for ci_notify_announcements.sh (empty
# otherwise).
printf '%s\n' "$newjson" >new_apps.json

# And the apps whose tracked config moved, with the field diff to show for it.
# Written in the repo's canonical document layout like every other persisted JSON.
jqx . <<<"$changedjson" >changed_apps.json

if [ -n "${GITHUB_OUTPUT:-}" ]; then
	echo "TRIGGER_CONFIG_CHANGE=$trigger" >>"$GITHUB_OUTPUT"
fi
echo "Config-change reconciliation: TRIGGER_CONFIG_CHANGE=$trigger; pending stable=$(jqx -c '.stable | length' <<<"$pb"), beta=$(jqx -c '.beta | length' <<<"$pb"); config-changed stable=$(jqx -c '.stable | length' <<<"$changedjson"), beta=$(jqx -c '.beta | length' <<<"$changedjson")"
