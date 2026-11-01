#!/bin/bash
# build_report_failures.sh — turn the per-app failure records the engine left in
# temp/failures into ONE batched Telegram message on the failure-notification
# topic, uploading each build log to xi.pe and linking it inline.
#
# Why a separate CI step instead of notifying from the engine: the engine stays
# free of network/notification code (and of Telegram credentials in its env);
# this step owns the whole report and is fail-soft like every other notify path,
# so one bad xi.pe upload never fails the build step.
#
# Records (written by scripts/utils.sh + scripts/build.sh), one per app+arch:
#   <slug>.json    a build that aborted (has <slug>.log alongside)
#   <slug>_pf.json a build the patcher itself aborted, "Patching aborted" — the
#                  engine skips with rc 0 for it, so only this survivor pair (plus
#                  <slug>_pf.log, relocated by the parent) reaches this directory
#   <slug>_dl.json a build whose download sources were all exhausted
#   <slug>_np.json a build the patch set refused for every supported version, so no
#                  APK was ever fetched (the dl record must not cover it: asking for a
#                  manual upload of a file nobody wanted is noise). Its optional
#                  bytesVersion column says a file WAS fetched and its own versionName is
#                  what the set refuses, which reads differently from a version nobody made.
#   <slug>_npa.json a build the patcher completed while applying **zero** patches, judged
#                  from its own machine-readable result file. The artifact is refused rather
#                  than published (an unpatched app under a patched name is worse than no
#                  build), so this record is the only trace the app left. Settled like _np:
#                  the same inputs apply the same nothing, so retrying spends a slot to
#                  learn nothing.
#   <slug>_lb.json a build whose patch bundle could not be LISTED at all (the CLI's
#                  list-patches itself aborted, e.g. the bundle was built against a
#                  different patcher library than the CLI ships). Unlike _np, no version
#                  is ever resolved, so the build aborts before the plain descriptor is
#                  written; the parent relocates the captured log to <slug>_lb.log so the
#                  abort reason (the JVM stack trace) is linkable.
# Records are regrouped by app base name and rendered in five parts: a Build
# Failed section (per-arch versionCode + the log link; both the <slug>.json and
# the <slug>_pf.json survivors land here), a Patch Bundle Unreadable section
# (<slug>_lb.json survivors + the log link), a Download Failures section
# (per-arch versionCode + search-engine links for the APK), a Patch Compatibility
# section (the versions the bundle refused + the bundle link to complain to) and a CLI
# Issue section (<slug>_npa.json survivors: the run applied nothing, so nothing shipped).
# Each arch
# carries its own version so an app that resolved a different version per arch
# never renders a wrong shared version. A _pf twin whose plain <slug>.json also
# survived is dropped: that build aborted hard and is already reported with its log.
#
# Route B: when this step actually sends, it writes reported_failures=true so
# ci.yml can skip the generic "🔴 CI #N failed" alert for the same run.
#
# Env: TG_TOKEN TG_CHAT_ID TG_THREAD_NOTIFY APKS_REPO
#      GITHUB_SERVER_URL GITHUB_REPOSITORY GITHUB_RUN_ID GITHUB_OUTPUT
#      DISCORD_WEBHOOK_GITHUB_LOG (optional mirror, see notify_discord.sh)
# TG_CHAT_ID and TG_THREAD_NOTIFY come from repository variables only: with no
# built-in handle, an unset one fails this step (reported_failures stays unset,
# so ci.yml still raises its generic alert) rather than posting to a stale chat.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=notify_targets.sh
source "$SCRIPT_DIR/notify_targets.sh"
# shellcheck source=notify_pack.sh
source "$SCRIPT_DIR/notify_pack.sh"
# shellcheck source=notify_discord.sh
source "$SCRIPT_DIR/notify_discord.sh"

NL=$'\n'
FAILURES_DIR="temp/failures"
TG_LIMIT=4096
XIPE_URL_BASE="https://xi.pe"

if [ -z "${TG_TOKEN:-}" ]; then
	echo "TG_TOKEN is not set. Skipping failure report."
	exit 0
fi
if [ ! -d "$FAILURES_DIR" ] || ! find "$FAILURES_DIR" -maxdepth 1 -name '*.json' -print -quit | grep -q .; then
	echo "No failure records in $FAILURES_DIR; nothing to report."
	exit 0
