#!/usr/bin/env bash

MODULE_TEMPLATE_DIR="module"
CWD=$(pwd)
TEMP_DIR="temp"
BIN_DIR="bin"
BUILD_DIR="build"
DL_SRCS=("direct" "github" "archive" "apkmirror" "uptodown" "apkpure" "apkcombo")
BUILD_JSON_FILE="build.json"
PATCH_OUTPUT=""

if [ "${GITHUB_TOKEN-}" ]; then GH_HEADER="Authorization: token ${GITHUB_TOKEN}"; else GH_HEADER=; fi
NEXT_VER_CODE=${NEXT_VER_CODE:-$(date +'%Y%m%d')}
OS=$(uname -o)

toml_prep() {
	if [ ! -f "$1" ]; then return 1; fi
	if [ "${1##*.}" == toml ]; then
		__TOML__=$($TOML --output json --file "$1" .)
	elif [ "${1##*.}" == json ]; then
		__TOML__=$(cat "$1")
	else abort "config extension not supported"; fi
}
toml_get_table_names() { jq -r -e 'to_entries[] | select(.value | type == "object") | .key' <<<"$__TOML__"; }
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
	rm -rf ./${TEMP_DIR}/*tmp.* ./${TEMP_DIR}/*/*tmp.* ./${TEMP_DIR}/*-temporary-files ./${TEMP_DIR}/*.apk-temporary-files ./*-temporary-files
	trap - SIGTERM SIGINT EXIT
	kill -9 -- -$$ 2>/dev/null
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
			if [ "$mode" = dev ]; then
				jq -e -c 'map(select(.prerelease == true and .tag_name != null and .tag_name != "")) | sort_by(.published_at // .created_at // "") | reverse | .[0] // empty'
			else
				jq -e -c 'map(select(.prerelease != true and .tag_name != null and .tag_name != "")) | sort_by(.published_at // .created_at // "") | reverse | .[0] // empty'
			fi
			;;
		gitlab)
			if [ "$mode" = dev ]; then
				jq -e -c 'map(select(.tag_name != null and .tag_name != "" and (.tag_name | test("(?i)(dev|alpha|beta|rc)")))) | sort_by(.released_at // .created_at // "") | reverse | .[0] // empty'
			else
				jq -e -c 'map(select(.tag_name != null and .tag_name != "" and (.tag_name | test("(?i)(dev|alpha|beta|rc)") | not))) | sort_by(.released_at // .created_at // "") | reverse | .[0] // empty'
			fi
			;;
		*) return 1 ;;
	esac
}

get_prebuilts() {
	local cli_host=$1 cli_src=$2 cli_ver=$3 patches_host_list=$4 patches_src_list=$5 patches_ver_list=$6
	
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
	if [ "$ver" = "dev" ]; then
		resp=$({ if [ "$host" = github ]; then gh_req "$rv_rel?per_page=100" -; else req "$rv_rel?per_page=100" -; fi; }) || return 1
		ver=$(source_release_pick_from_list "$host" dev <<<"$resp" | jq -r '.tag_name') || true
		if [ -z "$ver" ] || [ "$ver" = "null" ]; then
			ver=$(jq -e -r '.[].tag_name' <<<"$resp" | get_highest_ver) || return 1
		fi
	fi
	if [ "$ver" = "latest" ]; then
		resp=$({ if [ "$host" = github ]; then gh_req "$rv_rel?per_page=100" -; else req "$rv_rel?per_page=100" -; fi; }) || return 1
		release=$(source_release_pick_from_list "$host" latest <<<"$resp") || return 1
	else
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
			matches_new=$(jq -e -r 'map(select(.name | contains("-dev") | not))' <<<"$matches")
			if [ "$(jq 'length' <<<"$matches_new")" -eq 1 ]; then
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
		if [ "$ver" = "dev" ]; then
			resp=$({ if [ "$host" = github ]; then gh_req "$rv_rel?per_page=100" -; else req "$rv_rel?per_page=100" -; fi; }) || return 1
			ver=$(source_release_pick_from_list "$host" dev <<<"$resp" | jq -r '.tag_name') || true
			if [ -z "$ver" ] || [ "$ver" = "null" ]; then
				ver=$(jq -e -r '.[].tag_name' <<<"$resp" | get_highest_ver) || return 1
			fi
		fi
		if [ "$ver" = "latest" ]; then
			resp=$({ if [ "$host" = github ]; then gh_req "$rv_rel?per_page=100" -; else req "$rv_rel?per_page=100" -; fi; }) || return 1
			release=$(source_release_pick_from_list "$host" latest <<<"$resp") || return 1
		else
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
	AAPT2="${BIN_DIR}/aapt2/aapt2-${arch}"
	TOML="${BIN_DIR}/toml/tq-${arch}"
}

config_update() {
	if [ ! -f build.md ]; then abort "build.md not available"; fi
	declare -A sources
	: >"$TEMP_DIR"/skipped
	local upped=()
	local prcfg=false
	for table_name in $(toml_get_table_names); do
		if [ -z "$table_name" ]; then continue; fi
		t=$(toml_get_table "$table_name")
		enabled=$(toml_get "$t" enabled) || enabled=true
		if [ "$enabled" = "false" ]; then continue; fi
		local raw_patches_src raw_patches_host raw_patches_ver
		raw_patches_src=$(toml_get "$t" patches-source) || raw_patches_src=$DEF_PATCHES_SRC
		raw_patches_host=$(toml_get "$t" patches-source-host) || raw_patches_host=$DEF_PATCHES_SRC_HOST
		raw_patches_ver=$(toml_get "$t" patches-version) || raw_patches_ver=$DEF_PATCHES_VER
		local IFS=$'\n'
		local p_srcs=($(list_args "$raw_patches_src" | tr -d \"\')); [ ${#p_srcs[@]} -eq 0 ] && p_srcs=("$raw_patches_src")
		local p_hosts=($(list_args "$raw_patches_host" | tr -d \"\')); [ ${#p_hosts[@]} -eq 0 ] && p_hosts=("$raw_patches_host")
		local p_vers=($(list_args "$raw_patches_ver" | tr -d \"\')); [ ${#p_vers[@]} -eq 0 ] && p_vers=("$raw_patches_ver")
		unset IFS
		local table_updated=false
		for i in "${!p_srcs[@]}"; do
			local PATCHES_SRC="${p_srcs[$i]}"
			local PATCHES_HOST="${p_hosts[$i]:-${p_hosts[0]}}"
			local PATCHES_VER="${p_vers[$i]:-${p_vers[0]}}"
			if [[ -v sources["$PATCHES_HOST/$PATCHES_SRC/$PATCHES_VER"] ]]; then
				if [ "${sources["$PATCHES_HOST/$PATCHES_SRC/$PATCHES_VER"]}" = 1 ]; then table_updated=true; fi
			else
				sources["$PATCHES_HOST/$PATCHES_SRC/$PATCHES_VER"]=0
				local rv_rel resp last_patches
				rv_rel=$(source_release_api_base "$PATCHES_HOST" "$PATCHES_SRC") || continue
				if [ "$PATCHES_VER" = "dev" ]; then
					resp=$({ if [ "$PATCHES_HOST" = github ]; then gh_req "$rv_rel?per_page=100" -; else req "$rv_rel?per_page=100" -; fi; }) || continue
					last_patches=$(source_release_pick_from_list "$PATCHES_HOST" dev <<<"$resp") || continue
				elif [ "$PATCHES_VER" = "latest" ]; then
					resp=$({ if [ "$PATCHES_HOST" = github ]; then gh_req "$rv_rel?per_page=100" -; else req "$rv_rel?per_page=100" -; fi; }) || continue
					last_patches=$(source_release_pick_from_list "$PATCHES_HOST" latest <<<"$resp") || continue
				else
					rv_rel=$(source_release_tag_api "$PATCHES_HOST" "$PATCHES_SRC" "$PATCHES_VER") || continue
					last_patches=$({ if [ "$PATCHES_HOST" = github ]; then gh_req "$rv_rel" -; else req "$rv_rel" -; fi; }) || continue
				fi
				if ! last_patches=$(source_release_assets_json "$PATCHES_HOST" <<<"$last_patches" | jq -e -r '.[0].name'); then
					abort "config_update error: '$last_patches'"
				fi
				if [ "$last_patches" ]; then
					if ! OP=$(grep "^Patches: ${PATCHES_SRC%%/*}/" build.md | grep -m1 "$last_patches"); then
						sources["$PATCHES_HOST/$PATCHES_SRC/$PATCHES_VER"]=1
						prcfg=true
						table_updated=true
					else
						echo "$OP" >>"$TEMP_DIR"/skipped
					fi
				fi
			fi
		done
		[ "$table_updated" = true ] && upped+=("$table_name")
	done
	if [ "$prcfg" = true ]; then
		local query=""
		for table in "${upped[@]}"; do
			if [ -n "$query" ]; then query+=" or "; fi
			query+=".key == \"$table\""
		done
		jq "to_entries | map(select(${query} or (.value | type != \"object\"))) | from_entries" <<<"$__TOML__"
	fi
}

_req() {
	local ip="$1" op="$2"
	shift 2
	local dlp="$op"
	if [ "$op" != - ]; then
		if [ -f "$op" ]; then return; fi
		dlp="$(dirname "$op")/tmp.$(basename "$op")"
		if [ -f "$dlp" ]; then
			while [ -f "$dlp" ]; do sleep 1; done
			return
		fi
	fi
	if ! curl -L -c "$TEMP_DIR/cookie.txt" -b "$TEMP_DIR/cookie.txt" --connect-timeout 10 --retry 1 --fail -s -S "$@" "$ip" -o "$dlp"; then
		epr "Request failed: $ip"
		return 1
	fi
	if [ "$dlp" != - ]; then
		mv -f "$dlp" "$op"
	fi
}
req() { _req "$1" "$2" -H "User-Agent: Mozilla/5.0 (X11; Linux x86_64; rv:108.0) Gecko/20100101 Firefox/108.0"; }
gh_req() { _req "$1" "$2" -H "$GH_HEADER"; }
gh_dl() {
	if [ ! -f "$1" ]; then
		pr "Getting '$1' from '$2'"
		_req "$2" "$1" -H "$GH_HEADER" -H "Accept: application/octet-stream"
	fi
}

log() { echo -e "$1  " >>"build.md"; }
get_highest_ver() {
	local vers m
	vers=$(tee)
	m=$(head -1 <<<"$vers")
	if ! semver_validate "$m"; then echo "$m"; else sort -s -t- -k1,1Vr <<<"$vers" | head -1; fi
}
semver_validate() {
	local a="${1%-*}"
	local a="${a#v}"
	local ac="${a//[.0-9]/}"
	[ ${#ac} = 0 ]
}
get_patch_last_supported_ver() {
	local list_patches=$1 pkg_name=$2 inc_sel=$3 _exc_sel=$4 _exclusive=$5 cli_source=$6 # TODO: resolve using all of these
	local op
	if [ "$inc_sel" ]; then
		if ! op=$(awk '{$1=$1}1' <<<"$list_patches"); then
			epr "list-patches: '$op'"
			return 1
		fi
		local ver vers="" NL=$'\n'
		while IFS= read -r line; do
			line="${line:1:${#line}-2}"
			ver=$(sed -n "/^Name: $line\$/,/^\$/p" <<<"$op" | sed -n "/^Compatible versions:\$/,/^\$/p" | tail -n +2)
			vers=${ver}${NL}
		done <<<"$(list_args "$inc_sel")"
		vers=$(awk '{$1=$1}1' <<<"$vers")
		if [ "$vers" ]; then
			get_highest_ver <<<"$vers"
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
	grep -F "($pcount patch" <<<"$op" | sed 's/ (.* patch.*//' | get_highest_ver || return 1
}

