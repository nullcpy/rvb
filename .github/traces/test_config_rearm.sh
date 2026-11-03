#!/usr/bin/env bash
# Functional regression tests for the ADR 0010 re-arm in ci_detect_config_changes.sh
# (and the fingerprint-preserving merge in build_update_retry_list.sh).
#
# The rule: a pending entry is an order placed under a particular config. When that
# app's own compiled entry changes, the failed build no longer describes the build
# being asked for, so attempts reset and a parked entry is queued again. Each
# acceptance here is paired with the refusal that makes it mean something: an
# unchanged config must NOT re-arm, a reordered-but-identical block must NOT re-arm,
# a re-armed entry must NOT re-arm again on the next run, and an app that left the
# config must lose its queue entry while its built_shape memory stays. The cases from
# 13 on belong to ADR 0014: a tracked config field must wake an app that is already
# built, a transport field must not, and a missing baseline must record itself
# silently rather than force-rebuild the pool.
#
# Drives the real watcher script (no stubs): it reads config.stable.json /
# config.beta.json and state/*.json from its cwd, so each case runs in its own
# sandbox tree. Nothing here touches the repo's own configs/ or state/.
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=../scripts/retry_lib.sh
source "$REPO/.github/scripts/retry_lib.sh"
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL: $*"; exit 1; }

# run_case <name> <config.stable.json> <pending_builds.json> <built_shape.json>
# leaves: CASE=<dir>, OUT_TRIGGER, OUT_PENDING, OUT_LOG, OUT_STATE, OUT_STATE2
run_case() {
	local name=$1 cfg=$2 pb=$3 bs=$4
	CASE="$t/$name"
	mkdir -p "$CASE/state"
	printf '%s\n' "$cfg" >"$CASE/config.stable.json"
	printf '%s\n' '{"patches-version":"stable"}' >"$CASE/config.beta.json"
	printf '%s\n' "$pb" >"$CASE/state/pending_builds.json"
	printf '%s\n' "$bs" >"$CASE/state/built_shape.json"
	(
		cd "$CASE" || exit 1
		GITHUB_OUTPUT="$CASE/gho" bash "$REPO/.github/scripts/ci_detect_config_changes.sh" \
			>"$CASE/log" 2>&1
	) || fail "$name: ci_detect_config_changes.sh exited non-zero"
	OUT_TRIGGER=$(sed -n 's/^TRIGGER_CONFIG_CHANGE=//p' "$CASE/gho" | tail -1)
	OUT_PENDING=$(cat "$CASE/pending.stable.json" 2>/dev/null || echo '[]')
	OUT_NEWAPPS=$(cat "$CASE/new_apps.json" 2> /dev/null || echo '{}')
	OUT_CHANGED=$(cat "$CASE/changed_apps.json" 2> /dev/null || echo '{}')
	OUT_STATE=$(cat "$CASE/state/pending_builds.json")
	OUT_STATE2=$(cat "$CASE/state/built_shape.json")
	OUT_LOG=$(cat "$CASE/log")
}

APP='"App-x": {"pkg-name":"com.x","app-name":"App","apkmirror-dlurl":"https://apkmirror.com/a"}'
# built_shape with a different app present (and fully built for its requested arches),
# so no case trips the cold-start seed and no unrelated app joins the pending list.
SHAPE='{"stable":{"Other-y":["arm-v7a","arm64-v8a"]},"beta":{}}'
STABLE_CFG="{\"patches-version\":\"stable\",$APP}"
FP=$(cd "$t" && printf '%s\n' "$STABLE_CFG" >probe.json && retry_fingerprint probe.json "App-x")
[ -n "$FP" ] || fail "fingerprint helper returned nothing"

# --- 1. a parked app whose config gained a source is re-armed and re-queued ------
run_case rearm_on_change \
	"{\"patches-version\":\"stable\",\"App-x\":{\"pkg-name\":\"com.x\",\"app-name\":\"App\",\"apkmirror-dlurl\":\"https://apkmirror.com/a\",\"direct-dlurl\":\"https://vendor.example/dl/apk\"}}" \
	'{"stable":{"App-x":{"reason":"retry","arches":["arm-v7a","arm64-v8a"],"attempts":3,"parked":true,"cfg":"deadbeef"}},"beta":{}}' \
	"$SHAPE"
[[ "$OUT_TRIGGER" == "1" ]] || fail "case1 trigger: $OUT_TRIGGER"
grep -q "Re-armed 'App-x'" <<<"$OUT_LOG" || fail "case1: no re-arm logged: $OUT_LOG"
[[ "$(jqx -r '.stable["App-x"].attempts' <<<"$OUT_STATE")" == "0" ]] || fail "case1 attempts not reset"
[[ "$(jqx -r '.stable["App-x"].parked' <<<"$OUT_STATE")" == "false" ]] || fail "case1 still parked"
[[ "$OUT_PENDING" == '["App-x"]' ]] || fail "case1 not queued for the pool: $OUT_PENDING"
[[ "$(jqx -r '.stable["App-x"].cfg' <<<"$OUT_STATE")" != "deadbeef" ]] || fail "case1 cfg not refreshed"

# --- 2. negative control: the same config must not re-arm, must not write --------
run_case no_change_no_rearm "$STABLE_CFG" \
	"{\"stable\":{\"App-x\":{\"reason\":\"retry\",\"arches\":[\"arm-v7a\",\"arm64-v8a\"],\"attempts\":3,\"parked\":true,\"cfg\":\"$FP\"}},\"beta\":{}}" \
	"$SHAPE"
