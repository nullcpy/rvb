#!/bin/bash
# build_notify_gh.sh — publish one build's durable report to GitHub Discussions.
# Additive: Telegram and Discord are untouched. One discussion per build, titled
# "Build <tag> · <Channel> · <UTC date>", with the compact download table at the
# top of the body and the build report beneath it. Full failure logs live in a
# dedicated comment so the body stays small and a retry can edit in place.
#
# The download links come from build.archive.md, whose URLs already point at the
# permanent archive repo — a numbered rvb release being deleted cannot break
# them. A build that shipped files without a successful mirror is an error, not
# a silent fallback to rvb links (ADR 0015's ownership rule).
#
# Env: GH_TOKEN GH_BUILDLOG_CATEGORY ARCHIVE_REPO BUILD_TAG CHANNEL_LABEL
#      HAS_NEW_FILES NOTES_FILE GITHUB_SERVER_URL GITHUB_REPOSITORY GITHUB_RUN_ID
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=notify_gh.sh
source "$SCRIPT_DIR/notify_gh.sh"

GH_ROWS="temp/gh_buildlog/failures.tsv"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

declare -a ROWS=()
if [ -f "$GH_ROWS" ]; then
	while IFS= read -r line; do
		[ -n "$line" ] && ROWS+=("$line")
	done < "$GH_ROWS"
fi

# A no-change, failure-free build has no log to write. Check this before the
# target guard: a fork with no category configured must not fail on a build
# that has nothing to report (same placement rule as notify_targets.sh).
if [ "${HAS_NEW_FILES:-false}" != "true" ] && [ "${#ROWS[@]}" -eq 0 ]; then
	echo "Nothing to publish to the GitHub build log."
	exit 0
fi

gh_require_targets \
	"GH_TOKEN=${GH_TOKEN:-}" \
	"GH_BUILDLOG_CATEGORY=${GH_BUILDLOG_CATEGORY:-}" \
	"ARCHIVE_REPO=${ARCHIVE_REPO:-}" \
	"BUILD_TAG=${BUILD_TAG:-}" \
	"CHANNEL_LABEL=${CHANNEL_LABEL:-}" \
	"GITHUB_REPOSITORY=${GITHUB_REPOSITORY:-}" || exit 1

if [ "${HAS_NEW_FILES:-false}" = "true" ]; then
	if [ "${NOTES_FILE:-}" != "build.archive.md" ] || [ ! -f "${NOTES_FILE:-}" ]; then
		echo "::error::GitHub build log needs build.archive.md (the archive mirror must have landed); got '${NOTES_FILE:-none}'. Refusing to link files that are not in the permanent mirror." >&2
		exit 1
	fi
fi

TITLE="Build ${BUILD_TAG} · ${CHANNEL_LABEL} · $(date -u +%F)"
gh_log_find "$TITLE" || exit 1
if [ "$GH_LOG_FIND_COUNT" -eq 0 ]; then
	printf '<!-- rvb:buildlog:%s:seed -->\n' "$BUILD_TAG" > "$WORK/seed.md"
	gh discussion create --title "$TITLE" \
		--category "$GH_BUILDLOG_CATEGORY" \
		--body-file "$WORK/seed.md" >/dev/null || exit 1
	gh_log_find "$TITLE" || exit 1
	if [ "$GH_LOG_FIND_COUNT" -ne 1 ]; then
		echo "::error::Discussion '${TITLE}' was created but could not be resolved to exactly one number." >&2
		exit 1
	fi
fi

# ---- Full failure logs: one comment (or more, on overflow) --------------------
declare -A LOGURL=()
declare -a BLOCKS=() BLOCK_KEYS=() PART_START=() PART_END=() PART_URLS=()
for line in "${ROWS[@]}"; do
	IFS=$'\t' read -r section app arch detail link logfile <<< "$line"
	if [ "${logfile:-}" = "-" ] || [ -z "${logfile:-}" ] || [ ! -f "$logfile" ]; then
		continue
	fi
	clean=$(gh_sanitize_log "$logfile")
	[ -n "$clean" ] || continue
	fence=$(gh_fence_for "$clean")
	key="${app}|${arch}"
	block="<details>"$'\n'"<summary>$(gh_html_escape "$app") $(gh_html_escape "$arch")</summary>"$'\n\n'
	block+="${fence}text"$'\n'"${clean}"$'\n'"${fence}"$'\n\n'"</details>"
	BLOCKS+=("$block")
	BLOCK_KEYS+=("$key")
done