patches_list_versions() {
	local cli_jar=$1 patches_jar=$2 pkg_name=$3 cli_source=$4 op
	local cli_source_l="${cli_source,,}"
	if [[ "$cli_source_l" == *"npatch"* ]] || [[ "$cli_source_l" == *"lspatch"* ]]; then
		echo ""
		return 0
	fi

	# Build arg strings for each jar in space-separated patches_jar
	local IFS=$'\n'
	local p_jars=($(echo "$patches_jar" | tr ' ' '\n' | grep -v '^$'))
	unset IFS
	local p_args_short="" p_args_long=""
	for j in "${p_jars[@]}"; do
		p_args_short+="-p '$j' "
		p_args_long+="--patches '$j' "
	done
	# Try long form (--patches) with and without -b, then short form (-p)
	if ! op=$(eval java -jar "'$cli_jar'" list-versions $p_args_long -f "'$pkg_name'" -b 2>&1); then
		if ! op=$(eval java -jar "'$cli_jar'" list-versions $p_args_long -f "'$pkg_name'" 2>&1); then
			if ! op=$(eval java -jar "'$cli_jar'" list-versions $p_args_short -f "'$pkg_name'" -b 2>&1); then
				if ! op=$(eval java -jar "'$cli_jar'" list-versions $p_args_short -f "'$pkg_name'" 2>&1); then
					if ! op=$(eval java -jar "'$cli_jar'" list-versions $(echo "$patches_jar" | awk '{print $1}') -f "'$pkg_name'" 2>&1); then
						epr "Could not list versions $cli_jar: '$op'"
						return 1
					fi
				fi
			fi
		fi
	fi
	echo "$op"
}
patches_list() {
	local cli_jar=$1 patches_jar=$2 pkg_name=$3 cli_source=$4 op
	local cli_source_l="${cli_source,,}"
	if [[ "$cli_source_l" == *"npatch"* ]] || [[ "$cli_source_l" == *"lspatch"* ]]; then
		echo "Name: xposed-module-dummy"
		return 0
	fi
	# Build arg strings for each jar in space-separated patches_jar
	local IFS=$'\n'
	local p_jars=($(echo "$patches_jar" | tr ' ' '\n' | grep -v '^$'))
	unset IFS
	local p_args_short="" p_args_long="" p_args_pos=""
	for j in "${p_jars[@]}"; do
		p_args_short+="-p '$j' "
		p_args_long+="--patches '$j' "
		p_args_pos+="'$j' "
	done
	# Try positional (morphe-cli), then --patches with/without -b, then -p
	if ! op=$(eval java -jar "'$cli_jar'" list-patches --with-packages --with-versions $p_args_pos --filter-package-name "'$pkg_name'" 2>&1); then
		if ! op=$(eval java -jar "'$cli_jar'" list-patches $p_args_long --packages --versions --options -f "'$pkg_name'" -b 2>&1); then
			if ! op=$(eval java -jar "'$cli_jar'" list-patches $p_args_long --filter-package-name "'$pkg_name'" --with-versions --with-packages 2>&1); then
				if ! op=$(eval java -jar "'$cli_jar'" list-patches $p_args_short --packages --versions --options -f "'$pkg_name'" -b 2>&1); then
					if ! op=$(eval java -jar "'$cli_jar'" list-patches $p_args_short --filter-package-name "'$pkg_name'" --versions --packages -b 2>&1); then
						epr "Could not get patches list $cli_jar: '$op'"
						return 1
					fi
				fi
			fi
		fi
	fi
	echo "$op"
}

