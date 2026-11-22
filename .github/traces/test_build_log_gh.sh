#!/usr/bin/env bash
# Regression tests for the additive GitHub Discussions build log:
# .github/scripts/build_report_failures.sh (machine-readable rows),
# .github/scripts/build_notify_gh.sh + notify_gh.sh (transport) and
# .github/scripts/build_gh_download_table.py (GFM table).
#
# Everything runs offline against a stubbed `gh`: no discussion is created on
# GitHub, and negative controls (unset category, ambiguous title, missing
# archive note, oversized body, no-op) prove the positive cases are not passing
# vacuously.
set -u
export LC_ALL=C
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL: $*"; exit 1; }

mkdir -p "$t/bin" "$t/work/temp/failures" "$t/state"
: > "$t/state/discussions.json"
printf '{"discussions":[],"totalCount":0}\n' > "$t/state/discussions.json"
: > "$t/state/calls"

cat > "$t/bin/gh" << 'STUB'
#!/usr/bin/env bash
state=${GH_STUB_STATE:?}
printf '%s\n' "$*" >> "$state/calls"
cmd=${1:-}; shift || true
case "$cmd" in
discussion)
	sub=${1:-}; shift || true
	case "$sub" in
	list)
		# --search is deliberately unsupported: its index lags writes, so a
		# lookup that uses it would miss a discussion created moments earlier.
		for arg in "$@"; do
			if [ "$arg" = "--search" ]; then
				echo "stub: --search is not available" >&2
				exit 1
			fi
		done
		if [ "${GH_STUB_BAD_LIST:-0}" = 1 ]; then
			printf '[]\n'
		else
			cat "$state/discussions.json"
		fi
		;;
	create)
		title=""
		bodyfile=""
		while [ $# -gt 0 ]; do
			case "$1" in
			--title) title=${2:-}; shift 2 ;;
			--body-file) bodyfile=${2:-}; shift 2 ;;
			*) shift ;;
			esac
		done
		[ -f "$bodyfile" ] || exit 1
		cp "$bodyfile" "$state/body.md"
		jq -n --arg t "$title" '{discussions:[{"number":412,"title":$t,"url":"https://github.com/nullcpy/rvb/discussions/412"}],totalCount:1}' > "$state/discussions.json"
		printf 'https://github.com/nullcpy/rvb/discussions/412\n'
		;;
	comment)
		target=${1:-}; shift || true
		bodyfile=""
		editing=0
		while [ $# -gt 0 ]; do
			case "$1" in
			--body-file) bodyfile=${2:-}; shift 2 ;;
			--edit) editing=1; shift ;;
			*) shift ;;
			esac
		done
		[ -f "$bodyfile" ] || exit 1
		if [ "$editing" = 1 ]; then
			n=${target#DC}
			cp "$bodyfile" "$state/comment_${n}.md"
		else
			n=$(find "$state" -maxdepth 1 -name 'comment_*.md' | wc -l)
			n=$((n + 1))
			cp "$bodyfile" "$state/comment_${n}.md"
		fi
		printf 'https://github.com/nullcpy/rvb/discussions/412#discussioncomment-%s\n' "$n"
		;;
	edit)
		bodyfile=""
		while [ $# -gt 0 ]; do
			case "$1" in
			--body-file) bodyfile=${2:-}; shift 2 ;;
			--add-label) shift 2 ;;
			*) shift ;;
			esac
		done
		if [ -n "$bodyfile" ]; then
			[ -f "$bodyfile" ] || exit 1
			cp "$bodyfile" "$state/body.md"
		fi
		;;
	*) exit 1 ;;
	esac
	;;
api)
	[ "${1:-}" = graphql ] || exit 1
	nodes='[]'
	for f in "$state"/comment_*.md; do
		[ -f "$f" ] || continue
		n=${f##*_}; n=${n%.md}
		node=$(jq -Rs --arg id "DC$n" --arg url "https://github.com/nullcpy/rvb/discussions/412#discussioncomment-$n" \
			'{id:$id,url:$url,body:.}' "$f")
		nodes=$(jq -c --argjson n "$node" '. + [$n]' <<< "$nodes")
	done
	jq -n --argjson nodes "$nodes" '{data:{repository:{discussion:{comments:{nodes:$nodes}}}}}'
	;;
*) exit 1 ;;
esac
STUB
chmod +x "$t/bin/gh"

cat > "$t/bin/curl" << 'STUB'
#!/usr/bin/env bash
out=${REPORT_OUT:-/dev/null}
for arg in "$@"; do
	case "$arg" in
	*sendMessage*) continue ;;
	*xi.pe*) printf 'https://xi.pe/deadbeef\n'; exit 0 ;;
	text=*) printf '%s\n----MESSAGE----\n' "${arg#text=}" >> "$out" ;;
	esac
