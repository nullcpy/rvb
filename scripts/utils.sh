#!/usr/bin/env bash

MODULE_TEMPLATE_DIR="module"
CWD=$(pwd)
TEMP_DIR="temp"
BIN_DIR="bin"
BUILD_DIR="build"
DL_SRCS=("cache_repo" "direct" "github" "archive" "apkmirror" "uptodown" "apkpure" "apkcombo")
BUILD_JSON_FILE="build.json"
PATCH_OUTPUT=""

if [ -z "${GITHUB_TOKEN-}" ] && command -v gh >/dev/null 2>&1; then
	GITHUB_TOKEN=$(gh auth token 2>/dev/null || true)
fi
if [ "${GITHUB_TOKEN-}" ]; then GH_HEADER="Authorization: token ${GITHUB_TOKEN}"; else GH_HEADER=; fi
NEXT_VER_CODE=${NEXT_VER_CODE:-$(date +'%Y%m%d')}
OS=$(uname -o)
DEFAULT_UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/133.0.0.0 Safari/537.36"

# Signing identity — overridable from CI (secrets written to these files/vars
# by build.yml); defaults preserve the upstream keystore in the repo.
RVB_KEYSTORE="${RVB_KEYSTORE:-ks.keystore}"
RVB_KEYSTORE_P12="${RVB_KEYSTORE_P12:-ks-p12.keystore}"
RVB_KEYSTORE_PASS="${RVB_KEYSTORE_PASS:-123456789}"
RVB_KEY_ALIAS="${RVB_KEY_ALIAS:-jhc}"

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

declare -gA __PREBUILTS_CACHE__
declare -gA __PATCHES_LIST_CACHE__
declare -gA __PATCH_VER_CACHE__
declare -gA __PKG_VERS_CACHE__
declare -gA __DL_RESP_CACHE__

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
java() { env -i PATH="$PATH" HOME="$HOME" LANG="${LANG:-en_US.UTF-8}" java --enable-native-access=ALL-UNNAMED "$@"; }

source_release_api_base() {
	local host=${1,,} src=$2 encoded
	case "$host" in
		github) echo "https://api.github.com/repos/${src}/releases" ;;
		gitlab)
			encoded=$(jq -nr --arg v "$src" '$v | @uri')
			echo "https://gitlab.com/api/v4/projects/${encoded}/releases"
			;;
		*) return 1 ;;
	esac
}

source_release_tag_api() {
	local host=${1,,} src=$2 tag=$3 base
	base=$(source_release_api_base "$host" "$src") || return 1
	case "$host" in
		github) echo "${base}/tags/${tag}" ;;
		gitlab) echo "${base}/${tag}" ;;
		*) return 1 ;;
	esac
}

source_release_assets_json() {
	local host=${1,,}
	case "$host" in
		github) jq -e '[.assets[]? | select(.name | (endswith("asc") or endswith("json")) | not)]' ;;
		gitlab) jq -e '[.assets.links[]? | select(.name | (endswith("asc") or endswith("json")) | not)]' ;;
		*) return 1 ;;
	esac
}

source_release_asset_url() {
	local host=${1,,}
	case "$host" in
		github) jq -r '.url' ;;
		gitlab) jq -r '.direct_asset_url // .url' ;;
		*) return 1 ;;
	esac
}

source_release_pick_from_list() {
	local host=${1,,} mode=$2
	case "$host" in
		github)
			if [ "$mode" = dev ] || [ "$mode" = beta ]; then
				jq -e -c 'map(select(.prerelease == true and .tag_name != null and .tag_name != "")) | sort_by(.published_at // .created_at // "") | reverse | .[0] // empty'
			else
				jq -e -c 'map(select(.prerelease != true and .tag_name != null and .tag_name != "")) | sort_by(.published_at // .created_at // "") | reverse | .[0] // empty'
			fi
			;;
		gitlab)
			if [ "$mode" = dev ] || [ "$mode" = beta ]; then
				jq -e -c 'map(select(.tag_name != null and .tag_name != "" and (.tag_name | test("(?i)(dev|alpha|beta|rc)")))) | sort_by(.released_at // .created_at // "") | reverse | .[0] // empty'
			else
				jq -e -c 'map(select(.tag_name != null and .tag_name != "" and (.tag_name | test("(?i)(dev|alpha|beta|rc)") | not))) | sort_by(.released_at // .created_at // "") | reverse | .[0] // empty'
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

get_prebuilts() {
	local cache_key="${1}_${2}_${3}_${4}_${5}_${6}"
	if [ -n "${__PREBUILTS_CACHE__["$cache_key"]:-}" ]; then
		echo "${__PREBUILTS_CACHE__["$cache_key"]}"
		return 0
	fi
	local result
	if ! result=$(_get_prebuilts "$@"); then return 1; fi
	__PREBUILTS_CACHE__["$cache_key"]="$result"
	echo "$result"
}