isoneof() {
	local i=$1 v
	shift
	for v; do [ "$v" = "$i" ] && return 0; done
	return 1
}

merge_splits() {
	local bundle=$1 output=$2
	if unzip -l "$bundle" 2>/dev/null | grep -q '^[[:space:]]*[0-9].*AndroidManifest\.xml$'; then
		pr "Downloaded bundle is actually a standard APK. Bypassing merge."
		mv -f "$bundle" "$output"
		return 0
	fi
	pr "Merging splits"
	gh_dl "$TEMP_DIR/apkeditor.jar" "https://github.com/REAndroid/APKEditor/releases/download/V1.4.9/APKEditor-1.4.9.jar" >/dev/null || return 1
	if ! OP=$(java -jar "$TEMP_DIR/apkeditor.jar" merge -i "$bundle" -o "${output}-unsigned" -clean-meta -f 2>&1); then
		epr "APKEditor error: $OP"
		return 1
	fi
	# sign the merged stock apk
	if ! OP=$(java -jar "$APKSIGNER" sign --ks ks-p12.keystore --ks-pass pass:123456789 --key-pass pass:123456789 --ks-key-alias jhc \
		--out "${output}" "${output}-unsigned"); then
		epr "apksigner error: $OP"
		return 1
	fi
	rm "${output}.idsig" "${output}-unsigned" 2>/dev/null || :
	return 0
}

_fs_get() {
	local url=$1 referer=${2:-}
	local max_retries=5 attempt
	local fs_url="${FLARESOLVERR_URL:-http://localhost:8191}/v1"
	local extra_headers=""
	[ -n "$referer" ] && extra_headers=",\"headers\":{\"Referer\":\"$referer\"}"
	for attempt in $(seq 1 $max_retries); do
		local response status
		response=$(curl -s -X POST "$fs_url" \
			-H 'Content-Type: application/json' \
			-d "{\"cmd\":\"request.get\",\"url\":\"$url\",\"maxTimeout\":60000${extra_headers}}") || true
		status=$(echo "$response" | jq -r '.status // empty')
		if [[ "$status" == "ok" ]]; then
			html=$(echo "$response" | jq -r '.solution.response // empty')
			export FS_COOKIES
			FS_COOKIES=$(echo "$response" | jq -r '[.solution.cookies[] | .name + "=" + .value] | join("; ")')
			user_agent=$(echo "$response" | jq -r '.solution.userAgent // empty')
			return 0
		fi
		wpr "FlareSolverr attempt $attempt/$max_retries failed for: $url"
		sleep 10
	done
	epr "FlareSolverr failed after $max_retries attempts: $url — falling back to plain request"
	html=$(req "$url" -) || return 1
	FS_COOKIES=""
	user_agent="Mozilla/5.0 (X11; Linux x86_64; rv:109.0) Gecko/20100101 Firefox/109.0"
}

# -------------------- apkmirror --------------------
get_apkmirror_resp() {
	local html=""
	_fs_get "${1}" || return 1
	__APKMIRROR_RESP__="$html"
	__APKMIRROR_CAT__="${1##*/}"
	__APKMIRROR_EXAMPLE_URL__="${args[apkmirror_example_url]:-}"
}

get_apkmirror_vers() {
	local vers apkm_resp html=""
	_fs_get "https://www.apkmirror.com/uploads/?appcategory=${__APKMIRROR_CAT__}" || return 1
	apkm_resp="$html"
	vers=$(sed -n 's;.*Version:</span><span class="infoSlide-value">\(.*\) </span>.*;\1;p' <<<"$apkm_resp" | awk '{$1=$1}1')
	if [ "$__AAV__" = false ]; then
		local IFS=$'\n'
		vers=$(grep -iv "\(beta\|alpha\)" <<<"$vers")
		local v r_vers=()
		for v in $vers; do
			grep -iq "${v} \(beta\|alpha\)" <<<"$apkm_resp" || r_vers+=("$v")
		done
		echo "${r_vers[*]}"
	else
		echo "$vers"
	fi
}

get_apkmirror_pkg_name() { sed -n 's;.*id=\(.*\)" class="accent_color.*;\1;p' <<<"$__APKMIRROR_RESP__"; }