fi
# Checked after the "nothing to report" exit so a clean build never fails this
# step over routing config it did not need.
tg_require_targets \
	"TG_CHAT_ID=${TG_CHAT_ID:-}" \
	"TG_THREAD_NOTIFY=${TG_THREAD_NOTIFY:-}" || exit 1

# Markdown (legacy) has no escape-all helper; strip the few characters that
# would corrupt a [label](url) or a *bold* run in app-authored text.
md_clean() { printf '%s' "$1" | tr -d '[]`'; }

version_label() { # $1=version — hide the unhelpful placeholder values
	local v="${1:-}"
	case "$v" in
	'' | auto | latest | beta | exp) printf '' ;;
	*) printf 'v%s' "${v#v}" ;;
	esac
}

# app_base <app-label> <arch> — the app name with the engine's " (<arch>)" build
# suffix removed, so per-arch records regroup under one name. Only the exact
# " (<arch>)" suffix is stripped, so a legitimate table name like "YouTube
# (Experimental)" keeps its parenthetical.
app_base() {
	local app=$1 arch=$2
	[ -n "$arch" ] && app="${app% ($arch)}"
	printf '%s' "$app"
}

# uniq_col <n> <blob> — first-seen unique values of pipe-column n, empties dropped.
uniq_col() { printf '%s\n' "$2" | cut -d'|' -f"$1" | sed '/^$/d' | awk '!s[$0]++'; }