_get_prebuilts() {
	local cli_host=$1 cli_src=$2 cli_ver=$3 patches_host_list=$4 patches_src_list=$5 patches_ver_list=$6
	resolve_patcher "$cli_src"
	
	local first_patch_src
	first_patch_src=$(list_args "$patches_src_list" | tr -d \"\' | head -n 1)
	pr "Getting prebuilts (${first_patch_src%/*})" >&2

	local cl_dir=${first_patch_src%/*}
	cl_dir=${TEMP_DIR}/${cl_dir,,}-rv
	[ -d "$cl_dir" ] || mkdir "$cl_dir"

	local host=$cli_host src=$cli_src tag="CLI" ver=${cli_ver} fprefix="cli"
	host=${host,,}
	if ! isoneof "$host" github gitlab; then abort "source host '$host' is not supported"; fi

	local grab_cl=false
	local dir=${src%/*}
	dir=${TEMP_DIR}/${dir,,}-rv
	[ -d "$dir" ] || mkdir "$dir"

	local rv_rel release resp tag_name matches asset name url
	rv_rel=$(source_release_api_base "$host" "$src") || return 1
	if [ "$ver" = "beta" ] || [ "$ver" = "dev" ]; then
		resp=$({ if [ "$host" = github ]; then gh_req "$rv_rel?per_page=100" -; else req "$rv_rel?per_page=100" -; fi; }) || return 1
		release=$(source_release_pick_from_list "$host" beta <<<"$resp") || true
		ver=$(jq -r '.tag_name' <<<"$release") || true
		if [ -z "$ver" ] || [ "$ver" = "null" ]; then
			ver=$(jq -e -r '.[].tag_name' <<<"$resp" | get_highest_ver) || return 1
			release="" # Clear release if we had to fallback to get_highest_ver
		fi
	fi
	if [ "$ver" = "stable" ] || [ "$ver" = "latest" ]; then
		resp=$({ if [ "$host" = github ]; then gh_req "$rv_rel?per_page=100" -; else req "$rv_rel?per_page=100" -; fi; }) || return 1
		release=$(source_release_pick_from_list "$host" stable <<<"$resp") || return 1
	elif [ -z "${release:-}" ]; then
		rv_rel=$(source_release_tag_api "$host" "$src" "$ver") || return 1
		release=$({ if [ "$host" = github ]; then gh_req "$rv_rel" -; else req "$rv_rel" -; fi; }) || return 1
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
		if ! isoneof "$host" github gitlab; then abort "source host '$host' is not supported"; fi
		local tag="Patches" fprefix="patches"
		local grab_cl=true
		
		local dir=${src%/*}
		dir=${TEMP_DIR}/${dir,,}-rv
		[ -d "$dir" ] || mkdir "$dir"
		
		local rv_rel release resp tag_name matches asset name url
		rv_rel=$(source_release_api_base "$host" "$src") || return 1
		if [ "$ver" = "beta" ] || [ "$ver" = "dev" ]; then
			resp=$({ if [ "$host" = github ]; then gh_req "$rv_rel?per_page=100" -; else req "$rv_rel?per_page=100" -; fi; }) || return 1
			release=$(source_release_pick_from_list "$host" beta <<<"$resp") || true
			ver=$(jq -r '.tag_name' <<<"$release") || true
			if [ -z "$ver" ] || [ "$ver" = "null" ]; then
				ver=$(jq -e -r '.[].tag_name' <<<"$resp" | get_highest_ver) || return 1
				release="" # Clear release if we had to fallback to get_highest_ver
			fi
		fi
		if [ "$ver" = "stable" ] || [ "$ver" = "latest" ]; then
			resp=$({ if [ "$host" = github ]; then gh_req "$rv_rel?per_page=100" -; else req "$rv_rel?per_page=100" -; fi; }) || return 1
			release=$(source_release_pick_from_list "$host" stable <<<"$resp") || return 1
		elif [ -z "${release:-}" ]; then
			rv_rel=$(source_release_tag_api "$host" "$src" "$ver") || return 1
			release=$({ if [ "$host" = github ]; then gh_req "$rv_rel" -; else req "$rv_rel" -; fi; }) || return 1
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

		if [ "$grab_cl" = true ]; then
			if [ "$host" = github ]; then
				echo -e "[Changelog](https://github.com/${src}/releases/tag/${tag_name})\n" >>"${cl_dir}/changelog.md"
			else
				echo -e "[Changelog](https://gitlab.com/${src}/-/releases/${tag_name})\n" >>"${cl_dir}/changelog.md"
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
		if ! op=$(awk '{$1=$1}1' <<<"$list_patches"); then
			epr "list-patches: '$op'"
			return 1
		fi
		local ver vers="" NL=$'\n'
		while IFS= read -r line; do
			line="${line:1:${#line}-2}"
			ver=$(sed -n "/^Name: $line\$/,/^\$/p" <<<"$op" | sed -n "/^Compatible versions:\$/,/^\$/p" | tail -n +2 | sed 's/ \[.*//')
			vers="${vers}${ver}${NL}"
		done <<<"$(list_args "$inc_sel")"
		vers=$(awk '{$1=$1}1' <<<"$vers")
		if [ -n "$vers" ]; then
			echo "$vers" | tr ' ' '\n' | sort | uniq -c | sort -k1,1nr | awk '
				NR==1 { max=$1; print $2; next }
				$1==max { print $2 }
			' | sort_vers
			return
		fi
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
	local abi=""
	case "${arch,,}" in
		arm64-v8a|arm64) abi="ARM64_V8A" ;;
		arm-v7a|armeabi-v7a|arm) abi="ARMEABI_V7A" ;;
		x86_64) abi="X86_64" ;;
		x86) abi="X86" ;;
	esac

	local line="" l
	while IFS= read -r l; do
		if [[ "$l" =~ ^[[:space:]]*${version//./\\.}[[:space:]] ]]; then
			line="$l"
			break
		fi
	done <<<"$raw_op"

	if [[ "$line" =~ \[versionCodes:[[:space:]]*([^]]+)\] ]]; then
		local vcodes="${BASH_REMATCH[1]}"
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
	local old_ifs="$IFS"
	IFS='|'
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
	IFS="$old_ifs"
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
		fi
	fi
	echo "$target"
}

# Discover the cached APK for one pkg/arch at a resolved version (build_rv
# cache checks). $1=stripped version (paths), $2=arch, $3=raw version for
# versionCode metadata lookup (defaults to $1 — the pre-refactor code used
# version_f in filenames but the unstripped resolved_version in
# get_patch_version_code). Populates: _CACHE_VC, _CACHE_CHECK_APK (path or
# empty), _CACHE_ALL_APK (non-legacy "all" candidate, used by validation
# delete check).
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
		local bx
		for bx in xapk apkm apks; do
			local bpath="${apk_cache_dir}/${pkg_name}-${ver}${vc_infix}-all.${bx}"
			if [ -f "$bpath" ]; then check_apk="$bpath"; all_apk="$bpath"; break; fi
		done
	fi
	if [ -z "$check_apk" ] && [ -n "$vc" ]; then
		local legacy_stock="${apk_cache_dir}/${pkg_name}-${ver}-${arch}.apk"
		local legacy_all="${apk_cache_dir}/${pkg_name}-${ver}-all.apk"
		[ -f "$legacy_stock" ] && check_apk="$legacy_stock"
		[ -z "$check_apk" ] && [ -f "$legacy_all" ] && check_apk="$legacy_all"
	fi
	_CACHE_VC="$vc"
	_CACHE_CHECK_APK="$check_apk"
	_CACHE_ALL_APK="$all_apk"
}