apkmirror_search() {
	local resp="$1" dpi="$2" arch="$3" apk_bundle="$4" clean_search_version="$5"
	local dlurl="" node app_table emptyCheck

	local apparch=('universal' 'noarch' 'arm64-v8a + armeabi-v7a')
	if [ "$arch" != all ]; then
		apparch+=("$arch")
	fi

	local appdpi=("nodpi" "anydpi")
	local match_any_dpi=false
	if [ "$dpi" ]; then
		appdpi+=($dpi)
		if isoneof "auto" "${appdpi[@]}"; then
			match_any_dpi=true
		fi
	fi

	local best_fallback_url=""

	for ((n = 1; n < 40; n++)); do
		node=$($HTMLQ "div.table-row.headerFont:nth-last-child($n)" <<<"$resp")
		if [ -z "$node" ]; then break; fi
		
		dlurl=$($HTMLQ --base https://www.apkmirror.com --attribute href "div.table-cell:nth-child(1) > a:nth-child(1)" <<<"$node")
		if [ -z "$dlurl" ]; then continue; fi

		echo "[DEBUG] Evaluated variant dlurl: $dlurl" >&2
		
		local node_apk_bundle node_arch node_dpi
		node_apk_bundle=$($HTMLQ "div.table-cell:nth-child(1) span.apkm-badge:first-of-type" --text <<<"$node" | xargs)
		[ -z "$node_apk_bundle" ] && node_apk_bundle="APK"

		node_arch=$($HTMLQ "div.table-cell:nth-child(2)" --text <<<"$node" | xargs)
		node_dpi=$($HTMLQ "div.table-cell:nth-child(4)" --text <<<"$node" | xargs)

		if [ "$node_apk_bundle" != "$apk_bundle" ]; then continue; fi

		if [ -n "$clean_search_version" ] && [[ "$dlurl" != *"$clean_search_version"* ]]; then
			echo "[DEBUG] Rejected variant because it does not contain clean_search_version ($clean_search_version)"
			continue
		fi

		if isoneof "$node_arch" "${apparch[@]}"; then
			if isoneof "$node_dpi" "${appdpi[@]}"; then
				echo "$dlurl"
				return 0
			elif [ "$match_any_dpi" = true ] && [ -z "$best_fallback_url" ]; then
				best_fallback_url="$dlurl"
			fi
		fi
	done

	if [ -n "$best_fallback_url" ]; then
		echo "$best_fallback_url"
		return 0
	fi
	return 1
}

dl_apkmirror() {
	local url=$1 version=${2// /-} output=$3 arch=$4 dpi=$5 is_bundle=false
	local base_url="https://www.apkmirror.com"
	local html=""

	if [ -f "${output}.apkm" ]; then
		merge_splits "${output}.apkm" "${output}"
		return 0
	fi

	if [ "$arch" = "arm-v7a" ]; then arch="armeabi-v7a"; fi

	local clean_version="${version//[^0-9.]/}"
	if [[ "${__APKMIRROR_CAT__:-}" == *"todoist"* ]] && [[ "$clean_version" =~ ^([0-9]{1,2})([0-9]{2})([0-9])$ ]]; then
		# Transform 12190 -> 12.19.0
		clean_version="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}"
	fi
	local clean_search_version="${clean_version//./-}"

	local resp release_url=""

	if [ -n "${__APKMIRROR_EXAMPLE_URL__:-}" ]; then
		local example_path="${__APKMIRROR_EXAMPLE_URL__#$base_url}"
		local slug_ver target_ver
		slug_ver=$(echo "$example_path" | grep -oP '\d+(-\d+)+' | tail -1)
		target_ver=$(echo "$version" | tr '.' '-' | grep -oP '\d+(-\d+)+')
		if [ -n "$slug_ver" ] && [ -n "$target_ver" ]; then
			release_url="${base_url}${example_path/$slug_ver/$target_ver}"
				_fs_get "$release_url" || true
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
		_fs_get "$release_url" || true
		resp="$html"
		if [[ "$resp" == *"Page Not Found"* ]] || [[ "$resp" == *"404 Whoops"* ]] || [ -z "$resp" ]; then
			release_url=""
		fi
	fi

	if [ -z "$release_url" ]; then
		local list_url="${url%/}"
		local version_href=""
		for page_num in $(seq 1 5); do
			local page_url="$list_url/"
			[[ $page_num -gt 1 ]] && page_url="$list_url/page/$page_num/"
			_fs_get "$page_url" || return 1
			echo "[DEBUG] APKMirror HTML length: ${#html}, Preview: ${html:0:150}"
			
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

			if [ -n "$version_href" ]; then
				release_url="$base_url$version_href"
				_fs_get "$release_url" || return 1
				resp="$html"
				break
			fi
		done
		
		# Fallback to direct search if not found on first 5 pages
		if [ -z "$release_url" ]; then
			local search_list_url="https://www.apkmirror.com/?post_type=app_release&searchtype=apk&s=${__APKMIRROR_CAT__}+${version}"
			_fs_get "$search_list_url" || true
			if [ -n "$html" ] && [ "$html" != "null" ]; then
				local search_links
				search_links=$($HTMLQ --attribute href "div.appRow h5 a" <<<"$html")
				
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
					_fs_get "$release_url" || return 1
					resp="$html"
				fi
			fi
		fi

		if [ -z "$release_url" ]; then
			epr "Could not find version $version on APKMirror"
			return 1
		fi
	fi

	local node dlurl=""
	node=$($HTMLQ "div.table-row.headerFont:nth-last-child(1)" -r "span:nth-child(n+3)" <<<"$resp")
	if [ "$node" ]; then
		for type in APK BUNDLE; do
			if dlurl=$(apkmirror_search "$resp" "$dpi" "$arch" "$type" "$clean_search_version"); then
				[ "$type" = "BUNDLE" ] && is_bundle=true || is_bundle=false
				break
			fi
		done
		if [ -z "$dlurl" ]; then return 1; fi
		echo "[DEBUG] Fetching dlurl: $dlurl"
		_fs_get "$dlurl" || return 1
		resp="$html"
		echo "[DEBUG] Variant page HTML length: ${#resp}"
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

	_fs_get "$base_url$btn_url" || return 1
	local final_url
	final_url=$($HTMLQ "a#download-link" --attribute href <<<"$html" 2>/dev/null | head -1) || true
	[ -z "$final_url" ] && final_url=$(echo "$html" | grep -oP 'id="download-link"[^>]*href="\K[^"]+' | head -1) || true
	if [ -z "$final_url" ]; then epr "Could not find final download link on APKMirror"; return 1; fi
	final_url=$(echo "$final_url" | sed 's/&amp;/\&/g')
	[[ "$final_url" != http* ]] && final_url="${base_url}${final_url}"

	pr "Downloading APK: $final_url"
	local cookie_args=()
	[ -n "${FS_COOKIES:-}" ] && cookie_args=(--header "Cookie: $FS_COOKIES")
	local referer_url="$base_url$btn_url"
	[[ "$btn_url" == http* ]] && referer_url="$btn_url"

	if [ "$is_bundle" = true ]; then
		wget -nv -O "${output}.apkm" \
			--header="User-Agent: ${user_agent:-Mozilla/5.0}" \
			--referer="$referer_url" \
			"${cookie_args[@]}" \
			--timeout=300 \
			"$final_url" || return 1
		if ! unzip -t "${output}.apkm" >/dev/null 2>&1; then
			epr "Downloaded file is not a valid zip (apkm): $final_url"
			return 1
		fi
		merge_splits "${output}.apkm" "${output}"
	else
		wget -nv -O "${output}" \
			--header="User-Agent: ${user_agent:-Mozilla/5.0}" \
			--referer="$referer_url" \
			"${cookie_args[@]}" \
			--timeout=300 \
			"$final_url" || return 1
	fi
}

# -------------------- apkpure --------------------
get_apkpure_resp() {
	local url=$1
	url="${url%/downloading*}"
	url="${url%/}"
	__APKPURE_BASE_URL__="$url"
	__APKPURE_PKG__=$(echo "$url" | grep -oP '[a-zA-Z][a-zA-Z0-9]*(\.[a-zA-Z][a-zA-Z0-9]*){1,}' | tail -1)
	local html=""
	_fs_get "${url}/downloading/" || return 1
	__APKPURE_RESP__="$html"
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
		dl_page_url="${__APKPURE_BASE_URL__}/downloading"
	fi

	_fs_get "$dl_page_url" || return 1

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
	[ -n "${FS_COOKIES:-}" ] && cookie_header=(-H "Cookie: $FS_COOKIES")

	local is_bundle=false
	echo "$download_url" | grep -qi 'xapk' && is_bundle=true

	if [ "$is_bundle" = true ]; then
		curl -L -s -S \
			-H "User-Agent: ${user_agent:-Mozilla/5.0}" \
			-H "Referer: $dl_page_url" \
			"${cookie_header[@]}" \
			--connect-timeout 30 --max-time 300 \
			"$download_url" -o "${output}.xapk" || return 1
		_apkpure_install_xapk "${output}.xapk" "${output}" || return 1
	else
		curl -L --fail -s -S \
			-H "User-Agent: ${user_agent:-Mozilla/5.0}" \
			-H "Referer: $dl_page_url" \
			"${cookie_header[@]}" \
			--connect-timeout 30 --max-time 300 \
			"$download_url" -o "${output}" || return 1
	fi
}

_apkpure_install_xapk() {
	local xapk=$1 output=$2
	if ! unzip -t "$xapk" >/dev/null 2>&1; then
		epr "Downloaded XAPK is not a valid zip (Cloudflare block?): $xapk"
		return 1
	fi
	gh_dl "$TEMP_DIR/apkeditor.jar" "https://github.com/REAndroid/APKEditor/releases/download/V1.4.9/APKEditor-1.4.9.jar" >/dev/null || return 1
	if unzip -l "$xapk" 2>/dev/null | grep -q '^[[:space:]]*[0-9].*base\.apk$'; then
		pr "Extracting base.apk from XAPK"
		unzip -p "$xapk" base.apk > "$output" || return 1
	else
		pr "Merging XAPK splits with APKEditor"
		local OP
		if ! OP=$(java -jar "$TEMP_DIR/apkeditor.jar" m -i "$xapk" -o "${output}-unsigned" 2>&1); then
			epr "APKEditor m error: $OP"
			return 1
		fi
		if ! OP=$(java -jar "$APKSIGNER" sign --ks ks-p12.keystore --ks-pass pass:123456789 --key-pass pass:123456789 --ks-key-alias jhc \
			--out "$output" "${output}-unsigned" 2>&1); then
			epr "apksigner error: $OP"
			return 1
		fi
		rm "${output}.idsig" "${output}-unsigned" 2>/dev/null || :
	fi
}

# -------------------- apkcombo --------------------
get_apkcombo_resp() {
	local url=$1
	url="${url%/}"
	__APKCOMBO_PKG__="${url##*/}"
	__APKCOMBO_BASE_URL__="$url"
	local html=""
	_fs_get "https://apkcombo.com/search/${__APKCOMBO_PKG__}/download" || return 1
	__APKCOMBO_RESP__="$html"
}
get_apkcombo_vers() {
	echo "$__APKCOMBO_RESP__" | grep -oP 'phone-\K[0-9][^-]+-apk' | sed 's/-apk$//' | head -1
}
get_apkcombo_pkg_name() { echo "$__APKCOMBO_PKG__"; }
dl_apkcombo() {
	local _url=$1 version=$2 output=$3 _arch=$4 _dpi=$5
	local html="" dl_url final_url checkin page_url page compact_page

	if [ -n "$version" ]; then
		local sfxs=("apk" "xapk" "apks")
	else
		local sfxs=("apk")
	fi

	for sfx in "${sfxs[@]}"; do
		if [ -n "$version" ]; then
			page_url="https://apkcombo.com/search/${__APKCOMBO_PKG__}/download/phone-${version}-${sfx}"
		else
			page_url="https://apkcombo.com/search/${__APKCOMBO_PKG__}/download/apk"
		fi

		_fs_get "$page_url" "https://apkcombo.com/" || continue
		page="$html"
		compact_page=$(tr '\n' ' ' <<<"$page")

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
    parts.path,
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
		-H "Referer: $page_url" "$final_url" -o "$output" || return 1
	if ! unzip -t "$output" >/dev/null 2>&1; then
		epr "Downloaded file from APKCombo is not a valid zip"
		return 1
	fi
	if echo "$final_url$dl_url" | grep -qi 'xapk\|\.apks'; then
		_apkpure_install_xapk "$output" "${output}.extracted" || return 1
		mv "${output}.extracted" "$output"
	fi
}

# -------------------- uptodown --------------------
get_uptodown_resp() {
	_fs_get "${1}/versions" || return 1
	__UPTODOWN_RESP__="$html"
	_fs_get "${1}/download" || return 1
	__UPTODOWN_RESP_PKG__="$html"
}
get_uptodown_vers() { $HTMLQ --text ".version" <<<"$__UPTODOWN_RESP__"; }
dl_uptodown() {
	local uptodown_dlurl=$1 version=$2 output=$3 arch=$4 _dpi=$5
	if [ "$arch" = "arm-v7a" ]; then arch="armeabi-v7a"; fi

	local apparch=('universal' 'noarch' 'arm64-v8a, armeabi-v7a, x86_64' 'arm64-v8a, armeabi-v7a, x86, x86_64' 'arm64-v8a, armeabi-v7a')
	if [ "$arch" != all ]; then
		apparch+=("$arch")
	fi

	local op resp data_code
	data_code=$($HTMLQ "#detail-app-name" --attribute data-code <<<"$__UPTODOWN_RESP__")
	local versionURL=""
	local is_bundle=false
	for i in {1..20}; do
		_fs_get "${uptodown_dlurl}/apps/${data_code}/versions/${i}" || continue
		resp="$html"
		if ! op=$(jq -e -r ".data | map(select(.version == \"${version}\")) | .[0]" <<<"$resp" 2>/dev/null); then
			continue
		fi
		if [ "$(jq -e -r ".kindFile" <<<"$op")" = "xapk" ]; then is_bundle=true; fi
		if versionURL=$(jq -e -r '.versionURL' <<<"$op"); then break; else return 1; fi
	done
	if [ -z "$versionURL" ]; then return 1; fi
	versionURL=$(jq -e -r '.url + "/" + .extraURL + "/" + (.versionID | tostring)' <<<"$versionURL")
	_fs_get "$versionURL" || return 1
	resp="$html"

	local data_version files node_arch="" data_file_id node_class
	data_version=$($HTMLQ '.button.variants' --attribute data-version <<<"$resp") || return 1
	if [ "$data_version" ]; then
		_fs_get "${uptodown_dlurl%/*}/app/${data_code}/version/${data_version}/files" || return 1
		files=$(jq -e -r .content <<<"$html" 2>/dev/null) || return 1
		for ((n = 1; n < 12; n += 1)); do
			node_class=$($HTMLQ -w -t ".content > :nth-child($n)" --attribute class <<<"$files") || return 1
			if [ "$node_class" != "variant" ]; then
				node_arch=$($HTMLQ -w -t ".content > :nth-child($n)" <<<"$files" | xargs) || return 1
				continue
			fi
			if [ -z "$node_arch" ]; then return 1; fi
			if ! isoneof "$node_arch" "${apparch[@]}"; then continue; fi

			file_type=$($HTMLQ -w -t ".content > :nth-child($n) > .v-file > span" <<<"$files") || return 1
			if [ "$file_type" = "xapk" ]; then is_bundle=true; else is_bundle=false; fi
			data_file_id=$($HTMLQ ".content > :nth-child($n) > .v-report" --attribute data-file-id <<<"$files") || return 1
			_fs_get "${uptodown_dlurl}/download/${data_file_id}-x" || return 1
			resp="$html"
			break
		done
		if [ $n -eq 12 ]; then return 1; fi
	fi
	local data_url
	data_url=$($HTMLQ "#detail-download-button" --attribute data-url <<<"$resp") || return 1
	
	local cookie_args=()
	[ -n "${FS_COOKIES:-}" ] && cookie_args=(--header "Cookie: $FS_COOKIES")

	if [ $is_bundle = true ]; then
		wget -nv -O "${output}.apkm" \
			--header="User-Agent: ${user_agent:-Mozilla/5.0}" \
			"${cookie_args[@]}" \
			"https://dw.uptodown.com/dwn/${data_url}" || return 1
		merge_splits "${output}.apkm" "${output}"
	else
		wget -nv -O "${output}" \
			--header="User-Agent: ${user_agent:-Mozilla/5.0}" \
			"${cookie_args[@]}" \
			"https://dw.uptodown.com/dwn/${data_url}" || return 1
	fi
}
get_uptodown_pkg_name() { $HTMLQ --text "tr.full:nth-child(1) > td:nth-child(3)" <<<"$__UPTODOWN_RESP_PKG__"; }

# -------------------- archive --------------------
dl_archive() {
	local url=$1 version=$2 output=$3 arch=$4
	local path="" version_f=${version// /}
	while IFS= read -r p; do
		case "$p" in
			*"${version_f#v}-${arch// /}.apk"|*"${version_f#v}-${arch// /}.apkm"|*"${version_f#v}-${arch// /}.xapk"|*"${version_f#v}-${arch// /}.apks"|*"${version_f#v}-all.apk"|*"${version_f#v}-all.apkm"|*"${version_f#v}-all.xapk"|*"${version_f#v}-all.apks")
				path="$p"
				break
				;;
		esac
	done <<<"$__ARCHIVE_RESP__"
	if [ -z "$path" ]; then
		epr "Version ${version} with arch ${arch} not found in archive"
		return 1
	fi
	case "${path##*.}" in
		apk)
			req "${url}/${path}" "$output"
			;;
		apkm|xapk|apks)
			req "${url}/${path}" "${output}.${path##*.}" || return 1
			merge_splits "${output}.${path##*.}" "${output}"
			;;
		*)
			epr "Unsupported archive file type for ${path}"
			return 1
			;;
	esac
}
get_archive_resp() {
	local r
	r=$(req "$1" -)
	if [ -z "$r" ]; then return 1; else __ARCHIVE_RESP__=$(sed -n 's;^<a href="\(.*\)"[^"]*;\1;p' <<<"$r"); fi
	__ARCHIVE_PKG_NAME__=$(awk -F/ '{print $NF}' <<<"$1")
}
get_archive_vers() { sed 's/^[^-]*-//;s/-\(all\|arm64-v8a\|arm-v7a\|x86\|x86_64\)\.\(apk\|apkm\|xapk\|apks\)$//g' <<<"$__ARCHIVE_RESP__"; }
get_archive_pkg_name() { echo "$__ARCHIVE_PKG_NAME__"; }