# ---- Collect records, grouped by app base name (ordered by first sighting) ----
# Per record the blob is:  arch | version | versionCode | logurl | patches | pkg
declare -A BREC DREC BORDERSET DORDERSET VCFB
BORDER=""; DORDER=""
shopt -s nullglob
for json in "$FAILURES_DIR"/*.json; do
	case "$json" in *_dl.json | *_np.json | *_npa.json | *_pf.json | *_lb.json) continue ;; esac
	slug="$(basename "${json%.json}")"
	# A cascaded case (download exhausted, or the patch set refused, then the build
	# itself failed) is reported once, as the build failure; drop its twins.
	[ -f "$FAILURES_DIR/${slug}_dl.json" ] && rm -f "$FAILURES_DIR/${slug}_dl.json"
	[ -f "$FAILURES_DIR/${slug}_np.json" ] && rm -f "$FAILURES_DIR/${slug}_np.json"
	# A hard abort already carries the patcher's own failure in <slug>.log: the
	# _pf survivor would render the same app+arch a second time. Remove the pair.
	if [ -f "$FAILURES_DIR/${slug}_pf.json" ]; then
		rm -f "$FAILURES_DIR/${slug}_pf.json" "$FAILURES_DIR/${slug}_pf.log"
	fi
	# Same reasoning for a zero-patch record: the app is already in the Build Failed
	# section with its log, and an unpatched build that then aborted outright is one news.
	if [ -f "$FAILURES_DIR/${slug}_npa.json" ]; then
		rm -f "$FAILURES_DIR/${slug}_npa.json"
	fi

	app="$(jq -r '.app // empty' "$json")"
	arch="$(jq -r '.arch // empty' "$json")"
	ver="$(version_label "$(jq -r '.version // empty' "$json")")"
	vc="$(jq -r '.vc // empty' "$json")"
	patches="$(jq -r '.patches_src // empty' "$json")"

	# Upload the log; a non-URL response means no link (the app is still listed).
	logurl=""
	if [ -f "$FAILURES_DIR/$slug.log" ]; then
		link="$(curl -sS --data-binary "@$FAILURES_DIR/$slug.log" "$XIPE_URL_BASE/" 2> /dev/null || true)"
		case "$link" in "$XIPE_URL_BASE/"*) logurl="$link" ;; esac
	fi

	base="$(app_base "$app" "$arch")"
	# A build that failed even after the engine's version-code arch fallback is a
	# genuine incompatibility, not a transient miss - flag it for the note below.
	[ "$(jq -r '.vc_fallback // false' "$json")" = "true" ] && VCFB[$base]=1
	BREC[$base]+="${arch}|${ver}|${vc}|${logurl}|${patches}|${NL}"
	[ -z "${BORDERSET[$base]:-}" ] && { BORDER+="${base}${NL}"; BORDERSET[$base]=1; }
done

# Patcher aborts (the patch set loaded, the APK was fetched, the patcher refused to
# produce one): survivors of the parent's clean-return sweep, because build_rv
# skips with rc 0 on a patch_apk failure. Same fields and same Build Failed
# section as a plain build record; the log is the <slug>_pf.log the parent
# relocated from the child's captured output. A slug with BOTH a plain record and
# a _pf twin was consumed by the build loop above, which deletes the twin.
for json in "$FAILURES_DIR"/*_pf.json; do
	slug="$(basename "${json%.json}")"          # "<slug>_pf"
	base_log="${slug%_pf}"                      # "<slug>"
	app="$(jq -r '.app // empty' "$json")"
	arch="$(jq -r '.arch // empty' "$json")"
	ver="$(version_label "$(jq -r '.version // empty' "$json")")"
	vc="$(jq -r '.vc // empty' "$json")"
	patches="$(jq -r '.patches_src // empty' "$json")"
	logurl=""
	# The parent relocates the captured log to <slug>_pf.log on the rc-0 sweep;
	# a leftover <slug>.log (its plain descriptor gone, so not a hard abort) is
	# the serial-mode alternative.
	for _pfl in "$FAILURES_DIR/${slug}.log" "$FAILURES_DIR/${base_log}.log"; do
		if [ -f "$_pfl" ]; then
			link="$(curl -sS --data-binary "@$_pfl" "$XIPE_URL_BASE/" 2> /dev/null || true)"
			case "$link" in "$XIPE_URL_BASE/"*) logurl="$link" ;; esac
			break
		fi
	done
	base="$(app_base "$app" "$arch")"
	if [ "$(jq -r '.vc_fallback // false' "$json")" = "true" ]; then VCFB[$base]=1; fi
	BREC[$base]+="${arch}|${ver}|${vc}|${logurl}|${patches}|${NL}"
	if [ -z "${BORDERSET[$base]:-}" ]; then BORDER+="${base}${NL}"; BORDERSET[$base]=1; fi
done

for json in "$FAILURES_DIR"/*_dl.json; do
	app="$(jq -r '.app // empty' "$json")"
	arch="$(jq -r '.arch // empty' "$json")"
	ver="$(version_label "$(jq -r '.version // empty' "$json")")"
	vc="$(jq -r '.vc // empty' "$json")"
	pkg="$(jq -r '.pkg // empty' "$json")"
	base="$(app_base "$app" "$arch")"
	# No log and no patches for a download failure; blob must still be 6 fields
	# (arch|ver|vc|log|patches|pkg) so the reader's columns line up.
	DREC[$base]+="${arch}|${ver}|${vc}|||${pkg}${NL}"
	[ -z "${DORDERSET[$base]:-}" ] && { DORDER+="${base}${NL}"; DORDERSET[$base]=1; }
done

# Patch-compatibility rejections: no APK was fetched, so the "version" slot carries the
# versions the bundle refused and the patches slot names the bundle to fix. When a source
# did answer and the artifact's own versionName is what the bundle refuses, the record also
# carries bytesVersion, and the line says so: "nobody made this build" and "the store served
# a different flavour of it" need different fixes.
declare -A NREC NORDERSET
NORDER=""
for json in "$FAILURES_DIR"/*_np.json; do
	app="$(jq -r '.app // empty' "$json")"
	arch="$(jq -r '.arch // empty' "$json")"
	patches="$(jq -r '.patches_src // empty' "$json")"
	pkg="$(jq -r '.pkg // empty' "$json")"
	# ".tried" is a comma list of version names; render each with its v prefix.
	tried="$(jq -r '.tried // empty' "$json")"
	ver="$(printf '%s' "$tried" | tr ',' '\n' | sed -e 's/^v//' -e '/^$/d' -e 's/^/v/' | paste -sd ' ' -)"
	vc="$(jq -r '.vc // empty' "$json")"
	patch_url="$(jq -r '.patch_url // empty' "$json")"
	bytes="$(jq -r '.bytesVersion // empty' "$json")"
	base="$(app_base "$app" "$arch")"
	# Columns: arch|ver|vc|log|patches|pkg|patch_url|bytes; the log is absent because
	# build_rv returned clean, and patch_url names the bundle release that refused.
	NREC[$base]+="${arch}|${ver}|${vc}||${patches}|${pkg}|${patch_url}|${bytes}${NL}"
	[ -z "${NORDERSET[$base]:-}" ] && { NORDER+="${base}${NL}"; NORDERSET[$base]=1; }
done

# Zero-patch builds: the tool answered with a result file listing nothing applied, so the
# engine refused the artifact. Columns match the np case (bundle link, no log, no APK to
# hunt): the reader's next step is the bundle release or the app's config, never an upload.
declare -A AREC AORDERSET
AORDER=""
for json in "$FAILURES_DIR"/*_npa.json; do
	app="$(jq -r '.app // empty' "$json")"
	arch="$(jq -r '.arch // empty' "$json")"
	patches="$(jq -r '.patches_src // empty' "$json")"
	pkg="$(jq -r '.pkg // empty' "$json")"
	ver="$(version_label "$(jq -r '.version // empty' "$json")")"
	vc="$(jq -r '.vc // empty' "$json")"
	patch_url="$(jq -r '.patch_url // empty' "$json")"
	base="$(app_base "$app" "$arch")"
	AREC[$base]+="${arch}|${ver}|${vc}||${patches}|${pkg}|${patch_url}|${NL}"
	[ -z "${AORDERSET[$base]:-}" ] && { AORDER+="${base}${NL}"; AORDERSET[$base]=1; }
done

# Bundle-unreadable rejections: the CLI could not list the bundle at all, so no version
# was ever resolved and there is nothing to hunt for or complain about per version. Like
# the build/_pf case the reason lives in the captured log, uploaded here as <slug>_lb.log
# (build.sh relocates it); unlike _np the section names the CLI too, because the mismatch
# is between the CLI's patcher library and the bundle.
declare -A LREC LORDERSET
LORDER=""
for json in "$FAILURES_DIR"/*_lb.json; do
	slug="$(basename "${json%.json}")"          # "<slug>_lb"
	base_log="${slug%_lb}"                      # "<slug>"
	app="$(jq -r '.app // empty' "$json")"
	arch="$(jq -r '.arch // empty' "$json")"
	patches="$(jq -r '.patches_src // empty' "$json")"
	cli="$(jq -r '.cli_source // empty' "$json")"
	logurl=""
	# The relocated <slug>_lb.log is "<slug>_lb" + ".log" = $slug.log; the serial tee
	# log basename <slug>.log is the fallback.
	for _lbl in "$FAILURES_DIR/${slug}.log" "$FAILURES_DIR/${base_log}.log"; do
		if [ -f "$_lbl" ]; then
			link="$(curl -sS --data-binary "@$_lbl" "$XIPE_URL_BASE/" 2> /dev/null || true)"
			case "$link" in "$XIPE_URL_BASE/"*) logurl="$link" ;; esac
			break
		fi
	done
	base="$(app_base "$app" "$arch")"
	# Columns match render_app_group's read (arch|ver|vc|log|patches|cli|patch_url);
	# ver/vc are empty (none was resolved) and the 6th column carries the cli_source.
	LREC[$base]+="${arch}|||${logurl}|${patches}|${cli}|${NL}"
	[ -z "${LORDERSET[$base]:-}" ] && { LORDER+="${base}${NL}"; LORDERSET[$base]=1; }
done
shopt -u nullglob

# arch_token <ver> <vc> — the `v<version> (<versionCode>)` code span for one arch
# line, collapsing to whatever pieces are actually known.
arch_token() { # $1=ver $2=vc
	local ver=$1 vc=$2
	[ -z "$ver" ] && { [ -n "$vc" ] && printf '(%s)' "$vc"; return 0; }
	printf '`%s%s`' "$ver" "${vc:+ ($vc)}"
}

# search_links <pkg> <base> <ver> — three engine links to locate the missing APK.
search_links() { # $1=pkg $2=base $3=ver(label, maybe 'vX')
	local enc q
	q="${1:-$2}${3:+ ${3#v}} android apk"
	enc="$(jq -rn --arg q "$q" '$q|@uri')"
	printf 'Search [Google](https://www.google.com/search?q=%s) / [DuckDuckGo](https://duckduckgo.com/?q=%s) / [Brave](https://search.brave.com/search?q=%s)' "$enc" "$enc" "$enc"
}

# render_app_group <base> <blob> <mode build|lb|dl|np> — one grouped app block. All
# modes list each arch as "arch `vX (vc)`: <link>"; build and lb link the log, download
# links the search engines, np links the patch bundle that refused the versions. Build and
# lb add a Patches line naming the failing bundle; lb additionally names the CLI, since
# an unreadable bundle is a CLI↔bundle mismatch. An 8th blob column (bytes) is the
# versionName read off an artifact that was fetched and then refused: it is appended to the
# version span as ", file is `vY`" and stays empty for every mode that never held a file.
render_app_group() { # $1=base $2=blob $3=mode
	local base=$1 blob=$2 mode=$3 out arch ver vc log patches pkg patch_url bytes tok links cli
	out="📱 *$(md_clean "$base")*"
	if [ "$mode" = build ] || [ "$mode" = lb ]; then
		patches=$(uniq_col 5 "$blob" | head -1)
		[ -n "$patches" ] && out+="${NL}  ╰ Patches: [$(md_clean "$patches")](https://github.com/$patches)"
		if [ "$mode" = lb ]; then
			cli=$(uniq_col 6 "$blob" | head -1)
			[ -n "$cli" ] && out+="${NL}  ╰ CLI: [$(md_clean "$cli")](https://github.com/$cli)"
		else
			[ -n "${VCFB[$base]:-}" ] && out+="${NL}  ╰ version-code arch fallback already tried; genuine incompatibility (not retried)"
		fi
	fi
	while IFS='|' read -r arch ver vc log patches pkg patch_url bytes; do
		[ -z "$arch" ] && continue
		tok="$(arch_token "$ver" "$vc")"
		[ -n "${bytes:-}" ] && tok="${tok}, file is \`v${bytes#v}\`"
		if [ "$mode" = build ] || [ "$mode" = lb ]; then
			[ -z "$log" ] && { out+="${NL}  ╰ ${arch}${tok:+ ${tok}}"; continue; }
			links="[Log](${log})"
		elif [ "$mode" = np ] || [ "$mode" = npa ]; then
			# No log, no APK to hunt for: the bundle is the thing that has to change.
			[ -z "$patches" ] && { out+="${NL}  ╰ ${arch}${tok:+ ${tok}}"; continue; }
			if [ -n "$patch_url" ]; then
				# Deep-link the exact release that refused, labelled "owner/repo (tag)" —
				# the tag is a version, not a path segment, and the parentheses stay outside
				# the link because a ')' inside a [label] run ends it (same grammar as the
				# release notes and the build-queue headings).
				links="$(md_clean "$patches") ([$(md_clean "${patch_url##*/}")](${patch_url}))"
			else
				links="[Patch bundle](https://github.com/$patches)"
			fi
		else
			links="$(search_links "$pkg" "$base" "$ver")"
		fi
		out+="${NL}  ╰ ${arch}${tok:+ ${tok}}: ${links}"
	done <<< "$blob"
	printf '%s' "$out"
}