# Refresh mtimes on all cached variants for one pkg/arch/version (exact, all,
# and the two legacy names).
_cache_touch_apks() {
	local ver=$1 arch=$2
	local vc; vc=$(_cache_target_vc "$ver" "$arch")
	local vc_infix="${vc:+-$vc}"
	local f
	for f in "${apk_cache_dir}/${pkg_name}-${ver}${vc_infix}-${arch}.apk" \
		"${apk_cache_dir}/${pkg_name}-${ver}${vc_infix}-all.apk" \
		"${apk_cache_dir}/${pkg_name}-${ver}${vc_infix}-all.xapk" \
		"${apk_cache_dir}/${pkg_name}-${ver}${vc_infix}-all.apkm" \
		"${apk_cache_dir}/${pkg_name}-${ver}${vc_infix}-all.apks" \
		"${apk_cache_dir}/${pkg_name}-${ver}-${arch}.apk" \
		"${apk_cache_dir}/${pkg_name}-${ver}-all.apk"; do
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
_instafel_shadow_core() {
	local cli_jar=$1 patches_jar=$2; shift 2
	local -a extra_dirs=("$@")
	local cli_dir cli_commit d j j_base
	cli_dir=$(dirname "$cli_jar")
	cli_commit=$(unzip -p "$cli_jar" META-INF/MANIFEST.MF 2>/dev/null | sed -n 's/^Patcher-Cli-Commit: //p' | tr -d '\r')
	[ -z "$cli_commit" ] && cli_commit="$RVB_INSTAFEL_FALLBACK_COMMIT"
	for j in $(echo "$patches_jar" | tr ' ' '\n' | grep -v '^$'); do
		j_base=$(basename "$j")
		cp "$j" "$cli_dir/$j_base" 2>/dev/null || :
		cp "$j" "$j_base" 2>/dev/null || :
		for d in "${extra_dirs[@]}"; do cp "$j" "$d/$j_base" 2>/dev/null || :; done
		cp "$j" "$cli_dir/ifl-patcher-core-${cli_commit}.jar" 2>/dev/null || :
		cp "$j" "ifl-patcher-core-${cli_commit}.jar" 2>/dev/null || :
		for d in "${extra_dirs[@]}"; do cp "$j" "$d/ifl-patcher-core-${cli_commit}.jar" 2>/dev/null || :; done
		if [ "$cli_commit" != "$RVB_INSTAFEL_FALLBACK_COMMIT" ]; then
			cp "$j" "$cli_dir/ifl-patcher-core-${RVB_INSTAFEL_FALLBACK_COMMIT}.jar" 2>/dev/null || :
			cp "$j" "ifl-patcher-core-${RVB_INSTAFEL_FALLBACK_COMMIT}.jar" 2>/dev/null || :
			for d in "${extra_dirs[@]}"; do cp "$j" "$d/ifl-patcher-core-${RVB_INSTAFEL_FALLBACK_COMMIT}.jar" 2>/dev/null || :; done
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
		if ! op=$(eval java -jar "'$cli_jar'" list 2>&1); then
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

has_compatible_patches() {
	local cli_jar=$1 patches_jar=$2 pkg_name=$3 version=$4 cli_source=$5
	local inc_patches=${6:-}
	resolve_patcher "$cli_source"
	if [ "$PATCHER_ANY_VERSION" = true ]; then
		return 0
	fi
	[ -z "$cli_jar" ] || [ -z "$patches_jar" ] || [ -z "$pkg_name" ] || [ -z "$version" ] && return 0

	local extra_args="$PATCHER_LIST_X"

	local raw_vers
	if ! raw_vers=$(patches_list_versions "$cli_jar" "$patches_jar" "$pkg_name" "$cli_source" "$extra_args") || [ -z "$raw_vers" ]; then
		return 0
	fi

	local ver_clean="${version// /}"
	ver_clean="${ver_clean#v}"
	ver_clean="${ver_clean#V}"
	local line v_raw v_clean
	while IFS= read -r line; do
		[[ "$line" =~ ^[[:space:]]*INFO: ]] && continue
		[[ "$line" =~ ^[[:space:]]*Most[[:space:]]common ]] && continue

		if [[ "$line" =~ ^[[:space:]]*Any([[:space:]]|$) ]]; then
			return 0
		fi

		# Strip patch count and versionCodes metadata: e.g. " (4 patches)" or " [versionCodes: ...]"
		v_raw=$(sed -e 's/ (.* patch.*//' -e 's/ \[.*//' <<<"$line" | awk '{$1=$1}1')
		v_clean="${v_raw// /}"
		v_clean="${v_clean#v}"
		v_clean="${v_clean#V}"

		if [ -n "$v_clean" ] && [ "$v_clean" = "$ver_clean" ]; then
			return 0
		fi
	done <<<"$raw_vers"

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
	if cffi_res=$("$py_cmd" "$py_script" "$url" "$TEMP_DIR/cookie.txt" 2>/dev/null); then
		html="$cffi_res"
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

	local best_fallback_url=""
	local specific_arch_url=""
	local specific_arch_fallback_url=""

	for ((n = 1; n < 100; n++)); do
		node=$($HTMLQ "div.table-row.headerFont:nth-last-child($n)" <<<"$resp")
		if [ -z "$node" ]; then break; fi
		
		dlurl=$($HTMLQ --base https://www.apkmirror.com --attribute href "div.table-cell:nth-child(1) > a:nth-child(1)" <<<"$node")
		if [ -z "$dlurl" ]; then continue; fi

		local node_apk_bundle node_arch node_dpi node_vc
		node_apk_bundle=$($HTMLQ "div.table-cell:nth-child(1) span.apkm-badge:first-of-type" --text <<<"$node" | xargs)
		[ -z "$node_apk_bundle" ] && node_apk_bundle="APK"

		node_arch=$($HTMLQ "div.table-cell:nth-child(2)" --text <<<"$node" | xargs)
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

		if [ -n "$target_vc" ]; then
			if [ -n "$node_vc" ] && [ "$node_vc" = "$target_vc" ]; then
				echo "$dlurl"
				return 0
			else
				continue
			fi
		fi

		# Pass 1 Logic: Return Universal/Fat Bundles immediately to optimize cache size
		if isoneof "$node_arch" 'universal' 'noarch' 'arm64-v8a + x86_64' 'arm64-v8a + armeabi-v7a'; then
			if isoneof "$node_dpi" "${appdpi[@]}"; then
				echo "$dlurl"
				return 0
			elif [ "$match_any_dpi" = true ] && [ -z "$best_fallback_url" ]; then
				best_fallback_url="$dlurl"
			fi
		# Pass 2 Logic: If it's strictly the requested arch, save it as a fallback in case no universal is found
		elif [ "$node_arch" = "$arch" ]; then
			if isoneof "$node_dpi" "${appdpi[@]}"; then
				[ -z "$specific_arch_url" ] && specific_arch_url="$dlurl"
			elif [ "$match_any_dpi" = true ] && [ -z "$specific_arch_fallback_url" ]; then
				specific_arch_fallback_url="$dlurl"
			fi
		fi
	done

	if [ -n "$best_fallback_url" ]; then
		echo "$best_fallback_url"
		return 0
	elif [ -n "$specific_arch_url" ]; then
		echo "$specific_arch_url"
		return 0
	elif [ -n "$specific_arch_fallback_url" ]; then
		echo "$specific_arch_fallback_url"
		return 0
	fi
	return 1
}

dl_apkmirror() {
	local url=$1 version=${2// /-} output=$3 arch=$4 dpi=$5 is_bundle=false get_latest_ver=${6:-false} version_code=${7:-}
	local base_url="https://www.apkmirror.com"
	local html=""

	if [ -f "${output%.apk}.apkm" ]; then
		if [ "${MORPHE_PASSTHROUGH_ACTIVE:-false}" = true ]; then
			# sidecar exists but merged output may not (prior passthrough run
			# adopted+deleted it): hand the bundle itself to the caller's
			# adoption logic instead of re-merging through apkeditor.
			cp -f "${output%.apk}.apkm" "${output}"
			return 0
		fi
		merge_splits "${output%.apk}.apkm" "${output}"
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

	local search_version="${version//./-}"
	search_version="${search_version//_/-}"
	search_version="${search_version,,}"
	search_version="${search_version//[^a-z0-9-]/}"
	search_version="${search_version//---/-}"

	if [ -z "$release_url" ]; then
		local apkmname
		apkmname=$($HTMLQ "h1.marginZero" --text <<<"$__APKMIRROR_RESP__")
		apkmname="${apkmname,,}" apkmname="${apkmname// /-}" apkmname="${apkmname//[^a-z0-9-]/}"
		release_url="${url%/}/${apkmname}-${search_version}-release/"
		__SILENT_CF_GET__=true _cf_get "$release_url" || true
		resp="$html"
		if [[ "$resp" == *"Page Not Found"* ]] || [[ "$resp" == *"404 Whoops"* ]] || [ -z "$resp" ]; then
			release_url=""
		fi
	fi

	if [ -z "$release_url" ]; then
		local list_url="${url%/}"
		local version_href=""

		# 1. Targeted search query (?s=version) first as inspired by uni-apks
		local search_target_url="${list_url}/?s=${clean_version}"
		if _cf_get "$search_target_url" 2>/dev/null && [ -n "$html" ]; then
			local s_flat=$(echo "$html" | tr -d '\n\r')
			local s_split="${s_flat//<\/a>/<\/a>
}"
			local s_links=$(echo "$s_split" | grep -oP 'href="\K/apk/[^"]+')
			version_href=$(echo "$s_links" | grep -F "$search_version-release" | head -1) || true
			if [ -z "$version_href" ]; then
				version_href=$(echo "$s_split" | grep -F "$version" | grep -oP 'href="\K/apk/[^"]+' | grep -F -- '-release/' | head -1) || true
			fi
			if [ -n "$version_href" ]; then
				release_url="$base_url$version_href"
				_cf_get "$release_url" || return 1
				resp="$html"
			fi
		fi

		if [ -z "$release_url" ]; then
			for page_num in $(seq 1 10); do
			local page_url="$list_url/"
			[[ $page_num -gt 1 ]] && page_url="$list_url/page/$page_num/"
			_cf_get "$page_url" || return 1
			
			
			local html_flat=$(echo "$html" | tr -d '\n\r')
			local html_split="${html_flat//<\/a>/<\/a>
}"

			local all_links=$(echo "$html_split" | grep -oP 'href="\K/apk/[^"]+')
			
			# 1. Exact URL match (strict)
			version_href=$(echo "$all_links" | grep -F "$search_version-release" | head -1) || true
			
			# 2. Exact text match
			if [ -z "$version_href" ]; then
				version_href=$(echo "$html_split" | grep -F "$version" | grep -oP 'href="\K[^"]+' | head -1) || true
			fi
			
			# 3. Clean text match
			if [ -z "$version_href" ] && [ -n "$clean_version" ] && [ "$clean_version" != "$version" ]; then
				version_href=$(echo "$html_split" | grep -F "$clean_version" | grep -oP 'href="\K[^"]+' | head -1) || true
			fi

			# 4. Clean URL match
			if [ -z "$version_href" ] && [ -n "$clean_search_version" ]; then
				version_href=$(echo "$all_links" | grep -E "${clean_search_version}(-[a-z0-9]+)*-release" | head -1) || true
			fi

			# 5. Safe Short URL match (for grouped versions)
			if [ -z "$version_href" ] && [ -n "$short_search_version" ] && [ "$short_search_version" != "$clean_search_version" ]; then
				version_href=$(echo "$all_links" | grep -E "${short_search_version}(-[0-9])?-release/?$" | head -1) || true
			fi

				if [ -n "$version_href" ]; then
					release_url="$base_url$version_href"
					_cf_get "$release_url" || return 1
					resp="$html"
					break
				fi
			done
		fi
		
		# Fallback to direct search if not found on first 5 pages
		if [ -z "$release_url" ]; then
			local search_list_url="https://www.apkmirror.com/?post_type=app_release&searchtype=apk&s=${__APKMIRROR_CAT__}+${version}"
			__SILENT_CF_GET__=true _cf_get "$search_list_url" || true
			if [ -n "$html" ] && [ "$html" != "null" ]; then
				local search_links=""
				if [[ "$html" != *"No results found matching your query"* ]]; then
					search_links=$($HTMLQ --attribute href "div.appRow h5 a" <<<"$html")
				fi
				
				# Try to find exact version match first to be safe, otherwise fallback to top result
				version_href=$(echo "$search_links" | grep -F "$search_version-release" | head -1) || true
				if [ -z "$version_href" ] && [ -n "$clean_search_version" ]; then
					version_href=$(echo "$search_links" | grep -E "${clean_search_version}(-[a-z0-9]+)*-release" | head -1) || true
				fi
				
				# Search query is exact, so the top search result is the best match if strict regexes fail
				if [ -z "$version_href" ]; then
					version_href=$(echo "$search_links" | head -1) || true
				fi

				if [ -n "$version_href" ]; then
					release_url="$base_url$version_href"
					_cf_get "$release_url" || return 1
					resp="$html"
				fi
			fi
		fi

		if [ -z "$release_url" ]; then
			epr "Could not find version $version on APKMirror"
			return 1
		fi
	fi

	# APKMirror's fuzzy search fallback can resolve to an unrelated app's
	# release page (e.g. a superseded version grabbing the top search hit),
	# which then wastes a bundle download + merge before the post-download
	# package guard rejects it. Verify the discovered page's package against
	# the expected pkg_name first; only reject when the page clearly belongs
	# to a different app (an empty extraction keeps prior behavior).
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
		if [ "${args[prefer_dl_mode]:-}" = "bundle" ]; then
			types="BUNDLE APK"
		else
			types="APK BUNDLE"
		fi
		for type in $types; do
			if dlurl=$(apkmirror_search "$resp" "$dpi" "$arch" "$type" "$clean_search_version" "$search_version" "$version_code"); then
				[ "$type" = "BUNDLE" ] && is_bundle=true || is_bundle=false
				break
			fi
		done
		if [ -z "$dlurl" ]; then
			if [ -n "$version_code" ]; then
				wpr "Could not find variant with version code '$version_code' for version '$version' on APKMirror"
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
			--header="User-Agent: ${user_agent:-Mozilla/5.0}" \
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
		if [ "${MORPHE_PASSTHROUGH_ACTIVE:-false}" = true ]; then
			# bundle-as-apk; build_rv's manifest check adopts it as .xapk
			cp -f "${output%.apk}.apkm" "${output}"
		else
			merge_splits "${output%.apk}.apkm" "${output}"
		fi
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

dl_apkpure() {
	local url=$1 version=$2 output=$3 arch=${4:-} _dpi=${5:-}
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

	local download_url
	download_url=$($HTMLQ "a#download_link" --attribute href <<<"$html" 2>/dev/null | head -1) || true
	[ -z "$download_url" ] && \
		download_url=$(echo "$html" | grep -oP '<a[^>]+id="download_link"[^>]+href="\Khttps://[^"]+' | head -1) || true
	[ -z "$download_url" ] && \
		download_url=$(echo "$html" | grep -oP 'id="download_link"[^>]*href="\Khttps://[^"]+' | head -1) || true

	if [ -z "$download_url" ]; then
		epr "Could not find download link on APKPure"
		return 1
	fi

	pr "Downloading from APKPure: $download_url"
	local cookie_header=()
	[ -n "${CF_COOKIES:-}" ] && cookie_header=(-H "Cookie: $CF_COOKIES")

	local is_bundle=false
	echo "$download_url" | grep -qi 'xapk' && is_bundle=true

	local bundle="${output%.apk}.xapk"
	if [ "$is_bundle" = true ]; then
		curl -L -s -S \
			-H "User-Agent: ${user_agent:-Mozilla/5.0}" \
			-H "Referer: $dl_page_url" \
			"${cookie_header[@]}" \
			--connect-timeout 30 --max-time 300 \
			"$download_url" -o "$bundle" || { rm -f "$bundle"; return 1; }
		if ! _apkpure_install_xapk "$bundle" "${output}"; then
			rm -f "$bundle"
			return 1
		fi
		if [ "${MORPHE_PASSTHROUGH_ACTIVE:-false}" != true ]; then
			rm -f "$bundle"
		fi
	else
		curl -L --fail -s -S \
			-H "User-Agent: ${user_agent:-Mozilla/5.0}" \
			-H "Referer: $dl_page_url" \
			"${cookie_header[@]}" \
			--connect-timeout 30 --max-time 300 \
			"$download_url" -o "${output}" || { rm -f "${output}"; return 1; }
	fi
}

_apkpure_install_xapk() {
	local xapk=$1 output=$2
	if ! unzip -l "$xapk" >/dev/null 2>&1; then
		epr "Downloaded XAPK is not a valid zip (Cloudflare block?): $xapk"
		rm -f "$xapk"
		return 1
	fi
	if ! merge_splits "$xapk" "$output"; then
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
dl_apkcombo() {
	local _url=$1 version=$2 output=$3 _arch=$4 _dpi=$5
	local html="" dl_url="" final_url checkin page_url page compact_page

	if [ -n "$version" ]; then
		local sfxs=("apk" "xapk" "apks")
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

		dl_url=$(echo "$page" | grep -oP '(?<=a href=")https://download\.apkcombo\.com/[^"]+' | head -1) || true
		[ -z "$dl_url" ] && dl_url=$(echo "$page" | grep -oP '(?<=a href=")/r2[^"]+' | head -1) || true
		[ -z "$dl_url" ] && dl_url=$(echo "$compact_page" | grep -oP '"download_url"\s*:\s*"\K[^"]+' | head -1 | sed 's#\\/#/#g') || true
		[ -z "$dl_url" ] && dl_url=$(echo "$compact_page" | grep -oP '"url"\s*:\s*"\Khttps://download\.apkcombo\.com/[^"]+' | head -1 | sed 's#\\/#/#g') || true
		[ -z "$dl_url" ] && dl_url=$(echo "$compact_page" | grep -oP 'https://download\.apkcombo\.com/[^"'"'"' <>]+' | head -1 | sed 's#\\/#/#g') || true
		[ -z "$dl_url" ] && dl_url=$(echo "$compact_page" | grep -oP '/r2\?u=[^"'"'"' <>]+' | head -1 | sed 's#\\/#/#g') || true

		if [ -n "$dl_url" ]; then
			break
		fi
	done

	[ -z "$dl_url" ] && { epr "Could not find APK link on APKCombo"; return 1; }
	[[ "$dl_url" != http* ]] && dl_url="https://apkcombo.com${dl_url}"
	dl_url=$(echo "$dl_url" | sed 's/\\u0026/\&/g; s/&amp;/\&/g')

	if [[ "$dl_url" == https://apkcombo.com/r2\?u=* ]]; then
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
			-H "User-Agent: ${user_agent:-Mozilla/5.0}" \
			-H "Referer: $page_url" "$dl_url") || return 1
	fi

	pr "Downloading from APKCombo: $final_url"
	curl -L --fail -s -S --connect-timeout 30 --max-time 300 \
		-H "User-Agent: ${user_agent:-Mozilla/5.0}" \
		-H "Referer: $page_url" "$final_url" -o "$output" || { rm -f "$output"; return 1; }
	if ! unzip -l "$output" >/dev/null 2>&1; then
		epr "Downloaded file from APKCombo is not a valid zip"
		rm -f "$output"
		return 1
	fi
	if echo "$final_url$dl_url" | grep -qi 'xapk\|\.apks'; then
		local ext="xapk"
		echo "$final_url$dl_url" | grep -qi '\.apks' && ext="apks"
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

	local vers
	vers=$(grep -oP '<span class="version">\K[^<]+' <<<"${__UPTODOWN_RESP__:-}" || true)
	if [ -z "$vers" ] && [ -n "${HTMLQ:-}" ] && [ -x "$HTMLQ" ]; then
		vers=$($HTMLQ --text ".version" <<<"${__UPTODOWN_RESP__:-}" 2>/dev/null || true)
	fi
	if [ "$allow_all" = false ]; then
		vers=$(grep -iv "\(beta\|alpha\|secondary\)" <<<"$vers" || true)
	fi
	echo "$vers"
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

	local pkg
	pkg=$(grep -oP 'play\.google\.com/store/apps/details\?id=\K[a-zA-Z0-9_.]+' <<<"${__UPTODOWN_RESP_PKG__:-}${__UPTODOWN_RESP__:-}" | head -1) || true
	if [ -z "$pkg" ] && [ -n "${HTMLQ:-}" ] && [ -x "$HTMLQ" ]; then
		pkg=$($HTMLQ --text "tr.full:nth-child(1) > td:nth-child(3)" <<<"${__UPTODOWN_RESP_PKG__:-}" 2>/dev/null || true)
	fi
	echo "$pkg"
}

dl_uptodown() {
	local uptodown_dlurl=$1 version=$2 output=$3 arch=$4 _dpi=$5
	if [ "$arch" = "arm-v7a" ]; then arch="armeabi-v7a"; fi

	local py_cmd=""
	if command -v python3 >/dev/null 2>&1; then
		py_cmd="python3"
	elif command -v python >/dev/null 2>&1; then
		py_cmd="python"
	fi

	local py_script="${CWD}/scripts/uptodown.py"
	[ ! -f "$py_script" ] && [ -n "${BASH_SOURCE[0]:-}" ] && py_script="$(dirname "${BASH_SOURCE[0]}")/uptodown.py"

	local errf="${TEMP_DIR}/uptodown_resolve_$$.err"
	if [ -n "$py_cmd" ] && [ -f "$py_script" ]; then
		local py_info="" attempt
		# Retry: Uptodown's API/auth endpoints are bot-gated and can throw
		# intermittently (HTTP 403/503 or a JSON error) from datacenter IPs
		# like GitHub runners. A few short-backoff attempts ride out transient
		# blocks; stderr is captured (not discarded) so a hard failure reports
		# its real cause instead of a blank "Failed to resolve".
		for attempt in 1 2 3; do
			if py_info=$("$py_cmd" "$py_script" download-url "$uptodown_dlurl" "$version" "$arch" 2>"$errf") && [ -n "$py_info" ]; then
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
			if [ "$is_bundle" = "true" ]; then
				local bundle="${output%.apk}.apkm"
				req "$cdn_url" "$bundle" || { rm -f "$errf"; return 1; }
				if [ "${MORPHE_PASSTHROUGH_ACTIVE:-false}" = true ]; then
					cp -f "$bundle" "${output}"
				else
					merge_splits "$bundle" "${output}" || { rm -f "$bundle" "$errf"; return 1; }
					rm -f "$bundle"
				fi
			else
				req "$cdn_url" "$output" || { rm -f "$errf"; return 1; }
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

# -------------------- archive --------------------
dl_archive() {
	local url=$1 version=$2 output=$3 arch=$4 is_bundle=${5:-false} get_latest_ver=${6:-false} version_code=${7:-}
	local path="" version_f=${version// /}
	local norm_resp="${__ARCHIVE_RESP__//$'\r'/}"
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
			merge_splits "$bundle" "${output}" || { rm -f "$bundle"; return 1; }
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
			merge_splits "$bundle" "$output" || { rm -f "$bundle"; return 1; }
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
	
	repo=$(cut -d/ -f4-5 <<<"$url")
	tag=${url%/}
	tag=${tag##*/}
	endpoint="tags/${tag}"
	
	if ! resp=$(gh_req "https://api.github.com/repos/${repo}/releases/${endpoint}" -); then
        return 1
	fi
	
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
			merge_splits "$bundle" "$output" || { rm -f "$bundle"; return 1; }
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
dl_direct() {
	local url=$1 version=${2// /-} output=$3 arch=$4 _dpi=$5
	req "$url" "${output}" || return 1
}
get_direct_vers() { cut -d- -f2 <<<"$__DIRECT_APKNAME__" | sed 's/\.\(apk\|xapk\|apks\|apkm\)$//'; }
get_direct_pkg_name() { cut -d- -f1 <<<"$__DIRECT_APKNAME__" | sed 's/\.\(apk\|xapk\|apks\|apkm\)$//'; }
get_direct_resp() { __DIRECT_APKNAME__=$(awk -F/ '{print $NF}' <<<"$1"); }
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
		mkdir -p "$tmp_dir"
		local cmd="java -jar '$cli_jar' -o '$tmp_dir' $p_args_modules $patcher_args '$stock_input'"
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
		_instafel_shadow_core "$cli_jar" "$patches_jar" "$rel_tmp_dir"

		local expected_base
		expected_base=$(basename "$stock_input" .apk)
		[ -n "$expected_base" ] && [ -d "$expected_base" ] && rm -rf "$expected_base" 2>/dev/null || :

		local init_cmd="java -jar '$cli_jar' init '$stock_input'"
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
			patches_to_run=$(echo "$per_bundle_ed" | grep -oE "['\"][^'\"]+['\"]" | tr -d "'\"" | tr '\n' ' ' | sed 's/ *$//')
		fi
		if [ -z "$patches_to_run" ]; then
			patches_to_run="$RVB_INSTAFEL_DEFAULT_PATCHES"
		fi

		local run_cmd="java -jar '$cli_jar' run '$wdir' $patches_to_run"
		pr "$run_cmd"
		PATCH_OUTPUT=$(eval "$run_cmd" 2>&1)
		echo "$PATCH_OUTPUT"

		local build_cmd="java -jar '$cli_jar' build '$wdir'"
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
	local arch_orig="${args[arch]// /}"
	if [ "$arch_orig" != "auto" ]; then ext="${arch}${ext}"; arch=""; fi
	# extract applied patches supporting revanced, morphe-desktop, and instafel output formats
	# revanced: INFO: "Patch Name" succeeded
	# morphe:   INFO: Applied: Patch Name
	# instafel: I: Patch 'Patch Name' loaded
	local applied_json
	applied_json=$(printf '%s\n' "$PATCH_OUTPUT" | grep -oP '(?<=INFO: ")[^"\n]+(?=" succeeded)|(?<=INFO: Applied: ).*|(?<=I: Patch \x27)[^\x27]+(?=\x27 loaded)' | jq -R -s -c 'split("\n") | map(select(length > 0))' 2>/dev/null || true)
	[[ "$applied_json" != \[* ]] && applied_json='[]'
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
			if .[$e.key] == null then .[$e.key] = $e.value
			else
				.[$e.key].exts = ((.[$e.key].exts + $e.value.exts) | unique) |
				reduce (["name","arch","version","patches","changelog","package_name","display_name","patches_source","brand","variant","sub_variant"][]) as $k (.;
					if ((.[$e.key][$k] // "") == "") and (($e.value[$k] // "") != "")
					then .[$e.key][$k] = $e.value[$k] else . end) |
				if ((.[$e.key].applied_patches | length) == 0) and (($e.value.applied_patches | length) > 0)
				then .[$e.key].applied_patches = $e.value.applied_patches else . end
			end)
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

check_is_universal() {
	local stock_apk=$1
	if [ -f "${stock_apk%.apk}.apkm" ]; then
		if ! unzip -l "${stock_apk%.apk}.apkm" 2>/dev/null | grep -iq "arm64\|armeabi\|x86\|x86_64" || (unzip -l "${stock_apk%.apk}.apkm" 2>/dev/null | grep -iq "arm64" && unzip -l "${stock_apk%.apk}.apkm" 2>/dev/null | grep -iq "armeabi"); then
			return 0
		fi
	else
		if ! unzip -l "$stock_apk" 2>/dev/null | grep -q "lib/" || (unzip -l "$stock_apk" 2>/dev/null | grep -q "lib/arm64-v8a/" && unzip -l "$stock_apk" 2>/dev/null | grep -q "lib/armeabi-v7a/"); then
			return 0
		fi
	fi
	return 1
}

# Shared version-resolution pre-pass used by build_rv's two call sites
# (early pkg path + post-download path). Operates on the caller's dynamic
# locals: list_patches, resolved_version, version_mode.
# Returns: 0 continue | 1 hard failure (caller `return 1`) | 2 skip app (caller `return 0`)
_resolve_list_and_version() {
	local cli_jar=$1 patches_jar=$2 pkg_name=$3 table=$4 say_pkg=${5:-false}
	if [ -z "$list_patches" ]; then
		[ "$say_pkg" = true ] && pr "Package name of '${table}' is '$pkg_name'"
		list_patches=$(patches_list "$cli_jar" "$patches_jar" "$pkg_name" "${args[cli_source]}") || return 1
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
		# Check app_versions.json for exact version
		local app_versions_file=".github/configs/app_versions.json"
		if [ -f "$app_versions_file" ]; then
			local t_pure="${table% (arm64-v8a)}"
			t_pure="${t_pure% (arm-v7a)}"
			local json_ver=$(jq -r --arg t "$t_pure" 'to_entries | map(select(.key | startswith("_") | not)) | map(select(.value.keys != null and (.value.keys | index($t)))) | .[0].value.version // empty' "$app_versions_file")
			if [ -n "$json_ver" ]; then
				resolved_version="$json_ver"
			fi
		fi

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
					epr "ERROR: Could not get response for ${table} in ${dl_p}"
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
			continue
		fi

		for arch in "${arch_list[@]}"; do
			arch_f="${arch// /}"
			local target_version_code
			target_version_code=$(parse_arch_mapping "${args[version_code]:-}" "$arch_f")
			if [ -z "$target_version_code" ] || [ "$target_version_code" = "auto" ]; then
				target_version_code=""
				if [ -n "$version" ] && [ -n "$cli_jar" ] && [ -n "$patches_jar" ]; then
					local raw_vers
					if raw_vers=$(patches_list_versions "$cli_jar" "$patches_jar" "$pkg_name" "${args[cli_source]:-}" "$cli_lv_extra"); then
						target_version_code=$(get_patch_version_code "$raw_vers" "$version" "$arch_f" || true)
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
			local _apk_lock_held=""
			if command -v flock >/dev/null 2>&1; then
				mkdir -p "${TEMP_DIR}/apkslocks"
				exec 203>"${TEMP_DIR}/apkslocks/${pkg_name}-${version_f}${vc_infix}.lock"
				flock -x 203
				_apk_lock_held=1
			fi
			local cached_stock_apk="${apk_cache_dir}/${pkg_name}-${version_f}${vc_infix}-${arch_f}.apk"
			local cached_all_apk="${apk_cache_dir}/${pkg_name}-${version_f}${vc_infix}-all.apk"
			local stock_apk="$cached_stock_apk"
			local all_apk="$cached_all_apk"
			if [ ! -f "$stock_apk" ] && [ ! -f "$all_apk" ] && [ -n "$target_version_code" ]; then
				local legacy_stock="${apk_cache_dir}/${pkg_name}-${version_f}-${arch_f}.apk"
				local legacy_all="${apk_cache_dir}/${pkg_name}-${version_f}-all.apk"
				if [ -f "$legacy_stock" ] || [ -f "$legacy_all" ]; then
					stock_apk="$legacy_stock"
					all_apk="$legacy_all"
				fi
			fi
			local cached_bundle_apk=""
			if [ "$_CACHE_BUNDLE_OK" = true ]; then
				local bx
				for bx in xapk apkm apks; do
					if [ -f "${apk_cache_dir}/${pkg_name}-${version_f}${vc_infix}-all.${bx}" ]; then
						cached_bundle_apk="${apk_cache_dir}/${pkg_name}-${version_f}${vc_infix}-all.${bx}"
						break
					fi
				done
			fi
			if [ -n "$cached_bundle_apk" ]; then
				# vendor bundle is universal; skip per-arch apk names
				stock_apk="$cached_bundle_apk"
				all_apk="$cached_bundle_apk"
			fi
			if [ -f "$all_apk" ] && [ -z "$cached_bundle_apk" ]; then
				local missing_arch=false
				if [ "$arch_f" = "arm64-v8a" ] && ! unzip -l "$all_apk" 2>/dev/null | grep -q "lib/arm64-v8a/"; then
					unzip -l "$all_apk" 2>/dev/null | grep -q "lib/" && missing_arch=true
				elif [ "$arch_f" = "arm-v7a" ] && ! unzip -l "$all_apk" 2>/dev/null | grep -q "lib/armeabi-v7a/"; then
					unzip -l "$all_apk" 2>/dev/null | grep -q "lib/" && missing_arch=true
				fi
				if [ "$missing_arch" = false ]; then
					stock_apk="$all_apk"
				fi
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
					pr "Downloading '${table}' from '${dl_p}'"
					if ! isoneof $dl_p "${tried_dl[@]}"; then
						if ! get_${dl_p}_resp "${args[${dl_p}_dlurl]}"; then
							epr "ERROR: Could not get '${table}' from '${dl_p}'"
							continue
						fi
					fi
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
							downloaded_vc=$(_meta_field_of "$stock_apk" versionCode) || true
						
						if [ -z "$downloaded_pkg" ]; then
							epr "ERROR: Downloaded file is not a valid APK or aapt failed to parse it. Rejecting..."
							rm -f "$stock_apk"
							continue
						fi

						if [ -n "$downloaded_pkg" ] && [ "$downloaded_pkg" != "$pkg_name" ] && [[ "$pkg_name" == *.* ]]; then
							epr "ERROR: Downloaded APK package name ($downloaded_pkg) does not match expected ($pkg_name). Rejecting..."
							rm -f "$stock_apk"
							continue
						fi

						if [ -n "$target_version_code" ] && [ -n "$downloaded_vc" ]; then
							if [ "$downloaded_vc" != "$target_version_code" ]; then
								epr "ERROR: Downloaded APK version code ($downloaded_vc) does not match expected ($target_version_code). Rejecting..."
								rm -f "$stock_apk" "${stock_apk%.apk}.apkm"
								continue
							fi
						fi

						if [ -n "$downloaded_ver" ] && [[ "$dl_p" == "direct" ]]; then
							if [ "$version" != "$downloaded_ver" ]; then
								pr "Updating version from '${version}' to '${downloaded_ver}' based on APK info"
								version="$downloaded_ver"
								version_f=${version// /}
								version_f=${version_f#v}
								
								local new_stock_apk="${TEMP_DIR}/${pkg_name}-${version_f}${vc_infix}-${arch_f}.apk"
								mv "$stock_apk" "$new_stock_apk"
								stock_apk="$new_stock_apk"
								cached_stock_apk="${apk_cache_dir}/${pkg_name}-${version_f}${vc_infix}-${arch_f}.apk"
								cached_all_apk="${apk_cache_dir}/${pkg_name}-${version_f}${vc_infix}-all.apk"
							fi
						fi
					fi
					local _vapk="$stock_apk"
					if ! verify_downloaded_apk "$_vapk" "$pkg_name" "$dl_p"; then
						rm -f "$stock_apk" "${stock_apk%.apk}.apkm"
						continue
					fi

					break
				done
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
				if [ -f "$stock_apk" ] && [ -z "$morphe_bundle_path" ] && [ ! -f "$all_apk" ] && [[ "$arch" != "all" && "$arch" != "universal" ]]; then
					if check_is_universal "$stock_apk"; then
						mv -f "$stock_apk" "$all_apk"
						if [ -f "${stock_apk%.apk}.apkm" ]; then
							mv -f "${stock_apk%.apk}.apkm" "${all_apk%.apk}.apkm"
						fi
						stock_apk="$all_apk"
					fi
				fi
				
				# Sync pristine files from staging to cache
				if [ -f "$stock_apk" ]; then
					local _sync_bext
					if _sync_bext=$(_bundle_ext_of "$stock_apk"); then
						local cached_bundle="${cached_all_apk%.apk}.${_sync_bext}"
						cp -f "$stock_apk" "$cached_bundle"
						stock_apk="$cached_bundle"
						all_apk="$cached_bundle"
					elif [ "$stock_apk" = "$all_apk" ]; then
						cp -f "$all_apk" "$cached_all_apk"
						stock_apk="$cached_all_apk"
						all_apk="$cached_all_apk"
					else
						cp -f "$stock_apk" "$cached_stock_apk"
						stock_apk="$cached_stock_apk"
						all_apk=""
					fi
				fi

				if [ -f "$stock_apk" ] && [ -n "${UPLOAD_APKS_REPO:-}" ] && [ "$dl_p" != "archive" ] && [ "$dl_p" != "cache_repo" ]; then
					pr "Uploading newly downloaded APKs to ${UPLOAD_APKS_REPO}..."
					local _ua_file="$stock_apk" _ua_ok="" _ua_att
					[ -n "$all_apk" ] && [ -f "$all_apk" ] && _ua_file="$all_apk"
					# Retry: with parallel builds a sibling process can create the same
					# release tag between our view (404) and create (422 tag exists);
					# the next attempt's view finds it. Upload races are transient too.
					for _ua_att in 1 2 3; do
						if { gh release view "$pkg_name" --repo "$UPLOAD_APKS_REPO" >/dev/null 2>&1 || \
							gh release create "$pkg_name" --repo "$UPLOAD_APKS_REPO" --title "$pkg_name" --notes ""; } && \
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
			epr "ERROR: Could not download '${table}' for version $resolved_version"
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
		epr "ERROR: Could not download '${table}' after trying all supported versions."
		return 0
	fi

	# Ensure the mtime is set to now so newly downloaded APKs with old server timestamps aren't purged
	touch "$stock_apk" 2>/dev/null || true
	[ -f "${stock_apk%.apk}.apkm" ] && touch "${stock_apk%.apk}.apkm" 2>/dev/null || true
	[ -n "${all_apk:-}" ] && [ -f "$all_apk" ] && touch "$all_apk" 2>/dev/null || true

	# Log usage for apks repo cache sync
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
			cp -f "$stock_apk" "$stock_apk_to_patch"
			if [ "$arch" = "arm64-v8a" ]; then
				zip -d "$stock_apk_to_patch" "lib/armeabi-v7a/*" "lib/x86_64/*" "lib/x86/*" >/dev/null 2>&1 || :
			elif [ "$arch" = "arm-v7a" ]; then
				zip -d "$stock_apk_to_patch" "lib/arm64-v8a/*" "lib/x86_64/*" "lib/x86/*" >/dev/null 2>&1 || :
			elif [ "$arch" = "x86" ]; then
				zip -d "$stock_apk_to_patch" "lib/arm64-v8a/*" "lib/x86_64/*" "lib/armeabi-v7a/*" >/dev/null 2>&1 || :
			elif [ "$arch" = "x86_64" ]; then
				zip -d "$stock_apk_to_patch" "lib/arm64-v8a/*" "lib/armeabi-v7a/*" "lib/x86/*" >/dev/null 2>&1 || :
			else
				zip -d "$stock_apk_to_patch" "lib/x86_64/*" "lib/x86/*" >/dev/null 2>&1 || :
			fi
		fi
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
		local upj="${args[module_prop_name],,}-update.json"

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
join_args() { list_args "$1" | sed "s/^/${2} /" | paste -sd " " - || :; }

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
module_prop() {
	echo "id=${1}
name=${2}
version=v${3}
versionCode=${NEXT_VER_CODE}
author=${4}
description=${5}" >"${7}/module.prop"

	if [ "$ENABLE_MODULE_UPDATE" = true ]; then echo "updateJson=${6}" >>"${7}/module.prop"; fi
}