done
exit 0
STUB
chmod +x "$t/bin/curl"

# A realistic archive-linked note (URLs must point at the mirror, not rvb).
cat > "$t/work/build.archive.md" << 'NOTE'
### 🧩 revanced/revanced-patches ([v4.9.0](https://github.com/revanced/revanced-patches/releases/tag/v4.9.0))

* **YouTube** `v19.09.37`
  * APK: [arm64](https://github.com/nullcpy/archive/releases/download/260141/YouTube-v19.09.37-arm64-v8a.apk) • [arm](https://github.com/nullcpy/archive/releases/download/260141/YouTube-v19.09.37-arm-v7a.apk)
  * Module: [arm64](https://github.com/nullcpy/archive/releases/download/260141/YouTube-module-v19.09.37-arm64-v8a.zip)

---

### ℹ️ Notes
NOTE

printf '\033[31mSECRET LOG LINE\033[0m\r\n```\r\njava.lang.RuntimeException: nope\r\n' \
	> "$t/work/temp/failures/youtube.log"
jq -n '{type:"patch_failed", app:"YouTube (arm64-v8a)", arch:"arm64-v8a", version:"19.09.37", vc:"1", patches_src:"revanced/revanced-patches"}' \
	> "$t/work/temp/failures/youtube_pf.json"
jq -n '{type:"download", app:"Spotify (arm-v7a)", arch:"arm-v7a", pkg:"com.spotify.music", patches_src:"revanced/revanced-patches"}' \
	> "$t/work/temp/failures/spotify_dl.json"

TITLE="Build 260141 · Stable · $(date -u +%F)"

run_log() { # $1=label $2=...
	(
		cd "$t/work" || exit 1
		PATH="$t/bin:$PATH" GH_STUB_STATE="$t/state" \
			GH_TOKEN=stub GH_BUILDLOG_CATEGORY="Build Log" ARCHIVE_REPO=nullcpy/archive \
			BUILD_TAG=260141 CHANNEL_LABEL=Stable HAS_NEW_FILES=true NOTES_FILE=build.archive.md \
			GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=nullcpy/rvb GITHUB_RUN_ID=1 \
			"${@:2}" bash "$ROOT/.github/scripts/build_notify_gh.sh"
	) > "$t/$1.stdout" 2>&1
}

run_report() { # the manifest producer, stubbed curl for xi.pe
	(
		cd "$t/work" || exit 1
		PATH="$t/bin:$PATH" TG_TOKEN=dummy TG_CHAT_ID=-100 TG_THREAD_NOTIFY=7 \
			APKS_REPO=nullcpy/apks GITHUB_REPOSITORY=nullcpy/rvb GITHUB_SERVER_URL=https://github.com \
			GITHUB_RUN_ID=1 DISCORD_WEBHOOK_GITHUB_LOG="" \
			bash "$ROOT/.github/scripts/build_report_failures.sh"
	) > "$t/report.stdout" 2>&1
}

# ---- 1. the manifest carries derived details and the log path ----------------
run_report
rows="$t/work/temp/gh_buildlog/failures.tsv"
[ -f "$rows" ] || fail "no machine-readable failure manifest written"
grep -qF $'build\tYouTube\tarm64-v8a\tpatcher aborted' "$rows" || fail "patcher-abort row missing: $(cat "$rows")"
grep -qF $'dl\tSpotify\tarm-v7a\tsources exhausted' "$rows" || fail "download-failure row missing: $(cat "$rows")"

# ---- 2. one discussion, downloads first, failure report second ---------------
run_log first
[ -f "$t/state/body.md" ] || fail "no discussion body written"
body="$t/state/body.md"
grep -qF "$TITLE" <<< "$(cat "$t/state/discussions.json")" || fail "wrong discussion title"
grep -qF 'discussion edit 412 --add-label build_log' "$t/state/calls" || fail "build_log label was not applied"
grep -qF '## 📦 Downloads' "$body" || fail "downloads heading missing"
grep -qF '## 🚨 Build Report' "$body" || fail "report heading missing"
dl_pos=$(grep -nF '## 📦 Downloads' "$body" | cut -d: -f1)
rp_pos=$(grep -nF '## 🚨 Build Report' "$body" | cut -d: -f1)
[ "$dl_pos" -lt "$rp_pos" ] || fail "downloads must precede the report"
grep -qF 'nullcpy/archive/releases/download/260141/YouTube-v19.09.37-arm64-v8a.apk' "$body" || fail "archive download link missing"
grep -qF 'patcher aborted' "$body" || fail "derived detail missing"
grep -qF 'sources exhausted' "$body" || fail "download detail missing"
grep -qF '[xi.pe](https://xi.pe/deadbeef)' "$body" || fail "xi.pe link missing"
grep -qF '[github](https://github.com/nullcpy/rvb/discussions/412#discussioncomment-1)' "$body" || fail "log comment link missing"
grep -qF 'SECRET LOG LINE' "$body" && fail "raw log leaked into the body"

# ---- 3. the log comment is collapsed, sanitised and fenced safely -------------
comment="$t/state/comment_1.md"
[ -f "$comment" ] || fail "no failure log comment written"
grep -qF '## 📄 Failure Log' "$comment" || fail "log comment heading missing"
grep -qF '<summary>YouTube arm64-v8a</summary>' "$comment" || fail "summary must be just app + arch"
grep -qF 'SECRET LOG LINE' "$comment" || fail "log content missing from comment"
grep -qF $'\033' "$comment" && fail "ANSI escape survived sanitisation"
grep -qF '````text' "$comment" || fail "fence did not grow past the embedded backticks"

# ---- 4. retry edits in place, never duplicates -------------------------------
run_log retry
[ "$(find "$t/state" -maxdepth 1 -name 'comment_*.md' | wc -l)" -eq 1 ] || fail "retry created a second comment"
[ "$(grep -c 'discussion create' "$t/state/calls")" -eq 1 ] || fail "retry created a second discussion"
grep -qF '[github](https://github.com/nullcpy/rvb/discussions/412#discussioncomment-1)' "$body" || fail "retry lost the stable comment URL"

# ---- 4b. a retry after UTC midnight reuses the same build's discussion -------
jq -n '{discussions:[{"number":411,"title":"Build 260141 · Stable · 2000-01-01","url":"x"}],totalCount:1}' \
	> "$t/state/discussions.json"
creates_before=$(grep -c 'discussion create' "$t/state/calls")
run_log midnight
[ "$(grep -c 'discussion create' "$t/state/calls")" -eq "$creates_before" ] || fail "cross-midnight retry created a duplicate"
grep -qF '## 📦 Downloads' "$t/state/body.md" || fail "cross-midnight retry did not update the body"

# ---- 5. negative: unset category fails before any gh call --------------------
before=$(wc -l < "$t/state/calls")
if run_log no_category env GH_BUILDLOG_CATEGORY=; then fail "unset category did not fail"; fi
grep -q 'target not configured' "$t/no_category.stdout" || fail "unset category error missing"
[ "$(wc -l < "$t/state/calls")" -eq "$before" ] || fail "unset category still called gh"

# ---- 6. negative: ambiguous title fails loudly -------------------------------
jq -n --arg day "$(date -u +%F)" '{discussions:[{"number":411,"title":("Build 260141 · Stable · " + $day),"url":"x"},{"number":412,"title":("Build 260141 · Stable · " + $day),"url":"y"}],totalCount:2}' \
	> "$t/state/discussions.json"
if run_log ambiguous; then fail "ambiguous title did not fail"; fi
grep -q 'More than one discussion' "$t/ambiguous.stdout" || fail "ambiguity error missing"

# ---- 6b. negative: a wrong list shape must not be read as "no discussion" -----
if run_log bad_list env GH_STUB_BAD_LIST=1; then fail "unexpected list shape did not fail"; fi
grep -q 'Unexpected gh discussion list output' "$t/bad_list.stdout" || fail "shape error missing"

# ---- 7. negative: a shipped build without the archive note fails -------------
printf '{"discussions":[],"totalCount":0}\n' > "$t/state/discussions.json"
if run_log no_note env NOTES_FILE=; then fail "missing archive note did not fail"; fi
grep -q 'build.archive.md' "$t/no_note.stdout" || fail "missing-note error missing"

# ---- 8. negative: body over budget fails instead of truncating ---------------
printf '{"discussions":[],"totalCount":0}\n' > "$t/state/discussions.json"
long=$(printf 'X%.0s' {1..70000})
printf 'build\t%s\tarm64-v8a\tbuild aborted\t-\t-\n' "$long" >> "$t/work/temp/gh_buildlog/failures.tsv"
if run_log oversized; then fail "oversized body did not fail"; fi
grep -q 'budget' "$t/oversized.stdout" || fail "oversize error missing"

# ---- 9. no failures and no files: a quiet no-op ------------------------------
printf '{"discussions":[],"totalCount":0}\n' > "$t/state/discussions.json"
: > "$t/work/temp/gh_buildlog/failures.tsv"
run_log noop env HAS_NEW_FILES=false GH_BUILDLOG_CATEGORY=
grep -q 'Nothing to publish' "$t/noop.stdout" || fail "no-op did not say so"

echo "github build log: all cases passed"