# ---- Assemble the five parts ----
# Render each app block first and count only the ones that produce output, so a
# part never prints its "(N apps)" header over an empty body.
build_body=""; lb_body=""; dl_body=""; np_body=""; a_body=""; cbuild=0; clb=0; cdl=0; cnp=0; ca=0
while IFS= read -r base; do
	[ -z "$base" ] && continue
	blk="$(render_app_group "$base" "${BREC[$base]}" build)"
	[ -z "${blk//[[:space:]]/}" ] && continue
	build_body+="${blk}${NL}${NL}"; cbuild=$((cbuild + 1))
done <<< "$BORDER"
while IFS= read -r base; do
	[ -z "$base" ] && continue
	blk="$(render_app_group "$base" "${LREC[$base]:-}" lb)"
	[ -z "${blk//[[:space:]]/}" ] && continue
	lb_body+="${blk}${NL}${NL}"; clb=$((clb + 1))
done <<< "$LORDER"
while IFS= read -r base; do
	[ -z "$base" ] && continue
	blk="$(render_app_group "$base" "${NREC[$base]:-}" np)"
	[ -z "${blk//[[:space:]]/}" ] && continue
	np_body+="${blk}${NL}${NL}"; cnp=$((cnp + 1))
done <<< "$NORDER"
while IFS= read -r base; do
	[ -z "$base" ] && continue
	blk="$(render_app_group "$base" "${DREC[$base]:-}" dl)"
	[ -z "${blk//[[:space:]]/}" ] && continue
	dl_body+="${blk}${NL}${NL}"; cdl=$((cdl + 1))