# -------------------- github --------------------
dl_github() {
    local url=$1 version=$2 output=$3 arch=$4
    local path="" version_f=${version// /}
	local base_url=${__GITHUB_URL__:-$url}
    
    # Matches the exact file selection logic from dl_archive
    while IFS= read -r p; do
        case "$p" in
            *"${version_f#v}-${arch// /}.apk"|*"${version_f#v}-${arch// /}.apkm"|*"${version_f#v}-${arch// /}.xapk"|*"${version_f#v}-${arch// /}.apks"|*"${version_f#v}-all.apk"|*"${version_f#v}-all.apkm"|*"${version_f#v}-all.xapk"|*"${version_f#v}-all.apks")
                path="$p"
                break
                ;;
        esac
    done <<<"$__ARCHIVE_RESP__"
    
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
			local bundle="${output}.${ext}"
			req "${base_url}/${path}" "$bundle" || return 1
			merge_splits "$bundle" "$output"
            ;;
        *)
            epr "Unsupported github file type for ${path}"
            return 1
            ;;
    esac
}

get_github_resp() {
    local repo tag resp
    
    repo=$(cut -d/ -f4-5 <<<"$1")
    tag=${1%/}
    tag=${tag##*/}
    
    resp=$(gh_req "https://api.github.com/repos/${repo}/releases/tags/${tag}" -) || return 1
    
    # Extract only supported file extensions
    __ARCHIVE_RESP__=$(jq -r '.assets[]? | select(.name | test("\\.(apk|apkm|xapk|apks)$")) | .name' <<<"$resp")
    if [ -z "$__ARCHIVE_RESP__" ]; then return 1; fi
    
    # Grab the package name exactly like how get_archive_vers isolates the version
    __ARCHIVE_PKG_NAME__=$(get_github_pkg_name)
    if [ -z "$__ARCHIVE_PKG_NAME__" ]; then return 1; fi
    
    __GITHUB_URL__="https://github.com/${repo}/releases/download/${tag}"
}

# Extracts version matching the archive logic: strips prefix (up to first '-') and suffix (arch/extension)
get_github_vers() {
    sed 's/^[^-]*-//;s/-\(all\|arm64-v8a\|arm-v7a\|x86\|x86_64\)\.\(apk\|apkm\|xapk\|apks\)$//g' <<<"$__ARCHIVE_RESP__"
}

# Extracts package name by stripping everything from the first hyphen '-' onwards
get_github_pkg_name() {
    sed 's/-.*//' <<<"$__ARCHIVE_RESP__" | head -n 1
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
	local tmp_dir="${CWD}/${patched_apk}-temporary-files"
	local IFS=$'\n'
	local p_jars=($(echo "$patches_jar" | tr ' ' '\n' | grep -v '^$'))
	unset IFS

	local cli_source_l="${cli_source,,}"
	if [[ "$cli_source_l" == *"npatch"* ]] || [[ "$cli_source_l" == *"lspatch"* ]]; then
		local p_args_modules=""
		for j in "${p_jars[@]}"; do
			p_args_modules+=" -m '$j'"
		done
		mkdir -p "$tmp_dir"
		local cmd="java -jar '$cli_jar' '$stock_input' -o '$tmp_dir' $p_args_modules $patcher_args"
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

	local p_args_long="" p_args_short=""
	for j in "${p_jars[@]}"; do
		p_args_long+=" --patches '$j'"
		p_args_short+=" -p '$j'"
	done

	local base_cmd="java -jar '$cli_jar' patch '$stock_input' --purge -t '$tmp_dir' -o '$patched_apk' --keystore=ks.keystore \
--keystore-entry-password=123456789 --keystore-password=123456789 --signer=jhc --keystore-entry-alias=jhc"

	local cmd_long="${base_cmd}${p_args_long} $patcher_args"
	local cmd_short="${base_cmd}${p_args_short} $patcher_args"

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

write_build_info() {
	local key=$1 arch=$2 ext=$3 name=$4 version=$5 patches=$6 changelog=$7
	if [ "$ext" = ".apk" ] || [ "$mode_arg" = module ]; then
		log "${key} (${arch}): ${version}"
	fi
	local arch_orig="${args[arch]// /}"
	if [ "$arch_orig" != "auto" ]; then ext="${arch}${ext}"; arch=""; fi
	# extract applied patches supporting both old and new morphe-cli output formats
	# old: INFO: "Patch Name" succeeded
	# new: INFO: Applied: Patch Name
	local applied_json
	applied_json=$(printf '%s\n' "$PATCH_OUTPUT" | grep -oP '(?<=INFO: ")[^"\n]+(?=" succeeded)|(?<=INFO: Applied: ).*' | jq -R -s -c 'split("\n") | map(select(length > 0))' 2>/dev/null || true)
	[[ "$applied_json" != \[* ]] && applied_json='[]'
	jq --arg key "$key" \
		--arg ext "$ext" \
		--arg arch "$arch" \
		--arg name "$name" \
		--arg version "$version" \
		--arg patches "$patches" \
		--arg changelog "$changelog" \
		--argjson applied "$applied_json" \
		'if has($key) then .[$key].exts = (.[$key].exts + [$ext] | unique) else .[$key] = {exts: [$ext], name: $name, arch: $arch, version: $version, patches: $patches, changlog: $changelog, applied_patches: $applied} end' \
		"$BUILD_JSON_FILE" > "${BUILD_JSON_FILE}.tmp" && mv "${BUILD_JSON_FILE}.tmp" "$BUILD_JSON_FILE"
}

build_rv() {
	eval "declare -A args=${1#*=}"
	local version="" pkg_name=""
	local cli_jar="${args[cli]}"
	local patches_jar="${args[ptjar]}"
	local mode_arg=${args[build_mode]} version_mode=${args[version]}
	local app_name=${args[app_name]}
	local app_name_l=${app_name,,}
	app_name_l=${app_name_l// /-}
	local table=${args[table]}
	local dl_from=${args[dl_from]}
	local arch=${args[arch]}
	local arch_f="${arch// /}"
	local arch_list=("$arch_f")
	[ "$arch_f" = "auto" ] && arch_list=("all" "arm64-v8a" "arm-v7a")

	local p_patcher_args=()
	if [ "${args[excluded_patches]}" ]; then p_patcher_args+=("$(join_args "${args[excluded_patches]}" -d)"); fi
	if [ "${args[included_patches]}" ]; then p_patcher_args+=("$(join_args "${args[included_patches]}" -e)"); fi
	[ "${args[exclusive_patches]}" = true ] && p_patcher_args+=("--exclusive")

	local tried_dl=()
	if [ "${args[pkg_name]}" ]; then
		pkg_name="${args[pkg_name]}"
	else
		for dl_p in "${DL_SRCS[@]}"; do
			if [ -z "${args[${dl_p}_dlurl]}" ]; then continue; fi
			if ! get_${dl_p}_resp "${args[${dl_p}_dlurl]}" || ! pkg_name=$(get_"${dl_p}"_pkg_name); then
				args[${dl_p}_dlurl]=""
				epr "ERROR: Could not find ${table} in ${dl_p}"
				continue
			fi
			tried_dl+=("$dl_p")
			dl_from=$dl_p
			break
		done
	fi

	if [ -z "$pkg_name" ]; then
		epr "empty pkg name, not building ${table}."
		return 0
	fi
	pr "Package name of '${table}' is '$pkg_name'"
	local list_patches
	list_patches=$(patches_list "$cli_jar" "$patches_jar" "$pkg_name" "${args[cli_source]}") || return 1
	local get_latest_ver=false
	if [ "$version_mode" = auto ]; then
		if ! version=$(get_patch_last_supported_ver "$list_patches" "$pkg_name" \
			"${args[included_patches]}" "${args[excluded_patches]}" "${args[exclusive_patches]}" "${args[cli_source]}"); then
			epr "get_patch_last_supported_ver failed '$list_patches'"
			return
		elif [ -z "$version" ]; then get_latest_ver=true; fi
	elif isoneof "$version_mode" latest beta; then
		get_latest_ver=true
		p_patcher_args+=("-f")
	else
		version=$version_mode
		p_patcher_args+=("-f")
	fi
	if [ $get_latest_ver = true ]; then
		if [ "$version_mode" = beta ]; then __AAV__="true"; else __AAV__="false"; fi
		pkgvers=$(get_"${dl_from}"_vers)
		version=$(get_highest_ver <<<"$pkgvers") || version=$(head -1 <<<"$pkgvers")
	fi
	if [ -z "$version" ]; then
		epr "empty version, not building ${table}."
		return 0
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
	for arch in "${arch_list[@]}"; do
		arch_f="${arch// /}"
	local stock_apk="${TEMP_DIR}/${pkg_name}-${version_f}-${arch_f}.apk"
	if [ ! -f "$stock_apk" ]; then
		for dl_p in "${DL_SRCS[@]}"; do
			if [ -z "${args[${dl_p}_dlurl]}" ]; then continue; fi
			pr "Downloading '${table}' from '${dl_p}'"
			if ! isoneof $dl_p "${tried_dl[@]}"; then
				if ! get_${dl_p}_resp "${args[${dl_p}_dlurl]}"; then
					epr "ERROR: Could not get '${table}' from '${dl_p}'"
					continue
				fi
			fi
			if ! dl_${dl_p} "${args[${dl_p}_dlurl]}" "$version" "$stock_apk" "$arch" "${args[dpi]}" "$get_latest_ver"; then
				pr "ERROR: Could not download '${table}' from '${dl_p}' with version '${version}', arch '${arch}', dpi '${args[dpi]}'"
				continue
			fi
			if ! unzip -t "$stock_apk" >/dev/null 2>&1; then
				epr "ERROR: Downloaded file from ${dl_p} is not a valid zip archive (Cloudflare block or bad file)!"
				rm -f "$stock_apk"
				continue
			fi
			if ! unzip -l "$stock_apk" 2>/dev/null | grep -q '^[[:space:]]*[0-9].*AndroidManifest\.xml$'; then
				pr "WARNING: ${stock_apk} does not contain AndroidManifest.xml at root. Attempting to extract as XAPK/APKS..."
				mv "$stock_apk" "${stock_apk}.xapk"
				if ! _apkpure_install_xapk "${stock_apk}.xapk" "$stock_apk"; then
					epr "ERROR: Failed to extract XAPK/APKS"
					rm -f "${stock_apk}.xapk" "$stock_apk"
					continue
				fi
				rm -f "${stock_apk}.xapk"
			fi

			local aapt_cmd="aapt"
			if ! command -v aapt >/dev/null 2>&1 && [ -n "${ANDROID_SDK_ROOT:-}" ]; then
				aapt_cmd=$(ls -1 $ANDROID_SDK_ROOT/build-tools/*/aapt 2>/dev/null | tail -1) || true
			fi
			if [ -n "$aapt_cmd" ] && [ -x "$aapt_cmd" ]; then
				local downloaded_pkg downloaded_ver
				downloaded_pkg=$("$aapt_cmd" dump badging "$stock_apk" 2>/dev/null | grep -oP "package: name='\K[^']+" | head -1) || true
				downloaded_ver=$("$aapt_cmd" dump badging "$stock_apk" 2>/dev/null | grep -oP "versionName='\K[^']+" | head -1) || true
				
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

				if [ -n "$downloaded_ver" ] && [[ "$dl_p" == "direct" ]]; then
					if [ "$version" != "$downloaded_ver" ]; then
						pr "Updating version from '${version}' to '${downloaded_ver}' based on APK info"
						version="$downloaded_ver"
						version_f=${version// /}
						version_f=${version_f#v}
						
						local new_stock_apk="${TEMP_DIR}/${pkg_name}-${version_f}-${arch_f}.apk"
						mv "$stock_apk" "$new_stock_apk"
						stock_apk="$new_stock_apk"
					fi
				fi
			fi

			break
		done
	fi
	if [ -f "$stock_apk" ]; then break; fi
	done
	if [ ! -f "$stock_apk" ]; then
		epr "ERROR: Could not download '${table}'"
		return 0
	fi

	local sig_op
	if [ -f "${stock_apk}.apkm" ]; then
		rm -rf "${stock_apk}-zip" || :
		unzip -j "${stock_apk}.apkm" -d "${stock_apk}-zip" >/dev/null
		for a in "${stock_apk}"-zip/*.apk; do
			if ! sig_op=$(check_sig "$a" "$pkg_name" 2>&1); then
				epr "Not building $table, apk signature mismatch '$a': $sig_op"
				return 0
			fi
		done
		rm -rf "${stock_apk}-zip" || :
	else
		if ! sig_op=$(check_sig "$stock_apk" "$pkg_name" 2>&1); then
			epr "Not building $table, apk signature mismatch '$stock_apk': $sig_op"
			return 0
		fi
	fi

	local microg_patch
	microg_patch=$(grep "^Name: " <<<"$list_patches" | grep -i "gmscore\|microg" || :) microg_patch=${microg_patch#*: }
	if [ -n "$microg_patch" ] && [[ ${p_patcher_args[*]} =~ $microg_patch ]]; then
		wpr "You cant include/exclude microg patch as that's done by rvmm builder automatically."
		p_patcher_args=("${p_patcher_args[@]//-[ei] ${microg_patch}/}")
	fi

	local patcher_args patched_apk build_mode
	local rv_brand_f=${args[rv_brand],,}
	rv_brand_f=${rv_brand_f// /-}
	local patches_ref="${args[patches_ref]}"
	local changelog_url="${args[changelog_url]}"
	if [ "${args[patcher_args]}" ]; then p_patcher_args+=("${args[patcher_args]}"); fi
	for build_mode in "${build_mode_arr[@]}"; do
		patcher_args=("${p_patcher_args[@]}")
		pr "Building '${table}' in '$build_mode' mode"
		if [ -n "$microg_patch" ]; then
			patched_apk="${TEMP_DIR}/${app_name_l}-${rv_brand_f}-${version_f}-${arch_f}-${build_mode}.apk"
		else
			patched_apk="${TEMP_DIR}/${app_name_l}-${rv_brand_f}-${version_f}-${arch_f}.apk"
		fi
		if [ -n "$microg_patch" ]; then
			if [ "$build_mode" = apk ]; then
				patcher_args+=("-e \"${microg_patch}\"")
			elif [ "$build_mode" = module ]; then
				patcher_args+=("-d \"${microg_patch}\"")
			fi
		fi
		if [ "$build_mode" = module ]; then
			if [[ "${args[cli_source],,}" != *"revanced-cli"* ]]; then
				patcher_args+=("--mount")
			fi
		fi

		local stock_apk_to_patch="${stock_apk}.stripped.apk"
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

		local apk_output="${BUILD_DIR}/${app_name_l}-${rv_brand_f}-v${version_f}-${arch_f}.apk"
		if [ "${NORB:-}" != true ] || { [ ! -f "$patched_apk" ] && [ ! -f "$apk_output" ]; }; then
			if ! patch_apk "$stock_apk_to_patch" "$patched_apk" "${patcher_args[*]}" "${args[cli]}" "${args[ptjar]}" "${args[cli_source]}"; then
				epr "Building '${table}' failed!"
				return 0
			fi
		fi
		rm "$stock_apk_to_patch"
		if [ "$build_mode" = apk ]; then
			if [ "${NORB:-}" != true ] || { [ ! -f "$patched_apk" ] && [ ! -f "$apk_output" ]; }; then
				mv -f "$patched_apk" "$apk_output"
			else
				cp -f "$patched_apk" "$apk_output"
			fi
			pr "Built ${table} (non-root): '${apk_output}'"
			write_build_info "${table% (*}" "${arch_f}" ".apk" "${app_name_l}-${rv_brand_f}" "$version_f" "$patches_ref" "$changelog_url"
			continue
		fi
		local base_template
		base_template=$(mktemp -d -p "$TEMP_DIR")
		cp -a $MODULE_TEMPLATE_DIR/. "$base_template"
		local upj="${table,,}-update.json"

		module_config "$base_template" "$pkg_name" "$version_f" "$arch"

		local patches_ver
		patches_ver="${patches_jar%% *}"; patches_ver="${patches_ver##*-}"
		module_prop \
			"${args[module_prop_name]}" \
			"${app_name} ${args[rv_brand]}" \
			"${version_f} (patches ${patches_ver})" \
			"${app_name} ${args[rv_brand]} module" \
			"https://raw.githubusercontent.com/${GITHUB_REPOSITORY-}/update/${upj}" \
			"$base_template"

		local module_output="${app_name_l}-${rv_brand_f}-module-v${version_f}-${arch_f}.zip"
		pr "Packing module ${table}"
		cp -f "$patched_apk" "${base_template}/base.apk"

		if [ "${args[include_stock]}" != "disable" ]; then
			mkdir -p "${base_template}/stock/"
			if [ "${args[include_stock]}" = "merged" ]; then
				cp -f "$stock_apk" "${base_template}/stock/base.apk"
			elif [ "${args[include_stock]}" = "split" ]; then
				if [ ! -f "${stock_apk}.apkm" ]; then
					epr "Cannot include as 'split' because stock apk of $table_name is not a bundle"
					return 0
				fi
				if [ "$arch" = "arm64-v8a" ]; then
					unzip -j "${stock_apk}.apkm" '*.apk' -x '*x86_64.apk' -x '*x86.apk' -x '*armeabi_v7a.apk' -d "${base_template}/stock/" >/dev/null 2>&1
				elif [ "$arch" = "arm-v7a" ]; then
					unzip -j "${stock_apk}.apkm" '*.apk' -x '*x86_64.apk' -x '*x86.apk' -x '*arm64_v8a.apk' -d "${base_template}/stock/" >/dev/null 2>&1
				elif [ "$arch" = "x86" ]; then
					unzip -j "${stock_apk}.apkm" '*.apk' -x '*x86_64.apk' -x '*arm64_v8a.apk' -x '*armeabi_v7a.apk' -d "${base_template}/stock/" >/dev/null 2>&1
				elif [ "$arch" = "x86_64" ]; then
					unzip -j "${stock_apk}.apkm" '*.apk' -x '*x86.apk' -x '*arm64_v8a.apk' -x '*armeabi_v7a.apk' -d "${base_template}/stock/" >/dev/null 2>&1
				else
					unzip -j "${stock_apk}.apkm" '*.apk' -x '*x86_64.apk' -x '*x86.apk' -d "${base_template}/stock/" >/dev/null 2>&1
				fi
			fi
		fi

		pushd >/dev/null "$base_template" || abort "Module template dir not found"
		zip -"$COMPRESSION_LEVEL" -FSqr "${CWD}/${BUILD_DIR}/${module_output}" .
		popd >/dev/null || :
		pr "Built ${table} (root): '${BUILD_DIR}/${module_output}'"
		write_build_info "${table% (*}" "${arch_f}" ".zip" "${app_name_l}-${rv_brand_f}" "$version_f" "$patches_ref" "$changelog_url"
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
author=j-hc
description=${4}" >"${6}/module.prop"

	if [ "$ENABLE_MODULE_UPDATE" = true ]; then echo "updateJson=${5}" >>"${6}/module.prop"; fi
}
