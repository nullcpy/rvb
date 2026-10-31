#!/usr/bin/env bash

MODULE_TEMPLATE_DIR="module"
CWD=$(pwd)
TEMP_DIR="temp"
BIN_DIR="bin"
BUILD_DIR="build"
DL_SRCS=("cache_repo" "direct" "github" "fdroid" "archive" "apkmirror" "uptodown" "apkpure" "apkcombo")
BUILD_JSON_FILE="build.json"
PATCH_OUTPUT=""

if [ -z "${GITHUB_TOKEN-}" ] && command -v gh >/dev/null 2>&1; then
	GITHUB_TOKEN=$(gh auth token 2>/dev/null || true)
fi
if [ "${GITHUB_TOKEN-}" ]; then GH_HEADER="Authorization: token ${GITHUB_TOKEN}"; else GH_HEADER=; fi
NEXT_VER_CODE=${NEXT_VER_CODE:-$(date +'%Y%m%d')}
OS=$(uname -o)
DEFAULT_UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/154.0.0.0 Safari/537.36"

# Signing identity. There is deliberately no default here. CI supplies it: build.yml
# passes the KEYSTORE_* secrets to install_keystore.sh, which writes the two store
# files and exports RVB_KEYSTORE_PASS / RVB_KEY_ALIAS. A local build must set all
# four itself (see require_signing_identity below and the table in
# docs/build-engine.md#signing-and-identity).
#
# Two stores because the consumers read different keystore formats, one key pair:
#   RVB_KEYSTORE (BKS)     - ReVanced CLI calls KeyStore.getInstance("BKS", "BC")
#                            and loads the file as BKS, so this store has to be BKS
#                            for it. Morphe would also take JKS/PKCS12 (it sniffs
#                            the format and converts), but the CLI flows share this
#                            variable, so the stricter consumer decides.
#   RVB_KEYSTORE_P12 (P12)  - apksigner (--ks) and LSPatch, which load through
#                            KeyStore.getDefaultType(), i.e. PKCS12 on a modern JDK.
# NPatch also reads BKS - and it is the only consumer that asks the *JVM* for the
# BKS type (single-argument getInstance("BKS")), which is why the runner-level
# BouncyCastle install is gated on NPatch alone. ReVanced and Morphe ship their own
# BC provider and need nothing installed.
# One alias, and the engine has a single RVB_KEYSTORE_PASS it passes as both store
# and key password, so the two files must be built that way.
RVB_KEYSTORE="${RVB_KEYSTORE-}"
RVB_KEYSTORE_P12="${RVB_KEYSTORE_P12-}"
RVB_KEYSTORE_PASS="${RVB_KEYSTORE_PASS-}"
RVB_KEY_ALIAS="${RVB_KEY_ALIAS-}"

# Refuse before the first download instead of after patching: every build path
# signs (the CLI --keystore flags, apksigner on merged bundles, -k for the xposed
# flows), so a missing identity is a whole-run problem, not a per-app one. It used
# to fall back to the keystore committed by the repo template, whose private key is
# public - any fork could then produce signature-compatible "updates" for builds
# published here. Signing with someone else's key is not a default to keep.
require_signing_identity() {
	local bad=0 v
	for v in RVB_KEYSTORE RVB_KEYSTORE_P12 RVB_KEYSTORE_PASS RVB_KEY_ALIAS; do
		if [ -z "${!v-}" ]; then epr "$v is not set"; bad=1; fi
	done
	if [ -n "${RVB_KEYSTORE-}" ] && [ ! -f "$RVB_KEYSTORE" ]; then epr "keystore not found: $RVB_KEYSTORE"; bad=1; fi
	if [ -n "${RVB_KEYSTORE_P12-}" ] && [ ! -f "$RVB_KEYSTORE_P12" ]; then epr "keystore not found: $RVB_KEYSTORE_P12"; bad=1; fi
	# The password is interpolated into an eval'd command line (and into single
	# quotes for the -k arguments), so anything outside [0-9A-Za-z] would either
	# split the argument or terminate it early.
	if [ -n "${RVB_KEYSTORE_PASS-}" ] && [[ "$RVB_KEYSTORE_PASS" =~ [^0-9A-Za-z] ]]; then
		epr "RVB_KEYSTORE_PASS must be alphanumeric: it is embedded in eval'd CLI arguments"
		bad=1
	fi
	if [ -n "${RVB_KEY_ALIAS-}" ] && [[ "$RVB_KEY_ALIAS" =~ [^0-9A-Za-z_.-] ]]; then
		epr "RVB_KEY_ALIAS must not contain characters that break eval'd CLI arguments"
		bad=1
	fi
	if [ "$bad" -ne 0 ]; then
		epr "no usable signing identity - in CI set KEYSTORE_B64, KEYSTORE_P12_B64, KEYSTORE_PASSWORD and KEY_ALIAS; locally export RVB_KEYSTORE, RVB_KEYSTORE_P12, RVB_KEYSTORE_PASS and RVB_KEY_ALIAS"
		return 1
	fi
	return 0
}

# Instafel fallbacks (used when the CLI manifest lacks a commit hash, and
# when a config omits included-patches). Overridable without code edits.
RVB_INSTAFEL_FALLBACK_COMMIT="${RVB_INSTAFEL_FALLBACK_COMMIT:-8e4756f}"
RVB_INSTAFEL_DEFAULT_PATCHES="${RVB_INSTAFEL_DEFAULT_PATCHES:-unlock_developer_options remove_snooze_warning remove_ads amoled_theme instafel}"

# Morphe bundle passthrough: when the CLI tool is morphe-desktop, the freshly
# downloaded stock is a bundle format (.xapk/.apkm/.apks), and this switch is
# on, the bundle is kept as the cache artifact (instead of apkeditor-merging
# it) and passed to morphe directly — morphe merges bundles natively, and some
# APKs misbehave after apkeditor's rewrite+re-sign. Set
# RVB_MORPHE_PASSTHROUGH=false to revert to the old merge-at-download flow.
RVB_MORPHE_PASSTHROUGH="${RVB_MORPHE_PASSTHROUGH:-true}"

# Morphe's own native-lib strip: --striplibs filters at output assembly, so it reaches the
# two things a rewrite of the input cannot - the multi-ABI libs a bundle's base.apk
# carries, and any lib/<dir> that names no ABI, which _strip_apk_abis deliberately leaves
# alone rather than claiming to know. Both sides read the one keep-list,
# _striplibs_keep_of_arch. On a plain APK the flag REPLACES the engine's rewrite instead of
# stacking on it: deleting entries from a signed archive deletes its signing block too, so
# an engine-rewritten input reaches the patcher unsigned (_patcher_strips_libs keeps the
# two decisions in one place). The bundle trim is unaffected - a bundle member is never
# rewritten, only dropped whole. Set RVB_MORPHE_STRIPLIBS=false to drop the flag and go
# back to patching a stripped input - the bisect switch, same shape as the passthrough knob
# above.
RVB_MORPHE_STRIPLIBS="${RVB_MORPHE_STRIPLIBS:-true}"

declare -gA __PREBUILTS_CACHE__
declare -g __PREBUILTS_RESULT=""
declare -gA __PATCHES_LIST_CACHE__
declare -gA __PATCH_VER_CACHE__
declare -gA __PKG_VERS_CACHE__
declare -gA __DL_RESP_CACHE__
declare -gA __EFF_PATCH_VER_CACHE__

# Patcher tool registry: resolve_patcher() + PATCHER_* flags.
# RVB_PATCHERS_SH lets the trace harness point at it when utils.sh is sourced
# from a process substitution (same trick as scripts/cf_get.py lookup below).
_RVB_PATCHERS_SH="${RVB_PATCHERS_SH:-${CWD}/.github/scripts/patchers.sh}"
[ ! -f "$_RVB_PATCHERS_SH" ] && [ -n "${BASH_SOURCE[0]:-}" ] && _RVB_PATCHERS_SH="$(dirname "$(dirname "${BASH_SOURCE[0]}")")/.github/scripts/patchers.sh"
if [ -f "$_RVB_PATCHERS_SH" ]; then
	# shellcheck disable=SC1090
	source "$_RVB_PATCHERS_SH"
else
	echo "FATAL: patcher registry not found at $_RVB_PATCHERS_SH" >&2
	exit 1
fi

toml_file_to_json() {
	local f="$1"
	if [ ! -f "$f" ]; then return 1; fi
	if [[ "$f" == *.toml ]]; then
		local res=""
		if [ -n "${TOML-}" ] && [ -x "$TOML" ] 2>/dev/null; then
			if res=$("$TOML" --output json --file "$f" . 2>/dev/null) && [ -n "$res" ]; then
				echo "$res"
				return 0
			fi
		fi
		if command -v python3 >/dev/null 2>&1 || command -v python >/dev/null 2>&1; then
			local py_bin="python3"
			command -v python3 >/dev/null 2>&1 || py_bin="python"
			if res=$("$py_bin" -c "
try:
    import tomllib
except ImportError:
    try:
        import tomli as tomllib
    except ImportError:
        import sys; sys.exit(1)
import json, sys
print(json.dumps(tomllib.load(open(sys.argv[1], 'rb'))))
" "$f" 2>/dev/null) && [ -n "$res" ]; then
				echo "$res"
				return 0
			fi
		fi
		if command -v yq >/dev/null 2>&1; then
			if res=$(yq -o=json eval '.' "$f" 2>/dev/null) && [ -n "$res" ]; then
				echo "$res"
				return 0
			fi
		fi
		abort "Neither python (tomllib/tomli) nor yq is available to parse $f"
	elif [[ "$f" == *.json ]]; then
		cat "$f"
	else
		abort "config extension not supported: $f"
	fi
}

toml_merge_configs() {
	local files=("$@")
	local jsons=()
	for f in "${files[@]}"; do
		[ -f "$f" ] || continue
		local file_json
		file_json=$(toml_file_to_json "$f") || continue

		local propagated
		propagated=$(jq '
			(to_entries | map(select(.value | type != "object")) | from_entries) as $defaults |
			map_values(
				if type == "object" then
					($defaults + .)
				else . end
			)
		' <<<"$file_json")
		jsons+=("$propagated")
	done

	if [ ${#jsons[@]} -eq 0 ]; then
		echo "{}"
	else
		printf '%s\n' "${jsons[@]}" | jq -s 'add // {}'
	fi
}

toml_prep() {
	if [ ! -f "$1" ]; then return 1; fi
	__TOML__=$(toml_file_to_json "$1") || abort "failed to parse config file: $1"
}
toml_get_table_names() { jq -r -e 'to_entries[] | select(.value | type == "object") | .key' <<<"$__TOML__" | tr -d '\r'; }
toml_get_table_main() { jq -r -e 'to_entries | map(select(.value | type != "object")) | from_entries' <<<"$__TOML__"; }
toml_get_table() { jq -r -e ".\"${1}\"" <<<"$__TOML__"; }
toml_get() {
	local op quote_placeholder=$'\001'
	op=$(jq -r ".\"${2}\" | values" <<<"$1")
	if [ "$op" ]; then
		op="${op#"${op%%[![:space:]]*}"}"
		op="${op%"${op##*[![:space:]]}"}"
		op=${op//\\\'/$quote_placeholder}
		op=${op//"''"/$quote_placeholder}
		op=${op//"'"/'"'}
		op=${op//$quote_placeholder/$'\''}
		echo "$op"
	else return 1; fi
}

pr() { echo >&2 -e "\033[0;32m[+] ${1}\033[0m"; }
epr() {
	echo >&2 -e "\033[0;31m[-] ${1}\033[0m"
	if [ "${GITHUB_REPOSITORY-}" ]; then echo >&2 -e "::error::utils.sh [-] ${1}\n"; fi
}
wpr() {
	echo >&2 -e "\033[0;33m[!] ${1}\033[0m"
	if [ "${GITHUB_REPOSITORY-}" ]; then echo >&2 -e "::warning::utils.sh [!] ${1}\n"; fi
}
abort() {
	epr "ABORT: ${1-}"
	# In a pooled child (build.sh parallel-jobs) the parent owns the shared
	# tmp-file sweep — deleting temp/*tmp.* here would kill sibling downloads.
	if [ "${RVB_CHILD-}" = 1 ]; then
		trap - SIGTERM SIGINT EXIT
		exit 1
	fi
	rm -rf ./${TEMP_DIR}/*tmp.* ./${TEMP_DIR}/*/*tmp.* ./${TEMP_DIR}/*-temporary-files ./${TEMP_DIR}/*.apk-temporary-files ./*-temporary-files
	trap - SIGTERM SIGINT EXIT
	exit 1
}
# -- Per-app failure records (temp/failures) ---------------------------------
# build.sh's post-build CI step reads these to report per-app failures once the
# engine finishes. Each record is one jq-built JSON file; the engine writes them,
# the CI step consumes them. Kept notification-free on purpose (no Telegram/curl
# here) so the engine stays pure. A build failure leaves <slug>.json (descriptor)
# plus <slug>.log (attached by build.sh's parent); a download-exhaustion leaves
# only <slug>_dl.json; a patch-set rejection leaves only <slug>_np.json; a patcher
# abort (which skips with rc 0, so the plain descriptor is wiped as a "clean"
# return) leaves the survivor pair <slug>_pf.json plus <slug>_pf.log — the parent
# copies the build log onto that name before the sweep; and a bundle the CLI cannot
# list at all (list-patches itself aborted, so the build never reaches the version
# point that writes the plain descriptor) leaves <slug>_lb.json plus <slug>_lb.log —
# again the parent relocates the captured log onto that name. All fail-soft: a write
# error never aborts a build.
#
# The slug is derived from the display label "$table" (which already carries the
# arch, e.g. "Foo (arm64-v8a)"), lowercased with every non-alphanumeric run
# collapsed to a single '-'. build.sh and build_rv compute it identically so the
# descriptor and the parent-attached log share a basename.
failure_slug() { # $1=label ($table)
	printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-//; s/-$//'
}

# write_build_failure_descriptor — record an intended build for the current app so
# that if any later step aborts, the parent can attach the log and report it.
# Deleted by the parent on a clean build_rv return. Called from build_rv once the
# version, version-code and patches-source are all resolved.
write_build_failure_descriptor() { # $1=slug $2=app $3=version $4=vc $5=arch $6=patches_src
	[ -n "${TEMP_DIR:-}" ] || return 0
	local dir="$TEMP_DIR/failures"
	mkdir -p "$dir" 2> /dev/null || return 0
	jq -n --arg type "build_failed" --arg app "$2" --arg version "$3" \
		--arg vc "$4" --arg arch "$5" --arg patches_src "$6" \
		'{type:$type, app:$app, version:$version, vc:$vc, arch:$arch, patches_src:$patches_src}' \
		> "$dir/$1.json" 2> /dev/null || true
}

# write_dl_failure_descriptor — record that every configured download source was
# exhausted for this app. Emitted and build_rv returns 0 (skip), so the parent
# never sees a non-zero rc for it and does not touch it.
write_dl_failure_descriptor() { # $1=slug $2=app $3=version $4=vc $5=arch $6=pkg
	[ -n "${TEMP_DIR:-}" ] || return 0
	local dir="$TEMP_DIR/failures"
	mkdir -p "$dir" 2> /dev/null || return 0
	jq -n --arg type "dl_exhausted" --arg app "$2" --arg version "$3" \
		--arg vc "$4" --arg arch "$5" --arg pkg "$6" \
		'{type:$type, app:$app, version:$version, vc:$vc, arch:$arch, pkg:$pkg}' \
		> "$dir/$1_dl.json" 2> /dev/null || true
}

# write_no_patches_failure_descriptor — record that every supported version of this
# app was rejected by the patch set (no compatible patch, or no build for the
# requested arch), so NOTHING was ever fetched. Distinct from the dl record above:
# reporting this one as a download failure asks for a manual APK upload of a file that
# is already cached and sends the patch author no message at all. Like the dl record
# it uses its own suffix, because the parent deletes <slug>.json/.log on a clean (rc 0)
# return and build_rv skips with rc 0 here.
# $1=slug $2=app $3=versions-tried $4=requested $5=vc $6=arch $7=patches_src $8=pkg $9=patch-release-url
write_no_patches_failure_descriptor() {
	[ -n "${TEMP_DIR:-}" ] || return 0
	local dir="$TEMP_DIR/failures"
	mkdir -p "$dir" 2> /dev/null || return 0
	jq -n --arg type "no_compatible_patches" --arg app "$2" --arg tried "$3" \
		--arg version "$4" --arg vc "$5" --arg arch "$6" --arg patches_src "$7" --arg pkg "$8" \
		--arg patch_url "$9" \
		'{type:$type, app:$app, tried:$tried, version:$version, vc:$vc, arch:$arch, patches_src:$patches_src, pkg:$pkg, patch_url:$patch_url}' \
		> "$dir/$1_np.json" 2> /dev/null || true
}

# write_patch_failure_record — record that the patcher itself aborted this build
# (patch_apk returned non-zero, "Patching aborted"). build_rv still returns 0 for
# it — the per-app fail-soft skip — so the plain <slug>.json descriptor is deleted
# by the parent's clean-return sweep and the serial tee log with it. The _pf suffix
# survives that sweep the way _dl/_np do, and the parent copies the captured build
# log to <slug>_pf.log so the report can link it: the abort reason lives only in
# that log. Fields mirror write_build_failure_descriptor so the CI step renders the
# record in the same Build Failed section.
# $1=slug $2=app $3=version $4=vc $5=arch $6=patches_src
write_patch_failure_record() {
	[ -n "${TEMP_DIR:-}" ] || return 0
	local dir="$TEMP_DIR/failures"
	mkdir -p "$dir" 2> /dev/null || return 0
	jq -n --arg type "patch_failed" --arg app "$2" --arg version "$3" \
		--arg vc "$4" --arg arch "$5" --arg patches_src "$6" \
		'{type:$type, app:$app, version:$version, vc:$vc, arch:$arch, patches_src:$patches_src}' \
		> "$dir/$1_pf.json" 2> /dev/null || true
}

# write_unlistable_failure_descriptor — record that the patch CLI could not list the
# patch bundle AT ALL (patches_list itself aborted, e.g. the bundle was built against
# a different patcher library than the CLI ships, so loading any patch class throws).
# This is distinct from the _np record above: there the bundle answered and simply had
# no patch for the candidate versions; here the bundle cannot be interrogated at all,
# so no version is ever resolved and the build aborts (rc 1) at the version-resolution
# pre-pass, BEFORE the plain <slug>.json descriptor is written. Without this record the
# failure is silent to the notification step, which reads only temp/failures. It returns
# rc 1 (a real abort, not the rc-0 skips of _dl/_np/_pf), so the parent attaches the
# captured log as <slug>_lb.log rather than deleting a descriptor that was never made.
# $1=slug $2=app $3=arch $4=patches_src $5=cli_source $6=pkg
write_unlistable_failure_descriptor() {
	[ -n "${TEMP_DIR:-}" ] || return 0
	local dir="$TEMP_DIR/failures"
	mkdir -p "$dir" 2> /dev/null || return 0
	jq -n --arg type "bundle_unreadable" --arg app "$2" --arg arch "$3" \
		--arg patches_src "$4" --arg cli_source "$5" --arg pkg "$6" \
		'{type:$type, app:$app, arch:$arch, patches_src:$patches_src, cli_source:$cli_source, pkg:$pkg}' \
		> "$dir/$1_lb.json" 2> /dev/null || true
}

# clear_patch_failure_record — drop the survivor pair for a build that ultimately
# produced its artifact. build_rv calls it on a dedup skip (content already
# published), so a patcher abort earlier in the same build must not re-report or
# re-queue an app+arch that shipped. Stale records would otherwise loop the app.
clear_patch_failure_record() { # $1=slug
	[ -n "${TEMP_DIR:-}" ] || return 0
	rm -f "$TEMP_DIR/failures/$1_pf.json" "$TEMP_DIR/failures/$1_pf.log" 2> /dev/null || true
}
# env -i keeps JVM runs hermetic; XDG_DATA_HOME is forwarded so callers can
# relocate an app's per-user state dir out of the shared HOME (see the
# instafel flows) — without it, parallel builds race on $HOME state.
java() {
	local -a java_env=(PATH="$PATH" HOME="$HOME" LANG="${LANG:-en_US.UTF-8}")
	[ -n "${XDG_DATA_HOME:-}" ] && java_env+=(XDG_DATA_HOME="$XDG_DATA_HOME")
	env -i "${java_env[@]}" java --enable-native-access=ALL-UNNAMED "$@";
}

# Per-forge release API endpoints. $2 is always "owner/repo" (gitlab URL-encodes
# it because its API keys projects by numeric/encoded path).
# codeberg.org runs Forgejo, whose REST API is the Gitea one: paths hang off
# /api/v1/repos/<owner>/<repo>, releases carry prerelease/published_at like GitHub,
# but pagination uses limit (per_page is ignored) and an asset's API url is null -
# only browser_download_url is populated. Hence the dedicated helpers below rather
# than reusing github's case arms wholesale.
source_release_api_base() {
	local host=${1,,} src=$2 encoded
	case "$host" in
		github) echo "https://api.github.com/repos/${src}/releases" ;;
		codeberg) echo "https://codeberg.org/api/v1/repos/${src}/releases" ;;
		gitlab)
			encoded=$(jq -nr --arg v "$src" '$v | @uri')
			echo "https://gitlab.com/api/v4/projects/${encoded}/releases"
			;;
		*) return 1 ;;
	esac
}

# Release listing URL, with the pagination parameter that forge actually honours.
# Asking Codeberg for per_page=100 silently returns its 30-item default page, which
# would make an older release look like it no longer exists; limit=50 is that API's
# page maximum, and it lists newest-first like the others.
source_release_list_url() {
	local host=${1,,} src=$2 base
	base=$(source_release_api_base "$host" "$src") || return 1
	case "$host" in
	codeberg) echo "${base}?limit=50" ;;
	*) echo "${base}?per_page=100" ;;
	esac
}

# Human-facing release page: $1=host $2=owner/repo $3=tag. This is the one owner of
# that shape - changelog.md, build metadata and the release notes all derive it from
# here instead of repeating the per-forge literal.
source_release_web_url() {
	local host=${1,,} src=$2 tag=$3
	case "$host" in
		github) echo "https://github.com/${src}/releases/tag/${tag}" ;;
		# Forgejo/Gitea keeps GitHub's /releases/tag/<tag> web layout
		codeberg) echo "https://codeberg.org/${src}/releases/tag/${tag}" ;;
		gitlab) echo "https://gitlab.com/${src}/-/releases/${tag}" ;;
		*) return 1 ;;
	esac
}

source_release_tag_api() {
	local host=${1,,} src=$2 tag=$3 base
	base=$(source_release_api_base "$host" "$src") || return 1
	case "$host" in
		# This is the path a resolved tag takes (a concrete pin, or a channel keyword
		# answered from state/patch_sources.json), so every supported forge needs an
		# arm here - Forgejo keeps GitHub's /releases/tags/<tag> layout.
		github | codeberg) echo "${base}/tags/${tag}" ;;
		gitlab) echo "${base}/${tag}" ;;
		*) return 1 ;;
	esac
}

source_release_assets_json() {
	local host=${1,,}
	case "$host" in
		# Codeberg assets sit directly under .assets[] like GitHub's, and a release
		# there commonly ships a metadata sidecar (output-metadata.json) next to the
		# apk, so the same .json/.asc filter matters.
		github | codeberg) jq -e '[.assets[]? | select(.name | (endswith("asc") or endswith("json")) | not)]' ;;
		gitlab) jq -e '[.assets.links[]? | select(.name | (endswith("asc") or endswith("json")) | not)]' ;;
		*) return 1 ;;
	esac
}

source_release_asset_url() {
	local host=${1,,}
	case "$host" in
		github) jq -r '.url' ;;
		# .url is null on Forgejo/Gitea installations; browser_download_url is the
		# only usable link (and needs no auth header for public repos).
		codeberg) jq -r '.browser_download_url // .url' ;;
		gitlab) jq -r '.direct_asset_url // .url' ;;
		*) return 1 ;;
	esac
}

# The pre-release marker words of a release tag, as a jq regex, for the forges whose
# releases carry no pre-release flag. .github/scripts/channels.py owns the
# vocabulary (the watcher and the config compiler import it); this is the engine's
# copy, assembled from the same word list so the words appear once here too, and
# .github/traces/test_channel_markers.sh fails the suite if the two strings stop
# being identical. The class around the word is what keeps `rc` from firing inside
# "arch" and `exp` from firing inside "-express".
RVB_CHANNEL_MARKERS="dev alpha beta rc pre experimental exp"
channel_beta_re() {
	local alt=${RVB_CHANNEL_MARKERS// /|}
	printf '%s%s%s' '[-._](' "$alt" ')([^a-zA-Z]|$)'
}

source_release_pick_from_list() {
	# $2 = channel keyword: "beta" or anything else (read as stable). "dev" is not a
	# keyword any more, so it is not tested here even though a release TAG may
	# contain it (v1.2.3-dev.4) - that is matched by the gitlab pattern below.
	local host=${1,,} mode=$2
	case "$host" in
		github | codeberg)
			# .draft is always false for GitHub (its API omits drafts entirely) but
			# Forgejo lists them, and an unpublished release is nobody's channel entry.
			# Both forges carry a per-release pre-release flag, so the flag alone
			# decides here: a tag name must not override what the publisher ticked.
			if [ "$mode" = beta ]; then
				jq -e -c 'map(select(.prerelease == true and .draft != true and .tag_name != null and .tag_name != "")) | sort_by(.published_at // .created_at // "") | reverse | .[0] // empty'
			else
				jq -e -c 'map(select(.prerelease != true and .draft != true and .tag_name != null and .tag_name != "")) | sort_by(.published_at // .created_at // "") | reverse | .[0] // empty'
			fi
			;;
		gitlab)
			# A GitLab release has no pre-release flag, so the tag name is the only
			# signal there. channel_beta_re is the shell copy of channels.py.
			local marker_re
			marker_re=$(channel_beta_re)
			if [ "$mode" = beta ]; then
				jq -e -c --arg re "$marker_re" 'map(select(.tag_name != null and .tag_name != "" and (.tag_name | test($re; "i")))) | sort_by(.released_at // .created_at // "") | reverse | .[0] // empty'
			else
				jq -e -c --arg re "$marker_re" 'map(select(.tag_name != null and .tag_name != "" and (.tag_name | test($re; "i") | not))) | sort_by(.released_at // .created_at // "") | reverse | .[0] // empty'
			fi
			;;
		*) return 1 ;;
	esac
}

get_apkeditor() {
	if [ -f "$TEMP_DIR/apkeditor.jar" ]; then return 0; fi
	local api_resp dl_url
	api_resp=$(gh_req "https://api.github.com/repos/REAndroid/APKEditor/releases/latest" -) || true
	dl_url=$(echo "$api_resp" | jq -r '.assets[]? | select(.name | endswith(".jar")) | .browser_download_url' | head -1) || true
	if [ -z "$dl_url" ] || [ "$dl_url" = "null" ]; then
		dl_url="https://github.com/REAndroid/APKEditor/releases/download/V1.4.9/APKEditor-1.4.9.jar"
	fi
	gh_dl "$TEMP_DIR/apkeditor.jar" "$dl_url" >/dev/null || return 1
}

# Result is published through the global __PREBUILTS_RESULT instead of stdout on
# purpose: callers MUST invoke this directly (NOT via $(...)). Command
# substitution runs in a subshell, so the __PREBUILTS_CACHE__ write below would
# be discarded there and every call would miss the cache and re-hit the release
# API. Printing to a global keeps both the cache write and the read in the main
# shell so repeated apps sharing a source set are served from memory.
get_prebuilts() {
	local cache_key="${1}_${2}_${3}_${4}_${5}_${6}"
	if [ -n "${__PREBUILTS_CACHE__["$cache_key"]:-}" ]; then
		__PREBUILTS_RESULT="${__PREBUILTS_CACHE__["$cache_key"]}"
		return 0
	fi
	local result
	if ! result=$(_get_prebuilts "$@"); then return 1; fi
	__PREBUILTS_CACHE__["$cache_key"]="$result"
	__PREBUILTS_RESULT="$result"
}

# Canonical on-disk folder for a source's downloaded release assets. Namespaced by
# forge host AND the full owner/repo so that two repos under one owner (e.g.
# hxreborn/morphe-patches vs hxreborn/hxreborn-tiktok-patches), or the same
# owner/repo on GitHub vs GitLab, never share a folder and cross-match by version.
# Lowercased; '/' becomes '__'; the legacy '-rv' (ReVanced) marker is kept.
rv_release_dir() { # $1=host (github|gitlab) $2=owner/repo -> ${TEMP_DIR}/<host>__<owner>__<repo>-rv
	local slug=${2,,}
	slug=${slug//\//__}
	printf '%s/%s__%s-rv' "$TEMP_DIR" "${1,,}" "$slug"
}

# Canonical release channel of a version value, or empty when it is not a channel
# keyword. "stable" and "beta" are the entire vocabulary - CONFIG.md documents
# nothing else, and compile_patch_configs.py routes pools on the same two words.
# Anything else (a concrete tag, or a word someone typed by mistake) goes down the
# exact-release path, so "latest" fails loudly at the release API instead of
# quietly building whichever channel a fallback happened to pick. "both" is pool
# routing that build.sh resolves from the config it was given before a build ever
# sees it, so it is deliberately not a channel here. Keeping the two tests in one
# function is what stops the beta/stable branch conditions from drifting apart.
_release_channel_of() {
	case "${1,,}" in
	stable) echo stable ;;
	beta) echo beta ;;
	*) echo "" ;;
	esac
}

# Concrete tag the watcher recorded for one patch source, or nothing.
# $1=owner/repo (any case) $2=host $3=channel (stable|beta)
# state/patch_sources.json is the watcher's snapshot of every patch source's
# current release per channel (see sync_patch_sources.py); reading it here saves
# a release listing plus a second copy of the selection heuristics. A blocked
# source is reported as "no tag" here even though the snapshot still carries its
# last known tag - callers must check _patch_source_state_blocked and skip it.
# RVB_PATCH_SOURCES_JSON lets the trace harness pin the lookup off, the same way
# RVB_PATCHERS_SH does. The type==object filter skips metadata keys: jq errors out
# of the whole program on ".value.repo" of a string, which would silently disable
# every resolution.
_patch_source_state_tag() {
	local file="${RVB_PATCH_SOURCES_JSON:-state/patch_sources.json}"
	[ -f "$file" ] || return 0
	jq -r --arg repo "${1,,}" --arg host "${2:-github}" --arg ch "$3" '
		to_entries
		| map(select(.value | type == "object"))
		| map(select(((.value.repo // .key) | ascii_downcase) == $repo))
		| map(select(((.value.host // "github") | ascii_downcase) == $host))
		| (.[0].value // {}) as $e
		| if $e.blocked == true then "" else ($e[$ch] // "") end
	' "$file"
}

# Is this patch source's repository blocked? Success = yes. $1=owner/repo (any case)
# $2=host
# sync_patch_sources.py marks an entry blocked when the forge answers 404 (deleted
# or renamed), 451 (legal takedown) or 403 (made private / access refused), and
# freezes whatever tags it last knew. Those are not things a retry or a live listing
# can fix, so a build must not spend a request on them - see _get_prebuilts.
# A missing file, an unknown source or a jq error all answer "not blocked", which
# leaves the live listing path as the default behaviour.
_patch_source_state_blocked() {
	local file="${RVB_PATCH_SOURCES_JSON:-state/patch_sources.json}"
	[ -f "$file" ] || return 1
	jq -e --arg repo "${1,,}" --arg host "${2:-github}" '
		to_entries
		| map(select(.value | type == "object"))
		| map(select(((.value.repo // .key) | ascii_downcase) == $repo))
		| map(select(((.value.host // "github") | ascii_downcase) == $host))
		| (.[0].value.blocked // false)
	' "$file" >/dev/null
}

_get_prebuilts() {
	local cli_host=$1 cli_src=$2 cli_ver=$3 patches_host_list=$4 patches_src_list=$5 patches_ver_list=$6
	resolve_patcher "$cli_src"
	
	local first_patch_src
	first_patch_src=$(list_args "$patches_src_list" | tr -d \"\' | head -n 1)
	# The "Getting prebuilts" header is printed lazily, exactly once, the first
	# time a file actually needs to be downloaded (see the download sites below),
	# so fully disk-cached runs stay silent instead of repeating it per app.
	local prebuilts_header_printed=false

	local first_patch_host
	first_patch_host=$(list_args "$patches_host_list" | tr -d \"\' | head -n 1)
	local cl_dir
	cl_dir=$(rv_release_dir "$first_patch_host" "$first_patch_src")
	[ -d "$cl_dir" ] || mkdir "$cl_dir"

	local host=$cli_host src=$cli_src tag="CLI" ver=${cli_ver} fprefix="cli"
	host=${host,,}
	if ! isoneof "$host" github gitlab codeberg; then abort "source host '$host' is not supported"; fi

	local grab_cl=false
	local dir
	dir=$(rv_release_dir "$host" "$src")
	[ -d "$dir" ] || mkdir "$dir"

	local rv_rel release resp tag_name matches asset name url channel
	rv_rel=$(source_release_list_url "$host" "$src") || return 1
	# The CLI is not in the watcher snapshot (that file tracks patch sources only),
	# so its channel keyword still resolves through the live listing below.
	channel=$(_release_channel_of "$ver")
	if [ "$channel" = beta ]; then
		resp=$(source_release_req "$host" "$rv_rel" -) || return 1
		release=$(source_release_pick_from_list "$host" beta <<<"$resp") || true
		ver=$(jq -r '.tag_name' <<<"$release") || true
		if [ -z "$ver" ] || [ "$ver" = "null" ]; then
			ver=$(jq -e -r '.[].tag_name' <<<"$resp" | get_highest_ver) || return 1
			release="" # Clear release if we had to fallback to get_highest_ver
		fi
	fi
	if [ "$channel" = stable ]; then
		resp=$(source_release_req "$host" "$rv_rel" -) || return 1
		release=$(source_release_pick_from_list "$host" stable <<<"$resp") || return 1
	elif [ -z "${release:-}" ]; then
		rv_rel=$(source_release_tag_api "$host" "$src" "$ver") || return 1
		release=$(source_release_req "$host" "$rv_rel" -) || return 1
	fi
	tag_name=$(jq -r '.tag_name' <<<"$release") || return 1
	name_ver=$tag_name

	local file
	file=$(find "$dir" -name "*${fprefix}-${name_ver#v}.*" -type f 2>/dev/null | head -1)
	if [ -z "$file" ]; then
		matches=$(source_release_assets_json "$host" <<<"$release") || return 1
		if [ "$(jq 'length' <<<"$matches")" -gt 1 ]; then
			local matches_new
			matches_new=$(jq -e -r 'map(select(.name | test("\\.(jar|zip)$"; "i")))' <<<"$matches" 2>/dev/null) || true
			if [ -n "$matches_new" ] && [ "$(jq 'length' <<<"$matches_new")" -ge 1 ]; then
				matches=$matches_new
			fi
		fi
		if [ "$(jq 'length' <<<"$matches")" -gt 1 ]; then
			local matches_new
			matches_new=$(jq -e -r 'map(select(.name | contains("-dev") | not))' <<<"$matches")
			if [ "$(jq 'length' <<<"$matches_new")" -eq 1 ]; then
				matches=$matches_new
			fi
		fi
		if [ "$(jq 'length' <<<"$matches")" -gt 1 ]; then
			local matches_new
			matches_new=$(jq -e -r 'map(select(.name | contains("debug") | not))' <<<"$matches")
			if [ "$(jq 'length' <<<"$matches_new")" -ge 1 ]; then
				matches=$matches_new
			fi
		fi
		if [ "$(jq 'length' <<<"$matches")" -gt 1 ]; then
			local matches_new
			matches_new=$(jq --arg ver "${name_ver#v}" -e -r 'map(select(.name | contains($ver)))' <<<"$matches")
			if [ "$(jq 'length' <<<"$matches_new")" -ge 1 ]; then
				matches=$matches_new
			fi
		fi
		if [ "$(jq 'length' <<<"$matches")" -eq 0 ]; then
			epr "No asset was found"
			return 1
		elif [ "$(jq 'length' <<<"$matches")" -ne 1 ]; then
			wpr "More than 1 asset was found for this release. Falling back to the first one found..."
		fi
		asset=$(jq -r ".[0]" <<<"$matches")
		url=$(source_release_asset_url "$host" <<<"$asset")
		name=$(jq -r .name <<<"$asset")
		file="${dir}/${name}"
		if [ "$prebuilts_header_printed" != true ]; then pr "Getting prebuilts (${first_patch_src%/*})" >&2; prebuilts_header_printed=true; fi
		if [ "$host" = github ]; then
			gh_dl "$file" "$url" >&2 || return 1
		else
			pr "Getting '$file' from '$url'"
			_req "$url" "$file" -H "Accept: application/octet-stream" >&2 || return 1
		fi
		echo "$tag: $(cut -d/ -f1 <<<"$src")/${name}  " >>"${cl_dir}/changelog.md"
	else
		grab_cl=false
		name=$(basename "$file")
		tag_name=$(cut -d'-' -f3- <<<"$name")
		tag_name=v${tag_name%.*}
	fi

	echo -n "$file "

	local IFS=$'\n'
	local p_srcs=($(list_args "$patches_src_list" | tr -d \"\'))
	local p_hosts=($(list_args "$patches_host_list" | tr -d \"\'))
	local p_vers=($(list_args "$patches_ver_list" | tr -d \"\'))
	unset IFS
	for i in "${!p_srcs[@]}"; do
		local host="${p_hosts[$i]:-${p_hosts[0]}}"
		local src="${p_srcs[$i]}"
		local ver="${p_vers[$i]:-${p_vers[0]}}"
		
		host=${host,,}
		if ! isoneof "$host" github gitlab codeberg; then abort "source host '$host' is not supported"; fi
		local tag="Patches" fprefix="patches"
		local grab_cl=true
		
		# Reset per-source resolution state. `local` re-declaration does NOT clear a
		# variable already local to this function, so release would otherwise leak from
		# the CLI block (or the previous source). The concrete-version branch below is
		# gated on [ -z "$release" ], so a stale release would skip the tag fetch and
		# resolve this source's bundle from the wrong release entirely.
		local rv_rel resp tag_name matches asset name url release=""
		local dir
		dir=$(rv_release_dir "$host" "$src")
		[ -d "$dir" ] || mkdir "$dir"
		
		rv_rel=$(source_release_list_url "$host" "$src") || return 1
		local channel snap_tag
		# Gone, taken down or unreachable as far as the forge is concerned: skip the
		# whole app rather than spend a live listing on it (and on every arch of it).
		# Checked before any version handling, because a pinned tag of a dead repo is
		# just as undownloadable as a keyword - build.sh logs the skip and moves on.
		if _patch_source_state_blocked "$src" "$host"; then
			epr "Patch source '$src' is blocked in the watcher state (repository gone, taken down or inaccessible); not building this app"
			return 1
		fi
		# A channel keyword is a question the watcher has already answered: this
		# source's current stable/beta release is recorded in the state snapshot the
		# build job checked out. Resolve from there (one local read, and no second
		# copy of the selection heuristics); on a miss - unknown source, or no tag
		# recorded for that channel - fall through to the live path below unchanged.
		channel=$(_release_channel_of "$ver")
		if [ -n "$channel" ]; then
			snap_tag=$(_patch_source_state_tag "$src" "$host" "$channel")
			if [ -n "$snap_tag" ]; then
				pr "Resolved '$src' ($channel) to '$snap_tag' from state snapshot" >&2
				ver="$snap_tag"
				channel=""
			fi
		fi
		if [ "$channel" = beta ]; then
			resp=$(source_release_req "$host" "$rv_rel" -) || return 1
			release=$(source_release_pick_from_list "$host" beta <<<"$resp") || true
			ver=$(jq -r '.tag_name' <<<"$release") || true
			if [ -z "$ver" ] || [ "$ver" = "null" ]; then
				ver=$(jq -e -r '.[].tag_name' <<<"$resp" | get_highest_ver) || return 1
				release="" # Clear release if we had to fallback to get_highest_ver
			fi
		fi
		if [ "$channel" = stable ]; then
			resp=$(source_release_req "$host" "$rv_rel" -) || return 1
			release=$(source_release_pick_from_list "$host" stable <<<"$resp") || return 1
		elif [ -z "${release:-}" ]; then
			rv_rel=$(source_release_tag_api "$host" "$src" "$ver") || return 1
			release=$(source_release_req "$host" "$rv_rel" -) || return 1
		fi
		tag_name=$(jq -r '.tag_name' <<<"$release") || return 1
		name_ver=$tag_name

		local file
		file=$(find "$dir" -name "*${fprefix}-${name_ver#v}.*" -type f 2>/dev/null | head -1)
		if [ -z "$file" ]; then
			matches=$(source_release_assets_json "$host" <<<"$release") || return 1
			if [ "$(jq 'length' <<<"$matches")" -gt 1 ]; then
				local matches_new
				matches_new=$(jq -e -r --arg re "$PATCHER_BUNDLE_RE" 'map(select(.name | test($re; "i")))' <<<"$matches") || true
				if [ -n "$matches_new" ] && [ "$(jq 'length' <<<"$matches_new")" -ge 1 ]; then
					matches=$matches_new
				fi
			fi
			if [ "$(jq 'length' <<<"$matches")" -gt 1 ]; then
				local matches_new
				matches_new=$(jq -e -r 'map(select(.name | contains("-dev") | not))' <<<"$matches")
				if [ "$(jq 'length' <<<"$matches_new")" -eq 1 ]; then
					matches=$matches_new
				fi
			fi
			if [ "$(jq 'length' <<<"$matches")" -gt 1 ]; then
				local matches_new
				matches_new=$(jq -e -r 'map(select(.name | contains("debug") | not))' <<<"$matches")
				if [ "$(jq 'length' <<<"$matches_new")" -ge 1 ]; then
					matches=$matches_new
				fi
			fi
			if [ "$(jq 'length' <<<"$matches")" -gt 1 ]; then
				local matches_new
				matches_new=$(jq --arg ver "${name_ver#v}" -e -r 'map(select(.name | contains($ver)))' <<<"$matches")
				if [ "$(jq 'length' <<<"$matches_new")" -ge 1 ]; then
					matches=$matches_new
				fi
			fi
			if [ "$(jq 'length' <<<"$matches")" -eq 0 ]; then
				epr "No asset was found"
				return 1
			elif [ "$(jq 'length' <<<"$matches")" -ne 1 ]; then
				wpr "More than 1 asset was found for this release. Falling back to the first one found..."
			fi
			asset=$(jq -r ".[0]" <<<"$matches")
			url=$(source_release_asset_url "$host" <<<"$asset")
			name=$(jq -r .name <<<"$asset")
			file="${dir}/${name}"
			if [ "$prebuilts_header_printed" != true ]; then pr "Getting prebuilts (${first_patch_src%/*})" >&2; prebuilts_header_printed=true; fi
			if [ "$host" = github ]; then
				gh_dl "$file" "$url" >&2 || return 1
			else
				pr "Getting '$file' from '$url'"
				_req "$url" "$file" -H "Accept: application/octet-stream" >&2 || return 1
			fi
			echo "$tag: $(cut -d/ -f1 <<<"$src")/${name}  " >>"${cl_dir}/changelog.md"
		else
			grab_cl=false
			name=$(basename "$file")
		fi

		echo "$tag_name" > "${dir}/tag_name.txt"
		# Per-bundle tag marker, keyed to the exact downloaded/found file. Unlike the
		# dir-level tag_name.txt it is immune to other versions/apps sharing the same
		# folder and to a process-level cache hit skipping the rewrite, so build.sh
		# can always read the authoritative tag for the file this build actually used.
		echo "$tag_name" > "${file}.tag"

		if [ "$grab_cl" = true ]; then
			local cl_url
			if cl_url=$(source_release_web_url "$host" "$src" "$tag_name"); then
				echo -e "[Changelog](${cl_url})\n" >>"${cl_dir}/changelog.md"
			fi
		fi
		if [ "$REMOVE_RV_INTEGRATIONS_CHECKS" = true ]; then
			local extensions_ext
			extensions_ext=$(unzip -l "${file}" "extensions/shared.*" | grep -o "shared\..*") extensions_ext="${extensions_ext#*.}"
			if ! (
				mkdir -p "${file}-zip" || return 1
				unzip -qo "${file}" -d "${file}-zip" || return 1
				java -cp "${BIN_DIR}/paccer.jar:${BIN_DIR}/dexlib2.jar" com.jhc.Main "${file}-zip/extensions/shared.${extensions_ext}" "${file}-zip/extensions/shared-patched.${extensions_ext}" || return 1
				mv -f "${file}-zip/extensions/shared-patched.${extensions_ext}" "${file}-zip/extensions/shared.${extensions_ext}" || return 1
				rm "${file}" || return 1
				cd "${file}-zip" || abort
				zip -0rq "${CWD}/${file}" . || return 1
			) >&2; then
				echo >&2 "Patching revanced-integrations failed"
			fi
			rm -r "${file}-zip" || :
		fi
		
		echo -n "$file "
	done
	echo
}

set_prebuilts() {
	APKSIGNER="${BIN_DIR}/apksigner.jar"
	local arch
	arch=$(uname -m)
	if [ "$arch" = aarch64 ]; then arch=arm64; elif [ "${arch:0:5}" = "armv7" ]; then arch=arm; fi
	HTMLQ="${BIN_DIR}/htmlq/htmlq-${arch}"
	if [ ! -x "$HTMLQ" ] && command -v htmlq >/dev/null 2>&1; then HTMLQ="htmlq"; fi
	AAPT2="${BIN_DIR}/aapt2/aapt2-${arch}"
	if [ ! -x "$AAPT2" ] && command -v aapt2 >/dev/null 2>&1; then AAPT2="aapt2"; fi
	TOML="${BIN_DIR}/toml/tq-${arch}"
	if [ ! -x "$TOML" ] && command -v tq >/dev/null 2>&1; then TOML="tq"; fi

	local sdk_root="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
	if [ -n "$sdk_root" ] && [ -d "$sdk_root/build-tools" ]; then
		local latest_bt
		latest_bt=$(ls -1d "$sdk_root"/build-tools/* 2>/dev/null | sort -V | tail -1)
		if [ -n "$latest_bt" ] && [ -f "$latest_bt/lib/apksigner.jar" ]; then
			APKSIGNER="$latest_bt/lib/apksigner.jar"
		fi
		if [ ! -x "$AAPT2" ] && [ -n "$latest_bt" ] && [ -x "$latest_bt/aapt2" ]; then
			AAPT2="$latest_bt/aapt2"
		fi
	fi
}

_req() {
	local ip="$1" op="$2"
	shift 2
	local dlp="$op"
	local _req_lock=""
	if [ "$op" != - ]; then
		if [ -f "$op" ]; then return; fi
		# Serialize fetches per destination: parallel siblings used to download
		# the same jar/mpp twice because the exists-check and the write were not
		# atomic. Re-check under the lock; a waiter finds the file already there.
		if command -v flock >/dev/null 2>&1; then
			mkdir -p "${TEMP_DIR}/dllocks"
			exec 204>"${TEMP_DIR}/dllocks/$(tr -cs 'a-zA-Z0-9._-' '_' <<<"$op").lock"
			flock -x 204
			_req_lock=1
			if [ -f "$op" ]; then exec 204>&-; return 0; fi
		fi
		dlp="$(dirname "$op")/tmp.$(basename "$op")"
		if [ -f "$dlp" ]; then
			local wait_c=0
			while [ -f "$dlp" ] && [ $wait_c -lt 300 ]; do 
				sleep 1
				wait_c=$((wait_c+1))
			done
			if [ -f "$op" ]; then return 0; fi
		fi
	fi
	# Ceilings for the transfer itself: --connect-timeout only bounds setup, so a
	# mirror that connects and then trickles could occupy its build slot
	# indefinitely. 30 min is far above any legitimate APK/bundle fetch on a
	# runner link, and the stall guard aborts a transfer sustaining <1 KiB/s for
	# 2 min so the caller can fall through to the next download source instead of
	# burning the whole job timeout.
	# Placed before "$@" so a caller can still override them with its own flags.
	if ! curl -L -c "$TEMP_DIR/cookie.txt" -b "$TEMP_DIR/cookie.txt" \
		--connect-timeout 10 --retry 1 --max-time "${RVB_DL_MAX_TIME:-1800}" \
		--speed-limit 1024 --speed-time 120 \
		--fail -s -S "$@" "$ip" -o "$dlp"; then
		epr "Request failed: $ip"
		if [ "$dlp" != - ]; then rm -f "$dlp"; fi
		if [ -n "$_req_lock" ]; then exec 204>&-; fi
		return 1
	fi
	if [ "$dlp" != - ]; then
		mv -f "$dlp" "$op"
	fi
	if [ -n "$_req_lock" ]; then exec 204>&-; fi
}
req() { _req "$1" "$2" -H "User-Agent: ${DEFAULT_UA}"; }
gh_req() { _req "$1" "$2" -H "$GH_HEADER"; }
# A vendor's own download endpoint is the one place a transfer can die part-way and
# stay dead: curl reports a truncated body as (18) "transfer closed with N bytes
# remaining", which is NOT in curl's transient list, so --retry never covers it, and a
# link that redirects to a freshly minted signed URL (telegram.org/dl/android/apk ->
# cdn4.telesco.pe/file/Telegram.apk?token=...) cannot be resumed with -C - because the
# token belongs to the request that died. Re-requesting the bare URL is what recovers:
# the redirect is followed again and a new token is served. _req deletes its partial
# file and releases the per-destination lock when it fails, so every attempt here is a
# genuine fresh fetch and never a resume of a half file.
# Observed in run 39985777497: one arch of Telegram (web) 13.1.0 received 277 KB of a
# 70 MB APK and was dropped as a source miss, while its sibling's attempt twelve
# seconds later completed the same URL.
req_artifact() { # $1=url  $2=destination
	local url=$1 out=$2 att=1 tries=3
	while [ "$att" -le "$tries" ]; do
		if req "$url" "$out"; then return 0; fi
		if [ "$att" -lt "$tries" ]; then
			wpr "Retrying '$url' (attempt $((att + 1))/$tries)"
			sleep $((att * 5))
		fi
		att=$((att + 1))
	done
	return 1
}
source_release_req() {
	local host=${1,,} url=$2 out=${3:--}
	case "$host" in
		github) gh_req "$url" "$out" ;;
		codeberg)
			if [ -n "${CODEBERG_TOKEN-}" ]; then
				_req "$url" "$out" -H "Accept: application/json" -H "Authorization: token ${CODEBERG_TOKEN}"
			else
				_req "$url" "$out" -H "Accept: application/json"
			fi
			;;
		gitlab)
			_req "$url" "$out" -H "Accept: application/json"
			;;
		*) req "$url" "$out" ;;
	esac
}
gh_dl() {
	if [ ! -f "$1" ]; then
		pr "Getting '$1' from '$2'"
		_req "$2" "$1" -H "$GH_HEADER" -H "Accept: application/octet-stream"
	fi
}

log() { echo -e "$1  " >>"build.md"; }
get_highest_ver() {
	local vers valid_vers=""
	vers=$(tee)
	
	# Try to find the highest valid semver first
	while IFS= read -r v; do
		if [ -n "$v" ] && semver_validate "$v"; then
			valid_vers+="${v}"$'\n'
		fi
	done <<<"$vers"
	
	if [ -n "$valid_vers" ]; then
		sort -s -t- -k1,1Vr <<<"$valid_vers" | head -1
	else
		# Fallback to sorting all versions descending if no semvers validated
		sort -s -t- -k1,1Vr <<<"$vers" | head -1
	fi
}
sort_vers() {
	local vers valid_vers=""
	vers=$(tee)
	
	# Try to find valid semvers first
	while IFS= read -r v; do
		if [ -n "$v" ] && semver_validate "$v"; then
			valid_vers+="${v}"$'\n'
		fi
	done <<<"$vers"
	
	if [ -n "$valid_vers" ]; then
		sort -s -t- -k1,1Vr <<<"$valid_vers" | head -2
	else
		sort -s -t- -k1,1Vr <<<"$vers" | head -2
	fi
}
semver_validate() {
	local a="${1%%[-+_ (]*}"
	a="${a#v}"
	a="${a#V}"
	local ac="${a//[.0-9]/}"
	[ -n "$a" ] && [ ${#ac} = 0 ]
}
get_patch_last_supported_ver() {
	local cache_key="${1}_${2}_${3:-}_${4:-}_${5:-}_${6:-}_${7:-}_${8:-}"
	if [ -n "${__PATCH_VER_CACHE__["$cache_key"]:-}" ]; then
		echo "${__PATCH_VER_CACHE__["$cache_key"]}"
		return 0
	fi
	local result
	if ! result=$(_get_patch_last_supported_ver "$@"); then return 1; fi
	__PATCH_VER_CACHE__["$cache_key"]="$result"
	echo "$result"
}

_get_patch_last_supported_ver() {
	local list_patches=$1 pkg_name=$2 inc_sel=${3:-} _exc_sel=${4:-} _exclusive=${5:-} cli_source=${6:-} cli_jar=${7:-} patches_jar=${8:-}
	local op
	if [ "$inc_sel" ]; then
		# Rank the versions the named patches declare - the table carries one occurrence
		# per declaring patch, so this still prefers the version the most patches agree
		# on - and takes the two highest. It is read from the same listing the
		# compatibility gate consults, so a version can never be advertised here and
		# rejected there.
		local _vs="" _ev=""
		if _ev=$(_effective_patch_versions "$cli_jar" "$patches_jar" "$pkg_name" "$cli_source" named "$inc_sel"); then
			_vs=$(cut -f1 <<<"$_ev" | sed -e '/^$/d' -e '/^Any$/d' | sort | uniq -c | sort -k1,1nr | awk '
					NR==1 { max=$1; print $2; next }
					$1==max { print $2 }
				' | sort_vers) || _vs=""
		fi
		if [ -n "$_vs" ]; then
			echo "$_vs"
			return
		fi
		# Names that match no version block: fall through to the CLI's own counting,
		# which is what happened before this table existed.
	fi
	op=$(patches_list_versions "$cli_jar" "$patches_jar" "$pkg_name" "$cli_source") || return 1
	op=$(sed -n '/Most common compatible versions:/,$p' <<<"$op" | sed '1d' | awk '{$1=$1}1')
	if [ "$op" = "Any" ]; then return; fi
	pcount=$(head -1 <<<"$op") pcount=${pcount#*(} pcount=${pcount% *}
	if [ -z "$pcount" ]; then
		return
	fi
	grep -F "($pcount patch" <<<"$op" | sed 's/ (.* patch.*//' | sed 's/ \[.*//' | sort_vers || return 1
}

get_patch_exp_ver() {
	local cli_jar=$1 patches_jar=$2 pkg_name=$3 cli_source=$4
	local list_stable list_all

	list_stable=$(patches_list_versions "$cli_jar" "$patches_jar" "$pkg_name" "$cli_source" "") || return 1
	list_all=$(patches_list_versions "$cli_jar" "$patches_jar" "$pkg_name" "$cli_source" "-x") || return 1

	list_stable=$(sed -n '/Most common compatible versions:/,$p' <<<"$list_stable" | sed '1d' | awk '{print $1}')
	list_all=$(sed -n '/Most common compatible versions:/,$p' <<<"$list_all" | sed '1d' | awk '{print $1}')

	local exp_versions=""
	for ver in $list_all; do
		if [ -n "$ver" ] && ! echo "$list_stable" | grep -qFx "$ver"; then
			exp_versions+="$ver"$'\n'
		fi
	done

	if [ -n "$exp_versions" ]; then
		sort_vers <<<"$exp_versions"
	fi
}

get_patch_version_code() {
	local raw_op="$1" version="$2" arch="${3:-}"
	local abi
	abi=$(_abi_token_of_arch "$arch")

	local line="" l
	while IFS= read -r l; do
		if [[ "$l" =~ ^[[:space:]]*${version//./\\.}[[:space:]] ]]; then
			line="$l"
			break
		fi
	done <<<"$raw_op"

	if [[ "$line" =~ \[versionCodes:[[:space:]]*([^]]+)\] ]]; then
		local vcodes="${BASH_REMATCH[1]}"
		# Canonicalize the ABI spelling (ARM64_V8A and arm64-v8a both occur in the
		# wild) so this and _effective_arch_verdict read the same token.
		vcodes="${vcodes^^}"
		vcodes="${vcodes//-/_}"
		if [ -n "$abi" ]; then
			if [[ "$vcodes" =~ ${abi}=([0-9]+) ]]; then
				echo "${BASH_REMATCH[1]}"
				return 0
			fi
			return 1
		elif [[ "$vcodes" =~ =([0-9]+) ]]; then
			echo "${BASH_REMATCH[1]}"
			return 0
		fi
	fi
	return 1
}

parse_arch_mapping() {
	local mapping="${1:-}" arch="${2:-}"
	if [[ "$mapping" != *":"* ]]; then
		echo "$mapping"
		return 0
	fi
	local matched="" entry
	# Scope IFS to this function instead of saving and restoring it: the caller may
	# have `unset IFS` (build_rv does, after its bundle-list split), which reads as
	# unbound under set -u, and restoring an empty value would leave that caller with
	# no word splitting at all. A local assignment reverts on return either way.
	local IFS='|'
	for entry in $mapping; do
		if [[ "$entry" =~ ^[[:space:]]*([^:]+)[[:space:]]*:[[:space:]]*(.*)$ ]]; then
			local e_arch="${BASH_REMATCH[1]//[[:space:]]/}"
			local e_val="${BASH_REMATCH[2]}"
			e_val="${e_val//[ \'\";\r\n]/}"
			if [ "${e_arch,,}" = "${arch,,}" ]; then
				matched="$e_val"
				break
			fi
		fi
	done
	echo "$matched"
}

# build_rv cache check for one resolved version across all archs:
#   _cache_all_archs_present <version> [validate]
# Returns 0 when every arch has a cached (and, with "validate", versionCode-
# matching) APK, touching all cached variants for cache-LRU purposes; 1
# otherwise. Reads apk_cache_dir/arch_list/pkg_name + cli vars from scope.
# (The pre-refactor code inlined this loop twice with and without validation;
# a deletion of an invalidating non-"all" APK preserves that behavior.)
_cache_all_archs_present() {
	local ver=$1 validate=${2:-no} raw_ver=${3:-$1}
	local arch arch_f check_apk
	for arch in "${arch_list[@]}"; do
		arch_f="${arch// /}"
		_cache_probe_apk "$ver" "$arch_f" "$raw_ver"
		check_apk="$_CACHE_CHECK_APK"
		if [ -z "$check_apk" ]; then
			return 1
		elif [ "$validate" = validate ] && [ -n "$_CACHE_VC" ]; then
			local cached_vc
			cached_vc=$(_meta_field_of "$check_apk" versionCode) || cached_vc=""
			if [ -n "$cached_vc" ] && [ "$cached_vc" != "$_CACHE_VC" ]; then
				pr "Cached APK for '$pkg_name' has versionCode '$cached_vc', but target requires '$_CACHE_VC'. Cache invalidated."
				[ "$check_apk" != "$_CACHE_ALL_APK" ] && rm -f "$check_apk"
				return 1
			fi
		fi
	done
	for arch in "${arch_list[@]}"; do
		_cache_touch_apks "$ver" "${arch// /}"
	done
	return 0
}

# Resolve the target versionCode for one cached-APK lookup (build_rv cache
# checks). $1=version $2=arch. Reads cli_jar/patches_jar/pkg_name/cli_lv_extra
# and args from the calling build_rv scope (bash dynamic scoping). Echoes the
# versionCode or empty.
_cache_target_vc() {
	local target
	target=$(parse_arch_mapping "${args[version_code]:-}" "$2")
	if [ -z "$target" ] || [ "$target" = "auto" ]; then
		target=""
		if [ -n "$1" ] && [ -n "$cli_jar" ] && [ -n "$patches_jar" ]; then
			local raw_vers
			if raw_vers=$(patches_list_versions "$cli_jar" "$patches_jar" "$pkg_name" "${args[cli_source]:-}" "$cli_lv_extra"); then
				target=$(get_patch_version_code "$raw_vers" "$1" "$2" || true)
			fi
			# list-versions counts only the patches used by default, so a bundle whose
			# app patches ship disabled carries no annotation for it here. The effective
			# table knows the code the named patches tested, and without it the cache key
			# and the post-download check would both go unverified.
			if [ -z "$target" ]; then
				target=$(_patch_arch_verdict "$1" "$2" || true)
			fi
		fi
	fi
	echo "$target"
}

# Discover the cached APK for one pkg/arch at a resolved version (build_rv
# cache checks). $1=stripped version (paths), $2=arch, $3=raw version for
# versionCode metadata lookup (defaults to $1 — the pre-refactor code used
# version_f in filenames but the unstripped resolved_version in
# get_patch_version_code). Populates: _CACHE_VC, _CACHE_CHECK_APK (path or
# empty), _CACHE_ALL_APK (the "all" candidate, which the validation delete check
# spares because it is shared by every arch).
#
# The version code entered these names after the cache existed. Names without it
# are deliberately not probed: nothing writes them any more, so reviving them
# meant trusting a file whose code was never checked when it was stored, and
# _cache_touch_apks kept refreshing its mtime so cache eviction never retired it.
# A miss now costs one re-download per app+version, after which the modern name is
# what exists.
_cache_probe_apk() {
	local ver=$1 arch=$2 raw_ver=${3:-$1}
	local vc check_apk=""
	vc=$(_cache_target_vc "$raw_ver" "$arch")
	local vc_infix="${vc:+-$vc}"
	local stock_apk="${apk_cache_dir}/${pkg_name}-${ver}${vc_infix}-${arch}.apk"
	local all_apk="${apk_cache_dir}/${pkg_name}-${ver}${vc_infix}-all.apk"
	[ -f "$stock_apk" ] && check_apk="$stock_apk"
	[ -z "$check_apk" ] && [ -f "$all_apk" ] && check_apk="$all_apk"
	if [ -z "$check_apk" ] && [ "${_CACHE_BUNDLE_OK:-false}" = true ]; then
		local bx bpath
		for bx in xapk apkm apks; do
			bpath="${apk_cache_dir}/${pkg_name}-${ver}${vc_infix}-${arch}.${bx}"
			[ -f "$bpath" ] || bpath="${apk_cache_dir}/${pkg_name}-${ver}${vc_infix}-all.${bx}"
			if [ -f "$bpath" ]; then check_apk="$bpath"; all_apk="$bpath"; break; fi
		done
	fi
	_CACHE_VC="$vc"
	_CACHE_CHECK_APK="$check_apk"
	_CACHE_ALL_APK="$all_apk"
}


# Refresh mtimes on every cached variant this pkg/arch/version can be served by,
# so a cache hit does not age toward eviction while it is still in use.
_cache_touch_apks() {
	local ver=$1 arch=$2
	local vc; vc=$(_cache_target_vc "$ver" "$arch")
	local vc_infix="${vc:+-$vc}"
	local f
	for f in "${apk_cache_dir}/${pkg_name}-${ver}${vc_infix}-${arch}.apk" \
		"${apk_cache_dir}/${pkg_name}-${ver}${vc_infix}-all.apk" \
		"${apk_cache_dir}/${pkg_name}-${ver}${vc_infix}-${arch}.xapk" \
		"${apk_cache_dir}/${pkg_name}-${ver}${vc_infix}-${arch}.apkm" \
		"${apk_cache_dir}/${pkg_name}-${ver}${vc_infix}-${arch}.apks" \
		"${apk_cache_dir}/${pkg_name}-${ver}${vc_infix}-all.xapk" \
		"${apk_cache_dir}/${pkg_name}-${ver}${vc_infix}-all.apkm" \
		"${apk_cache_dir}/${pkg_name}-${ver}${vc_infix}-all.apks"; do
		[ -f "$f" ] && touch "$f" 2>/dev/null || true
	done
}

patches_list_versions() {
	local cache_key="${1}_${2}_${3}_${4}_${5:-}"
	if [ -n "${__PATCH_VER_CACHE__["$cache_key"]:-}" ]; then
		echo "${__PATCH_VER_CACHE__["$cache_key"]}"
		return 0
	fi
	local result
	if ! result=$(_patches_list_versions "$@"); then return 1; fi
	__PATCH_VER_CACHE__["$cache_key"]="$result"
	echo "$result"
}

_patches_list_versions() {
	local cli_jar=$1 patches_jar=$2 pkg_name=$3 cli_source=$4 extra_args=${5:-} op
	resolve_patcher "$cli_source"
	if [ "$PATCHER_HAS_PATCH_LIST" = false ]; then
		echo ""
		return 0
	fi

	local p_jars=($(echo "$patches_jar" | tr ' ' '\n' | grep -v '^$'))

	local p_args=""
	for j in "${p_jars[@]}"; do
		p_args+="$PATCHER_LIST_BUNDLE_ARG '$j' "
	done
	# shellcheck disable=SC2086  # registry tokens are single fixed args
	if ! op=$(eval java -jar "'$cli_jar'" $PATCHER_LIST_VERSIONS_SUB $PATCHER_LIST_B $p_args-f "'$pkg_name'" "$extra_args" 2>&1); then
		epr "Could not list versions $cli_jar: '$op'"
		return 1
	fi
	echo "$op"
}
# Wrap raw patch names (one per line) into the "'A' 'B'" group shape that TOML
# values use. Deliberately NOT shell-escaped: this is the same representation a
# person writes by hand, so everything downstream - list_args, the compatibility
# gate, the applied-patch post-flight check - sees one shape from both sources.
# Shell quoting happens once, in join_args.
_group_patch_names() {
	local n
	while IFS= read -r n; do
		[ -z "$n" ] && continue
		printf "'%s' " "$n"
	done
}

# Every patch name a bundle offers for one package, one raw name per line (the
# caller quotes them). Used by inclusive-patches. Fails when the tool cannot list
# patches or the listing errors: guessing at "all" is worse than refusing, the same
# rule the exclusive-patches expansion below already follows.
_all_patch_names() { # $1=cli_jar $2=bundle $3=pkg $4=cli_source
	local op
	[ "${PATCHER_HAS_PATCH_LIST:-false}" = true ] || return 1
	if ! op=$(patches_list "$1" "$2" "$3" "$4"); then return 1; fi
	printf '%s\n' "$op" | grep -iE '^[[:space:]]*Name:' \
		| sed -E 's/^[[:space:]]*Name:[[:space:]]*//I' | sed 's/[[:space:]]*$//'
}

# Applied patch names from a morphe -r result file, as a JSON array. Echoes nothing
# when the file is absent or unparsable, which is the caller's cue to fall back to
# scraping. Shape (verified against morphe-desktop 1.15.1):
#   {"packageName":..,"packageVersion":..,"patchingSteps":[{"step","success"}],
#    "appliedPatches":[{"name":..}],"failedPatches":[{"name":..}]}
_applied_from_result() {
	[ -f "$1" ] || return 0
	jq -c '[.appliedPatches[]? | if type=="object" then .name else . end | select(. != null)]' "$1" 2>/dev/null || :
}

# Names morphe reported as failed, comma separated (empty when none/unparsable).
_failed_from_result() {
	[ -f "$1" ] || return 0
	jq -r '[.failedPatches[]? | if type=="object" then (.name // .patch // tostring) else . end] | join(", ")' "$1" 2>/dev/null || :
}

patches_list() {
	local cache_key="${1}_${2}_${3}_${4}"
	if [ -n "${__PATCHES_LIST_CACHE__["$cache_key"]:-}" ]; then
		echo "${__PATCHES_LIST_CACHE__["$cache_key"]}"
		return 0
	fi
	local result
	if ! result=$(_patches_list "$@"); then return 1; fi
	__PATCHES_LIST_CACHE__["$cache_key"]="$result"
	echo "$result"
}

# Instafel CLI resolves its patcher-core jar by filename in the CLI dir, CWD
# (and, during patching, the run temp dir). Shadow copies of the bundle jars
# under every name the CLI may look for. Extra target dirs passed as args.
# The CLI-dir/CWD targets are shared with sibling builds, so copy with
# --remove-destination (unlink+create) instead of truncate-in-place when the
# platform's cp supports it.
_instafel_shadow_core() {
	local cli_jar=$1 patches_jar=$2; shift 2
	local -a extra_dirs=("$@")
	local cli_dir cli_commit d j j_base
	local _cp="cp"
	cp --version 2>/dev/null | grep -q GNU && _cp="cp --remove-destination"
	cli_dir=$(dirname "$cli_jar")
	cli_commit=$(unzip -p "$cli_jar" META-INF/MANIFEST.MF 2>/dev/null | sed -n 's/^Patcher-Cli-Commit: //p' | tr -d '\r')
	[ -z "$cli_commit" ] && cli_commit="$RVB_INSTAFEL_FALLBACK_COMMIT"
	for j in $(echo "$patches_jar" | tr ' ' '\n' | grep -v '^$'); do
		j_base=$(basename "$j")
		$_cp "$j" "$cli_dir/$j_base" 2>/dev/null || :
		$_cp "$j" "$j_base" 2>/dev/null || :
		for d in "${extra_dirs[@]}"; do $_cp "$j" "$d/$j_base" 2>/dev/null || :; done
		$_cp "$j" "$cli_dir/ifl-patcher-core-${cli_commit}.jar" 2>/dev/null || :
		$_cp "$j" "ifl-patcher-core-${cli_commit}.jar" 2>/dev/null || :
		for d in "${extra_dirs[@]}"; do $_cp "$j" "$d/ifl-patcher-core-${cli_commit}.jar" 2>/dev/null || :; done
		if [ "$cli_commit" != "$RVB_INSTAFEL_FALLBACK_COMMIT" ]; then
			$_cp "$j" "$cli_dir/ifl-patcher-core-${RVB_INSTAFEL_FALLBACK_COMMIT}.jar" 2>/dev/null || :
			$_cp "$j" "ifl-patcher-core-${RVB_INSTAFEL_FALLBACK_COMMIT}.jar" 2>/dev/null || :
			for d in "${extra_dirs[@]}"; do $_cp "$j" "$d/ifl-patcher-core-${RVB_INSTAFEL_FALLBACK_COMMIT}.jar" 2>/dev/null || :; done
		fi
	done
}

_patches_list() {
	local cli_jar=$1 patches_jar=$2 pkg_name=$3 cli_source=$4 op
	resolve_patcher "$cli_source"
	if [ "$PATCHER_FLOW" = xposed-module ]; then
		echo "Name: xposed-module-dummy"
		return 0
	fi
	local p_jars=($(echo "$patches_jar" | tr ' ' '\n' | grep -v '^$'))
	if [ "$PATCHER_FLOW" = instafel-workflow ]; then
		_instafel_shadow_core "$cli_jar" "$patches_jar"
		# The patcher creates $XDG_DATA_HOME|~/.local/share/.../core_data/info.json
		# check-then-create style at startup; concurrent builds sharing one HOME
		# crash the loser ("Information file cannot be created"). Give each list
		# call a private, throwaway data dir instead.
		local ifl_xdg
		ifl_xdg=$(mktemp -d "${TMPDIR:-/tmp}/ifl-xdg.XXXXXX" 2>/dev/null) || ifl_xdg=""
		local op_rc=0
		if [ -n "$ifl_xdg" ]; then
			op=$(eval "XDG_DATA_HOME='$ifl_xdg' java -jar '$cli_jar' list" 2>&1) || op_rc=$?
			rm -rf "$ifl_xdg" 2>/dev/null || :
		else
			op=$(eval java -jar "'$cli_jar'" list 2>&1) || op_rc=$?
		fi
		if [ "$op_rc" -ne 0 ]; then
			epr "Could not get patches list $cli_jar: '$op'"
			return 1
		fi
		echo "$op"
		return 0
	fi
	if [ "$PATCHER_KIND" = morphe ]; then
		local p_args_morphe=""
		for j in "${p_jars[@]}"; do
			p_args_morphe+="--patches '$j' "
		done
		if ! op=$(eval java -jar "'$cli_jar'" list-patches $p_args_morphe -f "'$pkg_name'" --with-versions --with-packages -x 2>&1); then
			epr "Could not get patches list $cli_jar: '$op'"
			return 1
		fi
	else
		local p_args_revanced=""
		for j in "${p_jars[@]}"; do
			p_args_revanced+="-p '$j' "
		done
		if ! op=$(eval java -jar "'$cli_jar'" list-patches -b $p_args_revanced --packages --versions --options --filter-package-name="'$pkg_name'" 2>&1); then
			epr "Could not get patches list $cli_jar: '$op'"
			return 1
		fi
	fi
	echo "$op"
}

# The engine's canonical form of a version string. Bundles print names like
# "348.10 - Stable", while build_rv's version_f (and every cache filename) has its
# spaces removed, so the two sides of every comparison have to be folded the same way:
# strip whitespace, then one leading v/V. This is the shape the pre-table gate used
# with ${version// /} and ${v_raw// /}.
_ver_key() { local v=${1// /}; v="${v#v}"; v="${v#V}"; printf '%s' "$v"; }

# Map a build arch onto the ABI token a patch bundle uses in its version-code
# annotation ("[versionCodes: ARM64_V8A=3327]" / "3.15.3: ARM64_V8A=3327"). The one
# mapping for the whole engine: get_patch_version_code, the candidate verdict and the
# cache probes all read it, so a token spelling cannot drift between them.
_abi_token_of_arch() { # $1=build arch
	case "${1,,}" in
		arm64-v8a | arm64) echo "ARM64_V8A" ;;
		arm-v7a | armeabi-v7a | arm) echo "ARMEABI_V7A" ;;
		x86_64) echo "X86_64" ;;
		x86) echo "X86" ;;
		*) echo "" ;;
	esac
}

# The arch pairing this build's strip is built from, spelled for the Morphe CLI's
# --striplibs keep-list, which reads the Android ABI name ("armeabi-v7a") rather than the
# versionCode token above. _strip_apk_abis reads it too, so the input rewrite and the
# patcher's own strip can never state different decisions. A concrete arch keeps its own
# ABI. The catch-all arches mean "arm universal": an all build carries no x86 ABI
# whichever artifact format the vendor shipped, because publishing x86 is a separate
# decision, not a side effect of the download source.
_striplibs_keep_of_arch() { # $1=build arch
	case "${1,,}" in
		arm64-v8a | arm64) echo "arm64-v8a" ;;
		arm-v7a | armeabi-v7a | arm) echo "armeabi-v7a" ;;
		x86_64) echo "x86_64" ;;
		x86) echo "x86" ;;
		*) echo "arm64-v8a,armeabi-v7a" ;;
	esac
}

# The version set of the patches that will ACTUALLY be applied for one package
# (docs/decisions/0009).
#
# Why this exists: included-patches names are handed to the CLI as -e arguments, so
# they apply whether or not the bundle marks them Enabled. Morphe's list-versions
# counts only the patches "used by default" (-u is what widens it), so a bundle whose
# app patches ship disabled answers list-versions with nothing at all - and the
# compatibility gate then rejects every version the resolver just advertised from the
# same bundle (OfflineGames-ggYasin, where every com.JindoBlu.OfflineGames patch in
# ggYasin/ggyasin-morphe-patches v1.6.0 ships Enabled: false). The two questions have
# to be answered from one table, so -u is deliberately NOT used anywhere: widening
# list-versions would also make the resolver advertise versions supported only by
# patches that never get applied.
#
# $1=cli_jar $2=bundles $3=pkg $4=cli_source $5=mode $6=included-patches group (named)
#   mode "named"   -> the patches listed in $6, read out of list-patches
#   mode "default" -> the patches the CLI itself counts, read out of list-versions
# stdout: "<version>\t<ABI=vc[ ABI=vc]>" - one occurrence per declaring patch, so a
#   caller can rank versions by how many patches support them; "Any\t" for a patch
#   that puts no version constraint. The version column is a _ver_key, and commas in
#   the annotation are normalized to spaces (Venus prints "ARM64_V8A=348010, ...") -
#   a caller comparing against anything else compares a different string.
# rc: 0 table | 1 no listing (CLI failed / printed nothing: caller stays permissive)
#     2 the CLI answered but declares no version (caller runs its own logic)
_effective_patch_versions() {
	local cli_jar=$1 patches_jar=$2 pkg_name=$3 cli_source=$4 mode=${5:-named} inc=${6:-}
	[ -n "$cli_jar" ] && [ -n "$patches_jar" ] && [ -n "$pkg_name" ] || return 1
	resolve_patcher "$cli_source"
	[ "${PATCHER_HAS_PATCH_LIST:-false}" = true ] || return 1

	local key="${mode}|${cli_jar}|${patches_jar}|${pkg_name}|${cli_source}|${inc}"
	local cached="${__EFF_PATCH_VER_CACHE__["$key"]:-}"
	if [ -n "$cached" ]; then
		[ "$cached" = "@fail" ] && return 1
		[ "$cached" = "@none" ] && return 2
		printf '%s\n' "$cached"
		return 0
	fi

	local listing out
	if [ "$mode" = named ]; then
		[ -n "$inc" ] || { __EFF_PATCH_VER_CACHE__["$key"]="@fail"; return 1; }
		if ! listing=$(patches_list "$cli_jar" "$patches_jar" "$pkg_name" "$cli_source"); then
			__EFF_PATCH_VER_CACHE__["$key"]="@fail"
			return 1
		fi
		# Names arrive in the TOML group shape ("'A' 'B'"), possibly one group per
		# bundle joined with '|'. Flatten, then strip only the OUTER quote pair: an
		# apostrophe inside a name ("Keep the screen's refresh rate") must survive, and
		# it does here exactly as it does in the version-unpinned matcher below.
		local names
		names=$(list_args "${inc//|/ }" | sed -e "s/^'//" -e "s/'\$//" -e 's/^"//' -e 's/"$//')
		# Names and listing share one stream: the awk pass reads the wanted names until
		# the sentinel, then the listing. Passed this way rather than through -v because
		# -v re-interprets backslash escapes in a multi-line value.
		out=$(printf '%s\n__RVB_EFF_NAMES__\n%s\n' "$names" "$listing" | awk -v sent="__RVB_EFF_NAMES__" '
			function flush(  i, v) {
				if (active) {
					if (anyv) printf "Any\t\n"
					for (i = 1; i <= nv; i++) { v = vers[i]; printf "%s\t%s\n", v, abis[v] }
				}
				nv = 0; delete vers; delete abis; anyv = 0; sect = ""; active = 0
			}
			{ t = $0; sub(/^[ \t]+/, "", t); sub(/[ \t]+$/, "", t) }
			!named { if (t == sent) named = 1; else if (t != "") want[t] = 1; next }
			t ~ /^Name:/ {
				flush(); nm = substr(t, 6); sub(/^[ \t]+/, "", nm); sub(/[ \t]+$/, "", nm)
				active = (nm in want); next
			}
			t ~ /^(INFO: )?Index:/ { flush(); next }
			t ~ /^Compatible versions:/ { if (active) sect = "ver"; next }
			t ~ /^Version codes:/ { if (active) sect = "vc"; next }
			# Any other patch-level field closes the block being collected. Enumerated
			# rather than pattern-matched on "word:" so a wrapped description that
			# happens to contain a colon cannot truncate the version list.
			t ~ /^(Enabled|Description|Options|Requires|Version|Compatible packages|Min version|UUID|Author|Package name):/ { sect = ""; next }
			!active { next }
			sect == "ver" && t == "Any" { anyv = 1; next }
			sect == "ver" && t ~ /^[vV]?[0-9]/ { gsub(/[ \t]/, "", t); sub(/^[vV]/, "", t); nv++; vers[nv] = t; next }
			sect == "vc" && t ~ /^[vV]?[0-9][^:]*: .*=/ {
				p = index(t, ":"); v = substr(t, 1, p - 1); r = substr(t, p + 1)
				gsub(/[ \t]/, "", v); sub(/^[vV]/, "", v)
				gsub(/,/, " ", r); gsub(/[ \t]+/, " ", r); sub(/^ /, "", r); sub(/ $/, "", r)
				found = 0
				for (i = 1; i <= nv; i++) if (vers[i] == v) { found = 1; break }
				if (!found) { nv++; vers[nv] = v }
				abis[v] = (abis[v] == "" ? r : abis[v] " " r)
				next
			}
			END { flush() }')
	else
		if ! listing=$(patches_list_versions "$cli_jar" "$patches_jar" "$pkg_name" "$cli_source" "$PATCHER_LIST_X"); then
			__EFF_PATCH_VER_CACHE__["$key"]="@fail"
			return 1
		fi
		[ -n "$listing" ] || { __EFF_PATCH_VER_CACHE__["$key"]="@fail"; return 1; }
		out=$(awk '
			function trimv(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
			{ t = $0; sub(/^[ \t]+/, "", t); sub(/[ \t]+$/, "", t) }
			t == "" { next }
			t ~ /^INFO:/ { next }
			t ~ /^Most common compatible versions:/ { next }
			t ~ /^Package name:/ { next }
			t == "Any" { printf "Any\t\n"; next }
			t !~ /^[vV]?[0-9]/ { next }
			{
				abis = ""; q = index(t, "[versionCodes:")
				if (q) {
					r = substr(t, q + 14)
					if (sub(/\].*/, "", r)) { gsub(/,/, " ", r); gsub(/[ \t]+/, " ", r); sub(/^ /, "", r); sub(/ $/, "", r); abis = r }
				}
				v = substr(t, 1, q ? q - 1 : length(t))
				sub(/ \(.*$/, "", v); v = trimv(v); gsub(/[ \t]/, "", v); sub(/^[vV]/, "", v)
				if (v == "") next
				printf "%s\t%s\n", v, abis
			}' <<<"$listing")
	fi

	if [ -z "$out" ]; then
		__EFF_PATCH_VER_CACHE__["$key"]="@none"
		return 2
	fi
	__EFF_PATCH_VER_CACHE__["$key"]="$out"
	printf '%s\n' "$out"
}

# What one candidate version means for one build arch, decided over the effective
# table. A version whose annotation lists other ABIs only has no build for this arch,
# so the engine must not fetch it (ADR 0007 makes the arch a hard requirement and the
# post-download gate would reject the bytes anyway - the fetch is pure waste).
# $1=table $2=version $3=arch
# stdout: the versionCode when the table pins exactly one for this arch
# rc: 0 buildable (pinned, or not annotated at all) | 1 annotated without this arch
_effective_arch_verdict() {
	local tab=$1 ver arch=$3 abi
	ver=$(_ver_key "$2")
	abi=$(_abi_token_of_arch "$arch")
	# all / auto / an unmapped arch: nothing to filter or pin on.
	[ -z "$abi" ] && return 0
	awk -F'\t' -v ver="$ver" -v abi="$abi" '
		# Bundles print the token either as ARM64_V8A or arm64-v8a; both spellings
		# mean the same ABI, so the comparison is canonicalized on both sides.
		function canon(s) { gsub(/-/, "_", s); return toupper(s) }
		$1 != ver { next }
		{
			total++
			if ($2 == "") { uncon = 1; next }
			n = split($2, tok, " ")
			for (i = 1; i <= n; i++) {
				if (tok[i] == "") continue
				# Strip any leftover list punctuation and take only a numeric code: a
				# versionCode is a claim the cache filename and the post-download check go
				# on making, so a value that is not a bare number is not a pin at all.
				t = tok[i]; sub(/[,;]+$/, "", t)
				p = index(t, "=")
				if (p < 2) continue
				k = canon(substr(t, 1, p - 1)); val = substr(t, p + 1)
				if (val !~ /^[0-9]+$/) continue
				seen[k] = 1
				if (k in code) { if (code[k] != val) code[k] = "@amb" } else code[k] = val
			}
			constrained++
		}
		END {
			if (total == 0) exit 0
			if (!constrained || uncon) exit 0
			if (!(canon(abi) in seen)) exit 1
			if (code[canon(abi)] != "" && code[canon(abi)] != "@amb") printf "%s", code[canon(abi)]
			exit 0
		}' <<<"$tab"
}

# Does one effective table mention a version at all? $1=table $2=version (stripped)
_table_has_version() { awk -F'\t' -v ver="$2" '$1 == ver { found = 1 } END { exit !found }' <<<"$1"; }

# Verdict for one version+arch across both tables: the named patches decide when they
# know the version, otherwise the default set does. Echoes a versionCode or nothing;
# rc 1 means the version is annotated for other ABIs only (skip the candidate).
_patch_arch_verdict() { # $1=version $2=arch  (reads build_rv scope: cli_jar, patches_jar, pkg_name, args)
	local tab v
	v=$(_ver_key "$1")
	if [ -n "${args[included_patches]:-}" ]; then
		tab=$(_effective_patch_versions "$cli_jar" "$patches_jar" "$pkg_name" "${args[cli_source]:-}" named "${args[included_patches]}") || tab=""
		if [ -n "$tab" ] && _table_has_version "$tab" "$v"; then
			_effective_arch_verdict "$tab" "$v" "$2"
			return $?
		fi
	fi
	tab=$(_effective_patch_versions "$cli_jar" "$patches_jar" "$pkg_name" "${args[cli_source]:-}" default) || tab=""
	[ -n "$tab" ] && _table_has_version "$tab" "$v" || return 0
	_effective_arch_verdict "$tab" "$v" "$2"
}

# What build_rv does with one candidate version for one requested arch.
# $1=version $2=arch $3=the whole candidate list (space separated)
# stdout: the versionCode when the annotation pins one for this arch
# rc: 0 build it | 1 skip it - another supported version is viable for this arch and
#     should take the slot instead
# The annotation records what the patch author tested, not what the store ships, so it
# is only allowed to REDIRECT: when no candidate mentions the arch the download
# proceeds and _artifact_satisfies_arch judges the bytes (docs/decisions/0009).
_candidate_arch_verdict() {
	local vc="" cand v
	v=$(_ver_key "$1")
	if vc=$(_patch_arch_verdict "$1" "$2"); then
		printf '%s' "$vc"
		return 0
	fi
	for cand in $3; do
		cand=$(_ver_key "$cand")
		if [ -z "$cand" ] || [ "$cand" = "$v" ]; then continue; fi
		if _patch_arch_verdict "$cand" "$2" > /dev/null 2>&1; then
			return 1
		fi
	done
	pr "No supported version declares a '$2' build; trying v${v} and letting the artifact bytes decide."
	return 0
}

has_compatible_patches() {
	local cli_jar=$1 patches_jar=$2 pkg_name=$3 version=$4 cli_source=$5
	local inc_patches=${6:-}
	resolve_patcher "$cli_source"
	if [ "$PATCHER_ANY_VERSION" = true ]; then
		return 0
	fi
	[ -z "$cli_jar" ] || [ -z "$patches_jar" ] || [ -z "$pkg_name" ] || [ -z "$version" ] && return 0

	local ver_clean
	ver_clean=$(_ver_key "$version")

	# Pinned scan over the patch set that will actually be applied: the included-patches
	# names when configured (those reach the CLI as -e and apply whatever the bundle
	# marks them), then the default set list-versions counts on its own. Consulting both
	# keeps a bundle whose app patches ship default-disabled buildable, and keeps a config
	# whose names match nothing on exactly the list-versions behaviour it had before.
	local _named="" _default="" _default_rc=0
	if [ -n "$inc_patches" ]; then
		_named=$(_effective_patch_versions "$cli_jar" "$patches_jar" "$pkg_name" "$cli_source" named "$inc_patches") || _named=""
	fi
	_default=$(_effective_patch_versions "$cli_jar" "$patches_jar" "$pkg_name" "$cli_source" default) || _default_rc=$?

	local _tbl tv
	for _tbl in "$_named" "$_default"; do
		[ -n "$_tbl" ] || continue
		while IFS=$'\t' read -r tv _; do
			[ -z "$tv" ] && continue
			[ "$tv" = "Any" ] && return 0
			[ "$tv" = "$ver_clean" ] && return 0
		done <<<"$_tbl"
	done

	# No listing at all (the CLI failed or printed nothing): stay permissive, as before -
	# a tool that cannot answer must not drop a build on its own.
	if [ "$_default_rc" = 1 ]; then
		return 0
	fi

	# Version-unpinned patches (e.g. structural browser hooks) enumerate their
	# package under Compatible packages but print no version constraint, so
	# list-versions yields no candidate line for any version. Morphe's CLI still
	# applies them with "Compatibility: Unknown". When the strict scan above
	# found nothing, accept the target only if an unpinned patch actually gets
	# applied: with included-patches configured, at least one of its names must
	# match a package-enumerated unpinned patch; with none configured, at least
	# one such patch must be default-enabled. Otherwise warn and skip rather
	# than hand Morphe a target where nothing applies. Global/universal patches
	# print no package line, and pinned packages keep their version block, so
	# both stay on the strict skip path. Only reached when no pinned patch
	# matched, so pinned-app behavior is untouched.
	if [ "$PATCHER_KIND" = morphe ] && [ -n "$patches_jar" ]; then
		local op_list
		if op_list=$(patches_list "$cli_jar" "$patches_jar" "$pkg_name" "$cli_source"); then
			# Emit "<patch name>\t<default-enabled>" per unpinned patch that
			# enumerates this package. Dynamic pattern only via $0 ~ pat; state
			# resets on every Package name line; flush at END (no exit-in-rule).
			local unp
			unp=$(awk -v pkg="$pkg_name" 'BEGIN{pat="^[[:space:]]*Package name:[[:space:]]*" pkg "[[:space:]]*$"}
				function flush(){if (seen && !pins && name != "") print name "\t" en}
				{if ($0 ~ /^INFO: Index:/ || $0 ~ /^[[:space:]]*Index:/) {flush(); name=""; en=""; seen=0; pins=0}
					else if ($0 ~ /^[[:space:]]*Name:/) {name=$0; sub(/^[[:space:]]*Name:[[:space:]]*/, "", name); sub(/[[:space:]]+$/, "", name)}
					else if ($0 ~ /^[[:space:]]*Enabled:/) {en=($0 ~ /true/) ? "true" : "false"}
					else if ($0 ~ /^[[:space:]]*Package name:/) {seen=($0 ~ pat); pins=0}
					else if ($0 ~ /^[[:space:]]*Compatible versions:/ && seen) pins=1}
				END{flush()}' <<<"$op_list")
			if [ -n "$unp" ]; then
				local -a inc_names=()
				local n uname uen
				while IFS= read -r n; do
					n="${n#"${n%%[![:space:]]*}"}"
					n="${n%"${n##*[![:space:]]}"}"
					n=${n#\'}; n=${n%\'}; n=${n#\"}; n=${n%\"}
					[ -n "$n" ] && inc_names+=("$n")
				done <<<"$(list_args "${inc_patches//|/ }")"
				if [ ${#inc_names[@]} -gt 0 ]; then
					local match=false
					while IFS=$'\t' read -r uname uen; do
						[ -z "$uname" ] && continue
						for n in "${inc_names[@]}"; do
							if [ "$n" = "$uname" ]; then match=true; break; fi
						done
						[ "$match" = true ] && break
					done <<<"$unp"
					if [ "$match" = true ]; then return 0; fi
					wpr "Only version-unpinned patches found in '$pkg_name' bundle ($(cut -f1 <<<"$unp" | paste -sd ',' -)); none of included-patches matches them, so nothing would be applied."
					return 1
				fi
				if awk -F'\t' '$2 == "true"{found=1} END{exit !found}' <<<"$unp"; then
					return 0
				fi
				wpr "Only version-unpinned patches found in '$pkg_name' bundle ($(cut -f1 <<<"$unp" | paste -sd ',' -)), but none is default-enabled and no included-patches are configured."
				return 1
			fi
		fi
	fi

	return 1
}

isoneof() {
	local i=$1 v
	shift
	for v; do [ "$v" = "$i" ] && return 0; done
	return 1
}

# -------------------- morphe bundle passthrough helpers --------------------
# When _CACHE_BUNDLE_OK=true (morphe + RVB_MORPHE_PASSTHROUGH) the cache may
# hold the vendor bundle (.xapk/.apkm/.apks) instead of a merged apk.

_bundle_ext_of() { # $1=path -> echoes extension without dot if it is a bundle
	local ext="${1##*.}"
	case "${ext,,}" in xapk|apkm|apks) echo "${ext,,}" ;; *) return 1 ;; esac
}

# config.* member keep-list for one target arch (mips/unknown ABIs treated as
# generic: only base kept is never correct, so for those we keep everything).
_bundle_keep_regex_for_arch() {
	case "$1" in
		arm64-v8a) echo 'arm64_v8a' ;;
		arm-v7a) echo 'armeabi' ;;
		x86_64) echo 'x86_64' ;;
		x86) echo 'x86(?!_)' ;;
		*) echo '' ;; # all/universal: keep everything
	esac
}

# Copy $1 bundle -> $2 trimmed to $3 arch by deleting other-ABI config members.
# Density/language configs are always kept (name doesn't identify an ABI).
_trim_bundle_for_arch() {
	local src=$1 dst=$2 arch=$3
	cp -f "$src" "$dst" || return 1
	local keep; keep=$(_bundle_keep_regex_for_arch "$arch")
	[ -z "$keep" ] && return 0
	local -a drop=()
	local name
	while IFS= read -r name; do
		[[ "$name" == *.apk ]] || continue
		name="${name##*/}"
		[[ "$name" == base.apk ]] && continue
		# only native-ABI config splits are trim candidates; language/density/
	# sdk splits (config.hdpi, config.en, config.v21…) must always stay
	[[ "$name" =~ config\.(arm64_v8a|armeabi[_-]v7a|armeabi|x86_64|x86|mips|mips64)([._-]|\.apk$) ]] || continue
		if ! grep -qP "$keep" <<<"$name"; then drop+=("$name"); fi
	done < <(unzip -Z1 "$src" 2>/dev/null)
	if [ ${#drop[@]} -gt 0 ]; then
		zip -q -d "$dst" "${drop[@]}" 2>/dev/null || return 1
	fi
	return 0
}

# Who removes the foreign-ABI native libs of a plain-APK build: the patcher, from the flag
# this engine passes it, or the engine, by rewriting the input.
#
# Rewriting a signed archive is not a free edit. The APK Signing Block sits between the
# local file data and the central directory, so it is not an entry, and a tool that rebuilds
# the archive from the central directory drops it along with the entries it deletes -
# measured on a signed multi-ABI apk with info-zip "zip -d" returning 0: the block's magic
# is gone, so v2/v3 have nothing to verify and v1 is left referencing files that no longer
# exist. The patcher then holds an unsigned apk, and the patches that ask for the *stock*
# certificate - the spoof-signature family, the universal microG metadata patch - abort
# with NoCertificateException after the archive has already been decoded. Nothing notices
# in time: check_sig only answers for a package pinned in sig.txt, and an unpinned one
# answers nothing at all.
#
# So where the patcher can do this job itself from the same keep-list, the input has to
# reach it byte for byte. morphe-desktop is the only tool with --striplibs.
_patcher_strips_libs() {
	[ "${PATCHER_KIND:-}" = morphe ] && [ "$RVB_MORPHE_STRIPLIBS" = true ]
}

# Strip the native-lib ABIs a plain-APK build of this arch must not carry, writing the
# result to $2. The keep-list is the one this build hands to --striplibs, so the engine's
# rewrite and the patcher's strip state the same decision - and a build gets one of the two
# behaviours, never both (_patcher_strips_libs picks).
#
# Deletion happens by exact entry name read off the archive, never by a wildcard: zip
# matches the stored name, so "lib/x86/*" leaves a "./"-rooted "./lib/x86/libso.so"
# untouched and reports only a warning the old `|| :` threw away, while the widening that
# does catch it ("*lib/x86/*") also deletes an app's own "assets/engine/lib/x86/…"
# payload. Both halves were measured, and both are pinned by
# .github/traces/test_arch_strip.sh. The candidate set is Android's own ABI directories -
# an app's lib/<dir> that names no ABI is nobody's claim to delete.
#
# The archive lands through a temp file and one rename, so a run interrupted between the
# copy and the rewrite cannot leave a half-stripped file for the reuse guard to adopt as
# finished.
_strip_apk_abis() { # $1=source apk  $2=destination  $3=build arch
	local src=$1 dst=$2 arch=$3
	local keep tmp="${dst}.strip.tmp"
	keep=$(_striplibs_keep_of_arch "$arch")
	keep=${keep//,/ }
	local -a drop=()
	local name abi
	while IFS= read -r name; do
		[[ "$name" =~ ^(\./)?lib/([^/]+)/ ]] || continue
		abi=${BASH_REMATCH[2]}
		case "$abi" in
			armeabi | armeabi-v7a | arm64-v8a | x86 | x86_64 | mips | mips64) ;;
			*) continue ;;
		esac
		if [[ " $keep " == *" $abi "* ]]; then continue; fi
		# zip folds a leading "./" out of the *pattern* while the stored name keeps it, so
		# an exact "./lib/x86/libso.so" argument matches nothing and only reports rc 12
		# (measured). Spelling that prefix as the wildcard it has to be still anchors on
		# the "./lib/<abi>/<file>" tail: the broad "*lib/<abi>/…" form reaches it too, but
		# takes an app's "assets/engine/lib/x86/…" payload with it, which is why exact
		# names are used everywhere else.
		if [[ "$name" == ./* ]]; then
			drop+=("*$name")
		else
			drop+=("$name")
		fi
	done < <(unzip -Z1 "$src" 2>/dev/null | tr -d '\r')

	if [ ${#drop[@]} -eq 0 ]; then
		cp -f "$src" "$dst"
		return 0
	fi
	rm -f "$tmp"
	cp -f "$src" "$tmp" || return 1
	if ! zip -q -d "$tmp" "${drop[@]}" 2>/dev/null; then
		rm -f "$tmp"
		return 1
	fi
	mv -f "$tmp" "$dst" || {
		rm -f "$tmp"
		return 1
	}
	return 0
}

# Extract base.apk from bundle $1 to path $2 (no merge, no re-sign: base.apk
# carries AndroidManifest, package name and versionCode — enough for the
# aapt/validation reads on bundle cache entries).
_bundle_extract_base() {
	if unzip -p "$1" base.apk > "$2" 2>/dev/null && [ -s "$2" ]; then
		return 0
	fi
	# bundles without a literal base.apk: largest member is conventionally it
	local largest
	largest=$(unzip -l "$1" 2>/dev/null | awk '/\.apk$/{if ($1>max){max=$1; name=$NF}} END{print name}')
	[ -n "$largest" ] || { rm -f "$2"; return 1; }
	unzip -p "$1" "$largest" > "$2" 2>/dev/null && [ -s "$2" ]
}

# Read aapt badging field ($3: versionCode|versionName|package) from file $1,
# transparently handling bundles by their base.apk. Echoes value or nothing.
_meta_field_of() {
	local file=$1 field=$2
	local probe="$file" tmp=""
	if _bundle_ext_of "$file" >/dev/null 2>&1; then
		tmp="${TEMP_DIR}/meta_probe_$$.apk"
		_bundle_extract_base "$file" "$tmp" || { rm -f "$tmp"; return 1; }
		probe="$tmp"
	fi
	local v="" _tool
	# Tool preference: AAPT2 first. Legacy `aapt` (V1) `dump badging` silently
	# prints nothing for manifests compiled against recent SDKs (e.g. apps that
	# target Android 15/16), which used to make download verification reject
	# perfectly valid modern APKs. Only fall back to legacy aapt when AAPT2 is
	# unavailable or yields no value for the field.
	for _tool in "${AAPT2:-}" aapt2 aapt; do
		[ -z "$_tool" ] && continue
		if ! command -v "$_tool" >/dev/null 2>&1 && [ ! -x "$_tool" ]; then
			continue
		fi
		case "$field" in
			package)
				[[ "$_tool" == *"aapt2"* ]] && v=$("$_tool" dump packagename "$probe" 2>/dev/null | tr -d '\r\n')
				[ -z "$v" ] && v=$("$_tool" dump badging "$probe" 2>/dev/null | grep -oP "package: name='\K[^']+" | head -1)
				;;
			versionCode) v=$("$_tool" dump badging "$probe" 2>/dev/null | grep -oP "versionCode='\K[^']+" | head -1) ;;
			versionName) v=$("$_tool" dump badging "$probe" 2>/dev/null | grep -oP "versionName='\K[^']+" | head -1) ;;
		esac
		[ -n "$v" ] && break
	done
	[ -n "$tmp" ] && rm -f "$tmp"
	[ -n "$v" ] && echo "$v"
}

merge_splits() {
	local bundle=$1 output=$2
	# Serialize merges (and the apkeditor/apksigner writes they do) targeting
	# the same output: build.sh may run several tables over one shared stock
	# cache path concurrently when parallel-jobs > 1. Lock name is flattened
	# from the target path — no mkdir needed.
	local _ms_lock="${TEMP_DIR}/mergesplits.$(tr -c 'a-zA-Z0-9._-' '_' <<<"$output").lock"
	if command -v flock >/dev/null 2>&1; then
		exec 201>"$_ms_lock"
		flock -x 201
	fi
	_merge_splits_locked "$bundle" "$output"
	local _ms_ret=$?
	exec 201>&-
	return $_ms_ret
}
_merge_splits_locked() {
	local bundle=$1 output=$2
	if unzip -l "$bundle" 2>/dev/null | grep -q '^[[:space:]]*[0-9].*AndroidManifest\.xml$'; then
		pr "Downloaded bundle is actually a standard APK. Bypassing merge."
		mv -f "$bundle" "$output"
		return 0
	fi
	local apk_count
	apk_count=$(unzip -l "$bundle" 2>/dev/null | grep -c '\.apk$' || true)
	if [ "$apk_count" -le 1 ] && unzip -l "$bundle" 2>/dev/null | grep -q '^[[:space:]]*[0-9].*base\.apk$'; then
		pr "Extracting base.apk from bundle"
		unzip -p "$bundle" base.apk > "${output}-merge-tmp" || { rm -f "${output}-merge-tmp"; return 1; }
		mv -f "${output}-merge-tmp" "$output"
		return 0
	fi
	pr "Merging splits"
	get_apkeditor || return 1
	# write to temp siblings and rename atomically: a concurrent process may
	# have already produced (or be reading) $output — never truncate in place
	if ! OP=$(java -jar "$TEMP_DIR/apkeditor.jar" merge -i "$bundle" -o "${output}-merge-tmp.unsigned" -clean-meta -f 2>&1); then
		epr "APKEditor error: $OP"
		rm -f "${output}-merge-tmp.unsigned"
		return 1
	fi
	# sign the merged stock apk
	if ! OP=$(java -jar "$APKSIGNER" sign --ks "$RVB_KEYSTORE_P12" --ks-pass pass:$RVB_KEYSTORE_PASS --key-pass pass:$RVB_KEYSTORE_PASS --ks-key-alias "$RVB_KEY_ALIAS" \
		--out "${output}-merge-tmp" "${output}-merge-tmp.unsigned"); then
		epr "apksigner error: $OP"
		rm -f "${output}-merge-tmp.unsigned" "${output}-merge-tmp"
		return 1
	fi
	mv -f "${output}-merge-tmp" "$output" || return 1
	rm "${output}.idsig" "${output}-merge-tmp.unsigned" 2>/dev/null || :
	return 0
}

_cf_cffi_download() {
	local url=$1 dest=$2 referer=${3:-}
	local py_cmd=""
	if command -v python3 >/dev/null 2>&1; then
		py_cmd="python3"
	elif command -v python >/dev/null 2>&1; then
		py_cmd="python"
	fi
	[ -z "$py_cmd" ] && return 2
	local py_script="${CWD}/scripts/cf_get.py"
	[ ! -f "$py_script" ] && [ -n "${BASH_SOURCE[0]:-}" ] && py_script="$(dirname "${BASH_SOURCE[0]}")/cf_get.py"
	[ ! -f "$py_script" ] && return 2

	"$py_cmd" "$py_script" download "$url" "$dest" "$referer" "$TEMP_DIR/cookie.txt"
}

_fallback_get(){
	local url=$1
	html=$(curl -L -c "$TEMP_DIR/cookie.txt" -b "$TEMP_DIR/cookie.txt" --connect-timeout 10 --retry 1 -s -f "$url" -H "User-Agent: ${DEFAULT_UA}") || return 1
	if [[ "$html" == *"Attention Required!"* || "$html" == *"Just a moment..."* || "$html" == *"Please Wait... | Cloudflare"* || "$html" == *"Verify you are human"* ]]; then
		return 1
	fi
	__CF_GET_VIA__="curl"
	CF_COOKIES=""
	user_agent="${DEFAULT_UA}"
}

_cf_cffi_get() {
	local url=$1
	local py_cmd=""
	if command -v python3 >/dev/null 2>&1; then
		py_cmd="python3"
	elif command -v python >/dev/null 2>&1; then
		py_cmd="python"
	fi
	[ -z "$py_cmd" ] && return 2
	local py_script="${CWD}/scripts/cf_get.py"
	[ ! -f "$py_script" ] && [ -n "${BASH_SOURCE[0]:-}" ] && py_script="$(dirname "${BASH_SOURCE[0]}")/cf_get.py"
	[ ! -f "$py_script" ] && return 2

	local cffi_res
	# Which path produced $html matters to the scrapers: curl_cffi returns the raw page
	# while the solver returns a JS-rendered DOM that is not the same document. Clear the
	# note first, so a failed call cannot report the previous page's provenance.
	__CF_GET_VIA__=""
	rm -f "$TEMP_DIR/cf_source.txt" 2> /dev/null
	if cffi_res=$("$py_cmd" "$py_script" "$url" "$TEMP_DIR/cookie.txt" 2> /dev/null); then
		html="$cffi_res"
		if [ -f "$TEMP_DIR/cf_source.txt" ]; then
			__CF_GET_VIA__="$(head -1 "$TEMP_DIR/cf_source.txt" 2> /dev/null || true)"
		fi
		if [ -f "$TEMP_DIR/cf_ua.txt" ]; then
			user_agent="$(cat "$TEMP_DIR/cf_ua.txt" 2>/dev/null || echo "${DEFAULT_UA}")"
		else
			user_agent="${DEFAULT_UA}"
		fi
		if [ -f "$TEMP_DIR/cf_cookies.txt" ]; then
			export CF_COOKIES="$(cat "$TEMP_DIR/cf_cookies.txt" 2>/dev/null || echo "")"
		else
			CF_COOKIES=""
		fi
		return 0
	else
		return 1
	fi
}

_unqueued_cf_get() {
	_cf_cffi_get "$@" && return 0
	_fallback_get "$@" && return 0

	if [[ "${__SILENT_CF_GET__:-false}" != true ]]; then
		epr "All methods failed for: $1"
	fi
	return 1
}
_cf_get() {
	mkdir -p "$TEMP_DIR"
	local lock=$TEMP_DIR/cf_get.lock
	exec 200>"$lock"
	if command -v flock >/dev/null 2>&1; then
		flock -x 200
	fi
	trap 'exec 200>&-' RETURN EXIT INT TERM
	_unqueued_cf_get "$@"
}

# -------------------- apkmirror --------------------
get_apkmirror_resp() {
	local url="${1}"
	if [ -n "${__DL_RESP_CACHE__["apkmirror_resp_$url"]:-}" ]; then
		__APKMIRROR_RESP__="${__DL_RESP_CACHE__["apkmirror_resp_$url"]}"
		__APKMIRROR_CAT__="${__DL_RESP_CACHE__["apkmirror_cat_$url"]}"
		return 0
	fi
	local html=""
	_cf_get "${url}" || return 1
	__APKMIRROR_RESP__="$html"
	local clean_url="${url%/}"
	__APKMIRROR_CAT__="${clean_url##*/}"
	__DL_RESP_CACHE__["apkmirror_resp_$url"]="$__APKMIRROR_RESP__"
	__DL_RESP_CACHE__["apkmirror_cat_$url"]="$__APKMIRROR_CAT__"
	set +u
	__APKMIRROR_EXAMPLE_URL__="${args[apkmirror_example_url]:-}" 
	set -u
}

get_apkmirror_vers() {
	local vers apkm_resp html=""
	_cf_get "https://www.apkmirror.com/uploads/?appcategory=${__APKMIRROR_CAT__}" || return 1
	apkm_resp="$html"

	local py_cmd=""
	if command -v python3 >/dev/null 2>&1; then
		py_cmd="python3"
	elif command -v python >/dev/null 2>&1; then
		py_cmd="python"
	fi

	local py_script="${CWD}/scripts/apkmirror_search.py"
	[ ! -f "$py_script" ] && [ -n "${BASH_SOURCE[0]:-}" ] && py_script="$(dirname "${BASH_SOURCE[0]}")/apkmirror_search.py"

	local allow_all="${__AAV__:-false}"
	if [ -n "$py_cmd" ] && [ -f "$py_script" ]; then
		local py_vers
		if py_vers=$("$py_cmd" "$py_script" vers "$allow_all" <<<"$apkm_resp") && [ -n "$py_vers" ]; then
			echo "$py_vers"
			return 0
		fi
	fi

	if [ -n "${HTMLQ:-}" ] && [ -x "$HTMLQ" ]; then
		local main_content
		main_content=$($HTMLQ "#primary" <<<"$apkm_resp" 2>/dev/null || true)
		[ -z "$main_content" ] && main_content=$($HTMLQ "#content" <<<"$apkm_resp" 2>/dev/null || true)
		[ -n "$main_content" ] && apkm_resp="$main_content"
	fi

	vers=$(echo "$apkm_resp" | grep -oP 'class="fontBlack"[^>]*href="[^"]*-release/"[^>]*>\K[^<]+' | awk '{print $NF}' || true)
	if [ "$allow_all" = false ]; then
		local IFS=$'\n'
		vers=$(grep -iv "\(beta\|alpha\|secondary\)" <<<"$vers" || true)
		local v r_vers=()
		for v in $vers; do
			grep -iq "${v} \(beta\|alpha\|secondary\)" <<<"$apkm_resp" || r_vers+=("$v")
		done
		echo "${r_vers[*]}"
	else
		echo "$vers"
	fi
}

# Extract the app package name from an arbitrary APKMirror page's HTML
# (release page or category page). Every APKMirror app page embeds a Play
# Store deep link, so this works on the release page we resolved to as well
# as the config's category page.
_apkmirror_html_pkg_name() {
	local resp="$1"
	local py_cmd=""
	if command -v python3 >/dev/null 2>&1; then
		py_cmd="python3"
	elif command -v python >/dev/null 2>&1; then
		py_cmd="python"
	fi

	local py_script="${CWD}/scripts/apkmirror_search.py"
	[ ! -f "$py_script" ] && [ -n "${BASH_SOURCE[0]:-}" ] && py_script="$(dirname "${BASH_SOURCE[0]}")/apkmirror_search.py"

	if [ -n "$py_cmd" ] && [ -f "$py_script" ]; then
		local py_pkg
		if py_pkg=$("$py_cmd" "$py_script" pkg <<<"$resp") && [ -n "$py_pkg" ]; then
			echo "$py_pkg"
			return 0
		fi
	fi

	local pkg
	pkg=$(echo "$resp" | grep -oP 'play\.google\.com/store/apps/details\?id=\K[a-zA-Z0-9_.]+' | head -1) || true
	if [ -z "$pkg" ]; then
		pkg=$(sed -n 's;.*id=\(.*\)" class="accent_color.*;\1;p' <<<"$resp")
	fi
	echo "$pkg"
}

get_apkmirror_pkg_name() {
	_apkmirror_html_pkg_name "$__APKMIRROR_RESP__"
}

# APKMirror's 'Minimum Version' column as a sortable rank: lower = installs on an older
# device. 'Android 8.0+' -> 800, 'Android 4.0.3+' -> 400, 'Android 12L+' -> 1200 (the L
# suffix has no number of its own, so it ranks with 12). A column that cannot be read
# gets the sentinel, which is the last place a row can come: an unreadable column must
# lose to every row we CAN rank, never borrow a version number it does not have.
# Mirrors minapi_rank() in scripts/apkmirror_search.py.
_amk_minapi_rank() { # $1=Minimum Version column text
	local v=${1,,}
	if [[ "$v" =~ android[[:space:]]*([0-9]+)(\.([0-9]+))? ]]; then
		printf '%d' $((100 * ${BASH_REMATCH[1]} + ${BASH_REMATCH[3]:-0}))
	else
		printf '999999'
	fi
}

# Is the requested arch a catch-all — one artifact meant for every device (arch=all /
# universal)? A catch-all may only take a row that itself carries several ABIs, and the
# ranking then favours the widest. Mirrors is_catch_all() in apkmirror_search.py.
_amk_is_catch_all() { # $1=requested arch token
	case "${1,,}" in all | universal | noarch | auto | "") return 0 ;; *) return 1 ;; esac
}

# How many ABIs a row's Architecture column covers. A universal/noarch build runs
# everywhere, so it outranks any concrete split bundle; otherwise the count of
# '+'-joined ABIs decides. Mirrors arch_width() in apkmirror_search.py.
_amk_arch_width() { # $1=Architecture column
	local a=${1,,} t n=0
	if [ "$a" = "universal" ] || [ "$a" = "noarch" ]; then printf '99'; return 0; fi
	local -a toks=()
	IFS='+' read -ra toks <<<"$a"
	for t in "${toks[@]}"; do t=${t// /}; [ -n "$t" ] && n=$((n + 1)); done
	printf '%d' "$n"
}

# Can one variant row serve the requested arch, and how much of it does it cover?
# Echoes 0 (the row carries more ABIs than asked for: one fetch serves several builds)
# or 1 (exactly the requested ABI); rc 1 with no output means unusable. A multi-ABI
# column is matched by MEMBERSHIP, not by whole-string equality against a fixed list of
# spellings - 'arm64-v8a + armeabi-v7a + x86 + x86_64' carries arm-v7a just as the
# two-ABI form does, and a matcher that only knew the two spellings it had seen used to
# drop such a row entirely. A catch-all request may only take a row that carries
# everything: a multi-ABI bundle is the split form of a universal build, so it qualifies,
# while a single-ABI row would lie about the rest and stays unusable.
# Mirrors arch_class() in scripts/apkmirror_search.py.
_amk_arch_class() { # $1=Architecture column  $2=requested arch token
	local a=${1,,} b=${2,,} t n=0 hit=false
	if [ -z "$a" ]; then return 1; fi
	if [ "$a" = "universal" ] || [ "$a" = "noarch" ]; then printf '0'; return 0; fi
	local -a toks=()
	IFS='+' read -ra toks <<<"$a"
	for t in "${toks[@]}"; do
		t=${t// /}
		if [ -n "$t" ]; then
			n=$((n + 1))
			if [ "$t" = "$b" ]; then hit=true; fi
		fi
	done
	if _amk_is_catch_all "$b"; then
		if [ "$n" -gt 1 ]; then printf '0'; return 0; else return 1; fi
	fi
	if [ "$hit" != true ]; then return 1; fi
	if [ "$n" -gt 1 ]; then printf '0'; else printf '1'; fi
}

apkmirror_search() {
	local resp="$1" dpi="$2" arch="$3" apk_bundle="$4" clean_search_version="$5" search_version="$6" target_vc="${7:-}"
	
	local py_cmd=""
	if command -v python3 >/dev/null 2>&1; then
		py_cmd="python3"
	elif command -v python >/dev/null 2>&1; then
		py_cmd="python"
	fi

	local py_script="${CWD}/scripts/apkmirror_search.py"
	[ ! -f "$py_script" ] && [ -n "${BASH_SOURCE[0]:-}" ] && py_script="$(dirname "${BASH_SOURCE[0]}")/apkmirror_search.py"

	if [ -n "$py_cmd" ] && [ -f "$py_script" ]; then
		local py_res
		if py_res=$("$py_cmd" "$py_script" "$dpi" "$arch" "$apk_bundle" "$clean_search_version" "$search_version" "$target_vc" <<<"$resp") && [ -n "$py_res" ]; then
			echo "$py_res"
			return 0
		fi
	fi

	local dlurl="" node app_table emptyCheck

	local appdpi=("nodpi" "anydpi")
	local match_any_dpi=false
	local dpi_to_use="${dpi:-nodpi anydpi auto}"
	if [ "$dpi_to_use" ]; then
		appdpi+=($dpi_to_use)
		if isoneof "auto" "${appdpi[@]}"; then
			match_any_dpi=true
		fi
	fi

	local best_k="" best_url="" k rank cls dcls

	for ((n = 1; n < 100; n++)); do
		node=$($HTMLQ "div.table-row.headerFont:nth-last-child($n)" <<<"$resp")
		if [ -z "$node" ]; then break; fi
		
		dlurl=$($HTMLQ --base https://www.apkmirror.com --attribute href "div.table-cell:nth-child(1) > a:nth-child(1)" <<<"$node")
		if [ -z "$dlurl" ]; then continue; fi

		local node_apk_bundle node_arch node_min_ver node_dpi node_vc
		node_apk_bundle=$($HTMLQ "div.table-cell:nth-child(1) span.apkm-badge:first-of-type" --text <<<"$node" | xargs)
		[ -z "$node_apk_bundle" ] && node_apk_bundle="APK"

		node_arch=$($HTMLQ "div.table-cell:nth-child(2)" --text <<<"$node" | xargs)
		node_min_ver=$($HTMLQ "div.table-cell:nth-child(3)" --text <<<"$node" | xargs)
		node_dpi=$($HTMLQ "div.table-cell:nth-child(4)" --text <<<"$node" | xargs)
		node_vc=""
		local vc_regex='class="colorLightBlack"[^>]*>([0-9]+)</span>'
		if [[ "$node" =~ $vc_regex ]]; then
			node_vc="${BASH_REMATCH[1]}"
		else
			local raw_vc
			raw_vc=$($HTMLQ "div.table-cell:nth-child(1) span.colorLightBlack" --text <<<"$node" 2>/dev/null || true)
			local num_regex='([0-9]+)'
			if [[ "$raw_vc" =~ $num_regex ]]; then
				node_vc="${BASH_REMATCH[1]}"
			fi
		fi

		if [ "$node_apk_bundle" != "$apk_bundle" ]; then continue; fi

		if [ -n "$clean_search_version" ]; then
			if [[ "$dlurl" != *"$clean_search_version"* ]] && [[ "$dlurl" != *"$search_version"* ]]; then
				continue
			fi
		fi

		# A pinned versionCode narrows the rows; it does not END the search. Several
		# variants share one versionCode and differ only in arch, DPI and minimum
		# Android, so returning the first numeric match handed the arm-v7a build the
		# arm64-only file - which the arch-honesty gate then rejected, dropping the whole
		# source and the build with it (docs/decisions/0007).
		if [ -n "$target_vc" ]; then
			if [ -z "$node_vc" ] || [ "$node_vc" != "$target_vc" ]; then
				continue
			fi
		fi

		# Ranking tuple, packed into one integer so the comparison is locale-free and
		# needs no external sort. For a normal arch the fields are (minimum Android, arch
		# coverage, DPI match, table position), lowest wins. For a catch-all request
		# coverage is the whole point, so (widest ABI bundle, minimum Android, DPI,
		# position) — the row count is inverted so a fatter bundle sorts smaller. The
		# packing keeps every field strictly below the next (n<100, dcls*100<200,
		# rank*1000 below 1e9), so the lowest integer still means the intended winner, and
		# the trailing row index makes keys unique so a tie keeps the row seen first.
		# Mirrors the tuple in apkmirror_search() of scripts/apkmirror_search.py.
		if ! cls=$(_amk_arch_class "$node_arch" "$arch"); then continue; fi
		if isoneof "$node_dpi" "${appdpi[@]}"; then
			dcls=0
		elif [ "$match_any_dpi" = true ]; then
			dcls=1
		else
			continue
		fi
		rank=$(_amk_minapi_rank "$node_min_ver")
		if _amk_is_catch_all "$arch"; then
			_amk_w=$(_amk_arch_width "$node_arch")
			k=$(((99 - _amk_w) * 1000000000 + rank * 1000 + dcls * 100 + n))
		else
			k=$((rank * 10000 + cls * 1000 + dcls * 100 + n))
		fi
		if [ -z "$best_k" ] || [ "$k" -lt "$best_k" ]; then
			best_k=$k
			best_url="$dlurl"
		fi
	done

	if [ -z "$best_url" ]; then return 1; fi
	echo "$best_url"
}

# The config's ordered format chain (preferred-format), already validated and deduped
# at compile in build.sh. Read through the calling build_rv's args (bash dynamic
# scoping, as _cache_target_vc does with args[version_code]). Echoes nothing when the
# key is unset — unset is NOT a value, it means each source keeps its own order.
_pref_chain() {
	# The +x test keeps this safe under set -u when no `args` array is in scope yet
	# (offline callers source utils.sh at top level).
	if [ -n "${args[*]+x}" ]; then printf '%s' "${args[preferred_format]:-}"; fi
}

# Class collapse for sources whose rows cannot tell the bundle sub-formats apart
# (APKMirror's badge is BUNDLE|APK, Uptodown flags only is_bundle): the token 'apk'
# selects class APK, any of apkm/xapk/apks selects class BUNDLE. $1=chain, the rest
# the source's default class order. Chain entries first (first occurrence of a class
# wins), unnamed classes appended in default order — a prefix, never a filter.
# Empty chain returns the default verbatim.
_pref_class_order() { # $1=chain $2...=default class order
	local chain=$1 tok cls out="" seen=""
	shift
	if [ -z "$chain" ]; then printf '%s\n' "$@"; return; fi
	for cls in "$@"; do
		for tok in $chain; do
			case "$tok" in
				apk) tok=APK ;;
				*) tok=BUNDLE ;;
			esac
			[ "$tok" = "$cls" ] || continue
			case " $seen " in *" $cls "*) continue ;; esac
			seen+=" $cls"; out+="$cls"$'\n'
		done
	done
	for cls in "$@"; do
		case " $seen " in *" $cls "*) continue ;; esac
		out+="$cls"$'\n'
	done
	printf '%s' "$out"
}

# 1:1 format tokens over a source's own default order (APKCombo's page suffixes,
# Archive's filename extensions): chain first, unnamed entries in the order given.
_pref_ext_order() { # $1=chain $2...=default ext order
	local chain=$1 tok out="" seen=""
	shift
	# Nothing named: emit nothing. The caller's own built-in list IS the default; a
	# blank line here would become a phantom first candidate for every consumer.
	[ -n "$chain" ] || return 0
	for tok in $chain; do
		case " $seen " in *" $tok "*) continue ;; esac
		isoneof "$tok" "$@" || continue
		seen+=" $tok"; out+="$tok"$'\n'
	done
	for tok in "$@"; do
		case " $seen " in *" $tok "*) continue ;; esac
		out+="$tok"$'\n'
	done
	printf '%s' "$out"
}

# normalize + validate + dedupe the preferred-format chain. Lives here rather than
# inline in build.sh so the trace harness can exercise it without a signing identity
# and a full config compile. Results in __PREF_CHAIN (never through command
# substitution: an unknown token has to abort the compile, and an abort in a $()
# subshell only ends the subshell). Lowercases the value — a format name is a
# spelling, not a claim; an unknown token aborts — a typo has two readings and
# guessing one is rule 3; a repeated token says nothing new, so it is dropped with a
# warning rather than burning the runner's whole compile on it.
_pref_format_validate() { # $1=raw value  $2=owner name for messages
	local v=$1 owner=$2 tok seen="" keep=""
	v=${v,,}
	for tok in $v; do
		if ! isoneof "$tok" apk apkm xapk apks; then
			abort "ERROR: preferred-format '$v' for '$owner' contains unknown token '$tok': only 'apk', 'apkm', 'xapk', 'apks' are allowed"
		fi
		case " $seen " in
			*" $tok "*) wpr "preferred-format: duplicate token '$tok' for '$owner' ignored" ;;
			*) seen+=" $tok"; keep+="$tok " ;;
		esac
	done
	__PREF_CHAIN=${keep% }
}

# Badge kinds in the order APKMirror's variant rows are considered, one per line:
# split uploads (.apkm/.xapk) BEFORE single-file APKs. A bundle carries the ABIs and the
# densities one build asked for in a single fetch, and it is the shape the morphe
# passthrough can ship without a merge; the arch, versionCode and DPI predicates inside
# apkmirror_search still have to agree, and when no bundle row satisfies them the loop
# falls through to plain APKs. Spelled out on its own because it is a stated preference,
# not an implementation detail, and the trace test asserts it. The preferred-format
# chain reorders the two classes; unset keeps this order untouched.
_apkmirror_type_order() {
	local chain
	chain=$(_pref_chain)
	if [ -n "$chain" ]; then
		_pref_class_order "$chain" BUNDLE APK
	else
		printf 'BUNDLE\nAPK\n'
	fi
}

# How many candidate release pages one lookup may fetch to settle an identity. The
# candidates come out of a search listing, where a version number is not an identity, so
# the field can be several apps wide; fetching all of it would be a queue of requests to a
# host that throttles datacenter IPs, and the page we want is the first that states the
# package we are building.
_APKMIRROR_CANDIDATE_LIMIT=5

# A listing URL as APKMirror writes it inside its own links: site-relative. A config carries
# the same listing as an absolute URL, so the host has to come off before a link can be
# compared with it — comparing an absolute path against relative hrefs matches nothing and
# silently turns the ordering into a no-op.
_apkmirror_listing_relpath() { # $1=listing url or path
	local p=$1
	if [[ "$p" == *"://"* ]]; then
		p="${p#*://}"
		p="/${p#*/}"
	fi
	if [[ "$p" != /* ]]; then p="/$p"; fi
	printf '%s' "$p"
}

# Listing links first, everything else after them, order inside each group untouched. A
# release page's own listing path is the only part of an href that says whose bytes it
# serves, so it orders the candidate field even where it cannot prove it.
# $1=hrefs(newline)  $2=listing path, absolute or relative, no trailing slash ("" = keep order)
_apkmirror_prefer_listing() {
	local links=$1 path=$2 rel=""
	[ -n "$links" ] || return 1
	if [ -n "$path" ]; then
		rel=$(_apkmirror_listing_relpath "$path")
		printf '%s\n%s\n' \
			"$(echo "$links" | grep -F "$rel/" || true)" \
			"$(echo "$links" | grep -vF "$rel/" || true)" | awk 'NF && !seen[$0]++'
	else
		printf '%s\n' "$links" | awk 'NF && !seen[$0]++'
	fi
}

# Which of a page's release links name the requested version, strongest spelling first:
# the exact slug, then a slug carrying a suffix, then a grouped/short form. Each tier is
# kept as an ordered candidate list rather than one winner, because the winner used to be
# 'head -1' of a substring match over a whole site's links.
# $1=hrefs(newline)  $2=listing path  $3=search_version  $4=clean_search_version
# $5=short_search_version
_apkmirror_version_hrefs() {
	local links=$1 path=$2 sv=$3 csv=$4 ssv=$5 ordered="" out="" hit="" tier=""
	[ -n "$links" ] || return 1
	ordered=$(_apkmirror_prefer_listing "$links" "$path")
	[ -n "$ordered" ] || return 1
	local -a tiers=()
	if [ -n "$sv" ]; then tiers+=("F|${sv}-release"); fi
	if [ -n "$csv" ]; then tiers+=("E|${csv}(-[a-z0-9]+)*-release"); fi
	if [ -n "$ssv" ] && [ "$ssv" != "$csv" ]; then tiers+=("E|${ssv}(-[0-9])?-release/?$"); fi
	for tier in "${tiers[@]:0}"; do
		if [ "${tier%%|*}" = F ]; then
			hit=$(echo "$ordered" | grep -F "${tier#*|}" || true)
		else
			hit=$(echo "$ordered" | grep -E "${tier#*|}" || true)
		fi
		if [ -n "$hit" ]; then out+="${hit}"$'\n'; fi
	done
	[ -n "$out" ] || return 1
	printf '%s\n' "$out" | awk 'NF && !seen[$0]++'
}

# The tier that reads the version out of a link's ANCHOR TEXT instead of its slug, for
# listings whose slug drops or groups digits. Restricted to release pages: the link a text
# hit yields used to be whatever href shared the row, including an image or a forum link.
# $1=html split on </a>  $2=listing path  $3,$4=version spellings to look for in the text
_apkmirror_text_hrefs() {
	local split=$1 path=$2 v="" links=""
	for v in "${3:-}" "${4:-}"; do
		[ -n "$v" ] || continue
		links=$(echo "$split" | grep -F "$v" | grep -oP 'href="\K[^"]+' |
			grep -F -- '-release/' | sed 's/#.*$//' | awk 'NF && !seen[$0]++') || true
		[ -n "$links" ] || continue
		_apkmirror_prefer_listing "$links" "$path"
		return 0
	done
	return 1
}

# Fetch candidate release pages until one of them belongs to the app being built. A page
# for a different package is skipped, not fatal: the first search hit used to be downloaded
# on trust and the package guard at the end of dl_apkmirror then abandoned the whole
# source, so one collision cost the app its only remaining store. A candidate that will not
# answer at all is skipped for the same reason — a stale link inside a search field is
# nothing new, and it must not end a walk that has other pages to read. An unreadable
# package is accepted (a page that states no Play link is what the old code took), but never
# ahead of a page that does state the right one.
# Writes the caller's release_url/resp (dynamic scope, never through $(), so an abort is
# the build's and not a subshell's), and records every page it refused or could not read in
# the caller's _seen_pages map: the listing is walked ten pages deep and a related-apps link
# repeats on every one of them, so an unrecorded candidate is fetched once per page for the
# same answer. rc: 0 accepted | 1 nothing in this field was usable.
# $1=candidate hrefs(newline)  $2=base_url
_apkmirror_take_pages() {
	local hrefs=$1 base=$2 n=0 href page page_pkg
	[ -n "$hrefs" ] || return 1
	while IFS= read -r href; do
		[ -n "$href" ] || continue
		page="$href"
		if [[ "$page" != http* ]]; then
			if [[ "$page" != /* ]]; then page="/$page"; fi
			page="${base}${page}"
		fi
		if [ -n "${_seen_pages[$page]:-}" ]; then continue; fi
		n=$((n + 1))
		if [ "$n" -gt "$_APKMIRROR_CANDIDATE_LIMIT" ]; then break; fi
		if ! _cf_get "$page"; then
			_seen_pages["$page"]=1
			wpr "APKMirror result '$page' did not answer for version $version; trying the next result"
			continue
		fi
		if [ -n "${pkg_name:-}" ]; then
			page_pkg=$(_apkmirror_html_pkg_name "$html")
			if [ -n "$page_pkg" ] && [ "$page_pkg" != "$pkg_name" ]; then
				_seen_pages["$page"]=1
				wpr "APKMirror listed '$page_pkg' for version $version instead of '$pkg_name'; trying the next result"
				continue
			fi
		fi
		release_url="$page"
		resp="$html"
		return 0
	done <<<"$hrefs"
	return 1
}

dl_apkmirror() {
	local url=$1 version=${2// /-} output=$3 arch=$4 dpi=$5 is_bundle=false get_latest_ver=${6:-false} version_code=${7:-}
	local base_url="https://www.apkmirror.com"
	local html=""

	if [ -f "${output%.apk}.apkm" ]; then
		# Cached sidecar from an earlier run. _bundle_to_apk yields whatever the caller
		# has to verify - base.apk under passthrough, a merged apk otherwise - and leaves
		# the bundle itself in place for build_rv's adoption logic.
		_bundle_to_apk "${output%.apk}.apkm" "${output}"
		return 0
	fi

	if [ "$arch" = "arm-v7a" ]; then arch="armeabi-v7a"; fi

	local clean_version="${version//[^0-9.]/}"
	local clean_search_version="${clean_version//./-}"

	local short_version="" short_search_version=""
	if [[ "$clean_version" == *.*.*.* ]]; then
		short_version=$(echo "$clean_version" | cut -d. -f1-3)
	elif [[ "$clean_version" == *.*.* ]]; then
		short_version=$(echo "$clean_version" | cut -d. -f1-2)
	fi
	if [ -n "$short_version" ]; then
		short_search_version="${short_version//./-}"
	fi

	local resp release_url=""

	if [ -n "${__APKMIRROR_EXAMPLE_URL__:-}" ]; then
		local example_path="${__APKMIRROR_EXAMPLE_URL__#$base_url}"
		local slug_ver target_ver
		slug_ver=$(echo "$example_path" | grep -oP '\d+(-\d+)+' | tail -1)
		target_ver=$(echo "$version" | tr '.' '-' | grep -oP '\d+(-\d+)+')
		if [ -n "$slug_ver" ] && [ -n "$target_ver" ]; then
			release_url="${base_url}${example_path/$slug_ver/$target_ver}"
				__SILENT_CF_GET__=true _cf_get "$release_url" || true
			resp="$html"
			if [[ "$resp" == *"Page Not Found"* ]] || [[ "$resp" == *"404 Whoops"* ]] || [ -z "$resp" ]; then
					release_url=""
			fi
		fi
	fi

	# APKMirror's release slug keeps an underscore that appears in the version
	# (e.g. "4.50.1_tv" -> "4-50-1_tv"), so do NOT fold it into a dash here; the
	# all-dash form is still tried as a secondary candidate in the guess loop below.
	local search_version="${version//./-}"
	search_version="${search_version,,}"
	search_version="${search_version//[^a-z0-9_-]/}"
	search_version="${search_version//---/-}"
	local search_version_dash="${search_version//_/-}"

	if [ -z "$release_url" ]; then
		local apkmname cat_slug cand vform vforms guess_url guess_resp guess_pkg page_ok
		apkmname=$($HTMLQ "h1.marginZero" --text <<<"$__APKMIRROR_RESP__")
		apkmname="${apkmname,,}" apkmname="${apkmname// /-}" apkmname="${apkmname//[^a-z0-9-]/}"
		# APKMirror release slugs usually follow the <h1> app title, but some apps
		# publish under the short category slug instead (e.g. CapCut, whose title is
		# "CapCut - Video Editor" but whose releases live at capcut-<ver>-release),
		# and the version part may carry an underscore (ViX "4.50.1_tv"). Try every
		# (name, version) combination, and only accept a guess whose page really
		# belongs to the target package, so a wrong guess falls through to the
		# category-list scrape below rather than tripping the package guard and
		# aborting the whole source.
		cat_slug="${url%/}"; cat_slug="${cat_slug##*/}"
		vforms="$search_version"
		[ "$search_version_dash" != "$search_version" ] && vforms="${vforms} ${search_version_dash}"
		for cand in "$apkmname" "$cat_slug"; do
			[ -z "$cand" ] && continue
			for vform in $vforms; do
				guess_url="${url%/}/${cand}-${vform}-release/"
				__SILENT_CF_GET__=true _cf_get "$guess_url" || true
				guess_resp="$html"
				[ -z "$guess_resp" ] && continue
				if [[ "$guess_resp" == *"Page Not Found"* ]] || [[ "$guess_resp" == *"404 Whoops"* ]]; then
					continue
				fi
				page_ok=true
				if [ -n "${pkg_name:-}" ]; then
					guess_pkg=$(_apkmirror_html_pkg_name "$guess_resp")
					if [ -n "$guess_pkg" ] && [ "$guess_pkg" != "$pkg_name" ]; then
						page_ok=false
					fi
				fi
				if [ "$page_ok" = true ]; then
					release_url="$guess_url"
					resp="$guess_resp"
					break 2
				fi
			done
		done
		[ -z "$release_url" ] && resp=""
	fi

	if [ -z "$release_url" ]; then
		local list_url="${url%/}"
		local cands=""
		local -A _seen_pages=()   # release pages already proved to be another app

		# 1. Targeted search query (?s=version) first as inspired by uni-apks. APKMirror
		# ignores the app path as soon as a search query is present and answers site-wide,
		# so what comes back is a field of candidates, not an answer.
		local search_target_url="${list_url}/?s=${clean_version}"
		if _cf_get "$search_target_url" 2>/dev/null && [ -n "$html" ]; then
			local s_flat=$(echo "$html" | tr -d '\n\r')
			local s_split="${s_flat//<\/a>/<\/a>
}"
			local s_links=$(echo "$s_split" | grep -oP 'href="\K/apk/[^"]+' | sed 's/#.*$//' | awk 'NF && !seen[$0]++')
			cands=$(_apkmirror_version_hrefs "$s_links" "$list_url" "$search_version" "$clean_search_version" "$short_search_version") || true
			if [ -z "$cands" ]; then
				cands=$(_apkmirror_text_hrefs "$s_split" "$list_url" "$version" "$clean_version") || true
			fi
			if [ -n "$cands" ]; then
				# A field with no usable answer is not a failure of the source: the walk
				# continues to the listing and then to the site search, and only an empty
				# walk reports the version as missing.
				_apkmirror_take_pages "$cands" "$base_url" || true
			fi
		fi

		# 2. The listing itself, page by page. Links outside this app's own listing path
		# ('Apps related to …') are ordered last rather than dropped: a renamed app can
		# publish under a path the config does not carry, and its page still states the
		# package, which is what decides.
		if [ -z "$release_url" ]; then
			for page_num in $(seq 1 10); do
				local page_url="$list_url/"
				if [ "$page_num" -gt 1 ]; then page_url="$list_url/page/$page_num/"; fi
				_cf_get "$page_url" || return 1

				local html_flat=$(echo "$html" | tr -d '\n\r')
				local html_split="${html_flat//<\/a>/<\/a>
}"
				local all_links=$(echo "$html_split" | grep -oP 'href="\K[^"]+' | grep -F -- '-release/' | sed 's/#.*$//' | awk 'NF && !seen[$0]++')
				cands=$(_apkmirror_version_hrefs "$all_links" "$list_url" "$search_version" "$clean_search_version" "$short_search_version") || true
				if [ -z "$cands" ]; then
					cands=$(_apkmirror_text_hrefs "$html_split" "$list_url" "$version" "$clean_version") || true
				fi
				if [ -n "$cands" ]; then
					_apkmirror_take_pages "$cands" "$base_url" || true
					if [ -n "$release_url" ]; then break; fi
				fi
			done
		fi

		# 3. Site-wide search. The query has to name the APP: APKMirror matches display
		# names and answers "No results found matching your query" for a listing slug —
		# measured on the Truecaller case, 'truecaller-caller-id-block 26.10.6' returns
		# nothing while the h1 title's slug 'truecaller-spam-call-blocker 26.10.6' returns
		# the release. With no title to read, the old slug query is kept rather than
		# invented from the app name.
		if [ -z "$release_url" ]; then
			local search_name="${apkmname:-${__APKMIRROR_CAT__}}"
			local search_list_url="https://www.apkmirror.com/?post_type=app_release&searchtype=apk&s=${search_name}+${version}"
			__SILENT_CF_GET__=true _cf_get "$search_list_url" || true
			if [ -n "$html" ] && [ "$html" != "null" ]; then
				local search_links=""
				if [[ "$html" != *"No results found matching your query"* ]]; then
					search_links=$($HTMLQ --attribute href "div.appRow h5 a" <<<"$html") || true
					search_links=$(printf '%s\n' "$search_links" | grep -F -- '-release/' | sed 's/#.*$//' | awk 'NF && !seen[$0]++') || true
				fi
				cands=$(_apkmirror_version_hrefs "$search_links" "$list_url" "$search_version" "$clean_search_version" "$short_search_version") || true
				if [ -n "$cands" ]; then
					_apkmirror_take_pages "$cands" "$base_url" || true
				fi
			fi
		fi

		if [ -z "$release_url" ]; then
			epr "Could not find version $version on APKMirror"
			return 1
		fi
	fi

	# Last line of defence for a page this function did not choose itself — the config's
	# apkmirror-example-url path. A search candidate is now package-checked by
	# _apkmirror_take_pages before it is accepted, so a fuzzy collision costs one skipped
	# link instead of the whole source; an empty extraction still keeps prior behaviour.
	if [ -n "${pkg_name:-}" ] && [ -n "$resp" ]; then
		local page_pkg
		page_pkg=$(_apkmirror_html_pkg_name "$resp")
		if [ -n "$page_pkg" ] && [ "$page_pkg" != "$pkg_name" ]; then
			epr "Resolved APKMirror page is for '$page_pkg', not expected '$pkg_name'. Skipping apkmirror for version $version."
			return 1
		fi
	fi

	local node dlurl=""
	node=$($HTMLQ "div.table-row.headerFont:nth-last-child(1)" -r "span:nth-child(n+3)" <<<"$resp")
	if [ "$node" ]; then
		for type in $(_apkmirror_type_order); do
			if dlurl=$(apkmirror_search "$resp" "$dpi" "$arch" "$type" "$clean_search_version" "$search_version" "$version_code"); then
				[ "$type" = "BUNDLE" ] && is_bundle=true || is_bundle=false
				break
			fi
		done
		# A pinned version code is a preference, not a veto. When the bundle's per-ABI
		# code is wrong (an author stamping the arm64 code on every ABI - MacroDroid
		# 5.66.9 lists ARMEABI_V7A=896600011, but the real arm-v7a build is 796600011),
		# the code+arch predicate is unsatisfiable even though a matching-arch build of
		# the SAME version exists. Retry by arch+version only, dropping just the numeric
		# code: arch stays a hard requirement (ADR 0007), the caller re-keys the artifact
		# to its real code, and patch application remains the compatibility gate
		# (docs/decisions/0011-version-code-fallback-to-arch.md).
		if [ -z "$dlurl" ] && [ -n "$version_code" ]; then
			for type in $(_apkmirror_type_order); do
				if dlurl=$(apkmirror_search "$resp" "$dpi" "$arch" "$type" "$clean_search_version" "$search_version" ""); then
					[ "$type" = "BUNDLE" ] && is_bundle=true || is_bundle=false
					DL_VC_ARCH_FALLBACK=1
					wpr "No '$arch' variant carries pinned version code '$version_code' for $version; selecting the '$arch' build by architecture alone"
					break
				fi
			done
		fi
		if [ -z "$dlurl" ]; then
			if [ -n "$version_code" ]; then
				wpr "Could not find variant with version code '$version_code' for version '$version' on APKMirror"
			else
				wpr "APKMirror lists no build covering arch '$arch' for version '$version'"
			fi
			return 1
		fi
		
		_cf_get "$dlurl" || return 1
		resp="$html"
		
	fi

	local all_dl_btns btn_url
	all_dl_btns=$(echo "$resp" | $HTMLQ "a.downloadButton" --attribute href)
	if [ "$is_bundle" = true ]; then
		btn_url=$(echo "$all_dl_btns" | grep -v 'forcebaseapk' | head -1)
		[ -z "$btn_url" ] && btn_url=$(echo "$all_dl_btns" | head -1)
	else
		btn_url=$(echo "$all_dl_btns" | grep 'forcebaseapk' | head -1)
		[ -z "$btn_url" ] && btn_url=$(echo "$all_dl_btns" | head -1)
	fi
	if [ -z "$btn_url" ]; then epr "Could not find download button on APKMirror"; return 1; fi
	btn_url=$(echo "$btn_url" | sed 's/&amp;/\&/g')

	_cf_get "$base_url$btn_url" || return 1
	local final_url
	final_url=$($HTMLQ "a#download-link" --attribute href <<<"$html" 2>/dev/null | head -1) || true
	[ -z "$final_url" ] && final_url=$(echo "$html" | grep -oP 'id="download-link"[^>]*href="\K[^"]+' | head -1) || true
	if [ -z "$final_url" ]; then epr "Could not find final download link on APKMirror"; return 1; fi
	final_url=$(echo "$final_url" | sed 's/&amp;/\&/g')
	[[ "$final_url" != http* ]] && final_url="${base_url}${final_url}"

	pr "Downloading APK: $final_url"
	local cookie_args=()
	[ -n "${CF_COOKIES:-}" ] && cookie_args=(--header "Cookie: $CF_COOKIES")
	local referer_url="$base_url$btn_url"
	[[ "$btn_url" == http* ]] && referer_url="$btn_url"

	local target_dl_dest="${output}"
	[ "$is_bundle" = true ] && target_dl_dest="${output%.apk}.apkm"

	if ! _cf_cffi_download "$final_url" "$target_dl_dest" "$referer_url"; then
		wget -nv -O "$target_dl_dest" \
			--header="User-Agent: ${user_agent:-$DEFAULT_UA}" \
			--referer="$referer_url" \
			"${cookie_args[@]}" \
			--timeout=300 \
			"$final_url" || return 1
	fi

	if [ "$is_bundle" = true ]; then
		if ! unzip -l "${output%.apk}.apkm" >/dev/null 2>&1; then
			epr "Downloaded file is not a valid zip (apkm): $final_url"
			rm -f "${output%.apk}.apkm"
			return 1
		fi
		_bundle_to_apk "${output%.apk}.apkm" "${output}" || return 1
	fi
}

# -------------------- apkpure --------------------
get_apkpure_resp() {
	local url="${1}"
	if [ -n "${__DL_RESP_CACHE__["apkpure_resp_$url"]:-}" ]; then
		__APKPURE_BASE_URL__="${__DL_RESP_CACHE__["apkpure_base_$url"]}"
		__APKPURE_PKG__="${__DL_RESP_CACHE__["apkpure_pkg_$url"]}"
		__APKPURE_RESP__="${__DL_RESP_CACHE__["apkpure_resp_$url"]}"
		return 0
	fi
	url="${url%/downloading*}"
	url="${url%/download*}"
	url="${url%/}"
	__APKPURE_BASE_URL__="$url"
	__APKPURE_PKG__=$(echo "$url" | grep -oP '[a-zA-Z][a-zA-Z0-9]*(\.[a-zA-Z][a-zA-Z0-9]*){1,}' | tail -1)
	local html=""
	_cf_get "${url}/downloading/" || return 1
	__APKPURE_RESP__="$html"
	__DL_RESP_CACHE__["apkpure_base_$1"]="$__APKPURE_BASE_URL__"
	__DL_RESP_CACHE__["apkpure_pkg_$1"]="$__APKPURE_PKG__"
	__DL_RESP_CACHE__["apkpure_resp_$1"]="$__APKPURE_RESP__"
}

get_apkpure_vers() {
	local ver
	ver=$(echo "$__APKPURE_RESP__" | sed 's/<h2[^>]*>/\n__H2__/g' | grep '__H2__' | sed 's/__H2__//' | grep -oP '[0-9]+\.[0-9][0-9.]*' | head -1) || true
	[ -z "$ver" ] && ver=$(echo "$__APKPURE_RESP__" | grep -oP '"softwareVersion":"\K[^"]+' | head -1) || true
	echo "$ver"
}

get_apkpure_pkg_name() { echo "$__APKPURE_PKG__"; }

# Build arch token -> the ABI name APKPure spells in its links. One mapping, because
# _apkpure_pick_link reads it out of the page and _apkpure_construct_link has to write the
# same spelling - a second copy would be a second thing to keep in sync.
_apkpure_abi_of() { # $1=arch token; prints nothing when this arch has no store spelling
	case "$1" in
		arm64-v8a | arm64) echo arm64-v8a ;;
		arm-v7a | arm) echo armeabi-v7a ;;
		x86_64) echo x86_64 ;;
		x86) echo x86 ;;
	esac
}

# Pick the best link for one arch out of a candidate set: universal first, then the
# exact ABI, then the pinned version code, then the newest code. Split out of
# _apkpure_pick_link so the preferred-kind pass and the fallback passes there rank
# their subsets with the same code and no duplicated ordering logic.
_apkpure_best_of() { # $1=candidate lines  $2=abi  $3=version code to prefer
	local cands picked
	[ -n "${1:-}" ] || return 1
	cands=$(printf '%s\n' "$1" | grep -E '[?&]nc=[^&]*%2C') || true
	if [ -z "$cands" ] && [ -n "${2:-}" ]; then
		cands=$(printf '%s\n' "$1" | grep -E "[?&]nc=${2}(&|$)") || true
	elif [ -z "$cands" ] && [ -z "${2:-}" ]; then
		return 1
	fi
	[ -z "$cands" ] && return 1
	if [ -n "${3:-}" ]; then
		picked=$(grep -F "versionCode=${3}" <<<"$cands") || true
		[ -n "$picked" ] && cands="$picked"
	fi
	picked=$(printf '%s\n' "$cands" | awk '
		{ vc = -1; if (match($0, /versionCode=[0-9]+/)) vc = substr($0, RSTART + 12, RLENGTH - 12) + 0
		  if (vc > best) { best = vc; line = $0 } }
		END { if (line) print line }
	')
	[ -z "$picked" ] && return 1
	printf '%s\n' "$picked"
}

# Choose APKPure's link for the architecture being built.
#
# An APKPure download page carries exactly one <a id="download_link"> - the variant
# APKPure happens to feature, which need not be the arch being built - plus a
# per-variant link for every ABI it publishes. atvTools 1.3.2 for example:
#
#   b/XAPK/<pkg>?versionCode=49&nc=armeabi-v7a&sv=26   <- the featured #download_link
#   b/XAPK/<pkg>?versionCode=49&nc=arm64-v8a&sv=26
#
# and, where an app is published universal, a multi-ABI single APK whose ABI list is
# comma separated and percent encoded:
#
#   b/APK/com.google.android.youtube?versionCode=...&nc=arm64-v8a%2Carmeabi-v7a%2Cx86%2Cx86_64&sv=29
#
# Taking the featured link for every arch meant an arm64 build fetched the
# armeabi-v7a bundle and published it under an arm64-v8a file name - the native code
# inside was simply wrong for the label (the two bases are different artifacts, only
# their AndroidManifest differs).
#
# Preference order: universal first, then the exact ABI, then give up. Universal wins
# because one fetch then serves every arch of the matrix and the store is asked once per
# app rather than once per arch - avoiding repeated hits from one egress IP is the point
# of the policy, since that is what gets an address blocked. atvTools publishes no
# universal at all, which is why the per-ABI link is a fallback and not an error. That
# axis is deliberately NOT the preferred-format knob: which ABI set a link covers is a
# quota concern; the knob only ever reorders the apk-vs-xapk kind within the picks.
#
# Returns 1 whenever nothing matches - the caller then keeps using the featured link and
# says so, which is all a single-variant app ever offers. Whether the fetched file really
# is universal stays decided by its contents, as everywhere else in this pipeline:
# _cache_arch_key reads the artifact and picks the cache key from that, never from here.
#
# $3 may be empty: a page with no featured anchor still lists its variants, and the
# version code the build wants is then taken from $4 (resolved from patch metadata or the
# config's version-code map by the build loop) instead of from the anchor.
#
# The chain-set path delegates the per-subset ranking to _apkpure_best_of; the unset
# path keeps the historical order - arch across both kinds first, featured kind
# filtering inside the arch set - untouched.
_apkpure_pick_link() { # $1=page html  $2=arch  $3=featured url  $4=version code to prefer
	local html=$1 arch=$2 featured=$3 want_vc=${4:-} abi="" want_type="" picked all_links chain
	abi=$(_apkpure_abi_of "$arch")
	want_type=$(grep -oE '/b/(XAPK|APK)/' <<<"$featured" | head -1) || true
	if [ -z "$want_vc" ]; then
		want_vc=$(grep -oE 'versionCode=[0-9]+' <<<"$featured" | head -1 | cut -d= -f2) || true
	fi
	chain=$(_pref_chain)

	all_links=$(grep -oE 'https://d\.apkpure\.com/b/(XAPK|APK)/[^"]+' <<<"$html" | sed 's/&amp;/\&/g' | sort -u) || true
	[ -z "$all_links" ] && return 1

	# No chain: the historical order exactly - arch rows are picked across BOTH kinds
	# first (universal over the exact ABI, the quota policy), and the featured link's
	# kind only filters within that arch set, so the caller's xapk-vs-apk handling does
	# not silently change shape.
	if [ -z "${chain:-}" ]; then
		local cands
		cands=$(printf '%s\n' "$all_links" | grep -E '[?&]nc=[^&]*%2C') || true
		if [ -z "$cands" ] && [ -n "$abi" ]; then
			cands=$(printf '%s\n' "$all_links" | grep -E "[?&]nc=${abi}(&|$)") || true
		elif [ -z "$cands" ]; then
			return 1
		fi
		if [ -n "$want_type" ]; then
			picked=$(grep -F "$want_type" <<<"$cands") || true
			[ -n "$picked" ] && cands="$picked"
		fi
		if [ -n "$want_vc" ]; then
			picked=$(grep -F "versionCode=${want_vc}" <<<"$cands") || true
			[ -n "$picked" ] && cands="$picked"
		fi
		picked=$(printf '%s\n' "$cands" | awk '
			{ vc = -1; if (match($0, /versionCode=[0-9]+/)) vc = substr($0, RSTART + 12, RLENGTH - 12) + 0
			  if (vc > best) { best = vc; line = $0 } }
			END { if (line) print line }
		')
		[ -z "$picked" ] && return 1
		printf '%s\n' "$picked"
		return 0
	fi

	# preferred-format outranks the featured link's kind when it is set: the chain names
	# the shape the build wants, and the featured anchor only ever states the shape the
	# store happened to advertise. Like every format order here it is a prefix, not a
	# veto - each further pass keeps the arch/versionCode predicates from the pass above.
	local pf_type
	pf_type=$(set -- $chain; [ "$1" = apk ] && printf '/b/APK/' || printf '/b/XAPK/')
	picked=$(_apkpure_best_of "$(printf '%s\n' "$all_links" | grep -F "$pf_type")" "$abi" "$want_vc") || true
	[ -n "$picked" ] && { printf '%s\n' "$picked"; return 0; }
	if [ -n "$want_type" ]; then
		picked=$(_apkpure_best_of "$(printf '%s\n' "$all_links" | grep -F "$want_type")" "$abi" "$want_vc") || true
		[ -n "$picked" ] && { printf '%s\n' "$picked"; return 0; }
	fi
	_apkpure_best_of "$all_links" "$abi" "$want_vc"
}

# Did APKPure actually serve an app page? A version the store does not carry is answered
# with HTTP 200 and a generic "Free APK Downloader Online" page - measured on
# /downloading/9.99: 294k chars, no app markup and no file link anywhere in it - so an
# empty link search has two completely different causes and only this tells them apart.
# A challenge or anti-bot interstitial has no file link either, which is why the caller
# also reports how the page was fetched.
_apkpure_has_file_links() { # $1=page html
	grep -qE 'https://d\.apkpure\.com/b/(XAPK|APK)/' <<<"${1:-}"
}

# The store's own file-link form, built without reading a page.
#
# This is not a guessed URL: it is the exact href APKPure puts in #download_link and in the
# hidden iframe_download of its /downloading/<v> page -
#   https://d.apkpure.com/b/XAPK/<pkg>?versionCode=<vc>&nc=<abi>
# - and it was measured (2026-10-09, from this machine) to honour both parameters without
# any page or cookie: versionCode=3240500 answers 302 with a different file per nc
# (arm64-v8a -> full_size=41069874, armeabi-v7a -> 54307675, both labelled
# Flipkart...9.15_APKPure.xapk), an unknown versionCode redirects to a target carrying no
# filename and no size, and sv= changes nothing (sv=99 returned the same bytes), so it is
# left out instead of being invented.
#
# It is reached only when every page this source read carried no file link at all, which is
# what the bypass sidecar's rendered DOM does for apkpure.com (run 37964499217: three pages
# per build, ~206k chars each, not one d.apkpure.com href in any of them), and only when the
# engine already resolved a version code from patch metadata or the config - never one
# chosen here. The bytes are then judged by the pipeline as usual (zip, manifest at root,
# package, version, signature, then the arch-honesty gate of docs/decisions/0007), and the
# caller logs that the link was constructed rather than scraped, so this cannot pass as a
# read from the store's markup. An arch with no store spelling (all, universal) gets nothing
# back, because there is no ABI to name and inventing one would be a claim, not a fallback.
_apkpure_construct_link() { # $1=pkg  $2=arch  $3=version code
	local abi
	abi=$(_apkpure_abi_of "$2")
	if [ -z "$abi" ] || [ -z "${3:-}" ] || [ -z "${1:-}" ]; then return 1; fi
	printf 'https://d.apkpure.com/b/XAPK/%s?versionCode=%s&nc=%s\n' "$1" "$3" "$abi"
}

dl_apkpure() {
	local url=$1 version=$2 output=$3 arch=${4:-} _dpi=${5:-} version_code=${7:-}
	local html=""

	local dl_page_url
	if [ -n "$version" ]; then
		dl_page_url="${__APKPURE_BASE_URL__}/downloading/${version}"
	else
		dl_page_url="${__APKPURE_BASE_URL__}/downloading/"
	fi

	_cf_get "$dl_page_url" || return 1

	if [ -z "$version" ]; then
		version=$(echo "$html" | sed 's/<h2[^>]*>/\n__H2__/g' | grep '__H2__' | sed 's/__H2__//' | grep -oP '[0-9]+\.[0-9][0-9.]*' | head -1) || true
		[ -z "$version" ] && version=$(echo "$html" | grep -oP '"softwareVersion":"\K[^"]+' | head -1) || true
	fi

	# APKPure's featured link: the one variant the page advertises, which need not be this
	# build's arch. It is a candidate below, never a precondition - see why at the page scan.
	local featured_url
	featured_url=$($HTMLQ "a#download_link" --attribute href <<<"$html" 2>/dev/null | head -1) || true
	[ -z "$featured_url" ] && \
		featured_url=$(echo "$html" | grep -oP '<a[^>]+id="download_link"[^>]+href="\Khttps://[^"]+' | head -1) || true
	[ -z "$featured_url" ] && \
		featured_url=$(echo "$html" | grep -oP 'id="download_link"[^>]*href="\Khttps://[^"]+' | head -1) || true
	[ -n "$featured_url" ] && featured_url=$(echo "$featured_url" | sed 's/&amp;/\&/g')

	# The featured link is only correct for the arch APKPure happened to feature, so ask
	# for this build's own variant and keep the featured one as the fallback.
	#
	# The version page is not enough: /downloading/<version> advertises only the single
	# variant APKPure features for that version (measured on atvTools 1.3.2: one
	# nc=armeabi-v7a link, no nc=arm64-v8a at all), while /download/<version> lists one link
	# per ABI for exactly that version (measured on flipkart 9.15: both
	# versionCode=3240500&nc=arm64-v8a and ...&nc=armeabi-v7a sit on it) and the app's
	# /download page lists the variants of whatever APKPure calls latest. So ask the page in
	# hand, then the version's own all-variants page, then latest, and only then fall back -
	# otherwise an arm64 build silently fetches a 32-bit bundle.
	#
	# A missing featured link does not stop any of that, and must not: it is server-rendered
	# markup, and a rendered DOM can lose it. When Cloudflare keeps challenging curl_cffi,
	# _cf_get returns the solver's browser DOM instead of the raw page - measured 2026-10-09
	# on flipkart 9.15: 209k chars against 280k for the same URL, with no #download_link in
	# it - and this source then died on the anchor while its variants were one page away.
	# Parsing what a page offers instead of requiring one particular element is what keeps
	# the source alive while a challenge is escalated.
	local apkpure_page_html="$html" variant_url="" page_html="" links_seen=false
	if [ -n "$featured_url" ]; then links_seen=true; fi
	variant_url=$(_apkpure_pick_link "$apkpure_page_html" "$arch" "$featured_url" "$version_code") || true

	if [ -z "$variant_url" ] && { [ -n "$arch" ] || [ -z "$featured_url" ]; }; then
		local -a apkpure_pages=()
		if [ -n "$version" ]; then
			apkpure_pages+=("${__APKPURE_BASE_URL__}/download/${version}")
		fi
		apkpure_pages+=("${__APKPURE_BASE_URL__}/download")
		local apkpure_page
		for apkpure_page in "${apkpure_pages[@]}"; do
			html=""
			if _cf_get "$apkpure_page" >/dev/null 2>&1; then
				page_html="$html"
				if _apkpure_has_file_links "$page_html"; then links_seen=true; fi
				variant_url=$(_apkpure_pick_link "$page_html" "$arch" "$featured_url" "$version_code") || true
			fi
			if [ -n "$variant_url" ]; then break; fi
		done
		html="$apkpure_page_html"
	fi

	local download_url=""
	if [ -n "$variant_url" ]; then
		download_url="$variant_url"
	elif [ -n "$featured_url" ]; then
		download_url="$featured_url"
		if [ -n "$arch" ] && ! isoneof "$arch" all universal; then
			# Deliberately still taken: when the store lists no variant for this arch the
			# featured link is the only thing there, and its real ABI is only knowable from
			# its bytes. It is fetched, fingerprinted into the download-link index, then judged
			# by the arch-honesty gate in build_rv - which rejects a wrong single ABI instead of
			# shipping it under this arch's name. A repeat job hits the index and skips the
			# fetch. (docs/decisions/0007)
			wpr "APKPure lists no '$arch' variant for '${__APKPURE_PKG__}'; using the featured link, which may carry a different ABI than '$arch'"
		fi
	else
		# Nothing on any page. Before calling that a store failure, take the one route that
		# does not depend on the page at all - the link form the store itself writes into its
		# download markup (see _apkpure_construct_link), for the version code the engine
		# already resolved. Needed because the bypass sidecar's rendered DOM carries no file
		# link whatsoever for this host: measured on run 37964499217, all three pages of every
		# build came back from /html at ~206k characters with not one d.apkpure.com href in
		# them, while the same URLs from a normal browser list the arm64 link. Scraping this
		# store from a datacenter address is therefore not a solvable problem, and the URL form
		# is - the file endpoint is checked by the pipeline afterwards exactly like a scraped one.
		download_url=$(_apkpure_construct_link "$__APKPURE_PKG__" "$arch" "$version_code") || true
		if [ -n "$download_url" ]; then
			wpr "APKPure pages carried no link (last page read via ${__CF_GET_VIA__:-unknown}); using the store's file-link form for '$arch' at versionCode $version_code - the artifact is verified from its bytes"
		elif [ "$links_seen" != true ]; then
			# Used to be one message for two different failures. Whether the store carries this
			# version at all and whether it publishes this arch are answered by different next
			# steps - a retry at another version, or a different source - so they are named apart,
			# with the fetch path that produced the page, because a rendered DOM is not the raw
			# page and only says something is absent from the markup it kept.
			local construct_reason
			if [ -z "$version_code" ]; then
				construct_reason="no target version code was resolved to build the link from"
			else
				construct_reason="arch '$arch' has no per-ABI spelling to build the link from"
			fi
			epr "APKPure served no app page for '${__APKPURE_PKG__}' v${version:-latest} - no file link on any page tried (fetched via ${__CF_GET_VIA__:-unknown}), and $construct_reason"
			return 1
		else
			epr "APKPure publishes no '${arch:-any}' variant for '${__APKPURE_PKG__}' v${version:-latest}"
			return 1
		fi
	fi

	pr "Downloading from APKPure: $download_url"
	local cookie_header=()
	[ -n "${CF_COOKIES:-}" ] && cookie_header=(-H "Cookie: $CF_COOKIES")

	local is_bundle=false
	echo "$download_url" | grep -qi 'xapk' && is_bundle=true

	local bundle="${output%.apk}.xapk"

	# Learned link index: the URL has no ABI in it, so consult what an earlier build
	# already fetched from this exact link. Adopt it (no network) when it satisfies
	# this arch, skip the source (no network) when it is a known other single ABI,
	# and only download-and-remember when nothing is recorded yet.
	local _idx=""
	_idx=$(_dlurl_index_lookup "$download_url" "$arch") || true
	if [ "$_idx" = REJECT ]; then
		wpr "APKPure link for '${__APKPURE_PKG__}' is known to serve a different ABI than '$arch'; skipping source without re-download"
		return 1
	fi

	if [ "$is_bundle" = true ]; then
		# d.apkpure.com sits behind Cloudflare (verified: Server: cloudflare, CF-RAY on the
		# file endpoint itself). It answers a residential IP with a plain 302 to the CDN and
		# a datacenter IP with a managed challenge, which is why this source works from a
		# laptop and 403s on the runner. The solver-backed path is the only one that can
		# clear it - the solver container shares the runner's egress IP, so the clearance it
		# earns is valid for the request that follows, provided the user agent travels with
		# it (cf_get.py applies the solver's UA). Plain curl stays as the fallback for
		# networks that are never challenged, and for when curl_cffi is not installed.
		#
		# --fail on the fallback matters: without it a challenge page exits 0, is written to
		# the .xapk, and only then trips the zip check, so the log blames a corrupt archive
		# instead of naming the HTTP status. APKPure challenges are also frequently
		# transient, hence the retry on the transient statuses curl knows.
		if [ -n "$_idx" ]; then
			cp -f "$_idx" "$bundle" || { rm -f "$bundle"; return 1; }
			pr "Adopting cached APKPure download for '$download_url' (no re-download)"
		else
			if ! _cf_cffi_download "$download_url" "$bundle" "$dl_page_url"; then
				rm -f "$bundle" 2>/dev/null
				curl -L --fail --retry 2 --retry-delay 3 --retry-connrefused -s -S \
					-H "User-Agent: ${user_agent:-$DEFAULT_UA}" \
					-H "Referer: $dl_page_url" \
					"${cookie_header[@]}" \
					--connect-timeout 30 --max-time 300 \
					"$download_url" -o "$bundle" || { rm -f "$bundle"; return 1; }
			fi
			_dlurl_index_record "$download_url" "$bundle"
		fi
		if ! _apkpure_install_xapk "$bundle" "${output}"; then
			rm -f "$bundle"
			return 1
		fi
		if [ "${MORPHE_PASSTHROUGH_ACTIVE:-false}" != true ]; then
			rm -f "$bundle"
		fi
	else
		if [ -n "$_idx" ]; then
			cp -f "$_idx" "${output}" || { rm -f "${output}"; return 1; }
			pr "Adopting cached APKPure download for '$download_url' (no re-download)"
		else
			if ! _cf_cffi_download "$download_url" "${output}" "$dl_page_url"; then
				rm -f "${output}" 2>/dev/null
				curl -L --fail -s -S \
					-H "User-Agent: ${user_agent:-$DEFAULT_UA}" \
					-H "Referer: $dl_page_url" \
					"${cookie_header[@]}" \
					--connect-timeout 30 --max-time 300 \
					"$download_url" -o "${output}" || { rm -f "${output}"; return 1; }
			fi
			_dlurl_index_record "$download_url" "${output}"
		fi
	fi
}

# Turn a downloaded bundle into the APK the download loop verifies, without merging when
# morphe will not use the result.
#
# morphe-desktop merges split bundles itself; build_rv adopts the vendor bundle sitting
# next to this output and deletes the merged file. So under passthrough a full apkeditor
# merge was pure waste - a JVM start, a rewrite and a re-sign of the archive, and the
# result thrown away minutes later. Two sources tried to dodge it with
# "cp -f bundle output", which puts bundle bytes into a .apk path; that only survives
# because the manifest-at-root check renames the file before anything reads metadata,
# and _meta_field_of decides "is this a bundle?" from the EXTENSION - so the copy makes
# every later probe look at a zip of zips instead of recognising it.
#
# Extracting base.apk is cheaper than both and leaves a real APK behind: package,
# versionName and versionCode all read correctly, the AndroidManifest check passes on
# its own terms, and the untouched bundle beside it is what gets cached and patched.
_bundle_to_apk() { # $1=bundle  $2=output apk
	local bundle=$1 output=$2
	if ! unzip -l "$bundle" >/dev/null 2>&1; then
		epr "Downloaded bundle is not a valid zip (anti-bot interstitial or truncated file): $bundle"
		return 1
	fi
	if [ "${MORPHE_PASSTHROUGH_ACTIVE:-false}" = true ]; then
		if ! _bundle_extract_base "$bundle" "$output"; then
			epr "Cannot extract base.apk from bundle: $bundle"
			return 1
		fi
		pr "Passthrough: verifying base.apk of $(basename "$bundle") (no merge)"
		return 0
	fi
	merge_splits "$bundle" "$output"
}

_apkpure_install_xapk() {
	local xapk=$1 output=$2
	if ! unzip -l "$xapk" >/dev/null 2>&1; then
		epr "Downloaded XAPK is not a valid zip (Cloudflare block?): $xapk"
		rm -f "$xapk"
		return 1
	fi
	if ! _bundle_to_apk "$xapk" "$output"; then
		rm -f "$output"
		return 1
	fi
}

# -------------------- apkcombo --------------------
get_apkcombo_resp() {
	local url="${1}"
	if [ -n "${__DL_RESP_CACHE__["apkcombo_resp_$url"]:-}" ]; then
		__APKCOMBO_RESP__="${__DL_RESP_CACHE__["apkcombo_resp_$url"]}"
		__APKCOMBO_PKG__="${__DL_RESP_CACHE__["apkcombo_pkg_$url"]}"
		__APKCOMBO_BASE_URL__="${__DL_RESP_CACHE__["apkcombo_base_$url"]}"
		return 0
	fi
	url="${url%/}"
	__APKCOMBO_PKG__="${url##*/}"
	__APKCOMBO_BASE_URL__="$url"
	local html=""
	_cf_get "https://apkcombo.com/search/${__APKCOMBO_PKG__}/download" || return 1
	__APKCOMBO_RESP__="$html"
	__DL_RESP_CACHE__["apkcombo_resp_$1"]="$__APKCOMBO_RESP__"
	__DL_RESP_CACHE__["apkcombo_pkg_$1"]="$__APKCOMBO_PKG__"
	__DL_RESP_CACHE__["apkcombo_base_$1"]="$__APKCOMBO_BASE_URL__"
}
get_apkcombo_vers() {
	echo "$__APKCOMBO_RESP__" | grep -oP 'phone-\K[0-9][^-]+-apk' | sed 's/-apk$//' | head -1
}
get_apkcombo_pkg_name() { echo "$__APKCOMBO_PKG__"; }
# Pick APKCombo's link for the architecture being built.
#
# The redesigned variant page keeps its download links in a hidden "APK Variants" tab,
# grouped by ABI: a <code>armeabi-v7a</code> / <code>arm64-v8a</code> header owns every
# link that follows it until the next header, and each link is the tokenised form
#
#   https://apkcombo.com/d?u=<url-safe base64 of https://download.pureapk.com/b/XAPK/...>
#
# dl_apkcombo used to take the first link it could find, which is always the first ABI
# on the page (armeabi-v7a for atvTools), so every arch build fetched the same 32-bit
# bundle under an arm64 file name - the defect just fixed on APKPure, here.
#
# Version scoping needs no handling: the page requested is already
# /download/phone-<version>-apk, so the first row inside a group is the newest shown.
#
# A fat row (its header names two ABIs with a '+', e.g. "arm64-v8a + armeabi-v7a") also
# satisfies a specific ABI, but only when the page has no single-ABI row for it - the
# narrow artifact is what the output file name promises.
#
# Returns 1 when the page has no row for this ABI; the caller then keeps the first link
# it saw on any page and says so, rather than failing the source silently.
_apkcombo_pick_link() { # $1=page html  $2=arch
	local abi flat lnk hit
	case "$2" in
		arm64-v8a | arm64) abi='arm64[-_]v8a' ;;
		arm-v7a | arm) abi='armeabi[-_]v7a' ;;
		x86_64) abi='x86_64' ;;
		x86) abi='x86' ;;
		all | universal) abi='' ;;
		*) return 1 ;;
	esac
	# Links wrap across newlines in the markup, so flatten before matching. .*? stops at
	# the first link after the matched header, and \K drops everything up to the URL.
	flat=$(tr -d '\n\r' <<<"$1")
	# Both link forms occur on this site and the difference is per app, not per release:
	# apps APKCombo hosts themselves link through /r2?u= to their own Cloudflare R2
	# bucket (YouTube does), apps they do not link through /d?u= to download.pureapk.com
	# and from there to apkpure.com (atvTools does). Only the first makes APKCombo an
	# independent source, so neither form may be dropped.
	lnk='(?:https://apkcombo\.com/d\?u=|/r2\?u=)[^"]+'
	# A header naming more than one ABI - comma or '+' separated, e.g.
	# <code>arm64-v8a, armeabi-v7a, x86, x86_64</code> - is the universal row. It wins
	# over a per-ABI row for the same reason as on APKPure: one download covers every
	# arch in the matrix, so the source is hit once per app rather than once per arch.
	if [ -z "$abi" ]; then
		hit=$(printf '%s' "$flat" | grep -oP "<code>[^<]*[+,][^<]*</code>.*?href=\"\\K$lnk" | head -1) || true
	else
		hit=$(printf '%s' "$flat" | grep -oP "<code>[^<]*${abi}[^<]*[+,][^<]*</code>.*?href=\"\\K$lnk" | head -1) || true
		[ -z "$hit" ] && hit=$(printf '%s' "$flat" | grep -oP "<code>${abi}</code>.*?href=\"\\K$lnk" | head -1) || true
	fi
	[ -n "$hit" ] && printf '%s\n' "$hit"
}
# What extension the bytes APKCombo is about to serve really have.
#
# The storage object key and the delivered file disagree for split bundles: the bucket
# holds "<sha>.apks" while the presigned URL overrides the response with
#
#   response-content-disposition=attachment; filename="<App>_<ver>_apkcombo.com.xapk"
#   response-content-type=application/xapk-package-archive
#
# Naming the sidecar from the key labelled those bytes ".apks", so the identical
# artifact arriving from APKPure (…-arm-v7a.xapk) and from APKCombo (…-arm-v7a.apks)
# took two cache entries and two release assets, and the file name misdescribed its
# content. The disposition is the server's own statement of what the file is, so it
# wins; the key remains the fallback for link forms that carry no disposition. Those
# values arrive percent-encoded twice over, hence two rounds of decoding before matching.
_apkcombo_served_ext() { # $@=urls to inspect
	local served
	served=$(printf '%s\n' "$@" | sed 's/%25/%/g; s/%22/"/g; s/%3D/=/g; s/%3B/;/g')
	grep -qiE 'filename=[^&;"]*\.xapk' <<<"$served" && { echo xapk; return; }
	grep -qiE 'filename=[^&;"]*\.apks' <<<"$served" && { echo apks; return; }
	grep -qi 'xapk' <<<"$served" && { echo xapk; return; }
	echo apks
}
dl_apkcombo() {
	local _url=$1 version=$2 output=$3 arch=${4:-} _dpi=${5:-}
	local html="" dl_url="" final_url checkin page_url page compact_page any_url=""

	if [ -n "$version" ]; then
		local _pfc sfxs
		_pfc=$(_pref_chain)
		if [ -n "$_pfc" ]; then
			# set + "$@" copies the whole word-split list; a here-string with
			# `read -a` would take only its first line and drop the rest.
			set -- $(_pref_ext_order "$_pfc" apk xapk apks)
			sfxs=("$@")
		else
			sfxs=("apk" "xapk" "apks")
		fi
	else
		local sfxs=("apk")
	fi

	for sfx in "${sfxs[@]}"; do
		if [ -n "$version" ]; then
			local safe_version="${version// /-}"
			page_url="https://apkcombo.com/search/${__APKCOMBO_PKG__}/download/phone-${safe_version}-${sfx}"
		else
			page_url="https://apkcombo.com/search/${__APKCOMBO_PKG__}/download/apk"
		fi

		_cf_get "$page_url" "https://apkcombo.com/" || continue
		page="$html"
		compact_page=$(tr '\n' ' ' <<<"$page")

		if [ -n "$version" ]; then
			local page_vername
			page_vername=$(echo "$page" | grep -oP '<span class="vername">\K[^<]+' | head -1) || true
			if [ -n "$page_vername" ] && ! echo "$page_vername" | grep -qFi "$version"; then
				wpr "Version mismatch on APKCombo: requested '$version' but found '$page_vername'"
				continue
			fi
		fi

		dl_url=$(_apkcombo_pick_link "$page" "$arch") || true
		if [ -z "$dl_url" ]; then
			# No row labelled for this arch here. Remember any link on the page, but keep
			# looking: the next suffix page may still have a labelled row, and a labelled
			# artifact beats an unverified one.
			local any_link
			any_link=$(tr -d '\n\r' <<<"$page" | grep -oP 'https://apkcombo\.com/d\?u=[A-Za-z0-9_=+/%-]+' | head -1) || true
			[ -z "$any_url" ] && any_url="$any_link"
		fi
		[ -z "$dl_url" ] && dl_url=$(echo "$page" | grep -oP '(?<=a href=")https://download\.apkcombo\.com/[^"]+' | head -1) || true
		[ -z "$dl_url" ] && dl_url=$(echo "$page" | grep -oP '(?<=a href=")/r2[^"]+' | head -1) || true
		[ -z "$dl_url" ] && dl_url=$(echo "$compact_page" | grep -oP '"download_url"\s*:\s*"\K[^"]+' | head -1 | sed 's#\\/#/#g') || true
		[ -z "$dl_url" ] && dl_url=$(echo "$compact_page" | grep -oP '"url"\s*:\s*"\Khttps://download\.apkcombo\.com/[^"]+' | head -1 | sed 's#\\/#/#g') || true
		[ -z "$dl_url" ] && dl_url=$(echo "$compact_page" | grep -oP 'https://download\.apkcombo\.com/[^"'"'"' <>]+' | head -1 | sed 's#\\/#/#g') || true
		[ -z "$dl_url" ] && dl_url=$(echo "$compact_page" | grep -oP '/r2\?u=[^"'"'"' <>]+' | head -1 | sed 's#\\/#/#g') || true

		if [ -n "$dl_url" ]; then
			break
		fi
	done

	if [ -z "$dl_url" ] && [ -n "$any_url" ]; then
		# Same as APKPure: this link's real ABI is decided by its bytes downstream, not
		# by the unlabelled URL here. It is fingerprinted into the download-link index and
		# then judged by the arch-honesty gate in build_rv (docs/decisions/0007).
		wpr "APKCombo lists no '$arch' variant for '${__APKCOMBO_PKG__}'; using the first link on the page, which may carry a different ABI"
		dl_url="$any_url"
	fi

	[ -z "$dl_url" ] && { epr "Could not find APK link on APKCombo"; return 1; }
	[[ "$dl_url" != http* ]] && dl_url="https://apkcombo.com${dl_url}"
	dl_url=$(echo "$dl_url" | sed 's/\\u0026/\&/g; s/&amp;/\&/g')

	if [[ "$dl_url" == *apkcombo.com/d\?u=* ]]; then
		# Tokenised wrapper: it carries its own signed path, so the checkin parameters the
		# old /r2 form expected must not be appended to it, and it resolves to the file
		# through a redirect chain that ends on another host entirely.
		final_url="$dl_url"
	elif [[ "$dl_url" == https://apkcombo.com/r2\?u=* ]]; then
		final_url=$(python - <<'PYC' "$dl_url"
import sys, urllib.parse
u=sys.argv[1]
q=urllib.parse.urlparse(u).query
raw=urllib.parse.parse_qs(q).get('u',[''])[0]
decoded=urllib.parse.unquote(raw)
parts=urllib.parse.urlsplit(decoded)
query=urllib.parse.parse_qsl(parts.query, keep_blank_values=True)
encoded=urllib.parse.urlunsplit((
    parts.scheme,
    parts.netloc,
    urllib.parse.quote(parts.path, safe='/'),
    urllib.parse.urlencode(query, doseq=True, safe='/:_-.'),
    parts.fragment,
))
print(encoded)
PYC
		) || return 1
	else
		checkin=$(req "https://apkcombo.com/checkin" -) || true
		if [ -n "$checkin" ] && [[ "$dl_url" != *fp=* ]]; then
			if [[ "$dl_url" == *\?* ]]; then
				dl_url="${dl_url}&${checkin}"
			else
				dl_url="${dl_url}?${checkin}"
			fi
		fi
		final_url=$(curl -s -o /dev/null -w "%{url_effective}" -L --max-redirs 10 \
			-H "User-Agent: ${user_agent:-$DEFAULT_UA}" \
			-H "Referer: $page_url" "$dl_url") || return 1
	fi

	# Learned link index (see dl_apkpure): adopt without a fetch, skip a known wrong
	# ABI without a fetch, otherwise fetch once and remember what the bytes are.
	local _idx=""
	_idx=$(_dlurl_index_lookup "$final_url" "$arch") || true
	if [ "$_idx" = REJECT ]; then
		wpr "APKCombo link is known to serve a different ABI than '$arch'; skipping source without re-download"
		return 1
	fi

	pr "Downloading from APKCombo: $final_url"
	# The redirect chain from apkcombo.com -> download.pureapk.com -> data.winudf.com
	# forbids cross-origin referers from apkcombo.com (pureapk treats it as hotlinking
	# and redirects to apkpure.com/url?e=2 which 403s). Send with no referer.
	if [ -n "$_idx" ]; then
		cp -f "$_idx" "$output" || { rm -f "$output"; return 1; }
		pr "Adopting cached APKCombo download for '$final_url' (no re-download)"
	else
		if ! _cf_cffi_download "$final_url" "$output" ""; then
			rm -f "$output" 2>/dev/null
			curl -L --fail -s -S --connect-timeout 30 --max-time 300 \
				-H "User-Agent: ${user_agent:-$DEFAULT_UA}" \
				"$final_url" -o "$output" || { rm -f "$output"; return 1; }
		fi
		_dlurl_index_record "$final_url" "$output"
	fi
	if ! unzip -l "$output" >/dev/null 2>&1; then
		epr "Downloaded file from APKCombo is not a valid zip"
		rm -f "$output"
		return 1
	fi
	if echo "$final_url$dl_url" | grep -qi 'xapk\|\.apks'; then
		local ext
		ext=$(_apkcombo_served_ext "$final_url" "$dl_url")
		if ! _apkpure_install_xapk "$output" "${output}.extracted"; then
			rm -f "$output" "${output}.extracted"
			return 1
		fi
		if [ "${MORPHE_PASSTHROUGH_ACTIVE:-false}" = true ]; then
			cp -f "$output" "${output%.apk}.${ext}"
		fi
		mv "${output}.extracted" "$output"
	fi
}


# -------------------- uptodown --------------------
get_uptodown_resp() {
	local url="${1}"
	local clean_url="${url%/versions}"
	clean_url="${clean_url%/download}"
	clean_url="${clean_url%/}"
	__UPTODOWN_CLEAN_URL__="$clean_url"
	[ -n "${__DL_RESP_CACHE__["uptodown_resp_$url"]:-}" ] && return 0
	__DL_RESP_CACHE__["uptodown_resp_$url"]="$clean_url"
	return 0
}

get_uptodown_vers() {
	local py_cmd=""
	if command -v python3 >/dev/null 2>&1; then
		py_cmd="python3"
	elif command -v python >/dev/null 2>&1; then
		py_cmd="python"
	fi

	local py_script="${CWD}/scripts/uptodown.py"
	[ ! -f "$py_script" ] && [ -n "${BASH_SOURCE[0]:-}" ] && py_script="$(dirname "${BASH_SOURCE[0]}")/uptodown.py"

	local allow_all="${__AAV__:-false}"
	if [ -n "$py_cmd" ] && [ -f "$py_script" ] && [ -n "${__UPTODOWN_CLEAN_URL__:-}" ]; then
		local py_vers
		if py_vers=$("$py_cmd" "$py_script" vers "$__UPTODOWN_CLEAN_URL__" "$allow_all" 2>/dev/null) && [ -n "$py_vers" ]; then
			echo "$py_vers"
			return 0
		fi
	fi
	# uptodown.py is the only implementation of this scrape. The grep/htmlq pass that
	# used to follow it read __UPTODOWN_RESP__, which nothing has assigned since the
	# scrape moved into python (get_uptodown_resp only normalises the URL now), so it
	# could never answer anything but empty - and an empty answer is indistinguishable
	# from "the store has no versions", which is how one flaky scrape silently handed
	# the watcher a DIFFERENT source, and a version with it.
	# A missing answer deliberately still returns 0: build.sh calls
	# `pkgvers=$(get_${dl_from}_vers)` under `set -e`, so a non-zero here aborts the
	# whole app instead of falling through to the next source. Emptiness is the
	# caller's to notice - the watcher reports it as a fall-through.
	echo ""
}

get_uptodown_pkg_name() {
	local py_cmd=""
	if command -v python3 >/dev/null 2>&1; then
		py_cmd="python3"
	elif command -v python >/dev/null 2>&1; then
		py_cmd="python"
	fi

	local py_script="${CWD}/scripts/uptodown.py"
	[ ! -f "$py_script" ] && [ -n "${BASH_SOURCE[0]:-}" ] && py_script="$(dirname "${BASH_SOURCE[0]}")/uptodown.py"

	if [ -n "$py_cmd" ] && [ -f "$py_script" ] && [ -n "${__UPTODOWN_CLEAN_URL__:-}" ]; then
		local py_pkg
		if py_pkg=$("$py_cmd" "$py_script" pkg "$__UPTODOWN_CLEAN_URL__" 2>/dev/null) && [ -n "$py_pkg" ]; then
			echo "$py_pkg"
			return 0
		fi
	fi

	# Same reason as get_uptodown_vers: no shell fallback, because there is no shell
	# HTML left to parse. An unanswered package name stays empty with rc 0, and the
	# caller's own "Could not determine pkg_name" branch is what reports it.
	echo ""
}

dl_uptodown() {
	local uptodown_dlurl=$1 version=$2 output=$3 arch=$4 _dpi=$5
	# Keep the build-arch token for the link index; $arch is remapped to the store's
	# ABI spelling below for the resolver, and the index keys speak build tokens.
	local _arch_f="$arch"
	if [ "$arch" = "arm-v7a" ]; then arch="armeabi-v7a"; fi

	local py_cmd=""
	if command -v python3 >/dev/null 2>&1; then
		py_cmd="python3"
	elif command -v python >/dev/null 2>&1; then
		py_cmd="python"
	fi

	local py_script="${CWD}/scripts/uptodown.py"
	[ ! -f "$py_script" ] && [ -n "${BASH_SOURCE[0]:-}" ] && py_script="$(dirname "${BASH_SOURCE[0]}")/uptodown.py"

	# preferred-format reaches the resolver as its own argument: Uptodown's rows carry
	# only an is_xapk flag, so the chain collapses to a class there (see _pref_class_order)
	# and the store's own kindFile still decides the final extension.
	local pref_fmt
	pref_fmt=$(_pref_chain)

	local errf="${TEMP_DIR}/uptodown_resolve_$$.err"
	if [ -n "$py_cmd" ] && [ -f "$py_script" ]; then
		local py_info="" attempt
		# Retry: Uptodown's API/auth endpoints are bot-gated and can throw
		# intermittently (HTTP 403/503 or a JSON error) from datacenter IPs
		# like GitHub runners. A few short-backoff attempts ride out transient
		# blocks; stderr is captured (not discarded) so a hard failure reports
		# its real cause instead of a blank "Failed to resolve".
		for attempt in 1 2 3; do
			if py_info=$("$py_cmd" "$py_script" download-url "$uptodown_dlurl" "$version" "$arch" "${pref_fmt:-}" 2>"$errf") && [ -n "$py_info" ]; then
				break
			fi
			py_info=""
			if [ "$attempt" -lt 3 ]; then
				sleep $((attempt * 2))
			fi
		done
		if [ -n "$py_info" ]; then
			local cdn_url is_bundle
			cdn_url=$(cut -f1 <<<"$py_info")
			is_bundle=$(cut -f2 <<<"$py_info")

			pr "Downloading from Uptodown CDN: $cdn_url"
			# Learned link index (see dl_apkpure): adopt, skip, or fetch-and-remember.
			local _idx=""
			_idx=$(_dlurl_index_lookup "$cdn_url" "$_arch_f") || true
			if [ "$_idx" = REJECT ]; then
				wpr "Uptodown link is known to serve a different ABI than '$_arch_f'; skipping source without re-download"
				rm -f "$errf"
				return 1
			fi
			if [ "$is_bundle" = "true" ]; then
				local bundle="${output%.apk}.apkm"
				if [ -n "$_idx" ]; then
					cp -f "$_idx" "$bundle" || { rm -f "$errf"; return 1; }
					pr "Adopting cached Uptodown download for '$cdn_url' (no re-download)"
				else
					req "$cdn_url" "$bundle" || { rm -f "$errf"; return 1; }
					_dlurl_index_record "$cdn_url" "$bundle"
				fi
				_bundle_to_apk "$bundle" "${output}" || { rm -f "$bundle" "$errf"; return 1; }
				[ "${MORPHE_PASSTHROUGH_ACTIVE:-false}" != true ] && rm -f "$bundle"
			else
				if [ -n "$_idx" ]; then
					cp -f "$_idx" "${output}" || { rm -f "$errf"; return 1; }
					pr "Adopting cached Uptodown download for '$cdn_url' (no re-download)"
				else
					req "$cdn_url" "${output}" || { rm -f "$errf"; return 1; }
					_dlurl_index_record "$cdn_url" "${output}"
				fi
			fi
			rm -f "$errf"
			return 0
		fi
	fi

	local reason=""
	if [ -f "$errf" ]; then
		reason=$(tail -1 "$errf" 2>/dev/null)
	fi
	epr "Failed to resolve Uptodown download URL for $uptodown_dlurl version $version: ${reason:-unknown error}"
	rm -f "$errf"
	return 1
}

# -------------------- fdroid --------------------
# An F-Droid repo publishes one APK per version code under <repo>/<pkg>_<code>.apk and
# declares the ABIs that file carries instead of splitting per ABI (measured over a
# 1400-app repo: 2964 released entries, no ABI-suffixed file name, and only two names
# that deviate from <pkg>_<code>.apk - both author quirks). So this source needs no
# variant picker: the version code identifies the file, and the arch is judged off the
# bytes by build_rv's artifact gate like everywhere else.
#
# Two URL shapes are accepted, because those are the two things a human can copy out of
# a browser:
#   <origin>/[<lang>/]packages/<pkg>   a package page on f-droid.org or on any site
#                                      running the same web app. Its per-package JSON
#                                      (GET <origin>/api/v1/packages/<pkg>) lists the
#                                      recent releases in about 200 bytes, so the repo's
#                                      own index - 15.8 MB compressed, ~190 MB as JSON
#                                      there - is never fetched. It carries no ABI list,
#                                      which is why that column may be empty.
#   <host>/<path>/repo                 a bare third-party repo root (an author's GitLab
#                                      pages repo, IzzyOnDroid). Read through
#                                      index-v1.jar -> index-v1.json, which gives the
#                                      published file name verbatim plus `nativecode`.
#                                      Needs `pkg-name`: nothing in a repo root says
#                                      which app is wanted.
# Parsed releases are kept as one tab-separated row each:
#   versionName  versionCode  apkName  arch-tokens("" when the repo does not say)
__FDROID_URL__="" __FDROID_ORIGIN__="" __FDROID_REPO__="" __FDROID_PKG__="" __FDROID_TABLE__=""

# Split a config URL into repo + package, writing __FDROID_ORIGIN__/__FDROID_REPO__/
# __FDROID_PKG__ (origin stays empty for the repo-root form, which has no site API to
# ask). Set as globals rather than echoed for a positional read: a leading empty field
# does not survive `read`, tab or no tab, and a repo root is exactly the case where the
# first field is empty.
_fdroid_split_url() { # $1=url
	local url=${1%/}
	__FDROID_ORIGIN__="" __FDROID_REPO__="" __FDROID_PKG__=""
	case "$url" in
		*://*/*packages/*)
			__FDROID_ORIGIN__=$(sed -E 's#^(https?://[^/]+).*#\1#' <<<"$url")
			__FDROID_REPO__="${__FDROID_ORIGIN__}/repo"
			__FDROID_PKG__="${url##*/packages/}"
			;;
		*://*/*)
			__FDROID_REPO__="$url"
			__FDROID_PKG__="${pkg_name:-}"
			;;
		*)
			return 1
			;;
	esac
	[ -n "${__FDROID_REPO__}" ]
}

get_fdroid_resp() { # $1=url
	local url="${1%/}" json rows
	if [ "$url" = "$__FDROID_URL__" ] && [ -n "$__FDROID_TABLE__" ]; then
		return 0
	fi
	_fdroid_split_url "$url" || { epr "ERROR: '$url' is neither an F-Droid package page nor a repo root"; return 1; }
	if [ -z "$__FDROID_PKG__" ]; then
		epr "ERROR: '$url' is a bare F-Droid repo, which names no app; set 'pkg-name' in the config"
		return 1
	fi
	rows=""
	if [ -n "$__FDROID_ORIGIN__" ]; then
		local api="${__FDROID_ORIGIN__}/api/v1/packages/${__FDROID_PKG__}"
		# The page form: the site API knows the versions, the grammar names the file.
		# Guarded because a package the repo does not carry answers 404, which is a
		# per-source miss like any other and must not abort the app's whole build.
		if ! json=$(req "$api" -); then
			epr "ERROR: Could not read the F-Droid package list for '$__FDROID_PKG__' from $api"
			return 1
		fi
		[ -n "$json" ] || { epr "ERROR: F-Droid API returned nothing for '$__FDROID_PKG__' at $api"; return 1; }
		rows=$(jq -r --arg pkg "$__FDROID_PKG__" '
			(.packages // [])[]
			| select(.versionCode != null)
			| [ ((.versionName // "") | tostring), (.versionCode | tostring),
			    ($pkg + "_" + (.versionCode | tostring) + ".apk"), "" ]
			| @tsv' <<<"$json" 2>/dev/null) || rows=""
	else
		# The repo form: read the signed index jar the repo publishes.
		local jar="${TEMP_DIR}/fdroid-index-$(_dlurl_sha "$__FDROID_REPO__").jar" member="" _try
		mkdir -p "$TEMP_DIR" 2>/dev/null || true
		for _try in index-v1.jar index.jar; do
			if req "$__FDROID_REPO__/$_try" "$jar" 2>/dev/null; then
				for member in index-v1.json index.json; do
					if json=$(unzip -p "$jar" "$member" 2>/dev/null) && [ -n "$json" ]; then break 2; fi
				done
			fi
			rm -f "$jar"
			member=""
		done
		if [ -z "$member" ]; then
			epr "ERROR: Could not read an index (index-v1.jar / index.jar) from the F-Droid repo '$__FDROID_REPO__'"
			rm -f "$jar"
			return 1
		fi
		rows=$(jq -r --arg pkg "$__FDROID_PKG__" '
			def abis: (.nativecode // []) | map(({"armeabi-v7a": "arm-v7a"}[.]) // .) | join(" ");
			(.packages[$pkg] // [])[]
			| select(.apkName != null and .versionCode != null)
			| [ ((.versionName // "") | tostring), (.versionCode | tostring), .apkName, abis ]
			| @tsv' <<<"$json" 2>/dev/null) || rows=""
		json=""
		rm -f "$jar"
	fi
	# Newest release first: several apps ship more than one build per version name.
	rows=$(sort -t$'\t' -k2,2nr <<<"$rows" | grep . || :)
	if [ -z "$rows" ]; then
		epr "ERROR: F-Droid repo '$__FDROID_REPO__' lists no released APK for '$__FDROID_PKG__'"
		return 1
	fi
	__FDROID_URL__="$url"
	__FDROID_TABLE__="$rows"
	pr "F-Droid repo '$__FDROID_REPO__' has $(grep -c . <<<"$rows") release(s) of '$__FDROID_PKG__'; newest $(head -1 <<<"$rows" | cut -f1,2 | tr '\t' ' ')"
	return 0
}

# Reported only from the table get_fdroid_resp parsed off the repo.
get_fdroid_vers() {
	[ -n "$__FDROID_TABLE__" ] || return 1
	cut -f1 <<<"$__FDROID_TABLE__"
}
get_fdroid_pkg_name() {
	[ -n "$__FDROID_PKG__" ] || return 1
	printf '%s\n' "$__FDROID_PKG__"
}

dl_fdroid() { # url version output arch dpi get_latest target_version_code
	local url="${1%/}" version=$2 output=$3 arch=${4// /} _dpi=$5 latest=$6 target_vc=${7:-}
	[ "$url" = "$__FDROID_URL__" ] || get_fdroid_resp "$url" || return 1
	[ -n "$__FDROID_TABLE__" ] || return 1

	# A pinned version code selects the release outright - which is why this source
	# needs no variant picker - otherwise the version name does, and a name with no
	# match at all falls to the newest release only when listing latest.
	local pick=""
	if [ -n "$target_vc" ]; then
		pick=$(awk -F'\t' -v c="$target_vc" '$2 == c' <<<"$__FDROID_TABLE__")
	elif [ -n "$version" ]; then
		pick=$(awk -F'\t' -v v="$version" '$1 == v' <<<"$__FDROID_TABLE__")
	fi
	if [ -z "$pick" ] && [ "$latest" = true ]; then
		pick=$(head -1 <<<"$__FDROID_TABLE__")
	fi
	if [ -z "$pick" ]; then
		wpr "F-Droid repo '$__FDROID_REPO__' has no release of '$__FDROID_PKG__' matching '$version'${target_vc:+ (code $target_vc)}; skipping source"
		return 1
	fi

	# Among the releases that match, take one whose declared ABIs cover the requested
	# arch. An empty column means the repo does not declare ABIs (the site API), and is
	# left to build_rv's artifact gate rather than refused here.
	local row="" abis="" sel=""
	while IFS= read -r row; do
		[ -n "$row" ] || continue
		abis=$(cut -f4 <<<"$row")
		if [ -z "$abis" ] || _abis_satisfies "$abis" "$arch"; then sel="$row"; break; fi
	done <<<"$pick"
	if [ -z "$sel" ]; then
		wpr "Every F-Droid release of '$__FDROID_PKG__' v${version} excludes the requested '$arch'; skipping source"
		return 1
	fi

	local name=$(cut -f1 <<<"$sel") code=$(cut -f2 <<<"$sel") apk=$(cut -f3 <<<"$sel")
	pr "Downloading '$name' ($code) from F-Droid: $__FDROID_REPO__/$apk"
	req "$__FDROID_REPO__/$apk" "$output" || return 1
}
# --------------------------------------------------

# -------------------- archive --------------------
dl_archive() {
	local url=$1 version=$2 output=$3 arch=$4 is_bundle=${5:-false} get_latest_ver=${6:-false} version_code=${7:-}
	local path="" version_f=${version// /}
	local norm_resp="${__ARCHIVE_RESP__//$'\r'/}"
	# Extension scan order, once for both passes below. The legacy composite names
	# (apk.apkm/...) stay in the tail exactly where they always were: a chain token
	# selects the plain spelling; when a file with a composite name is the only one
	# present it is still found, one loop later than before.
	local _pfa _exts
	_pfa=$(_pref_chain)
	if [ -n "$_pfa" ]; then
		# set copies the word-split list (one entry per line) into the array - a here-
		# string + `read -a` would stop after the first line and silently drop every
		# later extension, including the composites. Positional parameters are local
		# to the function, so the caller's "$@" is untouched.
		set -- $(_pref_ext_order "$_pfa" apk apkm xapk apks) apk.apkm apk.xapk apk.apks
		_exts=("$@")
	else
		_exts=("apk" "apkm" "xapk" "apks" "apk.apkm" "apk.xapk" "apk.apks")
	fi
	if [ -n "$version_code" ]; then
		for a in "${arch// /}" "all"; do
			for ext in "${_exts[@]}"; do
				while IFS= read -r p; do
					if [[ "$p" == *"${version_f#v}-${version_code}-${a}.${ext}" ]]; then
						path="$p"
						break 3
					fi
				done <<<"$norm_resp"
			done
		done
	fi
	if [ -z "$path" ]; then
		for a in "${arch// /}" "all"; do
			for ext in "${_exts[@]}"; do
				while IFS= read -r p; do
					if [[ "$p" == *"${version_f#v}-${a}.${ext}" ]]; then
						path="$p"
						break 3
					fi
				done <<<"$norm_resp"
			done
		done
	fi
	if [ -z "$path" ]; then
		epr "Version ${version} with arch ${arch} not found in archive"
		return 1
	fi
	case "${path##*.}" in
		apk)
			req "${url}/${path}" "$output"
			;;
		apkm|xapk|apks)
			local bundle="${output%.apk}.${path##*.}"
			req "${url}/${path}" "$bundle" || return 1
			_bundle_to_apk "$bundle" "${output}" || { rm -f "$bundle"; return 1; }
			if [ "${MORPHE_PASSTHROUGH_ACTIVE:-false}" != true ]; then
				rm -f "$bundle"
			fi
			;;
		*)
			epr "Unsupported archive file type for ${path}"
			return 1
			;;
	esac
}
get_archive_resp() {
	local url="${1}"
	if [ -n "${__DL_RESP_CACHE__["archive_resp_$url"]:-}" ]; then
		__ARCHIVE_RESP__="${__DL_RESP_CACHE__["archive_resp_$url"]}"
		__ARCHIVE_PKG_NAME__="${__DL_RESP_CACHE__["archive_pkg_$url"]}"
		return 0
	fi
	local r
	r=$(req "$url" -)
	if [ -z "$r" ]; then return 1; else __ARCHIVE_RESP__=$(sed -n 's;^<a href="\(.*\)"[^"]*;\1;p' <<<"$r"); fi
	__ARCHIVE_PKG_NAME__=$(awk -F/ '{print $NF}' <<<"$url")
	__DL_RESP_CACHE__["archive_resp_$url"]="$__ARCHIVE_RESP__"
	__DL_RESP_CACHE__["archive_pkg_$url"]="$__ARCHIVE_PKG_NAME__"
}
get_archive_vers() {
	if command -v python3 >/dev/null 2>&1 || command -v python >/dev/null 2>&1; then
		local py_bin="python3"
		command -v python3 >/dev/null 2>&1 || py_bin="python"
		"$py_bin" -c "
import sys, re
pat = re.compile(r'^[^-]*-|(-[0-9]+)?-(all|arm64-v8a|arm-v7a|x86|x86_64)\.(apk|apkm|xapk|apks)$')
for line in sys.stdin:
    l = line.strip()
    if l:
        print(pat.sub('', l))
" <<<"$__ARCHIVE_RESP__"
	else
		sed -E 's/^[^-]*-//;s/(-[0-9]+)?-(all|arm64-v8a|arm-v7a|x86|x86_64)\.(apk|apkm|xapk|apks)$//g' <<<"$__ARCHIVE_RESP__"
	fi
}
get_archive_pkg_name() { echo "$__ARCHIVE_PKG_NAME__"; }

# -------------------- github --------------------
dl_github() {
    local url=$1 version=$2 output=$3 arch=$4 is_bundle=${5:-false} get_latest_ver=${6:-false}
    local path="" version_f=${version// /}
    local repo=$(cut -d/ -f4-5 <<<"$url")
    local exact_tag=""
    while IFS= read -r t; do
        [ -z "$t" ] && continue
        if [ "$t" = "v${version_f#v}" ] || [ "$t" = "${version_f#v}" ]; then
            exact_tag="$t"
            break
        fi
    done <<<"$__GITHUB_TAG__"

    if [ -z "$exact_tag" ]; then
        local tag_lines
        tag_lines=$(grep -c . <<<"$__GITHUB_TAG__" || true)
        if [ "$tag_lines" -eq 1 ]; then
            exact_tag="$__GITHUB_TAG__"
        else
            exact_tag="v${version_f#v}"
        fi
    fi
    local base_url="https://github.com/${repo}/releases/download/${exact_tag}"
    
local regex=""
    if [ -n "${args[github_regex]:-}" ]; then
        if [[ "${args[github_regex]}" == *":"* ]]; then
            regex=$(echo "${args[github_regex]}" | awk -F'|' -v a="$arch" '{
                for(i=1;i<=NF;i++) {
                    split($i, kv, ":")
                    gsub(/^[ \t'\''"]+|[ \t'\''"]+$/, "", kv[1])
                    if(kv[1] == a) {
                        gsub(/^[ \t'\''"]+|[ \t'\''"]+$/, "", kv[2])
                        print kv[2]
                        exit
                    }
                }
            }')
        else
            regex="${args[github_regex]}"
        fi
    fi

    if [ -n "$regex" ] && [ "$dl_p" != "cache_repo" ]; then
        regex="${regex//\{version\}/${version_f#v}}"
        regex="${regex//\{arch\}/${arch}}"
        path=$(grep -iE "$regex" <<<"$__GITHUB_RESP__" | head -1)
    else
        # Matches the exact file selection logic from dl_archive
        local norm_resp="${__GITHUB_RESP__//$'\r'/}"
        for a in "${arch// /}" "all"; do
            for ext in "apk" "apkm" "xapk" "apks" "apk.apkm" "apk.xapk" "apk.apks"; do
                while IFS= read -r p; do
                    if [[ "$p" == *"${version_f#v}-${a}.${ext}" ]]; then
                        path="$p"
                        break 3
                    fi
                done <<<"$norm_resp"
            done
        done
    fi
    
    path="${path%$'\r'}"
    if [ -z "$path" ]; then
        epr "Version ${version} with arch ${arch} not found in github"
        return 1
    fi
    
    local ext="${path##*.}"
    case "$ext" in
        apk)
            req "${base_url}/${path}" "$output"
            ;;
        apkm|xapk|apks)
			local bundle="${output%.apk}.${ext}"
			req "${base_url}/${path}" "$bundle" || return 1
			_bundle_to_apk "$bundle" "$output" || { rm -f "$bundle"; return 1; }
			if [ "${MORPHE_PASSTHROUGH_ACTIVE:-false}" != true ]; then
				rm -f "$bundle"
			fi
            ;;
        *)
            epr "Unsupported github file type for ${path}"
            return 1
            ;;
    esac
}

get_github_resp() {
	local url="${1}"
	local cache_key="${url}_${pkg_name:-default}"
	if [ -n "${__DL_RESP_CACHE__["github_resp_$cache_key"]:-}" ]; then
		__GITHUB_RESP__="${__DL_RESP_CACHE__["github_resp_$cache_key"]}"
		__GITHUB_PKG_NAME__="${__DL_RESP_CACHE__["github_pkg_$cache_key"]}"
		__GITHUB_URL__="${__DL_RESP_CACHE__["github_url_$cache_key"]}"
		__GITHUB_TAG__="${__DL_RESP_CACHE__["github_tag_$cache_key"]}"
		return 0
	fi
	local repo tag resp endpoint
	
	repo=$(cut -d/ -f4-5 <<<"$url")
	tag=${url%/}
	tag=${tag##*/}
	
	if [ "$tag" = "${repo##*/}" ]; then
		if [ -n "${resolved_version:-}" ]; then
			tag="v${resolved_version#v}"
		elif [ -n "${version:-}" ] && ! isoneof "$version" auto latest beta exp; then
			tag="v${version#v}"
		else
			tag="latest"
		fi
	fi
	
	if [ "$tag" = "latest" ]; then
		endpoint=""
	else
		endpoint="tags/${tag}"
	fi
	
	if ! resp=$(gh_req "https://api.github.com/repos/${repo}/releases${endpoint:+/$endpoint}" -); then
		if [ "$tag" != "latest" ] && [[ "$tag" == v* ]]; then
			tag="${tag#v}"
			endpoint="tags/${tag}"
			if ! resp=$(gh_req "https://api.github.com/repos/${repo}/releases/${endpoint}" -); then
				return 1
			fi
		else
			return 1
		fi
	fi

	if [ "$tag" = "latest" ]; then
		local jq_filter=""
		if [ -n "${args[github_release_regex]:-}" ]; then
			jq_filter="[.[] | select((.name // \"\") | test(\"${args[github_release_regex]}\"; \"i\"))]"
		else
			local variant_l="${table,,} ${args[variant]:-} ${args[brand]:-}"
			if [[ "$variant_l" == *"beta"* ]]; then
				jq_filter='[.[] | select((.name // "") | test("(^|[^a-zA-Z])Beta([^a-zA-Z]|$)"; "i"))]'
			elif [[ "$variant_l" == *"nightly"* ]]; then
				jq_filter='[.[] | select((.name // "") | test("(^|[^a-zA-Z])Nightly([^a-zA-Z]|$)"; "i"))]'
			elif [[ "$variant_l" == *"alpha"* ]]; then
				jq_filter='[.[] | select((.name // "") | test("(^|[^a-zA-Z])Alpha([^a-zA-Z]|$)"; "i"))]'
			elif [[ "$variant_l" == *"canary"* ]]; then
				jq_filter='[.[] | select((.name // "") | test("(^|[^a-zA-Z])Canary([^a-zA-Z]|$)"; "i"))]'
			else
				# Stable / default: exclude prereleases and channel-tagged builds if stable releases exist
				jq_filter='[.[] | select((.prerelease == false) and (((.name // "") | test("(^|[^a-zA-Z])(Beta|Nightly|Alpha|Canary|Dev)([^a-zA-Z]|$)"; "i")) | not))]'
			fi
		fi
		if [ -n "$jq_filter" ]; then
			local filtered_resp
			if filtered_resp=$(jq -e "$jq_filter" <<<"$resp" 2>/dev/null) && [ -n "$filtered_resp" ] && [ "$filtered_resp" != "[]" ]; then
				resp="$filtered_resp"
			fi
		fi
		tag=$(jq -r '.[].tag_name' <<<"$resp")
		__GITHUB_RESP__=$(jq -r '.[].assets[]? | select(.name | test("\\.(apk|apkm|xapk|apks)$")) | .name' <<<"$resp")
	else
		__GITHUB_RESP__=$(jq -r '.assets[]? | select(.name | test("\\.(apk|apkm|xapk|apks)$")) | .name' <<<"$resp")
	fi
	
	if [ -z "$__GITHUB_RESP__" ]; then return 1; fi
	
	# Grab the package name exactly like how get_archive_vers isolates the version
	__GITHUB_PKG_NAME__=$(get_github_pkg_name)
	[ -z "$__GITHUB_PKG_NAME__" ] && __GITHUB_PKG_NAME__="${pkg_name:-}"
	if [ -z "$__GITHUB_PKG_NAME__" ]; then return 1; fi
	
	local tag_lines
	tag_lines=$(grep -c . <<<"$tag" || true)
	if [ "$tag_lines" -eq 1 ]; then
		__GITHUB_URL__="https://github.com/${repo}/releases/download/${tag}"
	else
		__GITHUB_URL__="https://github.com/${repo}/releases/download"
	fi
	__GITHUB_TAG__="$tag"
	
	__DL_RESP_CACHE__["github_resp_$cache_key"]="$__GITHUB_RESP__"
	__DL_RESP_CACHE__["github_pkg_$cache_key"]="$__GITHUB_PKG_NAME__"
	__DL_RESP_CACHE__["github_url_$cache_key"]="$__GITHUB_URL__"
	__DL_RESP_CACHE__["github_tag_$cache_key"]="$__GITHUB_TAG__"
}

# Extracts version matching the archive logic: strips prefix (up to first '-') and suffix (arch/extension)
get_github_vers() {
    echo "$__GITHUB_TAG__" | sed 's/^v//'
}

# Extracts package name by stripping everything from the first hyphen '-' onwards
get_github_pkg_name() {
    local p
    p=$(sed 's/-.*//' <<<"$__GITHUB_RESP__" | head -n 1)
    if [ -n "$p" ] && [[ "$p" != *".apk"* ]]; then
        echo "$p"
    elif [ -n "${pkg_name:-}" ]; then
        echo "$pkg_name"
    fi
}

# -------------------- cache_repo --------------------
get_cache_repo_resp() {
	local url="${1}"
	if [ -n "${__DL_RESP_CACHE__["cache_repo_resp_$url"]:-}" ]; then
		__CACHE_REPO_RESP__="${__DL_RESP_CACHE__["cache_repo_resp_$url"]}"
		__CACHE_REPO_PKG_NAME__="${__DL_RESP_CACHE__["cache_repo_pkg_$url"]}"
		__CACHE_REPO_URL__="${__DL_RESP_CACHE__["cache_repo_url_$url"]}"
		__CACHE_REPO_TAG__="${__DL_RESP_CACHE__["cache_repo_tag_$url"]}"
		return 0
	fi
	local repo tag resp endpoint
	__CACHE_REPO_MISS__=false

	repo=$(cut -d/ -f4-5 <<<"$url")
	tag=${url%/}
	tag=${tag##*/}
	endpoint="tags/${tag}"

	# Ask for the status code as well, because "this package has never been uploaded"
	# and "the API call broke" are different news to report: _req runs curl with --fail,
	# so a 4xx/5xx returns nothing but the appended %{http_code}, and a success carries
	# the code as the last three bytes after the body.
	local raw="" call_rc=0 http_code=""
	raw=$(gh_req "https://api.github.com/repos/${repo}/releases/${endpoint}" - -w '%{http_code}') || call_rc=$?
	http_code="${raw: -3}"
	if [[ ! "$http_code" =~ ^[0-9]{3}$ ]]; then http_code=""; fi
	resp="${raw%"$http_code"}"
	if [ -n "$http_code" ] && [ "$http_code" != "200" ]; then
		if [ "$http_code" = "404" ]; then __CACHE_REPO_MISS__=true; fi
		return 1
	fi
	if [ "$call_rc" != 0 ] || [ -z "$resp" ]; then return 1; fi

	# Extract only supported file extensions
	__CACHE_REPO_RESP__=$(jq -r '.assets[]? | select(.name | test("\\.(apk|apkm|xapk|apks)$")) | .name' <<<"$resp")
	if [ -z "$__CACHE_REPO_RESP__" ]; then return 1; fi
	
	# Grab the package name exactly like how get_archive_vers isolates the version
	__CACHE_REPO_PKGNAME__=$(sed 's/-.*//' <<<"$__CACHE_REPO_RESP__" | head -n 1)
	if [ -z "$__CACHE_REPO_PKGNAME__" ]; then return 1; fi
	
	__CACHE_REPO_URL__="https://github.com/${repo}/releases/download/${tag}"
	__CACHE_REPO_TAG__="$tag"
	
	__DL_RESP_CACHE__["cache_repo_resp_$url"]="$__CACHE_REPO_RESP__"
	__DL_RESP_CACHE__["cache_repo_pkg_$url"]="$__CACHE_REPO_PKGNAME__"
	__DL_RESP_CACHE__["cache_repo_url_$url"]="$__CACHE_REPO_URL__"
	__DL_RESP_CACHE__["cache_repo_tag_$url"]="$__CACHE_REPO_TAG__"
}

get_cache_repo_vers() {
    # cache_repo is never used for checking versions, only for downloading
    echo "${__CACHE_REPO_TAG__#v}"
}

get_cache_repo_pkg_name() {
    echo "${__CACHE_REPO_PKGNAME__:-$__CACHE_REPO_PKG_NAME__}"
}

dl_cache_repo() {
    local url=$1 version=$2 output=$3 arch=$4 is_bundle=${5:-false} get_latest_ver=${6:-false} version_code=${7:-}
    local path="" version_f=${version// /}
	local base_url=${__CACHE_REPO_URL__:-$url}
    
    local regex=""
    if [ -n "${args[cache_repo_regex]:-}" ]; then
        if [[ "${args[cache_repo_regex]}" == *":"* ]]; then
            regex=$(echo "${args[cache_repo_regex]}" | awk -F'|' -v a="$arch" '{
                for(i=1;i<=NF;i++) {
                    split($i, kv, ":")
                    gsub(/^[ \t'\''"]+|[ \t'\''"]+$/, "", kv[1])
                    if(kv[1] == a) {
                        gsub(/^[ \t'\''"]+|[ \t'\''"]+$/, "", kv[2])
                        print kv[2]
                        exit
                    }
                }
            }')
        else
            regex="${args[cache_repo_regex]}"
        fi
    fi

    if [ -n "$regex" ]; then
        regex="${regex//\{version\}/${version_f#v}}"
        regex="${regex//\{arch\}/${arch}}"
        path=$(grep -iE "$regex" <<<"$__CACHE_REPO_RESP__" | head -1)
    else
        # Matches the exact file selection logic from dl_archive
        local norm_resp="${__CACHE_REPO_RESP__//$'\r'/}"
        if [ -n "$version_code" ]; then
            for a in "${arch// /}" "all"; do
                for ext in "apk" "apkm" "xapk" "apks" "apk.apkm" "apk.xapk" "apk.apks"; do
                    while IFS= read -r p; do
                        if [[ "$p" == *"${version_f#v}-${version_code}-${a}.${ext}" ]]; then
                            path="$p"
                            break 3
                        fi
                    done <<<"$norm_resp"
                done
            done
        fi
        if [ -z "$path" ]; then
            for a in "${arch// /}" "all"; do
                for ext in "apk" "apkm" "xapk" "apks" "apk.apkm" "apk.xapk" "apk.apks"; do
                    while IFS= read -r p; do
                        if [[ "$p" == *"${version_f#v}-${a}.${ext}" ]]; then
                            path="$p"
                            break 3
                        fi
                    done <<<"$norm_resp"
                done
            done
        fi
    fi
    
    # Strip any \r from path just in case
    path="${path%$'\r'}"
    if [ -z "$path" ]; then
        epr "Version ${version} with arch ${arch} not found in cache_repo"
        return 1
    fi
    
    local ext="${path##*.}"
    case "$ext" in
        apk)
            req "${base_url}/${path}" "$output"
            ;;
        apkm|xapk|apks)
			local bundle="${output%.apk}.${ext}"
			req "${base_url}/${path}" "$bundle" || return 1
			_bundle_to_apk "$bundle" "$output" || { rm -f "$bundle"; return 1; }
			if [ "${MORPHE_PASSTHROUGH_ACTIVE:-false}" != true ]; then
				rm -f "$bundle"
			fi
            ;;
        *)
            epr "Unsupported cache_repo file type for ${path}"
            return 1
            ;;
    esac
}


# -------------------- direct --------------------
# A bare file URL states nothing in its text: what it serves is only knowable from the
# bytes it delivers. So no filename grammar is required of it (it may be a versioned
# file, or a nameless redirect endpoint such as telegram.org/dl/android/apk whose
# target changes whenever the vendor ships), and the package name, version and
# versionCode are read off the artifact itself, exactly as the store sources read them
# off their pages. `get_direct_resp` performs that read - one fetch, at source
# selection - and the three getters below only report what it proved. Doing the fetch
# in the response hook is also what makes a dead or wrong URL a per-source miss (the
# caller drops this source and tries the next) rather than a failed build.
# The fetched blob goes into the learned download-link index, so every architecture
# adopts the same bytes instead of paying one transfer per arch.
get_direct_resp() { # $1=url
	local url=$1
	if [ "$url" = "${__DIRECT_URL__:-}" ] && [ -n "${__DIRECT_VERS__:-}" ]; then
		return 0
	fi
	local probe="${TEMP_DIR}/apks_dl/direct-$(_dlurl_sha "$url").apk"
	mkdir -p "${TEMP_DIR}/apks_dl" 2>/dev/null || return 1
	if ! req_artifact "$url" "$probe"; then
		epr "ERROR: Could not download the direct URL '$url'"
		rm -f "$probe"
		return 1
	fi
	if ! unzip -l "$probe" >/dev/null 2>&1; then
		epr "ERROR: The direct URL '$url' serves something that is not an APK or bundle (not a zip archive)"
		rm -f "$probe"
		return 1
	fi
	local p v vc
	p=$(_meta_field_of "$probe" package) || true
	v=$(_meta_field_of "$probe" versionName) || true
	vc=$(_meta_field_of "$probe" versionCode) || true
	if [ -z "$p" ] || [ -z "$v" ]; then
		epr "ERROR: No package or version readable from the file at '$url' (aapt read '${p:-none}' / '${v:-none}'); it is not a usable APK"
		rm -f "$probe"
		return 1
	fi
	if [ -n "${pkg_name:-}" ] && [ "$p" != "$pkg_name" ]; then
		wpr "The direct URL '$url' serves '$p', not the configured pkg-name '$pkg_name'; dropping it as a source"
		rm -f "$probe"
		return 1
	fi
	_dlurl_index_record "$url" "$probe"
	rm -f "$probe"
	__DIRECT_URL__="$url"
	__DIRECT_PKG_NAME__="$p"
	__DIRECT_VERS__="$v"
	pr "Direct URL '$url' serves '$p' v$v (versionCode ${vc:-unreadable})"
	return 0
}

dl_direct() {
	local url=$1 output=$3 arch=$4
	local _idx=""
	_idx=$(_dlurl_index_lookup "$url" "$arch") || true
	if [ "$_idx" = REJECT ]; then
		wpr "The direct link '$url' is known to serve a different ABI than '$arch'; skipping source without re-download"
		return 1
	fi
	if [ -n "$_idx" ]; then
		cp -f "$_idx" "$output" || return 1
		pr "Adopting the already-fetched direct download for '$url' (no re-download)"
		return 0
	fi
	req_artifact "$url" "$output" || return 1
	_dlurl_index_record "$url" "$output"
}
# Reported only through get_direct_resp, which read them off the artifact; nothing here
# parses the URL any more.
get_direct_vers() {
	[ -n "${__DIRECT_VERS__:-}" ] || return 1
	printf '%s\n' "$__DIRECT_VERS__"
}
get_direct_pkg_name() {
	[ -n "${__DIRECT_PKG_NAME__:-}" ] || return 1
	printf '%s\n' "$__DIRECT_PKG_NAME__"
}
# --------------------------------------------------

patch_apk() {
	local stock_input=$1 patched_apk=$2 patcher_args=$3 cli_jar=$4 patches_jar=$5 cli_source=$6
	local per_bundle_ed="${7:-}"
	local tmp_dir="${CWD}/${patched_apk}-temporary-files"
	local IFS=$'\n'
	local p_jars=($(echo "$patches_jar" | tr ' ' '\n' | grep -v '^$'))
	unset IFS

	local cli_source_l="${cli_source,,}"
	resolve_patcher "$cli_source"
	if [ "$PATCHER_FLOW" = xposed-module ]; then
		local p_args_modules=""
		for j in "${p_jars[@]}"; do
			p_args_modules+=" -m '$j'"
		done
		# Both tools sign the output themselves, so the identity has to reach them as
		# arguments: -k <path> <storePass> <alias> <aliasPass>, same order in LSPatch
		# (KeystoreSpec.of) and NPatch. Which store each can read is a per-tool fact -
		# NPatch asks JCA for a BKS type, LSPatch for the JDK default (PKCS12) - so the
		# registry names it. Placed before $patcher_args so a config can still override.
		local ks_args="" ks_file="$RVB_KEYSTORE_P12"
		if [ "${PATCHER_SIGNING:-false}" = true ]; then
			if [ "${PATCHER_KEYSTORE_FORMAT:-pkcs12}" = bks ]; then
				ks_file="$RVB_KEYSTORE"
			fi
			if [ -z "$ks_file" ] || [ ! -f "$ks_file" ]; then
				epr "No signing keystore for '$cli_source' (want a $PATCHER_KEYSTORE_FORMAT store; have RVB_KEYSTORE='$RVB_KEYSTORE' RVB_KEYSTORE_P12='$RVB_KEYSTORE_P12')"
				return 1
			fi
			ks_args=" -k '$ks_file' '$RVB_KEYSTORE_PASS' '$RVB_KEY_ALIAS' '$RVB_KEYSTORE_PASS'"
		fi
		mkdir -p "$tmp_dir"
		local cmd="java -jar '$cli_jar' -o '$tmp_dir'$p_args_modules$ks_args $patcher_args '$stock_input'"
		pr "$cmd"
		PATCH_OUTPUT=$(eval "$cmd" 2>&1)
		local ret=$?
		echo "$PATCH_OUTPUT"
		if [ $ret -eq 0 ]; then
			local npatch_out
			npatch_out=$(find "$tmp_dir" -type f -name "*.apk" | head -n 1)
			if [ -n "$npatch_out" ] && [ -f "$npatch_out" ]; then
				mv "$npatch_out" "$patched_apk"
				rm -rf "$tmp_dir"
				return 0
			fi
		fi
		rm "$patched_apk" 2>/dev/null || :
		rm -rf "$tmp_dir"
		return 1
	fi

	if [ "$PATCHER_FLOW" = instafel-workflow ]; then
		local rel_tmp_dir="${patched_apk}-temporary-files"
		mkdir -p "$rel_tmp_dir"
		# Private copy of the patcher's per-user data dir (core_data/info.json):
		# sibling builds sharing $HOME race on creating it. Lives under
		# rel_tmp_dir, so it is cleaned up with the rest of the run's temp files.
		local ifl_xdg="$rel_tmp_dir/xdg-data"
		mkdir -p "$ifl_xdg"
		_instafel_shadow_core "$cli_jar" "$patches_jar" "$rel_tmp_dir"

		local expected_base
		expected_base=$(basename "$stock_input" .apk)
		[ -n "$expected_base" ] && [ -d "$expected_base" ] && rm -rf "$expected_base" 2>/dev/null || :

		local init_cmd="XDG_DATA_HOME='$ifl_xdg' java -jar '$cli_jar' init '$stock_input'"
		pr "$init_cmd"
		local init_op
		init_op=$(eval "$init_cmd" 2>&1)
		pr "$init_op"

		local wdir=""
		if [ -n "$expected_base" ] && [ -d "$expected_base" ] && [ -f "$expected_base/project.json" ]; then
			wdir="$expected_base"
		elif [ -n "$expected_base" ] && [ -d "$rel_tmp_dir/$expected_base" ] && [ -f "$rel_tmp_dir/$expected_base/project.json" ]; then
			wdir="$rel_tmp_dir/$expected_base"
		else
			local proj_file
			proj_file=$(find "$rel_tmp_dir" . -maxdepth 3 -type f -name "project.json" 2>/dev/null | grep "$expected_base" | head -n 1)
			[ -z "$proj_file" ] && proj_file=$(find "$rel_tmp_dir" . -maxdepth 3 -type f -name "project.json" 2>/dev/null | head -n 1)
			if [ -n "$proj_file" ]; then
				wdir=$(dirname "$proj_file")
				wdir="${wdir#./}"
			fi
		fi

		if [ -z "$wdir" ] || [ ! -d "$wdir" ]; then
			epr "Instafel init failed to create project working directory for '$stock_input'."
			rm -rf "$rel_tmp_dir" 2>/dev/null || :
			return 1
		fi

		local patches_to_run=""
		if [ -n "$per_bundle_ed" ]; then
			patches_to_run=$(_ed_names "$per_bundle_ed" | paste -sd " " -)
		fi
		if [ -z "$patches_to_run" ]; then
			patches_to_run="$RVB_INSTAFEL_DEFAULT_PATCHES"
		fi

		local run_cmd="XDG_DATA_HOME='$ifl_xdg' java -jar '$cli_jar' run '$wdir' $patches_to_run"
		pr "$run_cmd"
		PATCH_OUTPUT=$(eval "$run_cmd" 2>&1)
		echo "$PATCH_OUTPUT"

		local build_cmd="XDG_DATA_HOME='$ifl_xdg' java -jar '$cli_jar' build '$wdir'"
		pr "$build_cmd"
		local build_op
		build_op=$(eval "$build_cmd" 2>&1)
		echo "$build_op"
		PATCH_OUTPUT+=$'\n'"$build_op"

		local built_apk=""
		if echo "$patches_to_run" | grep -qwi "clone"; then
			built_apk=$(find "$wdir/build" "$wdir" "$rel_tmp_dir" -maxdepth 5 -type f -name "*.apk" 2>/dev/null | grep -v "$stock_input" | grep -iE "/clone|_c_" | head -n 1)
			if [ -z "$built_apk" ]; then
				echo "[-] ERROR: Clone build was requested but no clone APK was generated!"
				rm -rf "$rel_tmp_dir" "$wdir" 2>/dev/null || :
				return 1
			fi
		else
			built_apk=$(find "$wdir/build" "$wdir" "$rel_tmp_dir" -maxdepth 5 -type f -name "*.apk" 2>/dev/null | grep -v "$stock_input" | head -n 1)
		fi
		if [ -n "$built_apk" ] && [ -f "$built_apk" ]; then
			mv "$built_apk" "$patched_apk"
			rm -rf "$rel_tmp_dir" "$wdir" 2>/dev/null || :
			return 0
		else
			rm -f "$patched_apk" 2>/dev/null || :
			rm -rf "$rel_tmp_dir" "$wdir" 2>/dev/null || :
			return 1
		fi
	fi

	# Morphe keeps a writable data root *next to its JAR* (morphe-data/). With
	# parallel builds, siblings sharing the cached JAR would share — and purge —
	# that directory, so each patch run executes from a private JAR copy in its
	# own stage dir, removed right after patching. The cached JAR stays read-only.
	local stage_jar="$cli_jar" stage_dir=""
	if [ "${PATCHER_KIND:-}" = morphe ]; then
		local sbase
		sbase=$(basename "$cli_jar")
		stage_dir="${TEMP_DIR}/morphe-stage-$(basename "$patched_apk" .apk)-$$"
		if mkdir -p "$stage_dir" && cp -f "$cli_jar" "${stage_dir}/${sbase}"; then
			stage_jar="${stage_dir}/${sbase}"
		else
			wpr "Could not stage a private morphe JAR copy; using the shared one"
			stage_dir=""
		fi
	fi

	local base_cmd="java -jar '$stage_jar' patch '$stock_input' -t '$tmp_dir' -o '$patched_apk' --keystore=$RVB_KEYSTORE \
--keystore-entry-password=$RVB_KEYSTORE_PASS --keystore-password=$RVB_KEYSTORE_PASS --signer=$RVB_KEY_ALIAS --keystore-entry-alias=$RVB_KEY_ALIAS"

	# Morphe writes a machine-readable summary of the run (-r): which patches applied,
	# which failed, and per-step success. Other tools have no equivalent, so the
	# stdout scrape in write_build_info stays the fallback. The path is deliberately
	# under TEMP_DIR and never apk_cache_dir - build.yml lists that directory into the
	# APK cache manifest, so a stray .json there would be published as a cache asset.
	PATCH_RESULT_FILE=""
	if [ "${PATCHER_KIND:-}" = morphe ]; then
		if mkdir -p "${TEMP_DIR}/patch_results" 2>/dev/null; then
			PATCH_RESULT_FILE="${TEMP_DIR}/patch_results/$(basename "$patched_apk" .apk).json"
			rm -f "$PATCH_RESULT_FILE" 2>/dev/null || :
			base_cmd+=" -r '$PATCH_RESULT_FILE'"
		else
			wpr "Could not create the patch-result directory; falling back to parsing CLI output"
		fi
	fi

	local -a ed_parts=()
	if [ -n "$per_bundle_ed" ]; then
		local IFS='|'
		read -ra ed_parts <<< "$per_bundle_ed"
		unset IFS
	fi

	local p_args_long="" p_args_short=""
	if [ "$PATCHER_BUNDLE_ED_PER_BUNDLE" = true ]; then
		for ((i=0; i<${#p_jars[@]}; i++)); do
			local j="${p_jars[$i]}"
			local ed="${ed_parts[$i]:-}"
			p_args_long+=" --patches '$j'${ed}"
			p_args_short+=" -p '$j'${ed}"
		done
		local cmd_long="${base_cmd}${p_args_long} $patcher_args"
		local cmd_short="${base_cmd}${p_args_short} $patcher_args"
	else
		for j in "${p_jars[@]}"; do
			p_args_long+=" --patches '$j'"
			p_args_short+=" -p '$j'"
		done
		local all_ed="${ed_parts[*]}"
		local cmd_long="${base_cmd}${p_args_long} ${all_ed} $patcher_args"
		local cmd_short="${base_cmd}${p_args_short} ${all_ed} $patcher_args"
	fi

	# TODO: remove this later — revanced-cli needs -b to bypass build provenance checks
	local cli_name=$(basename "$cli_jar")
	if [ "${cli_name::8}" = revanced ]; then
		cmd_long+=" -b"
		cmd_short+=" -b"
	fi

	if [ "$OS" = Android ]; then
		cmd_long+=" --custom-aapt2-binary='${AAPT2}'"
		cmd_short+=" --custom-aapt2-binary='${AAPT2}'"
	fi

	pr "$cmd_long"
	PATCH_OUTPUT=$(eval "$cmd_long" 2>&1)
	local ret=$?

	if [ $ret -ne 0 ] && echo "$PATCH_OUTPUT" | grep -Eq "Unknown option: '--patches'|Unmatched argument|Missing required argument"; then
		pr "Fallback to short syntax (-p)..."
		rm -rf "$tmp_dir" 2>/dev/null
		pr "$cmd_short"
		PATCH_OUTPUT=$(eval "$cmd_short" 2>&1)
		ret=$?
	fi

	if [ -n "$stage_dir" ]; then rm -rf "$stage_dir"; fi

	echo "$PATCH_OUTPUT"
	if [ $ret -eq 0 ] && [ -f "$patched_apk" ]; then
		return 0
	else
		rm "$patched_apk" 2>/dev/null || :
		return 1
	fi
}


check_sig() {
	local file=$1 pkg_name=$2
	local sig
	if grep -q "$pkg_name" sig.txt; then
		sig=$(java -jar "$APKSIGNER" verify --print-certs "$file" | grep ^Signer | grep SHA-256 | tail -1 | awk '{print $NF}')
		echo "$pkg_name signature: ${sig}"
		grep -qFx "$sig $pkg_name" sig.txt
	fi
}

resolve_slug() {
	local val="${1:-}"
	[ -z "$val" ] && return 0
	local slug
	slug=$(echo "$val" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g' | sed -E 's/^-+|-+$//g')
	echo "$slug"
}

write_build_info() {
	local key=$1 arch=$2 ext=$3 name=$4 version=$5 patches=$6 changelog=$7
	local pkg_name=${8:-${pkg_name:-}}
	local display_name=${9:-${app_name:-${key}}}
	local patches_source=${10:-${args[patches_src]:-}}
	local brand=${11:-${args[brand]:-}}
	local variant=${12:-${args[variant]:-}}
	local sub_variant=${13:-${args[sub_variant]:-}}
	# Raw filename arch token (e.g. arm64-v8a) and raw file-type suffix (apk/zip) —
	# captured before `arch` is folded into `ext` below. The merge keys its
	# per-arch version map by the token and its per-arch applied-patch map by
	# "token/kind", matching what build_make_manifest.py re-derives from the built
	# filename. The kind is required because build-mode "both" writes two
	# fragments for one arch whose applied sets legitimately differ (module mode
	# disables the microG/GmsCore patches); a token-only key lets one overwrite
	# the other in the merge.
	local arch_token="$arch"
	local file_kind="${ext#.}"
	local arch_orig="${args[arch]// /}"
	if [ "$arch_orig" != "auto" ]; then ext="${arch}${ext}"; arch=""; fi
	# Applied patches: morphe's -r summary when we have one (it lists every patch
	# actually applied, defaults included, verified against morphe-desktop 1.15.1),
	# otherwise scrape the CLI output.
	#   revanced: INFO: "Patch Name" succeeded
	#   morphe:   INFO: Applied: Patch Name
	#   instafel: I: Patch 'Patch Name' loaded
	local applied_json=""
	if [ -n "${PATCH_RESULT_FILE:-}" ]; then
		applied_json=$(_applied_from_result "$PATCH_RESULT_FILE")
		if [ -n "$applied_json" ] && [ "$applied_json" != "[]" ]; then
			local failed_list
			failed_list=$(_failed_from_result "$PATCH_RESULT_FILE")
			[ -n "$failed_list" ] && wpr "Morphe reported failed patches for '$key': $failed_list"
		elif [ -n "$applied_json" ]; then
			# An empty list from a tool that writes a summary is a real signal, not a
			# parse miss - but it is also what a schema change would look like, so say
			# which source produced it before anyone reads the empty catalog field as
			# "this app has no patches".
			wpr "Morphe result file for '$key' lists no applied patches (schema change?)"
			applied_json=""
		fi
	fi
	if [ -z "$applied_json" ]; then
		applied_json=$(printf '%s\n' "$PATCH_OUTPUT" | grep -oP '(?<=INFO: ")[^"\n]+(?=" succeeded)|(?<=INFO: Applied: ).*|(?<=I: Patch \x27)[^\x27]+(?=\x27 loaded)' | jq -R -s -c 'split("\n") | map(select(length > 0))' 2>/dev/null || true)
	fi
	[[ "$applied_json" != \[* ]] && applied_json='[]'

	# A name the config explicitly asked for that the run did not report applying means
	# the catalog would advertise a patch that is not in the APK: usually the author
	# renaming or dropping it, sometimes a version the patch no longer supports. Warn
	# only - tools without a result file scrape less reliably, and an inclusive
	# expansion lists every name the bundle offered, so "not applied" there can also
	# mean "applied but unreported".
	if [ "$applied_json" != "[]" ] && [ -n "${args[included_patches]:-}" ]; then
		local inc_name missing_inc=""
		while IFS= read -r inc_name; do
			inc_name="${inc_name#\'}"; inc_name="${inc_name%\'}"
			inc_name="${inc_name#\"}"; inc_name="${inc_name%\"}"
			[ -z "$inc_name" ] && continue
			printf '%s' "$applied_json" | jq -e --arg n "$inc_name" 'index($n) != null' >/dev/null 2>&1 \
				|| missing_inc+=" '$inc_name'"
		done <<<"$(list_args "${args[included_patches]//|/ }")"
		[ -n "$missing_inc" ] && wpr "Requested but not reported as applied for '$key':$missing_inc"
	fi

	# Warn (don't fail) when a tool that reports applied patches yields none —
	# previously this degraded silently into an empty catalog field. xposed
	# modules and instafel are excluded: xposed reports none by design, and
	# instafel prints its names before the -o build step whose captured
	# PATCH_OUTPUT we parse here (its run/build split makes the empty case
	# legitimately common).
	if [ "$applied_json" = "[]" ] && [ -n "$PATCH_OUTPUT" ] && [ "${PATCHER_FLOW:-}" = cli-patch ]; then
		wpr "No applied patches parsed from ${PATCHER_KIND:-cli-patch} CLI output for '$key' — catalog may show an empty patch list."
	fi
	# One fragment per write (key+arch+ext suffixed, pid-guarded): concurrent
	# build processes never touch the same file; merge_build_info folds them
	# into $BUILD_JSON_FILE at the end of the run.
	local frag_dir="${TEMP_DIR}/build_info" fid
	mkdir -p "$frag_dir"
	fid=$(tr -cs 'a-zA-Z0-9._-' '-' <<<"${key}|${arch}|${ext}")
	fid="${fid%%-}"; fid="${fid##-}"
	jq -n --arg key "$key" \
		--arg ext "$ext" \
		--arg arch "$arch" \
		--arg arch_token "$arch_token" \
		--arg file_kind "$file_kind" \
		--arg name "$name" \
		--arg version "$version" \
		--arg patches "$patches" \
		--arg changelog "$changelog" \
		--arg pkg_name "$pkg_name" \
		--arg display_name "$display_name" \
		--arg patches_source "$patches_source" \
		--arg brand "$brand" \
		--arg variant "$variant" \
		--arg sub_variant "$sub_variant" \
		--argjson applied "$applied_json" \
		'{ ($key): {
			exts: [$ext],
			name: $name,
			arch: $arch,
			arch_token: $arch_token,
			file_kind: $file_kind,
			version: $version,
			patches: $patches,
			changelog: $changelog,
			package_name: $pkg_name,
			display_name: $display_name,
			patches_source: $patches_source,
			brand: $brand,
			variant: $variant,
			sub_variant: $sub_variant,
			applied_patches: $applied
		} }' >"${frag_dir}/${fid}.$$.json"
}

# -- Duplicate-build detection (temp/hashes, temp/unchanged, state JSON) -----
# Rebuilding an app whose patch inputs did not really change (a patch source
# touching only shared/ — see issue #165) produces a logically identical APK,
# and republishing it under a new build number falsely notifies updaters.
# build_rv asks check_duplicate_build right after patch_apk: a verdict of
# "unchanged" ends the table build before module packaging, and nothing is
# copied to $BUILD_DIR, so no release record, note or manifest entry exists
# for a duplicate. The reference store is state/build_content_hashes.json
# on the data branch (fetch_data_branch.sh materialises it, the CI merge
# step and commit_data_branch.sh publish it after a successful upload) —
# deliberately NOT build.json or the website manifest: the hash is dedup
# bookkeeping, not published metadata. The engine itself makes no network
# calls for any of this, same stance as temp/failures.

# Content fingerprint of an APK (md5 over the zip central directory, signing
# and timestamps excluded — see .github/scripts/content_hash.py). Prints the
# digest; empty rc=1 means "no verdict" (no python, unreadable archive).
content_hash() { # $1=apk
	local py=""
	if command -v python3 >/dev/null 2>&1; then
		py="python3"
	elif command -v python >/dev/null 2>&1; then
		py="python"
	fi
	[ -n "$py" ] || { printf ''; return 1; }
	"$py" "${CWD}/.github/scripts/content_hash.py" "$1" 2>/dev/null || printf ''
}

# Published fingerprint for one dedup key, "" when the state file or the key
# is absent (first build of that app+arch ever → publish, never guess). The value
# is either a bare md5 — written before artifact kinds were tracked — or
# {hash, kinds}; both are read here so a half-migrated state file is never misread.
_dedup_recorded_hash() { # $1=channel $2=key
	local sf="state/build_content_hashes.json"
	[ -f "$sf" ] || return 0
	jq -r --arg chan "$1" --arg key "$2" '
		(.[$chan][$key] // "")
		| if type == "object" then (.hash // "") else . end' "$sf" 2> /dev/null || true
}

# Kinds recorded as live for one dedup key, space-separated; empty when nothing is
# on the record. An entry written before kind tracking says nothing about kinds, and
# an unknown kind can NEVER justify withholding a release. That is the opposite
# polarity to built_shape's baseline rule, deliberately: a duplicate skip is
# destructive and terminal (the missing artifact would never be asked for again),
# while one extra publish is merely noise.
_dedup_recorded_kinds() { # $1=channel $2=key
	local sf="state/build_content_hashes.json"
	[ -f "$sf" ] || return 0
	jq -r --arg chan "$1" --arg key "$2" '
		(.[$chan][$key] // {})
		| if type == "object" then ((.kinds // []) | join(" ")) else "" end' \
		"$sf" 2> /dev/null | tr -s '[:space:]' ' ' || true
}

# _dedup_kinds_covered <requested kinds> <recorded kinds> — success when every
# requested kind appears in the record. An empty record covers nothing.
_dedup_kinds_covered() { # $1=want $2=have
	local want=${1:-} k
	local have=" $(printf '%s' "${2:-}" | tr -s '[:space:]' ' ') "
	[ -n "$want" ] || return 1
	for k in $want; do
		case "$have" in
		*" $k "*) ;;
		*) return 1 ;;
		esac
	done
	return 0
}

# Record a freshly built fingerprint for the CI merge step (tab-separated
# channel/key/hash lines). Each process appends to its own file —
# RVB_HASH_APPEND is pid-named by build.sh, so parallel children never share
# an fd and no lock is needed; lines are short enough to stay atomic.
_dedup_record_hash() { # $1=channel $2=key $3=hash
	[ -n "${RVB_HASH_APPEND:-}" ] || return 0
	printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$RVB_HASH_APPEND" 2>/dev/null || true
}

# Merge this build's hashes into the local state JSON. Only the ENFORCE mode
# calls this: the local file doubles as the reference for later arch jobs in
# the same run, and mutating it while merely measuring (log mode) would let
# the observation period pollute its own baseline. The published copy on the
# data branch still comes only from a successful-upload run (CI merge step),
# and that step — not this one — decides which kinds are credited, from the
# filenames that actually shipped; the kinds written here are this build's
# request, provisional within the run, so a sibling arch asking the same question
# gets the same answer.
_dedup_store_hash() { # $1=channel $2=key $3=hash $4=kinds
	local sf="state/build_content_hashes.json" tmp kinds_json
	mkdir -p "${sf%/*}" 2> /dev/null || return 0
	[ -f "$sf" ] || echo '{}' >"$sf"
	tmp="${sf}.tmp.$$"
	if [ -z "${4:-}" ]; then
		kinds_json='[]'
	else
		# shellcheck disable=SC2086
		kinds_json=$(printf '%s\n' $4 | jq -R . | jq -sc . 2> /dev/null || printf '[]')
	fi
	if jq --arg chan "$1" --arg key "$2" --arg hash "$3" --argjson kinds "$kinds_json" \
		'.[$chan][$key] = {hash: $hash, kinds: $kinds}' "$sf" >"$tmp" 2> /dev/null; then
		mv -f "$tmp" "$sf"
	else
		rm -f "$tmp"
	fi
}

# Append the unchanged record the parent build.sh and the CI steps read
# (temp/unchanged/<slug>.json, upserted so both arches of one app agree).
_dedup_write_unchanged() { # $1=label $2=app $3=version $4=arch $5=key $6=hash
	local dir="${RVB_UNCHANGED_DIR:-${TEMP_DIR}/unchanged}" slug
	mkdir -p "$dir" 2>/dev/null || return 0
	slug=$(failure_slug "$1")
	local f="$dir/$slug.json" tmp
	[ -f "$f" ] || echo '{}' >"$f"
	tmp="${f}.tmp.$$"
	if jq --arg type "unchanged" --arg app "$2" --arg version "$3" --arg arch "$4" \
		--arg key "$5" --arg hash "$6" \
		'. + {type:$type, app:$app, version:$version, arch:$arch, key:$key, hash:$hash}' \
		"$f" >"$tmp" 2>/dev/null; then
		mv -f "$tmp" "$f"
	else
		rm -f "$tmp"
	fi
}

# Verdict for one finished patched APK. rc 0 = identical to published AND every
# requested artifact kind already lives (caller skips the rest of the table build),
# rc 1 = changed / kind missing / no verdict (publish). Never touches the failure
# records: a duplicate is a skip, like the download-exhaustion precedent, not
# something to report.
check_duplicate_build() { # $1=apk $2=stem $3=label $4=app $5=version $6=arch $7=kinds
	# off / local builds / a tool the registry deems hash-unstable: no check.
	# A hash that wobbles across rebuilds of unchanged input would only ever
	# say "changed" (dead weight), so eligibility is measured per tool before
	# granting it the power to suppress a release.
	[ "${RVB_DEDUP_MODE:-log}" != "off" ] || return 1
	[ -n "${GITHUB_REPOSITORY:-}" ] || return 1
	[ "${PATCHER_HASH_DEDUP_ELIGIBLE:-false}" = true ] || return 1
	local chan="${10:-${args[dup_channel]:-}}" key="$2" hash rec
	case "$chan" in stable | beta) ;; *) return 1 ;; esac
	hash=$(content_hash "$1")
	if [ -z "$hash" ]; then
		wpr "No content hash for '$key' (python3 unavailable or unreadable APK) — publishing."
		return 1
	fi
	rec=$(_dedup_recorded_hash "$chan" "$key")
	if [ -n "$rec" ] && [ "$rec" = "$hash" ]; then
		# Same bytes is only half the question. An app whose config moved `apk -> both`
		# re-produces an identical APK forever, so a hash-only skip would suppress the
		# very artifact the maintainer asked for and then record it as built.
		if _dedup_kinds_covered "${7:-}" "$(_dedup_recorded_kinds "$chan" "$key")"; then
			if [ "${RVB_DEDUP_MODE:-log}" = enforce ]; then
				pr "Unchanged build: '$key' matches published content hash and every requested kind is live — skipping release."
				_dedup_write_unchanged "$3" "$4" "$5" "$6" "$key" "$hash"
				return 0
			fi
			# Measurement phase: report what WOULD be skipped, keep publishing,
			# and do not append — the reference set must stay exactly the
			# published one while the numbers are being watched.
			pr "Dedup [log]: '$key' identical to published hash ${rec} (would skip)."
			return 1
		fi
		wpr "'$key' matches the published content hash, but the requested kinds '${7:-none}' are not all on the record — releasing, so a missing artifact can appear."
	fi
	if [ "${RVB_DEDUP_MODE:-log}" = enforce ]; then
		_dedup_store_hash "$chan" "$key" "$hash" "${7:-}"
	fi
	_dedup_record_hash "$chan" "$key" "$hash"
	return 1
}

# Recombine the per-write fragments from $TEMP_DIR/build_info into
# $BUILD_JSON_FILE. Called once by build.sh after all builds (serial or
# pooled) finish; fragment filenames sort in creation order, so the first
# fragment for a key provides the entry and later ones only union exts and
# fill empty scalars — mirroring the old sequential update semantics.
merge_build_info() {
	local frag_dir="${TEMP_DIR}/build_info"
	[ -d "$frag_dir" ] || return 0
	local files=()
	mapfile -t files < <(find "$frag_dir" -maxdepth 1 -type f -name '*.json' | sort)
	if [ ${#files[@]} -eq 0 ]; then
		rm -rf "$frag_dir"
		return 0
	fi
	jq -s '
		reduce .[] as $f ({};
			($f | to_entries[0]) as $e |
			(if .[$e.key] == null then .[$e.key] = $e.value
			else
				.[$e.key].exts = ((.[$e.key].exts + $e.value.exts) | unique) |
				reduce (["name","arch","version","patches","changelog","package_name","display_name","patches_source","brand","variant","sub_variant"][]) as $k (.;
					if ((.[$e.key][$k] // "") == "") and (($e.value[$k] // "") != "")
					then .[$e.key][$k] = $e.value[$k] else . end) |
				if ((.[$e.key].applied_patches | length) == 0) and (($e.value.applied_patches | length) > 0)
				then .[$e.key].applied_patches = $e.value.applied_patches else . end
			end)
			# Per-arch truth (additive): a single build can resolve different
			# versions/patch-sets per arch (an arch falling back to an older build),
			# which the first-wins scalars above lose. Key the concrete arch token to
			# the version of this fragment, and key applied patches by "arch/kind"
			# (apk vs module zip) — under build-mode "both" one arch yields both
			# artifacts and their sets legitimately differ (module mode disables the
			# microG/GmsCore patches), so a token-only key would let whichever
			# fragment sorts last erase the entries of the other one. The scalar
			# version/applied_patches stay unchanged for backward compatibility.
			| .[$e.key].archVersion = ((.[$e.key].archVersion // {}) + {($e.value.arch_token // "all"): ($e.value.version // "")})
			| .[$e.key].archApplied  = ((.[$e.key].archApplied // {}) + {"\(($e.value.arch_token // "all"))/\($e.value.file_kind // "apk")": ($e.value.applied_patches // [])})
		)
	' "${files[@]}" >"${BUILD_JSON_FILE}.merge-tmp" && mv -f "${BUILD_JSON_FILE}.merge-tmp" "$BUILD_JSON_FILE"
	rm -rf "$frag_dir"
}
verify_downloaded_apk() {
	local stock_apk=$1
	local pkg_name=$2
	local dl_p=$3
	local sig_op

	if _bundle_ext_of "$stock_apk" >/dev/null 2>&1; then
		# bundle stock: signature lives on base.apk
		local tmpb="${TEMP_DIR}/verify_base_$$.apk"
		if ! _bundle_extract_base "$stock_apk" "$tmpb"; then
			epr "Cannot extract base.apk from bundle $stock_apk"
			rm -f "$tmpb"
			return 1
		fi
		if ! sig_op=$(check_sig "$tmpb" "$pkg_name" 2>&1); then
			epr "Signature mismatch on base.apk of $stock_apk: $sig_op. Rejecting download from $dl_p..."
			rm -f "$tmpb"
			return 1
		fi
		rm -f "$tmpb"
		return 0
	fi
	
	if [ -f "${stock_apk%.apk}.apkm" ]; then
		rm -rf "${stock_apk}-zip" || :
		unzip -j "${stock_apk%.apk}.apkm" -d "${stock_apk}-zip" >/dev/null
		if [ -f "${stock_apk}-zip/base.apk" ]; then
			if ! sig_op=$(check_sig "${stock_apk}-zip/base.apk" "$pkg_name" 2>&1); then
				epr "Signature mismatch on base.apk: $sig_op. Rejecting download from $dl_p..."
				rm -rf "${stock_apk}-zip" || :
				return 1
			fi
		else
			for a in "${stock_apk}"-zip/*.apk; do
				if ! sig_op=$(check_sig "$a" "$pkg_name" 2>&1); then
					epr "Signature mismatch on $a: $sig_op. Rejecting download from $dl_p..."
					rm -rf "${stock_apk}-zip" || :
					return 1
				fi
				break
			done
		fi
		rm -rf "${stock_apk}-zip" || :
	else
		if ! sig_op=$(check_sig "$stock_apk" "$pkg_name" 2>&1); then
			epr "Signature mismatch on $stock_apk: $sig_op. Rejecting download from $dl_p..."
			return 1
		fi
	fi
	return 0
}

# Classify the entries of one zip archive into build-arch tokens, one per line, empty
# when it holds no ABI-specific content. Fails when the file cannot be listed at all.
_abis_of_listing() { # $1=apk or bundle
	local names
	# The status of unzip itself has to be checked: piping it into awk makes the
	# pipeline succeed on empty input, which would read a corrupt or truncated download
	# as "no ABI content" and therefore "universal" - caching junk under the key every
	# arch is allowed to adopt.
	names=$(unzip -l "$1" 2>/dev/null) || return 1
	printf '%s\n' "$names" | awk 'NF >= 4 { p = $4; for (i = 5; i <= NF; i++) p = p " " $i; print p }' | {
		while IFS= read -r n; do
			case "$n" in
				lib/arm64-v8a/*) echo arm64-v8a ;;
				lib/armeabi-v7a/*) echo arm-v7a ;;
				lib/x86_64/*) echo x86_64 ;;
				lib/x86/*) echo x86 ;;
				*config.arm64_v8a.apk) echo arm64-v8a ;;
				*config.armeabi_v7a.apk | *config.armeabi-v7a.apk | *config.armeabi.apk) echo arm-v7a ;;
				*config.x86_64.apk) echo x86_64 ;;
				*config.x86.apk) echo x86 ;;
			esac
		done
		# LC_ALL=C: plain sort collates '-' before digits differently per locale, which
		# would make this output (and so the key derived from it) machine-dependent.
	} | LC_ALL=C sort -u | grep . || :
}

# Which ABIs an artifact actually carries, read off its contents.
#
# Prints one build-arch token per line (arm64-v8a, arm-v7a, x86_64, x86), nothing when
# the artifact has no ABI-specific content, and fails when the file is not a zip.
# Three shapes have to be understood:
#   merged apk               -> native libraries at lib/<abi>/
#   bundle (xapk/apkm/apks)  -> nested config.<abi>.apk splits. A listing of one has no
#                          "lib/" entry at all, so grepping for lib/ concludes "nothing
#                          arch specific here" about a file whose entire purpose is being
#                          arch specific - which is how every XAPK came to be called
#                          universal and cached under the shared -all key.
#   bundle with no ABI split -> Microsoft Office ships its native code inside base.apk and
#                          splits only languages and densities, so the container names no
#                          ABI anywhere. base.apk has to be asked: an empty container
#                          listing is not evidence of an arch-agnostic file, and "all" is
#                          the one key every arch build may adopt - which is how an
#                          arm64-only Word bundle came to be stored as ...-all.apkm.
_artifact_abis() { # $1=apk or bundle
	local abis
	abis=$(_abis_of_listing "$1") || return 1
	if [ -z "$abis" ] && _bundle_ext_of "$1" >/dev/null 2>&1; then
		local base
		base=$(mktemp "${TEMP_DIR:-.}/artifact_abis_XXXXXX.apk") || return 1
		if ! _bundle_extract_base "$1" "$base"; then
			rm -f "$base"
			return 1
		fi
		abis=$(_abis_of_listing "$base") || { rm -f "$base"; return 1; }
		rm -f "$base"
	fi
	if [ -n "$abis" ]; then printf '%s\n' "$abis"; fi
	return 0
}

# True when the artifact may be cached under the shared "-all" key: it carries no
# ABI-specific content at all, or it carries both arm ABIs (the rule as it was, kept).
check_is_universal() { # $1=apk or bundle
	local abis
	abis=$(_artifact_abis "$1") || return 1
	[ -z "$abis" ] && return 0
	printf '%s\n' "$abis" | grep -qx arm64-v8a && printf '%s\n' "$abis" | grep -qx arm-v7a
}

# The arch token an artifact belongs under in a cache file name.
#
# Derived from the bytes, not from what the build asked for: a bundle carrying a single
# ABI is keyed by that ABI even when it was fetched for another arch, so a mis-served
# download lands under a name that cannot be mistaken for somebody else's artifact and
# the mismatch is logged instead of silently adopted by the next build. "all" when
# check_is_universal holds; the requested arch when the artifact names several ABIs but
# not the pair that makes it universal; the requested arch for a file that cannot be
# read at all, which is the conservative key (it can only ever be served to itself).
_cache_arch_key() { # $1=artifact  $2=arch_f this build asked for
	local abis n
	abis=$(_artifact_abis "$1") || { printf '%s' "$2"; return 0; }
	check_is_universal "$1" && { printf 'all'; return 0; }
	n=$(printf '%s\n' "$abis" | grep -c .)
	[ "$n" = 1 ] && { printf '%s' "$abis"; return 0; }
	printf '%s' "$2"
}

# Does a list of ABIs satisfy a build arch? $1=ABI tokens (space or newline
# separated), $2=build arch token. An arch-agnostic artifact (empty list) and the
# catch-all arches (all/universal/auto) satisfy everything; otherwise the list has
# to name $2 exactly. Deliberately NOT a downward-compat test: arm-v7a bytes do run
# on arm64 devices, but shipping them under an arm64-v8a name would be the mislabel
# this gate exists to remove (docs/decisions/0007). IFS-independent on purpose -
# build_rv runs with IFS=$'\n'.
_abis_satisfies() { # $1=abi list  $2=arch
	local arch=${2:-}; arch=${arch// /}
	case "$arch" in all | universal | auto | "") return 0 ;; esac
	[ -z "${1// /}" ] && return 0
	tr ' \n' '\n\n' <<<"$1" | grep -qxF -- "$arch"
}

# Same predicate, read straight off an artifact's bytes. Unreadable is treated as a
# pass (the conservative key: it can only ever be served to itself, matching
# _cache_arch_key's stance), never as a reason to drop a build.
_artifact_satisfies_arch() { # $1=apk or bundle  $2=arch
	local abis
	abis=$(_artifact_abis "$1" 2>/dev/null) || return 0
	_abis_satisfies "$abis" "${2:-}"
}

# Publish a freshly fetched stock artifact into the cache directory under the arch
# token its OWN bytes justify, and hand that path back to the build.
#
# Staging keeps the requested arch to the end - every rejection path in build_rv
# sweeps "${stock_apk%.apk}.*" and the passthrough sidecar scan predicts those names -
# but a name inside apk_cache_dir, and so in the apks store, states what the file
# contains. That key has always been read off the bytes for a bundle
# (_cache_arch_key); a plain APK used to inherit the arch the build happened to ask
# for, which is how one vendor universal APK came to sit in the store as
# <pkg>-13.1.0-72299-arm-v7a.apk beside the identical <pkg>-13.1.0-72299-all.apk.
# Universal bytes belong under the shared "-all" key that _cache_probe_apk and
# dl_archive already offer to every architecture (docs/cache-repo.md), and an
# arch-named copy of them is a filename that lies plus a second 70 MB object nobody
# asks for.
#
# The write is a temp file plus one rename, so an interrupted build cannot leave a
# half file for the next check to trust. A destination that already holds a readable
# archive is adopted instead of rewritten: the per-pkg+version lock in build_rv means
# whoever wrote it is finished with it and already uploaded it, so _PUB_UPLOADED stays
# empty and the caller owes the store nothing. A destination that is not a zip is a
# partial from a killed run and is overwritten.
#
# Sets _PUB_APK (the path to build from), _PUB_ALL (the same path when it is the
# shared key, else empty - the caller spares that one from the validation delete) and
# _PUB_UPLOADED (1 when the caller owes the store an upload).
_publish_stock_artifact() { # $1=staged artifact  $2=cache dir  $3=pkg  $4=version_f  $5=vc_infix  $6=arch_f
	local staged=$1 cdir=$2 pkg=$3 ver=$4 vci=$5 arch_f=$6
	local ext="" key dst tmp
	_PUB_APK=""
	_PUB_ALL=""
	_PUB_UPLOADED=""
	[ -f "$staged" ] || return 1
	# A bundle keeps its own container extension; anything else is a plain APK.
	if ! ext=$(_bundle_ext_of "$staged"); then ext="apk"; fi
	key=$(_cache_arch_key "$staged" "$arch_f")
	dst="${cdir}/${pkg}-${ver}${vci}-${key}.${ext}"
	if [ "$key" != "$arch_f" ] && [ "$key" != all ]; then
		wpr "The artifact fetched for '$pkg' carries '$key' but '$arch_f' was requested; caching under its own key"
	fi
	if [ "$key" = all ]; then _PUB_ALL="$dst"; fi
	if [ "$staged" = "$dst" ]; then
		_PUB_APK="$staged"
		_PUB_UPLOADED=1
		return 0
	fi
	if [ -f "$dst" ] && unzip -l "$dst" >/dev/null 2>&1; then
		pr "Adopting the already published '${dst##*/}' (no rewrite, no second upload)"
		_PUB_APK="$dst"
		return 0
	fi
	tmp="${dst}.tmp.$$"
	if ! cp -f "$staged" "$tmp"; then
		rm -f "$tmp"
		return 1
	fi
	if ! mv -f "$tmp" "$dst"; then
		rm -f "$tmp"
		return 1
	fi
	_PUB_APK="$dst"
	_PUB_UPLOADED=1
	return 0
}

# -------------------- learned download-link index --------------------
# An APKPure/APKCombo/Uptodown link carries no ABI in its URL, so the only way to
# know what it serves is to fetch it. The first build to want one fetches it once and
# records what the bytes actually are here; every later build consults the record and
# either adopts the stored blob with no network hit (right arch) or skips the source
# with no network hit (wrong arch). Kept out of apk_cache_dir so it never enters the
# cache manifest, and independent of the arch-specific staging so a build that rejects
# an artifact still leaves it for its sibling. Scoped to a run; wiped with temp/.
_dlurl_sha() { printf '%s' "$1" | sha1sum | cut -d' ' -f1; }

# Echoes the blob path when a recorded link satisfies $2, "REJECT" when it is a
# recorded different single ABI, or nothing when the link is unknown (so an unknown
# link is fetched, never refused without evidence).
_dlurl_index_lookup() { # $1=url  $2=arch
	local url=$1 arch=${2:-} key abis="" path=""
	key="${TEMP_DIR}/urlindex/keys/$(_dlurl_sha "$url")"
	[ -f "$key" ] || return 0
	IFS=$'\t' read -r abis path < "$key" 2>/dev/null || true
	if [ -z "$path" ] || [ ! -f "$path" ]; then return 0; fi
	if _abis_satisfies "$abis" "$arch"; then printf '%s' "$path"; else printf 'REJECT'; fi
}

# Record what a link's bytes are, after a real fetch, whether or not this build keeps
# them. Published atomically (temp+mv) so a concurrent reader never sees a half line.
_dlurl_index_record() { # $1=url  $2=artifact path
	local url=$1 art=$2
	[ -f "$art" ] || return 0
	local sha ext keysdir="${TEMP_DIR}/urlindex/keys" blobsdir="${TEMP_DIR}/urlindex/blobs"
	sha=$(_dlurl_sha "$url"); ext="${art##*.}"
	mkdir -p "$keysdir" "$blobsdir" 2>/dev/null || return 0
	local blob="$blobsdir/$sha.$ext"
	cp -f "$art" "$blob" 2>/dev/null || return 0
	local abis joined
	abis=$(_artifact_abis "$art" 2>/dev/null) || abis=""
	joined=$(tr '\n' ' ' <<<"$abis" | sed -e 's/  */ /g' -e 's/^ //' -e 's/ $//')
	printf '%s\t%s\n' "$joined" "$blob" > "$keysdir/$sha.tmp.$$" \
		&& mv -f "$keysdir/$sha.tmp.$$" "$keysdir/$sha"
}

# Recorded version for one app from state/app_versions.json. $1 = build table
# name (the " (arch)" suffix build_rv carries is stripped before matching).
# The file maps a group to {keys[], version} and the watcher only maintains the
# groups hand-listed in it ("_check_only_listed") — i.e. exactly the apps whose
# patch CLI advertises no supported version. Echoes nothing when untracked.
_app_versions_json_ver() {
	local app_versions_file="state/app_versions.json"
	[ -f "$app_versions_file" ] || return 0
	local t_pure="${1% (arm64-v8a)}"
	t_pure="${t_pure% (arm-v7a)}"
	jq -r --arg t "$t_pure" 'to_entries | map(select(.key | startswith("_") | not)) | map(select(.value.keys != null and (.value.keys | index($t)))) | .[0].value.version // empty' "$app_versions_file"
}

# Shared version-resolution pre-pass used by build_rv's two call sites
# (early pkg path + post-download path). Operates on the caller's dynamic
# locals: list_patches, resolved_version, version_mode.
#
# Precedence (highest first): an explicit version_mode (a concrete tag, or
# exp/latest/beta) > the version the patch bundle advertises > the version the
# watcher recorded in state/app_versions.json (only reachable when the bundle
# advertises nothing, i.e. get_patch_last_supported_ver returns "Any") > the
# live latest from the download source, which build_rv resolves afterwards.
# Returns: 0 continue | 1 hard failure (caller `return 1`) | 2 skip app (caller `return 0`)
_resolve_list_and_version() {
	local cli_jar=$1 patches_jar=$2 pkg_name=$3 table=$4 say_pkg=${5:-false}
	if [ -z "$list_patches" ]; then
		[ "$say_pkg" = true ] && pr "Package name of '${table}' is '$pkg_name'"
		if ! list_patches=$(patches_list "$cli_jar" "$patches_jar" "$pkg_name" "${args[cli_source]}"); then
			# The listing tool aborted rather than answered: record it so the CI step can
			# report the app. Every other return-1 in this function happens once a version is
			# resolved (the plain descriptor covers it); this one precedes version resolution, so
			# without an explicit record the abort is invisible to the failure notification.
			write_unlistable_failure_descriptor "$(failure_slug "$table")" "$table" "${arch_f:-}" \
				"${args[patches_src]:-${args[cli_source]:-}}" "${args[cli_source]:-}" "$pkg_name"
			return 1
		fi
	fi
	if [ "$PATCHER_HAS_PATCH_LIST" = true ]; then
		if ! grep -Fq "$pkg_name" <<<"$list_patches"; then
			epr "No app-specific patches found for '$pkg_name'. Skipping completely."
			return 2
		fi
	fi
	if [ -z "$resolved_version" ]; then
		if [ "$version_mode" = auto ]; then
			if ! resolved_version=$(get_patch_last_supported_ver "$list_patches" "$pkg_name" \
				"${args[included_patches]:-}" "${args[excluded_patches]:-}" "${args[exclusive_patches]:-}" "${args[cli_source]:-}" "$cli_jar" "$patches_jar"); then
				epr "get_patch_last_supported_ver failed for '$pkg_name'"
				return 2
			fi
			# A bundle can also advertise no version at all ("Any" — see
			# _get_patch_last_supported_ver), which succeeds with empty output.
			# That is the only case the watcher's recorded version is a fallback
			# for; it must never outrank a version the patches were tested with.
			if [ -z "$resolved_version" ]; then
				local json_ver
				json_ver=$(_app_versions_json_ver "$table")
				if [ -n "$json_ver" ]; then
					pr "Patches advertise no version for '$pkg_name'; using watcher version '$json_ver'"
					resolved_version="$json_ver"
				fi
			fi
		elif [ "$version_mode" = exp ]; then
			if [ "$PATCHER_EXP_VERSION_UNSUPPORTED" = true ]; then
				wpr "ReVanced CLI does not support experimental versions."
				return 2
			fi
			if ! resolved_version=$(get_patch_exp_ver "$cli_jar" "$patches_jar" "$pkg_name" "${args[cli_source]}"); then
				epr "get_patch_exp_ver failed"
			fi
			if [ -z "$resolved_version" ]; then
				epr "No exp version found for '$pkg_name', skipping."
				return 2
			fi
		elif isoneof "$version_mode" latest beta; then
			: # Needs latest
		else
			resolved_version=$version_mode
		fi
	fi
	return 0
}

build_rv() {
	eval "declare -A args=${1#*=}"
	local version="${args[version]:-}" pkg_name="${args[pkg_name]:-}"
	
	if [ -z "$pkg_name" ]; then
		if [ -n "${args[github_dlurl]}" ] && [[ "${args[github_dlurl]}" == *"releases/tag/"* ]]; then
			local tmp="${args[github_dlurl]%/}"
			pkg_name="${tmp##*/}"
		elif [ -n "${args[archive_dlurl]}" ] && [[ "${args[archive_dlurl]}" == *"apks/"* ]]; then
			local tmp="${args[archive_dlurl]%/}"
			pkg_name="${tmp##*/}"
		fi
	fi
	local cli_jar="${args[cli]}"
	local patches_jar="${args[ptjar]}"
	local mode_arg=${args[build_mode]} version_mode=${args[version]}
	local app_name=${args[app_name]}
	local app_name_l
	app_name_l=$(resolve_slug "$app_name")
	[ -z "$app_name_l" ] && { app_name_l=${app_name,,}; app_name_l=${app_name_l// /-}; }
	local table=${args[table]}
	local dl_from=${args[dl_from]}
	local arch=${args[arch]}
	local arch_f="${arch// /}"
	local arch_list=("$arch_f")
	[ "$arch_f" = "auto" ] && arch_list=("all" "arm64-v8a" "arm-v7a")

	local IFS=$'\n'
	local p_jars_arr=($(echo "${args[ptjar]}" | tr ' ' '\n' | grep -v '^$'))
	unset IFS
	local n_bundles=${#p_jars_arr[@]}
	local -a p_srcs_arr=(${args[patches_sources_all]:-})

	local -a per_bundle_ed_args=()
	local exc_str="${args[excluded_patches]}"
	local inc_str="${args[included_patches]}"

	# inclusive-patches: expand "every patch this bundle offers for the app" into
	# explicit names, right here, so everything downstream - the version-compatibility
	# gate, the -e/-d assembly below, the catalog's applied-patch list - keeps reading
	# the one included-patches string it already understands and no other code has to
	# learn the flag. Setting both flags at once is rejected in build.sh. An excluded
	# name is dropped from the expansion rather than passed as both -e and -d, where
	# argument order would decide what happens.
	if [ "${args[inclusive_patches]:-false}" = true ]; then
		local -a incl_exc=()
		if [[ "$exc_str" == *"|"* ]]; then
			IFS='|' read -ra incl_exc <<< "$exc_str"
		else
			incl_exc=("$exc_str")
		fi
		# Strip the wrapper quotes off the exclusion names before matching them against
		# the listing, which carries them bare. toml_get hands config names back
		# DOUBLE-quoted (it rewrites ' to "), so the double-quote pair has to be the one
		# that really works: inside single quotes \$ is a literal dollar to sed, not the
		# end-of-line anchor, and a pattern still carrying its trailing quote matches no
		# listing line at all - the exclusion then silently stays in the expansion and
		# reaches the CLI as both -e and -d.
		local incl_bi incl_names incl_drop incl_out incl_join="" incl_n
		for ((incl_bi=0; incl_bi<n_bundles; incl_bi++)); do
			if ! incl_names=$(_all_patch_names "$cli_jar" "${p_jars_arr[$incl_bi]}" "$pkg_name" "${args[cli_source]:-}"); then
				abort "ERROR: inclusive-patches for '$table' needs a CLI that lists its patches; '${args[cli_source]:-}' gave none. Use included-patches for this source."
			fi
			incl_drop=$(list_args "${incl_exc[$incl_bi]:-${incl_exc[0]:-}}" | sed -e "s/^'//" -e "s/'\$//" -e 's/^"//' -e 's/"$//')
			incl_out=$(printf '%s\n' "$incl_names" | grep -vxF -f <(printf '%s\n' "$incl_drop") | _group_patch_names)
			incl_out="${incl_out%"${incl_out##*[![:space:]]}"}"
			if [ -z "$incl_out" ]; then
				abort "ERROR: inclusive-patches for '$table' resolved to no patch names from '${p_srcs_arr[$incl_bi]:-}'."
			fi
			incl_n=$(printf '%s\n' "$incl_names" | grep -c .)
			pr "inclusive-patches: '$table' -> $incl_n patches from '${p_srcs_arr[$incl_bi]:-}'"
			[ "$incl_bi" -gt 0 ] && incl_join+=" | "
			incl_join+="$incl_out"
		done
		inc_str="$incl_join"
		args[included_patches]="$incl_join"
	fi

	if [[ "$exc_str" == *"|"* ]] || [[ "$inc_str" == *"|"* ]]; then
		local -a exc_parts=() inc_parts=()
		IFS='|' read -ra exc_parts <<< "$exc_str"
		IFS='|' read -ra inc_parts <<< "$inc_str"
		
		for ((bi=0; bi<n_bundles; bi++)); do
			local bundle_ed=""
			local bp_exc="${exc_parts[$bi]:-}"
			local bp_inc="${inc_parts[$bi]:-}"
			bp_exc=$(echo "$bp_exc" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
			bp_inc=$(echo "$bp_inc" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
			if [ -n "$bp_exc" ]; then bundle_ed+=" $(join_args "$bp_exc" -d)"; fi
			if [ -n "$bp_inc" ]; then bundle_ed+=" $(join_args "$bp_inc" -e)"; fi

			local is_exclusive=false
			if [ "${args[exclusive_patches]}" = "true" ]; then
				is_exclusive=true
			elif [ "${args[exclusive_patches]}" != "false" ] && [ -n "${args[exclusive_patches]}" ]; then
				local current_src="${p_srcs_arr[$bi]:-}"
				local -a exc_srcs=($(list_args "${args[exclusive_patches]}" | tr -d \"\'))
				[ ${#exc_srcs[@]} -eq 0 ] && exc_srcs=("${args[exclusive_patches]}")
				for esrc in "${exc_srcs[@]}"; do
					if [ "$esrc" = "$current_src" ]; then
						is_exclusive=true
						break
					fi
				done
			fi
			if [ "$is_exclusive" = true ]; then
				local all_patches_op
				if all_patches_op=$(patches_list "$cli_jar" "${p_jars_arr[$bi]}" "$pkg_name" "${args[cli_source]}"); then
					local all_patches=()
					mapfile -t all_patches < <(echo "$all_patches_op" | grep -iE '^[[:space:]]*Name:' | sed -E 's/^[[:space:]]*Name:[[:space:]]*//I' | sed 's/[[:space:]]*$//')
					
					local new_bp_exc="$bp_exc"
					local -a current_bp_inc=()
					bp_inc=$(echo "$bp_inc" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
					if [ -n "$bp_inc" ]; then
						while IFS= read -r p; do
							[ -n "$p" ] && current_bp_inc+=("$p")
						done <<< "$(list_args "$bp_inc" | sed -e "s/^'//" -e "s/'$//" -e 's/^"//' -e 's/"$//')"
					fi
					
					local new_bp_exc="$bp_exc"
					for p_name in "${all_patches[@]}"; do
						local found=false
						for inc_p in "${current_bp_inc[@]}"; do
							if [ "$p_name" = "$inc_p" ]; then
								found=true
								break
							fi
						done
						if [ "$found" = false ]; then
							new_bp_exc+=" '$p_name'"
						fi
					done
					bp_exc="$new_bp_exc"
					
					bundle_ed=""
					bp_exc=$(echo "$bp_exc" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
					if [ -n "$bp_exc" ]; then bundle_ed+=" $(join_args "$bp_exc" -d)"; fi
					if [ -n "$bp_inc" ]; then bundle_ed+=" $(join_args "$bp_inc" -e)"; fi
				else
					epr "FATAL: Failed to fetch patch list for exclusive bundle '${p_jars_arr[$bi]}'. Cannot safely apply per-bundle exclusivity."
					return 1
				fi
			fi
			per_bundle_ed_args+=("$bundle_ed")
		done
	else
		local global_ed=""
		if [ -n "$exc_str" ]; then global_ed+=" $(join_args "$exc_str" -d)"; fi
		if [ -n "$inc_str" ]; then global_ed+=" $(join_args "$inc_str" -e)"; fi
		
		for ((bi=0; bi<n_bundles; bi++)); do
			local bundle_ed="$global_ed"
			local is_exclusive=false
			if [ "${args[exclusive_patches]}" = "true" ]; then
				is_exclusive=true
			elif [ "${args[exclusive_patches]}" != "false" ] && [ -n "${args[exclusive_patches]}" ]; then
				local current_src="${p_srcs_arr[$bi]:-}"
				local -a exc_srcs=($(list_args "${args[exclusive_patches]}" | tr -d \"\'))
				[ ${#exc_srcs[@]} -eq 0 ] && exc_srcs=("${args[exclusive_patches]}")
				for esrc in "${exc_srcs[@]}"; do
					if [ "$esrc" = "$current_src" ]; then
						is_exclusive=true
						break
					fi
				done
			fi
			[ "$is_exclusive" = true ] && bundle_ed+=" --exclusive"
			per_bundle_ed_args+=("$bundle_ed")
		done
	fi

	local p_patcher_args=()
	if isoneof "$version_mode" latest beta || [ "$version_mode" != "auto" -a "$version_mode" != "exp" ]; then
		p_patcher_args+=("-f")
	fi

	local tried_dl=()
	local list_patches=""
	local apk_cache_dir="${APK_CACHE_DIR:-${TEMP_DIR}/apks}"
	local apk_dl_dir="${TEMP_DIR}/apks_dl"
	mkdir -p "$apk_cache_dir" "$apk_dl_dir"

	local skip_dl_source_check=false
	local resolved_version=""
	local get_latest_ver=false
	local cli_source_l="${args[cli_source]:-}"
	cli_source_l="${cli_source_l,,}"
	resolve_patcher "${args[cli_source]:-}"
	local cli_lv_extra="$PATCHER_LIST_X"
	# Morphe bundle passthrough: keep vendor bundles (.xapk/.apkm/.apks) as the
	# cache artifact and hand them to morphe directly (it merges bundles natively)
	# — only when the tool is morphe-desktop and RVB_MORPHE_PASSTHROUGH is on.
	# Other tools keep the apkeditor-merge-at-download flow unchanged.
	local MORPHE_PASSTHROUGH_ACTIVE=false
	local _CACHE_BUNDLE_OK=false
	local morphe_bundle_path=""
	if [ "$PATCHER_KIND" = morphe ] && [ "$RVB_MORPHE_PASSTHROUGH" = true ]; then
		MORPHE_PASSTHROUGH_ACTIVE=true
		_CACHE_BUNDLE_OK=true
	fi

	# 1. Resolve pkg_name early if possible and check cache
	if [ -n "$pkg_name" ]; then
		# Re-resolve fresh at this site (matches original unconditional call);
		# list_patches may be cached from an earlier pkg attempt.
		list_patches=""
		local _rstatus=0
		_resolve_list_and_version "$cli_jar" "$patches_jar" "$pkg_name" "$table" false || _rstatus=$?
		if [ "$_rstatus" = 1 ]; then return 1; fi
		if [ "$_rstatus" = 2 ]; then return 0; fi
	fi

	local all_resolved_versions=()
	if [ -n "$resolved_version" ]; then
		mapfile -t all_resolved_versions <<<"$resolved_version"
	else
		all_resolved_versions=("")
	fi

	local final_stock_apk=""
	local final_all_apk=""
	local final_version=""
	# The last version the engine actually resolved. build_rv wipes 'version' to
	# final_version (empty when nothing built) right after this loop, so the failure
	# descriptors below cannot read it; a latest/auto app also leaves resolved_version
	# empty, which is why they used to report a blank version. This survives the loop.
	local last_resolved_version=""
	# Why the candidate loop produced nothing. The two outcomes are reported very
	# differently: versions rejected by the patch set never wanted an APK, so telling a
	# human to upload one is noise; a fetch no source served is exactly that request.
	local _no_patch_versions=""
	local _dl_attempted=""
	
	for curr_resolved_version in "${all_resolved_versions[@]}"; do
		resolved_version="$curr_resolved_version"
		skip_dl_source_check=false
		get_latest_ver=false
		tried_dl=()
		dl_from=""
			# Cache Check
			if [ -n "$pkg_name" ]; then
				if [ -n "$resolved_version" ]; then
					local version_f=${resolved_version// /}
					version_f=${version_f#v}
					if _cache_all_archs_present "$version_f" validate "$resolved_version"; then
						pr "Found all required architectures for '$pkg_name' (v$version_f) in cache. Skipping download!"
						skip_dl_source_check=true
						version="$resolved_version"
					fi
				else
					# Dynamic Cache Discovery for "latest" or empty version
					local cached_apks=($(find "$apk_cache_dir" -name "${pkg_name}-*.apk" -type f 2>/dev/null || true))
					if [ ${#cached_apks[@]} -gt 0 ]; then
						local cached_versions=""
						for capk in "${cached_apks[@]}"; do
							local bname=$(basename "$capk")
							# extract version from format: pkg_name-version-arch.apk or pkg_name-version-vc-arch.apk
							local v=${bname#${pkg_name}-}
							v=${v%.apk}
							v=${v%-arm64-v8a}
							v=${v%-arm-v7a}
							v=${v%-x86_64}
							v=${v%-x86}
							v=${v%-all}
							v=${v%-universal}
							if [[ "$v" =~ ^(.*)-([0-9]+)$ ]]; then
								v="${BASH_REMATCH[1]}"
							fi
							cached_versions+="$v"$'
'
						done
						local dyn_ver
						if dyn_ver=$(echo "$cached_versions" | get_highest_ver) && [ -n "$dyn_ver" ]; then
							if _cache_all_archs_present "$dyn_ver"; then
								pr "Discovered highest version (v$dyn_ver) for '$pkg_name' in cache. Skipping download!"
								skip_dl_source_check=true
								version="$dyn_ver"
								resolved_version="$dyn_ver"
							fi
						fi
					fi
				fi
			fi


		if [ "$skip_dl_source_check" = false ]; then
			# 2. Establish dl_from and fetch required HTML responses
		if [ -n "${UPLOAD_APKS_REPO:-}" ] && [ -n "$pkg_name" ]; then
			args[cache_repo_dlurl]="https://github.com/${UPLOAD_APKS_REPO}/releases/tag/${pkg_name}"
		fi
			for dl_p in "${DL_SRCS[@]}"; do
				if [ -z "${args[${dl_p}_dlurl]}" ]; then continue; fi
				
				# If we need to find the latest version, do not use cache repositories as the source of truth
				if [ -z "$resolved_version" ]; then
					if [ "$dl_p" = "archive" ] || [ "$dl_p" = "cache_repo" ]; then
						continue
					fi
				fi

				if ! get_${dl_p}_resp "${args[${dl_p}_dlurl]}"; then
					args[${dl_p}_dlurl]=""
					if [ "$dl_p" = "cache_repo" ] && [ "${__CACHE_REPO_MISS__:-false}" = true ]; then
						# Not a failure: the package has never been uploaded to the cache repo,
						# which is the state of every app's first build. Calling it ERROR made
						# each of those runs look broken over a normal cache miss.
						pr "No cached release for '${pkg_name:-$table}' on ${UPLOAD_APKS_REPO} yet; using the live sources."
					else
						epr "ERROR: Could not get response for ${table} in ${dl_p}"
					fi
					continue
				fi
				
				# If pkg_name is still empty, try to scrape it from the response
				if [ -z "$pkg_name" ]; then
					if ! pkg_name=$(get_"${dl_p}"_pkg_name) || [ -z "$pkg_name" ]; then
						args[${dl_p}_dlurl]=""
						epr "ERROR: Could not scrape pkg_name for ${table} in ${dl_p}"
						continue
					fi
				fi
				
				tried_dl+=("$dl_p")
				dl_from=$dl_p
				break
			done

			if [ -z "$dl_from" ]; then
				epr "ERROR: No valid download source found for ${table}."
				# Record so the CI step can ask for a manual cache-repo upload. version is
				# the config value here (resolution hasn't run); show "unknown" when unpinned.
				write_dl_failure_descriptor "$(failure_slug "$table")" "$table" \
					"${resolved_version:-$version_mode}" \
					"$(parse_arch_mapping "${args[version_code]:-}" "${arch_f:-}")" \
					"$arch_f" "$pkg_name"
				return 0
			fi

			if [ -z "$pkg_name" ]; then
				epr "ERROR: Could not determine pkg_name for ${table}."
				return 0
			fi
			
			# If we didn't run patches_list earlier because pkg_name was empty
			local _rstatus=0
			_resolve_list_and_version "$cli_jar" "$patches_jar" "$pkg_name" "$table" true || _rstatus=$?
			if [ "$_rstatus" = 1 ]; then return 1; fi
			if [ "$_rstatus" = 2 ]; then return 0; fi
			
			version="$resolved_version"
			[ -z "$version" ] && get_latest_ver=true
			if [ $get_latest_ver = true ]; then
				if [ "$version_mode" = beta ]; then __AAV__="true"; else __AAV__="false"; fi
				local vers_cache_key="${dl_from}_${args[${dl_from}_dlurl]}_${pkg_name:-default}_${__AAV__}"
				if [ -n "${__PKG_VERS_CACHE__["$vers_cache_key"]:-}" ]; then
					pkgvers="${__PKG_VERS_CACHE__["$vers_cache_key"]}"
				else
					pkgvers=$(get_"${dl_from}"_vers)
					__PKG_VERS_CACHE__["$vers_cache_key"]="$pkgvers"
				fi
				version=$(get_highest_ver <<<"$pkgvers") || version=$(head -1 <<<"$pkgvers")
			fi
		else
			pr "Package name of '${table}' is '$pkg_name'"
			pr "Skipping download source check, APKs for version '$version' found in cache."
		fi
		if [ -z "$version" ]; then
			epr "empty version, not building ${table}."
			continue
		fi
		# Remember the concrete version this candidate resolved to (from config, patches
		# or the live latest), so a later fetch/patch failure can still report it after
		# 'version' is reset. Set before the patch gate so the no-patches path has it too.
		last_resolved_version="$version"

		if [ "$mode_arg" = module ]; then
			build_mode_arr=(module)
		elif [ "$mode_arg" = apk ]; then
			build_mode_arr=(apk)
		elif [ "$mode_arg" = both ]; then
			build_mode_arr=(apk module)
		fi

		pr "Choosing version '${version}' for ${table}"
		local version_f=${version// /}
		version_f=${version_f#v}

		if ! has_compatible_patches "$cli_jar" "$patches_jar" "$pkg_name" "$version_f" "${args[cli_source]:-}" "${args[included_patches]:-}"; then
			wpr "No compatible patches found in '${args[patches_src]:-${args[cli_source]:-}}' for '$pkg_name' v${version_f}. Skipping ${table}."
			_no_patch_versions+=" ${version_f}"
			continue
		fi

		# Arch honesty at the candidate level (docs/decisions/0007): a version whose
		# patch annotation lists other ABIs only has no build for this arch, so its bytes
		# would be thrown away by the post-download gate after a full fetch. Drop the
		# candidate now and let the next supported version take its place. Ordered AFTER
		# the gate on purpose: the gate is a direct call and fills the memo tables this
		# subshell reads, so no second JVM run per candidate.
		local _tbl_vc=""
		if [ "$arch_f" != "all" ] && [ "$arch_f" != "auto" ] && [ "$arch_f" != "universal" ]; then
			if ! _tbl_vc=$(_candidate_arch_verdict "$version_f" "$arch_f" "${all_resolved_versions[*]}"); then
				wpr "Version '${version_f}' of '$pkg_name' declares no '${arch_f}' build in '${args[patches_src]:-${args[cli_source]:-}}'. Skipping ${table}."
				_no_patch_versions+=" ${version_f}"
				continue
			fi
		fi

		# Version, VC and patches-source are final here; anything that aborts from the
		# build loop below leaves this descriptor for the CI step to report. The parent
		# deletes it when build_rv returns clean. Written once with the requested arch.
		write_build_failure_descriptor "$(failure_slug "$table")" "$table" "$version_f" \
			"$(parse_arch_mapping "${args[version_code]:-}" "$arch_f")" \
			"$arch_f" "${args[patches_src]:-${args[cli_source]:-}}"

		for arch in "${arch_list[@]}"; do
			arch_f="${arch// /}"
			local target_version_code
			target_version_code=$(parse_arch_mapping "${args[version_code]:-}" "$arch_f")
			# Whether that code is an order written in the config or merely what the patch
			# annotation says about a version. A direct link re-keys its artifact to the
			# bytes it actually got, and only a hand-written pin survives that re-key.
			local _vc_pinned_by_config=false
			if [ -n "$target_version_code" ] && [ "$target_version_code" != "auto" ]; then
				_vc_pinned_by_config=true
			fi
			if [ -z "$target_version_code" ] || [ "$target_version_code" = "auto" ]; then
				target_version_code=""
				if [ -n "$version" ] && [ -n "$cli_jar" ] && [ -n "$patches_jar" ]; then
					local raw_vers
					if raw_vers=$(patches_list_versions "$cli_jar" "$patches_jar" "$pkg_name" "${args[cli_source]:-}" "$cli_lv_extra"); then
						target_version_code=$(get_patch_version_code "$raw_vers" "$version" "$arch_f" || true)
					fi
					# Same fallback as _cache_target_vc: the effective table still knows the
					# code when list-versions ignores the patches this build will apply. The
					# candidate filter above already read it for this arch; reuse that value
					# instead of starting another pass.
					if [ -z "$target_version_code" ]; then
						target_version_code="${_tbl_vc:-}"
						if [ -z "$target_version_code" ]; then
							target_version_code=$(_patch_arch_verdict "$version_f" "$arch_f" || true)
						fi
					fi
				fi
			fi
			if [ -n "$target_version_code" ]; then
				pr "Target version code for '$pkg_name' (v${version}, arch: ${arch_f}): $target_version_code"
			fi

			local vc_infix="${target_version_code:+-${target_version_code}}"
			# Serialize the cache-check → download → upload sequence per pkg+version.
			# Sibling processes (parallel builds) then hit the local cache path or the
			# cache repo instead of hammering the same source twice, and can never
			# race on creating/uploading to the same apks-cache-repo release.
			# Lock files live OUTSIDE apk_cache_dir so they never enter its cache manifest.
			#
			# The version code is deliberately NOT part of the lock name. It is a claim about
			# bytes that are only read after the lock is taken - the arch picker leaves it
			# unset when no supported version declares this arch, and the direct source
			# re-keys to the code it reads off the artifact - so two builds of one pkg+version
			# can compute different names here and run unserialized. That is what let one
			# universal Telegram APK be uploaded twice in run 39985777497 (arm64-v8a locked on
			# the declared code, arm-v7a on the name without it).
			local _apk_lock_held=""
			if command -v flock >/dev/null 2>&1; then
				mkdir -p "${TEMP_DIR}/apkslocks"
				exec 203>"${TEMP_DIR}/apkslocks/${pkg_name}-${version_f}.lock"
				flock -x 203
				_apk_lock_held=1
			fi
			local cached_stock_apk="${apk_cache_dir}/${pkg_name}-${version_f}${vc_infix}-${arch_f}.apk"
			local cached_all_apk="${apk_cache_dir}/${pkg_name}-${version_f}${vc_infix}-all.apk"
			local stock_apk="$cached_stock_apk"
			local all_apk="$cached_all_apk"
			# No pre-versionCode name is tried here (see _cache_probe_apk for why): if
			# the modern names miss, this arch re-downloads and lands under the key that
			# states the code it was checked against.
			# Bundle lookup: this arch's own key first, then the shared "-all" key, which
			# now only ever holds a bundle verified to carry every ABI (or none). Nothing here
			# re-derives the arch from the file to decide whether the name was honest, because
			# the name is written from the file in the first place (_cache_arch_key).
			#
			# Before that, an arm64 bundle sat in <pkg>-<ver>-<vc>-all.xapk, this arm-v7a build
			# adopted it, the merge dropped the arm64 split as not the target arch, and the
			# patcher failed on the resulting library-less APK.
			local cached_bundle_apk=""
			if [ "$_CACHE_BUNDLE_OK" = true ]; then
				local bx _bp
				for bx in xapk apkm apks; do
					_bp="${apk_cache_dir}/${pkg_name}-${version_f}${vc_infix}-${arch_f}.${bx}"
					[ -f "$_bp" ] || _bp="${apk_cache_dir}/${pkg_name}-${version_f}${vc_infix}-all.${bx}"
					if [ -f "$_bp" ]; then cached_bundle_apk="$_bp"; break; fi
				done
			fi
			if [ -n "$cached_bundle_apk" ]; then
				stock_apk="$cached_bundle_apk"
				all_apk="$cached_bundle_apk"
			elif [ -f "$all_apk" ]; then
				stock_apk="$all_apk"
			fi

			local check_apk=""
			[ -f "$stock_apk" ] && check_apk="$stock_apk"
			[ -z "$check_apk" ] && [ -f "$all_apk" ] && check_apk="$all_apk"
			if [ -n "$check_apk" ] && [ -n "$target_version_code" ]; then
				local cached_vc
				cached_vc=$(_meta_field_of "$check_apk" versionCode) || true
				if [ -n "$cached_vc" ] && [ "$cached_vc" != "$target_version_code" ]; then
					pr "Cached APK for '$pkg_name' has versionCode '$cached_vc', but target requires '$target_version_code'. Cache invalidated."
					[ "$check_apk" != "$all_apk" ] && rm -f "$check_apk"
					stock_apk=""
					all_apk=""
				fi
			fi

			if [ ! -f "$stock_apk" ]; then
				# Redirect to staging directory for safe downloading and processing
				stock_apk="${apk_dl_dir}/${pkg_name}-${version_f}${vc_infix}-${arch_f}.apk"
				all_apk="${apk_dl_dir}/${pkg_name}-${version_f}${vc_infix}-all.apk"

				for dl_p in "${DL_SRCS[@]}"; do
					if [ -z "${args[${dl_p}_dlurl]}" ]; then continue; fi
					_dl_attempted=1
					pr "Downloading '${table}' from '${dl_p}'"
					if ! isoneof $dl_p "${tried_dl[@]}"; then
						if ! get_${dl_p}_resp "${args[${dl_p}_dlurl]}"; then
							epr "ERROR: Could not get '${table}' from '${dl_p}'"
							continue
						fi
					fi
					DL_VC_ARCH_FALLBACK=""
					if ! dl_${dl_p} "${args[${dl_p}_dlurl]}" "$version" "$stock_apk" "$arch" "${args[dpi]}" "$get_latest_ver" "$target_version_code"; then
						pr "ERROR: Could not download '${table}' from '${dl_p}' with version '${version}', arch '${arch}', dpi '${args[dpi]}'"
						rm -f "$stock_apk" "${stock_apk%.apk}".* "${stock_apk}".*
						continue
					fi
					if ! unzip -l "$stock_apk" >/dev/null 2>&1; then
						epr "ERROR: Downloaded file from ${dl_p} is not a valid zip archive (Cloudflare block or bad file)!"
						rm -f "$stock_apk" "${stock_apk%.apk}".* "${stock_apk}".*
						continue
					fi
					if ! unzip -l "$stock_apk" 2>/dev/null | grep -q '^[[:space:]]*[0-9].*AndroidManifest\.xml$'; then
						pr "WARNING: ${stock_apk} does not contain AndroidManifest.xml at root. Attempting to extract as bundle (XAPK/APKS/APKM)..."
						mv "$stock_apk" "${stock_apk}.bundle"
						if [ "${MORPHE_PASSTHROUGH_ACTIVE:-false}" = true ]; then
							# passthrough: keep the bundle (generic .xapk name is fine for
							# morphe; it merges bundles natively) — no apkeditor merge.
							mv -f "${stock_apk}.bundle" "${stock_apk%.apk}.xapk"
							stock_apk="${stock_apk%.apk}.xapk"
						else
							if ! merge_splits "${stock_apk}.bundle" "$stock_apk"; then
								epr "ERROR: Failed to extract/merge bundle"
								rm -f "${stock_apk}.bundle" "$stock_apk"
								continue
							fi
							rm -f "${stock_apk}.bundle"
						fi
					fi

					local aapt_cmd="aapt"
					if ! command -v aapt >/dev/null 2>&1; then
						if [ -n "${ANDROID_SDK_ROOT:-}" ]; then
							aapt_cmd=$(ls -1 $ANDROID_SDK_ROOT/build-tools/*/aapt 2>/dev/null | tail -1) || true
						fi
						if [ ! -x "$aapt_cmd" ] && [ -n "${AAPT2:-}" ] && [ -x "$AAPT2" ]; then
							aapt_cmd="$AAPT2"
						fi
					fi
					if [ -n "$aapt_cmd" ] && [ -x "$aapt_cmd" ]; then
						local downloaded_pkg downloaded_ver downloaded_vc
						downloaded_pkg=$(_meta_field_of "$stock_apk" package) || true
						downloaded_ver=$(_meta_field_of "$stock_apk" versionName) || true
						
						# Every rejection in this loop clears the same artifact set the
						# download-failure paths above use: the staged apk plus any sibling
						# extension the source produced (.apkm/.xapk/.apks/.bundle). These are
						# staging paths - the sync into apk_cache_dir happens after the loop - so a
						# leftover bundle could otherwise be picked up by the NEXT source's download
						# (the candidate scans at the bottom of the loop look for "${stock_apk%.apk}.<ext>")
						# and get merged, verified and cached as if it had passed identity checks.
						if [ -z "$downloaded_pkg" ]; then
							epr "ERROR: Downloaded file is not a valid APK or aapt failed to parse it. Rejecting..."
							rm -f "$stock_apk" "${stock_apk%.apk}".* "${stock_apk}".*
							continue
						fi

						if [ "$downloaded_pkg" != "$pkg_name" ] && [[ "$pkg_name" == *.* ]]; then
							epr "ERROR: Downloaded APK package name ($downloaded_pkg) does not match expected ($pkg_name). Rejecting..."
							rm -f "$stock_apk" "${stock_apk%.apk}".* "${stock_apk}".*
							continue
						fi

						# A target version code is a claim the cache filename goes on making
						# (<pkg>-<version>-<code>-<arch>), so it has to be read off the bytes.
						# An unreadable code is NOT a pass: versionCode only comes from
						# `dump badging`, while the package check above can succeed on the
						# cheaper `dump packagename` - so a badging failure used to slip an
						# unverified APK into the cache under a version code it never proved.
						# Apps with no resolved target code never enter this block at all.
						# A direct link is exempt unless the code was written by hand: whatever
						# code the patches annotated for some other version cannot judge the one
						# artifact this source is able to serve, and the block below keys the
						# cache name to the code it reads off these bytes.
						if [ -n "$target_version_code" ] &&
							{ [[ "$dl_p" != "direct" ]] || [ "$_vc_pinned_by_config" = true ]; }; then
							downloaded_vc=$(_meta_field_of "$stock_apk" versionCode) || true
							if [ -z "$downloaded_vc" ]; then
								epr "ERROR: Expected version code $target_version_code for '$pkg_name' but aapt read none from the downloaded file (dump badging produced nothing). Rejecting..."
								rm -f "$stock_apk" "${stock_apk%.apk}".* "${stock_apk}".*
								continue
							elif [ "$downloaded_vc" != "$target_version_code" ]; then
								if [ "${DL_VC_ARCH_FALLBACK:-}" = 1 ] && [ "$dl_p" = apkmirror ]; then
									# The picker returned the right arch at the right version under a
									# different code than the bundle pinned. Re-key the staged artifact
									# (and any sidecar) to its real code so the cache filename, the
									# upload and the patch gate all describe the bytes we actually hold.
									wpr "Re-keying '$arch' '$pkg_name' to its real version code $downloaded_vc (bundle pinned $target_version_code, which no '$arch' build carries)"
									local _rk_old="-${target_version_code}-" _rk_new="-${downloaded_vc}-" _rk_newstock _rk_bext
									_rk_newstock="${stock_apk/$_rk_old/$_rk_new}"
									if [ "$_rk_newstock" != "$stock_apk" ]; then
										mv -f "$stock_apk" "$_rk_newstock" 2> /dev/null || true
										for _rk_bext in xapk apkm apks bundle; do
											[ -e "${stock_apk%.apk}.${_rk_bext}" ] && mv -f "${stock_apk%.apk}.${_rk_bext}" "${_rk_newstock%.apk}.${_rk_bext}" 2> /dev/null || true
										done
										stock_apk="$_rk_newstock"
									fi
									vc_infix="-${downloaded_vc}"
									all_apk="${apk_dl_dir}/${pkg_name}-${version_f}${vc_infix}-all.apk"
									cached_stock_apk="${apk_cache_dir}/${pkg_name}-${version_f}${vc_infix}-${arch_f}.apk"
									cached_all_apk="${apk_cache_dir}/${pkg_name}-${version_f}${vc_infix}-all.apk"
									target_version_code="$downloaded_vc"
									DL_VC_ARCH_FALLBACK=""
									# Stamp the still-open failure descriptor with vc_fallback so the report
									# can name this a genuine code→arch incompatibility, not a transient miss
									# (build failures are settled, never re-queued, so the stamp no longer drives
									# a retry decision). On success the parent deletes the descriptor.
									local _rk_fd="${TEMP_DIR}/failures/$(failure_slug "$table").json"
									if [ -f "$_rk_fd" ]; then
										jq -c '. + {vc_fallback:true}' "$_rk_fd" > "${_rk_fd}.tmp" 2> /dev/null && mv -f "${_rk_fd}.tmp" "$_rk_fd" || rm -f "${_rk_fd}.tmp"
									fi
								else
									epr "ERROR: Downloaded APK version code ($downloaded_vc) does not match expected ($target_version_code). Rejecting..."
									rm -f "$stock_apk" "${stock_apk%.apk}".* "${stock_apk}".*
									continue
								fi
							fi
						fi

						# A direct URL carries no identity in its text, so its bytes decide it here,
						# after the package check has proved the artifact and after any hand-pinned
						# version code has been honoured: the staged file (and the bundle it arrived
						# in, if any) is re-keyed to the versionName and versionCode read off it, so the
						# cache name, the upload and the manifest describe what was actually fetched
						# instead of what the link's filename claimed. Nothing above this point mutates
						# state when it rejects, and nothing re-keyed here is left behind if the re-key
						# turns out to be unbuildable: the version can move out from under the
						# compatibility gate that ran before the download, so that gate is re-run on the
						# true version, an unsupported live build is never shipped, its fetch is
						# discarded, and the version-selecting sources are handed the original version
						# back to serve.
						if [[ "$dl_p" == "direct" ]] && [ -n "$downloaded_ver" ]; then
							downloaded_vc=$(_meta_field_of "$stock_apk" versionCode) || true
							local _d_ver_f=${downloaded_ver// /}
							_d_ver_f=${_d_ver_f#v}
							local _d_vc_infix="${downloaded_vc:+-$downloaded_vc}"
							if [ "$_d_ver_f" != "$version_f" ] || [ "$_d_vc_infix" != "$vc_infix" ]; then
								local _d_keep_version="$version" _d_keep_version_f="$version_f" \
									_d_keep_vc_infix="$vc_infix" _d_keep_target="$target_version_code" \
									_d_keep_all="$all_apk" _d_keep_cached="$cached_stock_apk" \
									_d_keep_cached_all="$cached_all_apk"
								pr "Direct URL serves '$pkg_name' v${_d_ver_f}${_d_vc_infix:+ (${downloaded_vc})} instead of v${version_f}${vc_infix}; re-keying the artifact"
								local _d_new="${apk_dl_dir}/${pkg_name}-${_d_ver_f}${_d_vc_infix}-${arch_f}.apk"
								if [ "$_d_new" != "$stock_apk" ]; then
									mv -f "$stock_apk" "$_d_new" 2>/dev/null || true
									local _d_bext
									for _d_bext in xapk apkm apks bundle; do
										if [ -e "${stock_apk%.apk}.${_d_bext}" ]; then
											mv -f "${stock_apk%.apk}.${_d_bext}" "${_d_new%.apk}.${_d_bext}" 2>/dev/null || true
										fi
									done
									stock_apk="$_d_new"
								fi
								version="$downloaded_ver"
								version_f="$_d_ver_f"
								vc_infix="$_d_vc_infix"
								all_apk="${apk_dl_dir}/${pkg_name}-${version_f}${vc_infix}-all.apk"
								cached_stock_apk="${apk_cache_dir}/${pkg_name}-${version_f}${vc_infix}-${arch_f}.apk"
								cached_all_apk="${apk_cache_dir}/${pkg_name}-${version_f}${vc_infix}-all.apk"
								if [ "$_vc_pinned_by_config" != true ]; then
									target_version_code="$downloaded_vc"
								fi
								if ! has_compatible_patches "$cli_jar" "$patches_jar" "$pkg_name" "$version_f" "${args[cli_source]:-}" "${args[included_patches]:-}"; then
									wpr "The direct URL's v${version_f} of '$pkg_name' has no compatible patches; dropping the source so the versioned sources can serve v${_d_keep_version_f}"
									rm -f "$stock_apk" "${stock_apk%.apk}".* "${stock_apk}".*
									version="$_d_keep_version"
									version_f="$_d_keep_version_f"
									vc_infix="$_d_keep_vc_infix"
									target_version_code="$_d_keep_target"
									stock_apk="${apk_dl_dir}/${pkg_name}-${version_f}${vc_infix}-${arch_f}.apk"
									all_apk="$_d_keep_all"
									cached_stock_apk="$_d_keep_cached"
									cached_all_apk="$_d_keep_cached_all"
									args[direct_dlurl]=""
									continue
								fi
							fi
						fi
					fi
					local _vapk="$stock_apk"
					if ! verify_downloaded_apk "$_vapk" "$pkg_name" "$dl_p"; then
						rm -f "$stock_apk" "${stock_apk%.apk}".* "${stock_apk}".*
						continue
					fi

					# Arch honesty: a download that does not carry the requested ABI is not
					# the artifact this build asked for. Reject it and fall through to the next
					# source; when no source supplies the arch the build is not produced at all
					# (replaces the old "warn + ship the featured bundle under another arch's
					# name" behaviour - docs/decisions/0007). Judged on the vendor bundle when one
					# is present, because a passthrough base.apk alone can look ABI-less.
					local _abi_file="$stock_apk" _abx
					for _abx in xapk apkm apks; do
						[ -f "${stock_apk%.apk}.${_abx}" ] && { _abi_file="${stock_apk%.apk}.${_abx}"; break; }
					done
					if ! _artifact_satisfies_arch "$_abi_file" "$arch"; then
						wpr "Downloaded artifact from '${dl_p}' does not carry '$arch' (found: $(tr '\n' ' ' <<<"$(_artifact_abis "$_abi_file" 2>/dev/null)")); skipping source"
						rm -f "$stock_apk" "${stock_apk%.apk}".* "${stock_apk}".*
						continue
					fi

					break
				done
				# The chain is a fetch-time ordering over variant lists; these sources
				# serve exactly one artifact per release, so there is nothing to prefer.
				# Warn-and-ignore, never an abort — the bytes they ship are still valid.
				if [ -f "$stock_apk" ] && [ -n "${args[preferred_format]:-}" ] &&
					isoneof "$dl_p" cache_repo direct github fdroid; then
					wpr "preferred-format '${args[preferred_format]}' has no effect on source '$dl_p' for '$table': it serves one artifact per release"
				fi
				local _be
				if [ "${MORPHE_PASSTHROUGH_ACTIVE:-false}" = true ]; then
					if _be=$(_bundle_ext_of "$stock_apk"); then
						morphe_bundle_path="$stock_apk"
					else
						for bx in xapk apkm apks; do
							local candidate=""
							if [ -f "${stock_apk%.apk}.${bx}" ]; then
								candidate="${stock_apk%.apk}.${bx}"
							elif [ -f "${stock_apk}.${bx}" ]; then
								candidate="${stock_apk}.${bx}"
							fi
							if [ -n "$candidate" ]; then
								if unzip -l "$candidate" >/dev/null 2>&1; then
									if [ "$candidate" = "${stock_apk}.${bx}" ]; then
										mv -f "${stock_apk}.${bx}" "${stock_apk%.apk}.${bx}" 2>/dev/null || true
										candidate="${stock_apk%.apk}.${bx}"
									fi
									morphe_bundle_path="$candidate"
									break
								else
									wpr "Corrupt bundle sidecar found and removed: $candidate"
									rm -f "$candidate"
								fi
							fi
						done
					fi
					if [ -n "$morphe_bundle_path" ]; then
						# cache/ship the vendor bundle; the apkeditor-merged apk is
						# redundant for morphe (it merges bundles natively) — drop it
						[ "$morphe_bundle_path" != "$stock_apk" ] && rm -f "$stock_apk"
						# drop leftover sidecars so only one file represents the bundle
						for _bx in xapk apkm apks; do
							[ -f "${stock_apk%.apk}.${_bx}" ] && [ "${stock_apk%.apk}.${_bx}" != "$morphe_bundle_path" ] && rm -f "${stock_apk%.apk}.${_bx}"
							[ -f "${stock_apk}.${_bx}" ] && [ "${stock_apk}.${_bx}" != "$morphe_bundle_path" ] && rm -f "${stock_apk}.${_bx}"
						done
						stock_apk="$morphe_bundle_path"
						all_apk=""
					fi
				fi
				# Publish the pristine file from staging into the cache dir under the arch
				# token its own bytes justify, atomically, adopting a sibling's identical copy
				# instead of writing a second one (_publish_stock_artifact). The build continues
				# from the cache path; all_apk is that same path only when it is the shared
				# "-all" key. If publishing fails (a full or unwritable cache dir) the staged
				# copy is still buildable, so the app is not dropped over the cache.
				local _PUB_APK="" _PUB_ALL="" _PUB_UPLOADED=""
				if [ -f "$stock_apk" ]; then
					if _publish_stock_artifact "$stock_apk" "$apk_cache_dir" "$pkg_name" \
						"$version_f" "$vc_infix" "$arch_f"; then
						stock_apk="$_PUB_APK"
						all_apk="$_PUB_ALL"
					else
						wpr "Could not publish the downloaded artifact for '$table' into ${apk_cache_dir}; building from the staged copy"
						all_apk=""
					fi
				fi

				if [ -f "$stock_apk" ] && [ -n "$_PUB_UPLOADED" ] && [ -n "${UPLOAD_APKS_REPO:-}" ] && [ "$dl_p" != "archive" ] && [ "$dl_p" != "cache_repo" ]; then
					pr "Uploading newly downloaded APKs to ${UPLOAD_APKS_REPO}..."
					local _ua_file="$stock_apk" _ua_ok="" _ua_att
					[ -n "$all_apk" ] && [ -f "$all_apk" ] && _ua_file="$all_apk"
					# Retry: with parallel builds a sibling process can create the same
					# release tag between our view (404) and create (422 tag exists);
					# the next attempt's view finds it. Upload races are transient too.
					#
					# The tag stays the package name - dl_cache_repo resolves an app by
					# `releases/tags/<pkg>` and matches assets by their own names, never by
					# this title - but the title is the label a person sees and searches in
					# the store, so it carries the app name, with the package name behind it.
					for _ua_att in 1 2 3; do
						if { gh release view "$pkg_name" --repo "$UPLOAD_APKS_REPO" >/dev/null 2>&1 || \
							gh release create "$pkg_name" --repo "$UPLOAD_APKS_REPO" \
								--title "${app_name:-$pkg_name}" --notes ""; } && \
							gh release upload "$pkg_name" "$_ua_file" --repo "$UPLOAD_APKS_REPO" --clobber; then
							_ua_ok=1
							break
						fi
						[ "$_ua_att" -lt 3 ] && { wpr "Cache upload for $pkg_name failed (attempt $_ua_att/3), retrying..."; sleep $((_ua_att * 3)); }
					done
					[ -n "$_ua_ok" ] || wpr "Failed to view/create/upload release $pkg_name on $UPLOAD_APKS_REPO after 3 attempts"
				fi
			else
				pr "Found APK in cache: ${stock_apk}. Skipping download!"
			fi
			if [ -n "$_apk_lock_held" ]; then exec 203>&-; fi
			if [ -f "$stock_apk" ]; then break; fi
		done
		if [ ! -f "$stock_apk" ]; then
			epr "ERROR: Could not download '${table}' for version ${version:-$resolved_version}"
			continue
		fi

		if [ -f "$stock_apk" ]; then
			final_stock_apk="$stock_apk"
			final_all_apk="${all_apk:-}"
			final_version="$version"
			break
		fi
	done

	stock_apk="$final_stock_apk"
	all_apk="$final_all_apk"
	version="$final_version"
	
	if [ ! -f "$stock_apk" ]; then
		if [ -z "$_dl_attempted" ] && [ -n "$_no_patch_versions" ]; then
			# Nothing was fetched: the patch set refused every supported version (or
			# annotated none for this arch). Reporting this as an exhausted download
			# asks a human to upload an APK that was never the problem.
			local _tried_versions
			_tried_versions=$(printf '%s' "${_no_patch_versions# }" | tr -s ' ' ',')
			epr "ERROR: No supported version of '${table}' has patches to apply from '${args[patches_src]:-${args[cli_source]:-}}' (tried: ${_tried_versions})."
			write_no_patches_failure_descriptor "$(failure_slug "$table")" "$table" \
				"$_tried_versions" \
				"${last_resolved_version:-${resolved_version:-$version_mode}}" "$(parse_arch_mapping "${args[version_code]:-}" "${arch_f:-}")" \
				"${arch_f:-}" "${args[patches_src]:-${args[cli_source]:-}}" "$pkg_name" \
				"${args[changelog_url]%% *}"
			return 0
		fi
		epr "ERROR: Could not download '${table}' after trying all supported versions."
		# This path used to be silent in the notification. The sources all responded and were
		# all tried, so it is not the "no valid download source" case above (which does record),
		# and build_rv skips with rc 0 here - so the parent runs _clear_failure_record, which
		# deletes <slug>.json and <slug>.log as a clean return, and temp/failures was empty by
		# the time the CI step looked (run 37964499217: Flipkart unbuilt on both arches, report
		# said "No failure records in temp/failures; nothing to report").
		# write_dl_failure_descriptor uses its own <slug>_dl.json name, which that clearing does
		# not touch, so the app now reaches the notify topic with the manual-upload hint.
		# Report the version that was actually resolved, not just 'resolved_version': for
		# a latest/auto app resolved_version stays empty even though the live source
		# answered with a concrete number, and version_label then blanks the placeholder
		# the notification would otherwise carry. 'version' has already been reset by the
		# loop's cleanup, so read the captured last_resolved_version.
		write_dl_failure_descriptor "$(failure_slug "$table")" "$table" \
			"${last_resolved_version:-${resolved_version:-$version_mode}}" \
			"$(parse_arch_mapping "${args[version_code]:-}" "${arch_f:-}")" \
			"${arch_f:-}" "$pkg_name"
		return 0
	fi

	# Ensure the mtime is set to now so newly downloaded APKs with old server timestamps aren't purged
	touch "$stock_apk" 2>/dev/null || true
	[ -f "${stock_apk%.apk}.apkm" ] && touch "${stock_apk%.apk}.apkm" 2>/dev/null || true
	[ -n "${all_apk:-}" ] && [ -f "$all_apk" ] && touch "$all_apk" 2>/dev/null || true

	# Log usage for the apks repo cache tracker. The key is "<pkg>-<version>" and
	# must NOT carry the target versionCode: cleanup-apks.py derives its key by
	# stripping (-[0-9]+)?-(<arch>).(<ext>) off the stored filename, so the optional
	# numeric group removes the version code deliberately and every ABI/artifact of
	# one app version shares a single usage stamp. Appending ${vc_infix} here - which
	# looks like it "matches the filename" - untracks those versions instead: the key
	# is never matched, the version falls back to aging out by upload time, and the
	# phantom key is pruned as a ghost entry. See docs/cache-repo.md.
	echo "${pkg_name}-${version_f}" >> "$TEMP_DIR/used_versions.txt"

	local sig_op
	if _bundle_ext_of "$stock_apk" >/dev/null 2>&1; then
		local tmpb="${TEMP_DIR}/stockcheck_base_$$.apk"
		if ! _bundle_extract_base "$stock_apk" "$tmpb"; then
			epr "Cannot extract base.apk from bundle $stock_apk"
			rm -f "$tmpb"
			return 0
		fi
		if ! sig_op=$(check_sig "$tmpb" "$pkg_name" 2>&1); then
			epr "Not building $table, apk signature mismatch 'base.apk' in $stock_apk: $sig_op"
			rm -f "$tmpb"
			return 0
		fi
		rm -f "$tmpb"
	elif [ -f "${stock_apk%.apk}.apkm" ]; then
		rm -rf "${stock_apk}-zip" || :
		unzip -j "${stock_apk%.apk}.apkm" -d "${stock_apk}-zip" >/dev/null
		if [ -f "${stock_apk}-zip/base.apk" ]; then
			if ! sig_op=$(check_sig "${stock_apk}-zip/base.apk" "$pkg_name" 2>&1); then
				epr "Not building $table, apk signature mismatch 'base.apk': $sig_op"
				return 0
			fi
		else
			for a in "${stock_apk}"-zip/*.apk; do
				if ! sig_op=$(check_sig "$a" "$pkg_name" 2>&1); then
					epr "Not building $table, apk signature mismatch '$a': $sig_op"
					return 0
				fi
				break # Only check one APK if no base.apk
			done
		fi
		rm -rf "${stock_apk}-zip" || :
	else
		if ! sig_op=$(check_sig "$stock_apk" "$pkg_name" 2>&1); then
			epr "Not building $table, apk signature mismatch '$stock_apk': $sig_op"
			return 0
		fi
	fi

	local microg_patches=()
	local microg_default_enabled=()
	while IFS=$'\t' read -r p_name p_enabled; do
		[ -z "$p_name" ] && continue
		microg_patches+=("$p_name")
		microg_default_enabled+=("$p_enabled")
	done < <(awk '
		BEGIN { RS=""; FS="\n" }
		{
			pname = ""
			enabled = ""
			for (i=1; i<=NF; i++) {
				if ($i ~ /^Name: /) {
					pname = substr($i, 7)
					gsub(/\r/, "", pname)
				}
				if ($i ~ /^Enabled: /) {
					enabled = substr($i, 10)
					gsub(/\r/, "", enabled)
				}
			}
			if (tolower(pname) ~ /gmscore|microg/) {
				print pname "\t" (enabled == "true" ? "true" : "false")
			}
		}
	' <<<"$list_patches")

	local patcher_args patched_apk build_mode
	local brand_val="${args[brand]:-}"
	local brand_slug=""
	[ -n "$brand_val" ] && brand_slug=$(resolve_slug "$brand_val")

	local variant_val="${args[variant]:-}"
	local variant_slug=""
	[ -n "$variant_val" ] && variant_slug=$(resolve_slug "$variant_val")

	local sub_variant_val="${args[sub_variant]:-}"
	local sub_variant_slug=""
	[ -n "$sub_variant_val" ] && sub_variant_slug=$(resolve_slug "$sub_variant_val")

	local file_prefix="${app_name_l}"
	[ -n "$brand_slug" ] && file_prefix+="-${brand_slug}"
	[ -n "$variant_slug" ] && [ "$variant_slug" != "default" ] && file_prefix+="-${variant_slug}"
	[ -n "$sub_variant_slug" ] && file_prefix+="-${sub_variant_slug}"

	local patches_ref="${args[patches_ref]}"
	local changelog_url="${args[changelog_url]}"
	if [ "${args[patcher_args]}" ]; then p_patcher_args+=("${args[patcher_args]}"); fi
	for build_mode in "${build_mode_arr[@]}"; do
		patcher_args=("${p_patcher_args[@]}")
		local -a cur_per_bundle_ed_args=("${per_bundle_ed_args[@]}")
		pr "Building '${table}' in '$build_mode' mode"
		if [ ${#microg_patches[@]} -gt 0 ] || [ ${#build_mode_arr[@]} -gt 1 ]; then
			patched_apk="${TEMP_DIR}/${file_prefix}-${version_f}-${arch_f}-${build_mode}.apk"
		else
			patched_apk="${TEMP_DIR}/${file_prefix}-${version_f}-${arch_f}.apk"
		fi
		if [ ${#microg_patches[@]} -gt 0 ]; then
			for idx in "${!microg_patches[@]}"; do
				local p="${microg_patches[$idx]}"
				local is_def_enabled="${microg_default_enabled[$idx]}"
				if [ "$build_mode" = apk ]; then
					if [ "$is_def_enabled" = "true" ]; then
						for ((bi=0; bi<n_bundles; bi++)); do
							if [[ "${cur_per_bundle_ed_args[$bi]}" != *"-d \"$p\""* && \
							      "${cur_per_bundle_ed_args[$bi]}" != *"-d '$p'"* && \
							      "${cur_per_bundle_ed_args[$bi]}" != *"-d $p"* && \
							      "${cur_per_bundle_ed_args[$bi]}" != *"-e \"$p\""* && \
							      "${cur_per_bundle_ed_args[$bi]}" != *"-e '$p'"* && \
							      "${cur_per_bundle_ed_args[$bi]}" != *"-e $p"* ]]; then
								cur_per_bundle_ed_args[$bi]+=" -e \"$p\""
							fi
						done
					fi
				elif [ "$build_mode" = module ]; then
					patcher_args=("${patcher_args[@]//-[ei] \'$p\'/}")
					patcher_args=("${patcher_args[@]//-[ei] \"$p\"/}")
					patcher_args=("${patcher_args[@]//-[ei] $p/}")
					for ((bi=0; bi<n_bundles; bi++)); do
						cur_per_bundle_ed_args[$bi]="${cur_per_bundle_ed_args[$bi]//-e \'$p\'/}"
						cur_per_bundle_ed_args[$bi]="${cur_per_bundle_ed_args[$bi]//-e \"$p\"/}"
						cur_per_bundle_ed_args[$bi]="${cur_per_bundle_ed_args[$bi]//-e $p/}"
						if [[ "${cur_per_bundle_ed_args[$bi]}" != *"-d \"$p\""* && \
						      "${cur_per_bundle_ed_args[$bi]}" != *"-d '$p'"* && \
						      "${cur_per_bundle_ed_args[$bi]}" != *"-d $p"* ]]; then
							cur_per_bundle_ed_args[$bi]+=" -d \"$p\""
						fi
					done
				fi
			done
		fi
		if [ "$build_mode" = module ] && [ -n "$PATCHER_MOUNT_ARG" ]; then
			patcher_args+=("$PATCHER_MOUNT_ARG")
		fi

		local stock_apk_to_patch
		local _pt_bext=""
		if [ -n "$morphe_bundle_path" ] || _pt_bext=$(_bundle_ext_of "$stock_apk"); then
			# morphe passthrough input: trim the bundle's config members to the
			# target arch (no apkeditor, no re-sign); "all" ships the raw bundle.
			[ -z "$_pt_bext" ] && _pt_bext=xapk
			stock_apk_to_patch="${TEMP_DIR}/${file_prefix}-${version_f}-${arch_f}.stripped.${_pt_bext}"
			if [ ! -f "$stock_apk_to_patch" ]; then
				if [ "$arch_f" = "all" ] || [ "$arch_f" = "universal" ]; then
					cp -f "$stock_apk" "$stock_apk_to_patch"
				else
					_trim_bundle_for_arch "$stock_apk" "$stock_apk_to_patch" "$arch_f" || {
						epr "Failed to trim bundle for $arch_f"
						rm -f "$stock_apk_to_patch"
						return 0
					}
				fi
			fi
		else
			stock_apk_to_patch="${TEMP_DIR}/${file_prefix}-${version_f}-${arch_f}.stripped.apk"
			if [ ! -f "$stock_apk_to_patch" ]; then
				if _patcher_strips_libs; then
					# The name says "stripped", the bytes must not be: the patcher filters the
					# ABIs at output assembly from the same keep-list, and rewriting the archive
					# here would only cost it the signing block the stock apk was signed with.
					if ! cp -f "$stock_apk" "$stock_apk_to_patch"; then
						epr "Failed to stage stock apk for $arch_f"
						rm -f "$stock_apk_to_patch"
						return 0
					fi
				elif ! _strip_apk_abis "$stock_apk" "$stock_apk_to_patch" "$arch_f"; then
					epr "Failed to strip foreign ABIs for $arch_f"
					rm -f "$stock_apk_to_patch"
					return 0
				fi
			fi
		fi

		# The other half of that one decision, and the only strip a morphe build of a plain
		# APK gets: the flag states the same keep-list at output assembly, which is also the
		# only thing that reaches a bundle's base.apk libs or a lib/<dir> that names no ABI -
		# neither of which _strip_apk_abis or the member trim can touch.
		if _patcher_strips_libs; then
			patcher_args+=("--striplibs" "$(_striplibs_keep_of_arch "$arch_f")")
		fi

		local per_bundle_ed_joined=""
		for ((bi=0; bi<n_bundles; bi++)); do
			[ $bi -gt 0 ] && per_bundle_ed_joined+="|"
			per_bundle_ed_joined+="${cur_per_bundle_ed_args[$bi]}"
		done

		local apk_output="${BUILD_DIR}/${file_prefix}-v${version_f}-${arch_f}.apk"
		if [ "${NORB:-}" != true ] || { [ ! -f "$patched_apk" ] && [ ! -f "$apk_output" ]; }; then
			if ! patch_apk "$stock_apk_to_patch" "$patched_apk" "${patcher_args[*]}" "${args[cli]}" "${args[ptjar]}" "${args[cli_source]}" "$per_bundle_ed_joined"; then
				epr "Building '${table}' failed!"
				# rc 0 keeps the per-app fail-soft, but it also made this failure
				# invisible to the report: the parent reads the clean return as
				# success and deletes <slug>.json/<slug>.log (run 39199799796:
				# TikTok-hushfeed aborted on both arches, nothing notified). The
				# _pf survivor pair is what the CI step and the retry writer read;
				# the parent moves the captured log onto <slug>_pf.log.
				write_patch_failure_record "$(failure_slug "$table")" "$table" "$version_f" \
					"$(parse_arch_mapping "${args[version_code]:-}" "$arch_f")" \
					"$arch_f" "${args[patches_src]:-${args[cli_source]:-}}"
				return 0
			fi
		fi

		# Duplicate-build verdict on the first patched APK of this table build.
		# Owner premise: apk- and module-mode patching of one app differ only in
		# microG handling, so the apk-mode APK (or the module APK when module is
		# the only mode) is a valid fingerprint for every artifact this app+arch
		# would publish; on a match the module stage is never patched or packed.
		# NORB reuse can leave the fresh bytes only in $apk_output, so hash
		# whichever file this iteration just produced.
		if [ "$build_mode" = apk ] || [ ${#build_mode_arr[@]} -eq 1 ]; then
			local _dedup_apk="$patched_apk"
			[ -f "$_dedup_apk" ] || _dedup_apk="$apk_output"
			if [ -f "$_dedup_apk" ] &&
				check_duplicate_build "$_dedup_apk" "${file_prefix}-v${version_f}-${arch_f}" \
					"$table" "$app_name" "$version_f" "$arch_f" "${build_mode_arr[*]}"; then
				# rc 0 is the skip itself: nothing copied to BUILD_DIR, no
				# write_build_info fragment, notes and manifest stay truthful.
				# The content is published, so a patcher abort earlier in this
				# same child (e.g. apk mode failed, module mode shipped the
				# bytes) must not re-queue or re-report this app+arch.
				clear_patch_failure_record "$(failure_slug "$table")"
				return 0
			fi
		fi

		local final_pkg_name="${args[patched_pkg_name]:-}"
		if [ -z "$final_pkg_name" ]; then
			local target_apk_to_check=""
			[ -f "$patched_apk" ] && target_apk_to_check="$patched_apk"
			[ -z "$target_apk_to_check" ] && [ -f "$apk_output" ] && target_apk_to_check="$apk_output"

			if [ -n "$target_apk_to_check" ]; then
				local aapt_tool=""
				if [ -n "${AAPT2:-}" ] && { [ -x "$AAPT2" ] || command -v "$AAPT2" >/dev/null 2>&1; }; then
					aapt_tool="$AAPT2"
				elif command -v aapt2 >/dev/null 2>&1; then
					aapt_tool="aapt2"
				elif command -v aapt >/dev/null 2>&1; then
					aapt_tool="aapt"
				fi

				if [ -n "$aapt_tool" ]; then
					local detected_pkg=""
					if [[ "$aapt_tool" == *"aapt2"* ]]; then
						detected_pkg=$("$aapt_tool" dump packagename "$target_apk_to_check" 2>/dev/null | tr -d '\r\n' || true)
					fi
					[ -z "$detected_pkg" ] && detected_pkg=$("$aapt_tool" dump badging "$target_apk_to_check" 2>/dev/null | grep -oP "package: name='\K[^']+" | head -1 || true)
					if [ -n "$detected_pkg" ]; then
						if [ "$detected_pkg" != "$pkg_name" ]; then
							pr "Detected modified package ID in manifest: '$pkg_name' -> '$detected_pkg'"
						fi
						final_pkg_name="$detected_pkg"
					fi
				fi
			fi
		fi
		final_pkg_name="${final_pkg_name:-$pkg_name}"

		if [ "$build_mode" = apk ]; then
			if [ "${NORB:-}" != true ] || { [ ! -f "$patched_apk" ] && [ ! -f "$apk_output" ]; }; then
				mv -f "$patched_apk" "$apk_output"
			else
				cp -f "$patched_apk" "$apk_output"
			fi
			pr "Built ${table} (non-root): '${apk_output}'"
			write_build_info "${table% (*}" "${arch_f}" ".apk" "${file_prefix}" "$version_f" "$patches_ref" "$changelog_url" "$final_pkg_name" "${app_name}" "${args[patches_src]}" "${brand_val}" "${variant_val}" "${sub_variant_val}"
			continue
		fi
		local base_template
		base_template=$(mktemp -d -p "$TEMP_DIR")
		cp -a $MODULE_TEMPLATE_DIR/. "$base_template"
		local upj
		upj=$(update_json_path "${args[module_prop_name]}" "${DEF_AUTHOR_NAME:-nullcpy}")

		module_config "$base_template" "$final_pkg_name" "$version_f" "$arch"

		local patches_ver
		patches_ver="${patches_jar%% *}"; patches_ver="${patches_ver##*-}"
		local brand_display="${args[brand]:-}"
		[ -n "${args[variant]:-}" ] && [ "${args[variant]}" != "Default" ] && brand_display+=" ${args[variant]}"
		[ -n "${args[sub_variant]:-}" ] && brand_display+=" ${args[sub_variant]}"
		brand_display="${brand_display#" "}"
		module_prop \
			"${args[module_prop_name]}" \
			"${app_name} ${brand_display}" \
			"${version_f} (patches ${patches_ver})" \
			"${DEF_AUTHOR_NAME:-nullcpy}" \
			"${app_name} ${brand_display} module" \
			"https://raw.githubusercontent.com/${GITHUB_REPOSITORY-}/update/${upj}" \
			"$base_template"

		local module_output="${file_prefix}-module-v${version_f}-${arch_f}.zip"
		pr "Packing module ${table}"
		cp -f "$patched_apk" "${base_template}/base.apk"

		if [ "${args[include_stock]}" != "disable" ]; then
			mkdir -p "${base_template}/stock/"
			local _stk_bext=""
			_bundle_ext_of "$stock_apk" >/dev/null 2>&1 && _stk_bext=1
			if [ "${args[include_stock]}" = "merged" ]; then
				if [ -n "$_stk_bext" ]; then
					# module needs a real merged apk for stock; merge from the
					# cached bundle on demand (throwaway, never cached)
					local _mod_stock="${TEMP_DIR}/${file_prefix}-${version_f}-stock-merged.apk"
					merge_splits "$stock_apk" "$_mod_stock" >/dev/null 2>&1 || {
						epr "Failed to merge bundle for module stock"
						return 0
					}
					cp -f "$_mod_stock" "${base_template}/stock/base.apk"
					rm -f "$_mod_stock"
				else
					cp -f "$stock_apk" "${base_template}/stock/base.apk"
				fi
			elif [ "${args[include_stock]}" = "split" ]; then
				local _split_src=""
				if [ -n "$_stk_bext" ]; then _split_src="$stock_apk"
				elif [ -f "${stock_apk%.apk}.apkm" ]; then _split_src="${stock_apk%.apk}.apkm"
				elif [ -f "${stock_apk}.apkm" ]; then _split_src="${stock_apk}.apkm"
				fi
				if [ -z "$_split_src" ]; then
					epr "Cannot include as 'split' because stock apk of $table_name is not a bundle"
					return 0
				fi
				if [ "$arch" = "arm64-v8a" ]; then
					unzip -j "$_split_src" '*.apk' -x '*x86_64.apk' -x '*x86.apk' -x '*armeabi_v7a.apk' -d "${base_template}/stock/" >/dev/null 2>&1
				elif [ "$arch" = "arm-v7a" ]; then
					unzip -j "$_split_src" '*.apk' -x '*x86_64.apk' -x '*x86.apk' -x '*arm64_v8a.apk' -d "${base_template}/stock/" >/dev/null 2>&1
				elif [ "$arch" = "x86" ]; then
					unzip -j "$_split_src" '*.apk' -x '*x86_64.apk' -x '*arm64_v8a.apk' -x '*armeabi_v7a.apk' -d "${base_template}/stock/" >/dev/null 2>&1
				elif [ "$arch" = "x86_64" ]; then
					unzip -j "$_split_src" '*.apk' -x '*x86.apk' -x '*arm64_v8a.apk' -x '*armeabi_v7a.apk' -d "${base_template}/stock/" >/dev/null 2>&1
				else
					unzip -j "$_split_src" '*.apk' -x '*x86_64.apk' -x '*x86.apk' -d "${base_template}/stock/" >/dev/null 2>&1
				fi
			fi
		fi

		pushd >/dev/null "$base_template" || abort "Module template dir not found"
		zip -"$COMPRESSION_LEVEL" -FSqr "${CWD}/${BUILD_DIR}/${module_output}" .
		popd >/dev/null || :
		pr "Built ${table} (root): '${BUILD_DIR}/${module_output}'"
		write_build_info "${table% (*}" "${arch_f}" ".zip" "${file_prefix}" "$version_f" "$patches_ref" "$changelog_url" "$final_pkg_name" "${app_name}" "${args[patches_src]}" "${brand_val}" "${variant_val}" "${sub_variant_val}"
	done
}

list_args() { tr -d '\t\r' <<<"$1" | tr -s ' ' | sed "s/' '/'\\n'/g" | sed 's/" "/"\n"/g' | sed 's/\([^"]\)"\([^"]\)/\1'\''\2/g' | grep -v '^$' || :; }
# Read back the words join_args produced ("-e 'a' -e 'b c'") as raw patch names, one
# per line. Needed wherever code wants the NAMES rather than the command words: the
# Instafel branch of patch_apk used to grep quoted spans out of the same string
# (grep -oE "['\"][^'\"]+['\"]"), which misreads the backslash-quote escape join_args
# emits for a name like "Keep the screen's refresh rate", handing Instafel a truncated
# patch name.
# Letting the shell re-parse is the only correct reader, since it resolves the escaping
# instead of trying to second-guess it. Flag words are skipped; -e and -d names are
# both returned, which is what the previous scrape did and what the Instafel caller
# has always passed on.
_ed_names() { # $1=ed string as join_args built it
	local IFS=$' \t\n' w
	eval "set -- $1" || return 1
	for w in "$@"; do
		case "$w" in -e | -d) continue ;; esac
		printf '%s\n' "$w"
	done
}
# Turn a group string ("'A' 'B'", the shape included-patches/excluded-patches hold)
# into "<flag> '<name>'" words. This is the one place patch names get shell-quoted:
# the result is interpolated into a command string that build_rv evals, so a name
# carrying an apostrophe - hushfeed ships "Keep the screen's refresh rate" - would
# otherwise leave an unbalanced quote there, failing the run with "unexpected EOF
# while looking for matching quote" or, with an even number of strays, silently
# splitting one name into several CLI arguments. Escaping exactly one layer of
# wrapper quotes also means hand-written and inclusive selections behave the same.
join_args() {
	local n
	list_args "$1" | while IFS= read -r n; do
		n=${n#\'}; n=${n%\'}; n=${n#\"}; n=${n%\"}
		[ -z "$n" ] && continue
		printf "%s '%s'\n" "$2" "$(printf '%s' "$n" | sed "s/'/'\\\\''/g")"
	done | paste -sd " " - || :
}

module_config() {
	local ma=""
	if [ "$4" = "arm64-v8a" ]; then
		ma="arm64"
	elif [ "$4" = "arm-v7a" ]; then
		ma="arm"
	fi
	echo "PKG_NAME=$2
PKG_VER=$3
MODULE_ARCH=$ma" >"$1/config"
}

# Map a module id (module_prop_name) to its update-branch JSON path:
#   <channel>/<id-without-author-or-channel-suffix>.json
# The channel folder (stable|beta) replaces the old "-beta-" filename infix,
# and the author segment is dropped since it's constant for this repo.
# Module id shape from build.sh: <table>-<author>[-beta][-arm64|-arm].
# This path is a wire format baked into every module zip via module.prop
# updateJson — changing it orphans installed modules; never restructure
# the branch to "tidy" it.
update_json_path() {
	local mpn=${1,,} author=${2,,} chan=stable arch=""
	case $mpn in
		*-arm64) arch="-arm64"; mpn=${mpn%-arm64} ;;
		*-arm) arch="-arm"; mpn=${mpn%-arm} ;;
	esac
	if [[ $mpn == *-beta ]]; then
		chan="beta"
		mpn=${mpn%-beta}
	fi
	[ -n "$author" ] && mpn=${mpn%-$author}
	echo "$chan/${mpn}${arch}.json"
}

module_prop() {
	echo "id=${1}
name=${2}
version=v${3}
versionCode=${NEXT_VER_CODE}
author=${4}
description=${5}" >"${7}/module.prop"

	if [ "$ENABLE_MODULE_UPDATE" = true ]; then echo "updateJson=${6}" >>"${7}/module.prop"; fi
}