done <<< "$DORDER"

while IFS= read -r base; do
	[ -z "$base" ] && continue
	blk="$(render_app_group "$base" "${AREC[$base]:-}" npa)"
	[ -z "${blk//[[:space:]]/}" ] && continue
	a_body+="${blk}${NL}${NL}"; ca=$((ca + 1))
done <<< "$AORDER"

if [ "$cbuild" = 0 ] && [ "$clb" = 0 ] && [ "$cdl" = 0 ] && [ "$cnp" = 0 ] && [ "$ca" = 0 ]; then
	echo "Failure records present but nothing renderable; no report sent."
	exit 0
fi

MSG=""
# Each section carries its own hint directly beneath it, so the guidance sits next
# to the failures it refers to instead of in a block at the very end. Section
# bodies end in a trailing blank line; $(printf '%s' …) drops it so the hint lands
# one line under the last app, and sections are joined by a single blank line.
if [ "$cbuild" -gt 0 ]; then
	MSG+="*🚨 Build Failed (${cbuild} app$([ "$cbuild" = 1 ] && echo '' || echo 's'))*${NL}${NL}$(printf '%s' "$build_body")${NL}${NL}⚠️ Report the issue to the patch author with the log link."
fi
if [ "$clb" -gt 0 ]; then
	[ -n "$MSG" ] && MSG+="${NL}${NL}"
	MSG+="*🚫 Patch Bundle Unreadable (${clb} app$([ "$clb" = 1 ] && echo '' || echo 's'))*${NL}${NL}$(printf '%s' "$lb_body")${NL}${NL}⚠️ The patch CLI could not list this bundle at all — the CLI's patcher library and the bundle do not match (see log). Pin the bundle to a version the CLI reads, or use a CLI built for it."