[[ "$OUT_TRIGGER" == "0" ]] || fail "case2 fired a build for an unchanged config"
grep -q "Re-armed" <<<"$OUT_LOG" && fail "case2 re-armed without a config change"
[[ "$OUT_PENDING" == "[]" ]] || fail "case2 un-parked a still-valid retry: $OUT_PENDING"
[[ "$(jqx -r '.stable["App-x"].attempts' <<<"$OUT_STATE")" == "3" ]] || fail "case2 budget reset"
[[ "$OUT_STATE" == "$(printf '%s\n' "{\"stable\":{\"App-x\":{\"reason\":\"retry\",\"arches\":[\"arm-v7a\",\"arm64-v8a\"],\"attempts\":3,\"parked\":true,\"cfg\":\"$FP\"}},\"beta\":{}}" | jqx -c .)" ]] ||
	fail "case2 rewrote the state file (churn): $OUT_STATE"

# --- 3. negative control: reordered keys are not a config change ----------------
run_case reorder_not_a_change \
	'{"patches-version":"stable","App-x":{"app-name":"App","apkmirror-dlurl":"https://apkmirror.com/a","pkg-name":"com.x"}}' \
	"{\"stable\":{\"App-x\":{\"reason\":\"retry\",\"arches\":[\"arm-v7a\",\"arm64-v8a\"],\"attempts\":3,\"parked\":true,\"cfg\":\"$FP\"}},\"beta\":{}}" \
	"$SHAPE"
[[ "$OUT_TRIGGER" == "0" ]] || fail "case3: key order re-armed the app"

# --- 4. a legacy entry with no baseline re-arms once, then never again ----------
run_case legacy_once \
	"$STABLE_CFG" \
	'{"stable":{"App-x":{"reason":"retry","arches":["arm-v7a","arm64-v8a"],"attempts":3,"parked":true}},"beta":{}}' \
	"$SHAPE"
[[ "$(jqx -r '.stable["App-x"].parked' <<<"$OUT_STATE")" == "false" ]] || fail "case4 legacy entry not re-armed"
[[ -n "$(jqx -r '.stable["App-x"].cfg // ""' <<<"$OUT_STATE")" ]] || fail "case4 baseline not recorded"
seeded=$(jqx -r '.stable["App-x"].cfg' <<<"$OUT_STATE")
# Second run on the identical config must be a no-op - the guard against an entry
# that re-arms every run because its fingerprint never sticks.
run_case legacy_second \
	"$STABLE_CFG" \
	"{\"stable\":{\"App-x\":{\"reason\":\"retry\",\"arches\":[\"arm-v7a\",\"arm64-v8a\"],\"attempts\":3,\"parked\":true,\"cfg\":\"$seeded\"}},\"beta\":{}}" \
	"$SHAPE"
[[ "$OUT_TRIGGER" == "0" ]] || fail "case5 re-armed on the second run too"
[[ "$(jqx -r '.stable["App-x"].attempts' <<<"$OUT_STATE")" == "3" ]] || fail "case5 budget reset again"

# --- 5b. loop guard: a LIVE entry with no baseline keeps its count ---------------
# Resetting attempts whenever `cfg` is missing would hand every naturally-triggered
# failure (whose first entry is written by the build job, which hashes no config) a
# fresh budget each run, so RVB_RETRY_MAX could never be reached and the app would
# retry forever. Only the park is lifted by a missing baseline, never the count.
run_case live_no_baseline_keeps_count \
	"$STABLE_CFG" \
	'{"stable":{"App-x":{"reason":"retry","arches":["arm-v7a","arm64-v8a"],"attempts":2,"parked":false}},"beta":{}}' \
	"$SHAPE"
[[ "$(jqx -r '.stable["App-x"].attempts' <<<"$OUT_STATE")" == "2" ]] ||
	fail "case5b a baseline-less live retry lost its attempts: $OUT_STATE"
[[ -n "$(jqx -r '.stable["App-x"].cfg // ""' <<<"$OUT_STATE")" ]] || fail "case5b baseline not recorded"
grep -q "Re-armed" <<<"$OUT_LOG" && fail "case5b logged a re-arm it must not have made"

# --- 6. a brand-new app still enqueues reason "new" and now carries a baseline --
run_case new_app_cfg \
	"$STABLE_CFG" '{"stable":{},"beta":{}}' "$SHAPE"
[[ "$OUT_PENDING" == '["App-x"]' ]] || fail "case6 new app not queued: $OUT_PENDING"
[[ "$(jqx -r '.stable["App-x"].reason' <<<"$OUT_STATE")" == "new" ]] || fail "case6 reason"
[[ "$(jqx -r '.stable["App-x"].cfg' <<<"$OUT_STATE")" == "$FP" ]] || fail "case6 new entry lacks the fingerprint"
[[ "$OUT_NEWAPPS" == '{"stable":["App-x"],"beta":[]}' ]] || fail "case6 notification list: $OUT_NEWAPPS"

# --- 7. arch pruning and re-arm coexist: both -> arm64 keeps the retry alive ----
run_case arch_prune_then_rearm \
	'{"patches-version":"stable","App-x":{"pkg-name":"com.x","arch":"arm64-v8a","apkmirror-dlurl":"https://apkmirror.com/a"}}' \
	'{"stable":{"App-x":{"reason":"retry","arches":["arm-v7a","arm64-v8a"],"attempts":1,"parked":false,"cfg":"old"}},"beta":{}}' \
	"$SHAPE"
[[ "$(jqx -c '.stable["App-x"].arches' <<<"$OUT_STATE")" == '["arm64-v8a"]' ]] || fail "case7 arch not pruned: $OUT_STATE"
[[ "$(jqx -r '.stable["App-x"].attempts' <<<"$OUT_STATE")" == "0" ]] || fail "case7 arch edit did not re-arm"

# --- 8. an arch the config no longer requests at all drops the entry ------------
run_case arch_gone_deletes \
	'{"patches-version":"stable","App-x":{"pkg-name":"com.x","arch":"x86_64","apkmirror-dlurl":"https://apkmirror.com/a"}}' \
	'{"stable":{"App-x":{"reason":"retry","arches":["arm-v7a","arm64-v8a"],"attempts":2,"parked":false,"cfg":"old"}},"beta":{}}' \
	"$SHAPE"
[[ "$(jqx -r '.stable | has("App-x")' <<<"$OUT_STATE")" == "false" ]] || fail "case8 disjoint arch kept: $OUT_STATE"

# --- 10. a download attempt must not lose the fingerprint (the re-arm-forever guard)
# build_update_retry_list.sh rewrites the pending entry when a DOWNLOAD exhausts. If
# that rewrite dropped `cfg`, the watcher would see a baseline-less entry on its next
# run and re-arm it again, buying an infinite retry loop - exactly what parking exists
# to stop. So the merge is tested where it is written, then fed back to the watcher.
# The retry class is a download failure; the default fixture is a `_dl` record (only
# `_dl` files re-queue — every other failure suffix settles, checked in 11b/11c).
run_build_case() { # <name> <pending-json> [f1-file] [f1-json] [f2-file] [f2-json]
	local name=$1 pb=$2
	local f1=${3:-} j1=${4:-} f2=${5:-} j2=${6:-}
	# A default is set on its own line, never inside ${4:-{...}} - a `}` in that
	# parameter-expansion default terminates the expansion early and truncates the JSON.
	[ -n "$f1" ] || f1=temp/failures/appx_dl.json
	if [ -z "$j1" ]; then
		j1='{"type":"dl_exhausted","app":"App-x","arch":"arm64-v8a"}'
	fi
	CASE="$t/$name"
	mkdir -p "$CASE/state" "$CASE/temp/failures"
	printf '%s\n' '{"patches-version":"stable","App-x":{"enabled":true,"pkg-name":"com.x"}}' >"$CASE/pool.stable.json"
	printf '%s\n' "$j1" >"$CASE/$f1"
	[ -n "$f2" ] && printf '%s\n' "$j2" >"$CASE/$f2"
	printf '%s\n' '{"stable":{"Other-y":["arm-v7a","arm64-v8a"]},"beta":{}}' >"$CASE/state/built_shape.json"
	printf '%s\n' "$pb" >"$CASE/state/pending_builds.json"
	(
		cd "$CASE" || exit 1
		CONFIG_FILE=pool.stable.json RVB_RETRY_MAX=3 GITHUB_OUTPUT="$CASE/gho" \
			bash "$REPO/.github/scripts/build_update_retry_list.sh" >"$CASE/log" 2>&1
	) || fail "$name: build_update_retry_list.sh exited non-zero"
	OUT_STATE=$(cat "$CASE/state/pending_builds.json")
	OUT_STATE2=$(cat "$CASE/state/built_shape.json")
}

run_build_case build_preserves_cfg \
	"{\"stable\":{\"App-x\":{\"reason\":\"retry\",\"arches\":[\"arm-v7a\",\"arm64-v8a\"],\"attempts\":0,\"parked\":false,\"cfg\":\"$FP\"}},\"beta\":{}}"
[[ "$(jqx -r '.stable["App-x"].attempts' <<<"$OUT_STATE")" == "1" ]] || fail "case10 attempts not counted"
[[ "$(jqx -r '.stable["App-x"].cfg // "MISSING"' <<<"$OUT_STATE")" == "$FP" ]] ||
	fail "case10 the attempt dropped the fingerprint: $OUT_STATE"

# --- 11. and the watcher, after that attempt, still does not re-arm --------------
# The entry is a live (non-parked) download retry, so the trigger stays high on its own
# account; what must NOT happen is the budget being reset behind the build's back.
run_case after_attempt_no_rearm "$STABLE_CFG" "$OUT_STATE" "$SHAPE"
grep -q "Re-armed" <<<"$OUT_LOG" && fail "case11 re-armed an app whose config never changed: $OUT_LOG"
[[ "$(jqx -r '.stable["App-x"].attempts' <<<"$OUT_STATE")" == "1" ]] ||
	fail "case11 the watcher reset an attempt it had no reason to reset: $OUT_STATE"

# --- 11b. a patcher abort is settled, not retried -------------------------------
# A `_pf` record must not create a retry entry: re-running the same engine over the
# same inputs aborts identically, so only a patch-bundle trigger or a config edit can
# fix it. Its attempted arch falls into the success side and settles into built_shape,
# so the watcher stops re-flagging it as "new" (the same settle `_np` relies on).
run_build_case pf_settled '{"stable":{},"beta":{}}' \
	temp/failures/appx_pf.json '{"type":"patch_failed","app":"App-x","arch":"arm64-v8a"}'
[[ "$(jqx -r '.stable | has("App-x")' <<<"$OUT_STATE")" == "false" ]] ||
	fail "case11b a patcher abort created a retry entry: $OUT_STATE"
[[ "$(jqx -r '.stable["App-x"].arches | index("arm64-v8a") != null' <<<"$OUT_STATE2")" == "true" ]] ||
	fail "case11b patcher abort arch did not settle into built_shape: $OUT_STATE2"

# --- 11c. a hard build abort is settled, not retried ----------------------------
# The plain `<slug>.json` descriptor (build_failed) follows the same rule: no retry
# entry, arch settled. This is the class the change removed from the retry queue.
run_build_case build_settled '{"stable":{},"beta":{}}' \
	temp/failures/appx.json '{"type":"build_failed","app":"App-x","arch":"arm64-v8a"}'
[[ "$(jqx -r '.stable | has("App-x")' <<<"$OUT_STATE")" == "false" ]] ||
	fail "case11c a build abort created a retry entry: $OUT_STATE"
[[ "$(jqx -r '.stable["App-x"].arches | index("arm64-v8a") != null' <<<"$OUT_STATE2")" == "true" ]] ||
	fail "case11c build abort arch did not settle into built_shape: $OUT_STATE2"

# --- 11d. mixed: a download retry coexists with a settled patcher abort ---------
# The coarse rule must be per-arch, not per-app: the `_dl` arch re-queues live while a
# sibling `_pf` arch settles — the abort must not park or suppress the download retry.
run_build_case dl_retry_plus_pf_settle '{"stable":{},"beta":{}}' \
	temp/failures/appx_dl.json '{"type":"dl_exhausted","app":"App-x","arch":"arm64-v8a"}' \
	temp/failures/appx_pf.json '{"type":"patch_failed","app":"App-x (arm-v7a)","arch":"arm-v7a"}'
[[ "$(jqx -r '.stable["App-x"].reason' <<<"$OUT_STATE")" == "retry" ]] ||
	fail "case11d download retry not queued: $OUT_STATE"
[[ "$(jqx -c '.stable["App-x"].arches' <<<"$OUT_STATE")" == '["arm64-v8a"]' ]] ||
	fail "case11d retry entry leaked the settled arch: $OUT_STATE"
[[ "$(jqx -r '.stable["App-x"].arches | index("arm-v7a") != null' <<<"$OUT_STATE2")" == "true" ]] ||
	fail "case11d settled patcher-abort arch missing from built_shape: $OUT_STATE2"

# --- 12. an app that left the config loses its queue entry, not its memory ------
# ADR 0010 promises that removal prunes the pending entry, and a key the config no
# longer lists is unreachable for every later writer, so a parked orphan would sit
# there forever. The paired control is the app that IS still listed: its entry must
# survive the same pass untouched, or the prune would be a blanket wipe that passes
# vacuously. Both are parked, so nothing is queued for the pool — the write must
# still be committed, and committing it must still not buy a build.
ONLY_OTHER='{"patches-version":"stable","Other-y":{"pkg-name":"com.o","app-name":"Other","apkmirror-dlurl":"https://apkmirror.com/o"}}'
# The memory holds BOTH apps: the one still listed (so nothing looks new) and the one
# that left the config (whose artifact was built and stays credited).
SHAPE_LEFT='{"stable":{"App-x":["arm-v7a","arm64-v8a"],"Other-y":["arm-v7a","arm64-v8a"]},"beta":{}}'
FP_OTHER=$(cd "$t" && printf '%s\n' "$ONLY_OTHER" >probe_other.json &&
	retry_fingerprint probe_other.json "Other-y")
[ -n "$FP_OTHER" ] || fail "fingerprint helper returned nothing for Other-y"
run_case app_absent_pruned_queue_kept_memory \
	"$ONLY_OTHER" \
	"{\"stable\":{\"App-x\":{\"reason\":\"retry\",\"arches\":[\"arm-v7a\"],\"attempts\":3,\"parked\":true,\"cfg\":\"old\"},\"Other-y\":{\"reason\":\"retry\",\"arches\":[\"arm64-v8a\"],\"attempts\":2,\"parked\":true,\"cfg\":\"$FP_OTHER\"}},\"beta\":{}}" \
	"$SHAPE_LEFT"
[[ "$(jqx -r '.stable | has("App-x")' <<<"$OUT_STATE")" == "false" ]] ||
	fail "case12 a removed app kept its queue entry: $OUT_STATE"
grep -q "Pruned stale pending entry 'App-x'" <<<"$OUT_LOG" ||
	fail "case12: no prune logged: $OUT_LOG"
[[ "$(jqx -c '.stable["Other-y"]' <<<"$OUT_STATE")" == \
	"$(jqx -c '.stable["Other-y"]' <<<"{\"stable\":{\"Other-y\":{\"reason\":\"retry\",\"arches\":[\"arm64-v8a\"],\"attempts\":2,\"parked\":true,\"cfg\":\"$FP_OTHER\"}},\"beta\":{}}")" ]] ||
	fail "case12 rewrote an app the config still lists: $OUT_STATE"
[[ "$OUT_TRIGGER" == "1" ]] || fail "case12 the prune would never reach data: $OUT_TRIGGER"
[[ "$OUT_PENDING" == "[]" ]] || fail "case12 queued a parked survivor: $OUT_PENDING"
# built_shape must be unchanged — the queue forgets, the memory does not. The file is
# written in the repo's canonical pretty layout, so compare the parsed documents.
[[ "$(jqx -c . <<<"$OUT_STATE2")" == "$(printf '%s\n' "$SHAPE_LEFT" | jqx -c .)" ]] ||
	fail "case12 the prune touched built_shape: $OUT_STATE2"

# --- 12b. the other half of that flag: persisted, and still no build -----------
# TRIGGER_CONFIG_CHANGE feeds ANYTHING_CHANGED, which is what runs the data commit.
# A bookkeeping write therefore has to raise it — and the run must still not start,
# because ci_resolve_triggers.sh counts the enabled apps in the pool.
RES="$t/resolve_after_prune"
mkdir -p "$RES/configs"
printf '%s\n' '{"patches-version":"stable","Other-y":{"enabled":false,"pkg-name":"com.o"}}' >"$RES/configs/stable_build.json"
printf '%s\n' '{"patches-version":"beta"}' >"$RES/configs/beta_build.json"
# The prune left a non-parked item in the stable queue, so the channel DOES have a
# reason to build: without this file the run below would be stopped by the new
# channel-scope test and would pass without ever reaching the enabled-count guard it
# is here to prove.
printf '%s\n' '["Other-y"]' >"$RES/pending.stable.json"
(
	cd "$RES" || exit 1
	RAW_TRIGGER_STABLE=0 RAW_TRIGGER_BETA=0 RAW_TRIGGER_APP_UPDATE=0 \
		RAW_TRIGGER_CONFIG_CHANGE=1 GITHUB_OUTPUT="$RES/gho" \
		bash "$REPO/.github/scripts/ci_resolve_triggers.sh" >"$RES/log" 2>&1
) || fail "12b: ci_resolve_triggers.sh exited non-zero: $(cat "$RES/log")"
[[ "$(sed -n 's/^TRIGGER_STABLE=//p' "$RES/gho")" == "0" ]] ||
	fail "12b a state-only write still started a build"
grep -q "Skipping stable build trigger: no enabled apps" "$RES/log" ||
	fail "12b was stopped before the enabled-count guard, so it proved nothing: $(cat "$RES/log")"
ok_12b=1

# run_resolve <dir> [NAME=value ...] — run ci_resolve_triggers.sh in <dir> with the
# given trigger env; leaves RES_STABLE, RES_BETA, RES_LOG.
run_resolve() {
	local dir="$1"
	shift
	(
		cd "$dir" || exit 1
		env "$@" GITHUB_OUTPUT="$dir/gho" \
			bash "$REPO/.github/scripts/ci_resolve_triggers.sh" >"$dir/log" 2>&1
	) || fail "ci_resolve_triggers.sh exited non-zero in $dir: $(cat "$dir/log")"
	RES_STABLE=$(sed -n 's/^TRIGGER_STABLE=//p' "$dir/gho" | tail -1)
	RES_BETA=$(sed -n 's/^TRIGGER_BETA=//p' "$dir/gho" | tail -1)
	RES_LOG=$(cat "$dir/log")
}

# --- 12c. a config change wakes ONLY the channel that owns it --------------------
# The hole this shuts: run 41590950846 removed an architecture field from a STABLE app,
# ci_resolve_triggers.sh read the shared TRIGGER_CONFIG_CHANGE as a reason for BETA too,
# and both Google Keyboard variants were re-patched from cache, called "Unchanged build"
# by the content-hash gate and published nothing — while the queue notice named them as
# queued. The owning channel must still wake, so the pair below is the whole claim.
RES="$t/resolve_channel_scope"
mkdir -p "$RES/configs"
printf '%s\n' '{"patches-version":"stable","App-x":{"enabled":true,"pkg-name":"com.x"}}' >"$RES/configs/stable_build.json"
printf '%s\n' '{"patches-version":"beta","Gboard-y":{"enabled":true,"pkg-name":"com.k"}}' >"$RES/configs/beta_build.json"
printf '%s\n' '["App-x"]' >"$RES/pending.stable.json"
printf '%s\n' '[]' >"$RES/pending.beta.json"
printf '%s\n' '{"stable":{"App-x":[]},"beta":{}}' >"$RES/changed_apps.json"
printf '%s\n' '{"stable":[],"beta":[]}' >"$RES/new_apps.json"
printf '%s\n' '[]' >"$RES/active_apps.json"
run_resolve "$RES" RAW_TRIGGER_STABLE=0 RAW_TRIGGER_BETA=0 \
	RAW_TRIGGER_APP_UPDATE=0 RAW_TRIGGER_CONFIG_CHANGE=1
[[ "$RES_STABLE" == "1" ]] || fail "12c the owning channel was not woken by its own change: $RES_LOG"
[[ "$RES_BETA" == "0" ]] || fail "12c a stable config change woke the beta pool again"
ok_12c=1

# And the mirror: the same inputs with the entry on the beta side must wake beta and
# leave stable down. Without it, 12c could be satisfied by a resolver that simply never
# wakes anyone on a config change.
printf '%s\n' '[]' >"$RES/pending.stable.json"
printf '%s\n' '["Gboard-y"]' >"$RES/pending.beta.json"
printf '%s\n' '{"stable":{},"beta":{"Gboard-y":[]}}' >"$RES/changed_apps.json"
run_resolve "$RES" RAW_TRIGGER_STABLE=0 RAW_TRIGGER_BETA=0 \
	RAW_TRIGGER_APP_UPDATE=0 RAW_TRIGGER_CONFIG_CHANGE=1
[[ "$RES_BETA" == "1" ]] || fail "12c-mirror a beta entry did not wake beta: $RES_LOG"
[[ "$RES_STABLE" == "0" ]] || fail "12c-mirror a beta entry woke the stable pool"
ok_12c_mirror=1

# --- 12d. an app version update is a reason only for a pool that lists the app ----
# ci_compare_app_versions.sh shares TRIGGER_APP_UPDATE, and one store group can hold
# keys from both pools, so the intersection with the pool decides. Same pairing: the
# refusal needs the acceptance beside it or either side could pass by never waking.
RES="$t/resolve_app_update"
mkdir -p "$RES/configs"
printf '%s\n' '{"patches-version":"stable","App-x":{"enabled":true,"pkg-name":"com.x"}}' >"$RES/configs/stable_build.json"
printf '%s\n' '{"patches-version":"beta","Gboard-y":{"enabled":true,"pkg-name":"com.k"}}' >"$RES/configs/beta_build.json"
printf '%s\n' '[]' >"$RES/pending.stable.json"
printf '%s\n' '[]' >"$RES/pending.beta.json"
printf '%s\n' '{"stable":{},"beta":{}}' >"$RES/changed_apps.json"
printf '%s\n' '{"stable":[],"beta":[]}' >"$RES/new_apps.json"
printf '%s\n' '["App-x"]' >"$RES/active_apps.json"
run_resolve "$RES" RAW_TRIGGER_STABLE=0 RAW_TRIGGER_BETA=0 \
	RAW_TRIGGER_APP_UPDATE=1 RAW_TRIGGER_CONFIG_CHANGE=0
[[ "$RES_STABLE" == "1" ]] || fail "12d the pool owning the updated app was not woken: $RES_LOG"
[[ "$RES_BETA" == "0" ]] || fail "12d an update for a stable-only app woke beta"
printf '%s\n' '["App-x","Gboard-y"]' >"$RES/active_apps.json"
run_resolve "$RES" RAW_TRIGGER_STABLE=0 RAW_TRIGGER_BETA=0 \
	RAW_TRIGGER_APP_UPDATE=1 RAW_TRIGGER_CONFIG_CHANGE=0
[[ "$RES_BETA" == "1" ]] || fail "12d a group with a beta key did not wake beta: $RES_LOG"
[[ "$RES_STABLE" == "1" ]] || fail "12d a group spanning pools lost the stable wake"
ok_12d=1

# --- 13. re-enabling a disabled app is not a build request on its own -----------
# Disabling pruned its queue entry, and the baseline survived, so the app comes back
# with every requested arch and every tracked field already recorded as built:
# nothing to enqueue, nothing to announce, no state file to rewrite. The paired case
# below is what makes this mean something — without the baseline the app would read
# as untracked and the run would have to guess.
BASE_MAP=$(printf '%s\n' "$STABLE_CFG" >"$t/base.json" && retry_effective_cfg "$t/base.json" "App-x")
[ -n "$BASE_MAP" ] || fail "tracked-map helper returned nothing"
SEED_X="{\"stable\":{\"App-x\":{\"arches\":[\"arm-v7a\",\"arm64-v8a\"],\"cfg\":$BASE_MAP}},\"beta\":{}}"
run_case reenable_without_change \
	"$STABLE_CFG" '{"stable":{},"beta":{}}' "$SEED_X"
[[ "$OUT_TRIGGER" == "0" ]] || fail "case13 rewrote state it had no reason to write"
[[ "$OUT_PENDING" == "[]" ]] || fail "case13 queued an unchanged re-enable: $OUT_PENDING"
[[ "$OUT_NEWAPPS" == '{"stable":[],"beta":[]}' ]] || fail "case13 announced it as new: $OUT_NEWAPPS"
[[ "$(jqx -c . <<<"$OUT_CHANGED")" == '{"stable":{},"beta":{}}' ]] ||
	fail "case13 announced a change: $OUT_CHANGED"
[[ -n "${ok_12b:-}" ]] || fail "case12b did not run"
[[ -n "${ok_12c:-}" ]] || fail "case12c did not run"
[[ -n "${ok_12c_mirror:-}" ]] || fail "case12c mirror did not run"
[[ -n "${ok_12d:-}" ]] || fail "case12d did not run"

# --- 14. an entry with no baseline records one and asks for NOTHING -------------
# This is the polarity that makes the comparison safe to deploy before the one-shot
# seed exists: guessing from the current config would forgive every edit published
# first, and treating the gap as new would force-rebuild the whole pool.
run_case legacy_records_silently \
	"$STABLE_CFG" '{"stable":{},"beta":{}}' \
	'{"stable":{"App-x":["arm-v7a","arm64-v8a"]},"beta":{}}'
[[ "$OUT_PENDING" == "[]" ]] || fail "case14 force-built an untracked app: $OUT_PENDING"
[[ "$OUT_NEWAPPS" == '{"stable":[],"beta":[]}' ]] || fail "case14 announced the record as new"
[[ "$(jqx -c . <<<"$OUT_CHANGED")" == '{"stable":{},"beta":{}}' ]] ||
	fail "case14 announced a change: $OUT_CHANGED"
[[ "$(jqx -c '.stable["App-x"].arches' <<<"$OUT_STATE2")" == '["arm-v7a","arm64-v8a"]' ]] ||
	fail "case14 the arch memory was lost on conversion: $OUT_STATE2"
[[ "$(jqx -c '.stable["App-x"].cfg' <<<"$OUT_STATE2")" == "$BASE_MAP" ]] ||
	fail "case14 no baseline stored: $OUT_STATE2"
[[ "$OUT_TRIGGER" == "1" ]] || fail "case14 the baseline would never reach data"

# --- 15. build-mode widened: enqueued as a config change, with the diff ---------
CFG_BOTH=$(printf '%s\n' "$STABLE_CFG" | jqx -c '.["App-x"]["build-mode"] = "both"')
run_case mode_widens "$CFG_BOTH" '{"stable":{},"beta":{}}' "$SEED_X"
[[ "$OUT_PENDING" == '["App-x"]' ]] || fail "case15 not queued: $OUT_PENDING"
[[ "$(jqx -r '.stable["App-x"].reason' <<<"$OUT_STATE")" == "config" ]] ||
	fail "case15 wrong reason: $OUT_STATE"
[[ "$OUT_NEWAPPS" == '{"stable":[],"beta":[]}' ]] ||
	fail "case15 announced a re-build as a NEW app: $OUT_NEWAPPS"
[[ "$(jqx -c '.stable["App-x"]' <<<"$OUT_CHANGED")" == \
	'[{"field":"build-mode","from":"apk","to":"both"}]' ]] ||
	fail "case15 no field diff announced: $OUT_CHANGED"
grep -q "Config change for 'App-x'" <<<"$OUT_LOG" || fail "case15: not logged: $OUT_LOG"
# the baseline must NOT advance: only a build that produced artifacts may do that
[[ "$(jqx -c '.stable["App-x"].cfg["build-mode"]' <<<"$OUT_STATE2")" == '"apk"' ]] ||
	fail "case15 the watcher credited a build that has not happened: $OUT_STATE2"

# --- 16. build-mode narrowed: nothing to build, so nothing asked ----------------
MAP_BOTH=$(printf '%s\n' "$BASE_MAP" | jqx -c '.["build-mode"] = "both"')
run_case mode_narrows "$STABLE_CFG" '{"stable":{},"beta":{}}' \
	"{\"stable\":{\"App-x\":{\"arches\":[\"arm-v7a\",\"arm64-v8a\"],\"cfg\":$MAP_BOTH}},\"beta\":{}}"
[[ "$OUT_PENDING" == "[]" ]] || fail "case16 rebuilt a narrowing: $OUT_PENDING"
[[ "$OUT_TRIGGER" == "0" ]] || fail "case16 moved state it had no reason to move"
[[ "$(jqx -c . <<<"$OUT_CHANGED")" == '{"stable":{},"beta":{}}' ]] ||
	fail "case16 announced a narrowing: $OUT_CHANGED"

# --- 17. a dlurl edit is transport, not a build request --------------------------
CFG_DL=$(printf '%s\n' "$STABLE_CFG" | jqx -c '.["App-x"]["apkmirror-dlurl"] = "https://www.apkmirror.com/apk/other/app"')
run_case dlurl_edit "$CFG_DL" '{"stable":{},"beta":{}}' "$SEED_X"
[[ "$OUT_PENDING" == "[]" ]] || fail "case17 rebuilt for a transport edit: $OUT_PENDING"
[[ "$OUT_TRIGGER" == "0" ]] || fail "case17 a transport edit moved state: $OUT_TRIGGER"

# --- 18. a patch-source move is a build request, and says which field ------------
MAP_SRC=$(printf '%s\n' "$BASE_MAP" | jqx -c '.["patches-source"] = "someone-else/patches"')
run_case source_moves "$STABLE_CFG" '{"stable":{},"beta":{}}' \
	"{\"stable\":{\"App-x\":{\"arches\":[\"arm-v7a\",\"arm64-v8a\"],\"cfg\":$MAP_SRC}},\"beta\":{}}"
[[ "$OUT_PENDING" == '["App-x"]' ]] || fail "case18 not queued: $OUT_PENDING"
[[ "$(jqx -r '.stable["App-x"] | map(.field) | index("patches-source") != null' <<<"$OUT_CHANGED")" == "true" ]] ||
	fail "case18 the source move is not in the announcement: $OUT_CHANGED"

# --- 19. the classification is complete over what CONFIG.md documents -----------
# Without this, a key added to the docs (or a TOML) silently joins the class of
# "edits a maintainer expects to cost a build that cost nothing" — which is exactly
# the bug being fixed here, one level up.
unclassified=""
while IFS= read -r k; do
	[ -z "$k" ] && continue
	if retry_tracked_key "$k" || retry_ignored_key "$k"; then
		continue
	fi
	unclassified="${unclassified:+${unclassified} }${k}"
done < <(sed -n 's/^\([a-z][a-z0-9_-]*\)[[:space:]]*=.*$/\1/p' "$REPO/CONFIG.md" | sort -u)
[ -z "$unclassified" ] ||
	fail "CONFIG.md documents keys that are neither tracked nor ignored: $unclassified"

# --- 20. the same edit must not be announced twice ---------------------------
# Run one wakes the app and announces it; run two sees the queue entry it left
# behind. The entry keeps the app in the pool, so the second run must stay quiet —
# otherwise every scheduled run until the build succeeds would re-announce one edit,
# and the announcement topic would stop meaning "something changed just now".
run_case wake_announces "$CFG_BOTH" '{"stable":{},"beta":{}}' "$SEED_X"
[[ "$OUT_PENDING" == '["App-x"]' ]] || fail "case20 run1 did not queue: $OUT_PENDING"
[[ "$(jqx -c '.stable["App-x"] // empty' <<<"$(jqx -c . <<<"$OUT_CHANGED")")" != "" ]] ||
	fail "case20 run1 announced nothing: $OUT_CHANGED"
run_case wake_announced_once "$CFG_BOTH" "$OUT_STATE" "$SEED_X"
[[ "$(jqx -c . <<<"$OUT_CHANGED")" == '{"stable":{},"beta":{}}' ]] ||
	fail "case20 run2 announced the same edit again: $OUT_CHANGED"
[[ "$OUT_PENDING" == '["App-x"]' ]] || fail "case20 run2 dropped the still-owed app: $OUT_PENDING"
[[ "$(jqx -r '.stable["App-x"].attempts' <<<"$OUT_STATE")" == "0" ]] ||
	fail "case20 run2 spent a retry budget it did not earn: $OUT_STATE"

# --- 22. a new arch on an existing app is a widening, not a new app ----------
# The entry is there and one ABI was never produced, so `need` is non-empty exactly as
# for a brand-new app — which is why both used to land in new_apps.json. A reader of the
# announcement topic does not care about the difference; a reader looking for the new
# app they added does, so the two must not share a reason.
SEED_ARM64="{\"stable\":{\"App-x\":{\"arches\":[\"arm64-v8a\"],\"cfg\":$BASE_MAP}},\"beta\":{}}"
run_case arch_widening "$STABLE_CFG" '{"stable":{},"beta":{}}' "$SEED_ARM64"
[[ "$OUT_PENDING" == '["App-x"]' ]] || fail "case22 widening not queued: $OUT_PENDING"
[[ "$(jqx -r '.stable["App-x"].reason' <<<"$OUT_STATE")" == "config" ]] ||
	fail "case22 wrong reason (must not be 'new'): $OUT_STATE"
[[ "$(jqx -c '.stable["App-x"].arches' <<<"$OUT_STATE")" == '["arm-v7a"]' ]] ||
	fail "case22 queued more arches than are missing: $OUT_STATE"
[[ "$OUT_NEWAPPS" == '{"stable":[],"beta":[]}' ]] ||
	fail "case22 announced an existing app as new: $OUT_NEWAPPS"
[[ "$(jqx -c '.stable["App-x"]' <<<"$(jqx -c . <<<"$OUT_CHANGED")")" == \
	'[{"field":"arch","from":"arm64-v8a","to":"arm-v7a, arm64-v8a"}]' ]] ||
	fail "case22 no expanded arch delta: $OUT_CHANGED"

# --- 23. patch-folder is attribution metadata, not an artifact input -----------
# ci_check_app_patches.py reads it; the engine never does, so a rebuild over it
# reproduces identical bytes and the content hash suppresses them. Waking on it buys a
# run and nothing else, so it must not be a tracked key.
CFG_PF=$(printf '%s\n' "$STABLE_CFG" | jqx -c '.["App-x"]["patch-folder"] = "appx"')
run_case patch_folder_silent "$CFG_PF" '{"stable":{},"beta":{}}' "$SEED_X"
[[ "$OUT_PENDING" == "[]" ]] || fail "case23 rebuilt for an attribution-only edit: $OUT_PENDING"
[[ "$OUT_TRIGGER" == "0" ]] || fail "case23 a no-op edit moved state: $OUT_TRIGGER"
[[ "$(jqx -c . <<<"$OUT_CHANGED")" == '{"stable":{},"beta":{}}' ]] ||
	fail "case23 announced an attribution-only edit: $OUT_CHANGED"

# --- 24. a change beside a stale baseline key is still seen -------------------
# Baselines are kept free of untracked keys by the one-shot state cleanup, not by the
# comparison. This case pins the part that must keep working regardless: an app whose
# baseline carries leftover text still wakes on a real change.
STALE_BASELINE=$(printf '%s\n' "$BASE_MAP" | jqx -c '. + {"patch-folder": "leftover"}')
run_case change_beside_stale_key \
	"$CFG_BOTH" '{"stable":{},"beta":{}}' \
	"{\"stable\":{\"App-x\":{\"arches\":[\"arm-v7a\",\"arm64-v8a\"],\"cfg\":$STALE_BASELINE}},\"beta\":{}}"
[[ "$OUT_PENDING" == '["App-x"]' ]] || fail "case24 missed a real change: $OUT_PENDING"
[[ "$(jqx -r '.stable["App-x"] | map(.field) | index("build-mode") != null' <<<"$(jqx -c . <<<"$OUT_CHANGED")")" == "true" ]] ||
	fail "case24 the real change is not what was announced: $OUT_CHANGED"

# --- 21. the shell list and the compiler's mirror agree -----------------------
# compile_patch_configs.py copies these lists so the shell stays stdlib and it can
# reject an unknown key without spawning anything. A copy without a check is how two
# files start disagreeing, so the equality is asserted where both are already loaded.
# Normalise both sides through the same function: the shell list arrives newline
# separated and the python list space separated, and comparing the raw text would
# fail on that alone.
keyset() { printf '%s' "$1" | tr -s '[:space:]' '\n' | LC_ALL=C sort | tr '\n' ' '; }
sh_tracked=$(keyset "$(retry_tracked_keys)")
sh_ignored=$(keyset "$(retry_ignored_keys)")
# Import by running from the scripts dir: a Git Bash path (/c/Users/...) means nothing
# to a Windows python, so sys.path juggling would work in CI and fail on a laptop.
py_lists=$(cd "$REPO/.github/scripts" && python3 -c "
import compile_patch_configs as c
print(' '.join(sorted(c.TRACKED_KEYS)))
print(' '.join(sorted(c.UNTRACKED_KEYS)))
") || fail "could not import compile_patch_configs"
[ "$(keyset "$(printf '%s\n' "$py_lists" | sed -n 1p)")" = "$sh_tracked" ] ||
	fail "tracked keys disagree between retry_lib.sh and compile_patch_configs.py
  shell: $sh_tracked
  py   : $(keyset "$(printf '%s\n' "$py_lists" | sed -n 1p)")"
[ "$(keyset "$(printf '%s\n' "$py_lists" | sed -n 2p)")" = "$sh_ignored" ] ||
	fail "untracked keys disagree
  shell: $sh_ignored
  py   : $(keyset "$(printf '%s\n' "$py_lists" | sed -n 2p)")"
# And a key that is read by no code must be accepted by neither list — otherwise the
# guard would wave it through again.
for ghost in folder-name mount-routing use-prebuilt-apks fdroid-index override-version-code; do
	if retry_tracked_key "$ghost" || retry_ignored_key "$ghost"; then
		fail "$ghost is classified although no code reads it"
	fi
	[ "$(cd "$REPO/.github/scripts" && python3 -c "
import compile_patch_configs as c
print('ok' if c.unknown_key('$ghost') is None else 'rejected')")" = "rejected" ] ||
		fail "$ghost is accepted by the compiler although no code reads it"
done

# --- 22. preferred-format is classified as never-wake (the ruling of 2026-10-21) --
# The key only steers a fetch, and the cache check skips the fetch for anything already
# built — so a rebuild over its edit reproduces the artifact an app already has. Both
# lists must agree it belongs with the transport keys, and the case fails if anyone
# re-tracks it on one side only (the parity above would still pass against the other).
retry_ignored_key preferred-format || fail "preferred-format must be ignored by the watcher"
if retry_tracked_key preferred-format; then fail "preferred-format must not wake a rebuild"; fi
[ "$(cd "$REPO/.github/scripts" && python3 -c "
import compile_patch_configs as c
print('ignored' if 'preferred-format' in c.UNTRACKED_KEYS else 'wrong')" 2>/dev/null)" = "ignored" ] ||
	fail "preferred-format is not in the compiler's UNTRACKED_KEYS"

# --- 23. end to end: adding the key to a built app wakes nothing ------------------
# The behavioral half of the same ruling, shaped like case 17: the config gains
# preferred-format over a seeded build, and the watcher must leave the pool, the
# trigger and the announcement all untouched.
CFG_PFMT=$(printf '%s\n' "$STABLE_CFG" | jqx -c '.["App-x"]["preferred-format"] = "apk apkm"')
run_case fmt_edit_no_rearm "$CFG_PFMT" '{"stable":{},"beta":{}}' "$SEED_X"
[[ "$OUT_PENDING" == "[]" ]] || fail "case23 rebuilt for a format-preference edit: $OUT_PENDING"
[[ "$OUT_TRIGGER" == "0" ]] || fail "case23 a format-preference edit moved state: $OUT_TRIGGER"

echo "CONFIG RE-ARM TESTS: PASS"