if [ "${#BLOCKS[@]}" -gt 0 ]; then
	part=0
	cur=""
	start=0
	for i in "${!BLOCKS[@]}"; do
		candidate="$cur"
		[ -n "$candidate" ] && candidate+=$'\n\n'
		candidate+="${BLOCKS[$i]}"
		if [ "$(gh_body_units "$candidate")" -gt "$((GH_COMMENT_LIMIT - 200))" ] && [ -n "$cur" ]; then
			PART_START+=("$start")
			PART_END+=("$((i - 1))")
			part=$((part + 1))
			cur="${BLOCKS[$i]}"
			start=$i
		else
			cur="$candidate"
		fi
	done
	PART_START+=("$start")
	PART_END+=("$(( ${#BLOCKS[@]} - 1 ))")
	part=$((part + 1))

	for ((p = 0; p < part; p++)); do
		suffix=""
		[ "$p" -gt 0 ] && suffix=":$((p + 1))"
		anchor="<!-- rvb:buildlog:${BUILD_TAG}:logs${suffix} -->"
		file="$WORK/log_comment_${p}.md"
		{
			printf '%s\n' "$anchor"
			printf '%s\n\n' '## 📄 Failure Log'
			printf '%s\n' "${BLOCKS[${PART_START[$p]}]}"
			for ((i = PART_START[p] + 1; i <= PART_END[p]; i++)); do
				printf '\n\n%s\n' "${BLOCKS[$i]}"
			done
		} > "$file"
		url=$(gh_log_comment_once "$anchor" "$file") || exit 1
		PART_URLS+=("$url")
	done

	for ((p = 0; p < part; p++)); do
		for ((i = PART_START[p]; i <= PART_END[p]; i++)); do
			LOGURL["${BLOCK_KEYS[$i]}"]="${PART_URLS[$p]}"
		done
	done
fi

# ---- Body: downloads first, failure report second -----------------------------
if [ "${HAS_NEW_FILES:-false}" = "true" ]; then
	downloads=$(python3 "$SCRIPT_DIR/build_gh_download_table.py" "$NOTES_FILE") || exit 1
else
	downloads=$'## 📦 Downloads\n\n> No files were published in this build.'
fi

report=""
for spec in \
	'build|🚨 Build Failed|⚠️ Report the issue to the patch author with the log link.' \
	'lb|🚫 Patch Bundle Unreadable|⚠️ The patch CLI could not list this bundle at all — the CLI patcher library and the bundle do not match (see log). Pin the bundle to a version the CLI reads, or use a CLI built for it.' \
	'np|🧩 Patch Compatibility|⚠️ These versions have no patch to apply or no patch for that arch.' \
	'npa|🔩 CLI Issue|⚠️ The patcher applied 0 patches to these builds.' \
	'dl|📡 Download Failures|ℹ️ Upload the APK to the cache repo manually.'
do
	IFS='|' read -r key heading hint <<< "$spec"
	rows=""
	count=0
	for line in "${ROWS[@]}"; do
		IFS=$'\t' read -r section app arch detail link logfile <<< "$line"
		[ "$section" = "$key" ] || continue
		count=$((count + 1))
		cell_link="—"
		if [ -n "${LOGURL["${app}|${arch}"]:-}" ]; then
			if [ -n "${link:-}" ]; then
				cell_link="[xi.pe](${link}) · [github](${LOGURL["${app}|${arch}"]})"
			else
				cell_link="[github](${LOGURL["${app}|${arch}"]})"
			fi
		elif [ -n "${link:-}" ]; then
			cell_link="$link"
		fi
		rows+="| $(gh_table_cell "$app") | $(gh_table_cell "$arch") | $(gh_table_cell "$detail") | ${cell_link}"$'\n'
	done
	if [ "$count" -gt 0 ]; then
		label="apps"
		[ "$count" -eq 1 ] && label="app"
		report+="### ${heading} (${count} ${label})"$'\n\n'
		report+='| App | Arch | Detail | Link |'$'\n''|---|---|---|---|'$'\n'"$rows"$'\n'"$hint"$'\n\n'
	fi
done
if [ -z "$report" ]; then
	report='✅ No build failures in this build.'
fi

BODY="[Release](${GITHUB_SERVER_URL:-https://github.com}/${ARCHIVE_REPO}/releases/tag/${BUILD_TAG}) · [Run](${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID:-0})"$'\n\n'
BODY+="${downloads}"$'\n\n'"## 🚨 Build Report"$'\n\n'"${report}"

units=$(gh_body_units "$BODY")
if [ "$units" -gt "$GH_BODY_LIMIT" ]; then
	echo "::error::Assembled build-log body is ${units} UTF-16 units, above the ${GH_BODY_LIMIT} budget. Refusing to truncate it; shorten the failure report or split the build." >&2
	exit 1
fi

printf '%s' "$BODY" > "$WORK/body.md"
gh discussion edit "$GH_LOG_NUMBER" --body-file "$WORK/body.md" >/dev/null || exit 1
echo "Published build log for ${TITLE}."