fi
if [ "$cnp" -gt 0 ]; then
	[ -n "$MSG" ] && MSG+="${NL}${NL}"
	MSG+="*🧩 Patch Compatibility (${cnp} app$([ "$cnp" = 1 ] && echo '' || echo 's'))*${NL}${NL}$(printf '%s' "$np_body")${NL}${NL}⚠️ These versions have no patch to apply or no patch for that arch."
fi
if [ "$ca" -gt 0 ]; then
	[ -n "$MSG" ] && MSG+="${NL}${NL}"
	MSG+="*🔩 CLI Issue (${ca} app$([ "$ca" = 1 ] && echo '' || echo 's'))*${NL}${NL}$(printf '%s' "$a_body")${NL}${NL}⚠️ The patcher applied 0 patches to these builds."
fi
if [ "$cdl" -gt 0 ]; then
	[ -n "$MSG" ] && MSG+="${NL}${NL}"
	MSG+="*📡 Download Failures (${cdl} app$([ "$cdl" = 1 ] && echo '' || echo 's'))*${NL}${NL}$(printf '%s' "$dl_body")${NL}${NL}ℹ️ Upload the APK to the [cache repo](https://github.com/${APKS_REPO:-nullcpy/apks}) manually."
fi

if [ -n "${GITHUB_REPOSITORY:-}" ] && [ -n "${GITHUB_RUN_ID:-}" ]; then
	run_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
	MSG+="${NL}${NL}⚙️ [View Run]($run_url)"
fi

# ---- Chunk on line boundaries and send ----
send_chunk() {
	local text="${1:-}"
	[ -z "$text" ] && return 0
	curl -s -X POST \
		--data-urlencode "parse_mode=Markdown" \
		--data-urlencode "disable_web_page_preview=true" \
		--data-urlencode "text=${text}" \
		--data-urlencode "chat_id=${TG_CHAT_ID}" \
		--data-urlencode "message_thread_id=${TG_THREAD_NOTIFY}" \
		"https://api.telegram.org/bot${TG_TOKEN}/sendMessage" > /dev/null || true
}

CHUNK=""
sent=0
# Blocks, not lines: an app's entry and its per-arch detail lines belong together, and a
# section heading must never be the last thing in a message (see notify_pack.sh). The
# heading pattern is this body's own Markdown: *🚨 Build Failed (2 apps)*.
while IFS= read -r -d "$PACK_RS" CHUNK; do
	if [ -n "$CHUNK" ]; then
		send_chunk "$CHUNK"
		sent=1
	fi
done < <(printf '%s' "$MSG" | pack_message "$TG_LIMIT" '^\*.*\*$')

if [ "$sent" = 1 ] && [ -n "${GITHUB_OUTPUT:-}" ]; then
	echo "reported_failures=true" >> "$GITHUB_OUTPUT"
fi

# Mirror last, and never as a failure of this step: the report's own delivery is the
# thing that decides reported_failures above, this is a copy. discord_send still
# prints what Discord said.
discord_send "${DISCORD_WEBHOOK_GITHUB_LOG:-}" "$MSG" || true
